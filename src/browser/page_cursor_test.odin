package browser

import "core:testing"
import "toolkit:font"
import "toolkit:platform"
import "wb:base"
import "wb:dom"
import "wb:html"
import lay "wb:layout"
import "wb:style"

// The page's cursor at a point: the computed `cursor` of what the hit test finds (inherited), `auto` resolved as
// Chromium does, images and their fallback (page_cursor.odin).

@(private = "file")
Cursor_Fx :: struct {
	fonts: font.State,
	doc:   ^dom.Document,
	eng:   ^style.Engine,
	st:    ^style.Styled,
	l:     Layout,
	m:     Measure,
	ss:    style.Settings,
}

@(private = "file")
fx_open :: proc(f: ^Cursor_Fx, src: string) -> bool {
	font.init(&f.fonts)
	ui, ok := font.load_system(&f.fonts, "Segoe UI")
	if !ok { return false }
	page_fonts_init(&page_render.fonts, &f.fonts, ui)
	page_render.settings = lay.settings_default()
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	f.ss = style.settings_default()
	f.eng = style.engine_make(f.ss)
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	lay.run(&f.l, lay.Input{doc = f.doc, styled = f.st, settings = &page_render.settings,
		text = page_text_api(&page_render.fonts, &f.m, &f.ss), viewport = {600, 1000}, scale = 1, band_h = 256})
	return true
}

@(private = "file")
fx_close :: proc(f: ^Cursor_Fx) {
	lay.destroy(&f.l)
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	style.settings_destroy(&f.ss)
	dom.document_destroy(f.doc)
	page_fonts_destroy(&page_render.fonts)
	font.destroy(&f.fonts)
}

// The center of the first box of element #id.
@(private = "file")
center_of :: proc(f: ^Cursor_Fx, id: string) -> [2]f32 {
	h := dom.find_by_id(f.doc, id)
	for it in f.l.items {
		if it.node == h && (it.kind == .Box || it.kind == .Control || it.kind == .Replaced) { return (it.rect.min + it.rect.max) * 0.5 }
	}
	for it in f.l.items { if it.node == h { return (it.rect.min + it.rect.max) * 0.5 } }
	return {-1, -1}
}

// A point on the text of element #id (its first text item).
@(private = "file")
text_of :: proc(f: ^Cursor_Fx, id: string) -> [2]f32 {
	h := dom.find_by_id(f.doc, id)
	for it in f.l.items { if it.node == h && it.kind == .Text { return (it.rect.min + it.rect.max) * 0.5 } }
	return {-1, -1}
}

@(private = "file")
at :: proc(f: ^Cursor_Fx, p: [2]f32, css := true) -> Page_Cursor {
	return page_cursor_at(&f.l, f.doc, f.st, p, {600, 1000}, 0, css)
}

PAGE_CURSOR_HTML :: `<!doctype html><html><head><style>
body { margin: 0; font: 16px "Segoe UI"; }
div.b { height: 30px; }
#ptr { cursor: pointer; }
#kid { }
#none { cursor: none; }
#img { cursor: url(a.png) 4 5, image-set("b.png" 1x, "b2.png" 2x), grab; }
#ns { user-select: none; }
#under { position: relative; height: 40px; cursor: copy; }
#over { position: absolute; inset: 0; pointer-events: none; cursor: wait; }
#hid { visibility: hidden; height: 20px; cursor: help; }
#scroller { height: 40px; overflow: auto; cursor: help; }
</style></head><body>
<div class="b" id="ptr"><span id="kid">inherited pointer</span></div>
<div class="b" id="none">hidden</div>
<div class="b" id="img">image</div>
<p id="text">Some selectable text</p>
<p id="ns">Text that cannot be selected</p>
<p><a id="link" href="x">a link</a></p>
<input id="field" value="a field"> <input id="check" type="checkbox"> <button id="btn">button</button>
<select id="sel"><option>one</option></select> <input id="range" type="range">
<textarea id="area">area</textarea>
<div id="ce" contenteditable="true" style="height: 30px"><span id="ce_kid">editable</span></div>
<div id="ce_off" contenteditable="false" style="height: 20px">not editable</div>
<div id="under"><div id="over">over</div></div>
<div id="empty" style="height: 30px"></div>
<div id="scroller"><div style="height: 300px">tall</div></div>
<p id="gap" style="width: 160px; line-height: 3">words that wrap on several lines here</p>
</body></html>`

