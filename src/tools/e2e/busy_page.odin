package e2e_scenarios

// What the user does while the page's script keeps the thread (examples/site/busy_probe.html hold(): one task that runs until the
// window's height changes). The input comes in the chrome frames made under that task, one step a frame (e2e.while_busy), and
// the pictures are those frames'; the last step changes the window's height and lets the task end. Then the page's turn:
//   * a drag over the text shows its selection under the task (painted from the page's last layout), the task saw none of
//     it (no selectionchange, an empty getSelection()), and once it ran the selection is the one the drag made; with a
//     mousemove listener the drag waits for the page as before, and selects the same;
//   * so does a drag whose press came under the task (but on the selection, or with a mousedown listener: it waits), and past
//     the view's edge the drag scrolls the page under the task;
//   * the thumb of the document's scroll bar and Page Down scroll the page under the task, with what was below the fold
//     painted (the busy frame is the page as it shows once it ran), and the presses on the bar are not the page's;
//   * Ctrl+L takes the address bar under the task;
//   * a slide (transform) and a fade (opacity) go on under the task, and the page's turn goes on from the same clock;
//   * the wheel over the scroll box and the thumb of its bar scroll it under the task (not the document), the task saw
//     none of it, the box took the offset and fired its scroll event once it ran;
//   * the focused field's caret blinks under the task.

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") SIZE :: [2]int{1000, 700}
@(private = "file") SHORTER :: [2]int{1000, 690}   // what lets the task go
@(private = "file") HIGHLIGHT :: "#00c000"
@(private = "file") HIGHLIGHT_RGB :: [3]u8{0x00, 0xc0, 0x00}
@(private = "file") CHANNEL_WITHIN :: 24          // a pixel of the highlight: each channel within this
@(private = "file") HIGHLIGHT_LEAST :: 2000       // pixels of the highlight in the selected words, at least
@(private = "file") DRAG_FROM_X :: 4              // from the line's left edge (CSS px)
@(private = "file") DRAG_TO_X :: 400              // where the drag ends: past "Select this line of words"
@(private = "file") DRAG_MID_X :: 200
@(private = "file") THUMB_GRAB_Y :: 20            // below the bar's top arrow (CSS px past it): on the thumb at the top of the page
@(private = "file") THUMB_MOVE :: 100
@(private = "file") SAME_WITHIN :: 24             // two pictures of the same page: each channel within this...
@(private = "file") SAME_MOST_DIFFERENT :: 200    // ... but for this many pixels (the edges of the glyphs)
@(private = "file") SCROLLED_LEAST :: 50          // the page moved at least this much (CSS px)
@(private = "file") EDGE_MOVED_LEAST :: 8         // a drag past the edge in a fixed time: that it moved, a slow machine makes fewer frames (px)
@(private = "file") EMPTY :: e2e.Point{500, 500}   // the tall box under everything: a press there selects nothing and gives the page the keyboard
@(private = "file") NO_MOUSEDOWN :: "document.removeEventListener('mousedown', down); 1"   // the page's own count of presses, which would have them run its code
@(private = "file") PAST_EDGE :: 30               // how far below the view a drag goes (CSS px)
@(private = "file") CLICK_PAST_WORDS :: 8         // past the end of the words dragged over, on the line (CSS px)
@(private = "file") TINT_LEAST :: 160            // the channel of a ::selection colour, at least...
@(private = "file") TINT_MOST :: 60              // ... and the others, at most
@(private = "file") TINT_PIXELS :: 40            // pixels of each colour along the line, at least
@(private = "file") EDGE_WAIT_MS :: 300           // under the task, with the pointer there

