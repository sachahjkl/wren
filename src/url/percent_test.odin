package url

import "core:strings"
import "core:testing"

// The run-copying percent_encode and percent_decode against their byte-by-byte references: every special byte at every
// position of strings of 0 to 64 bytes.
@(test)
percent_coding_matches_its_reference :: proc(t: ^testing.T) {
	specials := [?]string{"%", "+", " ", "%4", "%41", "%zz", "%%41", "é", "\xff", "~", "*", "-._", "\x00"}
	keeps := [?]string{"", UNRESERVED, FORM_KEEP, "/:%+"}
	for n in 0 ..= 64 {
		for at in 0 ..= n {
			b := strings.builder_make(context.temp_allocator)
			for sp in specials {
				strings.builder_reset(&b)
				for i in 0 ..< n {
					if i == at { strings.write_string(&b, sp) }
					strings.write_byte(&b, u8('a' + i % 26))
				}
				if at >= n { strings.write_string(&b, sp) }
				s := strings.clone(strings.to_string(b), context.temp_allocator)
				for plus in ([?]bool{false, true}) {
					testing.expectf(t, percent_decode(s, plus) == percent_decode_scalar(s, plus), "decode %q (plus %v)", s, plus)
					for keep in keeps {
						fast := strings.builder_make(context.temp_allocator)
						slow := strings.builder_make(context.temp_allocator)
						percent_encode(&fast, s, keep, plus)
						percent_encode_scalar(&slow, s, keep, plus)
						testing.expectf(t, strings.to_string(fast) == strings.to_string(slow), "encode %q keeping %q (plus %v): %q, the reference %q", s, keep, plus, strings.to_string(fast), strings.to_string(slow))
					}
				}
			}
		}
		free_all(context.temp_allocator)
	}
	testing.expect_value(t, percent_decode(""), "")
	testing.expect_value(t, percent_decode("a%41%2"), "aA%2")
	testing.expect_value(t, percent_decode("a+b", true), "a b")
}
