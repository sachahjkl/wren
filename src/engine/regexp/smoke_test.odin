#+build windows, linux, darwin
package regexp

import "core:testing"
import "core:fmt"

@(test)
test_smoke_literal :: proc(t: ^testing.T) {
	re, err := compile("abc", {}, context.allocator)
	testing.expect(t, err.message == "", fmt.tprintf("compile error: %s", err.message))
	defer destroy(&re)
	caps: Captures
	defer captures_destroy(&caps)
	st := exec_search(&re, input_utf8_string("xxabcyy"), 0, &caps)
	testing.expect(t, st == .Match)
	testing.expect_value(t, caps.groups[0].start, 2)
	testing.expect_value(t, caps.groups[0].end, 5)
}

@(test)
test_smoke_class_star :: proc(t: ^testing.T) {
	re, err := compile("[0-9]+", {}, context.allocator)
	testing.expect(t, err.message == "")
	defer destroy(&re)
	caps: Captures
	defer captures_destroy(&caps)
	st := exec_search(&re, input_utf8_string("abc123def"), 0, &caps)
	testing.expect(t, st == .Match)
	testing.expect_value(t, caps.groups[0].start, 3)
	testing.expect_value(t, caps.groups[0].end, 6)
}

@(test)
test_smoke_alt_group :: proc(t: ^testing.T) {
	re, err := compile("(foo|bar)baz", {}, context.allocator)
	testing.expect(t, err.message == "")
	defer destroy(&re)
	caps: Captures
	defer captures_destroy(&caps)
	st := exec_search(&re, input_utf8_string("xbarbaz"), 0, &caps)
	testing.expect(t, st == .Match)
	testing.expect_value(t, caps.groups[0].start, 1)
	testing.expect_value(t, caps.groups[0].end, 7)
	testing.expect_value(t, caps.groups[1].start, 1)
	testing.expect_value(t, caps.groups[1].end, 4)
}

@(test)
test_smoke_ignorecase :: proc(t: ^testing.T) {
	re, err := compile("hello", {.Ignore_Case}, context.allocator)
	testing.expect(t, err.message == "")
	defer destroy(&re)
	caps: Captures
	defer captures_destroy(&caps)
	st := exec_search(&re, input_utf8_string("HELLO"), 0, &caps)
	testing.expect(t, st == .Match)
}

@(test)
test_smoke_anchors :: proc(t: ^testing.T) {
	re, err := compile("^a+$", {}, context.allocator)
	testing.expect(t, err.message == "")
	defer destroy(&re)
	caps: Captures
	defer captures_destroy(&caps)
	testing.expect(t, exec_search(&re, input_utf8_string("aaa"), 0, &caps) == .Match)
	testing.expect(t, exec_search(&re, input_utf8_string("aaab"), 0, &caps) == .No_Match)
}

@(test)
test_smoke_backref :: proc(t: ^testing.T) {
	re, err := compile(`(ab)\1`, {}, context.allocator)
	testing.expect(t, err.message == "")
	defer destroy(&re)
	caps: Captures
	defer captures_destroy(&caps)
	testing.expect(t, exec_search(&re, input_utf8_string("abab"), 0, &caps) == .Match)
	testing.expect(t, exec_search(&re, input_utf8_string("abcd"), 0, &caps) == .No_Match)
}

@(test)
test_smoke_lookahead :: proc(t: ^testing.T) {
	re, err := compile(`foo(?=bar)`, {}, context.allocator)
	testing.expect(t, err.message == "")
	defer destroy(&re)
	caps: Captures
	defer captures_destroy(&caps)
	st := exec_search(&re, input_utf8_string("foobar"), 0, &caps)
	testing.expect(t, st == .Match)
	testing.expect_value(t, caps.groups[0].end, 3)
	testing.expect(t, exec_search(&re, input_utf8_string("fooqux"), 0, &caps) == .No_Match)
}

@(test)
test_smoke_lookbehind :: proc(t: ^testing.T) {
	re, err := compile(`(?<=foo)bar`, {}, context.allocator)
	testing.expect(t, err.message == "")
	defer destroy(&re)
	caps: Captures
	defer captures_destroy(&caps)
	st := exec_search(&re, input_utf8_string("foobar"), 0, &caps)
	testing.expect(t, st == .Match)
	testing.expect_value(t, caps.groups[0].start, 3)
	testing.expect(t, exec_search(&re, input_utf8_string("quxbar"), 0, &caps) == .No_Match)
}

@(test)
test_smoke_named :: proc(t: ^testing.T) {
	re, err := compile(`(?<year>\d{4})-(?<month>\d{2})`, {}, context.allocator)
	testing.expect(t, err.message == "")
	defer destroy(&re)
	caps: Captures
	defer captures_destroy(&caps)
	st := exec_search(&re, input_utf8_string("2026-10"), 0, &caps)
	testing.expect(t, st == .Match)
	yi, yok := named_group_index(&re, "year")
	testing.expect(t, yok)
	testing.expect_value(t, caps.groups[yi].start, 0)
	testing.expect_value(t, caps.groups[yi].end, 4)
}

@(test)
test_smoke_lazy :: proc(t: ^testing.T) {
	re, err := compile(`a.*?b`, {}, context.allocator)
	testing.expect(t, err.message == "")
	defer destroy(&re)
	caps: Captures
	defer captures_destroy(&caps)
	st := exec_search(&re, input_utf8_string("axbxb"), 0, &caps)
	testing.expect(t, st == .Match)
	testing.expect_value(t, caps.groups[0].end, 3) // lazy stops at first b
}

// The v flag's classes: nested classes, chains of difference and intersection, escaped reserved punctuators.
@(test)
test_smoke_class_sets :: proc(t: ^testing.T) {
	matches :: proc(src, input: string) -> bool {
		re, err := compile(src, {.Unicode_Sets}, context.allocator)
		if err.message != "" { return false }
		defer destroy(&re)
		caps: Captures
		defer captures_destroy(&caps)
		return exec(&re, input_utf8_string(input), 0, &caps) == .Match
	}
	testing.expect(t, matches(`^[\d&&[0-1]]$`, "1") && !matches(`^[\d&&[0-1]]$`, "3"), "intersection")
	testing.expect(t, matches(`^[[a-z]--a]$`, "z") && !matches(`^[[a-z]--a]$`, "a"), "difference with a nested class")
	testing.expect(t, matches(`^[\w--\d--_]$`, "q") && !matches(`^[\w--\d--_]$`, "_"), "a chain of differences")
	testing.expect(t, matches(`^[^\:]+$`, "80") && !matches(`^[^\:]+$`, "8:0"), "an escaped reserved punctuator")
}

// An optional group that matched empty fails its iteration (RepeatMatcher past min): it does not take part.
@(test)
test_smoke_optional_empty :: proc(t: ^testing.T) {
	re, err := compile(`^(.*)(.*)?$`, {}, context.allocator)
	testing.expect(t, err.message == "")
	defer destroy(&re)
	caps: Captures
	defer captures_destroy(&caps)
	testing.expect(t, exec(&re, input_utf8_string("ab"), 0, &caps) == .Match)
	testing.expect_value(t, caps.groups[1].end, 2)
	testing.expect_value(t, caps.groups[2].start, -1)
}
