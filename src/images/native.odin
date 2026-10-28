package images

// The built-in decoders: Rust (native\media), in the one Rust static library of wren.exe (tools\build_native.ps1 ->
// build\native\wren_native.lib). WebP and
// AVIF never go to WIC (they would need optional Store extensions there, and these are formats where a memory-safe
// decoder matters most); SVG documents are parsed once per encoded file (the parsed tree is kept with the Blob, shared by
// every raster made from it) and rasterised at whatever size is asked. The library converts colours to sRGB itself
// (qcms) and is also used for the ICC profiles of the formats WIC decodes.

import "base:runtime"
import "core:sync"

when ODIN_OS == .Windows {
	foreign import wren_native {
		"../../build/native/wren_native.lib",
		"system:ws2_32.lib",
		"system:advapi32.lib",
		"system:userenv.lib",
		"system:ntdll.lib",
		"system:kernel32.lib",
		"system:bcrypt.lib",
		"system:msvcrt.lib",
		"system:ucrt.lib",
		"system:libvcruntime.lib",
	}
} else {
	// tools/build_native.sh (cargo for this system): Rust's standard library needs libdl, libpthread and libm
	foreign import wren_native { "../../build/native-" + ODIN_OS_STRING + "/libwren_native.a", "system:opus", "system:asound", "system:dl", "system:pthread", "system:m" }
}

// Mirrors of the library's repr(C) structs (native\media\src\lib.rs).
@(private)
Wm_Limits :: struct {
	max_dimension:       u32,
	max_frames:          u32,
	max_pixels:          u64,
	max_image_bytes:     u64,
	min_delay_ms:        u32,
	default_delay_ms:    u32,
	first_frame_only:    u8,
	color_manage:        u8,
	svg_text:            u8,
	svg_data_images:     u8,
	svg_max_nodes:       u32,
	svg_max_depth:       u32,
	svg_max_expansion:   u64,
	svg_max_render_cost: u64,
	target_w, target_h:  u32,
}

@(private)
Wm_Info :: struct {
	width, height:   u32,
	frames, plays:   u32,
	animated:        u8,
	has_alpha:       u8,
	bit_depth:       u8,
	color:           u8,
	svg_has_w:       u8,
	svg_has_h:       u8,
	orientation:     u8,
	_pad:            u8,
	svg_w, svg_h:    f32,
	svg_ratio:       f32,
}

@(private)
Wm_Frame_Proc :: #type proc "c" (user: rawptr, index, w, h, delay_ms: u32) -> [^]u8

@(private)
Wm_Sink :: struct {
	user:  rawptr,
	frame: Wm_Frame_Proc,
}

@(private)
Wm_Byte_Sink :: struct {
	user:  rawptr,
	alloc: proc "c" (user: rawptr, n: uint) -> [^]u8,
}

// The library's codes of the raster formats (native\media\src\raster.rs); 0: not one of them.
@(private)
raster_code :: proc(f: Format) -> u32 {
	#partial switch f {
	case .Png:  return 1
	case .Jpeg: return 2
	case .Gif:  return 3
	case .Bmp:  return 4
	case .Ico:  return 5
	case .Tiff: return 6
	}
	return 0
}

@(private, default_calling_convention = "c")
foreign wren_native {
	wm_webp_probe :: proc(data: [^]u8, len: uint, limits: ^Wm_Limits, info: ^Wm_Info) -> i32 ---
	wm_webp_decode :: proc(data: [^]u8, len: uint, limits: ^Wm_Limits, out_w, out_h: u32, sink: ^Wm_Sink, info: ^Wm_Info) -> i32 ---
	wm_avif_probe :: proc(data: [^]u8, len: uint, limits: ^Wm_Limits, info: ^Wm_Info) -> i32 ---
	wm_avif_decode :: proc(data: [^]u8, len: uint, limits: ^Wm_Limits, out_w, out_h: u32, sink: ^Wm_Sink, info: ^Wm_Info) -> i32 ---
	wm_svg_parse :: proc(data: [^]u8, len: uint, limits: ^Wm_Limits, info: ^Wm_Info, doc: ^rawptr) -> i32 ---
	wm_svg_render :: proc(doc: rawptr, limits: ^Wm_Limits, w, h: u32, pixels: [^]u8) -> i32 ---
	wm_svg_free :: proc(doc: rawptr) ---
	wm_raster_probe :: proc(format: u32, data: [^]u8, len: uint, limits: ^Wm_Limits, info: ^Wm_Info) -> i32 ---
	wm_raster_decode :: proc(format: u32, data: [^]u8, len: uint, limits: ^Wm_Limits, out_w, out_h: u32, sink: ^Wm_Sink, info: ^Wm_Info) -> i32 ---
	wm_raster_encode :: proc(format: u32, rgba: [^]u8, w, h: u32, quality: f32, premultiplied: u8, sink: ^Wm_Byte_Sink) -> i32 ---
	wm_color_icc_to_srgb :: proc(icc: [^]u8, icc_len: uint, pixels: [^]u8, n: uint) -> i32 ---
	wm_color_adobe_to_srgb :: proc(pixels: [^]u8, n: uint) -> i32 ---
	wm_versions :: proc() -> cstring ---
}

