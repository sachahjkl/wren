package e2e_scenarios

// What the user does while the page's script keeps the thread (examples/site/busy.html hold(): one task that runs until the
// window's height changes). The input comes in the chrome frames made under that task, one step a frame (e2e.while_busy), and
// the pictures are those frames'; the last step changes the window's height and lets the task end. Then the page's turn:
//   * a drag over the text shows its selection under the task (painted from the page's last layout), the task saw none of
//     it (no selectionchange, an empty getSelection()), and once it ran the selection is the one the drag made; with a
//     mousemove listener the drag waits for the page as before, and selects the same;
//   * the thumb of the document's scroll bar and Page Down scroll the page under the task, with what was below the fold
//     painted (the busy frame is the page as it shows once it ran), and the presses on the bar are not the page's;
//   * Ctrl+L takes the address bar under the task.

import "core:fmt"
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
@(private = "file") EMPTY :: e2e.Point{500, 500}   // the tall box under everything: a press there selects nothing and gives the page the keyboard

@(private = "file")
open :: proc(t: ^testing.T, loc := #caller_location) -> ^e2e.Session {
	prefs := []string{fmt.tprintf("browser.selection.background=%s", HIGHLIGHT), fmt.tprintf("browser.selection.inactive_background=%s", HIGHLIGHT)}
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, prefs = prefs, url = e2e.file_url(fmt.tprintf("%s/examples/site/busy.html", e2e.repo_root()))}, loc)
	e2e.wait_idle(s)
	e2e.eval(s, "for (const e of document.querySelectorAll('.moving')) e.style.animation = 'none'; 1")   // (two pictures of the page are alike)
	e2e.wait_frames(s)
	return s
}

// The task holds the thread while `steps` are taken, then lets go; the pictures of the capture steps.
@(private = "file")
while_held :: proc(s: ^e2e.Session, short: ^bool, steps: []e2e.Busy_Step, loc := #caller_location) -> []e2e.Image {
	short^ = !short^
	size := short^ ? SHORTER : SIZE
	all := make([dynamic]e2e.Busy_Step, context.temp_allocator)
	append(&all, ..steps)
	append(&all, e2e.busy_resize(size))
	e2e.wait_frames(s, loc = loc)   // (what the page last painted is what it is now: what the chrome frames paint again)
	e2e.eval(s, "hold()", loc = loc)
	e2e.while_busy(s, all[:], loc)
	e2e.wait_js(s, "window.released === true", loc = loc)
	testing.expectf(s.t, e2e.busy_left(s, loc) == 0, "every step was taken under the task", loc = loc)
	return e2e.busy_shots(s, loc)
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
