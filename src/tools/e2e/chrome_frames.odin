package e2e_scenarios

// What chrome frames (src/browser/shell_frames.odin) hold for a page under a long script, and whose it stays. A script keeps the thread until the window's height changes; the
// steps come in the chrome frames made under it, one a frame (e2e.while_busy), the last one changes the height and lets it go. Nothing here waits for a time: the script ends on
// that step, and the state each test starts from is set up by what it does before.
//   * input held for a page is that page's: a tab switch or another window's frame does not hand it to what shows next;
//   * the picture kept is what the page last showed: a hover, a box scrolled, the document scrolled at rest; a frame that changes nothing copies nothing;
//   * a trim leaves every window its picture, and a tab shown after one takes its own again;
//   * a release the system made ends a press with no click; a press on the window's frame ends what the window was doing, under a script too.

import "core:fmt"
import "core:testing"
import "toolkit:platform"
import "wb:browser"
import "wb:e2e"

@(private = "file") SIZE :: [2]int{800, 600}
@(private = "file") FRAME_CAP_LOW :: 30   // (below every rate browser.frame.cap offers)
@(private = "file") SHORTER :: [2]int{800, 590}          // what lets the script go
@(private = "file") HOLD_LIMIT_MS :: "45000"             // (a net for a test that died, under wait_js's deadline: e2e.DEFAULT_DEADLINE)
// The script: `turn` starts it (a task of the loop; requestAnimationFrame: in a frame of the page's own window), `mutates`: the first thing it does is change the document, and from
// then on only the pixels kept are there to show.
@(private = "file") HOLD :: "window.hold = (turn = f => setTimeout(f, 0), mutates = false) => { window.released = false; turn(() => { if (mutates) document.documentElement.dataset.held = 1; const h = innerHeight, begun = performance.now(); while (innerHeight == h && performance.now() - begun < " + HOLD_LIMIT_MS + ") {} window.released = innerHeight != h; }); return 1; }; 1"
@(private = "file") HOLD_MUTATES :: "hold(undefined, true)"
@(private = "file") HOLD_IN_ITS_FRAME :: "hold(requestAnimationFrame, true)"
@(private = "file") LOG :: "window.log = []; for (const k of ['mousedown', 'mouseup', 'click', 'keydown', 'contextmenu']) addEventListener(k, e => log.push(k)); 1"
@(private = "file") AT :: e2e.Point{100, 100}            // on the box of the pages below
@(private = "file") OUTSIDE :: e2e.Point{700, 500}       // off it
@(private = "file") RED :: e2e.Color{255, 0, 0, 255}
@(private = "file") GREEN :: e2e.Color{0, 160, 0, 255}
@(private = "file") WHITE :: e2e.Color{255, 255, 255, 255}
@(private = "file") BOX :: `<!doctype html><style>html{background:#fff} body{margin:0} #b{position:absolute;left:0;top:0;width:300px;height:300px;background:rgb(0,0,255)} #b:hover{background:rgb(255,0,0)}</style><div id=b>text</div>`
@(private = "file") GREEN_PAGE :: `<!doctype html><style>html{background:#fff} body{margin:0} #b{position:absolute;left:0;top:0;width:300px;height:300px;background:rgb(0,160,0)}</style><div id=b>text</div>`
// Two screens of white, then the green: seen at all only when scrolled.
@(private = "file") TALL_PAGE :: `<!doctype html><style>html{background:#fff} body{margin:0} #top{height:1500px} #low{height:3000px;background:rgb(0,160,0)}</style><div id=top></div><div id=low></div>`
@(private = "file") TALL_NOTCHES :: 30
@(private = "file") TALL_TOP :: 1500
// A box whose first screen is white, the rest green.
@(private = "file") SCROLLER_PAGE :: `<!doctype html><style>html{background:#fff} body{margin:0} #s{width:300px;height:300px;overflow:auto} #top{height:400px} #low{height:3000px;background:rgb(0,160,0)}</style><div id=s><div id=top></div><div id=low></div></div>`
@(private = "file") BOX_NOTCHES :: 10
@(private = "file") SCROLL_FRAMES :: 40                  // what a wheel's smooth scroll takes, at most
@(private = "file") IDLE_FRAMES :: 8
@(private = "file") AUTOSCROLL_TAPS :: "browser.scroll.autoscroll.mode=toggle"   // (a tap latches, however long it takes: no time in the test)
@(private = "file") FAR_BELOW :: e2e.Point{100, 550}     // from AT: a session on scrolls fast
@(private = "file") AUTOSCROLL_HELD_MS :: 100            // how long a session scrolls under a script
@(private = "file") MARKER_REACH :: 12                   // around the anchor: the marker is drawn there
@(private = "file") AUTOSCROLL_WATCHED_FRAMES :: 10

