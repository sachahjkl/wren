package e2e_scenarios

// A browser at rest draws nothing: the frames made over turns of the loop that nothing asked for, on a page that changes nothing. What
// does draw at rest has its reason, and it costs what it says: a caret's toggle, one frame of its own pixels. A count, not a time: it holds on a slow machine too.

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "toolkit:render"
import "wb:e2e"

// What settles after the last frame (the status bar's numbers falling to rest) does so soon.
@(private = "file") STATUS_WINDOW_PREF :: "browser.status_bar.rate_window_ms=100"
@(private = "file") CARET_PREF :: "forms.caret.blink_ms=40"
// The toolkit's caret (ui/line_edit.odin: CARET_BLINK_MS).
@(private = "file") INTERFACE_CARET_FLIP_MS :: 530
// Turns of the loop watched: at a wake a millisecond or more, longer than anything of a page's first second that was still to come, and many status bar windows.
@(private = "file") REST_TURNS :: 120
// Frames of the moving pages looked at.
@(private = "file") MOVING_FRAMES :: 12
// What a caret may take of the window's pixels in its frame, in parts of a hundred (it takes far less).
@(private = "file") CARET_PERCENT_OF_THE_WINDOW :: 1
// A timer of a page that changes nothing is not the wake that keeps a page at rest from sleeping: it ran this many times meanwhile.
@(private = "file") TICKS_AT_LEAST :: 3
@(private = "file") STATIC_PAGE :: `<!doctype html><meta charset="utf-8"><title>at rest</title><h1>A page</h1><p>That changes nothing.</p>`
@(private = "file") FIELD_PAGE :: `<!doctype html><meta charset="utf-8"><title>field</title><input id="f" value="text">`
@(private = "file") ANIMATED_PAGE :: `<!doctype html><meta charset="utf-8"><title>moves</title><style>@keyframes m { from { transform: translateX(0) } to { transform: translateX(300px) } } #b { width: 80px; height: 80px; background: #06c; animation: m 2s linear infinite }</style><div id="b"></div>`

// What the loop kept of its last frames, to say who drew.
@(private = "file")
reasons :: proc(s: ^e2e.Session) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in e2e.stats(s).loop.reasons { fmt.sbprintf(&b, "\n  %.0f ms: %s, %s", r.at_ms, r.causes, r.by) }
	return strings.to_string(b)
}

@(private = "file")
draws_nothing :: proc(t: ^testing.T, url: string, loc := #caller_location) {
	s := e2e.start(t, {url = url, prefs = {STATUS_WINDOW_PREF}}, loc = loc)
	e2e.wait_idle(s)
	e2e.wait_at_rest(s)
	before := e2e.stats(s).loop
	e2e.rest_turns(s, REST_TURNS)
	after := e2e.stats(s).loop
	testing.expectf(t, after.frames == before.frames, "%s: %d frames over %d turns at rest:%s", url, after.frames - before.frames, REST_TURNS, reasons(s), loc = loc)
	testing.expectf(t, after.sleeps - before.sleeps >= REST_TURNS, "%s: the loop slept at each turn: %d of %d", url, after.sleeps - before.sleeps, REST_TURNS, loc = loc)
}

@(test)
about_blank_draws_nothing_at_rest :: proc(t: ^testing.T) { draws_nothing(t, "about:blank") }

@(test)
a_static_page_draws_nothing_at_rest :: proc(t: ^testing.T) {
	draws_nothing(t, e2e.file_page(e2e.temp_folder(t), "static.html", STATIC_PAGE))
}

// A script that ticks every 20 ms and touches nothing: no frame at all, whatever it costs it. (idle-timer.htm: page_apis.odin looks at what such a page does when it changes.)
@(test)
a_timer_that_changes_nothing_draws_nothing_at_rest :: proc(t: ^testing.T) {
	s := e2e.start(t, {dpi = e2e.DPI_ONE, url = e2e.url(e2e.test_server(t), "/site/remote/idle-timer.htm"), prefs = {STATUS_WINDOW_PREF}})
	e2e.wait_idle(s)
	e2e.wait_at_rest(s)
	ticks := e2e.eval_f64(s, "window.ticks")
	before := e2e.stats(s).loop.frames
	e2e.rest_turns(s, REST_TURNS)
	frames := e2e.stats(s).loop.frames - before
	testing.expectf(t, frames == 0, "%d frames over %d turns:%s", frames, REST_TURNS, reasons(s))
	testing.expectf(t, e2e.eval_f64(s, "window.ticks") - ticks >= TICKS_AT_LEAST, "its timer ran meanwhile")
}

