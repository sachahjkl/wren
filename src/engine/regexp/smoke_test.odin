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
