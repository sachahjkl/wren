package reftest

import "core:strings"
import "core:testing"
import "wb:dom"
import "wb:html"
import lay "wb:layout"
import "wb:style"

// The fuzzy annotations and links as WPT's manifest reads them, WPT's comparison, the PNG writer, and the rasteriser from
// real markup through style and layout to pixels.

@(private = "file")
TEST_W :: 200
@(private = "file")
TEST_H :: 150
@(private = "file")
RED := [3]u8{255, 0, 0}
@(private = "file")
GREEN := [3]u8{0, 128, 0}
@(private = "file")
LIME := [3]u8{0, 255, 0}
@(private = "file")
BLUE := [3]u8{0, 0, 255}
@(private = "file")
WHITE := [3]u8{255, 255, 255}
@(private = "file")
BLACK := [3]u8{0, 0, 0}

////////////////////////////////
// Scanning

@(test)
fuzzy_named_and_positional :: proc(t: ^testing.T) {
	f, ok := parse_fuzzy("maxDifference=15-30;totalPixels=300-1000", "/a/b.html", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, f.url, "")
	testing.expect_value(t, f.max_difference, [2]int{15, 30})
	testing.expect_value(t, f.total_pixels, [2]int{300, 1000})
	f, ok = parse_fuzzy("totalPixels=1-2; maxDifference=3-4", "/a/b.html", context.temp_allocator)
	testing.expect(t, ok, "in any order")
	testing.expect_value(t, f.max_difference, [2]int{3, 4})
	testing.expect_value(t, f.total_pixels, [2]int{1, 2})
	f, ok = parse_fuzzy("10-15;200-300", "/a/b.html", context.temp_allocator)
	testing.expect(t, ok, "by position")
	testing.expect_value(t, f.max_difference, [2]int{10, 15})
	testing.expect_value(t, f.total_pixels, [2]int{200, 300})
	f, ok = parse_fuzzy("15;300", "/a/b.html", context.temp_allocator)
	testing.expect(t, ok, "single values")
	testing.expect_value(t, f.max_difference, [2]int{15, 15})
	testing.expect_value(t, f.total_pixels, [2]int{300, 300})
	f, ok = parse_fuzzy("totalPixels=5;0-2", "/a/b.html", context.temp_allocator)
	testing.expect(t, ok, "one named, one by position")
	testing.expect_value(t, f.max_difference, [2]int{0, 2})
	testing.expect_value(t, f.total_pixels, [2]int{5, 5})
}

@(test)
fuzzy_for_one_reference :: proc(t: ^testing.T) {
	f, ok := parse_fuzzy("option1-ref.html:10-15;200-300", "/a/b.html", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, f.url, "/a/option1-ref.html")
	testing.expect_value(t, f.max_difference, [2]int{10, 15})
	f, ok = parse_fuzzy("../ref.html:maxDifference=1;totalPixels=2", "/a/b/c.html", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, f.url, "/a/ref.html")
	info := Page_Info{fuzzy = []Fuzzy{{url = "/x.html", total_pixels = {1, 1}}, {total_pixels = {2, 2}}}}
	got, has := fuzzy_for(&info, "/x.html")
	testing.expect(t, has)
	testing.expect_value(t, got.total_pixels, [2]int{1, 1})
	got, has = fuzzy_for(&info, "/y.html")
	testing.expect(t, has, "the page's general one")
	testing.expect_value(t, got.total_pixels, [2]int{2, 2})
}

@(test)
fuzzy_invalid :: proc(t: ^testing.T) {
	for s in ([]string{"", "5", "1;2;3", "nope=1;2", "maxDifference=1;maxDifference=2", "a;b", "3-1;4"}) {
		_, ok := parse_fuzzy(s, "/a.html", context.temp_allocator)
		testing.expectf(t, !ok, "%q is not valid", s)
	}
}

@(test)
paths_resolve :: proc(t: ^testing.T) {
	a := context.temp_allocator
	testing.expect_value(t, resolve_path("/css/x/t.html", "ref.html", a), "/css/x/ref.html")
	testing.expect_value(t, resolve_path("/css/x/t.html?a=1", "reference/r.htm", a), "/css/x/reference/r.htm")
	testing.expect_value(t, resolve_path("/css/x/t.html", "../../css/reference/g.xht", a), "/css/reference/g.xht")
	testing.expect_value(t, resolve_path("/css/x/t.html", "/fonts/a.html#f", a), "/fonts/a.html")
	testing.expect_value(t, resolve_path("/css/x/t.html", "r.html?q=1", a), "/css/x/r.html?q=1")
	testing.expect_value(t, resolve_path("/css/x/t.html", "http://web-platform.test:8000/a/b.html", a), "/a/b.html")
}