// "resvg 0.48.1, image-webp 0.2.4, ..." (about: pages).
native_versions :: proc() -> string { return string(wm_versions()) }

@(private)
wm_limits :: proc(o: Decode_Options) -> Wm_Limits {
	l := o.limits
	s := l.svg
	return Wm_Limits{
		max_dimension = u32(clamp(l.max_dimension, 1, int(max(u32)))), max_frames = u32(clamp(l.max_frames, 1, int(max(u32)))),
		max_pixels = u64(max(l.max_pixels, 1)), max_image_bytes = u64(max(l.max_image_bytes, 1)),
		min_delay_ms = u32(max(l.min_delay_ms, 0)), default_delay_ms = u32(max(l.default_delay_ms, 1)),
		first_frame_only = u8(o.first_frame_only), color_manage = u8(l.color_manage),
		svg_text = u8(s.text), svg_data_images = u8(s.data_images),
		svg_max_nodes = u32(clamp(s.max_nodes, 1, int(max(u32)))), svg_max_depth = u32(clamp(s.max_depth, 1, 100_000)),
		svg_max_expansion = u64(max(s.max_expansion, 0)), svg_max_render_cost = u64(max(s.max_render_cost, 1)),
		target_w = u32(clamp(o.target_w, 0, int(max(u32)))), target_h = u32(clamp(o.target_h, 0, int(max(u32)))),
	}
}

@(private)
error_of :: proc(code: i32) -> Error {
	if code < 0 || code > i32(max(Error)) { return .Internal }
	return Error(code)
}

@(private)
info_of :: proc(f: Format, w: Wm_Info) -> Info {
	info := Info{format = f, width = int(w.width), height = int(w.height), frames = int(w.frames), plays = int(w.plays), orientation = max(w.orientation, 1)}
	info.animated = w.animated != 0
	info.color = Color_Tag(min(w.color, u8(max(Color_Tag))))
	if f == .Svg {
		info.svg = Svg_Size{has_w = w.svg_has_w != 0, has_h = w.svg_has_h != 0, w = w.svg_w, h = w.svg_h, ratio = w.svg_ratio}
	}
	return info
}

// The frames the library writes, allocated here (context.allocator of the decode) as it asks for them.
@(private)
Native_Frames :: struct {
	ctx:      runtime.Context,
	frames:   [dynamic]Frame,
	w, h:     int,
	limit:    i64,
	bytes:    i64,
	failed:   bool,
}

@(private)
native_frame :: proc "c" (user: rawptr, index, w, h, delay_ms: u32) -> [^]u8 {
	nf := (^Native_Frames)(user)
	context = nf.ctx
	if len(nf.frames) == 0 { nf.w, nf.h = int(w), int(h) }
	if int(w) != nf.w || int(h) != nf.h { nf.failed = true; return nil }
	size := i64(w) * i64(h) * 4
	if nf.bytes + size > nf.limit { nf.failed = true; return nil }
	px, err := make([]u8, int(size))
	if err != nil { nf.failed = true; return nil }
	nf.bytes += size
	append(&nf.frames, Frame{pixels = px, delay_ms = int(delay_ms)})
	return raw_data(px)
}

