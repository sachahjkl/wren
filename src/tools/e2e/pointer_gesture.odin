package e2e_scenarios

// Who owns the pressed button (src/browser/pointer_gesture.odin): the press decides once, its moves and its release go to that owner
// whatever happens meanwhile, and a tab switch or a navigation ends it for good: nothing of it comes back on the page shown then, or
// on the page it began in.
//   * a press that waited for a layout dies with its page: the next page selects nothing under no button;
//   * a thumb, an arrow and :active do not outlive a tab switch, and the release lands nowhere;
//   * a release a handler takes (the element picker) still ends the selection; a text drag goes on over a frame;
//   * one series of clicks: forgetting it forgets it in a field too;
//   * Escape ends a page's drag for good, its release is no click; a drag is its window's: another window's events leave it alone;
//   * a press on a track is the bar's, to its release.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") SIZE :: [2]int{800, 600}
@(private = "file") WIDTH_PREF :: "layout.scrollbar.classic.width_px"
@(private = "file") DOUBLE_MS_PREF :: "forms.click.double_ms"
@(private = "file") DOUBLE_MS :: "60000"              // no test is slower than this: two clicks are a series unless forgotten
@(private = "file") THUMB_AT :: 1.5                   // how far down the bar a point of its thumb is, in widths of the bar
@(private = "file") TRACK_UP :: 2                     // a point of the track, in widths of the bar above its end (past the down arrow)
@(private = "file") THUMB_MOVE :: 120                 // how far a thumb is dragged (CSS px)
@(private = "file") NEVER_MS :: 60000                 // the test server's longest delay: this answer does not come in a test
@(private = "file") TEXT_AT :: e2e.Point{30, 30}      // on the first line of the pages below
@(private = "file") TEXT_FAR :: e2e.Point{300, 30}
@(private = "file") PAST_THRESHOLD :: 40              // a press moved this far is a drag (CSS px)
@(private = "file") LINE :: `<p style="margin:20px;font:20px monospace">some words to select with the pointer, a whole line of them</p>`
@(private = "file") TALL :: `<!doctype html><style>body{margin:0} #tall{height:3000px}</style><div id=tall></div>`
@(private = "file") LOG :: "window.log = []; for (const k of ['mousedown', 'mouseup', 'click', 'dragstart', 'dragend', 'drop']) addEventListener(k, e => log.push(k)); 1"
@(private = "file") LINK_PAGE :: `<!doctype html><style>body{margin:0} a{position:absolute;left:20px;top:20px;width:200px;height:40px;font:20px monospace}</style><a id=link href="#away">a link to drag</a>`
@(private = "file") LINK_AT :: e2e.Point{60, 35}
@(private = "file") BOX_AT :: e2e.Point{50, 50}       // in the box of the page with :active
@(private = "file") FIELD_AT :: e2e.Point{60, 40}     // on a word of the field's text
@(private = "file") OVER_FRAME :: e2e.Point{380, 200}  // inside the frame of the page that has one, right of TEXT_FAR

@(private = "file")
write_page :: proc(s: ^e2e.Session, html: string) {
	e2e.eval(s, fmt.tprintf("document.open(); document.write(%q); document.close(); 1", html))
	e2e.wait_frames(s)
}

@(private = "file")
selected :: proc(s: ^e2e.Session) -> string { return e2e.eval(s, "String(getSelection())") }

@(private = "file")
log_of :: proc(s: ^e2e.Session) -> string { return e2e.eval(s, "log.join(' ')") }

@(private = "file")
pref_f64 :: proc(s: ^e2e.Session, name: string) -> f64 {
	v, _ := strconv.parse_f64(e2e.pref_get(s, name))
	return v
}

// The tab of the test, and one more to switch to.
@(private = "file")
two_tabs :: proc(s: ^e2e.Session) -> (here, other: int) {
	here = e2e.targets(s).tabs[0].id
	other = e2e.new_tab(s, "about:blank", background = true)
	return
}