@(test)
page_links_and_metas :: proc(t: ^testing.T) {
	src := `<!DOCTYPE html>
<html class="reftest-wait">
<!-- <link rel="match" href="commented.html"> -->
<title>a <link rel=match href=not-a-link.html> title</title>
<link rel="author" href="mailto:x@y">
<link rel="match" href="one-ref.html">
<LINK HREF='../two-ref.html' REL=mismatch />
<link rel=match href=three-ref.html>
<meta name="fuzzy" content="maxDifference=1-2;totalPixels=3-4">
<meta content="one-ref.html:5;6" name=fuzzy>
<meta name=viewport-size content="400x300">
<script>document.write('<link rel="match" href="scripted.html">')</script>
<style>a { content: '<link rel=match href=styled.html>' }</style>
<body>x</body>`
	info := scan_page(src, "/f/t.html", context.temp_allocator)
	testing.expect_value(t, len(info.refs), 3)
	if len(info.refs) == 3 {
		testing.expect_value(t, info.refs[0], Ref_Link{.Match, "/f/one-ref.html"})
		testing.expect_value(t, info.refs[1], Ref_Link{.Mismatch, "/two-ref.html"})
		testing.expect_value(t, info.refs[2], Ref_Link{.Match, "/f/three-ref.html"})
	}
	testing.expect_value(t, len(info.fuzzy), 2)
	testing.expect_value(t, info.viewport, [2]int{400, 300})
	testing.expect(t, !info.paged)
	testing.expect(t, scan_page(`<meta name="reftest-pages" content="1">`, "/a", context.temp_allocator).paged)
	testing.expect_value(t, len(scan_page(`<div rel="match" href="x">`, "/a", context.temp_allocator).refs), 0)
}

@(test)
names_as_wpt_has_them :: proc(t: ^testing.T) {
	for p in ([]string{"/a/reference/x.html", "/a/x-ref.html", "/a/ref-x.html", "/a/x-ref2.xht", "/a/x-notref.html", "/a/x_ref_y.html", "/a/ref.html"}) {
		testing.expectf(t, is_reference_name(p), "%s is a reference", p)
	}
	for p in ([]string{"/a/x.html", "/a/reflow-001.html", "/a/preference.html", "/a/x-refs.html", "/references/x.html"}) {
		testing.expectf(t, !is_reference_name(p), "%s is no reference", p)
	}
	for p in ([]string{"/a/x-print.html", "/a/print/y.html", "/a/x-print.sub.html", "/a/x-visual.html"}) {
		testing.expectf(t, is_unmeasured_name(p), "%s is not measured", p)
	}
	for p in ([]string{"/a/x.html", "/a/printing.html", "/a/print-x.html"}) {
		testing.expectf(t, !is_unmeasured_name(p), "%s is measured", p)
	}
}

////////////////////////////////
// Comparing

@(private = "file")
solid_image :: proc(w, h: int, c: [3]u8) -> Image {
	img := image_make(w, h, context.temp_allocator)
	for i := 0; i < len(img.rgba); i += CHANNELS { img.rgba[i], img.rgba[i + 1], img.rgba[i + 2], img.rgba[i + 3] = c.r, c.g, c.b, 255 }
	return img
}

@(test)
compare_counts :: proc(t: ^testing.T) {
	a, b := solid_image(4, 4, {10, 20, 30}), solid_image(4, 4, {10, 20, 30})
	testing.expect_value(t, compare(&a, &b), Difference{})
	b.rgba[0] = 15
	b.rgba[CHANNELS + 2] = 33
	d := compare(&a, &b)
	testing.expect_value(t, d, Difference{max_channel = 5, pixels = 2})
	c := solid_image(5, 4, {10, 20, 30})
	testing.expect_value(t, compare(&a, &c).pixels, 20)
}

