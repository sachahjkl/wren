package images

// Decoding with WIC. Each thread keeps its own imaging factory (Codec_Context): WIC objects are free-threaded, but a
// factory per thread avoids any cross-thread traffic, and the thread's COM apartment is the multithreaded one.
//
// Pipeline for a still image: frame -> [scaler (Fant) when decoded smaller] -> format converter to 32bppRGBA ->
// CopyPixels into our buffer -> EXIF orientation. WIC's scaler reaches the JPEG decoder's IWICBitmapSourceTransform
// itself, so a reduced JPEG is decoded at 1/2, 1/4 or 1/8 scale in the DCT before the final resampling.

import win "core:sys/windows"

Codec_Context :: struct {
	factory:  ^IWICImagingFactory,
	com_init: bool,   // this context initialised COM on its thread and must uninitialise it
	ok:       bool,
}

// On the thread that will decode. Joins the multithreaded apartment (a thread already in a single-threaded one, such
// as a test's main thread, keeps it: WIC works in both).
codec_init :: proc(c: ^Codec_Context) -> bool {
	hr := win.CoInitializeEx(nil, .MULTITHREADED)
	c.com_init = succeeded(hr)
	if !succeeded(hr) && hr != RPC_E_CHANGED_MODE { return false }
	f: rawptr
	hr = win.CoCreateInstance(&CLSID_WICImagingFactory, nil, win.CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory, &f)
	if !succeeded(hr) || f == nil {
		if c.com_init { win.CoUninitialize(); c.com_init = false }
		return false
	}
	c.factory = (^IWICImagingFactory)(f)
	c.ok = true
	return true
}

codec_destroy :: proc(c: ^Codec_Context) {
	com_release(c.factory)
	c.factory = nil
	if c.com_init { win.CoUninitialize() }
	c^ = {}
}

// Headers only: format, natural size, frames, orientation. Allocates no pixels.
probe_with :: proc(c: ^Codec_Context, data: []byte, opts: Decode_Options) -> (Info, Error) {
	_, info, err := run(c, data, opts, true)
	return info, err
}

// The pixels. The image belongs to the caller (image_destroy), allocated with context.allocator.
decode_with :: proc(c: ^Codec_Context, data: []byte, opts: Decode_Options) -> (^Image, Info, Error) {
	return run(c, data, opts, false)
}

// Synchronous helpers for tools and tests: a codec context made and destroyed around the call, on the calling thread.
probe_now :: proc(data: []byte, opts: Decode_Options) -> (Info, Error) {
	c: Codec_Context
	if !codec_init(&c) { return {}, .Platform }
	defer codec_destroy(&c)
	return probe_with(&c, data, opts)
}

decode_now :: proc(data: []byte, opts: Decode_Options) -> (^Image, Info, Error) {
	c: Codec_Context
	if !codec_init(&c) { return nil, {}, .Platform }
	defer codec_destroy(&c)
	return decode_with(&c, data, opts)
}

@(private)
Wic :: struct {
	stream:  ^IWICStream,
	decoder: ^IWICBitmapDecoder,
}

@(private)
wic_release :: proc(w: ^Wic) {
	com_release(w.decoder)
	com_release(w.stream)
}

