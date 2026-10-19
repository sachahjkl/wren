package browser

import "core:strings"
import "core:testing"
import "toolkit:font"
import "wb:dom"
import "wb:html"
import lay "wb:layout"
import "wb:style"

// Layout with the real text stack (DirectWrite through page_text_api): fallback, bidi, and caret positions through
// the clusters of the shaped fragments.

@(private = "file")
Caret_Fx :: struct {
	fonts: font.State,
	doc:   ^dom.Document,
	eng:   ^style.Engine,
	st:    ^style.Styled,
	l:     Layout,
	m:     Measure,
	ss:    style.Settings,
}

@(private = "file")
cf_open :: proc(f: ^Caret_Fx, src: string) -> bool {
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
		text = page_text_api(&page_render.fonts, &f.m, &f.ss), viewport = {600, 400}, scale = 1, band_h = 256})
	return true
}

@(private = "file")
cf_close :: proc(f: ^Caret_Fx) {
	lay.destroy(&f.l)
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	style.settings_destroy(&f.ss)
	dom.document_destroy(f.doc)
	page_fonts_destroy(&page_render.fonts)
	font.destroy(&f.fonts)
}

@(private = "file")
text_items :: proc(f: ^Caret_Fx, needle: string) -> ^lay.Display_Item {
	for &it in f.l.items { if it.kind == .Text && strings.contains(it.text, needle) { return &it } }
	return nil
}

@(test)
caret_through_clusters :: proc(t: ^testing.T) {
	f := new(Caret_Fx)
	defer free(f)
	if !cf_open(f, `<body style="margin:0;font:20px 'Segoe UI'"><p>office \u2190 back</p><p>abc <span>&#x5E9;&#x5DC;&#x5D5;&#x5DD;</span> def</p></body>`) {
		testing.fail_now(t, "no Segoe UI")
	}
	defer cf_close(f)
	// left to right: carets grow with the index, hit testing finds them again
	it := text_items(f, "office")
	testing.expect(t, it != nil)
	if it != nil {
		prev := text_item_caret_x(&f.l, it, 0)
		for i in 1 ..= len(it.text) {
			if i < len(it.text) && it.text[i] & 0xC0 == 0x80 { continue }
			x := text_item_caret_x(&f.l, it, i)
			testing.expectf(t, x > prev, "caret %d not after %d", i, i - 1)
			testing.expect_value(t, text_item_hit(&f.l, it, x), i)
			prev = x
		}
		testing.expect(t, abs(text_item_caret_x(&f.l, it, len(it.text)) - it.rect.max.x) < 0.5)
	}
	// right to left: the caret before the first letter is at the right of the fragment, then goes left
	heb := text_items(f, "\u05E9")
	testing.expect(t, heb != nil)
	if heb != nil {
		testing.expect(t, heb.level & 1 == 1)
		x0 := text_item_caret_x(&f.l, heb, 0)
		x1 := text_item_caret_x(&f.l, heb, 2)
		testing.expect(t, x0 > x1)
		testing.expect(t, abs(x0 - heb.rect.max.x) < 0.5)
		testing.expect_value(t, text_item_offset(&f.l, heb), 0)
	}
}

// The selection's point -> (node, offset) goes through the shaped clusters (Text_Api.hit_index): in a right-to-left
// fragment the offsets grow leftwards, inside a ligature the characters share it, and every caret position maps back
// to its own offset. The layout's caret x (lay.item_caret_x) is the one of text_caret.odin.
@(test)
selection_positions_through_clusters :: proc(t: ^testing.T) {
	f := new(Caret_Fx)
	defer free(f)
	if !cf_open(f, `<body style="margin:0;font:20px 'Segoe UI'"><p id="a">office</p><p id="b">&#x633;&#x644;&#x627;&#x645; &#x639;&#x644;&#x64A;&#x643;&#x645;</p></body>`) {
		testing.fail_now(t, "no Segoe UI")
	}
	defer cf_close(f)
	api := page_text_api(&page_render.fonts, &f.m, &f.ss)
	for needle in ([]string{"office", "\u0633"}) {
		it := text_items(f, needle)
		testing.expect(t, it != nil)
		if it == nil { continue }
		node := it.node
		if n := dom.get(f.doc, node); n != nil && n.kind != .Text { node = n.first_child }
		y := (it.rect.min.y + it.rect.max.y) * 0.5
		for i in 0 ..= len(it.text) {
			if i < len(it.text) && it.text[i] & 0xC0 == 0x80 { continue }
			x := lay.item_caret_x(&f.l, it, i, api)
			testing.expectf(t, abs(it.rect.min.x + x - text_item_caret_x(&f.l, it, i)) < 0.01, "%q: layout and shell carets agree at %d", needle, i)
			pos, ok := lay.position_at(&f.l, f.doc, f.st, {it.rect.min.x + x, y}, {600, 400}, 0, api)
			testing.expect(t, ok && pos.node == node)
			want := text_item_offset(&f.l, it) + i
			// inside the ffi ligature the carets are shared out evenly: each still maps to its own offset
			testing.expectf(t, pos.offset == want, "%q: the caret of offset %d hit-tests to %d", needle, want, pos.offset)
		}
		if it.level & 1 == 1 {
			testing.expect(t, lay.item_caret_x(&f.l, it, 0, api) > lay.item_caret_x(&f.l, it, len(it.text), api), "right to left: the start is on the right")
		}
	}
}