// A press whose mousedown changes the document waits for a layout; the same mousedown leaves the page, the release comes while no page is
// there. The next page has no gesture of it: moves with no button select nothing.
@(test)
a_press_waiting_for_a_layout_ends_with_its_page :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank"})
	write_page(s, `<!doctype html>` + LINE)
	away := e2e.url(server, fmt.tprintf("/firstpaint/f/none.html?delay=%d", NEVER_MS))
	e2e.eval(s, fmt.tprintf("addEventListener('mousedown', () => {{ document.body.append('more'); location = %q }}); 1", away))
	e2e.press(s, TEXT_AT)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return strings.contains(e2e.location(s), "delay") }, "the page left")
	e2e.release(s, TEXT_AT)
	e2e.navigate(s, e2e.file_page(e2e.temp_folder(t), "next.html", `<!doctype html>` + LINE))
	e2e.wait_frames(s)
	e2e.hover(s, TEXT_AT)
	e2e.hover(s, TEXT_FAR)
	testing.expect_value(t, selected(s), "")
}

// The thumb is held, the tab changes, the button comes up over the other tab; back on the first one the pointer moves the document no more.
@(test)
a_thumb_drag_ends_with_a_tab_switch :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank"})
	write_page(s, TALL)
	here, other := two_tabs(s)
	bar := pref_f64(s, WIDTH_PREF)
	thumb := e2e.Point{e2e.eval_f64(s, "innerWidth") - bar / 2, bar * THUMB_AT}
	e2e.press(s, thumb)
	e2e.activate_tab(s, other)
	e2e.release(s, thumb)
	e2e.activate_tab(s, here)
	e2e.hover(s, {thumb.x, thumb.y + THUMB_MOVE})
	e2e.wait_frames(s)
	testing.expect_value(t, e2e.eval(s, "scrollY"), "0")
}

// So with an arrow: held, its repeats go on for ever on the tab left, which draws for ever.
@(test)
an_arrow_held_ends_with_a_tab_switch :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank"})
	write_page(s, TALL)
	here, other := two_tabs(s)
	bar := pref_f64(s, WIDTH_PREF)
	down := e2e.Point{e2e.eval_f64(s, "innerWidth") - bar / 2, e2e.eval_f64(s, "innerHeight") - bar / 2}
	e2e.press(s, down)
	e2e.activate_tab(s, other)
	e2e.release(s, down)
	e2e.activate_tab(s, here)
	e2e.wait_at_rest(s)
}

// :active is the press's, and goes with it: the page left under the press does not keep it, and its release is nobody's.
@(test)
active_ends_with_a_tab_switch :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank"})
	write_page(s, `<!doctype html><style>body{margin:0} #b{width:200px;height:200px;background:#00f} #b:active{background:#f00}</style><div id=b></div>`)
	here, other := two_tabs(s)
	style := "getComputedStyle(document.getElementById('b')).backgroundColor"
	at_rest := e2e.eval(s, style)
	e2e.press(s, BOX_AT)
	e2e.wait_frames(s)
	testing.expect(t, e2e.eval(s, style) != at_rest, ":active while the button is held")
	e2e.activate_tab(s, other)
	s.tab = other
	e2e.eval(s, LOG)
	e2e.release(s, BOX_AT)
	testing.expect_value(t, log_of(s), "")   // (its release is no mouseup in the other tab)
	s.tab = 0
	e2e.activate_tab(s, here)
	e2e.wait_frames(s)
	testing.expect_value(t, e2e.eval(s, style), at_rest)
}

// A handler that takes the release (the element picker, turned on while the button is held) does not leave the selection open.
@(test)
a_release_the_picker_takes_ends_the_selection :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank"})
	write_page(s, `<!doctype html>` + LINE)
	e2e.press(s, TEXT_AT)
	e2e.run_command(s, "view.devtools_pick")
	e2e.wait_frames(s)
	e2e.release(s, TEXT_AT)
	e2e.run_command(s, "view.devtools_pick")
	e2e.hover(s, TEXT_AT)
	e2e.hover(s, TEXT_FAR)
	testing.expect_value(t, selected(s), "")
}

// The moves of a text drag are the drag's over a frame too: a press keeps the pointer, as it does for a drag begun in the frame.
@(test)
a_text_drag_goes_on_over_a_frame :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank"})
	write_page(s, `<!doctype html><style>body{margin:0}</style>` + LINE + `<iframe style="position:absolute;left:0;top:100px;width:400px;height:200px;border:0" srcdoc="<!doctype html><p>inside</p>"></iframe>`)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return e2e.eval(s, "frames[0].document.readyState") == "complete" }, "the frame loaded")
	e2e.wait_frames(s)
	e2e.press(s, TEXT_AT)
	e2e.hover(s, TEXT_FAR)
	first := len(selected(s))
	e2e.hover(s, OVER_FRAME)
	e2e.release(s, OVER_FRAME)
	testing.expectf(t, len(selected(s)) > first, "the selection follows the pointer over the frame: %d, %d", first, len(selected(s)))
}

