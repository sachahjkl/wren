package browser

// Remote control, the state of a running browser: putting it back to a known state without starting it again (`wren ctl reset`,
// `checkpoint`, `pref reset`), the process's own numbers (CPU time, threads, handles) and the wait for a quiet process. A test
// that drives one Wren through many scenarios needs these: a process costs a start, a close, and a start-up's CPU to settle.
//
//   * The baseline is what `reset` returns to: the preferences as they were when the channel started and the window as it was
//     when the client last saved "initial" (`wren ctl start` and `run` do it once the window has its size). A reset also closes
//     every tab but one blank tab, and empties cookies, localStorage, sessionStorage, IndexedDB, the HTTP cache, HSTS, the
//     CORS preflight cache, the browsing history and the list of closed tabs.
//   * A checkpoint is a named copy of the preferences, the window, the tabs (address and zoom), the cookies (session ones too)
//     and localStorage. Restoring one closes the tabs, puts all that back and opens the tabs again. IndexedDB, the HTTP cache
//     and sessionStorage are not part of it: a restore empties them.
//   * Everything runs on the interface thread in the turn of the request, like every other method; a request that waited for
//     something else (a load, a quiet process) is an op (remote_shell.odin).

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import win "core:sys/windows"
import "toolkit:platform"
import "toolkit:ui"
import "wb:config"
import "wb:cookies"
import "wb:fetch"
import "wb:httpcache"
import "wb:page"
import "wb:remote"

Keep_Part :: enum u8 { Tabs, Data, Prefs, Window, History }
Keep :: bit_set[Keep_Part]

KEEP_NAMES := [Keep_Part]string{.Tabs = "tabs", .Data = "data", .Prefs = "prefs", .Window = "window", .History = "history"}

// "keep": a JSON array of part names, or a comma separated string. `bad` names the first part that is none.
keep_parse :: proc(v: json.Value) -> (keep: Keep, bad: string) {
	add :: proc(keep: ^Keep, name: string) -> bool {
		n := strings.trim_space(name)
		if n == "" { return true }
		for part in Keep_Part { if KEEP_NAMES[part] == n { keep^ += {part}; return true } }
		return false
	}
	#partial switch x in v {
	case json.String:
		for name in strings.split(string(x), ",", context.temp_allocator) { if !add(&keep, name) { return keep, strings.trim_space(name) } }
	case json.Array:
		for item in x {
			s, is_s := item.(json.String)
			if !is_s || !add(&keep, string(s)) { return keep, "(not a name)" }
		}
	}
	return
}

////////////////////////////////
// The process's numbers

// CPU time of the process (all threads), in milliseconds. The system counts in ticks of 100 ns but adds them up at its clock's
// resolution (about 15.6 ms): a difference smaller than a tick is 0 or one tick.
process_cpu_ms :: proc() -> (total, user, kernel: f64) {
	c, e, k, u: win.FILETIME
	win.GetProcessTimes(win.GetCurrentProcess(), &c, &e, &k, &u)
	ms :: proc(f: win.FILETIME) -> f64 { return f64(u64(f.dwHighDateTime) << 32 | u64(f.dwLowDateTime)) / 10000 }
	return ms(k) + ms(u), ms(u), ms(k)
}

process_uptime_ms :: proc() -> f64 {
	c, e, k, u, now: win.FILETIME
	win.GetProcessTimes(win.GetCurrentProcess(), &c, &e, &k, &u)
	win.GetSystemTimeAsFileTime(&now)
	ticks :: proc(f: win.FILETIME) -> u64 { return u64(f.dwHighDateTime) << 32 | u64(f.dwLowDateTime) }
	return f64(ticks(now) - ticks(c)) / 10000
}

