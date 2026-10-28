package page

// WebCodecs host side (api/webcodecs.widl, native/js/runtime/web_webcodecs.c). VideoFrame first: a host object holding
// Video_Pixels (webcodecs_frame.odin). A frame is constructed from an image source (canvas / image / video / bitmap /
// another VideoFrame) or from a BufferSource with a VideoFrameBufferInit; its metadata (format, coded / display size,
// visible rectangle, timestamp, duration, colour space) and its pixels are read by getters and by copyTo. drawImage and
// createImageBitmap(VideoFrame) resolve it through canvas_source (canvas_sources.odin).
//
// Native-first: the whole pixel model, the format conversions and the memory accounting are here in Odin. The engine
// only holds the VideoFrame wrapper, builds the dictionaries, resolves copyTo's promise and transfers the handle in a
// postMessage. A frame is "closed" (its pixels freed) by close(), by a transfer, or when the page goes away.

import "core:sync"
import "wb:base"
import "wb:canvas2d"
import "wb:media"

// A VideoFrame. The pixels may be gone (closed): the getters then report the last metadata (spec: a closed frame's
// attributes are null / 0 and most operations throw InvalidStateError — the engine checks `closed` before the call).
Video_Frame_Obj :: struct {
	page:      ^Page,
	self:      u64,
	px:        Video_Pixels,
	timestamp: i64,          // microseconds (WebCodecs timestamps are microseconds)
	duration:  i64,          // microseconds, -1 = none
	has_duration: bool,
	closed:    bool,
	// a premultiplied copy of the visible rectangle, made on first draw (drawImage / createImageBitmap); freed with the
	// frame. Rebuilt is never needed: a VideoFrame's pixels do not change after construction.
	draw_bmp:  canvas2d.Bitmap,
	has_draw:  bool,
}

video_frame_vt := Object_VTable{
	name = "VideoFrame",
	destroy = proc(p: ^Page, data: rawptr) {
		f := (^Video_Frame_Obj)(data)
		if f.has_draw { canvas_bitmap_free(p, &f.draw_bmp) }
		frame_pixels_free(p, &f.px)
		free(f)
	},
}

// The premultiplied bitmap a canvas draws a VideoFrame from: the visible rectangle converted to premultiplied BGRA,
// cached on the frame. nil when the frame is closed or memory is short.
@(private)
video_frame_draw_bitmap :: proc(p: ^Page, f: ^Video_Frame_Obj) -> ^canvas2d.Bitmap {
	if f.closed { return nil }
	if f.has_draw { return &f.draw_bmp }
	w, h := f.px.vis_w, f.px.vis_h
	if w <= 0 || h <= 0 { return nil }
	bmp, ok := canvas_bitmap(p, w, h)
	if !ok { return nil }
	// convert the visible rect to straight RGBA, then premultiply into the canvas bitmap's BGRA storage
	rgba := make([]u8, w * h * 4, context.temp_allocator)
	frame_to_rgba(&f.px, rgba, false, false)
	canvas2d.bitmap_write_straight(&bmp, rgba, w, 0, 0, w, h, 0, 0)
	canvas2d.bitmap_touch_all(&bmp)
	f.draw_bmp = bmp
	f.has_draw = true
	return &f.draw_bmp
}

lookup_VideoFrame :: proc(c: ^Call, h: u64) -> ^Video_Frame_Obj { return (^Video_Frame_Obj)(object_data(c.page, h, &video_frame_vt)) }

@(private)
video_frame_of :: proc(p: ^Page, h: u64) -> ^Video_Frame_Obj { return (^Video_Frame_Obj)(object_data(p, h, &video_frame_vt)) }

// Makes a VideoFrame object around already-built pixels (takes ownership of fp).
@(private)
video_frame_new :: proc(p: ^Page, owner: u32, fp: Video_Pixels, timestamp, duration: i64, has_duration: bool) -> u64 {
	f := new(Video_Frame_Obj)
	f.page = p
	f.px = fp
	f.timestamp = timestamp
	f.duration = duration
	f.has_duration = has_duration
	f.self = object_create(p, &video_frame_vt, f, owner)
	return f.self
}