// One series: what forgets the clicks forgets them in a field too (it was the page's text alone).
@(test)
forgetting_the_clicks_forgets_them_in_a_field :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank", prefs = {fmt.tprintf("%s=%s", DOUBLE_MS_PREF, DOUBLE_MS)}})
	write_page(s, `<!doctype html><style>body{margin:0}</style><input id=f value="words in a field" style="position:absolute;left:20px;top:20px;width:300px;height:40px;font:20px monospace">`)
	span := "(f => f.selectionEnd - f.selectionStart)(document.getElementById('f'))"
	e2e.forget_clicks(s)
	e2e.click_at(s, FIELD_AT)
	e2e.forget_clicks(s)
	e2e.click_at(s, FIELD_AT)
	testing.expect_value(t, e2e.eval(s, span), "0")
	e2e.click_at(s, FIELD_AT)
	testing.expect(t, e2e.eval(s, span) != "0", "without forgetting, the next click is the second of a series: a word")
}

// Escape ends a drag from the page; the button comes up over the link it began on: no mouseup, no click, the page stays.
@(test)
escape_ends_a_page_drag_for_good :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank"})
	write_page(s, LINK_PAGE)
	e2e.eval(s, LOG)
	e2e.press(s, LINK_AT)
	e2e.hover(s, {LINK_AT.x + PAST_THRESHOLD, LINK_AT.y})
	e2e.hover(s, {LINK_AT.x + 2, LINK_AT.y})
	e2e.key(s, "Escape")
	e2e.release(s, {LINK_AT.x + 2, LINK_AT.y})
	l := log_of(s)
	testing.expectf(t, strings.contains(l, "dragstart") && strings.contains(l, "dragend"), "the drag ran and ended: %s", l)
	testing.expectf(t, !strings.contains(l, "mouseup") && !strings.contains(l, "click"), "its release is no click: %s", l)
	testing.expect_value(t, e2e.eval(s, "location.hash"), "")
}

// A drag is its window's: what happens in another window's frames leaves it alone, and it ends on its own page with a drop.
@(test)
a_page_drag_is_its_windows :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank"})
	write_page(s, LINK_PAGE)
	e2e.eval(s, LOG + "; addEventListener('dragover', e => e.preventDefault()); 1")
	first := e2e.windows(s)[0].id
	e2e.run_command(s, "window.new")
	wins := e2e.windows(s)
	second := wins[0].id != first ? wins[0].id : wins[1].id
	{
		e2e.in_window(s, first)
		e2e.press(s, LINK_AT)
		e2e.hover(s, {LINK_AT.x + PAST_THRESHOLD, LINK_AT.y})
		e2e.hover(s, {LINK_AT.x + 2 * PAST_THRESHOLD, LINK_AT.y + PAST_THRESHOLD})
	}
	{
		e2e.in_window(s, second)
		e2e.hover(s, TEXT_AT)
		e2e.wait_frames(s)
	}
	{
		e2e.in_window(s, first)
		e2e.hover(s, {LINK_AT.x + 3 * PAST_THRESHOLD, LINK_AT.y + 2 * PAST_THRESHOLD})
		e2e.release(s, {LINK_AT.x + 3 * PAST_THRESHOLD, LINK_AT.y + 2 * PAST_THRESHOLD})
		l := log_of(s)
		testing.expectf(t, strings.contains(l, "drop") && strings.contains(l, "dragend"), "the drag went on to its drop: %s", l)
	}
}

// A press on a bar's track is the bar's, and so is its release: the page saw no mousedown, and hears no mouseup.
@(test)
a_press_on_a_track_is_the_bars_to_its_release :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank"})
	write_page(s, TALL)
	e2e.eval(s, LOG)
	bar := pref_f64(s, WIDTH_PREF)
	track := e2e.Point{e2e.eval_f64(s, "innerWidth") - bar / 2, e2e.eval_f64(s, "innerHeight") - TRACK_UP * bar}
	e2e.click_at(s, track)
	testing.expect_value(t, log_of(s), "")
}