// Threads of this process, from the system's list of processes (each entry carries its thread count): -1 when the system will not
// say. Not from the list of threads: that one has every thread of the machine (thousands, and the more on a busy runner), and
// walking it cost `wren ctl stats` 16 to 47 ms of the browser's own CPU time (more than a whole second of an idle Wren's).
process_thread_count :: proc() -> int {
	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0)
	if snap == win.INVALID_HANDLE_VALUE { return -1 }
	defer win.CloseHandle(snap)
	e := win.PROCESSENTRY32W{dwSize = size_of(win.PROCESSENTRY32W)}
	pid := win.GetCurrentProcessId()
	ok := win.Process32FirstW(snap, &e)
	for ok {
		if e.th32ProcessID == pid { return int(e.cntThreads) }
		e.dwSize = size_of(win.PROCESSENTRY32W)
		ok = win.Process32NextW(snap, &e)
	}
	return -1
}

////////////////////////////////
// Waiting for a quiet process

// The window a wait for quiet slides: it holds when nothing was busy and the process used at most `max_cpu_ms` of CPU time
// during `quiet_ms`; anything else starts it again from now.
Quiet_Window :: struct {
	since_ns: i64,
	cpu_ms:   f64,
	open:     bool,
}

quiet_look :: proc(q: ^Quiet_Window, busy: bool, now_ns: i64, cpu_ms: f64, quiet_ms: int, max_cpu_ms: f64) -> bool {
	if busy || !q.open || cpu_ms - q.cpu_ms > max_cpu_ms {
		q^ = {since_ns = now_ns, cpu_ms = cpu_ms, open = true}
		return false
	}
	return now_ns - q.since_ns >= i64(quiet_ms) * 1_000_000
}

// Is something being loaded, in any tab or by any request? (Without asking a page's script: a wait for quiet must not make the
// process busy by looking.)
remote_busy :: proc(app: ^App) -> bool {
	if fetch.in_flight(&app.loader) > 0 { return true }
	for t in tabs_all(app) {
		if !tab_loaded(app, t, false) { return true }
	}
	return false
}

////////////////////////////////
// Baseline and checkpoints

Window_State :: struct {
	left, top, width, height: int,   // the window's corner; the client area in pixels
	state:                    string,   // normal, minimized, maximized, fullscreen (a literal)
}

Checkpoint_Tab :: struct {
	url:  string,   // owned
	zoom: f32,
}

Checkpoint :: struct {
	name:     string,                 // owned
	prefs:    []config.Pref_State,
	window:   Window_State,
	has_tabs: bool,
	tabs:     []Checkpoint_Tab,
	current:  int,
	has_data: bool,
	cookies:  []cookies.Cookie,
	storage:  []page.Storage_Image,
}

checkpoint_free :: proc(c: ^Checkpoint) {
	if c == nil { return }
	delete(c.name)
	config.snapshot_destroy(c.prefs)
	for t in c.tabs { delete(t.url) }
	delete(c.tabs)
	cookies.copy_destroy(c.cookies)
	page.storage_images_destroy(c.storage)
	free(c)
}

window_capture :: proc(app: ^App) -> Window_State {
	wnd := active_window(app)
	rc: win.RECT
	win.GetWindowRect(wnd.win.hwnd, &rc)
	return {int(rc.left), int(rc.top), int(wnd.win.size.x), int(wnd.win.size.y), window_state(app)}
}

checkpoint_take :: proc(app: ^App, name: string, with_tabs, with_data: bool) -> ^Checkpoint {
	wnd := active_window(app)
	c := new(Checkpoint)
	c.name = strings.clone(name)
	c.prefs = config.snapshot(&app.prefs)
	c.window = window_capture(app)
	if with_tabs {
		c.has_tabs = true
		list := make([dynamic]Checkpoint_Tab)
		for t, i in wnd.tabs {
			if t.frame != nil { continue }
			if i == wnd.current { c.current = len(list) }
			append(&list, Checkpoint_Tab{url = strings.clone(t.url), zoom = t.zoom > 0 ? t.zoom : 1})
		}
		c.tabs = list[:]
	}
	if with_data {
		c.has_data = true
		c.cookies = cookies.copy_all(&app.profile.jar)
		page.storage_flush(&app.storage, sync_write = true, all = true)
		c.storage = page.storage_local_images(&app.storage)
	}
	return c
}

