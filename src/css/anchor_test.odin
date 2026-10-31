package css

import "core:mem/virtual"
import "core:testing"

@(private = "file")
OPT :: Parse_Options{max_nesting_depth = 512, max_rules = 100_000}

@(private = "file")
function_of :: proc(text: string, a: Arena_Alloc) -> Value {
	vs := trim_values(parse_component_values(text, OPT, a))
	return len(vs) == 1 ? vs[0] : Value{}
}

@(test)
anchor_function_parses_in_any_order :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	Case :: struct { text: string, want: Anchor_Keyword }
	for c in ([]Case{
		{"anchor(top)", .Top}, {"anchor(--a left)", .Left}, {"anchor(right --a)", .Right}, {"anchor(inside)", .Inside}, {"anchor(outside)", .Outside},
		{"anchor(start, 1px)", .Start}, {"anchor(self-end)", .Self_End}, {"anchor(center, anchor(top))", .Center}, {"anchor(25%)", .Percent}, {"anchor(calc(25%) --x)", .Percent},
	}) {
		n := parse_calc_anchored(function_of(c.text, a), a)
		testing.expectf(t, n != nil && n.op == .Anchor && n.anchor.side == c.want, "%s: %v", c.text, n)
	}
	n := parse_calc_anchored(function_of("anchor(right --a, 10%)", a), a)
	testing.expect_value(t, n.anchor.name, "--a")
	testing.expect_value(t, n.a.unit, Unit.Percent)
	for text in ([]string{"anchor()", "anchor(--a)", "anchor(top left)", "anchor(--a --b top)", "anchor(1px)", "anchor(top, red)", "anchor(top, 1px, 2px)", "anchor(top, 1)", "anchor(width)", "anchor-size(top)", "anchor-size(--a --b)", "anchor-size(, 1px)"}) {
		testing.expectf(t, parse_calc_anchored(function_of(text, a), a) == nil, "%s should not parse", text)
	}
	for text in ([]string{"anchor-size()", "anchor-size(width)", "anchor-size(--a)", "anchor-size(self-block --a, 3px)", "anchor-size(height, 0)"}) {
		n2 := parse_calc_anchored(function_of(text, a), a)
		testing.expectf(t, n2 != nil && n2.op == .Anchor_Size, "%s", text)
	}
}

// Only the properties that take them ask for them; a math function may hold them; what is not replaced is its fallback.
@(test)
anchor_function_in_math :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	testing.expect(t, parse_calc(function_of("anchor(top)", a), a) == nil)
	testing.expect(t, parse_calc(function_of("calc(anchor(top) + 1px)", a), a) == nil)
	n := parse_calc_anchored(function_of("calc(anchor(top, 2px) + 1px)", a), a)
	testing.expect(t, n != nil && calc_has_anchor(n) && calc_has_anchor_position(n))
	testing.expect_value(t, calc_type(n), Calc_Type.Length)
	testing.expect_value(t, eval_calc(n, {}), 3)
	s := parse_calc_anchored(function_of("anchor-size(width)", a), a)
	testing.expect(t, calc_has_anchor(s) && !calc_has_anchor_position(s))
	m := parse_calc_anchored(function_of("min(anchor(top), 10%)", a), a)
	testing.expect_value(t, calc_type(m), Calc_Type.Length_Percent)
}

@(test)
position_try_rule_parses :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	_ = a
	s := parse_stylesheet("@position-try --x { top: 1px; left: anchor(right) } @position-try x { top: 1px } @position-try { top: 1px } a { color: red }", OPT)
	defer { stylesheet_destroy(s); free(s) }
	testing.expect_value(t, len(s.rules), 2)
	testing.expect_value(t, s.rules[0].kind, Rule_Kind.Position_Try)
	testing.expect_value(t, s.rules[0].name, "--x")
	testing.expect_value(t, len(s.rules[0].declarations), 2)
}
