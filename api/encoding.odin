// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=encoding order=11 exposed=(Window,Worker)
/// TextEncoder and TextDecoder (Encoding Standard). Decoders keep their state between calls, so every WHATWG label
/// works, in replacement or fatal mode, with BOM handling and `stream`: a sequence cut between two chunks is completed by
/// the next call. Output is UTF-8.
package api_encoding

//@wb handle parent=Object host=Text_Decoder lookup=lookup_TextDecoder
TextDecoder :: distinct Handle

/// TextDecoderOptions
//@wb flags base=u32
TextDecoderOptions :: enum u32 {
	Fatal,
	Ignore_BOM,
}

/// What TextEncoder.encodeInto did, in bytes.
EncodeIntoResult :: struct {
	/// Bytes of the source consumed (whole characters only).
	read: u64,
	/// Bytes written to the destination.
	written: u64,
}

/// new TextEncoder().encode(text): a buffer of UTF-8. Quota past the page's memory limit.
//@wb fn raises
TextEncoder_encode :: proc(text: usvstring) -> Buffer

/// encoder.encodeInto(source, destination): invalid UTF-8 in the source counts as U+FFFD (3 bytes).
//@wb fn out=destination
TextEncoder_encodeInto :: proc(source: bytes, destination: bytes) -> EncodeIntoResult

/// new TextDecoder(label, options): Range for an unknown label ("" = utf-8).
//@wb fn raises
TextDecoder_create :: proc(label: string = "", options: TextDecoderOptions = none) -> TextDecoder

/// decoder.encoding (lower case)
//@wb fn
TextDecoder_encoding :: proc(decoder: TextDecoder) -> string

/// decoder.fatal and decoder.ignoreBOM
//@wb fn
TextDecoder_flags :: proc(decoder: TextDecoder) -> TextDecoderOptions

/// decoder.decode(input, {stream}): Type for invalid input in fatal mode. TextDecoder_output reads the whole result
/// again when the buffer was too small.
//@wb fn raises effects
TextDecoder_decode :: proc(decoder: TextDecoder, input: bytes, stream: bool = false) -> string

/// The same from a buffer (a fetch body, a stream chunk).
//@wb fn raises effects
TextDecoder_decodeBuffer :: proc(decoder: TextDecoder, input: Buffer, stream: bool = false) -> string

/// The result of the last decode.
//@wb fn
TextDecoder_output :: proc(decoder: TextDecoder) -> string