////////////////////////////////
// The format enum as the ABI passes it (api/webcodecs.widl VideoPixelFormat); must match Frame_Format's order.

@(private)
frame_format_from_abi :: proc(v: i32) -> Frame_Format {
	if v < 0 || v > i32(Frame_Format.BGRX) { return .None }
	return Frame_Format(v)
}
@(private)
frame_format_to_abi :: proc(f: Frame_Format) -> i32 { return i32(f) }

////////////////////////////////
// Construction

// new VideoFrame(image, {timestamp, duration, ...}): build from a drawable source. `source` is an element handle (img,
// canvas, video) or an object handle (ImageBitmap, OffscreenCanvas, VideoFrame). The source's pixels are captured as
// RGBA now (a VideoFrame is a snapshot). `timestamp` is required for an image source without an intrinsic one; a
// VideoFrame / video keeps its own unless overridden (has_ts).
VideoFrame_fromImage :: proc(c: ^Call, source: u64, timestamp: i64, has_ts: bool, duration: i64, has_duration: bool) -> (u64, Api_Error) {
	p := c.page
	if !p.settings.webcodecs.enabled { return 0, fail(c, .Not_Supported, "WebCodecs is disabled.") }

	// another VideoFrame: clone its pixels, keep (or override) its timing
	if src := video_frame_of(p, source); src != nil {
		if src.closed { return 0, fail(c, .Invalid_State, "InvalidStateError: the source VideoFrame is closed.") }
		fp, ok := frame_pixels_clone(p, &src.px)
		if !ok { return 0, fail(c, .Quota, "QuotaExceededError: VideoFrame too large.") }
		ts := has_ts ? timestamp : src.timestamp
		dur := has_duration ? duration : src.duration
		hd := has_duration || src.has_duration
		return video_frame_new(p, c.owner, fp, ts, dur, hd), .None
	}

	// a canvas / image / video / ImageBitmap / OffscreenCanvas: capture its current pixels as RGBA
	rgba, w, h, ts_us, ok := capture_source_rgba(p, source)
	if !ok {
		return 0, fail(c, .Invalid_State, "InvalidStateError: the image source cannot provide pixels (not loaded, empty or unsupported).")
	}
	defer delete(rgba, context.temp_allocator)
	fp, fok := frame_pixels_from_rgba(p, rgba, w, h)
	if !fok { return 0, fail(c, .Quota, "QuotaExceededError: VideoFrame too large.") }
	ts := has_ts ? timestamp : ts_us
	return video_frame_new(p, c.owner, fp, ts, duration, has_duration), .None
}

