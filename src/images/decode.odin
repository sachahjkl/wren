package images

// PNG, JPEG, GIF, BMP, ICO and TIFF with the built-in decoders (native.odin): every system, and Windows unless
// images.decode.system_codecs hands them to WIC (decode_windows.odin). The checks before a pixel is allocated are those
// of the system path: the header's size against the limits, a file that does not look complete refused unless
// `allow_truncated`.
@(private)
builtin_run :: proc(data: []byte, info: Info, opts: Decode_Options, header_only: bool) -> (^Image, Info, Error) {
	if hw, hh, known := header_size(data, info.format); known {
		if e := check_size(hw, hh, opts.limits); e != .None { return nil, info, e }
	}
	if !opts.allow_truncated && !looks_complete(data, info.format) { return nil, info, .Corrupt }
	return native_raster(data, info, opts, header_only)
}
