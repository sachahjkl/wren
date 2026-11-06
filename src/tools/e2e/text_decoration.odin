package e2e_scenarios

// The lines of text decoration by their pixels: every style of text-decoration-style was a solid line, and ::highlight() and ::selection drew none.

import "core:testing"
import "wb:e2e"

@(private = "file") DECO_SIZE :: [2]int{900, 700}
@(private = "file") DECO_PAGE :: `<!doctype html><style>
  body { margin: 20px; background: #fff; color: #000; font: 32px/60px sans-serif; }
  p { margin: 0; text-decoration-color: #f00; text-decoration-thickness: 2px; }
  #solid { text-decoration-line: underline; }
  #double { text-decoration-line: underline; text-decoration-style: double; }
  #dotted { text-decoration-line: underline; text-decoration-style: dotted; }
  #wavy { text-decoration-line: underline; text-decoration-style: wavy; }
  #far { text-decoration-line: underline; text-underline-offset: 14px; }
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

// What a band of the picture holds of pure red, the colour of the lines.
@(private = "file")
Red :: struct {
	rows:     int,   // rows with some
	bands:    int,   // runs of such rows
	columns:  int,   // columns with some
	gaps:     int,   // runs of columns without any between two with some
	first_x:  int,
	last_x:   int,
	top:      int,
}

@(private = "file")
red_in :: proc(img: e2e.Image, box: e2e.Rect) -> (r: Red) {
	r.first_x, r.top = -1, -1
	was_row := false
	was_column, seen := false, false
	for y in int(box.y) ..< int(box.y + box.h) {
		row := false
		for x in int(box.x) ..< int(box.x + box.w) { if is_red(e2e.pixel(img, x, y).rgb) { row = true; break } }
		if row {
			r.rows += 1
			if r.top < 0 { r.top = y }
			if !was_row { r.bands += 1 }
		}
		was_row = row
	}
	for x in int(box.x) ..< int(box.x + box.w) {
		column := false
		for y in int(box.y) ..< int(box.y + box.h) { if is_red(e2e.pixel(img, x, y).rgb) { column = true; break } }
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

@(private = "file")
is_red :: proc(c: [3]u8) -> bool { return c[0] > 200 && c[1] < 60 && c[2] < 60 }

@(private = "file")
open_page :: proc(t: ^testing.T) -> ^e2e.Session {
	s := e2e.start(t, {size = DECO_SIZE, dpi = e2e.DPI_ONE})
	e2e.navigate(s, e2e.file_page(e2e.temp_folder(t), "deco.html", DECO_PAGE))
	e2e.wait_frames(s)
	return s
}

@(test)
each_style_of_a_line_is_drawn_as_it_says :: proc(t: ^testing.T) {
	s := open_page(t)
	img := e2e.capture(s)
	solid := red_in(img, e2e.box_model(s, "#solid").window)
	double := red_in(img, e2e.box_model(s, "#double").window)
	dotted := red_in(img, e2e.box_model(s, "#dotted").window)
	wavy := red_in(img, e2e.box_model(s, "#wavy").window)
	far := red_in(img, e2e.box_model(s, "#far").window)
	testing.expectf(t, solid.bands == 1 && solid.gaps == 0 && solid.rows == 2, "a solid line, 2 px: %v", solid)
	testing.expectf(t, double.bands == 2 && double.gaps == 0, "a double line is two: %v", double)
	testing.expectf(t, dotted.bands == 1 && dotted.gaps > solid.columns / 8, "a dotted line has gaps: %v", dotted)
	testing.expectf(t, wavy.rows > solid.rows && wavy.gaps == 0, "a wave goes up and down, unbroken: %v", wavy)
	testing.expectf(t, far.top > solid.top - int(e2e.box_model(s, "#solid").window.y) + int(e2e.box_model(s, "#far").window.y), "text-underline-offset moves it down: %v, %v", far, solid)
}

@(test)
a_highlight_draws_its_line_under_its_words_alone :: proc(t: ^testing.T) {
	s := open_page(t)
	box := e2e.box_model(s, "#marked").window
	marked := red_in(e2e.capture(s), box)
	testing.expectf(t, marked.rows > 2, "the wave of ::highlight(): %v", marked)
	testing.expectf(t, marked.first_x > int(box.x) && marked.columns < int(box.w) / 3, "over its range only: %v of %v", marked, box)
}

@(test)
a_selection_draws_the_line_of_its_rule :: proc(t: ^testing.T) {
	s := open_page(t)
	box := e2e.box_model(s, "#sel").window
	testing.expect_value(t, red_in(e2e.capture(s), box).rows, 0)
	e2e.eval(s, `getSelection().selectAllChildren(document.getElementById("sel")); 1`)
	e2e.wait_frames(s)
	testing.expectf(t, red_in(e2e.capture(s), box).rows > 0, "the underline of #sel::selection")
}