// new VideoFrame(bufferSource, init): build from raw pixel bytes with a VideoFrameBufferInit. `format`, `coded_w`,
// `coded_h`, `timestamp` are required by the spec (the engine checks and passes them). The visible rectangle and the
// display size default to the coded picture; a custom layout gives per-plane offsets / strides.
VideoFrame_fromBuffer :: proc(c: ^Call, data: []u8, format_abi: i32, coded_w: i32, coded_h: i32, timestamp: i64, duration: i64, has_duration: bool,
	vis_x, vis_y, vis_w, vis_h: i32, has_visible: bool, display_w, display_h: i32, has_display: bool,
	layout_offsets, layout_strides: []i32, has_layout: bool,
	cp_prim, cp_trans, cp_matrix: i32, cp_full: i32, cp_has: i32) -> (u64, Api_Error) {
	p := c.page
	if !p.settings.webcodecs.enabled { return 0, fail(c, .Not_Supported, "WebCodecs is disabled.") }
	format := frame_format_from_abi(format_abi)
	if format == .None { return 0, fail(c, .Not_Supported, "NotSupportedError: unknown VideoFrame format.") }
	cw, ch := int(coded_w), int(coded_h)
	if cw <= 0 || ch <= 0 || cw > p.settings.webcodecs.max_dimension || ch > p.settings.webcodecs.max_dimension {
		return 0, fail(c, .Range, "RangeError: invalid coded size.")
	}
	fp, ok := frame_pixels_alloc(p, format, cw, ch)
	if !ok { return 0, fail(c, .Quota, "QuotaExceededError: VideoFrame too large.") }

	// fill the planes from `data`, either tightly or through the given layout
	if !frame_fill_from_buffer(&fp, data, has_layout, layout_offsets, layout_strides) {
		frame_pixels_free(p, &fp)
		return 0, fail(c, .Type, "TypeError: the buffer is too small for the frame's layout.")
	}

	if has_visible {
		if int(vis_x) < 0 || int(vis_y) < 0 || int(vis_w) <= 0 || int(vis_h) <= 0 || int(vis_x) + int(vis_w) > cw || int(vis_y) + int(vis_h) > ch {
			frame_pixels_free(p, &fp)
			return 0, fail(c, .Range, "RangeError: visibleRect is outside the coded picture.")
		}
		fp.vis_x, fp.vis_y, fp.vis_w, fp.vis_h = int(vis_x), int(vis_y), int(vis_w), int(vis_h)
	}
	if has_display && display_w > 0 && display_h > 0 { fp.display_w, fp.display_h = int(display_w), int(display_h) }
	else { fp.display_w, fp.display_h = fp.vis_w, fp.vis_h }
	if cp_has != 0 { fp.color = color_from_abi(cp_prim, cp_trans, cp_matrix, cp_full) }

	return video_frame_new(p, c.owner, fp, timestamp, duration, has_duration), .None
}

// Fills the planes of `fp` from `data`. Without a layout the bytes are the frame's tight layout as a whole; with one,
// each plane's rows are copied from (offset, stride) in `data`.
@(private)
frame_fill_from_buffer :: proc(fp: ^Video_Pixels, data: []u8, has_layout: bool, offsets, strides: []i32) -> bool {
	planes, n := frame_planes(fp.format)
	if !has_layout {
		if len(data) < len(fp.pix) { return false }
		copy(fp.pix, data[:len(fp.pix)])
		return true
	}
	if len(offsets) != n || len(strides) != n { return false }
	for i in 0 ..< n {
		rows := frame_plane_h(planes[i], fp.coded_h)
		row_bytes := frame_plane_w(planes[i], fp.coded_w) * planes[i].bytes
		src_stride := max(int(strides[i]), row_bytes)
		src_off := int(offsets[i])
		if src_off < 0 || src_off + src_stride * rows > len(data) { return false }
		for r in 0 ..< rows {
			copy(fp.pix[fp.offsets[i] + r * fp.strides[i]:][:row_bytes], data[src_off + r * src_stride:][:row_bytes])
		}
	}
	return true
}

@(private)
color_from_abi :: proc(prim, trans, coeffs, full: i32) -> Frame_Color_Space {
	cs: Frame_Color_Space
	if prim >= 0 { cs.has_primaries = true; cs.primaries = Frame_Color_Primaries(clamp(prim, 0, i32(Frame_Color_Primaries.SMPTE432))) }
	if trans >= 0 { cs.has_transfer = true; cs.transfer = Frame_Color_Transfer(clamp(trans, 0, i32(Frame_Color_Transfer.HLG))) }
	if coeffs >= 0 { cs.has_coefficients = true; cs.coefficients = Frame_Color_Matrix(clamp(coeffs, 0, i32(Frame_Color_Matrix.BT2020_NCL))) }
	if full >= 0 { cs.has_full_range = true; cs.full_range = full != 0 }
	return cs
}

