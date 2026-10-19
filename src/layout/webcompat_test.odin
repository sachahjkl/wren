package layout

import "core:math"
import "core:strconv"
import "core:testing"
import "wb:base"
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

// A decoded image's natural size, given by the test as data-nw / data-nh attributes (none: not loaded yet).
@(private = "file")
fake_natural :: proc(user: rawptr, node: base.Handle) -> (w, h: f32, ok: bool) {
	doc := (^dom.Document)(user)
	nw, okw := dom.get_attribute(doc, node, "data-nw")
	nh, okh := dom.get_attribute(doc, node, "data-nh")
	if !okw || !okh { return 0, 0, false }
	a, _ := strconv.parse_f32(nw)
	b, _ := strconv.parse_f32(nh)
	return a, b, true
}

@(private = "file")
with_layout :: proc(t: ^testing.T, src: string, check: proc(t: ^testing.T, l: ^Layout, doc: ^dom.Document), natural := false) {
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
	replaced := natural ? Replaced_Api{user = doc, intrinsic = fake_natural} : Replaced_Api{}
	run(&l, Input{doc = doc, styled = st, settings = &set, text = Text_Api{font = fake_font, width = fake_width, metrics = fake_metrics}, viewport = {800, 600}, scale = 1, band_h = 256, replaced = replaced})
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
	with_layout(t, `<!doctype html><body style="margin:0">
		<img id=a data-nw=1000 data-nh=1305 style="display:block;width:100%;max-width:200px;height:auto">
		<img id=b data-nw=1000 data-nh=500 style="display:block;max-width:100px">
		<img id=c data-nw=100 data-nh=50 style="display:block;min-height:100px">
		<img id=d data-nw=1000 data-nh=1000 style="display:block;max-width:300px;max-height:100px">
		<img id=e data-nw=400 data-nh=200 style="display:block;height:100px;max-width:150px">
	</body>`, proc(t: ^testing.T, l: ^Layout, doc: ^dom.Document) {
		near :: proc(a, b: [2]f32) -> bool { return math.abs(a.x - b.x) < 0.6 && math.abs(a.y - b.y) < 0.6 }
		testing.expectf(t, near(size_of_el(l, doc, "a"), {200, 261}), "width 100%% clamped by max-width: the height follows (%v)", size_of_el(l, doc, "a"))
		testing.expectf(t, near(size_of_el(l, doc, "b"), {100, 50}), "natural size over max-width (%v)", size_of_el(l, doc, "b"))
		testing.expectf(t, near(size_of_el(l, doc, "c"), {200, 100}), "natural size under min-height (%v)", size_of_el(l, doc, "c"))
		testing.expectf(t, near(size_of_el(l, doc, "d"), {100, 100}), "both over their maximum (%v)", size_of_el(l, doc, "d"))
		testing.expectf(t, near(size_of_el(l, doc, "e"), {150, 100}), "a given height, the width clamped (%v)", size_of_el(l, doc, "e"))
	}, natural = true)
}

