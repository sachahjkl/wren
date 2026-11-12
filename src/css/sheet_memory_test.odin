package css

import "wb:base"
import "core:strings"
import "core:testing"

@(private = "file")
OPT :: Parse_Options{max_nesting_depth = 512, max_rules = 100_000, max_errors_kept = 100}

@(private = "file")
parsed :: proc(src: string) -> ^Stylesheet { return parse_stylesheet(src, OPT) }

@(private = "file")
dropped :: proc(s: ^Stylesheet) {
	stylesheet_destroy(s)
	free(s)
}

// A name's fast path stops at what it does not take: the rest is read as before, the start kept.
@(test)
names_with_an_escape_or_beyond_ascii_keep_their_start :: proc(t: ^testing.T) {
	arena: base.Arena
	_ = base.arena_init_growing(&arena)
	defer base.arena_destroy(&arena)
	names := [?][2]string{{`ab\63 d`, "abcd"}, {"café-x", "café-x"}, {`--x\:y`, "--x:y"}, {"plain-name_1", "plain-name_1"}}
	for n in names {
		toks := tokenize(n[0], base.arena_allocator(&arena))
		testing.expect_value(t, len(toks), 1)
		testing.expect_value(t, toks[0].text, n[1])
	}
}

// Rules are read in a memory emptied after each: what they keep is the sheet's, whatever came after them.
@(test)
what_a_rule_keeps_outlives_the_memory_it_was_read_in :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, ".first > a.b { margin: calc(1px + 2px) 3px; background: url(x.png) } @media screen { .in { color: red } }\n")
	for _ in 0 ..< 500 { strings.write_string(&sb, ".pad .pad2 { padding: 1px 2px 3px 4px; color: rgb(1 2 3) }\n") }
	s := parsed(strings.to_string(sb))
	defer dropped(s)
	testing.expect_value(t, len(s.rules), 502)
	first := s.rules[0]
	testing.expect_value(t, first.selector_text, ".first > a.b")
	testing.expect_value(t, len(first.selectors[0].compounds), 2)
	testing.expect_value(t, first.selectors[0].compounds[1].simples[1].name, "b")
	testing.expect_value(t, len(first.declarations), 2)
	testing.expect_value(t, first.declarations[0].name, "margin")
	testing.expect_value(t, first.declarations[0].value[0].tok.text, "calc")
	testing.expect_value(t, len(first.declarations[0].value[0].children) > 0, true)
	testing.expect_value(t, first.declarations[1].value[0].tok.text, "x.png")
	inner := s.rules[1].rules[0]
	testing.expect_value(t, inner.selector_text, ".in")
	testing.expect_value(t, inner.declarations[0].value[0].tok.text, "red")
}

// A selector longer than what its lists start with, and the sheet's memory for a plain rule: 1.5 KB where the lists of
// eight took 3.3 KB.
@(test)
selector_lists_grow_past_their_reserve_and_a_plain_rule_stays_small :: proc(t: ^testing.T) {
	s := parsed(".a.b.c.d .e > .f + .g ~ .h i { color: red }")
	defer dropped(s)
	c := s.rules[0].selectors[0]
	testing.expect_value(t, len(c.compounds), 6)
	testing.expect_value(t, len(c.combinators), 5)
	testing.expect_value(t, len(c.compounds[0].simples), 4)
	testing.expect_value(t, c.compounds[0].simples[3].name, "d")

	RULES :: 1000
	PLAIN_RULE_BYTES_MAX :: 2048
	sb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< RULES { strings.write_string(&sb, ".sec .x p { padding: 1px }\n") }
	many := parsed(strings.to_string(sb))
	defer dropped(many)
	testing.expectf(t, int(many.arena.total_used) < RULES * PLAIN_RULE_BYTES_MAX, "%d bytes for %d rules", many.arena.total_used, RULES)
}

@(test)
nth_serializes_without_the_formatter :: proc(t: ^testing.T) {
	cases := [?][2]string{{":nth-child(2n+1)", ":nth-child(2n+1)"}, {":nth-child(-n+3)", ":nth-child(-n+3)"}, {":nth-child(3)", ":nth-child(3)"},
		{":nth-child(n-2)", ":nth-child(n-2)"}, {":nth-child(4n)", ":nth-child(4n)"}, {":nth-child(-2n-1)", ":nth-child(-2n-1)"}}
	for c in cases {
		s := parsed(strings.concatenate({c[0], " { color: red }"}, context.temp_allocator))
		defer dropped(s)
		testing.expect_value(t, s.rules[0].selector_text, c[1])
	}
}