// Captures the current pixels of an image source as tight straight-alpha RGBA8 (temp allocator). Returns the intrinsic
// timestamp in microseconds (a <video>'s currentTime) when it has one, else 0.
@(private)
capture_source_rgba :: proc(p: ^Page, h: u64) -> (rgba: []u8, w, h_out: int, ts_us: i64, ok: bool) {
	src := canvas_source(p, h)
	if src.status != .Ok { return }
	// a <video>: read its current picture through the media view into RGBA
	if src.video != base.NIL_HANDLE {
		return capture_video_rgba(p, src.video)
	}
	sbmp := canvas_source_bitmap(&src)
	if sbmp == nil || sbmp.w <= 0 || sbmp.h <= 0 { return }
	w, h_out = sbmp.w, sbmp.h
	rgba = make([]u8, w * h_out * 4, context.temp_allocator)
	// the canvas bitmap is premultiplied RGBA8; unpremultiply back to straight alpha (byte order stays R G B A)
	for i := 0; i + 4 <= len(rgba); i += 4 {
		r0, g0, b0, a0 := sbmp.pix[i], sbmp.pix[i + 1], sbmp.pix[i + 2], sbmp.pix[i + 3]
		rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3] = unpremul(r0, a0), unpremul(g0, a0), unpremul(b0, a0), a0
	}
	ok = true
	return
}

@(private)
unpremul :: proc(c, a: u8) -> u8 {
	if a == 0 { return 0 }
	if a == 255 { return c }
	v := (u32(c) * 255 + u32(a) / 2) / u32(a)
	return u8(min(v, 255))
}

////////////////////////////////
// Metadata getters

VideoFrame_format :: proc(c: ^Call, f: Api_VideoFrame) -> i32 {
	if f.data == nil || f.data.closed { return -1 }   // null for a closed frame
	return frame_format_to_abi(f.data.px.format)
}
VideoFrame_codedWidth :: proc(c: ^Call, f: Api_VideoFrame) -> u32 { return f.data == nil || f.data.closed ? 0 : u32(f.data.px.coded_w) }
VideoFrame_codedHeight :: proc(c: ^Call, f: Api_VideoFrame) -> u32 { return f.data == nil || f.data.closed ? 0 : u32(f.data.px.coded_h) }
VideoFrame_displayWidth :: proc(c: ^Call, f: Api_VideoFrame) -> u32 { return f.data == nil || f.data.closed ? 0 : u32(f.data.px.display_w) }
VideoFrame_displayHeight :: proc(c: ^Call, f: Api_VideoFrame) -> u32 { return f.data == nil || f.data.closed ? 0 : u32(f.data.px.display_h) }
VideoFrame_timestamp :: proc(c: ^Call, f: Api_VideoFrame) -> i64 { return f.data == nil ? 0 : f.data.timestamp }
VideoFrame_duration :: proc(c: ^Call, f: Api_VideoFrame) -> i64 { return f.data == nil || !f.data.has_duration ? -1 : f.data.duration }

// visibleRect: x, y, width, height into `rect` (four f64). Returns false (null) for a closed frame.
VideoFrame_visibleRect :: proc(c: ^Call, f: Api_VideoFrame, rect: []f64) -> bool {
	if f.data == nil || f.data.closed || len(rect) < 4 { return false }
	fp := &f.data.px
	rect[0], rect[1], rect[2], rect[3] = f64(fp.vis_x), f64(fp.vis_y), f64(fp.vis_w), f64(fp.vis_h)
	return true
}

// colorSpace members: -1 (null) when absent. kind selects primaries (0), transfer (1), matrix (2); full-range is a bool.
VideoFrame_colorSpace :: proc(c: ^Call, f: Api_VideoFrame, which: i32) -> i32 {
	if f.data == nil { return -1 }
	cs := f.data.px.color
	switch which {
	case 0: return cs.has_primaries ? i32(cs.primaries) : -1
	case 1: return cs.has_transfer ? i32(cs.transfer) : -1
	case 2: return cs.has_coefficients ? i32(cs.coefficients) : -1
	case 3: return cs.has_full_range ? (cs.full_range ? 1 : 0) : -1
	}
	return -1
}

////////////////////////////////
// allocationSize / copyTo