@(test)
fuzzy_rules :: proc(t: ^testing.T) {
	none := Fuzzy{}
	testing.expect(t, considered_equal({}, none, false))
	testing.expect(t, !considered_equal({1, 1}, none, false), "exact without an annotation")
	f := Fuzzy{max_difference = {10, 20}, total_pixels = {100, 200}}
	testing.expect(t, considered_equal({15, 150}, f, true))
	testing.expect(t, considered_equal({10, 100}, f, true), "inclusive")
	testing.expect(t, considered_equal({20, 200}, f, true), "inclusive")
	testing.expect(t, !considered_equal({21, 150}, f, true))
	testing.expect(t, !considered_equal({15, 99}, f, true), "too few pixels differ: the annotation says how many must")
	testing.expect(t, !considered_equal({}, f, true), "and that some must")
	g := Fuzzy{max_difference = {0, 5}, total_pixels = {0, 10}}
	testing.expect(t, considered_equal({}, g, true), "a range from 0 admits none")
	testing.expect(t, considered_equal({5, 10}, g, true))
	testing.expect(t, !considered_equal({6, 10}, g, true))
}

@(test)
difference_marks_what_differs :: proc(t: ^testing.T) {
	a, b := solid_image(2, 1, {0, 0, 0}), solid_image(2, 1, {0, 0, 0})
	b.rgba[CHANNELS] = 200
	d := difference_image(&a, &b, context.temp_allocator)
	testing.expect_value(t, pixel(&d, 1, 0), RED)
	testing.expect(t, pixel(&d, 0, 0) != RED)
}

////////////////////////////////
// Text cells

@(test)
patterns_of_characters :: proc(t: ^testing.T) {
	seen := make(map[u32]rune, context.temp_allocator)
	for r in rune(0x20) ..< rune(0x3000) {
		p := pattern_of(r, false, false)
		_, dup := seen[p]
		testing.expectf(t, !dup, "the pattern of U+%04X is another's", r)
		seen[p] = r
		testing.expect(t, p & 1 != 0, "the top-left square is set")
		testing.expect(t, p >> 31 == 0, "the bottom-right is not")
	}
	testing.expect(t, pattern_of('a', true, false) != pattern_of('a', false, false), "a weight shows")
	testing.expect(t, pattern_of('a', false, true) != pattern_of('a', false, false), "a slant shows")
}

@(test)
rotated_cell_parts :: proc(t: ^testing.T) {
	c := Cell{lay.Rect{{10, 20}, {30, 60}}, .Upright}
	testing.expect_value(t, cell_part(c, 0.5, 0, 1, 0.5), lay.Rect{{20, 20}, {30, 40}})
	c.frame = .Rotated_Cw
	// what is at the top of the glyph is at the right, and its writing direction goes down
	testing.expect_value(t, cell_part(c, 0, 0, 0.5, 0.5), lay.Rect{{20, 20}, {30, 40}})
	testing.expect_value(t, cell_part(c, 0.5, 0.5, 1, 1), lay.Rect{{10, 40}, {20, 60}})
}

////////////////////////////////
// From markup to pixels

@(private = "file")
Page :: struct {
	doc: ^dom.Document,
	eng: ^style.Engine,
	st:  ^style.Styled,
	set: lay.Settings,
	l:   lay.Layout,
}

@(private = "file")
text_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> lay.Font {
	return len(families) > 0 && strings.equal_fold(families[0], "Ahem") ? AHEM_FONT : OTHER_FONT
}
@(private = "file")
text_width :: proc(user: rawptr, f: lay.Font, size: f32, text: string) -> f32 { return font_advance(f, size) * f32(strings.rune_count(text)) }
@(private = "file")
text_metrics :: proc(user: rawptr, f: lay.Font, size: f32) -> lay.Font_Metrics {
	m := lay.Font_Metrics{ascent = ASCENT_EM * size, descent = DESCENT_EM * size, x_height = size * OTHER_ADVANCE_EM}
	if f == AHEM_FONT { m.line_height = size }
	return m
}

@(private = "file")
page_load :: proc(src: string) -> ^Page {
	p := new(Page)
	p.doc = dom.document_create(nil)
	html.parse_into(p.doc, p.doc.root, transmute([]byte)src, len(src) + 1)
	ss := style.settings_default()
	p.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.sync_document_sheets(p.eng, p.doc, "about:test")
	p.st = style.compute_styles(p.eng, p.doc, {})
	p.set = lay.settings_default()
	lay.run(&p.l, lay.Input{doc = p.doc, styled = p.st, settings = &p.set, text = {font = text_font, width = text_width, metrics = text_metrics}, viewport = {TEST_W, TEST_H}, scale = 1, band_h = 256})
	return p
}

