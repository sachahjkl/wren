package web

// TextEncoder / TextDecoder (import module "encoding"). Decoders accept every WHATWG label and keep their state between
// calls with stream = true.

foreign import encoding_mod "encoding"

Decoder_Flag :: enum u32 { Fatal = 0, Ignore_BOM = 1 }
Decoder_Flags :: bit_set[Decoder_Flag; u32]

@(default_calling_convention = "contextless")
foreign encoding_mod {
	@(link_name = "TextEncoder_encode") raw_textEncode :: proc(s: [^]u8, n: i32) -> Handle ---
	@(link_name = "TextEncoder_encodeInto") raw_textEncodeInto :: proc(s: [^]u8, n: i32, dst: [^]u8, cap: i32) -> i64 ---
	@(link_name = "TextDecoder_create") raw_textDecoderCreate :: proc(label: [^]u8, ll: i32, flags: Decoder_Flags) -> Handle ---
	@(link_name = "TextDecoder_encoding") raw_textDecoderEncoding :: proc(d: Handle, buf: [^]u8, cap: i32) -> i32 ---
	TextDecoder_flags :: proc(d: Handle) -> i32 ---
	@(link_name = "TextDecoder_decode") raw_textDecode :: proc(d: Handle, src: [^]u8, n: i32, stream: i32, dst: [^]u8, cap: i32) -> i32 ---
	@(link_name = "TextDecoder_decodeBuffer") raw_textDecodeBuffer :: proc(d: Handle, buffer: Handle, stream: i32, dst: [^]u8, cap: i32) -> i32 ---
	@(link_name = "TextDecoder_output") raw_textDecoderOutput :: proc(d: Handle, dst: [^]u8, cap: i32) -> i32 ---
}

// TextEncoder.encode: a buffer with the UTF-8 bytes.
text_encode :: proc "contextless" (s: string) -> Handle { return raw_textEncode(raw_data(s), i32(len(s))) }

// TextEncoder.encodeInto: whole characters only; read is in bytes of `s`.
text_encode_into :: proc "contextless" (s: string, dst: []u8) -> (read, written: int) {
	r := raw_textEncodeInto(raw_data(s), i32(len(s)), raw_data(dst), i32(len(dst)))
	return int(r >> 32), int(r & 0xFFFF_FFFF)
}

// new TextDecoder(label, options); 0 for an unknown label (RangeError).
text_decoder :: proc "contextless" (label := "utf-8", flags := Decoder_Flags{}) -> Handle {
	return raw_textDecoderCreate(raw_data(label), i32(len(label)), flags)
}

text_decoder_encoding :: proc "contextless" (d: Handle, buf: []u8) -> string {
	n := raw_textDecoderEncoding(d, raw_data(buf), i32(len(buf)))
	return string(buf[:min(int(max(n, 0)), len(buf))])
}

// decode(bytes, {stream}): the text that fits in `dst`; `needed` is the full length (read it all with
// raw_textDecoderOutput when larger), or a negative Web_Error (Type = fatal decoding error).
text_decode :: proc "contextless" (d: Handle, src: []u8, dst: []u8, stream := false) -> (text: string, needed: int) {
	n := raw_textDecode(d, raw_data(src), i32(len(src)), stream ? 1 : 0, raw_data(dst), i32(len(dst)))
	if n < 0 { return "", int(n) }
	return string(dst[:min(int(n), len(dst))]), int(n)
}

text_decode_buffer :: proc "contextless" (d: Handle, buffer: Handle, dst: []u8, stream := false) -> (text: string, needed: int) {
	n := raw_textDecodeBuffer(d, buffer, stream ? 1 : 0, raw_data(dst), i32(len(dst)))
	if n < 0 { return "", int(n) }
	return string(dst[:min(int(n), len(dst))]), int(n)
}
