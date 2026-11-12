package e2e_scenarios

// A browser at rest draws nothing: the frames made over turns of the loop that nothing asked for, on a page that changes nothing. What
// does draw at rest has its reason, and it costs what it says: a caret's toggle, one frame of its own pixels. A count, not a time: it holds on a slow machine too.

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "toolkit:render"
import "wb:browser"
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
draws_nothing :: proc(t: ^testing.T, url: string, prefs: []string = {STATUS_WINDOW_PREF}, loc := #caller_location) {
	s := e2e.start(t, {url = url, prefs = prefs}, loc = loc)
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
	s := e2e.start(t, {url = e2e.file_page(e2e.temp_folder(t), "field.html", FIELD_PAGE), prefs = {STATUS_WINDOW_PREF, CARET_PREF}, hidden = hidden, software = software, pixels = true})
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
// (Without the status bar: a flip is a whole frame, so it is a sample of the status bar, whose numbers then fall to rest in a frame of their
// own when that frame took long. That is the status bar's frame, not the caret's, and only a slow machine shows it: a runner drew 5 frames
// for 3 flips.)
@(private = "file") NO_STATUS_BAR :: "browser.status_bar.visible=false"

@(test)
the_address_bars_caret_draws_at_its_flips :: proc(t: ^testing.T) {
	s := e2e.start(t, {url = "about:blank", prefs = {STATUS_WINDOW_PREF, NO_STATUS_BAR}})
	e2e.wait_idle(s)
	e2e.wait_at_rest(s)   // (what a start still has to draw is not the caret's)
	e2e.address_bar_open(s)
	e2e.wait_at_rest(s, moving_ok = true)
	began := time.tick_now()
	before := e2e.stats(s).loop.frames
	e2e.rest_turns(s, REST_TURNS)
	frames := e2e.stats(s).loop.frames - before
	flips := (int(time.duration_milliseconds(time.tick_since(began))) + INTERFACE_CARET_FLIP_MS - 1) / INTERFACE_CARET_FLIP_MS   // (what began counts: 2.1 s holds a fourth flip)
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

// An animation nobody can see asks for no frame of its own. Under display: none it does not run at all (CSS Animations 1: the style timeline ends it,
// style/anim_seen_test.odin); far below the fold it ticks at style.animations.unseen_tick_ms (style.Seen_Probe, page/animations_seen.odin), past the turns watched
// here, and its events (one iteration a minute) too: a frame among them would be a frame for it.
@(private = "file") UNSEEN_PREFS :: []string{STATUS_WINDOW_PREF, "style.animations.unseen_tick_ms=10000"}
@(private = "file") SPIN_STYLE :: `<style>@keyframes spin { from { transform: rotate(0deg) } to { transform: rotate(360deg) } } .spin { width: 40px; height: 40px; background: #06c; animation: spin 60s linear infinite } body { margin: 0 }</style>`
@(private = "file") HIDDEN_SPINNER_PAGE :: `<!doctype html><meta charset="utf-8"><title>hidden spinner</title>` + SPIN_STYLE + `<p>A page.</p><div style="display: none"><div class="spin"></div></div>`
@(private = "file") SPINNER_BELOW_PAGE :: `<!doctype html><meta charset="utf-8"><title>spinner below</title>` + SPIN_STYLE + `<p>A page.</p><div style="height: 20000px"></div><div class="spin" id="s"></div>`
// The same far below, but what it animates is a size: it moves the boxes around it, and counts as seen.
@(private = "file") GROWER_BELOW_PAGE :: `<!doctype html><meta charset="utf-8"><title>grower below</title><style>@keyframes grow { from { width: 0px } to { width: 100px } } .grow { height: 40px; background: #06c; animation: grow 60s linear infinite } body { margin: 0 }</style><p>A page.</p><div style="height: 20000px"></div><div class="grow"></div>`

@(test)
an_animation_under_display_none_draws_nothing_at_rest :: proc(t: ^testing.T) {
	draws_nothing(t, e2e.file_page(e2e.temp_folder(t), "hidden.html", HIDDEN_SPINNER_PAGE), UNSEEN_PREFS)
}

@(test)
an_animation_far_below_the_fold_draws_nothing_at_rest_and_draws_once_scrolled_to :: proc(t: ^testing.T) {
	s := e2e.start(t, {url = e2e.file_page(e2e.temp_folder(t), "below.html", SPINNER_BELOW_PAGE), prefs = UNSEEN_PREFS})
	e2e.wait_idle(s)
	e2e.wait_at_rest(s)
	at_rest := e2e.stats(s).loop.frames
	e2e.rest_turns(s, REST_TURNS)
	testing.expectf(t, e2e.stats(s).loop.frames == at_rest, "%d frames over %d turns at rest:%s", e2e.stats(s).loop.frames - at_rest, REST_TURNS, reasons(s))
	e2e.eval(s, "document.getElementById('s').scrollIntoView(); 1")
	first := e2e.stats(s).loop
	e2e.rest_until_frames(s, first.frames + MOVING_FRAMES)
	last := e2e.stats(s).loop
	testing.expectf(t, last.causes[.Page] - first.causes[.Page] >= MOVING_FRAMES - 1, "seen, it draws at every frame: %v, then %v:%s", first.causes, last.causes, reasons(s))
}

@(test)
an_animation_of_a_size_far_below_the_fold_draws :: proc(t: ^testing.T) {
	s := e2e.start(t, {url = e2e.file_page(e2e.temp_folder(t), "grower.html", GROWER_BELOW_PAGE), prefs = UNSEEN_PREFS})
	e2e.wait_idle(s)
	first := e2e.stats(s).loop
	e2e.rest_until_frames(s, first.frames + MOVING_FRAMES)
	last := e2e.stats(s).loop
	testing.expectf(t, last.causes[.Page] > first.causes[.Page], "its frames are the page's: %v, then %v:%s", first.causes, last.causes, reasons(s))
}

// A document held for its render-blocking sheet (a gate of the test server) shows the loading bar (first_paint.odin loading_bar). The bar moves at the loading
// indicators' rate, not at every refresh, and the page's look at what it waits for (js_load.odin poll_schedule, every 16 ms) draws nothing: frames against the time
// gone by (a slow machine makes fewer, never more), a turn of the indicators and the status bar's numbers falling to rest after it. (Before: 87 frames in 1.1 s.)
@(private = "file") LOADING_FPS :: 4
@(private = "file") FRAMES_A_TURN :: 2   // (the turn's, the status bar's)
@(private = "file") FRAMES_ASKED_BEFORE :: 4   // (what the navigation's last steps asked for before the watch: an input asks for 4)
@(private = "file") LOADING_PREFS :: []string{STATUS_WINDOW_PREF, "browser.tabs.spinner_fps=4"}
@(private = "file") SHEET_GATE :: "loading-bar-sheet"

@(private = "file")
held_for_its_sheet :: proc(s: ^e2e.Session) -> bool {
	context = s.ctx
	t := browser.current_tab(s.app)
	return t != nil && t.page != nil && browser.tab_loading(t)
}

@(test)
the_loading_bar_moves_at_the_loading_indicators_rate :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	sheet := e2e.url(server, fmt.tprintf("/firstpaint/f/slow.css?gate=%s", SHEET_GATE))
	url := e2e.file_page(e2e.temp_folder(t), "held.html", fmt.tprintf(`<!doctype html><meta charset="utf-8"><title>held</title><link rel="stylesheet" href="%s"><p>Held for its sheet.</p>`, sheet))
	s := e2e.start(t, {url = "about:blank", prefs = LOADING_PREFS})
	e2e.wait_idle(s)
	e2e.navigate_begin(s, url)
	e2e.wait_until(s, held_for_its_sheet, "the document, held for its sheet")
	began := time.tick_now()
	before := e2e.stats(s).loop.frames
	e2e.rest_turns(s, REST_TURNS)
	frames := e2e.stats(s).loop.frames - before
	turns := (int(time.duration_milliseconds(time.tick_since(began))) * LOADING_FPS + 999) / 1000
	testing.expect(t, held_for_its_sheet(s), "still held")
	testing.expectf(t, frames <= FRAMES_A_TURN * turns + FRAMES_ASKED_BEFORE, "%d frames for %d turns of the bar:%s", frames, turns, reasons(s))
	e2e.open_gate(server, SHEET_GATE)
	e2e.wait_load(s)
}
