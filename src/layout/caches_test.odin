package layout

import "core:math"
import "core:math/rand"
import "core:testing"
import "wb:dom"

// What layout keeps so as not to do the same work twice (the active floats of a formatting context, the segments of a
// context measured once per pass, the natural size of a replaced element once per pass, code points measured in one call):
// each gives the result the work it saves would have given.

@(private = "file")
Counts :: struct {
	words:       int,      // `width` calls for anything but a space
	label:       int,      // `width` calls for "alpha"
	chars:       int,      // `char_widths` calls
	char_widths: bool,     // the fake shell has char_widths
}

@(private = "file")
count_width :: proc(user: rawptr, f: Font, size: f32, text: string) -> f32 {
	n := (^Counts)(user)
	if text != " " { n.words += 1 }
	if text == "alpha" { n.label += 1 }
	return fake_width(user, f, size, text)
}

@(private = "file")
count_char_widths :: proc(user: rawptr, f: Font, size: f32, text: string, out: []f32) {
	n := (^Counts)(user)
	n.chars += 1
	for i in 0 ..< len(text) { if text[i] & 0xC0 != 0x80 { out[i] = fake_width(user, f, size, text[i:i + 1]) } }
}

@(private = "file")
counting :: proc(n: ^Counts) -> Text_Api {
	api := Text_Api{user = n, font = fake_font, width = count_width, metrics = fake_metrics}
	if n.char_widths { api.char_widths = count_char_widths }
	return api
}

@(private = "file")
lines_of :: proc(f: ^Fixture, id: string) -> []Line {
	bi := box_index(&f.l, dom.find_by_id(f.doc, id))
	if bi == NONE { return nil }
	b := &f.l.boxes[bi]
	return f.l.lines[b.lines[0]:b.lines[1]]
}

@(private = "file")
text_frag :: proc(f: ^Fixture, ln: Line) -> ^Frag {
	for i in ln.frags[0] ..< ln.frags[1] { if f.l.frags[i].kind == .Text { return &f.l.frags[i] } }
	return nil
}

// The queries of a formatting context's floats read the floats still below the last top (Bfc.live) when they ask at
// or below it: they answer as a scan of every float does, at any height.
@(test)
float_queries_match_a_scan_of_every_float :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	r := rand.create(7)
	context.random_generator = rand.default_random_generator(&r)
	bfc := bfc_make()
	top: f32 = 0
	for _ in 0 ..< 200 {
		top += f32(rand.int_max(3)) * 10   // tops never go up (§9.5.1 rule 5); several floats share one
		x := f32(rand.int_max(300))
		f := Float_Box{Rect{{x, top}, {x + 20 + f32(rand.int_max(80)), top + f32(rand.int_max(120))}}, rand.int_max(2) == 0}
		bfc_add(&bfc, f)
		for _ in 0 ..< 8 {
			y := top + f32(rand.int_max(400)) - 200   // above the last top too (content raised by a negative margin)
			h := f32(rand.int_max(30))
			// what the queries were: every float scanned
			l, rr := f32(0), f32(400)
			nb: f32 = math.F32_MAX
			for &g in bfc.floats {
				if g.r.max.y <= y || g.r.min.y >= max(y + h, y + FLOAT_PROBE_MIN_H) { continue }
				if g.left { l = max(l, g.r.max.x) } else { rr = min(rr, g.r.min.x) }
			}
			for &g in bfc.floats { if g.r.max.y > y + 0.01 && g.r.min.y <= y + 0.01 { nb = min(nb, g.r.max.y) } }
			if nb == math.F32_MAX { for &g in bfc.floats { if g.r.min.y > y { nb = min(nb, g.r.min.y) } } }
			gl, gr := bfc_band(&bfc, y, y + h, 0, 400)
			testing.expectf(t, gl == l && gr == rr, "band at %v: %v %v, want %v %v", y, gl, gr, l, rr)
			testing.expect_value(t, bfc_next_bottom(&bfc, y), nb)
		}
		lb, rb, all: f32 = -math.F32_MAX, -math.F32_MAX, -math.F32_MAX
		for &g in bfc.floats {
			if g.left { lb = max(lb, g.r.max.y) } else { rb = max(rb, g.r.max.y) }
			all = max(all, g.r.max.y)
		}
		testing.expect_value(t, bfc_clear_floor(&bfc, .Left), lb)
		testing.expect_value(t, bfc_clear_floor(&bfc, .Right), rb)
		testing.expect_value(t, bfc_clear_floor(&bfc, .Both), max(lb, rb))
		testing.expect_value(t, bfc_bottom(&bfc), all)
	}
}

// A paragraph raised by a negative margin above the top of the last float still flows around the earlier floats it meets.
@(test)
line_above_the_last_float_top_meets_earlier_floats :: proc(t: ^testing.T) {
	f := fixture_load(`<body style="margin:0;width:400px;font-size:10px;line-height:10px">
<div style="float:left;width:100px;height:50px"></div><div style="height:100px"></div>
<div style="float:left;width:50px;height:10px"></div><p id=p style="margin:-80px 0 0">xx</p></body>`)
	defer fixture_unload(f)
	ls := lines_of(f, "p")
	testing.expect_value(t, len(ls), 1)
	if len(ls) == 1 {
		fr := text_frag(f, ls[0])
		testing.expect(t, fr != nil && fr.x == 100, "the line at y 20 starts after the first float (0 to 50)")
	}
}