@(private = "file")
page_unload :: proc(p: ^Page) {
	lay.destroy(&p.l)
	style.styled_destroy(p.st)
	style.engine_destroy(p.eng)
	dom.document_destroy(p.doc)
	free(p)
}

// The picture of markup, in temp memory.
@(private = "file")
draw_page :: proc(src: string, host: ^Host = nil) -> Image {
	p := page_load(src)
	defer page_unload(p)
	return render(&p.l, TEST_W, TEST_H, 0, p.l.canvas, host, context.temp_allocator).image
}

@(private = "file")
pixel :: proc(img: ^Image, x, y: int) -> [3]u8 {
	o := (y * img.width + x) * CHANNELS
	return {img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]}
}

@(private = "file")
same_page :: proc(a, b: string) -> bool {
	x, y := draw_page(a), draw_page(b)
	return compare(&x, &y).pixels == 0
}

@(test)
canvas_and_backgrounds :: proc(t: ^testing.T) {
	img := draw_page(`<!DOCTYPE html><html style="background: lime"><body style="margin: 0"><div style="position: absolute; left: 10px; top: 20px; width: 30px; height: 40px; background: red"></div>`)
	testing.expect_value(t, pixel(&img, 0, 0), LIME)
	testing.expect_value(t, pixel(&img, TEST_W - 1, TEST_H - 1), LIME)
	testing.expect_value(t, pixel(&img, 10, 20), RED)
	testing.expect_value(t, pixel(&img, 39, 59), RED)
	testing.expect_value(t, pixel(&img, 9, 20), LIME)
	testing.expect_value(t, pixel(&img, 40, 20), LIME)
	testing.expect_value(t, pixel(&img, 10, 60), LIME)
	blank := draw_page(`<!DOCTYPE html><body>`)
	testing.expect_value(t, pixel(&blank, 5, 5), WHITE)
}

@(test)
edges_are_snapped :: proc(t: ^testing.T) {
	testing.expect(t, same_page(
		`<!DOCTYPE html><div style="position: absolute; left: 10.4px; top: 20.5px; width: 30px; height: 40px; background: red"></div>`,
		`<!DOCTYPE html><div style="position: absolute; left: 10px; top: 21px; width: 30px; height: 40px; background: red"></div>`))
}

@(test)
opacity_group :: proc(t: ^testing.T) {
	img := draw_page(`<!DOCTYPE html><body style="margin: 0; background: white"><div style="opacity: 0.5; width: 50px; height: 50px; background: blue"><div style="width: 25px; height: 25px; background: blue"></div></div>`)
	// the group composites once: what overlaps inside it is not darker
	testing.expect(t, pixel(&img, 10, 10) == pixel(&img, 40, 40))
	testing.expect_value(t, pixel(&img, 10, 10), [3]u8{128, 128, 255})
	testing.expect(t, same_page(
		`<!DOCTYPE html><body style="margin: 0"><div style="opacity: 0.5; width: 50px; height: 50px; background: blue"></div>`,
		`<!DOCTYPE html><body style="margin: 0"><div style="width: 50px; height: 50px; background: rgba(0, 0, 255, 0.5)"></div>`))
}

@(test)
clips_rect_and_rounded :: proc(t: ^testing.T) {
	img := draw_page(`<!DOCTYPE html><body style="margin: 0"><div style="width: 40px; height: 40px; overflow: hidden"><div style="width: 100px; height: 100px; background: red"></div></div>`)
	testing.expect_value(t, pixel(&img, 39, 39), RED)
	testing.expect_value(t, pixel(&img, 40, 10), WHITE)
	testing.expect_value(t, pixel(&img, 10, 40), WHITE)
	round := draw_page(`<!DOCTYPE html><body style="margin: 0"><div style="width: 40px; height: 40px; border-radius: 20px; overflow: hidden"><div style="width: 100px; height: 100px; background: red"></div></div>`)
	testing.expect_value(t, pixel(&round, 20, 20), RED)
	testing.expect_value(t, pixel(&round, 1, 1), WHITE)
	testing.expect_value(t, pixel(&round, 38, 38), WHITE)
	testing.expect_value(t, pixel(&round, 20, 1), RED)
}