@(private = "file")
write_page :: proc(s: ^e2e.Session, html: string, loc := #caller_location) {
	e2e.eval(s, fmt.tprintf("document.open(); document.write(%q); document.close(); 1", html), loc = loc)
	e2e.eval(s, HOLD, loc = loc)
	e2e.wait_frames(s, loc = loc)
}

// The steps under a script of the tab `s` looks at, then the window's height changes and it ends. Their pictures.
@(private = "file")
while_held :: proc(s: ^e2e.Session, steps: []e2e.Busy_Step, hold := HOLD_MUTATES, loc := #caller_location) -> []e2e.Image {
	all := make([dynamic]e2e.Busy_Step, context.temp_allocator)
	append(&all, ..steps)
	append(&all, e2e.busy_resize(SHORTER))
	e2e.eval(s, hold, loc = loc)
	e2e.while_busy(s, all[:], loc)
	e2e.wait_js(s, "window.released === true", loc = loc)
	testing.expectf(s.t, e2e.busy_left(s, loc) == 0, "every step was taken under the script", loc = loc)
	return e2e.busy_shots(s, loc)
}

@(private = "file")
log_of :: proc(s: ^e2e.Session, loc := #caller_location) -> string { return e2e.eval(s, "log.join(' ')", loc = loc) }

@(private = "file")
tab_middle :: proc(s: ^e2e.Session, id: int) -> e2e.Point {
	for x in e2e.targets(s).tabs { if x.id == id { return {x.rect.x + x.rect.w / 2, x.rect.y + x.rect.h / 2} } }
	return {}
}

// The pixel of a picture at a point of the page.
@(private = "file")
page_pixel :: proc(s: ^e2e.Session, img: e2e.Image, at: e2e.Point) -> e2e.Color {
	context = s.ctx
	r := s.app.active.page_rect
	return e2e.pixel(img, int(r.min.x) + int(at.x), int(r.min.y) + int(at.y))
}

// A second window, in front, with a page of its own.
@(private = "file")
second_window :: proc(s: ^e2e.Session, html: string) -> (first, second: int) {
	first = e2e.windows(s)[0].id
	e2e.run_command(s, "window.new")
	wins := e2e.windows(s)
	second = wins[0].id != first ? wins[0].id : wins[1].id
	e2e.in_window(s, second)
	e2e.navigate(s, "about:blank")
	write_page(s, html)
	return
}

// 3a. A press and its release wait for the page; a click on the strip shows another tab at once. The tab shown then saw nothing of them, and neither did the page they were aimed at.
@(test)
input_held_for_a_tab_stays_off_the_next_one :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank", software = true})
	write_page(s, BOX)
	e2e.eval(s, LOG)
	here := e2e.targets(s).tabs[0].id
	other := e2e.new_tab(s, "about:blank")
	e2e.activate_tab(s, other)
	s.tab = other
	e2e.wait_load(s)
	write_page(s, BOX)
	e2e.eval(s, LOG)
	e2e.activate_tab(s, here)
	s.tab = here
	e2e.wait_frames(s)
	strip := tab_middle(s, other)
	while_held(s, {e2e.busy_press(s, AT), e2e.busy_release(s, AT), e2e.busy_press(s, strip, .Window), e2e.busy_release(s, strip, .Window), e2e.busy_wait(0), e2e.busy_wait(0)})
	e2e.wait_frames(s)
	testing.expect(t, e2e.targets(s).tabs[1].active, "the strip's click took under the script")
	testing.expect_value(t, log_of(s), "")
	s.tab = other
	testing.expect_value(t, log_of(s), "")
}