// <center> and align=center / right / left (text-align: -webkit-*): narrower block-level children are placed like the
// text, as Blink does (HTML §15.3.3 "align descendants"); auto margins and full-width blocks are left alone.
@(test)
legacy_alignment_of_blocks :: proc(t: ^testing.T) {
	with_layout(t, `<!doctype html><body style="margin:0"><div style="width:400px">
		<center><table id=a style="width:100px;border-spacing:0"><tr><td style="padding:0">x</td></tr></table><div id=b>full</div></center>
		<div align=right><div id=c style="width:100px;margin-right:10px">r</div><p><span id=s>t</span></p></div>
		<div align=center><div style="width:200px"><div id=d style="width:100px">nested</div></div></div>
		<div align=center><div id=e style="width:100px;margin-left:auto;margin-right:0">auto margins win</div></div>
		<div style="text-align:center"><div id=f style="width:100px">plain center does not move blocks</div></div>
		<div align=left dir=rtl><div id=g style="width:100px">left in rtl</div></div>
	</div></body>`, proc(t: ^testing.T, l: ^Layout, doc: ^dom.Document) {
		x_of :: proc(l: ^Layout, doc: ^dom.Document, id: string) -> f32 {
			r, ok := box_of(l, dom.find_by_id(doc, id), {800, 600}, 0)
			return ok ? r.border.min.x : -1
		}
		testing.expectf(t, math.abs(x_of(l, doc, "a") - 150) < 0.6, "a table in <center> is centered (%v)", x_of(l, doc, "a"))
		testing.expectf(t, x_of(l, doc, "b") == 0 && size_of_el(l, doc, "b").x == 400, "a full-width block stays")
		testing.expectf(t, math.abs(x_of(l, doc, "c") - 290) < 0.6, "align=right pushes the margin box right (%v)", x_of(l, doc, "c"))
		testing.expectf(t, x_of(l, doc, "s") > 300, "align=right aligns the text too (%v)", x_of(l, doc, "s"))
		testing.expectf(t, math.abs(x_of(l, doc, "d") - 150) < 0.6, "inherited: centered in its centered parent (%v)", x_of(l, doc, "d"))
		testing.expectf(t, math.abs(x_of(l, doc, "e") - 300) < 0.6, "auto margins are honored (%v)", x_of(l, doc, "e"))
		testing.expectf(t, x_of(l, doc, "f") == 0, "text-align: center leaves blocks (%v)", x_of(l, doc, "f"))
		testing.expectf(t, x_of(l, doc, "g") == 0, "align=left in rtl pushes left (%v)", x_of(l, doc, "g"))
	})
}

// Automatic table layout with fixed and percentage columns (CSS Tables 3 §3.9, as browsers): a column given a length
// stays at it while automatic columns take the rest (Hacker News' header), percentage columns take their share and make
// an auto-width table wide enough for it (Google's search form: 25% | form | 25%), <col> widths count.
@(test)
table_column_kinds :: proc(t: ^testing.T) {
	with_layout(t, `<!doctype html><body style="margin:0;font-size:10px"><div style="width:1000px">
		<table id=hn style="width:400px;border-spacing:0"><tr><td id=h1 style="width:18px;padding:0 4px 0 0"><div style="width:20px;height:5px"></div></td><td id=h2 style="padding:0">Hacker</td><td id=h3 style="padding:0">login</td></tr></table>
		<table id=g style="border-spacing:0"><tr><td id=g1 width="25%" style="padding:0"></td><td id=g2 style="padding:0"><div style="width:400px;height:5px"></div></td><td id=g3 width="25%" style="padding:0">adv</td></tr></table>
		<table id=c style="width:500px;border-spacing:0"><col width=100><col><tr><td id=c1 style="padding:0">a</td><td id=c2 style="padding:0">b</td></tr></table>
		<table id=p style="width:500px;border-spacing:0"><tr><td id=p1 style="width:80%;padding:0">a</td><td id=p2 style="width:40%;padding:0">b</td><td id=p3 style="padding:0">c</td></tr></table>
	</div></body>`, proc(t: ^testing.T, l: ^Layout, doc: ^dom.Document) {
		rect_of :: proc(l: ^Layout, doc: ^dom.Document, id: string) -> Rect {
			r, _ := box_of(l, dom.find_by_id(doc, id), {800, 600}, 0)
			return r.border
		}
		near :: proc(a, b: f32) -> bool { return math.abs(a - b) < 0.6 }
		check :: proc(t: ^testing.T, l: ^Layout, doc: ^dom.Document, id: string, x, w: f32, what: string, loc := #caller_location) {
			r := rect_of(l, doc, id)
			testing.expectf(t, near(r.min.x, x) && near(r.max.x - r.min.x, w), "%s: x %v w %v, want x %v w %v", what, r.min.x, r.max.x - r.min.x, x, w, loc = loc)
		}
		check(t, l, doc, "h1", 0, 24, "a fixed column keeps its width (content 20 + padding 4)")
		testing.expectf(t, near(rect_of(l, doc, "h2").min.x, 24), "the automatic columns take the rest (%v)", rect_of(l, doc, "h2").min.x)
		check(t, l, doc, "g", 0, 800, "percentage columns widen an auto table: 400 / (1 - 50%)")
		check(t, l, doc, "g1", 0, 200, "25%")
		check(t, l, doc, "g2", 200, 400, "the form")
		check(t, l, doc, "g3", 600, 200, "25%")
		check(t, l, doc, "c1", 0, 100, "<col width=100>")
		check(t, l, doc, "c2", 100, 400, "the other column takes the rest")
		p1, p2 := rect_of(l, doc, "p1"), rect_of(l, doc, "p2")
		testing.expectf(t, p1.max.x - p1.min.x > 390, "80%% (less the room the last column's content needs): %v", p1.max.x - p1.min.x)
		testing.expectf(t, p2.max.x - p2.min.x < 101, "percentages past 100%% are cut (%v)", p2.max.x - p2.min.x)
	})
}

