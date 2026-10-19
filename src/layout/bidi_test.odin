package layout

import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import "wb:dom"
import "wb:html"
import "wb:style"

// Bidi in inline layout with a stand-in for UAX #9 (Hebrew letters are strong right to left, Latin letters strong left
// to right, spaces and digits take the level of the run around them): fragments split at level changes, lines
// reordered (L2), atomic inlines follow, `direction: rtl` paragraphs, dictionary line breaks. Characters are 0.5 em.

@(private = "file")
Bfx :: struct {
	doc: ^dom.Document,
	eng: ^style.Engine,
	st:  ^style.Styled,
	set: Settings,
	l:   Layout,
}

@(private = "file")
is_hebrew :: proc(r: rune) -> bool { return r >= 0x05D0 && r <= 0x05EA }

// Levels: strong characters their own level, everything else the level of the previous strong character (the next one
// at the start). Embedding / isolate controls are ignored: enough for these tests.
@(private = "file")
fake_bidi :: proc(user: rawptr, text: string, rtl: bool, levels: []u8) {
	base := u8(rtl ? 1 : 0)
	strong := make([]i8, len(text), context.temp_allocator)   // -1 neutral, else level
	for r, i in text {
		n := utf8.rune_size(r)
		v := i8(-1)
		if is_hebrew(r) { v = 1 } else if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') { v = i8(rtl ? 2 : 0) }
		for k in 0 ..< n { strong[i + k] = v }
	}
	last := i8(-1)
	for i in 0 ..< len(text) {
		if strong[i] >= 0 { last = strong[i] }
		levels[i] = last >= 0 ? u8(last) : base
	}
	// leading neutrals: the first strong level, else the base
	first := i8(-1)
	for v in strong { if v >= 0 { first = v; break } }
	for i in 0 ..< len(text) {
		if strong[i] >= 0 { break }
		levels[i] = first >= 0 ? u8(first) : base
	}
	// a neutral between two runs of different levels takes the base level (N1 / N2, roughly)
	for i in 0 ..< len(text) {
		if strong[i] >= 0 { continue }
		prev, next := i8(-1), i8(-1)
		for j := i - 1; j >= 0; j -= 1 { if strong[j] >= 0 { prev = strong[j]; break } }
		for j in i + 1 ..< len(text) { if strong[j] >= 0 { next = strong[j]; break } }
		if prev >= 0 && next >= 0 && prev != next { levels[i] = base }
	}
}

@(private = "file")
b_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font { return Font(1) }
@(private = "file")
b_width :: proc(user: rawptr, f: Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(rune_count(text)) }
@(private = "file")
b_metrics :: proc(user: rawptr, f: Font, size: f32) -> Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }
// Thai stand-in dictionary: a break every 3 characters
@(private = "file")
b_break :: proc(user: rawptr, text: string) -> int {
	n := 0
	for _, i in text {
		if n == 3 { return i }
		n += 1
	}
	return -1
}

@(private = "file")
bload :: proc(src: string, vw: f32 = 800) -> ^Bfx {
	f := new(Bfx)
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	ss := style.settings_default()
	f.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	f.set = settings_default()
	api := Text_Api{font = b_font, width = b_width, metrics = b_metrics, bidi = fake_bidi, line_break = b_break}
	run(&f.l, Input{doc = f.doc, styled = f.st, settings = &f.set, text = api, viewport = {vw, 600}, scale = 1, band_h = 256})
	return f
}

@(private = "file")
bunload :: proc(f: ^Bfx) {
	destroy(&f.l)
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	free(f)
}

@(private = "file")
lines_of :: proc(f: ^Bfx, id: string) -> []Line {
	bi := box_index(&f.l, dom.find_by_id(f.doc, id))
	if bi == NONE { return nil }
	b := &f.l.boxes[bi]
	return f.l.lines[b.lines[0]:b.lines[1]]
}

