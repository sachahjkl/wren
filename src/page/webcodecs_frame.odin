package page

// WebCodecs pixel storage: the raw pixels of a VideoFrame and the planar / packed formats WebCodecs names, kept in
// browser memory and bounded by a per-page ceiling (webcodecs.max_frame_bytes, charged in p.held alongside buffers).
// The VideoFrame object (bindings_webcodecs.odin) owns one of these; nothing here touches the DOM or the realm.
//
// Native-first: every pixel format conversion WebCodecs copyTo / drawImage needs is done here in Odin, plane by plane,
// never in the page's JavaScript. The storage keeps the frame in the layout it was created with (so copyTo of the same
// format is a straight copy) and converts on demand (to RGBA for drawing, between YUV planes for copyTo of another
// format). A frame built from a canvas / image is RGBA; one built from the media decoder keeps its I420 / NV12 planes.

import "core:mem"
import "wb:media"

// The pixel formats of the WebCodecs VideoPixelFormat enum we store. The suffix "A" formats carry alpha; "X" ones a
// padding byte. YUV formats are 4:2:0 (half chroma resolution each way) unless the name says otherwise (…422, …444).
Frame_Format :: enum u8 {
	None,
	I420,    // planar Y, U, V (4:2:0), 8-bit
	I420A,   // I420 plus an alpha plane (full resolution)
	I422,    // planar Y, U, V (4:2:2)
	I444,    // planar Y, U, V (4:4:4)
	NV12,    // planar Y, then interleaved UV (4:2:0)
	RGBA,    // packed R G B A
	RGBX,    // packed R G B X (opaque)
	BGRA,    // packed B G R A
	BGRX,    // packed B G R X (opaque)
}

// VideoColorSpace, as a frame carries it (WebCodecs VideoColorSpaceInit). The enums mirror the WebCodecs string enums;
// 0 is "unspecified" / null in every one, which is what a frame from a canvas reports (sRGB is implied for RGBA).
Frame_Color_Primaries :: enum u8 { Unspecified, BT709, BT470BG, SMPTE170M, BT2020, SMPTE432 }
Frame_Color_Transfer  :: enum u8 { Unspecified, BT709, SMPTE170M, IEC61966_2_1, Linear, PQ, HLG }
Frame_Color_Matrix    :: enum u8 { Unspecified, RGB, BT709, BT470BG, SMPTE170M, BT2020_NCL }

Frame_Color_Space :: struct {
	primaries:   Frame_Color_Primaries,
	transfer:    Frame_Color_Transfer,
	coefficients: Frame_Color_Matrix,   // the WebCodecs "matrix" member (matrix is an Odin keyword)
	full_range:  bool,
	// which of the four members were given (a VideoColorSpace reports null for an absent one, and copy keeps that)
	has_primaries, has_transfer, has_coefficients, has_full_range: bool,
}

// The default color space of an RGBA frame (sRGB): full-range RGB, BT.709 primaries, sRGB transfer. A frame built from
// a canvas / image / bitmap gets this; the planes of a decoded frame get their stream's color (frame_color_from_media).
FRAME_COLOR_SRGB :: Frame_Color_Space{
	primaries = .BT709, transfer = .IEC61966_2_1, coefficients = .RGB, full_range = true,
	has_primaries = true, has_transfer = true, has_coefficients = true, has_full_range = true,
}

// The pixels of a frame: the coded (padded) picture, with a visible rectangle inside it. Planes are laid out tightly
// (one plane after another) in `pix`, each row `strides[i]` bytes; `offsets[i]` is where plane i starts in `pix`.
Video_Pixels :: struct {
	format:  Frame_Format,
	coded_w, coded_h: int,      // the coded size (a multiple of 2 for chroma-subsampled formats)
	vis_x, vis_y, vis_w, vis_h: int,   // the visible rectangle inside the coded picture
	display_w, display_h: int,  // the size the frame says it should be shown at (aspect-ratio corrected)
	color:   Frame_Color_Space,
	pix:     []u8,              // owned (page allocator), charged in p.held
	strides: [4]int,
	offsets: [4]int,
	nplanes: int,
}

// The planes of a WebCodecs format: how many, and for each its horizontal / vertical subsampling (1 = full res) and
// bytes per sample. Used to size storage, to validate a layout and to convert.
Frame_Plane_Info :: struct {
	sub_x, sub_y: int,   // a plane row has coded_w/sub_x samples; a plane has coded_h/sub_y rows
	bytes:        int,   // bytes per sample (packed formats: one "plane" of 4 bytes per pixel)
}

