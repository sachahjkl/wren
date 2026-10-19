package layout

import "core:math"
import "core:testing"
import "wb:dom"
import "wb:html"
import "wb:style"

// Layout behaviour real sites depend on: replaced elements that keep their ratio under max-width (Tailwind's
// `img { max-width: 100%; height: auto }`), size containment of query containers.

@(private = "file")
fake_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font { return Font(1) }
@(private = "file")
fake_width :: proc(user: rawptr, f: Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(rune_count(text)) }
@(private = "file")
fake_metrics :: proc(user: rawptr, f: Font, size: f32) -> Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }

@(private = "file")
with_layout :: proc(t: ^testing.T, src: string, check: proc(t: ^testing.T, l: ^Layout, doc: ^dom.Document)) {
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
	check(t, &l, doc)
}

@(private = "file")
size_of_el :: proc(l: ^Layout, doc: ^dom.Document, id: string) -> [2]f32 {
	r, ok := box_of(l, dom.find_by_id(doc, id), {800, 600}, 0)
	if !ok { return {-1, -1} }
	return r.border.max - r.border.min
}

@(test)
replaced_ratio_under_limits :: proc(t: ^testing.T) {
	with_layout(t, `<body style="margin:0">
		<img id=a width=1000 height=1305 style="display:block;width:100%;max-width:200px;height:auto">
		<img id=b width=1000 height=500 style="display:block;max-width:100px">
		<img id=c width=100 height=50 style="display:block;min-height:100px">
		<img id=d width=1000 height=1000 style="display:block;max-width:300px;max-height:100px">
		<img id=e width=400 height=200 style="display:block;height:100px;max-width:150px">
	</body>`, proc(t: ^testing.T, l: ^Layout, doc: ^dom.Document) {
		near :: proc(a, b: [2]f32) -> bool { return math.abs(a.x - b.x) < 0.6 && math.abs(a.y - b.y) < 0.6 }
		testing.expectf(t, near(size_of_el(l, doc, "a"), {200, 261}), "width 100%% clamped by max-width: the height follows (%v)", size_of_el(l, doc, "a"))
		testing.expectf(t, near(size_of_el(l, doc, "b"), {100, 50}), "natural size over max-width (%v)", size_of_el(l, doc, "b"))
		testing.expectf(t, near(size_of_el(l, doc, "c"), {200, 100}), "natural size under min-height (%v)", size_of_el(l, doc, "c"))
		testing.expectf(t, near(size_of_el(l, doc, "d"), {100, 100}), "both over their maximum (%v)", size_of_el(l, doc, "d"))
		testing.expectf(t, near(size_of_el(l, doc, "e"), {150, 100}), "a given height, the width clamped (%v)", size_of_el(l, doc, "e"))
	})
}

@(test)
size_containment_inline_axis :: proc(t: ^testing.T) {
	with_layout(t, `<body style="margin:0;font-size:10px">
		<div id=a style="display:inline-block;container-type:inline-size;padding:0 3px">some text inside</div>
		<div id=b style="display:inline-block;padding:0 3px">some text inside</div>
		<div id=c style="display:inline-block;contain:inline-size;width:40px">some text</div>
	</body>`, proc(t: ^testing.T, l: ^Layout, doc: ^dom.Document) {
		testing.expectf(t, size_of_el(l, doc, "a").x == 6, "an inline-size container shrinks as if empty (%v)", size_of_el(l, doc, "a"))
		testing.expectf(t, size_of_el(l, doc, "b").x == 86, "without containment it fits its text (%v)", size_of_el(l, doc, "b"))
		testing.expect(t, size_of_el(l, doc, "c").x == 40, "a given width stays")
	})
}
