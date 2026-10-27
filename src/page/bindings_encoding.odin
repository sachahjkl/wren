package page

// TextEncoder and TextDecoder (Encoding Standard; import module "encoding").
//
// Decoders are Lexbor's, kept alive between calls (src/shim/encoding_stream.c), so every WHATWG label works, in
// replacement or fatal mode, with BOM handling and `stream: true`: a multi-byte sequence cut between two chunks is
// completed by the next call. Output is UTF-8; a guest reads it with the usual "length needed" convention: decode
// copies what fits and returns the full length, TextDecoder_output copies the whole result of the last call again.
//
// TextEncoder always produces UTF-8. Guest strings are already UTF-8, but a guest may hand over invalid bytes: they are
// replaced by U+FFFD as for a lone surrogate in a JavaScript string.

import "core:strings"
import "core:unicode/utf8"

when ODIN_OS == .Windows {
	foreign import lexbor_enc {
		"../../build/lexbor/lexbor.lib",
		"system:msvcrt.lib",
		"system:ucrt.lib",
		"system:libvcruntime.lib",
		"system:legacy_stdio_definitions.lib",
	}
} else {
	foreign import lexbor_enc { "../../build/lexbor-" + ODIN_OS_STRING + "/liblexbor.a" }   // tools/build_lexbor.sh
}

Lexbor_Decoder :: distinct rawptr

@(default_calling_convention = "c")
foreign lexbor_enc {
	wb_decoder_create :: proc(label: [^]u8, label_len: uint, fatal: i32, ignore_bom: i32) -> Lexbor_Decoder ---
	wb_decoder_destroy :: proc(d: Lexbor_Decoder) ---
	wb_decoder_name :: proc(d: Lexbor_Decoder, out: [^]u8, cap: uint) -> uint ---
	wb_decoder_decode :: proc(d: Lexbor_Decoder, data: [^]u8, len: uint, flush: i32, out: ^[^]u8, out_len: ^uint) -> i32 ---
	@(link_name = "wb_free") wb_free_enc :: proc(p: rawptr) ---
}

Text_Decoder :: struct {
	dec:        Lexbor_Decoder,
	name:       string,          // owned, lower case
	fatal:      bool,
	ignore_bom: bool,
	output:     [dynamic]byte,   // result of the last decode, counted in p.held
}

text_decoder_vt := Object_VTable{
	name = "TextDecoder",
	destroy = proc(p: ^Page, data: rawptr) {
		d := (^Text_Decoder)(data)
		if !p.closed { p.held -= len(d.output) }
		wb_decoder_destroy(d.dec)
		delete(d.name)
		delete(d.output)
		free(d)
	},
}

// A stand-alone streaming decoder (host code and tests). `label` is any WHATWG label.
decoder_make :: proc(label: string, fatal := false, ignore_bom := false) -> (Lexbor_Decoder, bool) {
	l := strings.trim_space(label)
	empty := u8(0)
	ptr := raw_data(l)
	if len(l) == 0 { ptr = &empty }
	d := wb_decoder_create(ptr, uint(len(l)), fatal ? 1 : 0, ignore_bom ? 1 : 0)
	return d, d != nil
}

decoder_free :: proc(d: Lexbor_Decoder) { if d != nil { wb_decoder_destroy(d) } }

// Decodes one chunk; `stream` keeps an unfinished sequence for the next call. ok = false for a fatal-mode error.
decoder_decode :: proc(d: Lexbor_Decoder, data: []byte, stream: bool, allocator := context.allocator) -> (text: string, ok: bool) {
	out: [^]u8
	n: uint
	empty := u8(0)
	ptr := raw_data(data)
	if len(data) == 0 { ptr = &empty }
	rc := wb_decoder_decode(d, ptr, uint(len(data)), stream ? 0 : 1, &out, &n)
	if rc != 0 { return "", false }
	defer wb_free_enc(out)
	return strings.clone(string(out[:n]), allocator), true
}

decoder_name :: proc(d: Lexbor_Decoder, allocator := context.allocator) -> string {
	buf: [64]u8
	n := wb_decoder_name(d, raw_data(buf[:]), len(buf))
	return strings.clone(string(buf[:min(int(n), len(buf))]), allocator)
}

// UTF-8 with invalid sequences replaced by U+FFFD (what TextEncoder sees of a guest string).
utf8_scrub :: proc(s: string, allocator := context.allocator) -> string {
	if utf8.valid_string(s) { return strings.clone(s, allocator) }
	d, _ := decoder_make("utf-8", false, true)
	defer decoder_free(d)
	text, _ := decoder_decode(d, transmute([]byte)s, false, allocator)
	return text
}

