package page

import "core:fmt"
import "wb:flate"

// CompressionStream / DecompressionStream (Compression Standard; api/compression.widl, the streams themselves:
// native/js/runtime/web_transform.c) on wb:flate: gzip, zlib ("deflate") or raw deflate, fed chunk by chunk; what a chunk
// makes is returned at once (kept for Compression_output when the caller's buffer was too small). The output of one
// call is bounded by page.max_fetch_bytes: a small input that inflates past it errors the stream (Quota).

Zip_Stream :: struct {
	decompress: bool,
	inflater:   flate.Inflater,
	deflater:   flate.Deflater,
	out:        [dynamic]u8,    // the output of the last call
}

@(private)
zip_vt := Object_VTable{name = "Compressor", destroy = proc(p: ^Page, data: rawptr) {
	zs := (^Zip_Stream)(data)
	if zs.decompress { flate.inflater_destroy(&zs.inflater) } else { flate.deflater_destroy(&zs.deflater) }
	delete(zs.out)
	free(zs)
}}

lookup_Compressor :: proc(c: ^Call, h: u64) -> ^Zip_Stream { return (^Zip_Stream)(object_data(c.page, h, &zip_vt)) }

Compression_create :: proc(c: ^Call, format: Api_CompressionFormat, decompress: bool) -> (u64, Api_Error) {
	zs := new(Zip_Stream)
	zs.decompress = decompress
	f: flate.Format
	switch format {
	case .Gzip: f = .Gzip
	case .Deflate: f = .Zlib
	case .Deflate_Raw: f = .Raw
	}
	if decompress {
		flate.inflater_init(&zs.inflater, f, limit = max(c.page.settings.max_fetch_bytes, 1 << 20))
	} else {
		flate.deflater_init(&zs.deflater, f)
	}
	zs.out = make([dynamic]u8)
	return object_create(c.page, &zip_vt, zs, c.owner), .None
}

@(private)
zip_error :: proc(c: ^Call, err: flate.Error) -> Api_Error {
	switch err {
	case .None: return .None
	case .Bad_Data: return fail(c, .Type, "The compressed data is not valid.")
	case .Junk_After_End: return fail(c, .Type, "Junk found after the end of the compressed data.")
	case .Truncated: return fail(c, .Type, "The compressed data ended before its end.")
	case .Too_Large: return fail(c, .Quota, fmt.tprintf("the output of one chunk passes page.max_fetch_bytes (%d bytes)", c.page.settings.max_fetch_bytes))
	}
	return .None
}

Compression_push :: proc(c: ^Call, compressor: Api_Compressor, input: []u8) -> ([]u8, Api_Error) {
	zs := compressor.data
	clear(&zs.out)
	if zs.decompress {
		if err := zip_error(c, flate.inflate_push(&zs.inflater, input, &zs.out)); err != .None { return nil, err }
	} else {
		flate.deflate_push(&zs.deflater, input, &zs.out)
	}
	return zs.out[:], .None
}

Compression_finish :: proc(c: ^Call, compressor: Api_Compressor) -> ([]u8, Api_Error) {
	zs := compressor.data
	clear(&zs.out)
	if zs.decompress {
		if err := zip_error(c, flate.inflate_finish(&zs.inflater)); err != .None { return nil, err }
	} else {
		flate.deflate_finish(&zs.deflater, &zs.out)
	}
	return zs.out[:], .None
}

Compression_output :: proc(c: ^Call, compressor: Api_Compressor) -> []u8 { return compressor.data.out[:] }