@(private)
run :: proc(c: ^Codec_Context, data: []byte, opts: Decode_Options, header_only: bool) -> (img: ^Image, info: Info, err: Error) {
	l := opts.limits
	if len(data) == 0 { return nil, {}, .Empty }
	if len(data) > l.max_encoded_bytes || len(data) > int(max(u32)) { return nil, {}, .Too_Many_Bytes }
	info.format = sniff(data, opts.mime, opts.nosniff)
	#partial switch info.format {
	case .Unknown: return nil, info, .Unknown_Format
	case .Svg: return nil, info, .Unsupported_Format
	}
	if hw, hh, known := header_size(data, info.format); known {
		if e := check_size(hw, hh, l); e != .None { return nil, info, e }
	}
	if !opts.allow_truncated && !looks_complete(data, info.format) { return nil, info, .Corrupt }
	if c == nil || !c.ok { return nil, info, .Platform }
	f := c.factory

	w: Wic
	defer wic_release(&w)
	if !succeeded(f.CreateStream(f, &w.stream)) { return nil, info, .Platform }
	if !succeeded(w.stream.InitializeFromMemory(w.stream, raw_data(data), u32(len(data)))) { return nil, info, .Platform }
	hr := f.CreateDecoderFromStream(f, w.stream, nil, WICDecodeMetadataCacheOnDemand, &w.decoder)
	if !succeeded(hr) {
		missing := hr == WINCODEC_ERR_COMPONENTNOTFOUND || hr == WINCODEC_ERR_UNKNOWNIMAGEFORMAT || hr == WINCODEC_ERR_COMPONENTINITIALIZEFAILURE
		#partial switch info.format {
		case .Webp, .Avif, .Heif: if missing { return nil, info, .Codec_Missing }
		}
		switch hr {
		case E_OUTOFMEMORY: return nil, info, .Too_Much_Memory
		case HRESULT_ARITHMETIC_OVERFLOW: return nil, info, .Too_Many_Pixels   // sizes the decoder itself cannot represent
		}
		return nil, info, .Corrupt
	}
	count: u32
	if !succeeded(w.decoder.GetFrameCount(w.decoder, &count)) || count == 0 { return nil, info, .Corrupt }
	info.frames = int(count)
	info.orientation = 1

	if info.format == .Gif && count > 1 {
		return gif_run(f, &w, data, opts, header_only, info)
	}

	index := u32(0)
	if info.format == .Ico && count > 1 { index = best_icon(&w, int(count), opts.target_w, opts.target_h) }
	frame: ^IWICBitmapFrameDecode
	if !succeeded(w.decoder.GetFrame(w.decoder, index, &frame)) || frame == nil { return nil, info, .Corrupt }
	defer com_release(frame)
	fw, fh: u32
	if !succeeded(frame.GetSize(frame, &fw, &fh)) { return nil, info, .Corrupt }
	if e := check_size(int(fw), int(fh), l); e != .None { return nil, info, e }
	#partial switch info.format {
	case .Jpeg: info.orientation = read_orientation(frame, win.L("/app1/ifd/{ushort=274}"))
	case .Tiff: info.orientation = read_orientation(frame, win.L("/ifd/{ushort=274}"))
	}
	info.width, info.height = oriented(int(fw), int(fh), info.orientation)
	if header_only { return nil, info, .None }

	// the reduced size is computed upright, then turned back to the stored orientation for the scaler
	ow, oh, reduced := reduced_size(info.width, info.height, opts.target_w, opts.target_h, opts.downscale_below)
	sw, sh := oriented(ow, oh, info.orientation)   // orientation is its own inverse on the dimensions
	src := rawptr(frame)
	scaler: ^IWICBitmapScaler
	defer com_release(scaler)
	if reduced {
		if succeeded(f.CreateBitmapScaler(f, &scaler)) && succeeded(scaler.Initialize(scaler, src, u32(sw), u32(sh), WICBitmapInterpolationModeFant)) {
			src = scaler
		} else {
			sw, sh, reduced = int(fw), int(fh), false
		}
	} else {
		sw, sh = int(fw), int(fh)
	}
	pixels, perr := copy_rgba(f, src, sw, sh)
	if perr != .None { return nil, info, perr }
	img = new(Image)
	img.allocator = context.allocator
	img.info = info
	img.reduced = reduced
	if info.orientation > 1 {
		up, uw, uh := apply_orientation(pixels, sw, sh, info.orientation)
		delete(pixels)
		pixels, sw, sh = up, uw, uh
	}
	img.width, img.height, img.stride = sw, sh, sw * 4
	img.frames = make([]Frame, 1)
	img.frames[0] = Frame{pixels = pixels}
	img.bytes = len(pixels)
	return img, info, .None
}

