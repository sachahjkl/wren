package url

// Percent-encoding and decoding of bytes, for the code that builds or reads URLs, query strings and the profile's
// escaped fields by hand. ASCII alphanumerics always stay as they are; `keep` lists the other bytes that do.

import "core:strings"
import "wb:base"

UNRESERVED :: "-._~"   // RFC 3986's unreserved punctuation
FORM_KEEP :: "*-._"    // what application/x-www-form-urlencoded leaves as it is (URL Standard)

percent_encode :: proc(sb: ^strings.Builder, s: string, keep: string, space_plus := false) {
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || strings.index_byte(keep, c) >= 0:
			strings.write_byte(sb, c)
		case c == ' ' && space_plus:
			strings.write_byte(sb, '+')
		case:
			strings.write_byte(sb, '%')
			strings.write_byte(sb, HEX[c >> 4])
			strings.write_byte(sb, HEX[c & 15])
		}
	}
}

percent_encoded :: proc(s: string, keep: string, space_plus := false, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	percent_encode(&sb, s, keep, space_plus)
	return strings.to_string(sb)
}

// Every %XX of two hex digits as its byte, '+' as a space when asked; anything else as it is (no UTF-8 check).
percent_decode :: proc(s: string, plus_as_space := false, allocator := context.temp_allocator) -> string {
	out := make([dynamic]u8, 0, len(s), allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case c == '+' && plus_as_space:
			append(&out, ' ')
		case c == '%' && i + 2 < len(s) && base.hex_value(s[i + 1]) >= 0 && base.hex_value(s[i + 2]) >= 0:
			append(&out, u8(base.hex_value(s[i + 1]) << 4 | base.hex_value(s[i + 2])))
			i += 2
		case:
			append(&out, c)
		}
	}
	return string(out[:])
}