// The animations the compositor runs: a box slid sideways and one faded, both linear, long enough to be under way all along.
@(private = "file") SLIDE_PX :: 800
@(private = "file") FADE_FROM :: 0.9
@(private = "file") FADE_TO :: 0.1
@(private = "file") ANIM_S :: 4
@(private = "file") ANIM_WAIT_MS :: 400         // between the two pictures under the task: 80 px of the slide, 0.08 of the fade
@(private = "file") SLID_LEAST :: 40            // px the box moved between them, at least (half what the clock gives)
@(private = "file") FADED_LEAST :: 10           // the faded box's red channel rose this much, at least (white shows through)
@(private = "file") BOX_COLOR :: [3]u8{0x00, 0x88, 0xaa}   // .moving's background
// The caret: one picture in the middle of each half period, on the test's clock (e2e.busy_clock): shown, hidden, shown...
@(private = "file") CARET_BLINK_MS :: 200
@(private = "file") CARET_SHOTS :: 6
// The scroll box: the wheel over it, then its thumb.
@(private = "file") BOX_THUMB_GRAB :: 4      // below its bar's top arrow (CSS px): on the thumb, short as it is (40 lines in the box)
@(private = "file") BOX_THUMB_MOVE :: 40

@(private = "file")
open :: proc(t: ^testing.T, extra: []string = nil, loc := #caller_location) -> ^e2e.Session {
	prefs := make([dynamic]string, context.temp_allocator)
	append(&prefs, fmt.tprintf("browser.selection.background=%s", HIGHLIGHT), fmt.tprintf("browser.selection.inactive_background=%s", HIGHLIGHT))
	append(&prefs, ..extra)
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, pixels = true, prefs = prefs[:], url = e2e.file_url(fmt.tprintf("%s/examples/site/busy_probe.html", e2e.repo_root()))}, loc)
	e2e.wait_idle(s)
	e2e.eval(s, "for (const e of document.querySelectorAll('.moving')) e.style.animation = 'none'; 1")   // (two pictures of the page are alike)
	e2e.wait_frames(s)
	return s
}

// The task holds the thread while `steps` are taken, then lets go; the pictures of the capture steps.
@(private = "file")
while_held :: proc(s: ^e2e.Session, short: ^bool, steps: []e2e.Busy_Step, hold := "hold()", loc := #caller_location) -> []e2e.Image {
	short^ = !short^
	size := short^ ? SHORTER : SIZE
	all := make([dynamic]e2e.Busy_Step, context.temp_allocator)
	append(&all, ..steps)
	append(&all, e2e.busy_resize(size))
	e2e.wait_frames(s, loc = loc)   // (what the page last painted is what it is now: what the chrome frames paint again)
	e2e.eval(s, hold, loc = loc)
	e2e.while_busy(s, all[:], loc)
	e2e.wait_js(s, "window.released === true", loc = loc)
	testing.expectf(s.t, e2e.busy_left(s, loc) == 0, "every step was taken under the task", loc = loc)
	return e2e.busy_shots(s, loc)
}

// The topmost row of the picture with some of the highlight (-1: none).
@(private = "file")
highlight_top :: proc(img: e2e.Image) -> int {
	for y in 0 ..< img.height {
		if highlighted(img, {0, f64(y), f64(img.width), 1}) > 0 { return y }
	}
	return -1
}

@(private = "file")
highlighted :: proc(img: e2e.Image, r: e2e.Rect) -> int {
	n := 0
	for y in int(r.y) ..< int(r.y + r.h) {
		for x in int(r.x) ..< int(r.x + r.w) {
			c := e2e.pixel(img, x, y)
			if abs(int(c[0]) - int(HIGHLIGHT_RGB[0])) <= CHANNEL_WITHIN && abs(int(c[1]) - int(HIGHLIGHT_RGB[1])) <= CHANNEL_WITHIN && abs(int(c[2]) - int(HIGHLIGHT_RGB[2])) <= CHANNEL_WITHIN { n += 1 }
		}
	}
	return n
}