// WebP / AVIF, and PNG, JPEG, GIF, BMP, ICO, TIFF (raster_code): headers (`header_only`) or pixels, EXIF orientation
// applied. Stills may come reduced to (target_w, target_h) by `reduced_size`.
@(private)
native_raster :: proc(data: []byte, info_in: Info, opts: Decode_Options, header_only: bool) -> (img: ^Image, info: Info, err: Error) {
	info = info_in
	l := wm_limits(opts)
	wi: Wm_Info
	avif := info.format == .Avif
	rc := raster_code(info.format)
	probe :: proc(rc: u32, avif: bool, data: []byte, l: ^Wm_Limits, wi: ^Wm_Info) -> i32 {
		if rc != 0 { return wm_raster_probe(rc, raw_data(data), uint(len(data)), l, wi) }
		return avif ? wm_avif_probe(raw_data(data), uint(len(data)), l, wi) : wm_webp_probe(raw_data(data), uint(len(data)), l, wi)
	}
	code := probe(rc, avif, data, &l, &wi)
	if code != 0 { return nil, info, error_of(code) }
	info = info_of(info.format, wi)
	if e := check_size(info.width, info.height, opts.limits); e != .None { return nil, info, e }
	if info.animated && !opts.first_frame_only && info.frames > opts.limits.max_frames { return nil, info, .Too_Many_Frames }
	if header_only { return nil, info, .None }

	ow, oh, reduced := 0, 0, false
	if !info.animated || opts.first_frame_only {
		ow, oh, reduced = reduced_size(info.width, info.height, opts.target_w, opts.target_h, opts.downscale_below)
	}
	nf := Native_Frames{ctx = context, limit = opts.limits.max_image_bytes}
	nf.frames = make([dynamic]Frame)
	ok := false
	defer if !ok {
		for f in nf.frames { delete(f.pixels) }
		delete(nf.frames)
	}
	sink := Wm_Sink{user = &nf, frame = native_frame}
	tw, th := u32(reduced ? ow : 0), u32(reduced ? oh : 0)
	switch {
	case rc != 0: code = wm_raster_decode(rc, raw_data(data), uint(len(data)), &l, tw, th, &sink, &wi)
	case avif:    code = wm_avif_decode(raw_data(data), uint(len(data)), &l, tw, th, &sink, &wi)
	case:         code = wm_webp_decode(raw_data(data), uint(len(data)), &l, tw, th, &sink, &wi)
	}
	if code != 0 && len(nf.frames) == 0 { return nil, info, nf.failed ? .Too_Much_Memory : error_of(code) }
	if len(nf.frames) == 0 { return nil, info, .Corrupt }
	img = new(Image)
	img.allocator = context.allocator
	img.info = info
	img.width, img.height, img.stride = nf.w, nf.h, nf.w * 4
	img.frames = nf.frames[:]
	img.reduced = nf.w < info.width || nf.h < info.height
	total := 0
	for f in img.frames { total += f.delay_ms }
	img.info.animated = len(img.frames) > 1
	img.duration_ms = img.info.animated ? total : 0
	img.bytes = len(img.frames) * nf.w * nf.h * 4
	ok = true
	return img, img.info, .None
}

////////////////////////////////
// SVG

// The parsed document of a blob, made by the first job that needs it and kept until the blob goes (several threads may
// race to make it: one wins, the others free theirs). Info comes back each time (it is cheap to keep).
@(private)
svg_doc_of :: proc(b: ^Blob, opts: Decode_Options) -> (doc: rawptr, info: Info, err: Error) {
	if d := sync.atomic_load(&b.svg_doc); d != nil {
		return d, b.svg_info, .None
	}
	if e := Error(sync.atomic_load(&b.svg_err)); e != .None { return nil, {}, e }
	l := wm_limits(opts)
	wi: Wm_Info
	d: rawptr
	code := wm_svg_parse(raw_data(b.bytes), uint(len(b.bytes)), &l, &wi, &d)
	if code != 0 || d == nil {
		e := code != 0 ? error_of(code) : Error.Internal
		sync.atomic_store(&b.svg_err, u8(e))
		return nil, {}, e
	}
	info = info_of(.Svg, wi)
	sync.mutex_lock(&b.svg_mu)
	defer sync.mutex_unlock(&b.svg_mu)
	if b.svg_doc != nil {
		wm_svg_free(d)
		return b.svg_doc, b.svg_info, .None
	}
	b.svg_info = info
	sync.atomic_store(&b.svg_doc, d)
	return d, info, .None
}

