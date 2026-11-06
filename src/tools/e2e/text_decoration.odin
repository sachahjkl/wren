package e2e_scenarios

// CSS Text Decoration 3 and 4, and the highlight pseudo-elements of CSS Pseudo 4, by their pixels. The glyphs are Roboto's, from the repository (examples/site/fonts).

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:e2e"
import "wb:style"

@(private = "file") DECO_SIZE :: [2]int{900, 700}
// Roboto's own underline at 64 px: underlineThickness of its `post` table, 100 of its 2048 units an em.
@(private = "file") ROBOTO_UNDERLINE_ROWS :: 3
// The rows of a wave 3 px thick: its thickness and how far it goes each way, and a row of soft edge.
@(private = "file") WAVE_ROWS :: 3 * 3
@(private = "file") DECO_STYLE :: `<!doctype html><style>
  @font-face { font-family: T; src: url(roboto.ttf); }
  body { margin: 20px; background: #fff; color: #000; font: 32px/60px T; }
  p { margin: 0; }
</style>`

// What a band of the picture holds of a colour.
@(private = "file")
Ink :: struct {
	rows:     int,   // rows with some
	bands:    int,   // runs of such rows
	columns:  int,   // columns with some
	gaps:     int,   // runs of columns without any between two with some
	first_x:  int,
	last_x:   int,
	top:      int,
	bottom:   int,
}

@(private = "file")
Hue :: enum { Red, Blue, Green, Black }

@(private = "file")
is_hue :: proc(c: [3]u8, hue: Hue) -> bool {
	switch hue {
	case .Red: return c[0] > 200 && c[1] < 60 && c[2] < 60
	case .Blue: return c[2] > 200 && c[0] < 60 && c[1] < 60
	case .Green: return c[1] > 110 && c[0] < 60 && c[2] < 60
	case .Black: return c[0] < 60 && c[1] < 60 && c[2] < 60
	}
	return false
}

@(private = "file")
ink_in :: proc(img: e2e.Image, box: e2e.Rect, hue := Hue.Red) -> (r: Ink) {
	r.first_x, r.top = -1, -1
	was_row := false
	was_column, seen := false, false
	for y in int(box.y) ..< int(box.y + box.h) {
		row := false
		for x in int(box.x) ..< int(box.x + box.w) { if is_hue(e2e.pixel(img, x, y).rgb, hue) { row = true; break } }
		if row {
			r.rows += 1
			if r.top < 0 { r.top = y }
			r.bottom = y
			if !was_row { r.bands += 1 }
		}
		was_row = row
	}
	for x in int(box.x) ..< int(box.x + box.w) {
		column := false
		for y in int(box.y) ..< int(box.y + box.h) { if is_hue(e2e.pixel(img, x, y).rgb, hue) { column = true; break } }
		if column {
			r.columns += 1
			if r.first_x < 0 { r.first_x = x }
			r.last_x = x
			if seen && !was_column { r.gaps += 1 }
			seen = true
		}
		was_column = column
	}
	return
}

// The runs of rows, the same as columns of a column of vertical text: its line's gaps are along y.
@(private = "file")
row_gaps_in :: proc(img: e2e.Image, box: e2e.Rect, hue := Hue.Red) -> (gaps: int) {
	was, seen := false, false
	for y in int(box.y) ..< int(box.y + box.h) {
		row := false
		for x in int(box.x) ..< int(box.x + box.w) { if is_hue(e2e.pixel(img, x, y).rgb, hue) { row = true; break } }
		if row {
			if seen && !was { gaps += 1 }
			seen = true
		}
		was = row
	}
	return
}

// A page of `body`, its font ready.
@(private = "file")
open_page :: proc(t: ^testing.T, body: string, size := DECO_SIZE, url_tail := "", prefs: []string = nil, loc := #caller_location) -> ^e2e.Session {
	s := e2e.start(t, {size = size, dpi = e2e.DPI_ONE, prefs = prefs}, loc)
	dir := e2e.temp_folder(t)
	e2e.copy_file(fmt.tprintf("%s/examples/site/fonts/roboto.ttf", e2e.repo_root()), fmt.tprintf("%s/roboto.ttf", dir))
	url := e2e.file_page(dir, "deco.html", strings.concatenate({DECO_STYLE, body}, context.temp_allocator))
	e2e.navigate(s, strings.concatenate({url, url_tail}, context.temp_allocator))
	e2e.eval(s, "document.fonts.ready.then(() => 1)", await = true, loc = loc)
	e2e.wait_frames(s, loc = loc)
	return s
}