// 3a. The list of what waits is the process's, a frame is a window's, and the front window's comes first: what chrome frames of the window behind held goes to its page, not to the front one's.
@(test)
input_held_in_a_window_goes_to_its_page :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank", software = true})
	write_page(s, BOX)
	e2e.eval(s, LOG)
	first, second := second_window(s, BOX)
	{
		e2e.in_window(s, second)
		e2e.eval(s, LOG)
	}
	{
		e2e.in_window(s, first)
		while_held(s, {e2e.busy_press(s, AT), e2e.busy_release(s, AT)}, HOLD_IN_ITS_FRAME)
		e2e.wait_frames(s)
		testing.expect_value(t, log_of(s), "mousedown mouseup click")
	}
	{
		e2e.in_window(s, second)
		e2e.wait_frames(s)
		testing.expect_value(t, log_of(s), "")
	}
}

// 3b. A hover changes no node and runs no task: the picture shown under the next script has it all the same.
@(test)
the_picture_kept_has_the_hover :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank", software = true})
	write_page(s, BOX)
	e2e.hover(s, OUTSIDE)
	e2e.wait_frames(s)
	e2e.hover(s, AT)
	e2e.wait_frames(s)
	shots := while_held(s, {e2e.busy_capture()})
	testing.expectf(t, near(page_pixel(s, shots[0], AT), RED), "the box as the hover left it: %v", page_pixel(s, shots[0], AT))
}

// 3b. The wheel moved a box: no node changed. The picture has it where it is.
@(test)
the_picture_kept_has_a_box_scrolled :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank", software = true})
	write_page(s, SCROLLER_PAGE)
	e2e.scroll(s, BOX_NOTCHES, AT)
	e2e.wait_frames(s, SCROLL_FRAMES)
	testing.expect(t, e2e.eval_f64(s, "document.getElementById('s').scrollTop") > 0, "the box scrolled")
	shots := while_held(s, {e2e.busy_capture()})
	testing.expectf(t, near(page_pixel(s, shots[0], AT), GREEN), "the box where the wheel left it: %v", page_pixel(s, shots[0], AT))
}

// 3b. The document scrolled at rest, far from where the picture was taken: what the script's chrome frame shows is the page, not the page's background.
@(test)
the_picture_kept_follows_the_document :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank", software = true})
	write_page(s, TALL_PAGE)
	e2e.scroll(s, TALL_NOTCHES)
	e2e.wait_frames(s, SCROLL_FRAMES)
	testing.expect(t, e2e.eval_f64(s, "scrollY") > TALL_TOP, "the document scrolled")
	shots := while_held(s, {e2e.busy_capture()})
	testing.expectf(t, near(page_pixel(s, shots[0], AT), GREEN), "the page where the wheel left it: %v", page_pixel(s, shots[0], AT))
}

// 3b. A frame that says what the picture says costs no copy of the page, which is a millisecond of GPU and 20 MB of bandwidth, whatever it was made for.
@(test)
frames_that_change_nothing_copy_nothing :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank", software = true})
	write_page(s, BOX)
	e2e.hover(s, OUTSIDE)
	e2e.wait_frames(s)
	before := s.app.chrome_frames.captured
	testing.expect_value(t, e2e.eval(s, "new Promise(ok => setTimeout(() => ok('a task ran'), 0))", await = true), "a task ran")
	e2e.wait_frames(s, IDLE_FRAMES)
	testing.expect_value(t, s.app.chrome_frames.captured, before)
}