frame_planes :: proc(f: Frame_Format) -> (planes: [4]Frame_Plane_Info, n: int) {
	switch f {
	case .None: return
	case .I420:
		planes[0] = {1, 1, 1}; planes[1] = {2, 2, 1}; planes[2] = {2, 2, 1}; return planes, 3
	case .I420A:
		planes[0] = {1, 1, 1}; planes[1] = {2, 2, 1}; planes[2] = {2, 2, 1}; planes[3] = {1, 1, 1}; return planes, 4
	case .I422:
		planes[0] = {1, 1, 1}; planes[1] = {2, 1, 1}; planes[2] = {2, 1, 1}; return planes, 3
	case .I444:
		planes[0] = {1, 1, 1}; planes[1] = {1, 1, 1}; planes[2] = {1, 1, 1}; return planes, 3
	case .NV12:
		planes[0] = {1, 1, 1}; planes[1] = {2, 2, 2}; return planes, 2   // UV interleaved: 2 bytes per chroma sample, half resolution
	case .RGBA, .RGBX, .BGRA, .BGRX:
		planes[0] = {1, 1, 4}; return planes, 1
	}
	return
}

frame_has_alpha :: proc(f: Frame_Format) -> bool {
	#partial switch f {
	case .I420A, .RGBA, .BGRA: return true
	}
	return false
}

frame_is_rgb :: proc(f: Frame_Format) -> bool {
	#partial switch f {
	case .RGBA, .RGBX, .BGRA, .BGRX: return true
	}
	return false
}

// The number of samples in a row of plane i, for a coded width.
@(private)
frame_plane_w :: proc(info: Frame_Plane_Info, coded_w: int) -> int { return (coded_w + info.sub_x - 1) / info.sub_x }
@(private)
frame_plane_h :: proc(info: Frame_Plane_Info, coded_h: int) -> int { return (coded_h + info.sub_y - 1) / info.sub_y }

// The tight (minimal) allocation size of a frame in `format` at `coded_w` x `coded_h`, and the per-plane strides and
// offsets a tight layout produces. This is what allocationSize() reports when no custom layout is given.
frame_layout :: proc(format: Frame_Format, coded_w, coded_h: int) -> (total: int, strides, offsets: [4]int, nplanes: int) {
	planes, n := frame_planes(format)
	nplanes = n
	off := 0
	for i in 0 ..< n {
		pw := frame_plane_w(planes[i], coded_w) * planes[i].bytes
		ph := frame_plane_h(planes[i], coded_h)
		strides[i] = pw
		offsets[i] = off
		off += pw * ph
	}
	total = off
	return
}

// Allocates the pixels of a frame, charged against the page's memory ceiling. Returns ok = false (and nothing allocated)
// when it would exceed webcodecs.max_frame_bytes or the page's held total. The caller fills `pix` then.
frame_pixels_alloc :: proc(p: ^Page, format: Frame_Format, coded_w, coded_h: int) -> (fp: Video_Pixels, ok: bool) {
	if coded_w <= 0 || coded_h <= 0 || format == .None { return }
	limit := p.settings.webcodecs.max_frame_bytes
	if coded_w > p.settings.webcodecs.max_dimension || coded_h > p.settings.webcodecs.max_dimension { return }
	total, strides, offsets, n := frame_layout(format, coded_w, coded_h)
	if total <= 0 || total > limit { return }
	if p.held + total > p.settings.max_fetch_bytes { return }
	fp.pix = make([]u8, total)
	fp.format = format
	fp.coded_w, fp.coded_h = coded_w, coded_h
	fp.vis_x, fp.vis_y, fp.vis_w, fp.vis_h = 0, 0, coded_w, coded_h
	fp.display_w, fp.display_h = coded_w, coded_h
	fp.strides, fp.offsets, fp.nplanes = strides, offsets, n
	fp.color = frame_is_rgb(format) ? FRAME_COLOR_SRGB : Frame_Color_Space{}
	p.held += total
	return fp, true
}

frame_pixels_free :: proc(p: ^Page, fp: ^Video_Pixels) {
	if fp.pix != nil {
		if !p.closed { p.held -= len(fp.pix) }
		delete(fp.pix)
		fp.pix = nil
	}
	fp^ = {}
}

