#+build !windows
package images

// Systems without WIC: every format the built-in decoders know (native.odin); HEIF needs a system codec (Codec_Missing,
// what a Windows without the Store's extension answers). The decoding threads' context holds nothing.

Codec_Context :: struct {
	ok: bool,
}

@(private)
probe_codecs :: proc() { codecs.probed = true }

codec_init :: proc(c: ^Codec_Context) -> bool {
	c.ok = true
	return true
}

codec_destroy :: proc(c: ^Codec_Context) { c^ = {} }

// Headers only: format, natural size, frames, orientation. Allocates no pixels.
probe_with :: proc(c: ^Codec_Context, data: []byte, opts: Decode_Options) -> (Info, Error) {
	_, info, err := run(c, nil, data, opts, true)
	return info, err
}

// The pixels. The image belongs to the caller (image_destroy), allocated with context.allocator.
decode_with :: proc(c: ^Codec_Context, data: []byte, opts: Decode_Options) -> (^Image, Info, Error) {
	return run(c, nil, data, opts, false)
}

// Probe or decode of a shared blob (the decoding threads): an SVG document is parsed once per blob.
run_blob :: proc(c: ^Codec_Context, b: ^Blob, opts: Decode_Options, header_only: bool) -> (^Image, Info, Error) {
	return run(c, b, b.bytes, opts, header_only)
}

probe_now :: proc(data: []byte, opts: Decode_Options) -> (Info, Error) {
	c: Codec_Context
	codec_init(&c)
	return probe_with(&c, data, opts)
}

decode_now :: proc(data: []byte, opts: Decode_Options) -> (^Image, Info, Error) {
	c: Codec_Context
	codec_init(&c)
	return decode_with(&c, data, opts)
}

@(private)
run :: proc(c: ^Codec_Context, b: ^Blob, data: []byte, opts: Decode_Options, header_only: bool) -> (img: ^Image, info: Info, err: Error) {
	l := opts.limits
	if len(data) == 0 { return nil, {}, .Empty }
	if len(data) > l.max_encoded_bytes || len(data) > int(max(u32)) { return nil, {}, .Too_Many_Bytes }
	info.format = sniff(data, opts.mime, opts.nosniff)
	switch info.format {
	case .Unknown: return nil, info, .Unknown_Format
	case .Svg:     return svg_run(b, data, opts, header_only)
	case .Heif:    return nil, info, .Codec_Missing
	case .Webp, .Avif:
		if hw, hh, known := header_size(data, info.format); known {
			if e := check_size(hw, hh, l); e != .None { return nil, info, e }
		}
		return native_raster(data, info, opts, header_only)
	case .Png, .Jpeg, .Gif, .Bmp, .Ico, .Tiff:
		return builtin_run(data, info, opts, header_only)
	}
	return nil, info, .Unknown_Format
}
