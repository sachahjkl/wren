package blocker

import "core:testing"

@(private = "file")
repl :: proc(pat, flags, text, with: string, max := 0) -> string {
	re := jsre_compile(pat, flags)
	if re == nil { return "<invalid>" }
	defer jsre_destroy(re)
	out, _ := jsre_replace(re, text, with, max, context.temp_allocator)
	return out
}

@(private = "file")
matches :: proc(pat, flags, text: string) -> bool {
	re := jsre_compile(pat, flags)
	if re == nil { return false }
	defer jsre_destroy(re)
	return jsre_test(re, text)
}

@(test)
test_jsre_basics :: proc(t: ^testing.T) {
	testing.expect(t, matches("a.c", "", "xabcx"))
	testing.expect(t, !matches("^ab+c$", "", "xabc"))
	testing.expect(t, matches("^ab+c$", "", "abbbc"))
	testing.expect(t, matches("colou?r", "", "color"))
	testing.expect(t, matches("[a-c]{3}", "", "zabcz"))
	testing.expect(t, !matches("[^a-c]", "", "abc"))
	testing.expect(t, matches("\\d+\\.\\d+", "", "v 12.5"))
	testing.expect(t, matches("hello", "i", "HeLLo"))
	testing.expect(t, matches("a|b|cd", "", "xcd"))
	testing.expect(t, matches("\\bfoo\\b", "", "a foo b"))
	testing.expect(t, !matches("\\bfoo\\b", "", "afoob"))
	testing.expect(t, matches("^b", "m", "a\nb"))
	testing.expect(t, !matches("a.b", "", "a\nb"))
	testing.expect(t, matches("a.b", "s", "a\nb"))
	testing.expect(t, matches("(a)\\1", "", "xaa"))
	testing.expect(t, !matches("(a)\\1", "", "ab"))
	testing.expect(t, matches("foo(?=bar)", "", "foobar"))
	testing.expect(t, !matches("foo(?=bar)", "", "foobaz"))
	testing.expect(t, matches("foo(?!bar)", "", "foobaz"))
	testing.expect(t, matches("(?<=\\$)\\d+", "", "cost $42"))
	testing.expect(t, !matches("(?<!\\$)\\b\\d+", "", "$42"))
	testing.expect(t, matches("é+", "", "caféé"))
	testing.expect(t, jsre_compile("(", "") == nil)
	testing.expect(t, jsre_compile("[a", "") == nil)
	testing.expect(t, jsre_compile("*a", "") == nil)
	testing.expect(t, jsre_compile("a", "q") == nil)
}

@(test)
test_jsre_replace :: proc(t: ^testing.T) {
	testing.expect_value(t, repl("(\\d+)-(\\d+)", "g", "1-2 and 33-44", "$2-$1"), "2-1 and 44-33")
	testing.expect_value(t, repl("o", "g", "foo boo", "0"), "f00 b00")
	testing.expect_value(t, repl("o", "", "foo boo", "0"), "f0o boo")
	testing.expect_value(t, repl("o", "g", "foo boo", "0", 3), "f00 b0o")
	testing.expect_value(t, repl("x*", "g", "abc", "-"), "-a-b-c-")
	testing.expect_value(t, repl("b", "g", "abc", "[$&|$`|$'|$$]"), "a[b|a|c|$]c")
	// lazy and greedy
	testing.expect_value(t, repl("\"adPlacements\".*?\"adSlots\"", "g", "{\"adPlacements\":[1],\"adSlots\":2,\"adSlots\":3}", "\"no\""), "{\"no\":2,\"adSlots\":3}")
	testing.expect_value(t, repl("\"adPlacements\".*\"adSlots\"", "g", "{\"adPlacements\":[1],\"adSlots\":2,\"adSlots\":3}", "\"no\""), "{\"no\":3}")
	testing.expect_value(t, repl("a+?", "", "aaa", "x"), "xaa")
	testing.expect_value(t, repl("a{2}", "g", "aaaaa", "x"), "xxa")
	testing.expect_value(t, repl("a{2,3}", "g", "aaaaaaa", "x"), "xxa")
	// no capture taking part: nothing is written for it
	testing.expect_value(t, repl("(a)|(b)", "g", "ab", "<$1$2>"), "<a><b>")
	// a replacement text without a dollar
	testing.expect_value(t, repl("é", "g", "café", "e"), "cafe")
}

@(test)
test_jsre_budget :: proc(t: ^testing.T) {
	re := jsre_compile("(a*)*b", "")
	defer jsre_destroy(re)
	testing.expect(t, re != nil)
	// must come back (false or true), not hang
	_ = jsre_test(re, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
}

@(test)
test_needle :: proc(t: ^testing.T) {
	n := needle_make("")
	testing.expect(t, needle_test(&n, "anything"))
	needle_destroy(&n)
	n = needle_make("ads")
	testing.expect(t, needle_test(&n, "load ads now"))
	testing.expect(t, !needle_test(&n, "clean"))
	needle_destroy(&n)
	n = needle_make("!ads")
	testing.expect(t, !needle_test(&n, "load ads now"))
	testing.expect(t, needle_test(&n, "clean"))
	needle_destroy(&n)
	n = needle_make("/^ad[0-9]+$/i")
	testing.expect(t, needle_test(&n, "AD12"))
	testing.expect(t, !needle_test(&n, "AD12x"))
	needle_destroy(&n)
	n = needle_make("/(/")
	testing.expect(t, !needle_test(&n, "(") && n.bad)
	needle_destroy(&n)
	re := pattern_regex("a.b(c)")
	defer jsre_destroy(re)
	testing.expect(t, jsre_test(re, "xa.b(c)x") && !jsre_test(re, "axb(c)"))
}