// 3c. A picture lost to a trim comes back with the tab's next frame: nothing else changed, but a chrome frame has nothing to show without it.
@(test)
a_tab_shown_after_a_trim_takes_its_picture_again :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank", software = true})
	write_page(s, GREEN_PAGE)
	here := e2e.targets(s).tabs[0].id
	other := e2e.new_tab(s, "about:blank")
	e2e.activate_tab(s, other)
	s.tab = other
	e2e.wait_load(s)
	write_page(s, BOX)
	e2e.activate_tab(s, here)
	e2e.wait_frames(s)
	e2e.activate_tab(s, other)
	e2e.wait_frames(s)
	{
		context = s.ctx
		browser.memory_trim(s.app)
	}
	s.tab = here
	e2e.activate_tab(s, here)
	e2e.wait_frames(s)
	shots := while_held(s, {e2e.busy_capture()})
	testing.expectf(t, near(page_pixel(s, shots[0], AT), GREEN), "the tab's page: %v", page_pixel(s, shots[0], AT))
}

// 3d. Every window keeps the picture of the tab it shows, not only the one the trim came in.
@(test)
a_trim_keeps_what_every_window_shows :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank", software = true})
	write_page(s, GREEN_PAGE)
	first, second := second_window(s, GREEN_PAGE)
	{
		context = s.ctx
		browser.memory_trim(s.app)
	}
	for w in ([2]int{first, second}) {
		e2e.in_window(s, w)
		shots := while_held(s, {e2e.busy_capture()}, HOLD_IN_ITS_FRAME)
		testing.expectf(t, near(page_pixel(s, shots[0], AT), GREEN), "the page of window %d: %v", w, page_pixel(s, shots[0], AT))
	}
}

@(private = "file")
system_event :: proc(s: ^e2e.Session, ev: platform.Event) {
	context = s.ctx
	browser.inject_raw(s.app, ev)
	e2e.wait_frames(s)
}

@(private = "file")
point :: proc(at: e2e.Point) -> [2]f32 { return {f32(at.x), f32(at.y)} }

// A press whose release the system made: no mouseup, no click, no menu.
@(test)
a_release_the_system_made_is_no_click :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank", software = true})
	write_page(s, BOX)
	e2e.eval(s, LOG)
	e2e.press(s, AT)
	e2e.wait_frames(s)
	system_event(s, {kind = .Mouse_Release, button = .Left, pos = point(AT), lost = true})
	testing.expect_value(t, log_of(s), "mousedown")
	e2e.eval(s, "log.length = 0")
	e2e.press(s, AT, button = .Right)
	e2e.wait_frames(s)
	system_event(s, {kind = .Mouse_Release, button = .Right, pos = point(AT), lost = true})
	testing.expect_value(t, log_of(s), "mousedown")
}

// Autoscroll by a tap of the middle button, the page tall and at its top: nothing moves it but a session still on.
@(private = "file")
autoscroll_page :: proc(t: ^testing.T, loc := #caller_location) -> ^e2e.Session {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank", software = true, prefs = {AUTOSCROLL_TAPS}}, loc)
	write_page(s, TALL_PAGE)
	return s
}

@(private = "file")
expect_no_autoscroll :: proc(t: ^testing.T, s: ^e2e.Session, loc := #caller_location) {
	e2e.hover(s, FAR_BELOW)
	e2e.wait_frames(s, AUTOSCROLL_WATCHED_FRAMES)
	testing.expect_value(t, e2e.eval(s, "scrollY"), "0", loc = loc)
}

// A middle press the system took: no tap, nothing latches.
@(test)
a_middle_press_the_system_took_latches_nothing :: proc(t: ^testing.T) {
	s := autoscroll_page(t)
	e2e.press(s, AT, button = .Middle)
	e2e.wait_frames(s)
	system_event(s, {kind = .Mouse_Release, button = .Middle, pos = point(AT), lost = true})
	expect_no_autoscroll(t, s)
}

// A press on the window's frame ends a latched autoscroll, which no release ends.
@(test)
a_press_on_the_frame_ends_a_latched_autoscroll :: proc(t: ^testing.T) {
	s := autoscroll_page(t)
	e2e.press(s, AT, button = .Middle)
	e2e.release(s, AT, button = .Middle)
	e2e.wait_frames(s)
	system_event(s, {kind = .Frame_Press})
	expect_no_autoscroll(t, s)
}