@(test)
transforms :: proc(t: ^testing.T) {
	testing.expect(t, same_page(
		`<!DOCTYPE html><body style="margin: 0"><div style="transform: translate(30px, 10px); width: 40px; height: 20px; background: red"></div>`,
		`<!DOCTYPE html><body style="margin: 0"><div style="margin: 10px 0 0 30px; width: 40px; height: 20px; background: red"></div>`))
	// a quarter turn around the box's centre
	testing.expect(t, same_page(
		`<!DOCTYPE html><body style="margin: 0"><div style="transform: rotate(90deg); margin-left: 20px; width: 60px; height: 20px; background: red"></div>`,
		`<!DOCTYPE html><body style="margin: 0"><div style="position: absolute; left: 40px; top: -20px; width: 20px; height: 60px; background: red"></div>`))
	// a clip under a transform follows it
	turned := draw_page(`<!DOCTYPE html><body style="margin: 0"><div style="transform: translateX(50px); width: 20px; height: 20px; overflow: hidden"><div style="width: 80px; height: 80px; background: red"></div></div>`)
	testing.expect_value(t, pixel(&turned, 60, 10), RED)
	testing.expect_value(t, pixel(&turned, 75, 10), WHITE)
	testing.expect_value(t, pixel(&turned, 10, 10), WHITE)
}

@(test)
borders :: proc(t: ^testing.T) {
	sides := draw_page(`<!DOCTYPE html><body style="margin: 0"><div style="width: 20px; height: 20px; border: 10px solid; border-color: red lime blue green"></div>`)
	testing.expect_value(t, pixel(&sides, 20, 2), RED)
	testing.expect_value(t, pixel(&sides, 37, 20), LIME)
	testing.expect_value(t, pixel(&sides, 20, 37), BLUE)
	testing.expect_value(t, pixel(&sides, 2, 20), GREEN)
	testing.expect_value(t, pixel(&sides, 20, 20), WHITE)
	// sides meet on the diagonal
	testing.expect_value(t, pixel(&sides, 3, 1), RED)
	testing.expect_value(t, pixel(&sides, 1, 3), GREEN)
	double := draw_page(`<!DOCTYPE html><body style="margin: 0"><div style="width: 20px; height: 20px; border: 9px double red"></div>`)
	testing.expect_value(t, pixel(&double, 20, 1), RED)
	testing.expect_value(t, pixel(&double, 20, 4), WHITE)
	testing.expect_value(t, pixel(&double, 20, 7), RED)
	dashed := draw_page(`<!DOCTYPE html><body style="margin: 0"><div style="width: 100px; height: 20px; border-top: 4px dashed red"></div>`)
	seen_red, seen_white := false, false
	for x in 0 ..< 100 { if pixel(&dashed, x, 2) == RED { seen_red = true } else { seen_white = true } }
	testing.expect(t, seen_red && seen_white, "dashes and gaps")
	testing.expect_value(t, pixel(&dashed, 0, 2), RED)
	testing.expect_value(t, pixel(&dashed, 99, 2), RED)
	round := draw_page(`<!DOCTYPE html><body style="margin: 0"><div style="width: 40px; height: 40px; border: 5px solid red; border-radius: 25px"></div>`)
	testing.expect_value(t, pixel(&round, 25, 2), RED)
	testing.expect_value(t, pixel(&round, 1, 1), WHITE)
	testing.expect_value(t, pixel(&round, 25, 25), WHITE)
	outline := draw_page(`<!DOCTYPE html><body style="margin: 10px"><div style="width: 20px; height: 20px; outline: 2px solid blue; outline-offset: 1px"></div>`)
	testing.expect_value(t, pixel(&outline, 7, 15), BLUE)
	testing.expect_value(t, pixel(&outline, 9, 15), WHITE)
	testing.expect_value(t, pixel(&outline, 6, 15), WHITE)
}