// The baseline `reset` returns to: taken when the channel starts, and again when a client saves "initial".
remote_take_baseline :: proc(app: ^App) {
	r := &the_remote
	checkpoint_free(r.baseline)
	r.baseline = checkpoint_take(app, "initial", false, false)
}

remote_state_free :: proc() {
	r := &the_remote
	checkpoint_free(r.baseline)
	r.baseline = nil
	for _, c in r.checkpoints { checkpoint_free(c) }
	delete(r.checkpoints)
	r.checkpoints = nil
}

// The settings the channel itself reads from the preferences, again (a preference was changed or put back).
remote_reload_settings :: proc(app: ^App) {
	r := &the_remote
	r.cfg = remote.settings_from_prefs(&app.prefs)
	r.cfg.name = ""
}

////////////////////////////////
// Putting things back

Reset_Summary :: struct {
	ops, tabs, cookies, sites, cache, visits, prefs: int,
	window:                                          bool,
}

// The pending commands of every client end with an error (a wait that was for a page that is going away).
remote_cancel_ops :: proc(why: string) -> int {
	r := &the_remote
	list := make([]^Remote_Op, len(r.ops), context.temp_allocator)
	copy(list, r.ops[:])
	for op in list { op_finish(op, fail(remote.ERR_FAILED, why)) }
	delete(r.stash_text)
	r.stash_text, r.stash_id = "", 0
	r.rec.on = false
	clear(&r.rec.events)
	return len(list)
}

// Whatever the interface has open besides the page: developer tools (docked or in a window of their own), the search bar, the
// command palette, the element picker, full screen, downloads in progress.
chrome_reset :: proc(app: ^App) {
	find_close(app)
	if palette_open() { palette_close(app) }
	if blocker_picker_active() { blocker_picker_cancel(app) }
	if devtools_detached() { devtools_attach(app) }
	if dev.visible { devtools_toggle(app) }
	if platform.is_fullscreen(active_window(app).win) { toggle_fullscreen(app) }
	downloads_cancel_all()
}

// One blank tab (or one at `address`) and no other: returns it. The tabs that stand in for a frame are not tabs.
tabs_reset :: proc(app: ^App, address: string, closed: ^int) -> ^Tab {
	wnd := active_window(app)
	fresh := tab_open(app, address == "" ? "about:blank" : address, origin = .User)
	for i := len(wnd.tabs) - 1; i >= 0; i -= 1 {
		t := wnd.tabs[i]
		if t == fresh || t.frame != nil { continue }
		tab_close(app, i)
		closed^ += 1
	}
	for t, i in wnd.tabs { if t == fresh { wnd.current = i } }
	ui.field_set(&wnd.address, fresh.url)
	closed_tabs_destroy()
	request_frames(app, 3)
	return fresh
}

// Cookies, storage, caches and the security memories of the profile.
data_wipe :: proc(app: ^App, sum: ^Reset_Summary) {
	sum.cookies = cookies.count(&app.profile.jar)
	sum.sites = len(page.storage_sites(&app.storage))
	if app.profile.cache != nil { sum.cache = httpcache.summary(app.profile.cache).entries }
	clear_site(app, "*", CLEAR_ALL)
	fetch.hsts_clear(&app.profile.hsts)
	fetch.preflight_cache_clear(&app.profile.preflights)
}

history_wipe :: proc(app: ^App, sum: ^Reset_Summary) {
	sum.visits = len(ghist.visits)
	global_history_remove_range(app, 0, max(i64))
}

window_restore :: proc(app: ^App, w: Window_State) -> bool {
	now := window_capture(app)
	if now == w { return false }
	window_apply(app, w.state, true, w.width, w.height, w.left, w.top, true, true, true, true)
	return true
}