@(private)
svg_doc_free :: proc(b: ^Blob) {
	if b.svg_doc != nil { wm_svg_free(b.svg_doc); b.svg_doc = nil }
}

// An SVG document: its natural size (header_only), or its picture rendered at exactly (target_w, target_h) pixels (its
// default size when 0). `b` may be nil (tests): the document is parsed for this call only.
@(private)
svg_run :: proc(b: ^Blob, data: []byte, opts: Decode_Options, header_only: bool) -> (img: ^Image, info: Info, err: Error) {
	if !opts.limits.svg.enabled { return nil, Info{format = .Svg}, .Unsupported_Format }
	doc: rawptr
	own: ^Blob
	blob := b
	if blob == nil {
		own = new(Blob)
		own.bytes, own.refs, own.allocator = data, 1, context.allocator
		blob = own
	}
	defer if own != nil { svg_doc_free(own); free(own) }
	doc, info, err = svg_doc_of(blob, opts)
	if err != .None { return nil, info, err }
	if header_only { return nil, info, .None }
	w, h := opts.target_w, opts.target_h
	if w <= 0 || h <= 0 { w, h = info.width, info.height }
	// past the limits, the picture is drawn at the largest size they allow (the painter scales it up)
	w, h = max(w, 1), max(h, 1)
	for check_size(w, h, opts.limits) != .None && (w > 1 || h > 1) { w, h = max(w * 3 / 4, 1), max(h * 3 / 4, 1) }
	pixels, aerr := make([]u8, w * h * 4)
	if aerr != nil { return nil, info, .Too_Much_Memory }
	l := wm_limits(opts)
	if code := wm_svg_render(doc, &l, u32(w), u32(h), raw_data(pixels)); code != 0 {
		delete(pixels)
		return nil, info, error_of(code)
	}
	img = new(Image)
	img.allocator = context.allocator
	img.info = info
	img.width, img.height, img.stride = w, h, w * 4
	img.frames = make([]Frame, 1)
	img.frames[0] = Frame{pixels = pixels}
	img.bytes = len(pixels)
	return img, info, .None
}

////////////////////////////////
// Encoding (the canvas's toDataURL / toBlob / convertToBlob)

// Encodes a w x h image of RGBA8 as PNG (straight alpha) or JPEG (`quality` 0 to 1; transparent areas over black).
// `premultiplied`: the pixels are premultiplied (a canvas's): PNG gets them divided by alpha, JPEG as they are (a
// color premultiplied by its alpha is that color over black). The bytes are allocated with `allocator`. false: it
// could not be encoded (a size out of range, no memory).
encode_rgba :: proc(rgba: []u8, w, h: int, format: Encode_Format, quality: f32, premultiplied: bool, allocator := context.allocator) -> (out: []u8, ok: bool) {
	if w <= 0 || h <= 0 || w > 65535 * 4 || h > 65535 * 4 || len(rgba) < w * h * 4 { return }
	Out :: struct { ctx: runtime.Context, bytes: []u8 }
	o := Out{ctx = context}
	o.ctx.allocator = allocator
	sink := Wm_Byte_Sink{user = &o, alloc = proc "c" (user: rawptr, n: uint) -> [^]u8 {
		o := (^Out)(user)
		context = o.ctx
		b, err := make([]u8, int(n))
		if err != nil { return nil }
		o.bytes = b
		return raw_data(b)
	}}
	code := u32(format == .Png ? 1 : 2)
	if wm_raster_encode(code, raw_data(rgba), u32(w), u32(h), quality, u8(premultiplied), &sink) != 0 {
		delete(o.bytes, allocator)
		return nil, false
	}
	return o.bytes, o.bytes != nil
}

////////////////////////////////
// Colour of the formats WIC decodes

// Converts pixels tagged with a profile to sRGB, in place. False: left as they are (unusable profile).
color_icc_to_srgb :: proc(icc: []u8, pixels: []u8) -> bool {
	if len(icc) == 0 || len(pixels) < 4 { return false }
	return wm_color_icc_to_srgb(raw_data(icc), uint(len(icc)), raw_data(pixels), uint(len(pixels) / 4)) == 0
}

color_adobe_to_srgb :: proc(pixels: []u8) -> bool {
	if len(pixels) < 4 { return false }
	return wm_color_adobe_to_srgb(raw_data(pixels), uint(len(pixels) / 4)) == 0
}
