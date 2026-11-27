package browser

// Wren's panel in the toolkit's debug window (src/md/features/debug-panel.md): the browser's own counts, a few
// switches and acts, in the window (Ctrl+Alt+Shift+D) and for the tools (Toolkit.debugPanels, tk cdp debug). A build
// without TOOLKIT_DEVTOOLS (the release) compiles every debug call to nothing.

import "core:fmt"
import config "toolkit:config"
import "toolkit:debug"
import "toolkit:ui"
import "wb:images"
import "wb:page"
import "wb:wasm"

DEBUG_PANEL :: "Wren"

// The switches a developer flips to isolate a bug (debug-panel.md, Preferences).
DEBUG_SWITCHES :: [?]string{
	"browser.status_bar.visible",
	"browser.shell.page_thread",
	"browser.shell.preempt",
	"render.compositor.enabled",
	"paint.effects.cache.enabled",
	"history.bfcache.enabled",
	"browser.paint_holding.enabled",
}

// What the panel shows, made in one pass so that Print writes what the window shows. Each field is a count that Wren
// already keeps: nothing here walks a collection or asks the system.
Debug_State :: struct {
	pages:  Debug_Pages,
	tab:    Debug_Tab,
	images: Debug_Images,
	frames: Debug_Frames,
	memory: Debug_Memory,
}

Debug_Pages :: struct {
	windows, tabs_window, tabs: int,
	pages:          int,   // documents alive on this thread: tabs, frames, kept pages
	wasm_instances: int,   // one per realm
	workers:        int,   // the process's
}

Debug_Tab :: struct {
	url, title: string,
	loading:    bool,
	zoom:       f32,
	layout_ms:  f64,
}

Debug_Images :: struct {
	entries, bytes, limit: int,
	decoded, failed:       u64,
	decode_ms, longest_ms: f64,
}

Debug_Frames :: struct {
	measured:            bool,   // the status bar or the title shows statistics: the numbers below follow
	fps:                 f32,
	cpu_ms, cpu_p95_ms:  f32,
	gpu_ms:              f32,
	over_budget:         int,
	budget_ms:           f32,
	hz, live_hz:         f64,
	chrome_frames:       u64,
	chrome_skipped:      u64,
}

Debug_Memory :: struct {
	working_set, private_bytes: int,   // the status bar's snapshot (hud_refresh), not read here
	trims:                      int,
}

// Every browser window's State gets the panel (views_attach). The App outlives each State, so its pointer stays valid
// for as long as the surface keeps it.
debug_panel_attach :: proc(app: ^App, s: ^ui.State) {
	debug.panel(s, DEBUG_PANEL, debug_panel, app)
}

debug_panel :: proc(app: ^App) {
	// (a chrome frame: a page holds the thread, its layout may be on the page thread, and an act would run inside that work)
	if app.chrome_frames.nested {
		debug.note("A page holds the thread: the values come back after it.")
		return
	}
	st := debug_state(app)
	debug.value("pages", st.pages)
	debug.value("tab", st.tab)
	debug.value("images", st.images)
	debug.value("frames", st.frames)
	debug.value("memory", st.memory)
	if debug.section("Preferences") {
		for name in DEBUG_SWITCHES {
			on := config.bool_of(&app.prefs, name)
			if debug.toggle(name, &on) { set_pref_bool(app, name, on) }
		}
	}
	if debug.act("Trim memory") {
		memory_trim(app)
		app_invalidate(app, .Chrome)
	}
	if debug.act("Reload all tabs") {
		for t in tabs_all(app) { if t.kind == .Web { reload(app, t) } }
	}
	if debug.act("Print") { fmt.println(debug.odin_text(st)) }
}

debug_state :: proc(app: ^App) -> (st: Debug_State) {
	w := active_window(app)
	st.pages.windows, st.pages.tabs_window = len(app.windows), len(w.tabs)
	for x in app.windows { st.pages.tabs += len(x.tabs) }   // (a few windows)
	if len(app.windows) == 0 { st.pages.tabs = len(app.bare.tabs) }
	st.pages.pages, st.pages.wasm_instances, st.pages.workers = page.pages_alive(), wasm.instances_alive(), page.workers_running()
	if t := current_tab(app); t != nil {
		st.tab = {url = t.url, title = t.title, loading = t.load != nil, zoom = t.zoom, layout_ms = t.layout_ms}
	}
	ic := &app.pages.image_cache
	ds := images.decoder_stats()   // (a copy under the decoder's mutex, which its threads hold only to move a job)
	st.images = {entries = len(ic.by_id), bytes = ic.bytes, limit = ic.limit, decoded = ds.decoded, failed = ds.failed, decode_ms = ds.busy_ms, longest_ms = ds.longest_ms}
	n := &app.hud.nums
	st.frames = {
		measured = app.phase_clock.on, fps = n.fps, cpu_ms = n.cpu_mean, cpu_p95_ms = n.cpu_p95, gpu_ms = n.gpu_mean,
		over_budget = n.over, budget_ms = n.budget, hz = w.pacer.hz, live_hz = w.pacer.live_hz,
		chrome_frames = app.chrome_frames.frames, chrome_skipped = app.chrome_frames.skipped,
	}
	st.memory = {working_set = n.working_set, private_bytes = n.private_bytes, trims = memory_trim_count(app)}
	return
}