// Builds a frame's pixels from tightly-packed RGBA8 straight-alpha bytes (what a canvas / image / ImageBitmap gives):
// the frame is stored as RGBA, visible rectangle = the whole picture.
frame_pixels_from_rgba :: proc(p: ^Page, rgba: []u8, w, h: int) -> (fp: Video_Pixels, ok: bool) {
	if w <= 0 || h <= 0 || len(rgba) < w * h * 4 { return }
	fp, ok = frame_pixels_alloc(p, .RGBA, w, h)
	if !ok { return }
	// tight RGBA: one stride, one plane
	if fp.strides[0] == w * 4 {
		copy(fp.pix, rgba[:w * h * 4])
	} else {
		for y in 0 ..< h { copy(fp.pix[y * fp.strides[0]:][:w * 4], rgba[y * w * 4:][:w * 4]) }
	}
	return
}

// The color space of a frame decoded from the media pipeline, from its stream's Color_Info.
frame_color_from_media :: proc(ci: media.Color_Info) -> Frame_Color_Space {
	cs: Frame_Color_Space
	if !ci.known && ci.primaries == 0 { return cs }
	cs.has_coefficients = true
	cs.coefficients = matrix_from_media(ci.coeffs)
	cs.has_transfer = true
	cs.transfer = transfer_from_media(ci.transfer)
	cs.has_primaries = ci.primaries != 0
	cs.primaries = primaries_from_media(ci.primaries)
	cs.has_full_range = true
	cs.full_range = ci.full_range
	return cs
}

@(private)
matrix_from_media :: proc(m: media.Matrix_Coeffs) -> Frame_Color_Matrix {
	switch m {
	case .Unspecified: return .Unspecified
	case .BT709:       return .BT709
	case .BT601:       return .BT470BG
	case .BT2020:      return .BT2020_NCL
	case .SMPTE240:    return .SMPTE170M
	case .Identity:    return .RGB
	}
	return .Unspecified
}

@(private)
transfer_from_media :: proc(t: media.Transfer) -> Frame_Color_Transfer {
	switch t {
	case .Unspecified: return .Unspecified
	case .SDR:         return .BT709
	case .PQ:          return .PQ
	case .HLG:         return .HLG
	}
	return .Unspecified
}

@(private)
primaries_from_media :: proc(code: u8) -> Frame_Color_Primaries {
	switch code {
	case 1:  return .BT709
	case 5:  return .BT470BG
	case 6:  return .SMPTE170M
	case 9:  return .BT2020
	case 12: return .SMPTE432
	}
	return .Unspecified
}

////////////////////////////////
// Conversion to RGBA (for drawing and for copyTo of an RGB format from a YUV frame)

// Writes the visible rectangle of `fp` into `dst` as tight straight-alpha RGBA8 (w*h*4 bytes, w = fp.vis_w). Used by
// drawImage / createImageBitmap(VideoFrame) and by copyTo when the destination format is RGBA / RGBX / BGRA / BGRX.
frame_to_rgba :: proc(fp: ^Video_Pixels, dst: []u8, bgr: bool, opaque: bool) {
	w, h := fp.vis_w, fp.vis_h
	if len(dst) < w * h * 4 { return }
	switch fp.format {
	case .None:
	case .RGBA, .RGBX, .BGRA, .BGRX:
		src_bgr := fp.format == .BGRA || fp.format == .BGRX
		src_opaque := fp.format == .RGBX || fp.format == .BGRX
		for y in 0 ..< h {
			srow := fp.pix[fp.offsets[0] + (fp.vis_y + y) * fp.strides[0] + fp.vis_x * 4:]
			drow := dst[y * w * 4:]
			for x in 0 ..< w {
				r, g, b, a: u8
				if src_bgr { b, g, r, a = srow[x * 4], srow[x * 4 + 1], srow[x * 4 + 2], srow[x * 4 + 3] }
				else       { r, g, b, a = srow[x * 4], srow[x * 4 + 1], srow[x * 4 + 2], srow[x * 4 + 3] }
				if src_opaque { a = 255 }
				frame_put_rgba(drow[x * 4:], r, g, b, a, bgr, opaque)
			}
		}
	case .I420, .I420A, .I422, .I444:
		frame_planar_to_rgba(fp, dst, bgr, opaque)
	case .NV12:
		frame_nv12_to_rgba(fp, dst, bgr, opaque)
	}
}