@(private = "file")
differing :: proc(a, b: e2e.Image, r: e2e.Rect) -> int {
	n := 0
	for y in int(r.y) ..< int(r.y + r.h) {
		for x in int(r.x) ..< int(r.x + r.w) {
			pa, pb := e2e.pixel(a, x, y), e2e.pixel(b, x, y)
			for k in 0 ..< 3 { if abs(int(pa[k]) - int(pb[k])) > SAME_WITHIN { n += 1; break } }
		}
	}
	return n
}

@(test)
a_drag_selects_while_the_page_is_busy :: proc(t: ^testing.T) {
	s := open(t)
	short := false
	line := e2e.box_model(s, "#sel")
	y := line.box.y + line.box.h / 2
	from, mid, to := e2e.Point{line.box.x + DRAG_FROM_X, y}, e2e.Point{line.box.x + DRAG_MID_X, y}, e2e.Point{line.box.x + DRAG_TO_X, y}
	words := e2e.Rect{line.window.x, line.window.y, DRAG_MID_X, line.window.h}   // what both moves select

	e2e.press(s, from)
	changes := e2e.eval(s, "String(window.changes)")
	shots := while_held(s, &short, {e2e.busy_capture(), e2e.busy_move(s, mid), e2e.busy_move(s, to), e2e.busy_capture(), e2e.busy_release(s, to)})
	testing.expectf(t, highlighted(shots[0], words) == 0, "no highlight before the drag: %d px", highlighted(shots[0], words))
	testing.expectf(t, highlighted(shots[1], words) >= HIGHLIGHT_LEAST, "the drag's selection shows under the task: %d px of the highlight", highlighted(shots[1], words))
	testing.expect_value(t, e2e.eval(s, "held.selection"), "")   // the task saw none of it
	testing.expect_value(t, e2e.eval(s, "String(held.changes)"), changes)
	selected := e2e.eval(s, "String(getSelection())")
	testing.expectf(t, len(selected) > len("Select this line") && e2e.eval(s, "'Select this line of words while the page is busy.'.startsWith(String(getSelection()))") == "true", "the page's turn selected what the drag showed: %q", selected)
	e2e.wait_js(s, fmt.tprintf("window.changes > %s", changes))   // selectionchange, once the page had its turn
	// the release under the task was the page's too: the gesture is over, a move selects nothing more
	e2e.hover(s, from)
	testing.expect_value(t, e2e.eval(s, "String(getSelection())"), selected)

	// a mousemove listener: the moves are the page's to see first, the drag waits for its turn (and selects the same)
	e2e.click_at(s, EMPTY)
	e2e.eval(s, "window.moves = 0; document.addEventListener('mousemove', () => { window.moves++ }); 1")
	e2e.press(s, from)
	shots = while_held(s, &short, {e2e.busy_move(s, mid), e2e.busy_move(s, to), e2e.busy_capture()})
	testing.expectf(t, highlighted(shots[0], words) == 0, "with a mousemove listener nothing shows before the page's turn: %d px", highlighted(shots[0], words))
	e2e.release(s, to)
	testing.expect_value(t, e2e.eval(s, "String(getSelection())"), selected)
	testing.expectf(t, e2e.eval_f64(s, "window.moves") >= 1, "the page saw the moves")
}

