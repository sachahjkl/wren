package e2e_scenarios

// Two browsers in one process, each on a thread of its own and alive at the same time (docs/architecture.md, Where state lives): each sees
// only its own tabs and pages. Both open two pages of one origin (the test server's), each its own, on profiles of their own; then each, while the other does the
// same: a script's value, the page's storage, a BroadcastChannel between its two tabs (its realms' message ports), the picture of its frame.
// Neither sees what the other did.
//
// TOOLKIT_UI_OF_THE_PROCESS: the toolkit keeps the interface state it draws with in one variable of the process (ext/gui_toolkit/ui/state.odin,`g`), so
// two threads that draw at once break each other's. Until it is the thread's (`@(private, thread_local) g: ^State`), the two Apps' own threads
// take turns between the meetings; what they run besides (page threads, workers, loaders, decoders, compile threads) runs at once all the same.
// With that one change and this false, the two run their steps at once too (it passes so).

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "wb:base"
import "wb:e2e"

@(private = "file") APPS :: 2
@(private = "file") TOOLKIT_UI_OF_THE_PROCESS :: true
@(private = "file") WINDOW :: [2]int{640, 400}
// What each App's page is: its letter, the colour of its page.
@(private = "file") LETTERS := [APPS]string{"A", "B"}
@(private = "file") COLOURS := [APPS]e2e.Color{{200, 30, 30, 255}, {30, 30, 200, 255}}
// How far a flat colour of a capture may be from the page's.
@(private = "file") FLAT_TOLERANCE :: 8
// Frames each App makes after its message, while the other's would have come.
@(private = "file") SETTLE_FRAMES :: 6
// How long an App waits at a meeting for the other (it only ends a run that fails: the other stopped).
@(private = "file") MEET_LIMIT :: 60 * time.Second
// (the page's style is put in whole: fmt reads a brace as its own)
@(private = "file") PAGE :: `<!doctype html><meta charset="utf-8"><title>App %s</title><style>%s</style><p>%s`
@(private = "file") LISTEN :: `window.got = ""; new BroadcastChannel("wren").onmessage = e => { window.got += e.data }; "listening"`
@(private = "file") POST :: `new BroadcastChannel("wren").postMessage("%s"); "posted"`

// Where the two threads wait for each other: a count of arrivals, one round after another; and the turn of their steps (TOOLKIT_UI_OF_THE_PROCESS).
@(private = "file")
Meeting :: struct { arrived: sync.Futex, turn: sync.Mutex }

@(private = "file")
step_begin :: proc(m: ^Meeting) { when TOOLKIT_UI_OF_THE_PROCESS { sync.mutex_lock(&m.turn) } }
@(private = "file")
step_end :: proc(m: ^Meeting) { when TOOLKIT_UI_OF_THE_PROCESS { sync.mutex_unlock(&m.turn) } }

@(private = "file")
meet :: proc(m: ^Meeting, round: u32) -> bool {
	sync.atomic_add(&m.arrived, 1)
	want := sync.Futex(round * APPS)
	since := time.tick_now()
	for {
		now := sync.atomic_load(&m.arrived)
		if now >= want { sync.futex_broadcast(&m.arrived); return true }
		left := MEET_LIMIT - time.tick_since(since)
		if left <= 0 { return false }
		_ = sync.futex_wait_with_timeout(&m.arrived, u32(now), left)
	}
}

// What one App saw, read by the test once its thread is done (strings on the heap).
@(private = "file")
App_Run :: struct {
	t:        ^testing.T,
	logger:   runtime.Logger,    // the test's: what fails says it there
	index:    int,
	url:      string,
	profile:  string,
	meeting:  ^Meeting,
	met:      bool,
	tabs:     [dynamic]string,   // the titles of its tabs
	value:    string,            // a script's value, in its second tab
	stored:   string,            // localStorage, read in its first tab after both wrote
	got:      string,            // what its first tab's channel received
	centre:   e2e.Color,         // its page's middle pixel
	users:    int,               // the Apps using what the process shares, seen while both run
}