@(test)
gradients :: proc(t: ^testing.T) {
	linear := draw_page(`<!DOCTYPE html><body style="margin: 0"><div style="width: 100px; height: 10px; background: linear-gradient(to right, red, blue)"></div>`)
	left, right, mid := pixel(&linear, 0, 5), pixel(&linear, 99, 5), pixel(&linear, 50, 5)
	testing.expect(t, left.r > 250 && left.b < 5)
	testing.expect(t, right.b > 250 && right.r < 5)
	testing.expect(t, mid.r > 110 && mid.r < 140 && mid.b > 110 && mid.b < 140)
	hard := draw_page(`<!DOCTYPE html><body style="margin: 0"><div style="width: 100px; height: 10px; background: linear-gradient(to right, red 50%, lime 50%)"></div>`)
	testing.expect_value(t, pixel(&hard, 49, 5), RED)
	testing.expect_value(t, pixel(&hard, 50, 5), LIME)
	radial := draw_page(`<!DOCTYPE html><body style="margin: 0"><div style="width: 100px; height: 100px; background: radial-gradient(circle closest-side, red, red 50%, blue 50%, blue)"></div>`)
	testing.expect_value(t, pixel(&radial, 50, 50), RED)
	testing.expect_value(t, pixel(&radial, 50, 5), BLUE)
	sized := draw_page(`<!DOCTYPE html><body style="margin: 0"><div style="width: 40px; height: 10px; background: linear-gradient(to right, red 50%, lime 50%) 0 0 / 20px 10px"></div>`)
	testing.expect_value(t, pixel(&sized, 5, 5), RED)
	testing.expect_value(t, pixel(&sized, 15, 5), LIME)
	testing.expect_value(t, pixel(&sized, 25, 5), RED)
	testing.expect_value(t, pixel(&sized, 35, 5), LIME)
}

@(test)
box_shadows :: proc(t: ^testing.T) {
	hard := draw_page(`<!DOCTYPE html><body style="margin: 0"><div style="width: 20px; height: 20px; box-shadow: 10px 5px 0 blue"></div>`)
	testing.expect_value(t, pixel(&hard, 25, 10), BLUE)
	testing.expect_value(t, pixel(&hard, 10, 10), WHITE)   // (under the box: cut out)
	testing.expect_value(t, pixel(&hard, 31, 10), WHITE)
	inset := draw_page(`<!DOCTYPE html><body style="margin: 0"><div style="width: 20px; height: 20px; box-shadow: inset 5px 0 0 blue"></div>`)
	testing.expect_value(t, pixel(&inset, 2, 10), BLUE)
	testing.expect_value(t, pixel(&inset, 10, 10), WHITE)
	blur := draw_page(`<!DOCTYPE html><body style="margin: 40px"><div style="width: 20px; height: 20px; box-shadow: 0 0 10px black"></div>`)
	near, far := pixel(&blur, 38, 50), pixel(&blur, 32, 50)
	testing.expect(t, near.r < far.r && far.r < 255, "a blur fades")
}

@(test)
inline_box_and_marker :: proc(t: ^testing.T) {
	img := draw_page(`<!DOCTYPE html><body style="margin: 0"><span style="font: 20px/20px Ahem; background: lime; color: transparent; border-left: 5px solid red">X</span>`)
	testing.expect_value(t, pixel(&img, 2, 10), RED)
	testing.expect_value(t, pixel(&img, 10, 10), LIME)
	marker := draw_page(`<!DOCTYPE html><body style="margin: 0"><ul style="margin: 0 0 0 40px; padding: 0; list-style: square inside; font: 16px/20px sans-serif; color: red"><li></li></ul>`)
	found := false
	for y in 0 ..< 30 { for x in 30 ..< 80 { if pixel(&marker, x, y) == RED { found = true } } }
	testing.expect(t, found, "a square bullet")
}

// Ahem at 20 px on a line of 20 px: the baseline at 16 px.
@(private = "file")
ahem_line :: proc(text: string) -> Image {
	return draw_page(strings.concatenate({`<!DOCTYPE html><body style="margin: 0"><div style="font: 20px/20px Ahem; color: red">`, text, `</div>`}, context.temp_allocator))
}