@(test)
page_cursor_resolution :: proc(t: ^testing.T) {
	page_render_test_lock()
	defer page_render_test_unlock()
	f: Cursor_Fx
	if !fx_open(&f, PAGE_CURSOR_HTML) { return }
	defer fx_close(&f)
	expect_at :: proc(t: ^testing.T, f: ^Cursor_Fx, p: [2]f32, want: platform.Cursor, what: string, loc := #caller_location) {
		pc := at(f, p)
		testing.expectf(t, pc.keyword == want, "%s at %v: %v, want %v", what, p, pc.keyword, want, loc = loc)
	}
	expect_at(t, &f, text_of(&f, "kid"), .Hand, "pointer inherited by a span's text")
	expect_at(t, &f, center_of(&f, "none"), .None, "cursor: none")
	expect_at(t, &f, text_of(&f, "text"), .Text, "auto over selectable text: the I-beam")
	expect_at(t, &f, center_of(&f, "text") + {250, 0}, .Arrow, "auto past the end of the text: the arrow")
	expect_at(t, &f, text_of(&f, "ns"), .Arrow, "user-select: none: the arrow")
	expect_at(t, &f, text_of(&f, "link"), .Hand, "a link: the hand (UA sheet)")
	expect_at(t, &f, center_of(&f, "field"), .Text, "a text field")
	expect_at(t, &f, center_of(&f, "area"), .Text, "a textarea")
	expect_at(t, &f, center_of(&f, "check"), .Arrow, "a checkbox")
	expect_at(t, &f, center_of(&f, "btn"), .Arrow, "a button (its text too)")
	expect_at(t, &f, text_of(&f, "btn"), .Arrow, "a button's text")
	expect_at(t, &f, center_of(&f, "sel"), .Arrow, "a select")
	expect_at(t, &f, center_of(&f, "range"), .Arrow, "a range")
	expect_at(t, &f, center_of(&f, "ce") + {200, 0}, .Text, "contenteditable: the I-beam over its empty part too")
	expect_at(t, &f, text_of(&f, "ce_kid"), .Text, "inside contenteditable")
	expect_at(t, &f, center_of(&f, "ce_off") + {250, 0}, .Arrow, "contenteditable=false")
	expect_at(t, &f, center_of(&f, "under"), .Copy, "pointer-events: none lets the point through")
	expect_at(t, &f, center_of(&f, "empty"), .Arrow, "an empty block: auto, the arrow")
	expect_at(t, &f, {300, 990}, .Arrow, "below the content: the root's cursor (auto)")
	// between two lines of text: the I-beam still (Chromium's line boxes); past the lines' ends, the arrow
	{
		g := dom.find_by_id(f.doc, "gap")
		first, second := -1, -1
		for it, i in f.l.items {
			if it.node != g || it.kind != .Text { continue }
			if first < 0 { first = i } else if second < 0 && it.rect.min.y > f.l.items[first].rect.max.y { second = i }
		}
		if first >= 0 && second >= 0 {
			a, b := f.l.items[first].rect, f.l.items[second].rect
			mid := [2]f32{a.min.x + 4, (a.max.y + b.min.y) * 0.5}
			testing.expectf(t, b.min.y - a.max.y > 4, "a real gap between the lines (%v %v)", a, b)
			expect_at(t, &f, mid, .Text, "between two lines")
		} else {
			testing.expect(t, false, "the paragraph wraps")
		}
	}
	// css off: every cursor is auto's
	pc := at(&f, text_of(&f, "kid"), false)
	testing.expectf(t, pc.keyword == .Text && pc.images == nil, "page cursors off: auto's I-beam over text (%v)", pc.keyword)
	// images and their fallback
	pc = at(&f, center_of(&f, "img"))
	testing.expect(t, pc.keyword == .Grab && len(pc.images) == 2, "url() and image-set() before the keyword")
	if len(pc.images) == 2 {
		testing.expect(t, pc.images[0].has_hotspot && pc.images[0].hotspot == {4, 5} && pc.images[0].srcs[0].url == "a.png", "url() with its hotspot")
		src, ok := style.cursor_image_pick(pc.images[1], 1.5)
		testing.expect(t, ok && src.url == "b2.png" && src.density == 2, "image-set: 2x for a 1.5 dppx screen")
		src, ok = style.cursor_image_pick(pc.images[1], 1)
		testing.expect(t, ok && src.url == "b.png", "image-set: 1x for a 1 dppx screen")
	}
	// the scroll container's bar: the arrow, whatever the CSS says
	sc := dom.find_by_id(f.doc, "scroller")
	found := false
	for it in f.l.items {
		if it.kind == .Scrollbar && it.node == sc {
			found = true
			expect_at(t, &f, (it.rect.min + it.rect.max) * 0.5, .Arrow, "over a scroll bar")
		}
	}
	if found { expect_at(t, &f, center_of(&f, "scroller") - {100, 0}, .Help, "the scroll box itself") }
	_ = base.NIL_HANDLE
}

@(test)
page_cursor_keywords :: proc(t: ^testing.T) {
	// every CSS keyword names a cursor of the toolkit with the same name (auto: the arrow until resolved)
	for k in style.Cursor {
		c := cursor_of_keyword(k)
		if k == .Auto { testing.expect(t, c == .Arrow); continue }
		testing.expectf(t, platform.cursor_css_name(c) == style.cursor_keyword_name(k), "%v -> %v", k, c)
	}
}