@(private = "file")
app_run :: proc(data: rawptr) {
	r := (^App_Run)(data)
	context = base.process_context()   // (the test's allocator is its thread's alone)
	context.logger = r.logger
	letter := LETTERS[r.index]
	m := r.meeting
	step_begin(m)
	s := e2e.start(r.t, {url = r.url, profile = r.profile, size = WINDOW, own_thread = true})
	first := e2e.targets(s).tabs[0].id
	e2e.new_tab(s, r.url)
	e2e.wait_load(s)
	step_end(m)
	r.met = meet(m, 1)   // both have their two tabs
	r.users = e2e.process_share_users()
	step_begin(m)
	r.value = strings.clone(e2e.eval(s, fmt.tprintf(`document.title + " " + (6 * 7) + " %s"`, letter)))
	{
		s.tab = first
		defer s.tab = 0
		_ = e2e.eval(s, LISTEN)
		_ = e2e.eval(s, fmt.tprintf(`localStorage.setItem("k", "%s"); "stored"`, letter))
	}
	step_end(m)
	r.met = r.met && meet(m, 2)   // both listen, both stored
	step_begin(m)
	_ = e2e.eval(s, fmt.tprintf(POST, letter))
	step_end(m)
	r.met = r.met && meet(m, 3)   // both posted
	step_begin(m)
	{
		s.tab = first
		defer s.tab = 0
		e2e.wait_js(s, `window.got.length > 0`)
		e2e.wait_frames(s, SETTLE_FRAMES)
		r.got = strings.clone(e2e.eval(s, "window.got"))
		r.stored = strings.clone(e2e.eval(s, `localStorage.getItem("k")`))
	}
	page := e2e.capture(s, {target = .Page})   // (its current tab: the second)
	r.centre = e2e.pixel(page, page.width / 2, page.height / 2)
	for tab in e2e.targets(s).tabs { append(&r.tabs, strings.clone(tab.title)) }
	step_end(m)
	r.met = r.met && meet(m, 4)   // both looked: each stops its own
	step_begin(m)
	e2e.stop(s)
	step_end(m)
}

@(private = "file")
near_colour :: proc(a, b: e2e.Color) -> bool {
	for i in 0 ..< 4 { if abs(int(a[i]) - int(b[i])) > FLAT_TOLERANCE { return false } }
	return true
}

@(test)
two_apps_on_two_threads_keep_to_their_own :: proc(t: ^testing.T) {
	server := e2e.test_server(t)   // (one origin for both: what one App stores the other must not see)
	meeting: Meeting
	runs: [APPS]App_Run
	threads: [APPS]^thread.Thread
	for i in 0 ..< APPS {
		c := COLOURS[i]
		css := strings.concatenate({"html, body { margin: 0; height: 100%; background: ", fmt.tprintf("rgb(%d, %d, %d)", c.r, c.g, c.b), " }"}, context.temp_allocator)
		html := fmt.tprintf(PAGE, LETTERS[i], css, LETTERS[i])
		runs[i] = {t = t, logger = context.logger, index = i, url = e2e.url(server, fmt.tprintf("/frames/doc?body=%s", net.percent_encode(html, context.temp_allocator))), profile = e2e.temp_profile(t), meeting = &meeting}
		threads[i] = thread.create_and_start_with_data(&runs[i], app_run)
	}
	for th in threads { thread.join(th); thread.destroy(th) }
	for &r, i in runs {
		letter := LETTERS[i]
		own := fmt.tprintf("App %s", letter)
		testing.expectf(t, r.met, "App %s: the other App was there at each meeting", letter)
		testing.expectf(t, r.users == APPS, "App %s: %d Apps use what the process shares while both run, not %d", letter, r.users, APPS)
		testing.expectf(t, len(r.tabs) == 2 && r.tabs[0] == own && r.tabs[1] == own, "App %s: its own two tabs only: %v", letter, r.tabs)
		testing.expect_value(t, r.value, fmt.tprintf("%s 42 %s", own, letter))
		testing.expectf(t, r.stored == letter, "App %s: its profile's localStorage holds %q, not the other's (%q)", letter, letter, r.stored)
		testing.expectf(t, r.got == letter, "App %s: its channel received its own message only: %q", letter, r.got)
		testing.expectf(t, near_colour(r.centre, COLOURS[i]), "App %s: its frame shows its page: %v, not %v", letter, r.centre, COLOURS[i])
		context.allocator = base.process_allocator()   // (what its thread kept)
		for tab in r.tabs { delete(tab) }
		delete(r.tabs); delete(r.value); delete(r.stored); delete(r.got)
	}
	testing.expect_value(t, e2e.process_share_users(), 0)
	// (the test program is built with every allocation tracked: once both have stopped, nothing of either may be left)
	when base.TRACK_MEMORY { testing.expectf(t, base.mem_report("two_apps") == 0, "the two browsers leave nothing allocated: the report above") }
}