@(private)
frame_put_rgba :: proc(d: []u8, r, g, b, a: u8, bgr: bool, opaque: bool) {
	aa := opaque ? u8(255) : a
	if bgr { d[0], d[1], d[2], d[3] = b, g, r, aa } else { d[0], d[1], d[2], d[3] = r, g, b, aa }
}

// BT.601 limited-range YUV -> RGB (the common case for 8-bit video); full-range when the frame says so. Good enough for
// drawing and for copyTo's RGB conversion; a colour-managed path can refine it later.
@(private)
frame_yuv_to_rgb :: proc(y, u, v: int, full_range: bool) -> (r, g, b: u8) {
	yf, uf, vf: f32
	if full_range {
		yf = f32(y)
		uf = f32(u) - 128
		vf = f32(v) - 128
	} else {
		yf = (f32(y) - 16) * (255.0 / 219.0)
		uf = (f32(u) - 128) * (255.0 / 224.0)
		vf = (f32(v) - 128) * (255.0 / 224.0)
	}
	rf := yf + 1.402 * vf
	gf := yf - 0.344136 * uf - 0.714136 * vf
	bf := yf + 1.772 * uf
	return frame_clamp8(rf), frame_clamp8(gf), frame_clamp8(bf)
}

@(private)
frame_clamp8 :: proc(v: f32) -> u8 {
	if v <= 0 { return 0 }
	if v >= 255 { return 255 }
	return u8(v + 0.5)
}

@(private)
frame_planar_to_rgba :: proc(fp: ^Video_Pixels, dst: []u8, bgr: bool, opaque: bool) {
	w, h := fp.vis_w, fp.vis_h
	planes, _ := frame_planes(fp.format)
	full := fp.color.has_full_range ? fp.color.full_range : false
	has_alpha := fp.format == .I420A
	for y in 0 ..< h {
		yy := fp.vis_y + y
		yrow := fp.pix[fp.offsets[0] + yy * fp.strides[0] + fp.vis_x:]
		// the chroma row for this luma row (U and V share subsampling in every format here)
		urow := fp.pix[fp.offsets[1] + (yy / planes[1].sub_y) * fp.strides[1]:]
		vrow := fp.pix[fp.offsets[2] + (yy / planes[2].sub_y) * fp.strides[2]:]
		arow: []u8
		if has_alpha { arow = fp.pix[fp.offsets[3] + yy * fp.strides[3] + fp.vis_x:] }
		drow := dst[y * w * 4:]
		for x in 0 ..< w {
			xx := fp.vis_x + x
			r, g, b := frame_yuv_to_rgb(int(yrow[x]), int(urow[xx / planes[1].sub_x]), int(vrow[xx / planes[2].sub_x]), full)
			a: u8 = 255
			if has_alpha { a = arow[x] }
			frame_put_rgba(drow[x * 4:], r, g, b, a, bgr, opaque)
		}
	}
}

@(private)
frame_nv12_to_rgba :: proc(fp: ^Video_Pixels, dst: []u8, bgr: bool, opaque: bool) {
	w, h := fp.vis_w, fp.vis_h
	full := fp.color.has_full_range ? fp.color.full_range : false
	for y in 0 ..< h {
		yy := fp.vis_y + y
		yrow := fp.pix[fp.offsets[0] + yy * fp.strides[0] + fp.vis_x:]
		crow := fp.pix[fp.offsets[1] + (yy / 2) * fp.strides[1]:]
		drow := dst[y * w * 4:]
		for x in 0 ..< w {
			cx := (fp.vis_x + x) / 2
			u := int(crow[cx * 2])
			v := int(crow[cx * 2 + 1])
			r, g, b := frame_yuv_to_rgb(int(yrow[x]), u, v, full)
			frame_put_rgba(drow[x * 4:], r, g, b, 255, bgr, opaque)
		}
	}
}

////////////////////////////////
// copyTo and allocationSize with a visible-rectangle crop and an optional custom plane layout

// A plane layout as copyTo's options carry it: offset into the destination and the stride of each plane.
Frame_Plane_Layout :: struct { offset, stride: int }

// The layout copyTo uses when the caller gives none: tight packing of the (possibly cropped) rectangle in `format`.
// When `rect` is the whole coded picture and `format` is the frame's own, this is the frame's own layout.
frame_copy_layout :: proc(format: Frame_Format, rect_w, rect_h: int) -> (total: int, layout: [4]Frame_Plane_Layout, nplanes: int) {
	planes, n := frame_planes(format)
	nplanes = n
	off := 0
	for i in 0 ..< n {
		stride := frame_plane_w(planes[i], rect_w) * planes[i].bytes
		rows := frame_plane_h(planes[i], rect_h)
		layout[i] = {off, stride}
		off += stride * rows
	}
	total = off
	return
}