@(test)
ahem_glyphs :: proc(t: ^testing.T) {
	x := ahem_line("X")
	testing.expect_value(t, pixel(&x, 0, 0), RED)
	testing.expect_value(t, pixel(&x, 19, 19), RED)
	testing.expect_value(t, pixel(&x, 20, 10), WHITE)
	testing.expect_value(t, pixel(&x, 10, 20), WHITE)
	p := ahem_line("p")
	testing.expect_value(t, pixel(&p, 10, 15), WHITE)
	testing.expect_value(t, pixel(&p, 10, 16), RED)
	testing.expect_value(t, pixel(&p, 10, 19), RED)
	e := ahem_line("É")
	testing.expect_value(t, pixel(&e, 10, 15), RED)
	testing.expect_value(t, pixel(&e, 10, 16), WHITE)
	testing.expect_value(t, pixel(&e, 10, 0), RED)
	// the bars of U+03A5 and U+03A7, from Ahem.ttf: a fifth to two fifths of the em box
	v_bar := ahem_line("Υ")
	testing.expect_value(t, pixel(&v_bar, 3, 10), WHITE)
	testing.expect_value(t, pixel(&v_bar, 5, 10), RED)
	testing.expect_value(t, pixel(&v_bar, 8, 10), WHITE)
	h_bar := ahem_line("Χ")
	testing.expect_value(t, pixel(&h_bar, 10, 3), WHITE)
	testing.expect_value(t, pixel(&h_bar, 10, 5), RED)
	testing.expect_value(t, pixel(&h_bar, 10, 8), WHITE)
	two := ahem_line("X X")
	testing.expect_value(t, pixel(&two, 10, 10), RED)
	testing.expect_value(t, pixel(&two, 30, 10), WHITE)
	testing.expect_value(t, pixel(&two, 50, 10), RED)
}

@(test)
other_fonts :: proc(t: ^testing.T) {
	line :: proc(s: string) -> string {
		return strings.concatenate({`<!DOCTYPE html><body style="margin: 0"><div style="font: 32px/40px serif; color: black">`, s, `</div>`}, context.temp_allocator)
	}
	testing.expect(t, same_page(line("hello"), line("hello")), "the same text, the same pixels")
	testing.expect(t, !same_page(line("hello"), line("hellp")), "another character, other pixels")
	img := draw_page(line("a"))
	ink := false
	for y in 0 ..< 40 { for x in 0 ..< 16 { if pixel(&img, x, y) == BLACK { ink = true } } }
	testing.expect(t, ink)
	for y in 0 ..< 40 { for x in 16 ..< 32 { testing.expect_value(t, pixel(&img, x, y), WHITE) } }
}

// Layout makes no vertical text yet: an item of a horizontal run is turned into one, as Item_Flag.Vertical will come.
@(private = "file")
draw_vertical :: proc(src: string) -> Image {
	p := page_load(src)
	defer page_unload(p)
	for &it in p.l.items {
		if it.kind != .Text { continue }
		size := lay.item_font(&p.l, &it).size
		count := f32(strings.rune_count(it.text))
		adv := font_advance(lay.item_font(&p.l, &it).font, size)
		// a run from (50, 10) down, the baseline at x = 50
		it.rect = lay.Rect{{50 - DESCENT_EM * size, 10}, {50 + ASCENT_EM * size, 10 + adv * count}}
		it.baseline = 50
		it.flags += {.Vertical}
	}
	return render(&p.l, TEST_W, TEST_H, 0, p.l.canvas, nil, context.temp_allocator).image
}

@(test)
vertical_text :: proc(t: ^testing.T) {
	ahem :: proc(s: string) -> string {
		return strings.concatenate({`<!DOCTYPE html><body style="margin: 0"><div style="font: 20px/20px Ahem; color: red">`, s, `</div>`}, context.temp_allocator)
	}
	two := draw_vertical(ahem("XX"))
	// a quarter turn clockwise: the ascent (16 px) right of the baseline, the descent (4 px) left of it
	testing.expect_value(t, pixel(&two, 46, 10), RED)
	testing.expect_value(t, pixel(&two, 45, 10), WHITE)
	testing.expect_value(t, pixel(&two, 65, 10), RED)
	testing.expect_value(t, pixel(&two, 66, 10), WHITE)
	testing.expect_value(t, pixel(&two, 50, 49), RED)
	testing.expect_value(t, pixel(&two, 50, 50), WHITE)
	testing.expect_value(t, pixel(&two, 50, 9), WHITE)
	below := draw_vertical(ahem("p"))
	testing.expect_value(t, pixel(&below, 47, 20), RED)
	testing.expect_value(t, pixel(&below, 52, 20), WHITE)
	above := draw_vertical(ahem("É"))
	testing.expect_value(t, pixel(&above, 47, 20), WHITE)
	testing.expect_value(t, pixel(&above, 52, 20), RED)
	// another font: not the picture of an upright run, and characters still differ
	other :: proc(s: string) -> string {
		return strings.concatenate({`<!DOCTYPE html><body style="margin: 0"><div style="font: 32px/40px serif; color: black">`, s, `</div>`}, context.temp_allocator)
	}
	a, b := draw_vertical(other("a")), draw_vertical(other("b"))
	testing.expect(t, compare(&a, &b).pixels > 0)
	up := draw_page(other("a"))
	testing.expect(t, compare(&a, &up).pixels > 0)
}