// RGBA pixels of a bitmap source (tightly packed). Converts through WIC's format converter; when the converter cannot
// produce RGBA directly (older systems), it produces BGRA and the channels are swapped here.
@(private)
copy_rgba :: proc(f: ^IWICImagingFactory, src: rawptr, w, h: int) -> ([]u8, Error) {
	conv: ^IWICFormatConverter
	if !succeeded(f.CreateFormatConverter(f, &conv)) { return nil, .Platform }
	defer com_release(conv)
	swap := false
	if !succeeded(conv.Initialize(conv, src, &GUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone, nil, 0, WICBitmapPaletteTypeCustom)) {
		com_release(conv)
		conv = nil
		if !succeeded(f.CreateFormatConverter(f, &conv)) { return nil, .Platform }
		if !succeeded(conv.Initialize(conv, src, &GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nil, 0, WICBitmapPaletteTypeCustom)) { return nil, .Corrupt }
		swap = true
	}
	size := w * h * 4
	pixels, aerr := make([]u8, size)
	if aerr != nil { return nil, .Too_Much_Memory }
	hr := conv.CopyPixels(conv, nil, u32(w * 4), u32(size), raw_data(pixels))
	if !succeeded(hr) {
		delete(pixels)
		return nil, hr == E_OUTOFMEMORY ? .Too_Much_Memory : .Corrupt
	}
	if swap {
		for i := 0; i < size; i += 4 { pixels[i], pixels[i + 2] = pixels[i + 2], pixels[i] }
	}
	return pixels, .None
}

// The icon of an ICO / CUR to show: the smallest at least as large as the target, else the largest.
@(private)
best_icon :: proc(w: ^Wic, count, tw, th: int) -> u32 {
	best, best_area := u32(0), -1
	fit, fit_area := u32(0), max(int)
	for i in 0 ..< count {
		fr: ^IWICBitmapFrameDecode
		if !succeeded(w.decoder.GetFrame(w.decoder, u32(i), &fr)) || fr == nil { continue }
		fw, fh: u32
		ok := succeeded(fr.GetSize(fr, &fw, &fh))
		com_release(fr)
		if !ok { continue }
		a := int(fw) * int(fh)
		if a > best_area { best, best_area = u32(i), a }
		if tw > 0 && th > 0 && int(fw) >= tw && int(fh) >= th && a < fit_area { fit, fit_area = u32(i), a }
	}
	return fit_area < max(int) ? fit : best
}

@(private)
read_orientation :: proc(frame: ^IWICBitmapFrameDecode, path: cstring16) -> u8 {
	r: ^IWICMetadataQueryReader
	if !succeeded(frame.GetMetadataQueryReader(frame, &r)) || r == nil { return 1 }
	defer com_release(r)
	v, ok := query_uint(r, path)
	return ok && v >= 1 && v <= 8 ? u8(v) : 1
}

@(private)
query_uint :: proc(r: ^IWICMetadataQueryReader, path: cstring16) -> (int, bool) {
	pv: PROPVARIANT
	if !succeeded(r.GetMetadataByName(r, path, &pv)) { return 0, false }
	defer PropVariantClear(&pv)
	switch pv.vt {
	case VT_UI1: return int(pv.u8_val), true
	case VT_UI2: return int(pv.u16_val), true
	case VT_UI4: return int(pv.u32_val), true
	case VT_I2: return int(pv.i16_val), true
	case VT_I4: return int(pv.i32_val), true
	}
	return 0, false
}

// A byte vector (VT_VECTOR | VT_UI1), copied into `buf`.
@(private)
query_bytes :: proc(r: ^IWICMetadataQueryReader, path: cstring16, buf: []u8) -> []u8 {
	pv: PROPVARIANT
	if !succeeded(r.GetMetadataByName(r, path, &pv)) { return nil }
	defer PropVariantClear(&pv)
	if pv.vt != VT_VECTOR | VT_UI1 || pv.caub.elems == nil { return nil }
	n := min(int(pv.caub.count), len(buf))
	copy(buf[:n], pv.caub.elems[:n])
	return buf[:n]
}

////////////////////////////////
// Animated GIF

