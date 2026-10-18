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
import "wb:dom"
import "wb:wasm"

foreign import lexbor_enc {
	"../../build/lexbor/lexbor.lib",
	"system:msvcrt.lib",
	"system:ucrt.lib",
	"system:vcruntime.lib",
	"system:legacy_stdio_definitions.lib",
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

// new TextEncoder().encode(s): a buffer with the UTF-8 bytes.
n_TextEncoder_encode :: proc "c" (env: wasm.Exec_Env, s: [^]u8, n: i32) -> u64 {
	context = ctx()
	t := utf8_scrub(str(s, n), context.temp_allocator)
	return buffer_create(page_of(env), transmute([]byte)t, inst_of(env).index)
}

// encodeInto(s, dst): whole characters only. Returns read << 32 | written (read in bytes of the source).
n_TextEncoder_encodeInto :: proc "c" (env: wasm.Exec_Env, s: [^]u8, n: i32, dst: [^]u8, cap: i32) -> i64 {
	context = ctx()
	src := str(s, n)
	room := int(max(cap, 0))
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
		if written + len(bytes) > room { break }
		copy(dst[written:][:len(bytes)], bytes)
		written += len(bytes)
		read += w
	}
	return i64(read) << 32 | i64(written)
}

// new TextDecoder(label, {fatal, ignoreBOM}): flags bit 0 fatal, bit 1 ignoreBOM. 0 = RangeError (unknown label).
n_TextDecoder_create :: proc "c" (env: wasm.Exec_Env, label: [^]u8, ll: i32, flags: i32) -> u64 {
	context = ctx()
	l := str(label, ll)
	if l == "" { l = "utf-8" }
	dec, ok := decoder_make(l, flags & 1 != 0, flags & 2 != 0)
	if !ok { return 0 }
	d := new(Text_Decoder)
	d.dec, d.fatal, d.ignore_bom = dec, flags & 1 != 0, flags & 2 != 0
	d.name = decoder_name(dec)
	return object_create(page_of(env), &text_decoder_vt, d, inst_of(env).index)
}

@(private)
decoder_get :: proc(p: ^Page, h: u64) -> ^Text_Decoder { return (^Text_Decoder)(object_data(p, h, &text_decoder_vt)) }

n_TextDecoder_encoding :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	d := decoder_get(page_of(env), h)
	if d == nil { return i32(dom.Error.Invalid_Handle) }
	return out_string(d.name, buf, cap)
}

// bit 0 fatal, bit 1 ignoreBOM
n_TextDecoder_flags :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	d := decoder_get(page_of(env), h)
	if d == nil { return i32(dom.Error.Invalid_Handle) }
	return (d.fatal ? 1 : 0) | (d.ignore_bom ? 2 : 0)
}

@(private)
decode_into :: proc(p: ^Page, d: ^Text_Decoder, input: []byte, stream: bool, dst: [^]u8, cap: i32) -> i32 {
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
	case 1: return WEB_ERR_TYPE
	case: return WEB_ERR_ENCODING
	}
	defer wb_free_enc(out)
	if int(n) > int(max(i32)) || p.held + int(n) > p.settings.max_fetch_bytes { return WEB_ERR_QUOTA }
	append(&d.output, ..out[:n])
	p.held += int(n)
	return out_string(string(d.output[:]), dst, cap)
}

// decode(bytes, {stream}): copies the UTF-8 result into dst, returns its full length (TextDecoder_output gets all of
// it); WEB_ERR_TYPE for a fatal-mode error.
n_TextDecoder_decode :: proc "c" (env: wasm.Exec_Env, h: u64, src: [^]u8, n: i32, stream: i32, dst: [^]u8, cap: i32) -> i32 {
	context = ctx()
	p := page_of(env)
	d := decoder_get(p, h)
	if d == nil { return i32(dom.Error.Invalid_Handle) }
	return decode_into(p, d, src[:max(n, 0)], stream != 0, dst, cap)
}

// Same, from a buffer object (a fetch body, a stream chunk).
n_TextDecoder_decodeBuffer :: proc "c" (env: wasm.Exec_Env, h: u64, buffer: u64, stream: i32, dst: [^]u8, cap: i32) -> i32 {
	context = ctx()
	p := page_of(env)
	d := decoder_get(p, h)
	if d == nil { return i32(dom.Error.Invalid_Handle) }
	b := buffer_get(p, buffer)
	if b == nil { return i32(dom.Error.Invalid_Handle) }
	input := make([]byte, len(b.bytes), context.temp_allocator)   // the decoder must not alias a buffer it may outlive
	copy(input, b.bytes[:])
	return decode_into(p, d, input, stream != 0, dst, cap)
}

n_TextDecoder_output :: proc "c" (env: wasm.Exec_Env, h: u64, dst: [^]u8, cap: i32) -> i32 {
	context = ctx()
	d := decoder_get(page_of(env), h)
	if d == nil { return i32(dom.Error.Invalid_Handle) }
	return out_string(string(d.output[:]), dst, cap)
}

encoding_symbols := [?]wasm.Native_Symbol{
	{"TextEncoder_encode", rawptr(n_TextEncoder_encode), "(*~)I", nil},
	{"TextEncoder_encodeInto", rawptr(n_TextEncoder_encodeInto), "(*~*~)I", nil},
	{"TextDecoder_create", rawptr(n_TextDecoder_create), "(*~i)I", nil},
	{"TextDecoder_encoding", rawptr(n_TextDecoder_encoding), "(I*~)i", nil},
	{"TextDecoder_flags", rawptr(n_TextDecoder_flags), "(I)i", nil},
	{"TextDecoder_decode", rawptr(n_TextDecoder_decode), "(I*~i*~)i", nil},
	{"TextDecoder_decodeBuffer", rawptr(n_TextDecoder_decodeBuffer), "(IIi*~)i", nil},
	{"TextDecoder_output", rawptr(n_TextDecoder_output), "(I*~)i", nil},
}