////////////////////////////////
// Imports

// new TextEncoder().encode(s): a buffer with the UTF-8 bytes (`text` is scrubbed by the binding: USVString).
TextEncoder_encode :: proc(c: ^Call, text: string) -> (u64, Api_Error) {
	b := buffer_create(c.page, transmute([]byte)text, c.owner)
	if b == 0 { return 0, fail(c, .Quota, "QuotaExceededError: page memory limit") }
	return b, .None
}

// encodeInto(source, destination): whole characters only; invalid bytes of the source count as U+FFFD.
TextEncoder_encodeInto :: proc(c: ^Call, source: []u8, destination: []u8) -> Api_EncodeIntoResult {
	src := string(source)
	read, written := 0, 0
	for read < len(src) {
		r, w := utf8.decode_rune_in_string(src[read:])
		enc: [4]u8
		bytes: []u8
		if r == utf8.RUNE_ERROR && w <= 1 {
			enc = {0xEF, 0xBF, 0xBD, 0}
			bytes = enc[:3]
			w = 1
		} else {
			bytes = transmute([]u8)src[read:][:w]
		}
		if written + len(bytes) > len(destination) { break }
		copy(destination[written:], bytes)
		written += len(bytes)
		read += w
	}
	return Api_EncodeIntoResult{read = u64(read), written = u64(written)}
}

// new TextDecoder(label, {fatal, ignoreBOM}): RangeError for an unknown label.
TextDecoder_create :: proc(c: ^Call, label: string, options: Api_TextDecoderOptions) -> (u64, Api_Error) {
	l := label
	if l == "" { l = "utf-8" }
	fatal, ignore_bom := .Fatal in options, .Ignore_BOM in options
	dec, ok := decoder_make(l, fatal, ignore_bom)
	if !ok { return 0, fail(c, .Range, "RangeError: unknown encoding label") }
	d := new(Text_Decoder)
	d.dec, d.fatal, d.ignore_bom = dec, fatal, ignore_bom
	d.name = decoder_name(dec)
	return object_create(c.page, &text_decoder_vt, d, c.owner), .None
}

@(private)
decoder_get :: proc(p: ^Page, h: u64) -> ^Text_Decoder { return (^Text_Decoder)(object_data(p, h, &text_decoder_vt)) }

TextDecoder_encoding :: proc(c: ^Call, decoder: Api_TextDecoder) -> string { return decoder.data.name }

TextDecoder_flags :: proc(c: ^Call, decoder: Api_TextDecoder) -> Api_TextDecoderOptions {
	o: Api_TextDecoderOptions
	if decoder.data.fatal { o += {.Fatal} }
	if decoder.data.ignore_bom { o += {.Ignore_BOM} }
	return o
}

@(private)
decode_into :: proc(c: ^Call, d: ^Text_Decoder, input: []byte, stream: bool) -> (string, Api_Error) {
	p := c.page
	p.held -= len(d.output)
	clear(&d.output)
	out: [^]u8
	n: uint
	empty := u8(0)
	ptr := raw_data(input)
	if len(input) == 0 { ptr = &empty }
	rc := wb_decoder_decode(d.dec, ptr, uint(len(input)), stream ? 0 : 1, &out, &n)
	switch rc {
	case 0:
	case 1: return "", fail(c, .Type, "TypeError: the input is not valid in this encoding (fatal mode)")
	case: return "", .Encoding
	}
	defer wb_free_enc(out)
	if int(n) > int(max(i32)) || p.held + int(n) > p.settings.max_fetch_bytes { return "", fail(c, .Quota, "QuotaExceededError: page memory limit") }
	append(&d.output, ..out[:n])
	p.held += int(n)
	return string(d.output[:]), .None
}

// decode(bytes, {stream}): the UTF-8 result (TextDecoder_output gives all of it again).
TextDecoder_decode :: proc(c: ^Call, decoder: Api_TextDecoder, input: []u8, stream: bool) -> (string, Api_Error) {
	return decode_into(c, decoder.data, input, stream)
}

// Same, from a buffer object (a fetch body, a stream chunk).
TextDecoder_decodeBuffer :: proc(c: ^Call, decoder: Api_TextDecoder, input: Api_Buffer, stream: bool) -> (string, Api_Error) {
	copy_of := make([]byte, len(input.data.bytes), context.temp_allocator)   // the decoder must not alias a buffer it may outlive
	copy(copy_of, input.data.bytes[:])
	return decode_into(c, decoder.data, copy_of, stream)
}

TextDecoder_output :: proc(c: ^Call, decoder: Api_TextDecoder) -> string { return string(decoder.data.output[:]) }