// A focused field: the caret's toggle at its own period, one frame each, drawing only the caret's pixels, to the byte what a whole frame would be; a frame that is no
// activity: no sample of the status bar. (`render.damage.verify` draws each frame both ways.)
@(test)
a_caret_draws_its_own_pixels_and_nothing_else :: proc(t: ^testing.T) { caret_draws_its_own_pixels(t) }

// The same where drawing takes long enough to show in the status bar's graph: the time of the last whole frame lands in it while the caret blinks. (0.1 ms on a GPU, 15 to 22 ms
// here: on a GPU it is thinner than the thinnest part of a bar the graph draws, and this test would see nothing.)
@(test)
a_caret_draws_its_own_pixels_on_the_software_rasterizer :: proc(t: ^testing.T) { caret_draws_its_own_pixels(t, software = true) }

// (`hidden`: on a real window's swap chain, real_window.odin.)
caret_draws_its_own_pixels :: proc(t: ^testing.T, hidden := false, software := false) {
	s := e2e.start(t, {url = e2e.file_page(e2e.temp_folder(t), "field.html", FIELD_PAGE), prefs = {STATUS_WINDOW_PREF, CARET_PREF}, hidden = hidden, software = software})
	e2e.wait_idle(s)
	e2e.click(s, "#f")
	e2e.wait_at_rest(s, moving_ok = true)
	testing.expect(t, e2e.stats(s).caret_blinking, "the caret blinks")
	render.set_damage_verify(&s.app.r, true)
	first := e2e.stats(s).loop
	e2e.rest_until_frames(s, first.frames + MOVING_FRAMES)
	last := e2e.stats(s).loop
	testing.expectf(t, last.causes[.Asked] - first.causes[.Asked] == last.frames - first.frames, "only the caret asks: %d of %d:%s", last.causes[.Asked] - first.causes[.Asked], last.frames - first.frames, reasons(s))
	watched_from := first.reasons[len(first.reasons) - 1].at_ms   // (what the loop keeps goes back before the watch)
	for r in last.reasons {
		if r.at_ms > watched_from && r.causes != "wake, no frame" { testing.expectf(t, strings.contains(r.by, "forms_shell.odin"), "who drew: %s, %s", r.causes, r.by) }
	}
	_, _, region, whole, partial := render.damage_stats(&s.app.r)
	testing.expectf(t, partial && region * 100 < whole * CARET_PERCENT_OF_THE_WINDOW, "the caret's pixels alone: %d of %d (%v)", region, whole, partial)
	testing.expect_value(t, render.damage_verify_differences(&s.app.r), 0)
}

// The address bar's caret, a field of the interface: frames at its flips, no more; whole ones, the interface does not say what it changed. (A count against the time gone by:
// a slow machine makes fewer, never more.)
@(test)
the_address_bars_caret_draws_at_its_flips :: proc(t: ^testing.T) {
	s := e2e.start(t, {url = "about:blank", prefs = {STATUS_WINDOW_PREF}})
	e2e.wait_idle(s)
	e2e.address_bar_open(s)
	e2e.wait_at_rest(s, moving_ok = true)
	began := time.tick_now()
	before := e2e.stats(s).loop.frames
	e2e.rest_turns(s, REST_TURNS)
	frames := e2e.stats(s).loop.frames - before
	flips := int(time.duration_milliseconds(time.tick_since(began))) / INTERFACE_CARET_FLIP_MS
	testing.expectf(t, frames <= flips + 1, "%d frames for %d flips:%s", frames, flips, reasons(s))
}

// The comparison: a page that moves does draw, and says why.
@(test)
a_running_animation_draws :: proc(t: ^testing.T) {
	s := e2e.start(t, {url = e2e.file_page(e2e.temp_folder(t), "moves.html", ANIMATED_PAGE), prefs = {STATUS_WINDOW_PREF}})
	e2e.wait_idle(s)
	first := e2e.stats(s).loop
	e2e.rest_until_frames(s, first.frames + MOVING_FRAMES)
	last := e2e.stats(s).loop
	testing.expectf(t, last.causes[.Page] > first.causes[.Page], "its frames are the page's: %v, then %v:%s", first.causes, last.causes, reasons(s))
}
