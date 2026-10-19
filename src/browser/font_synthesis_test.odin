package browser

import "core:testing"
import "toolkit:font"
import "wb:page"

// Synthesized italic of a web family without an italic face (CSS font-synthesis: style), as Blink does: an upright
// static face asked for italic is slanted. DirectWrite reports implicit axes for static faces too (single values): they
// must not be taken for an ital / slnt axis, which would skip the synthesis.
@(test)
web_font_italic_is_synthesized :: proc(t: ^testing.T) {
	fs := new(font.State)
	defer free(fs)
	font.init(fs)
	defer font.destroy(fs)
	pf: Page_Fonts
	page_fonts_init(&pf, fs, 0)
	defer page_fonts_destroy(&pf)
	owner := rawptr(uintptr(1))
	page_fonts_scope(&pf, owner)
	data := #load("../../examples/site/fonts/roboto.ttf")
	wf := page.Web_Font{family = "Upright Only", weight = {400, 400}, font_style = .Normal, data = data}
	testing.expect(t, register_web_face(&pf, owner, &wf), "the face loads")
	for w in pf.web { testing.expect(t, !w.ital && !w.slnt, "a static face has no ital / slnt axis") }
	families := []string{"Upright Only"}
	upright := resolve_font(&pf, families, 400, false, nil)
	italic := resolve_font(&pf, families, 400, true, nil)
	testing.expect(t, upright != 0 && italic != 0 && upright != italic, "italic is another face")
	g0 := font.glyph(fs, upright, 32, 'l')
	g1 := font.glyph(fs, italic, 32, 'l')
	testing.expectf(t, g1.size.x > g0.size.x + 2, "the italic l leans: ink %v wide, upright %v", g1.size.x, g0.size.x)
}