// An image's width / height attributes are CSS width / height of the lowest priority plus aspect-ratio: auto w / h
// (HTML §15.4.1): the page's `height: auto` gives the decoded image its own ratio (a portrait photo given square
// attributes stays a portrait), and the attributes' ratio holds the place until it is decoded. Values as Blink lays out.
@(test)
image_size_attributes :: proc(t: ^testing.T) {
	with_layout(t, `<!doctype html><body style="margin:0"><div style="width:300px">
		<img id=a width=400 height=400 data-nw=600 data-nh=800 style="display:block;max-width:100%;height:auto">
		<img id=b width=400 height=400 style="display:block;max-width:100%;height:auto">
		<img id=c width=1000 height=500 data-nw=10 data-nh=10 style="display:block;max-width:100px">
		<img id=d width=200 data-nw=100 data-nh=50 style="display:block">
		<img id=e data-nw=100 data-nh=50 style="display:block;width:100%;height:auto">
		<img id=f width=120 height=60 data-nw=100 data-nh=100 style="display:block;object-fit:contain">
		<img id=g height=30 data-nw=100 data-nh=50 style="display:block">
		<div style="display:flex"><img id=h width=80 height=40 data-nw=100 data-nh=100 style="height:auto"></div>
		<div style="display:grid;grid-template-columns:150px"><img id=i width=400 height=400 data-nw=100 data-nh=200 style="max-width:100%;height:auto"></div>
	</div></body>`, proc(t: ^testing.T, l: ^Layout, doc: ^dom.Document) {
		near :: proc(a, b: [2]f32) -> bool { return math.abs(a.x - b.x) < 0.6 && math.abs(a.y - b.y) < 0.6 }
		check :: proc(t: ^testing.T, l: ^Layout, doc: ^dom.Document, id: string, want: [2]f32, what: string, loc := #caller_location) {
			got := size_of_el(l, doc, id)
			testing.expectf(t, near(got, want), "%s: %v, want %v", what, got, want, loc = loc)
		}
		check(t, l, doc, "a", {300, 400}, "square attributes, portrait image, max-width: 100%, height: auto")
		check(t, l, doc, "b", {300, 300}, "not decoded yet: the attributes' ratio")
		check(t, l, doc, "c", {100, 500}, "both attributes and no height: auto: the height attribute stays")
		check(t, l, doc, "d", {200, 100}, "width attribute only: the natural ratio")
		check(t, l, doc, "e", {300, 150}, "no attributes, width: 100%")
		check(t, l, doc, "f", {120, 60}, "object-fit does not change the box")
		check(t, l, doc, "g", {60, 30}, "height attribute only")
		check(t, l, doc, "h", {80, 80}, "flex item: height: auto follows the natural ratio")
		check(t, l, doc, "i", {150, 300}, "grid item under max-width: 100%")
	}, natural = true)
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