// The line's own drag, begun under the task: the press waits for the page with its moves, and the highlight does not.
@(test)
a_drag_begun_under_the_task_shows_from_its_press :: proc(t: ^testing.T) {
	s := open(t)
	short := false
	line := e2e.box_model(s, "#sel")
	y := line.box.y + line.box.h / 2
	from, mid, to := e2e.Point{line.box.x + DRAG_FROM_X, y}, e2e.Point{line.box.x + DRAG_MID_X, y}, e2e.Point{line.box.x + DRAG_TO_X, y}
	words := e2e.Rect{line.window.x, line.window.y, DRAG_MID_X, line.window.h}
	e2e.eval(s, NO_MOUSEDOWN)

	shots := while_held(s, &short, {e2e.busy_press(s, from), e2e.busy_move(s, mid), e2e.busy_move(s, to), e2e.busy_capture(), e2e.busy_release(s, to)})
	testing.expectf(t, highlighted(shots[0], words) >= HIGHLIGHT_LEAST, "the drag shows before its press had its turn: %d px of the highlight", highlighted(shots[0], words))
	testing.expect_value(t, e2e.eval(s, "held.selection"), "")   // the task saw none of it
	selected := e2e.eval(s, "String(getSelection())")
	testing.expectf(t, len(selected) > len("Select this line"), "the page's turn selected what the drag showed: %q", selected)

	// a press on the selection may drag it: it stays as it is
	shots = while_held(s, &short, {e2e.busy_press(s, mid), e2e.busy_capture(), e2e.busy_release(s, mid)})
	testing.expectf(t, highlighted(shots[0], words) >= HIGHLIGHT_LEAST, "a press on the selection leaves it shown: %d px", highlighted(shots[0], words))

	// a mousedown listener may cancel the press: the gesture waits for its turn, and selects the same
	e2e.click_at(s, EMPTY)
	e2e.eval(s, "document.addEventListener('mousedown', down); 1")
	shots = while_held(s, &short, {e2e.busy_press(s, from), e2e.busy_move(s, mid), e2e.busy_move(s, to), e2e.busy_capture(), e2e.busy_release(s, to)})
	testing.expectf(t, highlighted(shots[0], words) == 0, "with a mousedown listener nothing shows before the page's turn: %d px", highlighted(shots[0], words))
	testing.expect_value(t, e2e.eval(s, "String(getSelection())"), selected)
}

// A click elsewhere takes the selection away at once, under the task as on a page at rest: on text, on nothing, and it is what the page's turn does too.
@(test)
a_click_elsewhere_clears_the_selection_under_the_task :: proc(t: ^testing.T) {
	s := open(t)
	short := false
	line := e2e.box_model(s, "#sel")
	y := line.box.y + line.box.h / 2
	from, to := e2e.Point{line.box.x + DRAG_FROM_X, y}, e2e.Point{line.box.x + DRAG_TO_X, y}
	words := e2e.Rect{line.window.x, line.window.y, DRAG_TO_X, line.window.h}
	e2e.eval(s, NO_MOUSEDOWN)
	for elsewhere, i in ([]e2e.Point{EMPTY, {line.box.x + DRAG_TO_X + CLICK_PAST_WORDS, y}}) {
		e2e.press(s, from)
		e2e.hover(s, to)
		e2e.release(s, to)
		e2e.wait_frames(s)
		testing.expect(t, e2e.eval(s, "String(getSelection())") != "", "a selection to take away")
		shots := while_held(s, &short, {e2e.busy_capture(), e2e.busy_press(s, elsewhere), e2e.busy_capture(), e2e.busy_release(s, elsewhere), e2e.busy_capture()})
		testing.expectf(t, highlighted(shots[0], words) >= HIGHLIGHT_LEAST, "click %d: the selection is on screen first: %d px", i, highlighted(shots[0], words))
		testing.expectf(t, highlighted(shots[1], words) == 0, "click %d: the press took it away: %d px left", i, highlighted(shots[1], words))
		testing.expectf(t, highlighted(shots[2], words) == 0, "click %d: it stays away: %d px left", i, highlighted(shots[2], words))
		testing.expect_value(t, e2e.eval(s, "String(getSelection())"), "")
	}
}