reset_summary_json :: proc(s: Reset_Summary, extra := "") -> string {
	return fmt.tprintf(`{{"cancelledOps":%d,"closedTabs":%d,"cookies":%d,"sites":%d,"cacheEntries":%d,"historyVisits":%d,"prefsRestored":%d,"windowRestored":%v%s}}`,
		s.ops, s.tabs, s.cookies, s.sites, s.cache, s.visits, s.prefs, s.window, extra)
}

// Wren.reset {keep: [tabs, data, prefs, window, history], url, wait, timeout}
m_reset :: proc(app: ^App, c: ^Call) -> Reply {
	keep: Keep
	if v, has := c.params["keep"]; has {
		bad: string
		keep, bad = keep_parse(v)
		if bad != "" { return fail(remote.ERR_PARAMS, fmt.tprintf("keep: tabs, data, prefs, window, history (not %q)", bad)) }
	}
	address, _ := remote.param_string(c.params, "url")
	sum: Reset_Summary
	sum.ops = remote_cancel_ops("cancelled by a reset")
	chrome_reset(app)
	tab: ^Tab
	if .Tabs in keep { tab = current_tab(app) } else { tab = tabs_reset(app, address, &sum.tabs) }
	if .Data not_in keep { data_wipe(app, &sum) }
	if .History not_in keep { history_wipe(app, &sum) }
	r := &the_remote
	if .Prefs not_in keep && r.baseline != nil {
		sum.prefs = config.restore(&app.prefs, r.baseline.prefs)
		remote_reload_settings(app)
	}
	if .Window not_in keep && r.baseline != nil { sum.window = window_restore(app, r.baseline.window) }
	clear(&r.loaded)
	for t in tabs_all(app) { r.loaded[t.id] = tab_loaded(app, t) }
	request_frames(app, 3)
	what, _ := remote.param_string(c.params, "wait", "load")
	return start_wait(app, c, tab, what, reset_summary_json(sum, tab != nil ? fmt.tprintf(`,"tabId":%d`, tab.id) : ""))
}

CHECKPOINT_NAME_OK :: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."

// Wren.checkpoint {action: save|restore|list|delete, name, wait, timeout}
m_checkpoint :: proc(app: ^App, c: ^Call) -> Reply {
	r := &the_remote
	action, _ := remote.param_string(c.params, "action", "list")
	name, _ := remote.param_string(c.params, "name")
	if action != "list" {
		if name == "" || strings.trim_left(name, CHECKPOINT_NAME_OK) != "" { return fail(remote.ERR_PARAMS, "name: letters, digits, '-', '_' and '.'") }
	}
	switch action {
	case "save":
		if name == "initial" {
			remote_take_baseline(app)
			return done(`{"name":"initial","tabs":0,"cookies":0,"storageOrigins":0}`)
		}
		if _, exists := r.checkpoints[name]; !exists && len(r.checkpoints) >= r.cfg.max_checkpoints {
			return fail(remote.ERR_FAILED, fmt.tprintf("%d checkpoints exist already (browser.remote.max_checkpoints): delete one", len(r.checkpoints)))
		}
		cp := checkpoint_take(app, name, true, true)
		if r.checkpoints == nil { r.checkpoints = make(map[string]^Checkpoint) }
		if old, exists := r.checkpoints[name]; exists {
			delete_key(&r.checkpoints, name)   // (the key is the old checkpoint's own name)
			checkpoint_free(old)
		}
		r.checkpoints[cp.name] = cp
		return done(checkpoint_json(cp))
	case "list":
		names := make([dynamic]string, context.temp_allocator)
		for n in r.checkpoints { append(&names, n) }
		sort_strings(names[:])
		b := builder()
		j_begin(&b)
		j_key(&b, "checkpoints"); j_begin(&b, '[')
		j_raw(&b, "", `{"name":"initial","tabs":0,"cookies":0,"storageOrigins":0}`)
		for n in names { j_raw(&b, "", checkpoint_json(r.checkpoints[n])) }
		j_end(&b, ']'); j_end(&b)
		return done(strings.to_string(b))
	case "delete":
		cp, exists := r.checkpoints[name]
		if !exists { return fail(remote.ERR_PARAMS, fmt.tprintf("no checkpoint %q", name)) }
		delete_key(&r.checkpoints, name)
		checkpoint_free(cp)
		return done()
	case "restore":
		if name == "initial" { return m_reset(app, c) }
		cp, exists := r.checkpoints[name]
		if !exists { return fail(remote.ERR_PARAMS, fmt.tprintf("no checkpoint %q", name)) }
		return checkpoint_restore(app, c, cp)
	}
	return fail(remote.ERR_PARAMS, "action: save, restore, list or delete")
}