// allocationSize(options): the destination format (default: the frame's own, format_abi < 0), an optional crop rect
// (has_rect), and an optional custom layout (offsets / strides, has_layout).
VideoFrame_allocationSize :: proc(c: ^Call, f: Api_VideoFrame, format_abi: i32, rx, ry, rw, rh: i32, has_rect: bool,
	layout_offsets, layout_strides: []i32, has_layout: bool) -> (i32, Api_Error) {
	if f.data == nil || f.data.closed { return 0, fail(c, .Invalid_State, "InvalidStateError: the VideoFrame is closed.") }
	fp := &f.data.px
	format := format_abi < 0 ? fp.format : frame_format_from_abi(format_abi)
	if format == .None { return 0, fail(c, .Not_Supported, "NotSupportedError: unknown pixel format.") }
	rect_w := has_rect ? int(rw) : fp.vis_w
	rect_h := has_rect ? int(rh) : fp.vis_h
	if rect_w <= 0 || rect_h <= 0 { return 0, fail(c, .Range, "RangeError: empty rectangle.") }
	custom := layout_to_slice(layout_offsets, layout_strides, has_layout)
	return i32(frame_allocation_size(fp, format, rect_w, rect_h, custom)), .None
}

@(private)
layout_to_slice :: proc(offsets, strides: []i32, has: bool) -> []Frame_Plane_Layout {
	if !has || len(offsets) != len(strides) || len(offsets) == 0 { return nil }
	out := make([]Frame_Plane_Layout, len(offsets), context.temp_allocator)
	for i in 0 ..< len(offsets) { out[i] = {int(offsets[i]), int(strides[i])} }
	return out
}

// copyTo(destination, options): copies the frame into `dst` and reports the plane layout actually used (offsets /
// strides into `out_offsets` / `out_strides`, one per plane; the count returned). The engine wraps this in a promise.
VideoFrame_copyTo :: proc(c: ^Call, f: Api_VideoFrame, dst: []u8, format_abi: i32, rx, ry, rw, rh: i32, has_rect: bool,
	in_offsets, in_strides: []i32, has_layout: bool, out_offsets, out_strides: []i32) -> (i32, Api_Error) {
	if f.data == nil || f.data.closed { return 0, fail(c, .Invalid_State, "InvalidStateError: the VideoFrame is closed.") }
	fp := &f.data.px
	format := format_abi < 0 ? fp.format : frame_format_from_abi(format_abi)
	if format == .None { return 0, fail(c, .Not_Supported, "NotSupportedError: unknown pixel format.") }
	rect_x := has_rect ? int(rx) : fp.vis_x
	rect_y := has_rect ? int(ry) : fp.vis_y
	rect_w := has_rect ? int(rw) : fp.vis_w
	rect_h := has_rect ? int(rh) : fp.vis_h
	if rect_w <= 0 || rect_h <= 0 || rect_x < 0 || rect_y < 0 || rect_x + rect_w > fp.coded_w || rect_y + rect_h > fp.coded_h {
		return 0, fail(c, .Range, "RangeError: the rectangle is outside the coded picture.")
	}
	planes, n := frame_planes(format)
	layout: [4]Frame_Plane_Layout
	custom := layout_to_slice(in_offsets, in_strides, has_layout)
	if custom != nil {
		if len(custom) != n { return 0, fail(c, .Type, "TypeError: the layout has the wrong number of planes.") }
		for i in 0 ..< n {
			min_stride := frame_plane_w(planes[i], rect_w) * planes[i].bytes
			layout[i] = {custom[i].offset, max(custom[i].stride, min_stride)}
		}
	} else {
		_, layout, _ = frame_copy_layout(format, rect_w, rect_h)
	}
	if !frame_copy_to(fp, dst, format, rect_x, rect_y, rect_w, rect_h, layout, n) {
		return 0, fail(c, .Not_Supported, "NotSupportedError: this copyTo conversion is not supported.")
	}
	for i in 0 ..< n {
		if i < len(out_offsets) { out_offsets[i] = i32(layout[i].offset) }
		if i < len(out_strides) { out_strides[i] = i32(layout[i].stride) }
	}
	return i32(n), .None
}

////////////////////////////////
// clone / close / transfer