// allocationSize(options): the bytes copyTo needs for `rect` (default: the frame's visible rectangle) in `format`
// (default: the frame's own format), honouring a custom layout's strides when given.
frame_allocation_size :: proc(fp: ^Video_Pixels, format: Frame_Format, rect_w, rect_h: int, custom: []Frame_Plane_Layout) -> int {
	planes, n := frame_planes(format)
	if len(custom) == n {
		total := 0
		for i in 0 ..< n {
			rows := frame_plane_h(planes[i], rect_h)
			min_stride := frame_plane_w(planes[i], rect_w) * planes[i].bytes
			stride := max(custom[i].stride, min_stride)
			end := custom[i].offset + stride * rows
			if end > total { total = end }
		}
		return total
	}
	total, _, _ := frame_copy_layout(format, rect_w, rect_h)
	return total
}

// Copies the frame's `rect` into `dst` as `format`, with the plane layout `layout` (which has nplanes entries, matching
// `format`). Returns false when a conversion is not supported or `dst` is too small. The common path (same format, no
// conversion) is a plane-by-plane memcpy; RGB<->RGB reorders; YUV->RGB goes through frame_to_rgba.
frame_copy_to :: proc(fp: ^Video_Pixels, dst: []u8, format: Frame_Format, rect_x, rect_y, rect_w, rect_h: int, layout: [4]Frame_Plane_Layout, nplanes: int) -> bool {
	if rect_w <= 0 || rect_h <= 0 { return false }
	// RGB destination (any order): convert the (cropped) rectangle to the requested packed layout
	if frame_is_rgb(format) {
		bgr := format == .BGRA || format == .BGRX
		opaque := format == .RGBX || format == .BGRX
		stride := layout[0].stride
		off := layout[0].offset
		if off + stride * rect_h > len(dst) { return false }
		// convert via a temp RGBA of the crop (set the frame's visible rect to the requested crop for the converter)
		saved := fp^
		fp.vis_x, fp.vis_y, fp.vis_w, fp.vis_h = rect_x, rect_y, rect_w, rect_h
		defer fp^ = saved
		if stride == rect_w * 4 && off + rect_w * rect_h * 4 <= len(dst) {
			frame_to_rgba(fp, dst[off:], bgr, opaque)
		} else {
			tmp := make([]u8, rect_w * rect_h * 4, context.temp_allocator)
			frame_to_rgba(fp, tmp, bgr, opaque)
			for y in 0 ..< rect_h { copy(dst[off + y * stride:][:rect_w * 4], tmp[y * rect_w * 4:][:rect_w * 4]) }
		}
		return true
	}
	// YUV / NV12 destination: only a copy of the same format is supported (no YUV->YUV resampling here)
	if format != fp.format { return false }
	planes, n := frame_planes(format)
	if n != nplanes { return false }
	for i in 0 ..< n {
		src_stride := fp.strides[i]
		dst_stride := layout[i].stride
		rows := frame_plane_h(planes[i], rect_h)
		row_bytes := frame_plane_w(planes[i], rect_w) * planes[i].bytes
		if dst_stride < row_bytes { dst_stride = row_bytes }
		if layout[i].offset + dst_stride * rows > len(dst) { return false }
		src_x := (rect_x / planes[i].sub_x) * planes[i].bytes
		for r in 0 ..< rows {
			src_y := rect_y / planes[i].sub_y + r
			src := fp.pix[fp.offsets[i] + src_y * src_stride + src_x:]
			mem.copy(&dst[layout[i].offset + r * dst_stride], &src[0], row_bytes)
		}
	}
	return true
}

// A deep copy of a frame's pixels into fresh page-charged storage (VideoFrame.clone).
frame_pixels_clone :: proc(p: ^Page, src: ^Video_Pixels) -> (fp: Video_Pixels, ok: bool) {
	fp = src^
	fp.pix = nil
	limit := p.settings.webcodecs.max_frame_bytes
	if len(src.pix) > limit || p.held + len(src.pix) > p.settings.max_fetch_bytes { return Video_Pixels{}, false }
	fp.pix = make([]u8, len(src.pix))
	copy(fp.pix, src.pix)
	p.held += len(fp.pix)
	return fp, true
}