@(private = "file")
stand_in_host :: proc(user: rawptr, l: ^lay.Layout, it: ^lay.Display_Item, w, h: int) -> Content {
	return Content{kind = .Stand_In, key = (^string)(user)^}
}

@(private = "file")
TWO_PIXELS := [8]u8{255, 0, 0, 255, 0, 0, 255, 255}

@(private = "file")
pixels_host :: proc(user: rawptr, l: ^lay.Layout, it: ^lay.Display_Item, w, h: int) -> Content {
	return Content{kind = .Pixels, pixels = TWO_PIXELS[:], width = 2, height = 1, stride = 2 * CHANNELS, natural = {2, 1}}
}

@(private = "file")
pending_host :: proc(user: rawptr, l: ^lay.Layout, it: ^lay.Display_Item, w, h: int) -> Content {
	return Content{kind = .Pending}
}

@(private = "file")
SVG_FULL_PIXEL := [4]u8{0, 255, 0, 255}

// A vector picture without natural dimensions fills the area; with a ratio only, it is contained in it.
@(private = "file")
vector_filling_host :: proc(user: rawptr, url: string, w, h: int) -> Content {
	c := Content{kind = .Pixels, natural = {1, 1}, vector = true}
	if w > 0 { c.pixels, c.width, c.height, c.stride = SVG_FULL_PIXEL[:], 1, 1, CHANNELS }
	return c
}

@(private = "file")
vector_ratio_host :: proc(user: rawptr, url: string, w, h: int) -> Content {
	c := Content{kind = .Pixels, natural = {2, 1}, vector = true, ratio_only = true}
	if w > 0 { c.pixels, c.width, c.height, c.stride = SVG_FULL_PIXEL[:], 1, 1, CHANNELS }
	return c
}

@(test)
background_pictures :: proc(t: ^testing.T) {
	src := `<!DOCTYPE html><body style="margin: 0"><div style="width: 100px; height: 100px; background: url(a.svg) no-repeat"></div>`
	fills := Host{css_image = vector_filling_host}
	img := draw_page(src, &fills)
	testing.expect_value(t, pixel(&img, 99, 99), LIME)
	ratio := Host{css_image = vector_ratio_host}
	img = draw_page(src, &ratio)
	testing.expect_value(t, pixel(&img, 99, 49), LIME)
	testing.expect_value(t, pixel(&img, 99, 50), WHITE)
}

@(test)
replaced_content :: proc(t: ^testing.T) {
	src := `<!DOCTYPE html><body style="margin: 0"><img width="40" height="20" style="display: block">`
	k1, k2 := "one", "two"
	h1, h2 := Host{user = &k1, replaced = stand_in_host}, Host{user = &k2, replaced = stand_in_host}
	a, a2, b := draw_page(src, &h1), draw_page(src, &h1), draw_page(src, &h2)
	testing.expect_value(t, compare(&a, &a2).pixels, 0)
	testing.expect(t, compare(&a, &b).pixels > 0, "another picture, another colour")
	testing.expect(t, pixel(&a, 39, 19) != WHITE && pixel(&a, 40, 19) == WHITE)
	hp := Host{replaced = pixels_host}
	px := draw_page(src, &hp)
	testing.expect_value(t, pixel(&px, 10, 10), RED)
	testing.expect_value(t, pixel(&px, 30, 10), BLUE)
	pending := Host{replaced = pending_host}
	p := page_load(src)
	defer page_unload(p)
	res := render(&p.l, TEST_W, TEST_H, 0, p.l.canvas, &pending, context.temp_allocator)
	testing.expect_value(t, res.pending, 1)
}

@(test)
unknown_items_draw_nothing :: proc(t: ^testing.T) {
	UNKNOWN_KIND :: 200
	p := page_load(`<!DOCTYPE html><body style="margin: 0"><div style="width: 40px; height: 20px; background: red"></div>`)
	defer page_unload(p)
	for &it in p.l.items { if it.kind == .Box && it.cs != nil && it.cs.background_color.a > 0 { it.kind = lay.Item_Kind(UNKNOWN_KIND) } }
	img := render(&p.l, TEST_W, TEST_H, 0, p.l.canvas, nil, context.temp_allocator).image
	testing.expect_value(t, pixel(&img, 10, 10), WHITE)
}

