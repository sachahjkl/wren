package html

import "core:strings"

foreign import lexbor_enc {
	"../../build/lexbor/lexbor.lib",
	"system:msvcrt.lib",
	"system:ucrt.lib",
	"system:libvcruntime.lib",
	"system:legacy_stdio_definitions.lib",
}

@(default_calling_convention = "c")
foreign lexbor_enc {
	wb_decode_to_utf8 :: proc(data: [^]u8, len: uint, label: [^]u8, label_len: uint, out: ^[^]u8, out_len: ^uint) -> i32 ---
	wb_encoding_canonical_name :: proc(label: [^]u8, label_len: uint, out: [^]u8, cap: uint) -> uint ---
	wb_html_prescan_charset :: proc(data: [^]u8, len: uint, out: [^]u8, cap: uint) -> uint ---
	wb_free :: proc(p: rawptr) ---
}

Decoded :: struct {
	text:     []byte,   // UTF-8, owned
	encoding: string,   // canonical name that was used
	source:   Encoding_Source,
}

Encoding_Source :: enum u8 { Bom, Header, Meta, Default }

// The WHATWG name for a label ("latin1" -> "windows-1252"), or "" when unknown.
canonical_encoding :: proc(label: string) -> string {
	l := strings.trim_space(label)
	if l == "" { return "" }
	buf: [64]u8
	n := wb_encoding_canonical_name(raw_data(l), uint(len(l)), raw_data(buf[:]), len(buf))
	if n == 0 { return "" }
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

// The "encoding sniffing algorithm": byte-order mark, then the transport's charset (`header_charset`, from
// Content-Type), then the <meta> prescan, then the default. The result is always UTF-8; undecodable bytes become
// U+FFFD, as the specification requires.
// `default_encoding` is the last resort (preference `html.default_encoding`). `prescan_meta` is off for other text formats (CSS).
decode_document :: proc(data: []byte, header_charset: string, default_encoding: string, allocator := context.allocator, prescan_meta := true) -> (d: Decoded, ok: bool) {
	input := data
	switch {
	case len(data) >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF:
		d.encoding, d.source, input = "UTF-8", .Bom, data[3:]
	case len(data) >= 2 && data[0] == 0xFF && data[1] == 0xFE:
		d.encoding, d.source, input = "UTF-16LE", .Bom, data[2:]
	case len(data) >= 2 && data[0] == 0xFE && data[1] == 0xFF:
		d.encoding, d.source, input = "UTF-16BE", .Bom, data[2:]
	}
	if d.encoding == "" {
		if c := canonical_encoding(header_charset); c != "" {
			d.encoding, d.source = c, .Header
		} else {
			buf: [64]u8
			n: uint
			if prescan_meta { n = wb_html_prescan_charset(raw_data(data), uint(len(data)), raw_data(buf[:]), len(buf)) }
			if n > 0 { d.encoding, d.source = strings.clone(string(buf[:n]), context.temp_allocator), .Meta } else { d.encoding, d.source = default_encoding, .Default }
			// a <meta> found by the prescan is in ASCII bytes: the document cannot be UTF-16, whatever it says
			// (HTML §13.2.3.2 "get an encoding"); x-user-defined means windows-1252 there
			if d.source == .Meta {
				if strings.equal_fold(d.encoding, "UTF-16LE") || strings.equal_fold(d.encoding, "UTF-16BE") { d.encoding = "UTF-8" }
				if strings.equal_fold(d.encoding, "x-user-defined") { d.encoding = "windows-1252" }
			}
		}
	}

	if d.source == .Default && canonical_encoding(d.encoding) == "" { d.encoding = "windows-1252" }   // a broken preference must not break loading
	out: [^]u8
	out_len: uint
	empty: u8
	in_ptr := raw_data(input)
	if len(input) == 0 { in_ptr = &empty }
	label := d.encoding
	if wb_decode_to_utf8(in_ptr, uint(len(input)), raw_data(label), uint(len(label)), &out, &out_len) != 0 { return {}, false }
	defer wb_free(out)
	d.text = make([]byte, out_len, allocator)
	copy(d.text, out[:out_len])
	d.encoding = strings.clone(d.encoding, context.temp_allocator)
	return d, true
}
