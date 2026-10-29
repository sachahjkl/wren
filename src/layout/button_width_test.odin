package layout

import "core:testing"
import "wb:dom"
import "wb:html"
import "wb:style"

@(private = "file")
fake_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font { return Font(1) }
@(private = "file")
fake_width :: proc(user: rawptr, f: Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(rune_count(text)) }
@(private = "file")
fake_metrics :: proc(user: rawptr, f: Font, size: f32) -> Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }

// A <button> whose width is auto is as wide as its content, also when the page makes it a block or a flex container
// (HTML §15.5.x); a <div> of the same display fills its line.
@(test)
button_auto_width_is_fit_content :: proc(t: ^testing.T) {
	src := `<body style="margin:0"><div style="width:400px">
<button id=f style="display:flex;margin:0 auto;padding:0;border:0">Search</button>
<button id=b style="display:block;padding:0;border:0">Search</button>
<div id=d style="display:flex">Search</div></div></body>`
	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	html.parse_into(doc, doc.root, transmute([]byte)src, 2_000_000)
	ss := style.settings_default()
	eng := style.engine_make(ss)
	style.settings_destroy(&ss)
	defer style.engine_destroy(eng)
	style.sync_document_sheets(eng, doc, "about:test")
	st := style.compute_styles(eng, doc, {})
	defer style.styled_destroy(st)
	set := settings_default()
	l: Layout
	defer destroy(&l)
	run(&l, Input{doc = doc, styled = st, settings = &set, text = Text_Api{font = fake_font, width = fake_width, metrics = fake_metrics}, viewport = {800, 600}, scale = 1, band_h = 256})
	f, _ := box_of(&l, dom.find_by_id(doc, "f"), {800, 600}, 0)
	b, _ := box_of(&l, dom.find_by_id(doc, "b"), {800, 600}, 0)
	d, _ := box_of(&l, dom.find_by_id(doc, "d"), {800, 600}, 0)
	testing.expect(t, f.border.max.x - f.border.min.x < 100, "button, display: flex: its content")
	testing.expect(t, b.border.max.x - b.border.min.x < 100, "button, display: block: its content")
	testing.expect_value(t, d.border.max.x - d.border.min.x, f32(400))
	testing.expect(t, f.border.min.x > 100, "the auto margins center the button")
}
