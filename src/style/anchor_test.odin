package style

import "core:testing"
import "wb:css"
import "wb:dom"
import "wb:html"

@(private = "file")
Dx :: struct { doc: ^dom.Document, eng: ^Engine, st: ^Styled }

@(private = "file")
open :: proc(src: string) -> Dx {
	d: Dx
	d.doc = dom.document_create(nil)
	html.parse_into(d.doc, d.doc.root, transmute([]byte)src, 2_000_000)
	s := settings_default()
	d.eng = engine_make(s)
	settings_destroy(&s)
	sync_document_sheets(d.eng, d.doc, "about:test")
	d.st = compute_styles(d.eng, d.doc, {})
	return d
}

@(private = "file")
close :: proc(d: Dx) {
	styled_destroy(d.st)
	engine_destroy(d.eng)
	dom.document_destroy(d.doc)
}

@(private = "file")
at :: proc(d: Dx, id: string) -> ^Computed { return style_of(d.st, dom.find_by_id(d.doc, id)) }

@(test)
anchor_properties_supported :: proc(t: ^testing.T) {
	s := settings_default()
	e := engine_make(s)
	settings_destroy(&s)
	defer engine_destroy(e)
	opt := parse_options(&e.settings)
	yes := [][2]string{
		{"anchor-name", "--a"}, {"anchor-name", "--a, --b"}, {"anchor-name", "none"}, {"anchor-scope", "all"}, {"anchor-scope", "--a, --b"},
		{"position-anchor", "--a"}, {"position-anchor", "auto"}, {"position-anchor", "normal"}, {"position-anchor", "none"}, {"position-anchor", "match-parent"},
		{"top", "anchor(--a bottom)"}, {"left", "calc(anchor(right, 1px) + 2px)"}, {"inset-block-start", "anchor(top)"}, {"inset", "anchor(top) auto"},
		{"width", "anchor-size(width)"}, {"max-height", "anchor-size(--a height, 10%)"}, {"top", "anchor-size(height)"}, {"margin-left", "anchor-size(width)"},
		{"position-area", "top left"}, {"position-area", "span-all"}, {"position-area", "block-start inline-end"}, {"position-area", "none"},
		{"position-try-fallbacks", "flip-block, --x flip-start, top left"}, {"position-try-fallbacks", "none"}, {"position-try-order", "most-width"},
		{"position-try", "most-height --x, flip-inline"}, {"position-visibility", "anchor-visible no-overflow"}, {"position-visibility", "always"},
		{"align-self", "anchor-center"}, {"justify-self", "anchor-center"},
	}
	for x in yes { testing.expectf(t, supports_declaration(e, x[0], x[1], opt), "%s: %s", x[0], x[1]) }
	no := [][2]string{
		{"anchor-name", "a"}, {"anchor-name", "--a --b"}, {"anchor-scope", "--a none"}, {"position-anchor", "--a, --b"}, {"position-anchor", "a"},
		{"width", "anchor(top)"}, {"margin-top", "anchor(top)"}, {"padding-top", "anchor-size(width)"}, {"font-size", "anchor-size(width)"}, {"border-top-width", "anchor(top)"},
		{"position-area", "top top"}, {"position-area", "left inline-start"}, {"position-area", "none none"}, {"position-area", "top left bottom"},
		{"position-try-fallbacks", "flip-block --a --b"}, {"position-try-fallbacks", "flip-block, none"}, {"position-try-fallbacks", "flip-block flip-block"},
		{"position-try-order", "flip-block"}, {"position-try", "flip-block most-height"}, {"position-visibility", "always no-overflow"}, {"position-visibility", "no-overflow no-overflow"},
		{"justify-content", "anchor-center"},
	}
	for x in no { testing.expectf(t, !supports_declaration(e, x[0], x[1], opt), "%s: %s", x[0], x[1]) }
}