// ... and one made under a script, whose frames are the chrome's: the gesture hears of it at the page's turn.
@(test)
a_press_on_the_frame_under_a_script_ends_it_too :: proc(t: ^testing.T) {
	s := autoscroll_page(t)
	e2e.press(s, AT, button = .Middle)
	e2e.release(s, AT, button = .Middle)
	e2e.wait_frames(s)
	while_held(s, {{kind = .Event, ev = {kind = .Frame_Press}}})
	expect_no_autoscroll(t, s)
}

// A session goes on under a script, as the wheel does: the pointer moves only there and Escape ends it there, so what scrolled, chrome frames scrolled. Its marker stays.
@(test)
autoscroll_goes_on_under_a_script :: proc(t: ^testing.T) {
	s := autoscroll_page(t)
	e2e.press(s, AT, button = .Middle)
	e2e.release(s, AT, button = .Middle)
	e2e.wait_frames(s)
	testing.expect_value(t, e2e.eval(s, "scrollY"), "0")
	shots := while_held(s, {e2e.busy_capture(), e2e.busy_move(s, FAR_BELOW), e2e.busy_wait(AUTOSCROLL_HELD_MS), e2e.busy_key(s, "Escape", true)})
	e2e.wait_frames(s)
	testing.expectf(t, e2e.eval_f64(s, "scrollY") > 0, "the page moved under the script: %v", e2e.eval(s, "scrollY"))
	marked := false
	for dy in -MARKER_REACH ..= MARKER_REACH {
		for dx in -MARKER_REACH ..= MARKER_REACH {
			if !near(page_pixel(s, shots[0], {AT[0] + f64(dx), AT[1] + f64(dy)}), WHITE) { marked = true }
		}
	}
	testing.expect(t, marked, "the marker is drawn in a chrome frame")
	stopped := e2e.eval_f64(s, "scrollY")
	e2e.hover(s, FAR_BELOW)
	e2e.wait_frames(s, AUTOSCROLL_WATCHED_FRAMES)
	testing.expect_value(t, e2e.eval_f64(s, "scrollY"), stopped)
}

// browser.frame.cap from its commands: a rate is the ceiling of every window, uncapped takes every wait away and the frames' time still goes forward, auto gives the monitor's rate back.
@(test)
the_frame_rate_is_a_choice :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank", software = true})
	e2e.run_command(s, "window.new")
	auto_hz := browser.active_window(s.app).pacer.hz
	testing.expect(t, auto_hz > FRAME_CAP_LOW, "a screen faster than the rate this asks for, or the rate cannot show")

	e2e.run_command(s, "view.frame_cap.60")
	testing.expect_value(t, e2e.pref_get(s, "browser.frame.cap"), "60")
	e2e.wait_frames(s)
	for w in s.app.windows { testing.expect_value(t, w.pacer.hz, min(auto_hz, 60)) }

	e2e.pref_set(s, "browser.frame.cap_custom_hz", "45")
	e2e.run_command(s, "view.frame_cap.custom")
	e2e.wait_frames(s)
	for w in s.app.windows { testing.expect_value(t, w.pacer.hz, min(auto_hz, 45)) }

	e2e.run_command(s, "view.frame_cap.uncapped")
	e2e.wait_frames(s)
	for w in s.app.windows { testing.expect(t, w.pacer.cadence.uncapped, "every window") }
	d := platform.frame_decision(&browser.active_window(s.app).pacer.cadence, {now_ns = 1, presented = true})
	testing.expect(t, d.wait_ns == 0 && !d.wait_swap_chain && d.present_at_once, "no slot, no wait for the screen")
	times := e2e.eval(s, `new Promise(done => { const seen = []; const next = at => { seen.push(at); seen.length < 5 ? requestAnimationFrame(next) : done(String(seen.every((x, i) => !i || x >= seen[i - 1]))) }; requestAnimationFrame(next) })`, await = true)
	testing.expect_value(t, times, "true")

	e2e.run_command(s, "view.frame_cap.auto")
	e2e.wait_frames(s)
	for w in s.app.windows {
		testing.expect(t, !w.pacer.cadence.uncapped, "and back")
		testing.expect_value(t, w.pacer.hz, auto_hz)
	}
}