// The text fragments of a line, left to right on screen.
@(private = "file")
visual :: proc(f: ^Bfx, ln: Line) -> []Frag {
	out := make([dynamic]Frag, context.temp_allocator)
	for i in ln.frags[0] ..< ln.frags[1] { if f.l.frags[i].kind == .Text || f.l.frags[i].kind == .Atomic { append(&out, f.l.frags[i]) } }
	for i in 1 ..< len(out) {
		v := out[i]
		j := i - 1
		for j >= 0 && out[j].x > v.x { out[j + 1] = out[j]; j -= 1 }
		out[j + 1] = v
	}
	return out[:]
}

@(test)
bidi_mixed_line :: proc(t: ^testing.T) {
	// abc אבג דהו def: the Hebrew words go right to left between the Latin ones
	f := bload(`<body style="margin:0;font-size:10px"><p id=p style="margin:0">abc &#x5D0;&#x5D1;&#x5D2; &#x5D3;&#x5D4;&#x5D5; def</p></body>`)
	defer bunload(f)
	ls := lines_of(f, "p")
	testing.expect_value(t, len(ls), 1)
	v := visual(f, ls[0])
	texts := make([dynamic]string, context.temp_allocator)
	for fr in v { append(&texts, fr.text) }
	testing.expectf(t, len(v) == 3, "fragments: %v", texts[:])
	if len(v) == 3 {
		testing.expect_value(t, v[0].text, "abc ")
		testing.expect_value(t, v[1].level, 1)
		testing.expect_value(t, v[1].text, "\u05D0\u05D1\u05D2 \u05D3\u05D4\u05D5")   // one run: shaped right to left as a whole
		testing.expect_value(t, v[2].text, " def")
		testing.expect(t, v[0].x == 0 && v[1].x == 20 && v[2].x == 55)
	}
}

@(test)
bidi_rtl_paragraph :: proc(t: ^testing.T) {
	// direction: rtl: the paragraph's runs go right to left, the line is aligned right (text-align: start)
	f := bload(`<body style="margin:0;font-size:10px"><p id=p dir=rtl style="margin:0;width:200px">&#x5D0;&#x5D1; abc &#x5D2;&#x5D3;</p></body>`)
	defer bunload(f)
	ls := lines_of(f, "p")
	testing.expect_value(t, len(ls), 1)
	v := visual(f, ls[0])
	testing.expect(t, len(v) >= 3)
	if len(v) >= 3 {
		// visually: גד abc אב (the first Hebrew word at the right)
		testing.expect(t, strings.contains(v[len(v) - 1].text, "\u05D0"))
		testing.expect(t, strings.contains(v[0].text, "\u05D2"))
		last := v[len(v) - 1]
		testing.expect(t, abs(last.x + last.w - 200) < 0.01, "not aligned to the right")
	}
}

@(test)
bidi_atomic_follows :: proc(t: ^testing.T) {
	// an inline-block between two Hebrew words stays between them (in the reversed run)
	f := bload(`<body style="margin:0;font-size:10px"><p id=p style="margin:0">ab &#x5D0;&#x5D1; <span id=k style="display:inline-block;width:30px;height:5px"></span> &#x5D2;&#x5D3;</p></body>`)
	defer bunload(f)
	ls := lines_of(f, "p")
	v := visual(f, ls[0])
	ki := -1
	for fr, i in v { if fr.kind == .Atomic { ki = i } }
	testing.expect(t, ki > 0 && ki < len(v) - 1)
	if ki > 0 && ki < len(v) - 1 {
		testing.expect(t, strings.contains(v[ki - 1].text, "\u05D2"), "the second Hebrew word should be left of the box")
	}
}

@(test)
dictionary_breaks :: proc(t: ^testing.T) {
	// a run without spaces in a script that needs a dictionary breaks where Text_Api.line_break says (every 3 here)
	f := bload(`<body style="margin:0;font-size:10px"><p id=p style="margin:0;width:20px">&#xE20;&#xE32;&#xE29;&#xE32;&#xE44;&#xE17;&#xE22;&#xE07;&#xE32;</p></body>`)
	defer bunload(f)
	ls := lines_of(f, "p")
	testing.expectf(t, len(ls) == 3, "%d lines", len(ls))
}
