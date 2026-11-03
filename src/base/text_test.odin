package base

import "core:testing"

// ASCII case changes A-Z and a-z alone: the Kelvin sign U+212A is no 'k', the long s U+017F no 's' (strings.to_lower and
// equal_fold fold them so).
@(test)
ascii_case_leaves_other_letters :: proc(t: ^testing.T) {
	testing.expect_value(t, ascii_lower("DiV"), "div")
	testing.expect_value(t, ascii_lower("LinK"), "linK")
	s := "already"
	testing.expect(t, raw_data(ascii_lower(s)) == raw_data(s), "no uppercase ASCII letter: the string itself")
	c := ascii_lower_clone(s)
	defer delete(c)
	testing.expect(t, c == s && raw_data(c) != raw_data(s), "a clone is a copy")
	testing.expect_value(t, ascii_upper("poſt"), "POſT")
	testing.expect(t, ascii_equal_fold("CheckBox", "checkbox"), "ASCII letters fold")
	testing.expect(t, !ascii_equal_fold("checKbox", "checkbox"), "the Kelvin sign is no k")
	testing.expect(t, !ascii_equal_fold("ſcript", "script"), "the long s is no s")
	testing.expect(t, !ascii_equal_fold("ab", "abc"), "lengths")
	testing.expect(t, ascii_has_prefix_fold("NoSniff; x", "nosniff") && !ascii_has_prefix_fold("noſniff", "nosniff"), "a prefix")
	testing.expect(t, ascii_has_suffix_fold("A.WASM", ".wasm") && !ascii_has_suffix_fold("wasm", ".wasm"), "a suffix")
	testing.expect_value(t, ascii_index_fold("Hello World", "lo wo"), 3)
	testing.expect_value(t, ascii_index_fold("Keep keep", "KEEP"), len("Keep "))
	testing.expect(t, ascii_contains_fold("x", "") && !ascii_contains_fold("ab", "abc"), "an empty needle, a longer one")
}
