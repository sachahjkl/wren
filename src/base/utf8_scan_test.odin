package base

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

// `insert` at byte `at` of `n` ASCII letters (the letters cycle, so that blocks differ).
@(private = "file")
spliced :: proc(n, at: int, insert: string) -> string {
	b := strings.builder_make(0, n + len(insert), context.temp_allocator)
	for i in 0 ..< n {
		if i == at { strings.write_string(&b, insert) }
		strings.write_byte(&b, u8('a' + i % 26))
	}
	if at >= n { strings.write_string(&b, insert) }
	return strings.to_string(b)
}

@(private = "file")
VALID_SEQUENCES :: [?]string{"é", " ", "€", "ࠀ", "�", "😀", "\U0010FFFF", "\U00010000"}

@(private = "file")
INVALID_SEQUENCES :: [?]string{
	"\x80", "\xbf", "\xc0\x80", "\xc1\xbf", "\xc2", "\xc2\x41", "\xe0\x80\x80", "\xe0\x9f\xbf", "\xed\xa0\x80",
	"\xed\xbf\xbf", "\xe2\x82", "\xf0\x80\x80\x80", "\xf0\x8f\xbf\xbf", "\xf4\x90\x80\x80", "\xf5\x80\x80\x80",
	"\xf8", "\xff", "\xf0\x9f\x98", "\xe2\x28\xa1",
}

@(test)
ascii_prefix_matches_its_reference :: proc(t: ^testing.T) {
	testing.expect_value(t, ascii_prefix(""), 0)
	testing.expect(t, is_ascii(""), "the empty string is ASCII")
	for n in 0 ..= 64 {
		s := spliced(n, n, "")
		testing.expectf(t, ascii_prefix(s) == n && is_ascii(s), "%d ASCII bytes", n)
		for at in 0 ..= n {
			for special in ([?]string{"\x80", "\xff", "é"}) {
				m := spliced(n, at, special)
				testing.expectf(t, ascii_prefix(m) == ascii_prefix_scalar(m) && ascii_prefix(m) == at, "%d bytes, %q at %d", n, special, at)
			}
		}
	}
	free_all(context.temp_allocator)
}

@(test)
utf8_valid_matches_the_decoder :: proc(t: ^testing.T) {
	testing.expect(t, utf8_valid(""), "the empty string")
	for n in 0 ..= 64 {
		for at in 0 ..= n {
			for seq in VALID_SEQUENCES {
				s := spliced(n, at, seq)
				testing.expectf(t, utf8_valid(s) && utf8.valid_string(s), "%d bytes, %q at %d", n, seq, at)
				// two in a row, and one at the end as well: the scan returns to its blocks between them
				s2 := spliced(n, at, strings.concatenate({seq, seq}, context.temp_allocator))
				s2 = strings.concatenate({s2, seq}, context.temp_allocator)
				testing.expectf(t, utf8_valid(s2), "%d bytes, %q twice at %d and at the end", n, seq, at)
			}
			for seq in INVALID_SEQUENCES {
				s := spliced(n, at, seq)
				testing.expectf(t, utf8_valid(s) == utf8.valid_string(s), "%d bytes, %q at %d: %v, the decoder %v", n, seq, at, utf8_valid(s), utf8.valid_string(s))
				testing.expectf(t, !utf8_valid(s), "%d bytes, %q at %d is not UTF-8", n, seq, at)
				// after valid non-ASCII text
				s2 := spliced(n, at, strings.concatenate({"é€", seq}, context.temp_allocator))
				testing.expectf(t, !utf8_valid(s2), "%d bytes, %q after é€ at %d", n, seq, at)
			}
		}
		free_all(context.temp_allocator)
	}
}

@(test)
utf16_scans_match_their_references :: proc(t: ^testing.T) {
	samples := [?]string{"", "é", "€", "😀", "😀é€", "\U0010FFFF\U00010000"}
	for n in 0 ..= 64 {
		for at in 0 ..= n {
			for seq in samples {
				s := spliced(n, at, seq)
				length := utf16_length(s)
				testing.expectf(t, length == utf16_length_scalar(s), "length of %d bytes with %q at %d: %d, the reference %d", n, seq, at, length, utf16_length_scalar(s))
				for off in 0 ..= length + 2 {
					index, units := utf8_index_of_utf16(s, off)
					want := utf8_index_scalar(s, off)
					if index != want {
						testing.expectf(t, false, "index of %d in %q: %d, the reference %d", off, s, index, want)
						continue
					}
					want_units := utf16_length_scalar(s[:want])
					testing.expectf(t, units == want_units, "units before %d in %q: %d, want %d", off, s, units, want_units)
					if n > 40 { continue }   // (the ranges: the lengths around one and two blocks are enough)
					for count in ([?]int{0, 1, 3, 17, 1 << 31}) {
						a, b, ok := utf16_range(s, off, count)
						if off > length {
							testing.expectf(t, !ok, "range %d+%d of %q is past the end", off, count, s)
							continue
						}
						wa, wb := utf8_index_scalar(s, off), utf8_index_scalar(s, min(off + count, length))
						testing.expectf(t, ok && a == wa && b == wb, "range %d+%d of %q: %d..%d, want %d..%d", off, count, s, a, b, wa, wb)
					}
				}
			}
		}
		free_all(context.temp_allocator)
	}
}

@(test)
write_escaped_matches_its_reference :: proc(t: ^testing.T) {
	specials := [?]string{"&", "<", ">", "\"", "'", " ", "\xc2", "\xc2\xc2\xa0", "é", "<&>"}
	alsos := [?]Escapes{{}, {.Quote}, {.Apos}, {.Nbsp}, {.Quote, .Apos, .Nbsp}}
	for n in 0 ..= 64 {
		for at in 0 ..= n {
			for sp in specials {
				s := spliced(n, at, sp)
				for also in alsos {
					fast := strings.builder_make(context.temp_allocator)
					slow := strings.builder_make(context.temp_allocator)
					write_escaped(&fast, s, also)
					write_escaped_scalar(&slow, s, also)
					testing.expectf(t, strings.to_string(fast) == strings.to_string(slow), "%q with %v: %q, the reference %q", s, also, strings.to_string(fast), strings.to_string(slow))
				}
			}
		}
		free_all(context.temp_allocator)
	}
	// every special at once, the no-break space across the boundary of every block
	for at in 0 ..= 40 {
		s := fmt.tprintf("%s &\"'<>%s", strings.repeat("x", at, context.temp_allocator), strings.repeat("y", 40, context.temp_allocator))
		fast := strings.builder_make(context.temp_allocator)
		slow := strings.builder_make(context.temp_allocator)
		write_escaped(&fast, s, {.Quote, .Apos, .Nbsp})
		write_escaped_scalar(&slow, s, {.Quote, .Apos, .Nbsp})
		testing.expect_value(t, strings.to_string(fast), strings.to_string(slow))
	}
	free_all(context.temp_allocator)
}