// text-wrap: balance probes the lines at several widths: the words are measured once in the pass.
@(test)
balance_probes_measure_words_once :: proc(t: ^testing.T) {
	n: Counts
	f := fixture_load(`<body style="margin:0;font-size:16px"><div id=b style="width:100px;text-wrap:balance">aa bb cc dd ee ff</div></body>`,
		o = {text = counting(&n)})
	defer fixture_unload(f)
	testing.expect_value(t, len(lines_of(f, "b")), 2)
	testing.expectf(t, u64(n.words) == 6 * f.l.passes[.Full], "6 words measured per pass: %d in %d passes", n.words, f.l.passes[.Full])
}

// The limits of text-wrap: balance are preferences: a paragraph of more lines than layout.text.balance_max_lines is
// wrapped as usual.
@(test)
balance_max_lines_is_a_preference :: proc(t: ^testing.T) {
	set := settings_default()
	set.balance_max_lines = 1
	f := fixture_load(`<body style="margin:0;font-size:16px"><div id=b style="width:100px;text-wrap:balance">aa bb cc dd ee ff</div></body>`,
		o = {set = &set})
	defer fixture_unload(f)
	ls := lines_of(f, "b")
	testing.expect_value(t, len(ls), 2)
	if len(ls) == 2 { testing.expect(t, text_frag(f, ls[0]).w > 80, "not balanced: the first line is the longest that fits") }
}

// A <select> asks for its natural size several times a pass (its width, then its height): its options are measured once.
@(test)
select_options_measured_once_per_pass :: proc(t: ^testing.T) {
	n: Counts
	f := fixture_load(`<body style="margin:0;font-size:10px"><div style="float:left"><select id=s><option>alpha<option>be</select></div></body>`,
		o = {text = counting(&n)})
	defer fixture_unload(f)
	testing.expectf(t, u64(n.label) == f.l.passes[.Full], "\"alpha\" measured once per pass: %d in %d passes", n.label, f.l.passes[.Full])
	r, ok := box_of(&f.l, dom.find_by_id(f.doc, "s"), f.vp, 0)
	testing.expect(t, ok && r.border.max.x - r.border.min.x >= 25, "as wide as its widest label")
}

// Text broken anywhere is measured through Text_Api.char_widths in one call when the shell has it: the same lines.
@(test)
char_widths_break_the_same_lines :: proc(t: ^testing.T) {
	SRC :: `<body style="margin:0;font-size:10px;line-height:10px"><div id=a style="width:22px;overflow-wrap:anywhere">abcdefghij</div>
<div id=e style="width:22px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis">abcdefghij</div>
<div id=m style="float:left;overflow-wrap:anywhere">abcdef</div></body>`
	plain, fast: Counts
	fast.char_widths = true
	f0 := fixture_load(SRC, o = {text = counting(&plain)})
	defer fixture_unload(f0)
	f1 := fixture_load(SRC, o = {text = counting(&fast)})
	defer fixture_unload(f1)
	testing.expect(t, fast.chars > 0, "char_widths was called")
	testing.expect(t, fast.words < plain.words, "fewer calls to `width`")
	for id in ([]string{"a", "e", "m"}) {
		l0, l1 := lines_of(f0, id), lines_of(f1, id)
		testing.expectf(t, len(l0) == len(l1), "%s: %d lines, want %d", id, len(l1), len(l0))
		if len(l0) != len(l1) { continue }
		for ln, i in l0 {
			testing.expectf(t, ln.frags[1] - ln.frags[0] == l1[i].frags[1] - l1[i].frags[0], "%s line %d: fragments", id, i)
			if ln.frags[1] - ln.frags[0] != l1[i].frags[1] - l1[i].frags[0] { continue }
			for k in 0 ..< ln.frags[1] - ln.frags[0] {
				a, b := &f0.l.frags[ln.frags[0] + k], &f1.l.frags[l1[i].frags[0] + k]
				testing.expectf(t, a.x == b.x && a.w == b.w && a.text == b.text, "%s line %d: %v %v %q, want %v %v %q", id, i, b.x, b.w, b.text, a.x, a.w, a.text)
			}
		}
	}
	testing.expect_value(t, len(lines_of(f1, "a")), 3)   // 4 characters of 5 px in 22 px, ten of them
}

// A float sized by min-content or max-content is that wide (as an atomic inline is): not shrink-to-fit.
@(test)
float_min_content_width :: proc(t: ^testing.T) {
	f := fixture_load(`<body style="margin:0;font-size:10px;line-height:10px"><div id=a style="float:left;width:min-content">aaaa bb</div>
<div id=b style="float:right;width:max-content;max-width:20px">aaaa bb</div></body>`)
	defer fixture_unload(f)
	ra, _ := box_of(&f.l, dom.find_by_id(f.doc, "a"), f.vp, 0)
	rb, _ := box_of(&f.l, dom.find_by_id(f.doc, "b"), f.vp, 0)
	testing.expect_value(t, ra.border.max.x - ra.border.min.x, 20)   // its longest word
	testing.expect_value(t, rb.border.max.x - rb.border.min.x, 20)   // max-width applies
}
