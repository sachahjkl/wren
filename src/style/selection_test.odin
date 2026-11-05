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
	fg, has_fg, bg, has_bg := selection_colors(f.st, f.doc, dom.find_by_id(f.doc, "s"))
	testing.expect(t, has_fg && has_bg, "a span inherits the highlight of its paragraph")
	testing.expect(t, close_to(bg, {1, 0, 0, 1}) && close_to(fg, {1, 1, 1, 1}), "colors of p::selection")
	fg, has_fg, bg, has_bg = selection_colors(f.st, f.doc, dom.find_by_id(f.doc, "b"))
	testing.expect(t, has_fg && close_to(fg, {0, 0, 1, 1}), "the more specific rule wins")
	testing.expect(t, has_bg && close_to(bg, {1, 0, 0, 1}), "the background of p::selection still applies")
	_, has_fg, _, has_bg = selection_colors(f.st, f.doc, dom.find_by_id(f.doc, "c"))
	testing.expect(t, !has_fg && !has_bg, "no ::selection: the browser's colors")
	testing.expect(t, style_of(f.st, dom.find_by_id(f.doc, "c")).background_color.a == 0, "::selection does not style the element")
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
	fg, has_fg, bg, has_bg := highlight_colors(f.st, f.doc, dom.find_by_id(f.doc, "p"), "a")
	testing.expect(t, has_fg && has_bg && close_to(fg, {0, 0, 1, 1}) && close_to(bg, {1, 0, 0, 1}), "the more specific rule wins, the other's background stays")
	fg, has_fg, _, _ = highlight_colors(f.st, f.doc, dom.find_by_id(f.doc, "d"), "a")
	testing.expect(t, has_fg && close_to(fg, {1, 1, 1, 1}), "a rule of no element matches them all")
	fg, has_fg, _, has_bg = highlight_colors(f.st, f.doc, dom.find_by_id(f.doc, "s"), "b")
	testing.expect(t, has_fg && close_to(fg, {0, 1, 0, 1}) && !has_bg, "a name is a highlight of its own")
	_, has_fg, _, has_bg = highlight_colors(f.st, f.doc, dom.find_by_id(f.doc, "s"), "c")
	testing.expect(t, !has_fg && !has_bg, "no rule: no color of its own")
	testing.expect(t, style_of(f.st, dom.find_by_id(f.doc, "d")).background_color.a == 0, "::highlight() does not style the element")
}
