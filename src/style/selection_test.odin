package style

import "core:math"
import "core:testing"
import "wb:css"
import "wb:dom"
import "wb:html"

@(private = "file")
sel_load :: proc(src: string, state: State = {}) -> (^dom.Document, ^Engine, ^Styled) {
	d := dom.document_create(nil)
	html.parse_into(d, d.root, transmute([]byte)src, 2_000_000)
	s := settings_default()
	e := engine_make(s)
	settings_destroy(&s)
	sync_document_sheets(e, d, "about:test")
	return d, e, compute_styles(e, d, state)
}

@(private = "file")
close_to :: proc(a, b: css.Color) -> bool {
	for i in 0 ..< 4 { if math.abs(a[i] - b[i]) > 0.01 { return false } }
	return true
}

@(test)
selection_pseudo_element :: proc(t: ^testing.T) {
	d, e, st := sel_load(`<style>p::selection { background: rgb(255, 0, 0); color: white } #b::selection { color: rgb(0, 0, 255) }</style>
<p id=a>one <span id=s>two</span></p><p id=b>three</p><div id=c>four</div>`)
	defer { styled_destroy(st); engine_destroy(e); dom.document_destroy(d) }
	fg, has_fg, bg, has_bg := selection_colors(st, d, dom.find_by_id(d, "s"))
	testing.expect(t, has_fg && has_bg, "a span inherits the highlight of its paragraph")
	testing.expect(t, close_to(bg, {1, 0, 0, 1}) && close_to(fg, {1, 1, 1, 1}), "colors of p::selection")
	fg, has_fg, bg, has_bg = selection_colors(st, d, dom.find_by_id(d, "b"))
	testing.expect(t, has_fg && close_to(fg, {0, 0, 1, 1}), "the more specific rule wins")
	testing.expect(t, has_bg && close_to(bg, {1, 0, 0, 1}), "the background of p::selection still applies")
	_, has_fg, _, has_bg = selection_colors(st, d, dom.find_by_id(d, "c"))
	testing.expect(t, !has_fg && !has_bg, "no ::selection: the browser's colors")
	testing.expect(t, style_of(st, dom.find_by_id(d, "c")).background_color.a == 0, "::selection does not style the element")
}

@(test)
focus_visible_follows_the_state :: proc(t: ^testing.T) {
	d, e, st := sel_load(`<style>a:focus { color: rgb(255, 0, 0) } a:focus-visible { background: rgb(0, 0, 255) }</style><a id=a href=x>link</a>`)
	defer { engine_destroy(e); dom.document_destroy(d) }
	a := dom.find_by_id(d, "a")
	styled_destroy(st)
	st = compute_styles(e, d, State{focus = a})
	c := style_of(st, a)
	testing.expect(t, close_to(c.color, {1, 0, 0, 1}) && c.background_color.a == 0, "focused by the pointer: :focus only")
	changed, ok := restyle_state(e, d, st, State{focus = a, focus_visible = true})
	testing.expect(t, ok && changed, "a change of :focus-visible restyles")
	c = style_of(st, a)
	testing.expect(t, close_to(c.background_color, {0, 0, 1, 1}), ":focus-visible from the keyboard")
	styled_destroy(st)
}