VideoFrame_clone :: proc(c: ^Call, f: Api_VideoFrame) -> (u64, Api_Error) {
	if f.data == nil || f.data.closed { return 0, fail(c, .Invalid_State, "InvalidStateError: the VideoFrame is closed.") }
	fp, ok := frame_pixels_clone(c.page, &f.data.px)
	if !ok { return 0, fail(c, .Quota, "QuotaExceededError: VideoFrame too large.") }
	return video_frame_new(c.page, c.owner, fp, f.data.timestamp, f.data.duration, f.data.has_duration), .None
}

VideoFrame_close :: proc(c: ^Call, f: Api_VideoFrame) {
	if f.data == nil || f.data.closed { return }
	f.data.closed = true
	frame_pixels_free(c.page, &f.data.px)
}

VideoFrame_isClosed :: proc(c: ^Call, f: Api_VideoFrame) -> bool { return f.data == nil || f.data.closed }

// Transfer (postMessage) within the same realm: move the frame's pixels into a new object owned by `owner`, closing the
// original. Kept for a same-realm structured clone with transfer.
VideoFrame_transfer :: proc(c: ^Call, f: Api_VideoFrame, owner: u32) -> (u64, Api_Error) {
	if f.data == nil || f.data.closed { return 0, fail(c, .Data_Clone, "DataCloneError: the VideoFrame is detached.") }
	moved := f.data.px
	f.data.px = {}
	f.data.closed = true
	return video_frame_new(c.page, owner, moved, f.data.timestamp, f.data.duration, f.data.has_duration), .None
}

////////////////////////////////
// Cross-realm transfer store (postMessage to a worker / another page). The source realm detaches the frame into a
// process-wide token; the destination realm adopts the token, building a VideoFrame in its own registry. The pixels
// never cross a heap boundary as JS values: the host owns them throughout. The store is bounded by the same frame
// ceiling and is freed if nobody adopts it (a dropped message) through webcodecs_transfer_sweep.

@(private)
Frame_Transfer :: struct {
	token:    u64,
	px:       Video_Pixels,
	timestamp, duration: i64,
	has_duration: bool,
}

@(private)
Frame_Transfer_Store :: struct {
	mu:     sync.Mutex,
	items:  [dynamic]Frame_Transfer,
	next:   u64,
}

@(private)
frame_transfers: Frame_Transfer_Store

// Detach a frame into the transfer store, returning its token (0 on failure). The source object is closed.
VideoFrame_takeForTransfer :: proc(c: ^Call, f: Api_VideoFrame) -> u64 {
	if f.data == nil || f.data.closed { return 0 }
	sync.mutex_lock(&frame_transfers.mu)
	defer sync.mutex_unlock(&frame_transfers.mu)
	frame_transfers.next += 1
	tok := frame_transfers.next
	moved := f.data.px
	f.data.px = {}
	f.data.closed = true
	// the pixels are no longer charged to the source page: account them to no page while in flight
	if !c.page.closed { c.page.held -= len(moved.pix) }
	append(&frame_transfers.items, Frame_Transfer{token = tok, px = moved, timestamp = f.data.timestamp, duration = f.data.duration, has_duration = f.data.has_duration})
	return tok
}

// Adopt a transferred frame into the calling realm's registry (the receiver of a postMessage). 0 when the token is
// unknown (already adopted, or swept) or the destination page cannot charge the pixels.
VideoFrame_adoptTransfer :: proc(c: ^Call, token: u64) -> u64 {
	sync.mutex_lock(&frame_transfers.mu)
	idx := -1
	for it, i in frame_transfers.items { if it.token == token { idx = i; break } }
	if idx < 0 { sync.mutex_unlock(&frame_transfers.mu); return 0 }
	item := frame_transfers.items[idx]
	ordered_remove(&frame_transfers.items, idx)
	sync.mutex_unlock(&frame_transfers.mu)
	p := c.page
	// charge the pixels to the destination page; refuse (and drop) if it is over budget
	if p.held + len(item.px.pix) > p.settings.max_fetch_bytes {
		delete(item.px.pix)
		return 0
	}
	p.held += len(item.px.pix)
	return video_frame_new(p, c.owner, item.px, item.timestamp, item.duration, item.has_duration)
}