// The task changed the document, and a click's press and release have their turn together: the press waits for a layout, its release must not end it. The click was lost, the selection
// stayed, and what the chrome frames had taken away came back.
@(test)
a_click_whose_press_waits_for_a_layout_still_clears_the_selection :: proc(t: ^testing.T) {
	s := open(t)
	short := false
	line := e2e.box_model(s, "#sel")
	y := line.box.y + line.box.h / 2
	from, to := e2e.Point{line.box.x + DRAG_FROM_X, y}, e2e.Point{line.box.x + DRAG_TO_X, y}
	e2e.eval(s, NO_MOUSEDOWN)
	e2e.press(s, from)
	e2e.hover(s, to)
	e2e.release(s, to)
	e2e.wait_frames(s)
	testing.expect(t, e2e.eval(s, "String(getSelection())") != "", "a selection to take away")
	while_held(s, &short, {e2e.busy_press(s, EMPTY), e2e.busy_release(s, EMPTY)}, "hold(true)")
	e2e.wait_frames(s)
	e2e.wait_frames(s)
	testing.expect_value(t, e2e.eval(s, "String(getSelection())"), "")
}

// What a chrome frame shows of a drag has each word's own ::selection colour, as the page's frame would.
@(test)
each_word_keeps_its_selection_colour_under_the_task :: proc(t: ^testing.T) {
	s := open(t)
	short := false
	line := e2e.box_model(s, "#tinted")
	y := line.box.y + line.box.h / 2
	from, to := e2e.Point{line.box.x + DRAG_FROM_X, y}, e2e.Point{line.box.x + line.box.w - DRAG_FROM_X, y}
	e2e.eval(s, NO_MOUSEDOWN)
	shots := while_held(s, &short, {e2e.busy_press(s, from), e2e.busy_move(s, to), e2e.busy_capture(), e2e.busy_release(s, to)})
	red, blue := 0, 0
	for x in int(line.window.x) ..< int(line.window.x + line.window.w) {
		c := e2e.pixel(shots[0], x, int(line.window.y + line.window.h / 2))
		if c[0] > TINT_LEAST && c[1] < TINT_MOST && c[2] < TINT_MOST { red += 1 }
		if c[2] > TINT_LEAST && c[0] < TINT_MOST && c[1] < TINT_MOST { blue += 1 }
	}
	testing.expectf(t, red >= TINT_PIXELS && blue >= TINT_PIXELS, "both colours under the task: %d red, %d blue pixels of the line", red, blue)
}

// The task changed the document: the press's turn finds the layout old and the gesture begins a frame later, from where the moves that came with it left the pointer.
@(test)
a_press_that_waits_for_a_layout_keeps_its_moves :: proc(t: ^testing.T) {
	s := open(t)
	short := false
	line := e2e.box_model(s, "#sel")
	y := line.box.y + line.box.h / 2
	from, to := e2e.Point{line.box.x + DRAG_FROM_X, y}, e2e.Point{line.box.x + DRAG_TO_X, y}
	e2e.eval(s, NO_MOUSEDOWN)
	while_held(s, &short, {e2e.busy_press(s, from), e2e.busy_move(s, to)}, "hold(true)")
	e2e.wait_js(s, "String(getSelection()).length > 'Select this'.length")
	e2e.release(s, to)
}

// Past the bottom of the view the drag scrolls the page under the task, and what comes into view is selected: the highlight's top goes up with the line it began on.
@(test)
a_drag_past_the_edge_scrolls_under_the_task :: proc(t: ^testing.T) {
	s := open(t)
	short := false
	line := e2e.box_model(s, "#sel")
	y := line.box.y + line.box.h / 2
	from, mid := e2e.Point{line.box.x + DRAG_FROM_X, y}, e2e.Point{line.box.x + DRAG_MID_X, y}
	below := e2e.Point{line.box.x + DRAG_MID_X, e2e.eval_f64(s, "innerHeight") + PAST_EDGE}

	e2e.press(s, from)
	shots := while_held(s, &short, {e2e.busy_move(s, mid), e2e.busy_capture(), e2e.busy_move(s, below), e2e.busy_wait(EDGE_WAIT_MS), e2e.busy_capture()})
	top0, top1 := highlight_top(shots[0]), highlight_top(shots[1])
	testing.expectf(t, top0 >= 0 && top1 >= 0 && top0 - top1 >= EDGE_MOVED_LEAST, "the page moved under the task: the highlight's top at %d, then at %d", top0, top1)
	testing.expect_value(t, e2e.eval_f64(s, "held.scrollY"), 0)   // the task saw none of it
	testing.expectf(t, e2e.eval_f64(s, "scrollY") >= EDGE_MOVED_LEAST, "the document took the offset: %s", e2e.eval(s, "String(scrollY)"))
	testing.expect_value(t, e2e.eval(s, "String(getSelection()).includes('While the page runs')"), "true")
	e2e.release(s, below)
}

