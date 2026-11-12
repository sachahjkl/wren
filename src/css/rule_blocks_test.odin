package css

import "core:strings"
import "core:testing"

@(private = "file")
OPT :: Parse_Options{max_nesting_depth = 512, max_rules = 100_000, max_errors_kept = 100}

// Rule lists of at-rules read straight from the tokens (parse_at_rule), the errors a sheet keeps and counts, the first error of a
// single rule's parse, and the units the tokenizer classifies.

@(test)
rule_blocks_read_from_tokens :: proc(t: ^testing.T) {
	s := parse_stylesheet(`@media screen { .a { color: red } @media print { .b { color: blue } } .c { } } .d { }`, OPT)
	defer { stylesheet_destroy(s); free(s) }
	testing.expect_value(t, len(s.rules), 2)
	if len(s.rules) != 2 { return }
	m := s.rules[0]
	testing.expect_value(t, m.kind, Rule_Kind.Media)
	testing.expect_value(t, len(m.rules), 3)
	if len(m.rules) == 3 {
		testing.expect_value(t, m.rules[0].selector_text, ".a")
		testing.expect_value(t, m.rules[1].kind, Rule_Kind.Media)
		testing.expect_value(t, len(m.rules[1].rules), 1)
		testing.expect_value(t, m.rules[2].selector_text, ".c")
	}
	testing.expect_value(t, s.rules[1].selector_text, ".d")

	// a rule without a block inside a rule list is dropped at its `}`: the block ends there, the sheet goes on
	s2 := parse_stylesheet(`@supports (display: grid) { .a } .e { color: red }`, OPT)
	defer { stylesheet_destroy(s2); free(s2) }
	testing.expect_value(t, len(s2.rules), 2)
	if len(s2.rules) == 2 {
		testing.expect_value(t, len(s2.rules[0].rules), 0)
		testing.expect_value(t, s2.rules[1].selector_text, ".e")
	}

	// an @namespace inside a block is refused
	s3 := parse_stylesheet(`@media all { @namespace svg url(http://www.w3.org/2000/svg); .f { } }`, OPT)
	defer { stylesheet_destroy(s3); free(s3) }
	testing.expect(t, len(s3.rules) == 1 && len(s3.rules[0].rules) == 1, "the style rule alone")
}

// Rule-list blocks nested past the limit are skipped (no recursion past it) and reported.
@(test)
rule_blocks_nesting_bounded :: proc(t: ^testing.T) {
	DEPTH :: 100
	opt := OPT
	opt.max_nesting_depth = 64
	sb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< DEPTH { strings.write_string(&sb, "@media all { ") }
	strings.write_string(&sb, ".x { color: red }")
	for _ in 0 ..< DEPTH { strings.write_string(&sb, " }") }
	strings.write_string(&sb, " .after { }")
	s := parse_stylesheet(strings.to_string(sb), opt)
	defer { stylesheet_destroy(s); free(s) }
	testing.expect(t, len(s.errors) > 0, "the depth limit was reported")
	testing.expect(t, len(s.rules) == 2 && s.rules[1].selector_text == ".after", "what follows the deep block is read")
}

@(test)
parse_errors_kept_and_counted :: proc(t: ^testing.T) {
	opt := OPT
	opt.max_errors_kept = 2
	s := parse_stylesheet(`!a { } !b { } !c { } !d { } !e { } .ok { }`, opt)
	defer { stylesheet_destroy(s); free(s) }
	testing.expect_value(t, len(s.errors), 2)
	testing.expect_value(t, s.errors_dropped, 3)
	stylesheet_add_error(s, "late", opt)
	testing.expect_value(t, s.errors_dropped, 4)

	r, why := parse_rule_into(s, "!x { color: red }", OPT)
	testing.expect(t, r == nil && strings.contains(why, "invalid selector"), "the reason of a rule dropped")
	r, why = parse_rule_into(s, ".y { color: red }", OPT)
	testing.expect(t, r != nil && why == "", "a valid rule: no error")
	r, why = parse_rule_into(s, ".y { } .z { }", OPT)
	testing.expect(t, r == nil && why != "", "two rules")
	decls, first := parse_declarations_checked("color: red; @media x { .a { } }", OPT, context.temp_allocator)
	testing.expect(t, len(decls) == 1 && first == "", "declarations")
}

@(test)
dimension_units_classified :: proc(t: ^testing.T) {
	toks := tokenize("10PX 2Em 3s 4dvmin 5cQi 6q 7foo", context.temp_allocator)
	want := [?]Dim_Unit{.Px, .Em, .Other, .Vmin, .Cqw, .Q, .Other}
	n := 0
	for tok in toks {
		if tok.kind != .Dimension { continue }
		if n < len(want) { testing.expectf(t, tok.unit == want[n], "%q: %v", tok.text, tok.unit) }
		n += 1
	}
	testing.expect_value(t, n, len(want))
	testing.expect_value(t, token_dim_unit(Token{kind = .Dimension, text = "REM"}), Dim_Unit.Rem)   // (made by hand: read from its text)
	px, ok := length_unit_to_px(2, "IN", 0)
	testing.expect(t, ok && px == 192, "in")
	u, rok := relative_unit("SVH")
	testing.expect(t, rok && u == .Vh, "svh")
}