////////////////////////////////
// <video> capture

// Reads a <video>'s current picture as RGBA. The media view gives the decoded picture; only a CPU frame (planes) can be
// read back here — a GPU-only picture (DXVA texture) is not reachable from the page layer, so the capture fails and the
// VideoFrame constructor raises (the common software / VP9 / AV1 path keeps CPU planes). ts_us is the video position.
@(private)
capture_video_rgba :: proc(p: ^Page, node: base.Handle) -> (rgba: []u8, w, h: int, ts_us: i64, ok: bool) {
	v, vok := media_view(p, node, true)
	if !vok || v.frame == nil { return }
	frame := v.frame
	w, h = frame.width, frame.height
	if w <= 0 || h <= 0 || frame.planes[0] == nil { return }
	rgba = make([]u8, w * h * 4, context.temp_allocator)
	if !media_video_frame_to_rgba(frame, rgba, w, h) { delete(rgba, context.temp_allocator); return nil, 0, 0, 0, false }
	ts_us = i64(media.time_seconds(frame.pts) * 1_000_000)
	ok = true
	return
}

// Converts a media.Video_Frame's CPU planes (NV12 / I420, 8-bit) to tight straight-alpha RGBA8. 10-bit (P010 /
// I420_10) is down-shifted to 8-bit. Returns false for a GPU-only frame (no planes) or an unhandled format.
@(private)
media_video_frame_to_rgba :: proc(frame: ^media.Video_Frame, dst: []u8, w, h: int) -> bool {
	if frame.planes[0] == nil || len(dst) < w * h * 4 { return false }
	full := frame.color.full_range
	cx0, cy0 := frame.crop[0], frame.crop[1]
	switch frame.format {
	case .None: return false
	case .NV12, .P010:
		shift := frame.format == .P010 ? u8(8) : 0
		for y in 0 ..< h {
			yrow := frame.planes[0][(cy0 + y) * frame.strides[0]:]
			crow := frame.planes[1][((cy0 + y) / 2) * frame.strides[1]:]
			for x in 0 ..< w {
				yy := int(media_sample8(yrow, cx0 + x, shift, frame.format == .P010))
				cx := (cx0 + x) / 2
				u := int(media_sample8(crow, cx * 2, shift, frame.format == .P010))
				vv := int(media_sample8(crow, cx * 2 + 1, shift, frame.format == .P010))
				r, g, b := frame_yuv_to_rgb(yy, u, vv, full)
				d := dst[(y * w + x) * 4:]
				d[0], d[1], d[2], d[3] = r, g, b, 255
			}
		}
		return true
	case .I420, .I420_10:
		p10 := frame.format == .I420_10
		shift := p10 ? u8(8) : 0
		for y in 0 ..< h {
			yrow := frame.planes[0][(cy0 + y) * frame.strides[0]:]
			urow := frame.planes[1][((cy0 + y) / 2) * frame.strides[1]:]
			vrow := frame.planes[2][((cy0 + y) / 2) * frame.strides[2]:]
			for x in 0 ..< w {
				cx := (cx0 + x) / 2
				yy := int(media_sample8(yrow, cx0 + x, shift, p10))
				u := int(media_sample8(urow, cx, shift, p10))
				vv := int(media_sample8(vrow, cx, shift, p10))
				r, g, b := frame_yuv_to_rgb(yy, u, vv, full)
				d := dst[(y * w + x) * 4:]
				d[0], d[1], d[2], d[3] = r, g, b, 255
			}
		}
		return true
	}
	return false
}

@(private)
media_sample8 :: proc(row: []u8, index: int, shift: u8, wide: bool) -> u8 {
	if wide {
		lo := u32(row[index * 2])
		hi := u32(row[index * 2 + 1])
		return u8(((hi << 8) | lo) >> shift)
	}
	return row[index]
}