@(test)
the_scroll_bar_and_the_keys_scroll_a_busy_page :: proc(t: ^testing.T) {
	s := open(t)
	short := false
	page := e2e.box_model(s, "html").window
	inner := e2e.eval_f64(s, "innerWidth")
	bar := inner - e2e.eval_f64(s, "document.documentElement.clientWidth")
	view := e2e.Rect{page.x, page.y, inner - bar, e2e.eval_f64(s, "innerHeight") - f64(SIZE.y - SHORTER.y) - bar}   // the page area less its bars, in every size the window takes

	// the thumb: a press on it, a move down, the release, all under the task
	grab := e2e.Point{inner - bar / 2, bar + THUMB_GRAB_Y}
	downs := e2e.eval(s, "String(window.downs)")
	shots := while_held(s, &short, {e2e.busy_press(s, grab), e2e.busy_move(s, grab + {0, THUMB_MOVE}), e2e.busy_release(s, grab + {0, THUMB_MOVE}), e2e.busy_capture()})
	testing.expect_value(t, e2e.eval(s, "String(held.scrollY)"), "0")   // the task did not see it move
	testing.expectf(t, e2e.eval_f64(s, "scrollY") >= SCROLLED_LEAST, "the page took the thumb's position: %s", e2e.eval(s, "String(scrollY)"))
	after := e2e.capture(s, {target = .Window})
	testing.expectf(t, differing(shots[0], after, view) <= SAME_MOST_DIFFERENT, "the busy frame is the page as it shows once it ran: %d px differ", differing(shots[0], after, view))
	testing.expect_value(t, e2e.eval(s, "String(window.downs)"), downs)   // the bar's presses are not the page's

	// Page Down with the page's keyboard and no key listener
	e2e.eval(s, "scrollTo(0, 0); 1")
	e2e.click_at(s, EMPTY)
	shots = while_held(s, &short, {e2e.busy_key(s, "PageDown", true), e2e.busy_key(s, "PageDown", false), e2e.busy_capture()})
	testing.expectf(t, e2e.eval_f64(s, "scrollY") >= SCROLLED_LEAST, "Page Down scrolled the page: %s", e2e.eval(s, "String(scrollY)"))
	after = e2e.capture(s, {target = .Window})
	testing.expectf(t, differing(shots[0], after, view) <= SAME_MOST_DIFFERENT, "the busy frame is the page as Page Down left it: %d px differ", differing(shots[0], after, view))

	// Ctrl+L: the address bar takes the keyboard under the task
	field := e2e.urlbar(s).field
	ctrl_down := e2e.Busy_Step{kind = .Event, ev = {kind = .Key_Press, key = .Ctrl, mods = {.Ctrl}}}
	ctrl_up := e2e.Busy_Step{kind = .Event, ev = {kind = .Key_Release, key = .Ctrl}}
	shots = while_held(s, &short, {e2e.busy_capture(), ctrl_down, e2e.busy_key(s, "Ctrl+L", true), e2e.busy_key(s, "Ctrl+L", false), ctrl_up, e2e.busy_capture()})
	testing.expectf(t, differing(shots[0], shots[1], field) > 0, "the address field took the keyboard under the task")
}

