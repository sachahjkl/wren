package browser

// Preferences of the tab's history in the shell: restoring what an entry showed (history_restore.odin), the
// back/forward cache (bfcache.odin), the global history of visits (global_history.odin) and its views
// (history_ui.odin). The session history's own sizes are page.Web_Settings (history.max_entries, history.tree.max_nodes).

import "wb:config"
import "wb:page"

HISTORY_PREFS := [?]config.Def{
	{name = "history.restore.enabled", kind = .Bool, default = {b = true},
		description = "An entry shown again (back, forward, a reload, a restored session) comes back where it was left: scroll positions of the page and of its scrolling elements, the page zoom, what was typed in its forms. A page can opt out of the scroll part with history.scrollRestoration = \"manual\"."},
	{name = "history.restore.forms", kind = .Bool, default = {b = true},
		description = "Restore what the user typed or chose in form controls of an entry shown again (never passwords, files, hidden fields or fields with autocomplete=off)."},
	{name = "history.restore.zoom", kind = .Bool, default = {b = true},
		description = "An entry shown again gets back the page zoom it had."},
	{name = "history.restore.max_wait_ms", kind = .Float, default = {f = 10_000}, bounded = true, min = 0, max = 600_000, unit = "ms",
		description = "Longest time the browser keeps trying to bring an entry back to its scroll position while the page is still too short (it grows as it loads); then it scrolls as far as it can."},
	{name = "history.restore.after_load_ms", kind = .Float, default = {f = 1000}, bounded = true, min = 0, max = 60_000, unit = "ms",
		description = "Once the page's load event fired, how much longer the browser waits for it to become tall enough before scrolling as far as it can."},
	{name = "history.bfcache.enabled", kind = .Bool, default = {b = true},
		description = "Back/forward cache: a page left by a navigation stays alive, frozen (no script runs), for a while, so that going back or forward to it is instant and finds it exactly as it was. Pages that cannot be kept (unload handlers, open WebSocket or EventSource, requests in flight, Cache-Control: no-store...) load again."},
	{name = "history.bfcache.max_entries", kind = .Int, default = {i = 6}, bounded = true, min = 0, max = 1000,
		description = "Most pages kept in the back/forward cache, all tabs together (Chromium: 6). The pages left longest ago go first."},
	{name = "history.bfcache.max_memory", kind = .Int, default = {i = 512 << 20}, bounded = true, min = 0, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Memory the pages of the back/forward cache may use together (an estimate: their documents, layouts, buffers and script engines). The pages left longest ago go first past it."},
	{name = "history.bfcache.page_overhead", kind = .Int, default = {i = 8 << 20}, bounded = true, min = 0, max = 1 << 32, bytes = true, unit = "bytes",
		description = "What a cached page with a JavaScript realm or Wasm modules is counted beyond its document and layout (the engines' memory), for history.bfcache.max_memory."},
	{name = "history.bfcache.timeout_s", kind = .Int, default = {i = 600}, bounded = true, min = 1, max = 86_400, unit = "s",
		description = "How long a page stays in the back/forward cache (Chromium: 10 minutes)."},
	{name = "history.global.enabled", kind = .Bool, default = {b = true},
		description = "Record the pages visited in the browsing history (about:history). Off: nothing new is recorded (what is there stays until deleted)."},
	{name = "history.global.retention_days", kind = .Int, default = {i = 90}, bounded = true, min = 0, max = 36_500, unit = "days",
		description = "Visits older than this are deleted from the browsing history. 0 = kept until deleted."},
	{name = "history.global.max_visits", kind = .Int, default = {i = 100_000}, bounded = true, min = 10, max = 10_000_000,
		description = "Most visits the browsing history keeps; the oldest go past it."},
	{name = "history.global.max_url_bytes", kind = .Int, default = {i = 8 << 10}, bounded = true, min = 256, max = 2 << 20, bytes = true, unit = "bytes",
		description = "Longest address the browsing history records (longer ones are not recorded)."},
	{name = "history.global.save_delay_ms", kind = .Int, default = {i = 2000}, bounded = true, min = 0, max = 600_000, unit = "ms",
		description = "The browsing history is written to the profile this long after the first unsaved change (on a background thread, atomically), and when the browser closes."},
	{name = "history.global.record_file_urls", kind = .Bool, default = {b = true},
		description = "Record local files (file:) in the browsing history."},
	{name = "history.ui.menu_entries", kind = .Int, default = {i = 15}, bounded = true, min = 1, max = 100,
		description = "Entries the menu of the back and forward buttons lists (right click or long press), nearest first."},
	{name = "history.ui.long_press_ms", kind = .Float, default = {f = 500}, bounded = true, min = 100, max = 5000, unit = "ms",
		description = "Holding the back or forward button this long opens its menu."},
}

register_history_prefs :: proc(p: ^config.Prefs) {
	config.register(p, HISTORY_PREFS[:])
	config.register(p, HISTORY_TREE_PREFS[:])   // history_tree.odin
}

History_Settings :: struct {
	restore:          bool,
	restore_forms:    bool,
	restore_zoom:     bool,
	restore_max_ms:   f64,
	restore_after_ms: f64,
	bf_enabled:       bool,
	bf_max_entries:   int,
	bf_max_bytes:     int,
	bf_overhead:      int,
	bf_timeout_ms:    f64,
	global:           bool,
	retention_days:   int,
	max_visits:       int,
	max_url_bytes:    int,
	save_delay_ms:    f64,
	record_files:     bool,
	menu_entries:     int,
	long_press_ms:    f64,
}

history_settings_from_prefs :: proc(p: ^config.Prefs) -> History_Settings {
	return History_Settings{
		restore = config.bool_of(p, "history.restore.enabled"),
		restore_forms = config.bool_of(p, "history.restore.forms"),
		restore_zoom = config.bool_of(p, "history.restore.zoom"),
		restore_max_ms = config.float_of(p, "history.restore.max_wait_ms"),
		restore_after_ms = config.float_of(p, "history.restore.after_load_ms"),
		bf_enabled = config.bool_of(p, "history.bfcache.enabled"),
		bf_max_entries = int(config.int_of(p, "history.bfcache.max_entries")),
		bf_max_bytes = int(config.int_of(p, "history.bfcache.max_memory")),
		bf_overhead = int(config.int_of(p, "history.bfcache.page_overhead")),
		bf_timeout_ms = f64(config.int_of(p, "history.bfcache.timeout_s")) * 1000,
		global = config.bool_of(p, "history.global.enabled"),
		retention_days = int(config.int_of(p, "history.global.retention_days")),
		max_visits = int(config.int_of(p, "history.global.max_visits")),
		max_url_bytes = int(config.int_of(p, "history.global.max_url_bytes")),
		save_delay_ms = f64(config.int_of(p, "history.global.save_delay_ms")),
		record_files = config.bool_of(p, "history.global.record_file_urls"),
		menu_entries = int(config.int_of(p, "history.ui.menu_entries")),
		long_press_ms = config.float_of(p, "history.ui.long_press_ms"),
	}
}

hcfg: History_Settings
@(private = "file") history_watch: int

// At start-up, before the first navigation.
history_settings_init :: proc(app: ^App) {
	hcfg = history_settings_from_prefs(&app.prefs)
	history_tree_settings_init(app)
	history_watch = config.watch(&app.prefs, "history.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		hcfg = history_settings_from_prefs(p)
		bfcache_evict(app)
		global_history_apply(app)
		for t in app.tabs { tab_history_limits(app, t) }
	}, app)
}

history_settings_shutdown :: proc(app: ^App) {
	config.unwatch(&app.prefs, history_watch)
	history_tree_settings_shutdown(app)
}

// The session history's sizes from the preferences.
tab_history_limits :: proc(app: ^App, t: ^Tab) {
	w := &app.page_settings.web
	page.session_set_limits(&t.session, w.history_max_entries, w.history_max_nodes)
	sync_history(t)
}
