package style

import "core:math"
import "core:testing"
import "wb:css"
import "wb:dom"

@(private = "file")
close_to :: proc(a, b: css.Color) -> bool {
	for i in 0 ..< 4 { if math.abs(a[i] - b[i]) > 0.01 { return false } }
	return true
}

@(test)
selection_pseudo_element :: proc(t: ^testing.T) {
	f := fixture_load(`<style>p::selection { background: rgb(255, 0, 0); color: white } #b::selection { color: rgb(0, 0, 255) }</style>
<p id=a>one <span id=s>two</span></p><p id=b>three</p><div id=c>four</div>`)
	defer fixture_unload(f)
	s := highlight_paint(f.st, f.doc, dom.find_by_id(f.doc, "s"), .Selection)
	testing.expect(t, s.has_color && s.has_background, "a span inherits the highlight of its paragraph")
	testing.expect(t, close_to(s.background, {1, 0, 0, 1}) && close_to(s.color, {1, 1, 1, 1}), "colors of p::selection")
	b := highlight_paint(f.st, f.doc, dom.find_by_id(f.doc, "b"), .Selection)
	testing.expect(t, b.has_color && close_to(b.color, {0, 0, 1, 1}), "the more specific rule wins")
	testing.expect(t, b.has_background && close_to(b.background, {1, 0, 0, 1}), "the background of p::selection still applies")
	c := highlight_paint(f.st, f.doc, dom.find_by_id(f.doc, "c"), .Selection)
	testing.expect(t, !c.has_color && !c.has_background && !c.declared_color, "no ::selection: the browser's colors")
	testing.expect(t, style_of(f.st, dom.find_by_id(f.doc, "c")).background_color.a == 0, "::selection does not style the element")
}

// CSS Pseudo 4 §3.5: every property comes from the parent's highlight when the element's says nothing, even one that does not inherit; `inherit` and `unset` say nothing, and
// `initial` says the initial value.
@(test)
highlights_inherit_from_the_highlight_of_the_parent :: proc(t: ^testing.T) {
	f := fixture_load(`<style>
		div::selection { text-decoration: underline wavy rgb(0, 128, 0); text-shadow: 1px 1px red; background: rgb(255, 0, 0); text-underline-offset: 3px; -webkit-text-stroke-width: 2px }
		#set::selection { text-decoration-line: overline }
		#keep::selection { background: inherit; text-decoration-line: unset }
		#none::selection { background: initial; text-decoration: initial }
		#em::selection { font-size: 100px; text-underline-offset: 1em; color: currentcolor }
		</style>
		<div style="font-size: 10px"><p id=plain>one</p><p id=set>two</p><p id=keep>three</p><p id=none>four</p><p id=em>five</p></div>`)
	defer fixture_unload(f)
	plain := highlight_paint(f.st, f.doc, dom.find_by_id(f.doc, "plain"), .Selection)
	testing.expect(t, plain.lines == {.Underline} && plain.line_style == .Wavy && plain.has_line_color && len(plain.shadows) == 1, "a child takes it all, not inherited properties too")
	testing.expect(t, plain.offset.kind == .Px && plain.offset.v == 3 && plain.has_stroke_width && plain.stroke_width == 2)
	set := highlight_paint(f.st, f.doc, dom.find_by_id(f.doc, "set"), .Selection)
	testing.expect(t, set.lines == {.Overline} && set.line_style == .Wavy, "a longhand of its own, the others of the parent")
	keep := highlight_paint(f.st, f.doc, dom.find_by_id(f.doc, "keep"), .Selection)
	testing.expect(t, keep.has_background && close_to(keep.background, {1, 0, 0, 1}) && keep.lines == {.Underline}, "inherit and unset go to the parent's highlight")
	none := highlight_paint(f.st, f.doc, dom.find_by_id(f.doc, "none"), .Selection)
	testing.expect(t, none.has_background && none.background.a == 0 && none.lines == {}, "initial stops there")
	em := highlight_paint(f.st, f.doc, dom.find_by_id(f.doc, "em"), .Selection)
	testing.expect(t, em.offset.v == 10, "em units are the originating element's, whatever font-size the highlight says")
	testing.expect(t, em.declared_color && !em.has_color, "currentcolor: the layer below")
}