// The first x at or right of `from` on row `y` where the slid box shows (-1: nowhere).
@(private = "file")
box_left :: proc(img: e2e.Image, y, from: int) -> int {
	for x in max(from, 0) ..< img.width {
		c := e2e.pixel(img, x, y)
		if abs(int(c[0]) - int(BOX_COLOR[0])) <= CHANNEL_WITHIN && abs(int(c[1]) - int(BOX_COLOR[1])) <= CHANNEL_WITHIN && abs(int(c[2]) - int(BOX_COLOR[2])) <= CHANNEL_WITHIN { return x }
	}
	return -1
}

@(test)
animations_of_transform_and_opacity_go_on_while_the_page_is_busy :: proc(t: ^testing.T) {
	s := open(t, {"style.animations.mode=normal"})   // (whatever the system's reduced motion)
	short := false
	slid, faded := e2e.box_model(s, "#hoverbox").window, e2e.box_model(s, "#pulse").window
	e2e.eval(s, fmt.tprintf(`const k = document.head.appendChild(document.createElement("style"));
		k.textContent = "@keyframes slide {{ to {{ transform: translateX(%dpx) }} }} @keyframes fade {{ from {{ opacity: %v }} to {{ opacity: %v }} }}";
		document.getElementById("hoverbox").style.animation = "slide %ds linear forwards";
		document.getElementById("pulse").style.animation = "fade %ds linear forwards";
		window.began = performance.now(); 1`, SLIDE_PX, FADE_FROM, FADE_TO, ANIM_S, ANIM_S))
	row := int(slid.y + slid.h / 2)
	mid := e2e.Point{faded.x + faded.w / 2, faded.y + faded.h / 2}
	shots := while_held(s, &short, {e2e.busy_capture(), e2e.busy_wait(ANIM_WAIT_MS), e2e.busy_capture()})
	x0, x1 := box_left(shots[0], row, int(slid.x) - 1), box_left(shots[1], row, int(slid.x) - 1)
	testing.expectf(t, x0 >= 0 && x1 - x0 >= SLID_LEAST, "the slide goes on under the task: the box at x %d, then %d", x0, x1)
	r0, r1 := int(e2e.pixel(shots[0], int(mid.x), int(mid.y))[0]), int(e2e.pixel(shots[1], int(mid.x), int(mid.y))[0])
	testing.expectf(t, r1 - r0 >= FADED_LEAST, "the fade goes on under the task: red %d, then %d", r0, r1)
	// the page's turn: its timeline went by the same clock (the chrome frames did not move it), and the box goes on from there
	// (two orders, not a window: the frame the page last had is a moment that the machine's load decides)
	times := e2e.eval(s, fmt.tprintf(`(() => {{ const at = document.getElementById("hoverbox").getAnimations()[0].currentTime, since = performance.now() - window.began; return at + " " + since + " " + (at >= %d && at <= since + 1); }})()`, ANIM_WAIT_MS))
	testing.expectf(t, strings.has_suffix(times, " true"), "the animation's time at the page's turn is the clock's: past the wait under the task, not past the time since it began (time, since: %s)", times)
	after := e2e.capture(s, {target = .Window})
	testing.expectf(t, box_left(after, row, int(slid.x) - 1) >= x1, "no jump back once the page has its turn: at x %d, %d under the task", box_left(after, row, int(slid.x) - 1), x1)
}