@(test)
anchored_lengths_wait_for_layout :: proc(t: ^testing.T) {
	d := open(`<!doctype html><style>
		.a { position: absolute }
		#x { top: anchor(--a bottom); width: anchor-size(width); position-anchor: --a; anchor-name: --n, --m; anchor-scope: all }
		#plain { top: 1px; left: 2px; position: absolute }
		#st { position: absolute; position-try-fallbacks: --r flip-block, top left; position-try-order: most-height; position-visibility: no-overflow; font-size: 10px }
		@position-try --r { top: 2em; margin-left: anchor-size(width) }
		#fall { top: anchor(top, 3px); width: anchor-size(width, 1em); position: relative; font-size: 10px }
		#none { top: anchor(top); width: anchor-size(); position: relative }
		#var { --n: 7px; position: absolute; position-try-fallbacks: --v }
		@position-try --v { left: var(--n) }
		#miss { position: absolute; position-try-fallbacks: --absent }
	</style><div id=x class=a></div><div id=plain></div><div id=st></div><div id=fall></div><div id=none></div><div id=var></div><div id=miss></div>`)
	defer close(d)
	x := at(d, "x")
	testing.expect_value(t, x.inset[.Top].kind, Length_Kind.Anchor)
	testing.expect_value(t, x.width.kind, Length_Kind.Anchor)
	testing.expect_value(t, x.position_anchor.kind, Position_Anchor_Kind.Name)
	testing.expect_value(t, x.position_anchor.name, "--a")
	testing.expect_value(t, len(x.anchor_name), 2)
	testing.expect(t, x.anchor_scope.all)
	testing.expect(t, anchored_style(x))
	testing.expect(t, !anchored_style(at(d, "plain")))
	testing.expect_value(t, at(d, "plain").position_visibility, Position_Visibility{.Anchor_Visible})

	st := at(d, "st")
	testing.expect_value(t, len(st.position_try_fallbacks), 2)
	testing.expect_value(t, st.position_try_order, Try_Order.Most_Height)
	testing.expect_value(t, st.position_visibility, Position_Visibility{.No_Overflow})
	r := st.position_try_fallbacks[0]
	testing.expect_value(t, r.name, "--r")
	testing.expect_value(t, r.tactics[0], Try_Tactic.Flip_Block)
	testing.expect_value(t, r.n_tactics, 1)
	testing.expect(t, r.rule != nil)
	testing.expect_value(t, r.rule.inset[.Top].v, 20)    // 2em of the element
	testing.expect_value(t, r.rule.margin[.Left].kind, Length_Kind.Anchor)
	testing.expect_value(t, st.position_try_fallbacks[1].area, Position_Area{.Left, .Top})

	// not absolutely positioned: the fallback, or as if auto
	f := at(d, "fall")
	testing.expect_value(t, f.inset[.Top], px(3))
	testing.expect_value(t, f.width, px(10))
	testing.expect_value(t, at(d, "none").inset[.Top].kind, Length_Kind.Anchor)
	testing.expect(t, at(d, "none").inset[.Top].calc == nil)
	testing.expect(t, at(d, "none").width.calc == nil)

	testing.expect_value(t, at(d, "var").position_try_fallbacks[0].rule.inset[.Left], px(7))
	testing.expect(t, at(d, "miss").position_try_fallbacks[0].missing)
}

// A change of these values lays the box out again, and keeps it.
@(test)
anchor_changes_are_layout_changes :: proc(t: ^testing.T) {
	d := open(`<!doctype html><style>#a { position: absolute; anchor-name: --a } #b { position: absolute; anchor-name: --b; position-area: top left; }</style><div id=a></div><div id=b></div>`)
	defer close(d)
	a, b := new(Computed), new(Computed)
	defer { free(a); free(b) }
	a^, b^ = at(d, "a")^, at(d, "a")^
	b.anchor_name = {"--z"}
	testing.expect_value(t, change_level(a, b), Change_Level.Layout)
	b^ = a^
	b.position_area = {.Top, .Left}
	testing.expect_value(t, change_level(a, b), Change_Level.Layout)
}