@(private = "file")
window_of :: proc(s: ^e2e.Session, selector: string, loc := #caller_location) -> e2e.Rect { return e2e.box_model(s, selector, loc).window }

@(private = "file") STYLES_PAGE :: `<style>
  p { text-decoration-color: #f00; text-decoration-thickness: 2px; }
  #solid { text-decoration-line: underline; }
  #double { text-decoration-line: underline; text-decoration-style: double; }
  #dotted { text-decoration-line: underline; text-decoration-style: dotted; }
  #wavy { text-decoration-line: underline; text-decoration-style: wavy; }
  #far { text-decoration-line: underline; text-underline-offset: 14px; }
  p { text-decoration-skip-ink: none; }
  ::highlight(spell) { text-decoration: underline wavy #f00; }
  #sel::selection { text-decoration: underline #f00; }
</style>
<p id=solid>Some words here</p>
<p id=double>Some words here</p>
<p id=dotted>Some words here</p>
<p id=wavy>Some words here</p>
<p id=far>Some words here</p>
<div id=marked>Plain then wrong then plain</div>
<div id=sel>Words to select</div>
<script>
  const text = document.getElementById("marked").firstChild, range = new Range();
  range.setStart(text, 11);
  range.setEnd(text, 16);
  CSS.highlights.set("spell", new Highlight(range));
</script>`

@(test)
each_style_of_a_line_is_drawn_as_it_says :: proc(t: ^testing.T) {
	s := open_page(t, STYLES_PAGE)
	img := e2e.capture(s)
	solid := ink_in(img, window_of(s, "#solid"))
	double := ink_in(img, window_of(s, "#double"))
	dotted := ink_in(img, window_of(s, "#dotted"))
	wavy := ink_in(img, window_of(s, "#wavy"))
	far := ink_in(img, window_of(s, "#far"))
	testing.expectf(t, solid.bands == 1 && solid.gaps == 0 && solid.rows == 2, "a solid line, 2 px: %v", solid)
	testing.expectf(t, double.bands == 2 && double.gaps == 0, "a double line is two: %v", double)
	testing.expectf(t, dotted.bands == 1 && dotted.gaps > solid.columns / 8, "a dotted line has gaps: %v", dotted)
	testing.expectf(t, wavy.rows > solid.rows && wavy.gaps == 0, "a wave goes up and down, unbroken: %v", wavy)
	testing.expectf(t, far.top > solid.top - int(window_of(s, "#solid").y) + int(window_of(s, "#far").y), "text-underline-offset moves it down: %v, %v", far, solid)
}

@(test)
a_highlight_draws_its_line_under_its_words_alone :: proc(t: ^testing.T) {
	s := open_page(t, STYLES_PAGE)
	box := window_of(s, "#marked")
	marked := ink_in(e2e.capture(s), box)
	testing.expectf(t, marked.rows > 2, "the wave of ::highlight(): %v", marked)
	testing.expectf(t, marked.first_x > int(box.x) && marked.columns < int(box.w) / 3, "over its range only: %v of %v", marked, box)
}

@(test)
a_selection_draws_the_line_of_its_rule :: proc(t: ^testing.T) {
	s := open_page(t, STYLES_PAGE)
	box := window_of(s, "#sel")
	testing.expect_value(t, ink_in(e2e.capture(s), box).rows, 0)
	e2e.eval(s, `getSelection().selectAllChildren(document.getElementById("sel")); 1`)
	e2e.wait_frames(s)
	testing.expectf(t, ink_in(e2e.capture(s), box).rows > 0, "the underline of #sel::selection")
}

@(private = "file") INK_PAGE :: `<style>
  p { color: transparent; text-decoration: underline 2px #f00; text-underline-offset: 3px; }
  #none { text-decoration-skip-ink: none; }
  #all { text-decoration-skip-ink: all; }
  #wave { text-decoration-style: wavy; }
  #rtl { direction: rtl; width: 300px; }
  #cjk-auto, #cjk-all { text-underline-offset: -12px; text-decoration-skip-ink: auto; }
  #cjk-all { text-decoration-skip-ink: all; }
  #through { text-decoration: line-through 2px #f00; }
</style>
<p id=auto>gypsy jpg</p><p id=none>gypsy jpg</p><p id=all>gypsy jpg</p><p id=wave>gypsy jpg</p>
<p id=rtl dir=rtl>gypsy jpg</p><p id=through>gypsy jpg</p>
<p id=cjk-auto>&#x6F22;&#x5B57;&#x6F22;&#x5B57;</p><p id=cjk-all>&#x6F22;&#x5B57;&#x6F22;&#x5B57;</p>`

// The default `auto` leaves gaps where descenders go through, `none` none, `all` even through ideographs; line-through never does.
@(test)
a_line_skips_the_ink_it_meets :: proc(t: ^testing.T) {
	s := open_page(t, INK_PAGE)
	img := e2e.capture(s)
	auto := ink_in(img, window_of(s, "#auto"))
	none := ink_in(img, window_of(s, "#none"))
	testing.expectf(t, none.gaps == 0, "none: unbroken: %v", none)
	testing.expectf(t, auto.gaps >= 4 && auto.columns < none.columns - 8, "auto: around g, y, p, y, j, p, g: %v of %v", auto, none)
	wave := ink_in(img, window_of(s, "#wave"))
	testing.expectf(t, wave.gaps >= 4, "a wave skips too: %v", wave)
	rtl := ink_in(img, window_of(s, "#rtl"))
	testing.expectf(t, rtl.gaps >= 4, "right to left: %v", rtl)
	through := ink_in(img, window_of(s, "#through"))
	testing.expectf(t, through.gaps == 0, "a line-through is never cut: %v", through)
	cjk_auto := ink_in(img, window_of(s, "#cjk-auto"))
	cjk_all := ink_in(img, window_of(s, "#cjk-all"))
	testing.expectf(t, cjk_auto.gaps == 0, "auto goes through ideographs: %v", cjk_auto)
	testing.expectf(t, cjk_all.gaps > 0, "all does not: %v", cjk_all)
}

// The gap is of the line's thickness on each side of the ink: more ink out of a thick line.
@(test)
the_gap_follows_the_thickness :: proc(t: ^testing.T) {
	s := open_page(t, `<style>p { color: transparent; text-decoration: underline #f00; text-underline-offset: 3px; } #thin { text-decoration-thickness: 1px; } #thick { text-decoration-thickness: 4px; }</style>
<p id=thin>gypsy jpg</p><p id=thick>gypsy jpg</p>`)
	img := e2e.capture(s)
	thin, thick := ink_in(img, window_of(s, "#thin")), ink_in(img, window_of(s, "#thick"))
	testing.expectf(t, thick.columns < thin.columns - 6, "%v, %v", thin, thick)
}

// Each box keeps its line, style, colour and thickness; the outer one is under the inner one.
@(test)
each_decorating_box_keeps_its_line :: proc(t: ^testing.T) {
	s := open_page(t, `<style>
  body { text-decoration-skip-ink: none; }
  u { text-decoration: underline wavy #f00 3px; text-underline-offset: 8px; }
  s { text-decoration: line-through dotted #00f 2px; }
  .up { text-decoration: overline #0a0 4px; }
  #big { font-size: 64px; text-decoration: none; }
  </style>
  <p id=nested><u><s>Some nested <span class=up>lines</span> here</s></u></p>
  <p id=sized><u>small <span id=big>LARGE</span> small</u></p>
  <p id=raised><u id=ru>base <sup id=sup style="font-size: 16px">raised</sup> base</u></p>`)
	img := e2e.capture(s)
	box := window_of(s, "#nested")
	red, blue, green := ink_in(img, box, .Red), ink_in(img, box, .Blue), ink_in(img, box, .Green)
	testing.expectf(t, red.rows > 3 && red.gaps == 0, "the wave of <u>, 3 px, over all its text: %v", red)
	testing.expectf(t, blue.gaps > 8, "the dots of <s>, over all its text: %v", blue)
	testing.expectf(t, abs(red.last_x - blue.last_x) < 8 && red.first_x == blue.first_x, "the same length: %v, %v", red, blue)
	testing.expectf(t, red.top > blue.top, "under, through: %v, %v", red, blue)
	testing.expectf(t, green.rows == 4 && green.columns < red.columns / 2 && green.top < blue.top, "the overline of the inner box, over it alone: %v", green)
	// a box's line stays where its font and baseline put it, whatever its inner boxes are
	sized := window_of(s, "#sized")
	line := ink_in(img, sized)
	testing.expectf(t, line.gaps == 0 && line.rows <= WAVE_ROWS, "one line over text of two sizes: %v", line)
	raised := ink_in(img, window_of(s, "#raised"))
	testing.expectf(t, raised.gaps == 0 && raised.rows <= WAVE_ROWS, "under text raised by vertical-align: %v", raised)
}

// Underline and overline under the text, line-through over it (§2.6).
@(test)
lines_are_painted_in_their_order :: proc(t: ^testing.T) {
	s := open_page(t, `<style>
  body { font-size: 64px; line-height: 90px; text-decoration-skip-ink: none; }
  #under { text-decoration: underline 8px #f00; text-underline-offset: -24px; }
  #through { text-decoration: line-through 8px #f00; }
  </style><p id=under>HHH</p><p id=through>HHH</p>`)
	img := e2e.capture(s)
	under, through := ink_in(img, window_of(s, "#under")), ink_in(img, window_of(s, "#through"))
	testing.expectf(t, under.gaps >= 2, "the glyphs are over an underline: %v", under)
	testing.expectf(t, through.gaps == 0, "a line-through is over them: %v", through)
}

@(test)
a_shadow_has_the_lines_too :: proc(t: ^testing.T) {
	s := open_page(t, `<style>
  body { text-decoration-skip-ink: none; }
  #flat { text-decoration: underline 2px #f00; text-shadow: 0 8px #00f; }
  #blurred { text-decoration: underline 4px #f00; text-shadow: 0 12px 1px #00f; }
  </style><p id=flat>Some text</p><p id=blurred>Some text</p>`)
	img := e2e.capture(s)
	box := window_of(s, "#flat")
	red, blue := ink_in(img, box, .Red), ink_in(img, {box.x, box.y + box.h - 20, box.w, 20}, .Blue)
	testing.expectf(t, blue.columns >= red.columns - 2, "the shadow of the line: %v, %v", red, blue)
	box = window_of(s, "#blurred")
	testing.expectf(t, ink_in(img, {box.x, box.y + box.h - 16, box.w, 16}, .Blue).columns > 40, "blurred, through a layer")
}

// text-underline-position, thickness and offset from the font's metrics and in percentages.
@(test)
a_line_is_placed_and_sized_as_it_says :: proc(t: ^testing.T) {
	s := open_page(t, `<style>
  body { font-size: 64px; line-height: 150px; text-decoration-skip-ink: none; }
  p { text-decoration: underline #f00; }
  #auto, #font, #under { text-decoration-thickness: 2px; }
  #font { text-underline-position: from-font; }
  #under { text-underline-position: under; }
  #from { text-decoration-thickness: from-font; }
  #percent { text-decoration-thickness: 25%; }
  #offset { text-decoration-thickness: 2px; text-underline-offset: 50%; }
  #inherited { font-size: 32px; text-decoration-thickness: 2px; }
  div { text-underline-offset: 50%; }
  </style><p id=auto>xxx</p><p id=font>xxx</p><p id=under>xxx</p><p id=from>xxx</p><p id=percent>xxx</p><p id=offset>xxx</p><div><p id=inherited>xxx</p></div>`, {900, 1100})
	img := e2e.capture(s)
	top_of :: proc(s: ^e2e.Session, img: e2e.Image, id: string) -> (int, Ink) {
		box := window_of(s, id)
		ink := ink_in(img, box)
		return ink.top - int(box.y), ink
	}
	auto, _ := top_of(s, img, "#auto")
	font_top, _ := top_of(s, img, "#font")
	under, _ := top_of(s, img, "#under")
	testing.expectf(t, font_top != auto, "from-font: %d, auto: %d", font_top, auto)
	testing.expectf(t, under > auto && under > font_top, "under: below the descent: %d, %d", under, auto)
	_, from := top_of(s, img, "#from")
	testing.expect_value(t, from.rows, ROBOTO_UNDERLINE_ROWS)
	_, percent := top_of(s, img, "#percent")
	testing.expect_value(t, percent.rows, 16)
	offset, _ := top_of(s, img, "#offset")
	inherited, _ := top_of(s, img, "#inherited")
	// half an em from the baseline: 32 px of 64, and 16 px of 32 where the percentage inherited as one
	testing.expectf(t, offset - auto > 20 && inherited < offset, "percentages of 1em: %d, %d, %d", offset, inherited, auto)
}

@(test)
ends_of_a_line_are_as_it_says :: proc(t: ^testing.T) {
	s := open_page(t, `<style>
  body { text-decoration-skip-ink: none; white-space: pre; }
  p { text-decoration: underline 2px #f00; width: 500px; }
  #default {}
  #none { text-decoration-skip-spaces: none; }
  #all { text-decoration-skip-spaces: all; }
  #inset { text-decoration-inset: 20px 40px; }
  #rtl { text-decoration-inset: 20px 40px; direction: rtl; text-align: right; }
  </style><p id=default>   some   words   </p><p id=none>   some   words   </p><p id=all>   some   words</p><p id=plain>some words</p><p id=inset>some words</p><p id=rtl>some words</p>`)
	img := e2e.capture(s)
	dflt, none, all := ink_in(img, window_of(s, "#default")), ink_in(img, window_of(s, "#none")), ink_in(img, window_of(s, "#all"))
	testing.expectf(t, dflt.columns < none.columns - 20 && dflt.gaps == 0, "by default the spaces at the ends of a line are out: %v, %v", dflt, none)
	testing.expectf(t, all.gaps == 1, "all: inside too: %v", all)
	plain, inset := ink_in(img, window_of(s, "#plain")), ink_in(img, window_of(s, "#inset"))
	testing.expectf(t, inset.first_x == plain.first_x + 20 && inset.last_x == plain.last_x - 40, "text-decoration-inset: %v, %v", plain, inset)
	rtl := ink_in(img, window_of(s, "#rtl"))
	testing.expectf(t, rtl.columns == inset.columns, "right to left, the start on the right: %v", rtl)
}

@(test)
emphasis_marks_go_where_they_say :: proc(t: ^testing.T) {
	s := open_page(t, `<style>
  body { line-height: 100px; }
  #over { text-emphasis: filled circle #f00; }
  #under { text-emphasis: filled circle #f00; text-emphasis-position: under right; }
  #shorthand { -webkit-text-emphasis: "x" #f00; }
  #skipped { text-emphasis: dot #f00; }
  #vertical { writing-mode: vertical-rl; height: 200px; line-height: 100px; text-emphasis: filled sesame #f00; }
  #left { writing-mode: vertical-rl; height: 200px; line-height: 100px; text-emphasis: open dot #f00; text-emphasis-position: over left; }
  </style><p id=over>abc</p><p id=under>abc</p><p id=shorthand>abc</p><p id=skipped>a. b</p><p id=rtl style="direction: rtl; width: 300px; text-emphasis: dot #f00">abc</p>
  <div style="display: flex"><div id=vertical>abc</div><div id=left>abc</div></div>`, {900, 900})
	img := e2e.capture(s)
	box := window_of(s, "#over")
	over := ink_in(img, box)
	testing.expectf(t, over.bands == 1 && over.gaps == 2 && over.top - int(box.y) < 40, "a mark over each letter: %v", over)
	box = window_of(s, "#under")
	under := ink_in(img, box)
	testing.expectf(t, under.bands == 1 && under.gaps == 2 && under.top - int(box.y) > 55, "under: %v", under)
	testing.expectf(t, ink_in(img, window_of(s, "#shorthand")).gaps >= 2, "the -webkit- shorthand and a string")
	skipped := ink_in(img, window_of(s, "#skipped"))
	testing.expectf(t, skipped.gaps == 1, "not over a space or a period: %v", skipped)
	rtl := ink_in(img, window_of(s, "#rtl"))
	testing.expectf(t, rtl.gaps == 2 && rtl.first_x > 100, "right to left too: %v", rtl)
	box = window_of(s, "#vertical")
	vertical := ink_in(img, box)
	testing.expectf(t, vertical.columns > 0 && vertical.first_x > int(box.x + box.w / 2) + 10, "right of a vertical line: %v in %v", vertical, box)
	testing.expectf(t, row_gaps_in(img, box) == 2, "one each")
	box = window_of(s, "#left")
	left := ink_in(img, box)
	testing.expectf(t, left.columns > 0 && left.last_x < int(box.x + box.w / 2) - 10, "left: %v in %v", left, box)
}

@(test)
glyphs_have_a_stroke_of_their_own :: proc(t: ^testing.T) {
	s := open_page(t, `<style>
  body { font-size: 64px; line-height: 90px; }
  #stroke { -webkit-text-stroke: 2px #f00; color: #000; }
  #hollow { -webkit-text-stroke-width: 3px; -webkit-text-stroke-color: #f00; -webkit-text-fill-color: transparent; }
  </style><p id=stroke>HO</p><p id=hollow>HO</p><p id=plain>HO</p>`)
	img := e2e.capture(s)
	stroke, black := ink_in(img, window_of(s, "#stroke")), ink_in(img, window_of(s, "#stroke"), .Black)
	testing.expectf(t, stroke.columns > 40 && black.columns > 20, "a red edge around black: %v, %v", stroke, black)
	testing.expectf(t, ink_in(img, window_of(s, "#hollow"), .Black).columns == 0 && ink_in(img, window_of(s, "#hollow")).columns > 40, "only the edge")
	testing.expect_value(t, ink_in(img, window_of(s, "#plain")).columns, 0)
}

@(test)
vertical_lines_skip_and_change_sides :: proc(t: ^testing.T) {
	s := open_page(t, `<style>
  body { line-height: 60px; }
  div { width: 60px; height: 400px; text-decoration: underline 2px #f00; text-decoration-skip-ink: none; }
  #lines { display: flex; gap: 40px; }
  #left { writing-mode: vertical-rl; text-underline-position: left; }
  #right { writing-mode: vertical-rl; text-underline-position: right; }
  #ink, #plain, #ccw { color: transparent; text-underline-position: from-font; text-underline-offset: 3px; }
  #ink { writing-mode: vertical-rl; text-orientation: sideways; text-decoration-skip-ink: all; }
  #plain { writing-mode: vertical-rl; text-orientation: sideways; text-decoration-skip-ink: none; }
  #ccw { writing-mode: sideways-lr; text-decoration-skip-ink: all; }
  #over { writing-mode: vertical-rl; text-decoration: overline 2px #f00; text-underline-position: right; }
  </style><section id=lines><div id=left>xxxx</div><div id=right>xxxx</div><div id=ink>gypsy jpg</div><div id=plain>gypsy jpg</div><div id=ccw>gypsy jpg</div><div id=over>xxxx</div></section>`, {900, 500})
	img := e2e.capture(s)
	box := window_of(s, "#left")
	left := ink_in(img, box)
	testing.expectf(t, left.last_x < int(box.x + box.w / 2), "left: %v of %v", left, box)
	box = window_of(s, "#right")
	right := ink_in(img, box)
	testing.expectf(t, right.first_x > int(box.x + box.w / 2), "right: %v of %v", right, box)
	box = window_of(s, "#over")
	over := ink_in(img, box)
	testing.expectf(t, over.last_x < int(box.x + box.w / 2), "an underline on the right sends the overline to the left: %v of %v", over, box)
	testing.expectf(t, row_gaps_in(img, window_of(s, "#ink")) >= 4, "skips ink down a column")
	testing.expectf(t, row_gaps_in(img, window_of(s, "#plain")) == 0, "and not with none")
	testing.expectf(t, row_gaps_in(img, window_of(s, "#ccw")) >= 4, "and read upwards")
}

@(private = "file") OVERLAP_PAGE :: `<style>
  body { font-size: 40px; line-height: 70px; text-decoration-skip-ink: none; }
  ::highlight(low) { background-color: #f00; color: #fff; }
  ::highlight(high) { background-color: #00f; }
  ::highlight(line) { text-decoration: underline 3px #0a0; }
  #sel::selection { background-color: #0a0; color: #fff; }
  #shadow::selection { background-color: #fff; color: #000; text-shadow: 6px 0 #f00; }
  #fill::selection { -webkit-text-fill-color: #0a0; color: #f00; background-color: #fff; }
  #stroke::selection { -webkit-text-stroke-width: 2px; -webkit-text-stroke-color: #f00; background-color: #fff; color: #000; }
  #green { color: #0a0; text-decoration: underline #00f 3px; }
  #green::selection { color: #f00; background-color: #fff; }
</style>
<p id=first>AAAAAAAA</p><p id=second>AAAAAAAA</p><p id=sel>AAAAAAAA</p><p id=shadow>HHHH</p><p id=fill>HHHH</p><p id=stroke>HHHH</p><p id=green>HHHH</p>
<script>
  const range = id => { const r = new Range(); r.selectNodeContents(document.getElementById(id)); return r; };
  const low = new Highlight(range("first"), range("second"), range("sel")), high = new Highlight(range("first"), range("first"));
  CSS.highlights.set("high", high);
  CSS.highlights.set("low", low);
  const line = new Highlight(range("second"));
  CSS.highlights.set("line", line);
  function select(id) { getSelection().selectAllChildren(document.getElementById(id)); }
</script>`

// Same priority: the last registered is above; a higher priority is above that; a selection is above them all.
@(test)
overlapping_highlights_stack_by_priority :: proc(t: ^testing.T) {
	s := open_page(t, OVERLAP_PAGE)
	box := window_of(s, "#first")
	img := e2e.capture(s)
	testing.expectf(t, ink_in(img, box, .Red).columns > 100 && ink_in(img, box, .Blue).columns < 10, "registered last, low is over high")
	e2e.eval(s, "high.priority = 1; 1")
	e2e.wait_frames(s)
	img = e2e.capture(s)
	blue := ink_in(img, box, .Blue)
	testing.expectf(t, blue.columns > 100 && ink_in(img, box, .Red).columns < 10, "with a higher priority high is over it: %v", blue)
	second := window_of(s, "#second")
	testing.expectf(t, ink_in(img, second, .Green).rows >= 3, "a line of the highlight over the other's background")
	e2e.eval(s, `select("sel"); 1`)
	e2e.wait_frames(s)
	img = e2e.capture(s)
	sel := window_of(s, "#sel")
	testing.expectf(t, ink_in(img, sel, .Green).columns > 100 && ink_in(img, sel, .Red).columns < 10, "a selection is over custom highlights")
}

@(test)
a_highlight_paints_what_it_says :: proc(t: ^testing.T) {
	s := open_page(t, OVERLAP_PAGE)
	e2e.eval(s, `select("shadow"); 1`)
	e2e.wait_frames(s)
	img := e2e.capture(s)
	testing.expectf(t, ink_in(img, window_of(s, "#shadow"), .Red).columns > 20, "text-shadow")
	e2e.eval(s, `select("fill"); 1`)
	e2e.wait_frames(s)
	img = e2e.capture(s)
	box := window_of(s, "#fill")
	testing.expectf(t, ink_in(img, box, .Green).columns > 20 && ink_in(img, box, .Red).columns == 0, "-webkit-text-fill-color over color")
	e2e.eval(s, `select("stroke"); 1`)
	e2e.wait_frames(s)
	img = e2e.capture(s)
	testing.expectf(t, ink_in(img, window_of(s, "#stroke"), .Red).columns > 20, "-webkit-text-stroke-*")
	e2e.eval(s, `select("green"); 1`)
	e2e.wait_frames(s)
	img = e2e.capture(s)
	box = window_of(s, "#green")
	testing.expectf(t, ink_in(img, box, .Blue).columns == 0 && ink_in(img, box, .Green).columns == 0, "the text and its lines take the highlight's color")
	testing.expectf(t, ink_in(img, box, .Red).columns > 40, "%v", ink_in(img, box, .Red))
}

@(test)
a_highlight_cuts_the_text_it_is_over :: proc(t: ^testing.T) {
	s := open_page(t, `<style>
  body { font-size: 48px; line-height: 80px; text-decoration-skip-ink: none; }
  ::highlight(h) { color: #f00; background-color: #ff0; text-decoration: underline 2px #00f; }
  #rtl { direction: rtl; width: 400px; }
  #down { writing-mode: vertical-rl; height: 300px; }
  </style><p id=ltr>HHHHHH</p><p id=rtl dir=rtl>HHHHHH</p><div id=down>HHHHHH</div>
  <script>
  for (const id of ["ltr", "rtl", "down"]) {
    const r = new Range(), text = document.getElementById(id).firstChild;
    r.setStart(text, 2); r.setEnd(text, 4);
    (CSS.highlights.get("h") ?? CSS.highlights.set("h", new Highlight()).get("h")).add(r);
  }
  </script>`, {900, 700})
	img := e2e.capture(s)
	ltr := window_of(s, "#ltr")
	red, black := ink_in(img, ltr, .Red), ink_in(img, ltr, .Black)
	testing.expectf(t, red.columns > 20 && black.first_x < red.first_x && black.last_x > red.last_x, "the two middle ones: %v, %v", red, black)
	rtl := window_of(s, "#rtl")
	red, black = ink_in(img, rtl, .Red), ink_in(img, rtl, .Black)
	testing.expectf(t, red.columns > 20 && black.first_x < red.first_x && black.last_x > red.last_x, "the two middle ones, the other way: %v, %v", red, black)
	line := ink_in(img, rtl, .Blue)
	testing.expectf(t, line.first_x >= red.first_x - 8 && line.last_x <= red.last_x + 8 && line.columns > 20, "and its line over them alone: %v, %v", line, red)
	down := window_of(s, "#down")
	testing.expectf(t, ink_in(img, down, .Red).rows > 20 && ink_in(img, down, .Red).top > ink_in(img, down, .Black).top, "and down a column")
}

// What a frame's document highlights shows in its frame.
@(test)
a_frame_paints_its_highlights :: proc(t: ^testing.T) {
	s := open_page(t, `<iframe id=frame style="width: 400px; height: 120px; border: 0" srcdoc="<style>::highlight(h) { background-color: #f00; }</style><p id=p>Some words</p><script>
  const r = new Range(); r.selectNodeContents(document.getElementById(&quot;p&quot;)); CSS.highlights.set(&quot;h&quot;, new Highlight(r));</script>"></iframe>`)
	e2e.wait_idle(s)
	e2e.wait_frames(s)
	testing.expectf(t, ink_in(e2e.capture(s), window_of(s, "#frame")).columns > 40, "the background of ::highlight()")
}

// ::target-text: a URL's text directive marks it, and comes out of the URL.
@(test)
a_text_directive_is_target_text :: proc(t: ^testing.T) {
	s := open_page(t, `<style>::target-text { background-color: #f00; }</style>
  <p id=before>Some text before</p><p id=passage>The <b>wanted</b> words</p><p id=after>Some text after</p>`, url_tail = "#:~:text=wanted%20words")
	e2e.wait_frames(s)
	img := e2e.capture(s)
	testing.expectf(t, ink_in(img, window_of(s, "#passage")).columns > 60, "the passage, over two nodes")
	testing.expect_value(t, ink_in(img, window_of(s, "#before")).columns, 0)
	testing.expect_value(t, e2e.eval(s, "location.hash"), "")
}

@(test)
a_text_directive_has_a_context :: proc(t: ^testing.T) {
	s := open_page(t, `<p id=one>first word here</p><p id=two>second word here</p><style>::target-text { background-color: #f00; color: #fff; }</style>`, url_tail = "#:~:text=second-,word,-here")
	e2e.wait_frames(s)
	img := e2e.capture(s)
	testing.expect_value(t, ink_in(img, window_of(s, "#one")).columns, 0)
	testing.expectf(t, ink_in(img, window_of(s, "#two")).columns > 40, "after its prefix")
}

// What a spell checker flags: no rule, the UA's line; a rule, what it says. Under a selection, over custom highlights.
@(test)
errors_have_their_lines :: proc(t: ^testing.T) {
	s := open_page(t, `<style>
  body { text-decoration-skip-ink: none; }
  #styled::spelling-error { text-decoration: underline 3px #00f; }
  </style><p id=spelt>Some wrnog words</p><p id=grammar>Some wrnog words</p><p id=styled>Some wrnog words</p>`)
	e2e.mark_text(s, .Spelling_Error, "spelt", 5, 10)
	e2e.wait_frames(s)
	img := e2e.capture(s)
	box := window_of(s, "#spelt")
	wave := ink_in(img, box)
	testing.expectf(t, wave.rows > 2 && wave.first_x > int(box.x) + 20, "::spelling-error: a wave under its word: %v", wave)
	e2e.mark_text(s, .Grammar_Error, "grammar", 5, 10)
	e2e.wait_frames(s)
	img = e2e.capture(s)
	testing.expectf(t, ink_in(img, window_of(s, "#grammar"), .Green).rows > 2, "::grammar-error, green")
	e2e.mark_text(s, .Spelling_Error, "styled", 5, 10)
	e2e.wait_frames(s)
	img = e2e.capture(s)
	blue := ink_in(img, window_of(s, "#styled"), .Blue)
	testing.expectf(t, blue.rows == 3 && blue.gaps == 0, "what the rule says: %v", blue)
}

// Under a busy script a page is painted again from its last layout, with all of it: the wheel moves it, and every colour shows as it did.
@(private = "file") BUSY_DECO_PAGE :: `<style>
  body { height: 3000px; }
  #space { height: 260px; }
  #lines { color: transparent; text-decoration: underline 2px #f00; text-underline-offset: 3px; text-shadow: 0 8px #00f; }
  #marks { text-emphasis: dot #f00; line-height: 100px; }
  ::highlight(h) { background-color: #00f; color: #fff; text-decoration: overline 3px #f00; }
  #marked::selection { background-color: #0a0; color: #fff; }
</style>
<div id=space></div><p id=lines>gypsy jpg</p><p id=marks>abc</p><p id=marked>Selected words</p><p id=high>Highlighted words</p>
<script>
  const r = new Range(); r.selectNodeContents(document.getElementById("high"));
  CSS.highlights.set("h", new Highlight(r));
  getSelection().selectAllChildren(document.getElementById("marked"));
  window.hold = () => {
    window.released = false;
    setTimeout(() => { const h = innerHeight; while (innerHeight == h) {} window.released = true; }, 0);
    return "held";
  };
</script>`

// More than a notch of the wheel moves the page.
@(private = "file") BUSY_WHEEL_REACH :: 240

@(test)
all_of_it_shows_in_chrome_frames :: proc(t: ^testing.T) {
	s := open_page(t, BUSY_DECO_PAGE)
	top, end := window_of(s, "#lines"), window_of(s, "#high")
	area := e2e.Rect{0, top.y - BUSY_WHEEL_REACH, f64(DECO_SIZE.x) - 40, end.y + end.h - top.y + BUSY_WHEEL_REACH + 20}
	before := e2e.capture(s, {target = .Window})
	e2e.eval(s, "hold()")
	e2e.while_busy(s, {e2e.busy_wheel(s, 1, {300, 300}), e2e.busy_capture(), e2e.busy_resize({DECO_SIZE.x - 40, DECO_SIZE.y - 30})})
	e2e.wait_js(s, "window.released === true")
	shots := e2e.busy_shots(s)
	testing.expect_value(t, len(shots), 1)
	for hue in Hue {
		a, b := ink_in(before, area, hue), ink_in(shots[0], area, hue)
		testing.expectf(t, a.columns == b.columns && a.gaps == b.gaps && a.rows == b.rows, "%v: %v, then %v", hue, a, b)
		testing.expectf(t, a.top != b.top, "%v: the wheel moved it: %v, %v", hue, a, b)
	}
}

@(test)
computed_values_read_back :: proc(t: ^testing.T) {
	s := open_page(t, `<style>
  #a { text-decoration: underline 25% wavy #f00; text-underline-offset: 50%; text-underline-position: under left; text-decoration-skip-ink: all;
       text-decoration-skip-spaces: all; text-decoration-inset: 2px 3px; text-emphasis: open triangle #00f; text-emphasis-position: under left; -webkit-text-stroke: 2px #0f0; }
  #b { text-decoration: spelling-error; text-decoration-thickness: from-font; text-emphasis-style: "x"; text-underline-position: from-font; text-decoration-inset: auto; }
  #c { text-decoration-line: underline spelling-error; text-underline-offset: from-font; text-decoration-thickness: medium; }
  </style><p id=a>x</p><p id=b>x</p><p id=c>x</p>`)
	value :: proc(s: ^e2e.Session, id, prop: string) -> string { return e2e.eval(s, fmt.tprintf(`getComputedStyle(document.getElementById("%s")).getPropertyValue("%s")`, id, prop)) }
	testing.expect_value(t, value(s, "a", "text-decoration-thickness"), "25%")
	testing.expect_value(t, value(s, "a", "text-underline-offset"), "50%")
	testing.expect_value(t, value(s, "a", "text-underline-position"), "under left")
	testing.expect_value(t, value(s, "a", "text-decoration-skip-ink"), "all")
	testing.expect_value(t, value(s, "a", "text-decoration-skip-spaces"), "all")
	testing.expect_value(t, value(s, "a", "text-decoration-inset"), "2px 3px")
	testing.expect_value(t, value(s, "a", "text-emphasis-style"), "open triangle")
	testing.expect_value(t, value(s, "a", "text-emphasis-color"), "rgb(0, 0, 255)")
	testing.expect_value(t, value(s, "a", "text-emphasis-position"), "under left")
	testing.expect_value(t, value(s, "a", "-webkit-text-stroke-width"), "2px")
	testing.expect_value(t, value(s, "a", "-webkit-text-stroke-color"), "rgb(0, 255, 0)")
	testing.expect_value(t, value(s, "b", "text-decoration-line"), "spelling-error")
	testing.expect_value(t, value(s, "b", "text-decoration-thickness"), "from-font")
	testing.expect_value(t, value(s, "b", "text-emphasis-style"), `"x"`)
	testing.expect_value(t, value(s, "b", "text-underline-position"), "from-font")
	testing.expect_value(t, value(s, "b", "text-decoration-inset"), "auto")
	testing.expect_value(t, value(s, "c", "text-decoration-line"), "none")   // (an error's line is alone)
	testing.expect_value(t, value(s, "c", "text-underline-offset"), "auto")   // (no `from-font` in the draft's grammar)
	testing.expect_value(t, value(s, "c", "text-decoration-thickness"), "3px")
}

_ :: style