@(private)
gif_run :: proc(f: ^IWICImagingFactory, w: ^Wic, data: []byte, opts: Decode_Options, header_only: bool, info_in: Info) -> (img: ^Image, info: Info, err: Error) {
	info = info_in
	l := opts.limits
	n := info.frames
	r: ^IWICMetadataQueryReader
	sw, sh := 0, 0
	info.plays = 1   // no loop extension: the animation runs once
	if succeeded(w.decoder.GetMetadataQueryReader(w.decoder, &r)) && r != nil {
		if v, ok := query_uint(r, win.L("/logscrdesc/Width")); ok { sw = v }
		if v, ok := query_uint(r, win.L("/logscrdesc/Height")); ok { sh = v }
		app: [16]u8
		name := query_bytes(r, win.L("/appext/Application"), app[:])
		if string(name) == "NETSCAPE2.0" || string(name) == "ANIMEXTS1.0" {
			ext: [16]u8
			if plays, ok := plays_from_loop_extension(query_bytes(r, win.L("/appext/Data"), ext[:])); ok { info.plays = plays }
		}
		com_release(r)
	}
	// a logical screen of 0 (or one smaller than the first frame) takes the first frame's extent, as browsers do
	{
		fr: ^IWICBitmapFrameDecode
		if !succeeded(w.decoder.GetFrame(w.decoder, 0, &fr)) || fr == nil { return nil, info, .Corrupt }
		fx, fy, fw, fh := gif_frame_rect(fr)
		com_release(fr)
		sw, sh = max(sw, fx + fw), max(sh, fy + fh)
	}
	if e := check_size(sw, sh, l); e != .None { return nil, info, e }
	info.width, info.height = sw, sh
	shown := opts.first_frame_only ? 1 : n
	info.animated = true
	if n > l.max_frames && !opts.first_frame_only { return nil, info, .Too_Many_Frames }
	frame_bytes := i64(sw) * i64(sh) * 4
	if frame_bytes * i64(shown) > l.max_image_bytes { return nil, info, .Too_Much_Memory }
	if header_only { return nil, info, .None }

	comp: Composer
	composer_init(&comp, sw, sh)
	defer composer_destroy(&comp)
	frames := make([dynamic]Frame, 0, shown)
	ok := false
	defer if !ok {
		for fr in frames { delete(fr.pixels) }
		delete(frames)
	}
	total := 0
	for i in 0 ..< shown {
		fr: ^IWICBitmapFrameDecode
		if !succeeded(w.decoder.GetFrame(w.decoder, u32(i), &fr)) || fr == nil {
			if i == 0 { return nil, info, .Corrupt }
			break   // a truncated animation shows the frames that arrived
		}
		raw: Raw_Frame
		raw.x, raw.y, raw.w, raw.h = gif_frame_rect(fr)
		if fe := check_size(raw.w, raw.h, l); fe != .None { com_release(fr); return nil, info, fe }
		raw.delay_cs, raw.disposal = 0, .Unspecified
		q: ^IWICMetadataQueryReader
		if succeeded(fr.GetMetadataQueryReader(fr, &q)) && q != nil {
			if v, vok := query_uint(q, win.L("/grctlext/Delay")); vok { raw.delay_cs = v }
			if v, vok := query_uint(q, win.L("/grctlext/Disposal")); vok && v <= 3 { raw.disposal = Disposal(v) }
			com_release(q)
		}
		px, perr := copy_rgba(f, fr, raw.w, raw.h)
		com_release(fr)
		if perr != .None {
			if i == 0 { return nil, info, perr }
			break
		}
		raw.pixels = px
		composer_add(&comp, raw)
		delete(px)
		out := make([]u8, len(comp.canvas))
		copy(out, comp.canvas)
		d := frame_delay_ms(raw.delay_cs, l)
		total += d
		append(&frames, Frame{pixels = out, delay_ms = d})
	}
	img = new(Image)
	img.allocator = context.allocator
	img.info = info
	img.width, img.height, img.stride = sw, sh, sw * 4
	img.frames = frames[:]
	img.duration_ms = len(frames) > 1 ? total : 0
	img.bytes = len(frames) * sw * sh * 4
	if len(frames) <= 1 { img.info.animated = false }
	ok = true
	return img, img.info, .None
}

@(private)
gif_frame_rect :: proc(fr: ^IWICBitmapFrameDecode) -> (x, y, w, h: int) {
	fw, fh: u32
	if succeeded(fr.GetSize(fr, &fw, &fh)) { w, h = int(fw), int(fh) }
	q: ^IWICMetadataQueryReader
	if succeeded(fr.GetMetadataQueryReader(fr, &q)) && q != nil {
		if v, ok := query_uint(q, win.L("/imgdesc/Left")); ok { x = v }
		if v, ok := query_uint(q, win.L("/imgdesc/Top")); ok { y = v }
		com_release(q)
	}
	return
}