@(private = "file")
checkpoint_json :: proc(cp: ^Checkpoint) -> string {
	return fmt.tprintf(`{{"name":%s,"tabs":%d,"cookies":%d,"storageOrigins":%d}}`, remote.quote(cp.name), len(cp.tabs), len(cp.cookies), len(cp.storage))
}

@(private = "file")
sort_strings :: proc(list: []string) {
	for i in 1 ..< len(list) {
		for j := i; j > 0 && list[j] < list[j - 1]; j -= 1 { list[j], list[j - 1] = list[j - 1], list[j] }
	}
}

@(private = "file")
checkpoint_restore :: proc(app: ^App, c: ^Call, cp: ^Checkpoint) -> Reply {
	wnd := active_window(app)
	sum: Reset_Summary
	sum.ops = remote_cancel_ops("cancelled by a restore")
	chrome_reset(app)
	tabs_reset(app, "about:blank", &sum.tabs)   // (pages hold their storage: they go first)
	cookies.replace_all(&app.profile.jar, cp.cookies)
	sum.cookies = len(cp.cookies)
	clear_site(app, "*", {.Session, .Indexed_Db, .Cache})
	page.storage_restore_local(&app.storage, cp.storage)
	sum.sites = len(cp.storage)
	sum.prefs = config.restore(&app.prefs, cp.prefs)
	remote_reload_settings(app)
	sum.window = window_restore(app, cp.window)
	// the tabs again, then the blank one that held the place goes
	blank := wnd.tabs[wnd.current]
	for t in cp.tabs {
		nt := tab_open(app, t.url, origin = .Replay)
		zoom_set(app, nt, t.zoom)
	}
	for t, i in wnd.tabs { if t == blank { tab_close(app, i); break } }
	wnd.current = clamp(cp.current, 0, len(wnd.tabs) - 1)
	cur := current_tab(app)
	if cur != nil { ui.field_set(&wnd.address, cur.url) }
	r := &the_remote
	clear(&r.loaded)
	for t in tabs_all(app) { r.loaded[t.id] = false }
	request_frames(app, 3)
	what, _ := remote.param_string(c.params, "wait", "load")
	return start_wait(app, c, cur, what, reset_summary_json(sum, fmt.tprintf(`,"tabs":%d`, len(cp.tabs))))
}

// Wren.resetPref {name | all: true}: the preference(s) as they were when the channel started (command line, user and default
// layers alike), where setPref {override: true} may have changed a value `--pref` fixed.
m_pref_reset :: proc(app: ^App, c: ^Call) -> Reply {
	r := &the_remote
	if r.baseline == nil { return fail(remote.ERR_FAILED, "no baseline") }
	if all, _ := remote.param_bool(c.params, "all"); all {
		n := config.restore(&app.prefs, r.baseline.prefs)
		remote_reload_settings(app)
		request_frames(app, 3)
		return done(fmt.tprintf(`{{"restored":%d}}`, n))
	}
	name, bad := need_string(c, "name")
	if bad.code != 0 { return bad }
	for st, i in r.baseline.prefs {
		if st.name != name { continue }
		config.restore(&app.prefs, r.baseline.prefs[i:i + 1])
		remote_reload_settings(app)
		request_frames(app, 3)
		s, _ := pref_json(app, name)
		return done(s)
	}
	return fail(remote.ERR_PARAMS, fmt.tprintf("no preference %q", name))
}
