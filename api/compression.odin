// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=compression order=5 exposed=(Window,Worker)
/// CompressionStream and DecompressionStream (Compression Standard; src/page/compression.odin, the streams themselves:
/// native/js/runtime/web_transform.c): a DEFLATE stream (the toolkit's flate package: gzip, zlib "deflate" or raw) fed chunk by chunk. One call's
/// output is bounded by page.max_fetch_bytes (Quota past it: a decompression bomb errors the stream).
package api_compression

//@wb handle parent=Object host=Zip_Stream lookup=lookup_Compressor
Compressor :: distinct Handle

CompressionFormat :: enum i32 {
	Gzip,
	Deflate,
	Deflate_Raw,
}

/// A compressor (decompress false) or a decompressor of `format`.
//@wb fn raises
Compression_create :: proc(format: CompressionFormat, decompress: bool) -> Compressor

/// Feeds `input`: the output it made (Compression_output reads it again when the buffer was too small). Type for
/// data that is not of the format, or that follows the end of the compressed data; Quota past the bound.
//@wb fn raises effects
Compression_push :: proc(compressor: Compressor, input: bytes) -> bytes

/// The end of the input: what is left of the output. Type when the compressed data ended before its end.
//@wb fn raises effects
Compression_finish :: proc(compressor: Compressor) -> bytes

/// The output of the last push or finish.
//@wb fn
Compression_output :: proc(compressor: Compressor) -> bytes