@(test)
each_highlight_has_its_rules_and_defaults :: proc(t: ^testing.T) {
	f := fixture_load(`<style>
		::target-text { background: rgb(1, 2, 3) }
		::spelling-error { color: rgb(0, 0, 255) }
		#g::grammar-error { text-decoration: overline }
		::highlight(*) { color: rgb(0, 255, 0) }
		::highlight(named) { background: rgb(255, 0, 0) }
		</style><p id=g>one</p>`)
	defer fixture_unload(f)
	g := dom.find_by_id(f.doc, "g")
	target := highlight_paint(f.st, f.doc, g, .Target_Text)
	testing.expect(t, target.has_background && !target.has_color, "::target-text")
	spelling := highlight_paint(f.st, f.doc, g, .Spelling_Error)
	testing.expect(t, spelling.has_color && spelling.lines == {.Spelling_Error}, "::spelling-error: `text-decoration: spelling-error` unless it says otherwise")
	grammar := highlight_paint(f.st, f.doc, g, .Grammar_Error)
	testing.expect(t, grammar.lines == {.Overline}, "::grammar-error")
	named := highlight_paint(f.st, f.doc, g, .Custom, "named")
	testing.expect(t, named.has_color && close_to(named.color, {0, 1, 0, 1}) && named.has_background, "::highlight(*) goes with a name's rules")
	other := highlight_paint(f.st, f.doc, g, .Custom, "other")
	testing.expect(t, other.has_color && !other.has_background, "::highlight(*) alone")
}

@(test)
focus_visible_follows_the_state :: proc(t: ^testing.T) {
	f := fixture_load(`<style>a:focus { color: rgb(255, 0, 0) } a:focus-visible { background: rgb(0, 0, 255) }</style><a id=a href=x>link</a>`)
	defer fixture_unload(f)
	a := dom.find_by_id(f.doc, "a")
	styled_destroy(f.st)
	f.st = compute_styles(f.eng, f.doc, State{focus = a})
	c := style_of(f.st, a)
	testing.expect(t, close_to(c.color, {1, 0, 0, 1}) && c.background_color.a == 0, "focused by the pointer: :focus only")
	changed, ok := restyle_state(f.eng, f.doc, f.st, State{focus = a, focus_visible = true})
	testing.expect(t, ok && changed, "a change of :focus-visible restyles")
	c = style_of(f.st, a)
	testing.expect(t, close_to(c.background_color, {0, 0, 1, 1}), ":focus-visible from the keyboard")
}

@(test)
highlight_pseudo_element :: proc(t: ^testing.T) {
	f := fixture_load(`<style>::highlight(a) { background: rgb(255, 0, 0); color: white } p::highlight(a) { color: rgb(0, 0, 255) } ::highlight(b) { color: rgb(0, 255, 0) }</style>
<p id=p><span id=s>one</span></p><div id=d>two</div>`)
	defer fixture_unload(f)
	p := highlight_paint(f.st, f.doc, dom.find_by_id(f.doc, "p"), .Custom, "a")
	testing.expect(t, p.has_color && p.has_background && close_to(p.color, {0, 0, 1, 1}) && close_to(p.background, {1, 0, 0, 1}), "the more specific rule wins, the other's background stays")
	d := highlight_paint(f.st, f.doc, dom.find_by_id(f.doc, "d"), .Custom, "a")
	testing.expect(t, d.has_color && close_to(d.color, {1, 1, 1, 1}), "a rule of no element matches them all")
	b := highlight_paint(f.st, f.doc, dom.find_by_id(f.doc, "s"), .Custom, "b")
	testing.expect(t, b.has_color && close_to(b.color, {0, 1, 0, 1}) && !b.has_background, "a name is a highlight of its own")
	c := highlight_paint(f.st, f.doc, dom.find_by_id(f.doc, "s"), .Custom, "c")
	testing.expect(t, !c.has_color && !c.has_background, "no rule: no color of its own")
	testing.expect(t, style_of(f.st, dom.find_by_id(f.doc, "d")).background_color.a == 0, "::highlight() does not style the element")
}