@(test)
a_scroll_box_scrolls_while_the_page_is_busy :: proc(t: ^testing.T) {
	s := open(t)
	short := false
	box := e2e.box_model(s, "#scroller")
	at := e2e.Point{box.box.x + box.box.w / 2, box.box.y + box.box.h / 2}
	scrolls := e2e.eval(s, "String(window.boxScrolls)")

	// the wheel over it: the box scrolls under the task, not the document
	shots := while_held(s, &short, {e2e.busy_capture(), e2e.busy_wheel(s, 1, at), e2e.busy_capture()})
	testing.expect_value(t, e2e.eval(s, "String(held.boxTop)"), "0")   // the task did not see it move
	testing.expectf(t, e2e.eval_f64(s, "scroller.scrollTop") >= SCROLLED_LEAST, "the box took the wheel's offset: %s", e2e.eval(s, "String(scroller.scrollTop)"))
	testing.expect_value(t, e2e.eval(s, "String(scrollY)"), "0")
	testing.expectf(t, differing(shots[0], shots[1], box.window) > SAME_MOST_DIFFERENT, "the box moved under the task: %d px differ", differing(shots[0], shots[1], box.window))
	e2e.wait_js(s, fmt.tprintf("window.boxScrolls > %s", scrolls))   // its scroll event, at the page's turn
	after := e2e.capture(s, {target = .Window})
	testing.expectf(t, differing(shots[1], after, box.window) <= SAME_MOST_DIFFERENT, "the busy frame is the box as it shows once the page ran: %d px differ", differing(shots[1], after, box.window))

	// the thumb of its bar: a press on it, a move down, the release, all under the task
	e2e.eval(s, "scroller.scrollTop = 0; 1")
	e2e.wait_frames(s)
	bar := e2e.eval_f64(s, "scroller.offsetWidth - scroller.clientWidth - 2")   // (less its two borders)
	grab := e2e.Point{box.box.x + box.box.w - 1 - bar / 2, box.box.y + 1 + bar + BOX_THUMB_GRAB}
	downs := e2e.eval(s, "String(window.downs)")
	shots = while_held(s, &short, {e2e.busy_press(s, grab), e2e.busy_move(s, grab + {0, BOX_THUMB_MOVE}), e2e.busy_release(s, grab + {0, BOX_THUMB_MOVE}), e2e.busy_capture()})
	testing.expect_value(t, e2e.eval(s, "String(held.boxTop)"), "0")
	testing.expectf(t, e2e.eval_f64(s, "scroller.scrollTop") >= SCROLLED_LEAST, "the box took the thumb's offset: %s", e2e.eval(s, "String(scroller.scrollTop)"))
	after = e2e.capture(s, {target = .Window})
	testing.expectf(t, differing(shots[0], after, box.window) <= SAME_MOST_DIFFERENT, "the busy frame is the box as the thumb left it: %d px differ", differing(shots[0], after, box.window))
	testing.expect_value(t, e2e.eval(s, "String(window.downs)"), downs)   // the bar's presses are not the page's
}

@(test)
the_caret_blinks_while_the_page_is_busy :: proc(t: ^testing.T) {
	caret_blinks(t, "hold()")
}

// The frames under a native: a few long calls of it, each with a loop of its own, and no back edge of the script between two frames. What
// gives them their turn is the poll of that loop (src/wasm/poll.odin).
@(test)
the_caret_blinks_while_a_native_keeps_the_thread :: proc(t: ^testing.T) {
	caret_blinks(t, "holdNative()")
}

@(private = "file")
caret_blinks :: proc(t: ^testing.T, hold: string) {
	s := open(t, {fmt.tprintf("forms.caret.blink_ms=%d", CARET_BLINK_MS)})
	short := false
	field := e2e.box_model(s, "#field")
	e2e.click_at(s, e2e.center(field.box))
	// (the time since the caret's blink began is the step's: each picture is of a known phase, whatever the frames took)
	steps := make([dynamic]e2e.Busy_Step, context.temp_allocator)
	for i in 0 ..< CARET_SHOTS {
		append(&steps, e2e.busy_clock(f64(i * CARET_BLINK_MS + CARET_BLINK_MS / 2)), e2e.busy_capture())
	}
	shots := while_held(s, &short, steps[:], hold)
	if !testing.expectf(t, len(shots) == CARET_SHOTS, "a picture of each phase: %d of %d", len(shots), CARET_SHOTS) { return }
	for sh, i in shots[1:] {
		hidden := (i + 1) % 2 == 1
		n := differing(shots[0], sh, field.window)
		testing.expectf(t, (n > 0) == hidden, "the caret blinks under the task: picture %d (%s) differs from the first by %d px", i + 1, hidden ? "hidden" : "shown", n)
	}
}