@(test)
position_area_tracks :: proc(t: ^testing.T) {
	Case :: struct { a: Position_Area, rtl: bool, x, y: [2]i8 }
	cases := []Case{
		{{.Top, .None}, false, {0, 2}, {0, 0}},
		{{.Left, .Top}, false, {0, 0}, {0, 0}},
		{{.Center, .None}, false, {1, 1}, {1, 1}},
		{{.Span_All, .None}, false, {0, 2}, {0, 2}},
		{{.Center, .Bottom}, false, {1, 1}, {2, 2}},
		{{.Left, .Center}, false, {0, 0}, {1, 1}},
		{{.Span_Left, .Span_Bottom}, false, {0, 1}, {1, 2}},
		{{.Block_Start, .Inline_End}, false, {2, 2}, {0, 0}},
		{{.Block_Start, .Inline_End}, true, {0, 0}, {0, 0}},
		{{.Start, .End}, false, {2, 2}, {0, 0}},
		{{.Start, .None}, false, {0, 0}, {0, 0}},
		{{.Block_End, .Center}, false, {1, 1}, {2, 2}},
		{{.Center, .Inline_Start}, false, {0, 0}, {1, 1}},
	}
	for c in cases {
		x, y := area_tracks(c.a, c.rtl, c.rtl)
		testing.expectf(t, x == c.x && y == c.y, "%v rtl %v: x %v y %v", c.a, c.rtl, x, y)
	}
}

@(test)
anchor_values_serialize :: proc(t: ^testing.T) {
	d := open(`<!doctype html><style>
		#x { position: absolute; anchor-name: --a, --b; anchor-scope: --c; position-anchor: --d; position-area: bottom center;
		     position-try-fallbacks: flip-inline --e, top left; position-try-order: most-block-size; position-visibility: no-overflow anchor-valid }
		#y { position-area: block-end inline-start }
	</style><div id=x></div><div id=y></div>`)
	defer close(d)
	x := at(d, "x")
	testing.expect_value(t, anchor_prop_text(x, "anchor-name"), "--a, --b")
	testing.expect_value(t, anchor_prop_text(x, "anchor-scope"), "--c")
	testing.expect_value(t, anchor_prop_text(x, "position-anchor"), "--d")
	testing.expect_value(t, anchor_prop_text(x, "position-area"), "center bottom")
	testing.expect_value(t, anchor_prop_text(x, "position-try-fallbacks"), "--e flip-inline, left top")
	testing.expect_value(t, anchor_prop_text(x, "position-try-order"), "most-block-size")
	testing.expect_value(t, anchor_prop_text(x, "position-visibility"), "anchor-valid no-overflow")
	y := at(d, "y")
	testing.expect_value(t, anchor_prop_text(y, "position-area"), "end start")
	testing.expect_value(t, anchor_prop_text(y, "position-anchor"), "normal")
	testing.expect_value(t, anchor_prop_text(y, "position-visibility"), "anchor-visible")
	testing.expect_value(t, anchor_prop_text(y, "anchor-name"), "none")
}

// Tactics move the sides and what the functions name.
@(test)
try_tactics_mirror :: proc(t: ^testing.T) {
	d := open(`<!doctype html><style>
		#x { position: absolute; top: anchor(bottom); left: anchor(left, 1px); width: 10px; height: anchor-size(width); margin-top: 3px; align-self: start; justify-self: end }
	</style><div id=x></div>`)
	defer close(d)
	c := at(d, "x")^
	try_tactic_apply(&c, .Flip_Block, context.temp_allocator)
	testing.expect_value(t, c.inset[.Top].kind, Length_Kind.Auto)
	testing.expect_value(t, c.inset[.Bottom].calc.anchor.side, css.Anchor_Keyword.Top)
	testing.expect_value(t, c.margin[.Bottom].v, 3)
	testing.expect_value(t, c.align_self, Content_Align.End)
	testing.expect_value(t, c.justify_self, Content_Align.End)
	c = at(d, "x")^
	try_tactic_apply(&c, .Flip_Start, context.temp_allocator)
	testing.expect_value(t, c.inset[.Left].calc.anchor.side, css.Anchor_Keyword.Right)
	testing.expect_value(t, c.inset[.Top].calc.anchor.side, css.Anchor_Keyword.Top)
	testing.expect_value(t, c.height.v, 10)
	testing.expect_value(t, c.width.calc.anchor.side, css.Anchor_Keyword.Height)
	testing.expect_value(t, c.margin[.Left].v, 3)
	testing.expect_value(t, c.justify_self, Content_Align.Start)
	testing.expect_value(t, c.align_self, Content_Align.End)
}
