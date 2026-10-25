// Wasm-first browser shell. The chrome (tabs, address bar, developer tools) is built with gui_toolkit's `ui`; the page is a
// custom-draw box painted from the DOM. Everything a tab starts lives in the tab's scope: closing a tab is one call.
//
// Every load goes through the policy layer (package fetch): the main document, its Wasm modules (in document order), and
// whatever the modules fetch afterwards. The profile (cookies, HSTS) is loaded at start-up and saved as it changes.
package browser

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:cookies"
import "wb:desktop"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:html"
import "wb:http"
import "wb:net"
import lay "wb:layout"
import "wb:page"
import "wb:remote"
import "wb:url"
import "wb:wasm"
import "wb:tools/crashtrace"   // a crash leaves its symbolized stack and a minidump in <profile>\crashes

DEBUG_INPUT :: #config(DEBUG_INPUT, false)

debug_log :: proc(s: string) {
	f, err := os.open("build/debug.log", {.Write, .Create, .Append}, os.Permissions_Default_File)
	if err != nil { return }
	defer os.close(f)
	os.write_string(f, s)
	os.write_string(f, "\n")
}

Script_State :: enum u8 { Pending, Ready, Failed, Done }

// One <script type="application/wasm">: fetched concurrently, run in document order.
Script_Slot :: struct {
	load:  ^Doc_Load,
	url:   string,
	state: Script_State,
	bytes: [dynamic]byte,
}

// The state of one navigation, from request to the last module. It lives in the navigation scope.
Doc_Load :: struct {
	tab:        ^Tab,
	initiator:  fetch.Environment,      // who asked (a clone: the old page may already be gone)
	has_initiator: bool,
	page:       ^page.Page,
	status:     int,
	mime:       string,                  // essence
	charset:    string,
	final_url:  string,
	slots:      [dynamic]^Script_Slot,
	next_run:   int,
	bytes:      int,                     // size of the document's body
	view_source: bool,                   // a view-source: navigation: the bytes are shown as source (view_source.odin)
	task:       base.Handle,             // the document's request (Escape stops it)
	stopped:    bool,                    // Escape stopped it: the tab no longer shows it loading
	failed:     Load_Failure,            // the tab shows an error page (the security chip says so)
	pushed:     bool,                    // the navigation added a history entry (a download takes it back: download.odin)
	action:     Doc_Action,              // what the answer is shown as (download.odin doc_action)
	cache:      fetch.Cache_Mode,        // the document's cache mode; Reload: its subresources too (http_cache_ui.odin)
	from_cache: fetch.Cache_Outcome,     // where the document came from (the status bar says so)
	started_ns: i64,                     // the loop clock when the navigation began (Navigation Timing)
	response_ns: i64,                    // ... and when the head of the answer arrived
}

Load_Failure :: enum u8 { None, Other, Tls }

Tab_Kind :: enum u8 { Web, Config, History, Blocker }   // Blocker: about:blocker (blocker_dashboard.odin)   // History: about:history (history_ui.odin)

Tab :: struct {
	id:       u64,           // unique for the process: keys its boxes of the tab strip (tab_strip.odin)
	lazy:     bool,          // restored, not loaded yet: `url` loads when the tab is first shown (session.odin)
	icon:     Tab_Icon,      // its document's icon and title (favicon.odin)
	kind:     Tab_Kind,      // a web page, or the about:config view
	scope:    ^base.Scope,   // lives as long as the tab
	nav:      ^base.Scope,   // lives as long as the current navigation: the page and everything it started
	page:     ^page.Page,
	load:     ^Doc_Load,
	url:      string,
	title:    string,
	status:   string,
	console:  [dynamic]string,
	console_added: u64,         // lines ever added to console: line i of it is number console_added - len + i (devtools_console.odin)
	net:      Net_Log,         // the document's requests, for the Network tab (devtools_net_model.odin)
	conlog:   Con_Log,         // what the Console tab keeps beside the lines: their times, kinds, counts (devtools_console_log.odin)
	layout:   Layout,
	scroll:   f32,
	scroll_target: base.Handle, // what keyboard scrolling moves: the last element pressed in the page (its scroll container)
	fragment_seen: string,       // the document URL whose fragment the view last scrolled to (owned)
	web_fonts: int,              // faces of the page's @font-face already handed to the font registry
	web_font_page: rawptr,       // the page those faces came from (a new page starts over)
	image_sizes: u64,            // the page's image sizes generation the layout was made with (images_shell.odin)
	history:  [dynamic]string,   // addresses visited in this tab (mirror of `session`, for the chrome)
	hist:     int,               // index of the current one
	session:  Session_History,   // the joint session history: entries, history.state, same-document entries
	hold:     Paint_Hold,        // the previous page, shown until the new one paints (first_paint.odin)
	zoom:     f32,               // page zoom (zoom.odin); 1 = 100 %
	smooth:   Smooth_Scroll,     // scroll animations and scroll bar drags (smooth_scroll.odin)
	nav_state: Tab_Nav,          // restoring entries, leaving pages, the back/forward cache (history_restore.odin, bfcache.odin)
	frame:    ^Frame_View,       // non-nil: the stand-in tab of a frame's document, not a tab (frames_shell.odin)
}

Session_History :: page.Session_History   // (a field named `page` hides the package in the struct above)

App :: struct {
	win:      ^platform.Window,
	r:        render.Renderer,
	fonts:    font.State,
	dc:       draw.Context,
	ui_state: ui.State,
	theme:    ui.Theme,
	ui_font:  font.Font_Id,
	icons:    font.Font_Id,

	loop:     host.Loop,
	client:   net.Client,
	blocking: host.Blocking_Pool,
	prefs:    config.Prefs,   // every tunable of the browser (about:config)
	cfg:      Settings,       // the shell's own, derived from prefs
	page_settings: page.Settings,
	config_view:   Config_View,
	autosave_timer: base.Handle,
	profile:  fetch.Profile,
	loader:   fetch.Loader,
	storage:  page.Storage_Manager,   // localStorage / sessionStorage of the profile
	profile_dir: string,
	portable: bool,           // wren.portable beside the executable: the profile is <executable folder>\data (setup.odin)
	process:  ^base.Scope,

	tabs:     [dynamic]^Tab,
	current:  int,
	address:  ui.Text_Field,
	measure:  Measure,        // text measurement cache of the layout
	focus_address: bool,      // Ctrl+L: focus the address field in the next build
	show_console:  bool,

	page_rect: draw.Rect,   // where the page was painted last frame (physical pixels)
	frames_requested: int,
	last_tick:        time.Tick,
	presented:        bool,   // a frame went to the swap chain: from then on each frame waits for it to take the next
}

the_app: ^App

clip_get :: proc() -> string { return platform.get_clipboard(the_app.win, context.temp_allocator) }
clip_set :: proc(text: string) { platform.set_clipboard(the_app.win, text) }

current_tab :: proc(app: ^App) -> ^Tab { return len(app.tabs) > 0 ? app.tabs[app.current] : nil }

////////////////////////////////
// Tabs

@(private = "file") tab_ids: u64

tab_open :: proc(app: ^App, address := "", from: ^page.Page = nil, origin := Nav_Origin.Page) -> ^Tab {
	t := tab_new(app)
	app.current = len(app.tabs) - 1
	ui.field_set(&app.address, address)
	// an empty address opens the homepage; one that is refused (nav_trust.odin) leaves the homepage too, not an empty tab
	if !navigate(app, t, address, from, origin = origin) { navigate(app, t, "") }
	return t
}

// A new tab the user asked for (Ctrl+T, the + of the strip, the menus): the homepage, with the address field focused
// to type in, as in Chromium.
tab_open_new :: proc(app: ^App) -> ^Tab {
	t := tab_open(app)
	app.focus_address = true
	return t
}

// A tab at the end of the strip, showing nothing yet.
tab_new :: proc(app: ^App) -> ^Tab {
	t := new(Tab)
	tab_ids += 1
	t.id = tab_ids
	t.hist = -1
	t.zoom = 1
	t.scope = base.scope_make("tab", app.process)
	t.title = strings.clone("New tab")
	append(&app.tabs, t)
	tab_history_limits(app, t)
	blocker_tab_new(app, t)   // blocker_shell.odin
	recovery_touch(app)   // crash_recovery.odin
	return t
}

tab_close :: proc(app: ^App, index: int) {
	t := app.tabs[index]
	if shell_defer({kind = .Close_Tab, tab = t.id}) { return }   // (shell_frames.odin: its page may be the one running)
	closed_tabs_push(t.url)
	ordered_remove(&app.tabs, index)
	key := strings.clone(tab_key(t), context.temp_allocator)
	tab_free(app, t)
	page.storage_drop_session(&app.storage, key)   // (once its page is gone)
	if len(app.tabs) == 0 { tab_open(app) } else { app.current = clamp(app.current, 0, len(app.tabs) - 1) }
	if cur := current_tab(app); cur != nil { ui.field_set(&app.address, cur.url) }
	recovery_touch(app)
}

// Frees a tab taken out of the strip (closed, or at exit): its page and everything the shell keeps for it.
tab_free :: proc(app: ^App, t: ^Tab) {
	bfcache_drop_tab(t)
	tab_nav_destroy(app, t)
	base.scope_close(t.scope)   // page, instances, DOM, requests, timers: all gone (a held page too)
	hold_destroy(t)
	page_fonts_drop(&page_render.fonts, t)   // its web fonts (fonts.odin)
	page.session_destroy(&t.session)
	delete(t.url); delete(t.title); delete(t.status)
	delete(t.fragment_seen)
	tab_icon_destroy(&t.icon)
	for h in t.history { delete(h) }
	delete(t.history)
	for l in t.console { delete(l) }
	delete(t.console)
	net_log_destroy(&t.net)
	console_log_destroy(t)
	layout_destroy(&t.layout)
	smooth_destroy(&t.smooth)
	free(t)
}

tab_log :: proc(t: ^Tab, level: page.Log_Level, message: string) { console_append(t, level, message) }

console_sink :: proc(user: rawptr, level: page.Log_Level, message: string) {
	if the_remote.active && remote_take_console(message, (^Tab)(user).id) { return }   // (an answer of a remote script, not a message)
	t := (^Tab)(user)
	tab_log(t, level, message)
	if remote_subscribed() { remote_event("Runtime.consoleAPICalled", fmt.tprintf(`{{"tabId":%d,"type":%q,"text":%s}}`, t.id, level == .Error ? "error" : level == .Warn ? "warning" : "log", remote.quote(message))) }
}

set_status :: proc(t: ^Tab, s: string) {
	delete(t.status)
	t.status = strings.clone(s)
}

////////////////////////////////
// Navigation

// What the user typed: a URL, a file path, or a bare host.
normalize_address :: proc(input: string) -> string {
	s := strings.trim_space(input)
	if u, ok := local_path_url(s); ok { return u }   // C:\dir\page.html, \\server\share, ~ (local_paths.odin)
	if s == "about:" { return ABOUT_URL }
	if !strings.contains(s, "://") && !strings.has_prefix(s, "about:") && !strings.has_prefix(s, "data:") && s != "" {
		return strings.concatenate({"https://", s}, context.temp_allocator)
	}
	return s
}

// Starts loading `address` in `t`. `from` is the page the navigation comes from (a link click), nil for the address bar.
// `origin` says who chose the address (nav_trust.odin): a person (`.User`: the address bar, a menu, the command line), the
// browser showing an entry again (`.Replay`: back, forward, reload, a restored tab), or a document (`.Page`, the default: a
// navigation nobody vouches for has no privilege). false: refused, nothing changed and nothing recorded.
// `record`: false when the navigation walks the history (back, forward, reload) instead of extending it.
// `method` / `body` / `headers`: a form submission (POST); the history keeps the address only.
// `restore`: the navigation shows the current entry again (back, forward, a reload, a restored tab): what it showed when it
// was left comes back with it (history_restore.odin).
navigate :: proc(app: ^App, t: ^Tab, address: string, from: ^page.Page = nil, user_activation := false, record := true, method := "", body: []byte = nil, headers: []fetch.Header_Pair = nil, restore := false, cache := fetch.Cache_Mode.Default, origin := Nav_Origin.Page) -> (accepted: bool) {
	// asked by the chrome during a chrome frame (shell_frames.odin): once the page holding the thread is done (a form's
	// method and body come from page input, which is never handled there)
	if shell_nested() { shell_defer({kind = .Navigate, tab = t.id, text = strings.clone(address), flag = user_activation, record = record, restore = restore, cache = cache, origin = origin, from = from}); return true }
	target := strings.clone(normalize_address(address), context.temp_allocator)
	origin := origin
	if target == "" { target, origin = strings.clone(app.cfg.homepage, context.temp_allocator), .User }   // (the person's own setting)
	verdict := nav_judge(origin, from != nil ? &from.env : nil, app.loader.profile.settings.file_access, target)
	if verdict.refuse != "" { nav_refused(t, from, target, verdict.refuse); return false }
	accepted = true   // (from here on the early returns of the built-in pages are acceptances)
	target = verdict.address
	cache_prof_leave(t)   // (profile build: what the page cost, http_cache_ui.odin)
	leave_page(app, t)   // the entry being left keeps what it shows; the page may go to the back/forward cache
	t.nav_state.no_store = false
	pushed := false
	if record {
		cur := page.session_current(&t.session)
		pushed = cur == nil || cur.url != target   // (visiting the current entry's URL again adds none)
		history_push(t, target)
	}
	// built-in pages show at once (they paint in their first frame)
	entry := page.session_current(&t.session)
	restore_stop(app, t)
	if restore && entry != nil && hcfg.restore_zoom && entry.persisted.zoom > 0 { t.zoom = entry.persisted.zoom }
	if restore { timing_begin(t, false, target) }
	defer if restore { restore_begin(app, t, entry, .New_Document) }
	license_file := is_license_file_address(target) && verdict.acts   // license_shell.odin
	if is_builtin_address(target) || license_file { hold_release(t); bfcache_take(app, t) }   // (show_* closes the tab's navigation scope)
	if target == "about:config" { show_config(app, t); return }
	if is_history_address(target) { show_history(app, t, target); return }
	if is_blocker_address(target) { show_blocker(app, t, target); return }   // blocker_dashboard.odin
	if target == HOME_URL { show_home(app, t); return }
	if target == DEMOS_URL { show_demos(app, t); return }
	if target == ABOUT_URL { show_about_pages(app, t); return }
	if is_wren_address(target) { show_wren_page(app, t, target, verdict.acts); return }   // about_wren.odin
	if license_file { license_open_file(app, t, target); return }
	if is_cache_address(target) { hold_release(t); bfcache_take(app, t); show_cache_page(app, t, target, verdict.acts); return }   // http_cache_ui.odin
	if is_sites_address(target) { hold_release(t); bfcache_take(app, t); show_sites_page(app, t, target, verdict.acts); return }   // site_data_ui.odin
	load := new(Doc_Load)
	load.tab = t
	load.started_ns = host.now_ns(&app.loop)
	load.pushed = pushed
	load.cache = cache
	shown := target
	if strings.has_prefix(target, VIEW_SOURCE) {
		load.view_source = true
		target = strings.clone(normalize_address(target[len(VIEW_SOURCE):]), context.temp_allocator)
	}
	// (a link of a built-in page opens as the address bar would: about:demos links to local files)
	if from != nil && !verdict.trusted { load.initiator, load.has_initiator = fetch.environment_clone(from.env), true }

	// the previous page stays on screen until this one paints, or closes now (first_paint.odin)
	hold_begin(app, t, target)
	load_measure_begin(app, t, target)   // blocker_measure.odin
	t.kind = .Web
	t.nav = base.scope_make("navigation", t.scope)
	base.on_close(t.nav, load_closed, load)
	t.page = nil
	t.load = load
	t.scroll_target = base.NIL_HANDLE
	t.scroll = 0
	delete(t.fragment_seen)
	t.fragment_seen = ""   // a new document scrolls to its fragment again
	console_reset(t)
	delete(t.url)
	t.url = strings.clone(shown)
	delete(t.title)
	t.title = default_tab_title(shown, context.allocator)   // until the document says better (favicon.odin)
	ui.field_set(&app.address, shown)
	set_status(t, "loading...")

	load.task = fetch.start(&app.loader, {
		request = {
			url = target, mode = .Navigate, credentials = .Include, redirect = .Follow, destination = .Document,
			initiator = load.has_initiator ? &load.initiator : nil, user_activation = user_activation,
			method = method, body = body, headers = headers, cache = cache,
		},
		on_event = document_event, user = load, scope = t.nav, collect = true,
	})
	return
}

history_push :: proc(t: ^Tab, target: string) {
	page.session_push(&t.session, target, 0, max_entries = the_app.page_settings.web.history_max_entries)
	sync_history(t)
}

// The chrome's view of the session history (back / forward buttons).
sync_history :: proc(t: ^Tab) {
	for h in t.history { delete(h) }
	clear(&t.history)
	for e in t.session.entries { append(&t.history, strings.clone(e.url)) }
	t.hist = t.session.index
	recovery_touch(the_app)   // (every change of a tab's history: a navigation, back, forward, a redirect)
}

go_history :: proc(app: ^App, t: ^Tab, delta: int) {
	if t == nil || delta == 0 { return }
	if shell_defer({kind = .History, tab = t.id, delta = delta}) { return }   // (shell_frames.odin)
	go_entry(app, t, page.session_peek(&t.session, delta))
}

// Makes `e` (any entry of the tab's history tree: the path to it becomes the active one) the current entry: popstate
// when it is the document's, else the page it had from the back/forward cache, else it loads again.
go_entry :: proc(app: ^App, t: ^Tab, e: ^page.History_Entry) {
	if t == nil || e == nil || e == page.session_current(&t.session) { return }
	if shell_defer({kind = .Entry, tab = t.id, entry = e.id}) { return }   // (shell_frames.odin)
	// an entry of the current document: popstate, no load
	if t.page != nil && t.kind == .Web && page.history_traverse_to(t.page, e) == .Same_Document {
		sync_history(t)
		same_document_url(app, t, t.page.env.location.href)
		return
	}
	leave_page(app, t)
	page.session_goto(&t.session, e)
	sync_history(t)
	if bfcache_restore(app, t, e) { return }
	navigate(app, t, strings.clone(e.url, context.temp_allocator), record = false, restore = true, cache = history_cache_mode(app), origin = .Replay)
}

same_document_url :: proc(app: ^App, t: ^Tab, address: string) {
	delete(t.url)
	t.url = strings.clone(address)
	if current_tab(app) == t { ui.field_set(&app.address, address) }
	recovery_touch(app)
}

// sessionStorage partition of a tab (dropped when the tab closes).
tab_key :: proc(t: ^Tab) -> string { return fmt.tprintf("tab-%p", t) }

// What a page's script asks of its tab (location, history): always from a task of the page, never from inside a guest call.
page_navigate :: proc(user: rawptr, p: ^page.Page, req: page.Navigate_Request) {
	app := the_app
	t := (^Tab)(user)
	if t.page != p { return }
	switch req.kind {
	case .Assign:
		navigate(app, t, strings.clone(req.url, context.temp_allocator), p)
	case .Replace:
		// judged before the entry changes: a refused address (nav_trust.odin) must not replace the page's entry
		v := nav_judge(.Page, &p.env, app.loader.profile.settings.file_access, normalize_address(req.url))
		if v.refuse != "" {
			nav_refused(t, p, req.url, v.refuse)
			break
		}
		leave_page(app, t, keep = false, save = false)
		if cur := page.session_current(&t.session); cur != nil { page.persisted_clear(&cur.persisted) }   // another document in the entry
		page.session_replace(&t.session, v.address)
		sync_history(t)
		navigate(app, t, strings.clone(req.url, context.temp_allocator), p, record = false)
	case .Reload:
		reload(app, t)
	case .Traverse:
		go_history(app, t, req.delta)
	case .Url_Changed:
		sync_history(t)
		same_document_url(app, t, req.url)
		global_history_visit(app, t, req.url, t.title)
	}
	app.frames_requested = max(app.frames_requested, 2)
}

// Connects a document to its tab: navigation hook, session history, storage.
attach_page :: proc(app: ^App, t: ^Tab, p: ^page.Page) {
	page.set_embedder(p, {navigate = page_navigate, user = t, session = &t.session, tab_key = tab_key(t), storage = &app.storage, print = page_print, leaving = page_entry_leaving, entered = page_entry_entered})
	if cur := page.session_current(&t.session); cur != nil { bfcache_forget(t, cur.id) }   // a new document for the entry: an older one cached for it is stale
	attach_js_layout(app, t, p)   // geometry for scripts (js_layout_shell.odin)
}

// A reload keeps the entry's positions and forms (as other browsers do); the page itself does not go to the back/forward
// cache (a new document replaces it). The document is revalidated with its server (no-cache); `bypass_cache` (Ctrl+F5):
// it and everything it loads come from the network (reload).
reload :: proc(app: ^App, t: ^Tab, bypass_cache := false) {
	if shell_defer({kind = .Reload, tab = t.id, flag = bypass_cache}) { return }   // (shell_frames.odin)
	leave_page(app, t, keep = false)
	navigate(app, t, strings.clone(t.url, context.temp_allocator), record = false, restore = true, cache = bypass_cache ? .Reload : .No_Cache, origin = .Replay)
}

load_closed :: proc(data: rawptr) {
	load := (^Doc_Load)(data)
	if load.tab != nil && load.tab.load == load { load.tab.load = nil }
	if load.has_initiator { fetch.environment_destroy(&load.initiator) }
	for s in load.slots { delete(s.url); delete(s.bytes); free(s) }
	delete(load.slots)
	delete(load.mime); delete(load.charset); delete(load.final_url)
	free(load)
}

// about:config is a view of the browser itself, not a document: it has no page, no origin, no scripts.
show_config :: proc(app: ^App, t: ^Tab) {
	base.scope_close(t.nav)
	t.nav = base.scope_make("navigation", t.scope)
	t.page, t.load, t.kind = nil, nil, .Config
	layout_reset(&t.layout)
	t.scroll_target = base.NIL_HANDLE
	console_reset(t)
	delete(t.url); t.url = strings.clone("about:config")
	delete(t.title); t.title = strings.clone("Configuration")
	set_status(t, "about:config")
	ui.field_set(&app.address, "about:config")
}

// An HTML page the browser makes up when a load fails, so the tab always shows something readable.
// (error_pages.odin writes it.)
show_error_page :: proc(app: ^App, load: ^Doc_Load, e: Error_Text) {
	t := load.tab
	if load.page == nil {
		load.page = page.page_create(&app.loop, &app.loader, &app.page_settings, t.nav, "about:blank", console_sink, t)
		t.page = load.page
		attach_page(app, t, load.page)
	}
	load.failed = e.kind == .Tls ? .Tls : .Other
	title := error_tab_title(t.url)
	page.load_html(load.page, transmute([]byte)error_page_html(e, t.url, title))
	delete(t.title)
	t.title = strings.clone(title)
	set_status(t, e.headline)
	tab_log(t, .Error, fmt.tprintf("%s: %s", e.headline, e.detail))
}

escape_html :: proc(s: string) -> string {
	r, _ := strings.replace_all(s, "&", "&amp;", context.temp_allocator)
	r, _ = strings.replace_all(r, "<", "&lt;", context.temp_allocator)
	r, _ = strings.replace_all(r, ">", "&gt;", context.temp_allocator)
	r, _ = strings.replace_all(r, "\"", "&quot;", context.temp_allocator)
	return r
}

document_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	load := (^Doc_Load)(user)
	t := load.tab
	app := the_app
	defer { app.frames_requested = max(app.frames_requested, 3) }
	switch ev.kind {
	case .Response:
		r := ev.response
		// an answer to save rather than show: the request goes on as a download, the tab keeps its page (download.odin)
		disposition, _ := http.get_header(r.headers, "content-disposition")
		load.action = doc_action(r.has_mime ? http.mime_essence(r.mime) : "", disposition, r.url)
		if load.action == .Download && !load.view_source && r.status >= 200 && r.status < 300 {
			download_from_navigation(app, load, task, r, disposition)
			return   // (`load` is gone)
		}
		load.status = r.status
		load.final_url = strings.clone(r.url)
		if r.has_mime {
			load.mime = strings.clone(http.mime_essence(r.mime))
			if cs, ok := http.mime_param(r.mime, "charset"); ok { load.charset = strings.clone(cs) }
		}
		load.from_cache = r.cache
		set_status(t, fmt.tprintf("HTTP %d%s", r.status, cache_status_suffix(r.cache)))
		shown := load.view_source ? strings.concatenate({VIEW_SOURCE, r.url}, context.temp_allocator) : r.url
		delete(t.url)
		t.url = strings.clone(shown)
		if current_tab(app) == t { ui.field_set(&app.address, shown) }
		// an image is shown by a document the browser writes once the image is in (download.odin show_image_document)
		if load.action == .Image && !load.view_source { return }
		// the document exists from here on, with the origin of its *final* URL
		if cc, ok := http.get_header(r.headers, "cache-control"); ok && strings.contains(strings.to_lower(cc, context.temp_allocator), "no-store") { t.nav_state.no_store = true }
		// a redirect: the entry is the final address
		if cur := page.session_current(&t.session); cur != nil && !load.view_source && cur.url != r.url { page.session_replace(&t.session, r.url, set_state = false); sync_history(t) }
		load.page = page.page_create(&app.loop, &app.loader, &app.page_settings, t.nav, r.url, console_sink, t)
		if load.cache == .Reload { load.page.env.cache_override = .Reload }   // Ctrl+F5: everything it loads, from the network
		load.response_ns = host.now_ns(&app.loop)
		page.set_navigation_timing(load.page, {
			start_ns = load.started_ns, response_ns = load.response_ns, reload = load.cache == .Reload || load.cache == .No_Cache,
			status = r.status, from_cache = r.cache == .Hit, mime = load.mime, redirects = r.redirected ? 1 : 0,
		})
		attach_page(app, t, load.page)
		t.page = load.page
		if !load.view_source && r.status < 400 { global_history_visit(app, t, r.url, "") }
		csp_h := http.get_all(r.headers, "content-security-policy")
		ro_h := http.get_all(r.headers, "content-security-policy-report-only")
		rp, _ := http.get_header(r.headers, "referrer-policy")
		page.apply_response_headers(load.page, csp_h, ro_h, rp)
	case .Data:
	case .Done:
		document_loaded(app, load, ev.data)
	case .Failed:
		load.task = base.NIL_HANDLE
		show_error_page(app, load, classify_load_error(t.url, ev.error, ev.net_code, ev.detail))
	}
}

looks_like_wasm :: proc(data: []byte) -> bool {
	return len(data) >= 4 && data[0] == 0 && data[1] == 'a' && data[2] == 's' && data[3] == 'm'
}

document_loaded :: proc(app: ^App, load: ^Doc_Load, data: []byte) {
	t := load.tab
	p := load.page
	load.task = base.NIL_HANDLE
	if load.view_source { show_source(app, load, data); return }
	if looks_like_wasm(data) || load.action == .Wasm {
		// the document is a module
		_, ok, err := page.load_module(p, data, t.url)
		if ok { set_status(t, fmt.tprintf("%s: running", t.url)) } else { set_status(t, err); tab_log(t, .Error, err) }
		page.render_begin(p)   // the document is what the module built
		return
	}
	switch load.action {
	case .Text: show_text(app, load, data); return
	case .Image: show_image_document(app, load); return
	case .Download:
		// (only an error status gets here: a successful one became a download)
		show_error_page(app, load, {kind = .Content, headline = "This page can't be shown", explain = fmt.tprintf("The server answered HTTP %d with a file to download.", load.status), detail = fmt.tprintf("type %s", load.mime)})
		return
	case .Render, .Wasm:
	}

	// decoded and parsed off the UI thread (page.threads.*); the page closing first cancels the callback
	load.bytes = len(data)
	page.navigation_response_end(p, host.now_ns(&app.loop), len(data))
	page.parse_document(p, data, load.charset, document_parsed, load)
}

document_parsed :: proc(p: ^page.Page, user: rawptr, d: ^page.Parsed_Document) {
	load := (^Doc_Load)(user)
	t := load.tab
	app := the_app
	app.frames_requested = max(app.frames_requested, 3)
	if !d.decoded {
		show_error_page(app, load, {kind = .Content, headline = "This page can't be shown", explain = "Its text could not be decoded.", detail = fmt.tprintf("encoding %q", load.charset)})
		return
	}
	r := page.adopt_document(p, d)
	if !p.render.adopted { page.render_begin(p) }   // nothing adopted: the blank document is what there is
	if !r.ok { tab_log(t, .Error, fmt.tprintf("HTML parse failed (%d)", r.status)) }
	if r.truncated { tab_log(t, .Warn, "document truncated: too many nodes") }
	if title := collapse_title(html.title(p.doc)); title != "" {
		delete(t.title)
		t.title = strings.clone(title)
	}
	recovery_touch(app)   // (the document is there: its title and, a moment later, where it is scrolled)
	set_status(t, fmt.tprintf("HTTP %d%s, %d bytes (%s), %d nodes", load.status, cache_status_suffix(load.from_cache), load.bytes, d.encoding, r.nodes))
	start_scripts(app, load)
	page.scripts_start(p)   // JavaScript (js_scripts.odin)
}

show_text :: proc(app: ^App, load: ^Doc_Load, data: []byte) {
	d, ok := html.decode_document(data, load.charset, app.page_settings.html.default_encoding)
	if !ok { return }
	defer delete(d.text)
	p := load.page
	pre := dom.create_element(p.doc, "pre")
	dom.set_text_content(p.doc, pre, string(d.text[:min(len(d.text), 1 << 20)]))
	dom.append_child(p.doc, p.body, pre)
	page.render_begin(p)
	set_status(load.tab, fmt.tprintf("HTTP %d, %d bytes of text", load.status, len(data)))
}

////////////////////////////////
// Wasm modules: fetched concurrently, run in document order

start_scripts :: proc(app: ^App, load: ^Doc_Load) {
	p := load.page
	t := load.tab
	for sh in html.wasm_scripts(p.doc, app.page_settings.html.module_script_type) {
		src, has := dom.get_attribute(p.doc, sh, "src")
		if !has || src == "" { tab_log(t, .Error, "an inline Wasm script needs a src (use a data: URL)"); continue }
		resolved, ok := url.parse(src, &p.env.location, context.temp_allocator)
		if !ok { tab_log(t, .Error, fmt.tprintf("invalid script URL %q", src)); continue }
		nonce, _ := dom.get_attribute(p.doc, sh, "nonce")
		slot := new(Script_Slot)
		slot.load = load
		slot.url = strings.clone(resolved.href)
		append(&load.slots, slot)
		fetch.start(&app.loader, {
			request = {url = resolved.href, mode = .Cors, credentials = .Same_Origin, destination = .Script, initiator = &p.env, nonce = nonce},
			on_event = script_event, user = slot, scope = t.nav, collect = true,
		})
	}
	run_ready_scripts(load)
}

script_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	slot := (^Script_Slot)(user)
	load := slot.load
	#partial switch ev.kind {
	case .Done:
		append(&slot.bytes, ..ev.data)
		slot.state = .Ready
	case .Failed:
		tab_log(load.tab, .Error, fmt.tprintf("module %s: %s", slot.url, ev.detail))
		slot.state = .Failed
	case .Response:
		if ev.response.status != 200 && ev.response.type != .Opaque {
			tab_log(load.tab, .Error, fmt.tprintf("module %s: HTTP %d", slot.url, ev.response.status))
		}
	}
	run_ready_scripts(load)
	the_app.frames_requested = max(the_app.frames_requested, 3)
}

// Runs modules in order: a later module waits for an earlier one that is still loading.
run_ready_scripts :: proc(load: ^Doc_Load) {
	for load.next_run < len(load.slots) {
		s := load.slots[load.next_run]
		switch s.state {
		case .Pending: return
		case .Failed, .Done: load.next_run += 1
		case .Ready:
			s.state = .Done
			load.next_run += 1
			_, ok, err := page.load_module(load.page, s.bytes[:], s.url)
			if !ok { tab_log(load.tab, .Error, fmt.tprintf("module %s: %s", s.url, err)) }
			if load.next_run >= len(load.slots) { set_status(load.tab, fmt.tprintf("%d module(s) running", len(load.slots))) }
		}
	}
}

////////////////////////////////
// UI

page_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	app := the_app
	app.page_rect = b.rect
	t := current_tab(app)
	if shell_nested() {
		// a chrome frame (shell_frames.odin): the page holds the thread; its last frame, nothing of it runs
		if t == nil || t.kind != .Web || !shell_paint_page(app, t, dc, b.rect) { draw.rect(dc, b.rect, to_draw(expected_canvas(app))) }
		return
	}
	for other in app.tabs { if other != t { hold_release(other) } }   // a frame held in a tab not shown is of no use
	if t == nil || t.kind != .Web {
		draw.rect(dc, b.rect, to_draw(expected_canvas(app)))
		return
	}
	defer loading_bar(app, t, dc, b.rect)
	defer devtools_overlay(app, t, dc, b.rect)   // devtools.odin: the Elements tab's box over the page
	if t.page == nil {
		// the request is out: the previous page stays (first_paint.odin), else the expected canvas
		hold_paint(app, t, dc, b.rect, expected_canvas(app))
		return
	}
	page_paint(app, t, dc, b.rect)   // page_frame.odin
}

// HTML "scroll to the fragment": when the document URL changes (load, link to #id, location.hash, history), the view
// goes to the element whose id (or <a name>) is the fragment; "top" or an empty fragment goes to the top.
scroll_to_fragment :: proc(t: ^Tab, viewport: draw.Vec2) {
	href := t.page.env.location.href
	if href == t.fragment_seen || !t.layout.valid { return }
	// within the same document the page's scroll-behavior: smooth animates it (smooth_scroll.odin); a new one jumps
	smooth := t.fragment_seen != "" && css_smooth(the_app, t)
	delete(t.fragment_seen)
	t.fragment_seen = strings.clone(href)
	loc := t.page.env.location
	if !loc.has_fragment { return }
	frag := loc.fragment
	frag = percent_decode_bytes(frag)   // HTML: the decoded fragment is tried as an id
	if frag == "" || strings.equal_fold(frag, "top") { scroll_document_to(the_app, t, 0, smooth); return }
	target := dom.find_by_id(t.page.doc, frag)
	if target == base.NIL_HANDLE { target = find_named_anchor(t.page.doc, frag) }
	if target == base.NIL_HANDLE { return }
	if r, ok := lay.box_of(&t.layout, target, viewport, t.scroll); ok && !r.fixed { scroll_document_to(the_app, t, max(r.border.min.y, 0), smooth) }
}

@(private = "file")
percent_decode_bytes :: proc(s: string) -> string {
	if strings.index_byte(s, '%') < 0 { return s }
	hex :: proc(c: u8) -> int {
		switch c {
		case '0' ..= '9': return int(c - '0')
		case 'a' ..= 'f': return int(c - 'a') + 10
		case 'A' ..= 'F': return int(c - 'A') + 10
		}
		return -1
	}
	out := make([dynamic]u8, 0, len(s), context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) && hex(s[i + 1]) >= 0 && hex(s[i + 2]) >= 0 {
			append(&out, u8(hex(s[i + 1]) * 16 + hex(s[i + 2])))
			i += 2
		} else { append(&out, s[i]) }
	}
	return string(out[:])
}

@(private = "file")
find_named_anchor :: proc(d: ^dom.Document, name: string) -> base.Handle {
	stack := make([dynamic]base.Handle, context.temp_allocator)
	append(&stack, d.root)
	for len(stack) > 0 {
		h := pop(&stack)
		n := dom.get(d, h)
		if n == nil { continue }
		if n.kind == .Element && n.name == "a" {
			if v, ok := dom.get_attribute(d, h, "name"); ok && v == name { return h }
		}
		for c := n.last_child; c != base.NIL_HANDLE; c = dom.get(d, c).prev { append(&stack, c) }
	}
	return base.NIL_HANDLE
}

// The page's own box (or the view of a built-in page): what fills the room the developer tools leave.
page_view :: proc(app: ^App, t: ^Tab) {
	ui.next({width = ui.fill(), height = ui.fill()})
	if t != nil && t.kind == .Config {
		config_page(&app.config_view, &app.prefs)
	} else if t != nil && t.kind == .History {
		history_page(app, t)   // history_ui.odin
	} else if t != nil && t.kind == .Blocker {
		blocker_page(app, t)   // blocker_dashboard.odin
	} else {
		// a Tab stop of the chrome: reaching it hands the keyboard to the page (forms_focus_from_chrome)
		pb := ui.custom("###page_area", page_draw, nil, {.Focusable})
		page_area_focus(app, t, pb)
		blocker_picker_frame(app, t)   // blocker_picker.odin
	}
}

build_ui :: proc(app: ^App) {	session_lazy_load(app)   // session.odin: a restored tab loads when it is first shown
	chrome_shortcuts(app)
	t := current_tab(app)
	if ui.style({width = ui.fill(), height = ui.fill()}) {
		ui.next({axis = .Y})
		root := ui.build_box({.Draw_Background}, "###window")
		if ui.parent(root) {
			// tab strip (the window's title bar when integrated: window_chrome.odin), navigation, security chip,
			// address, menu; in full screen they come over the page on demand (fullscreen_bars)
			if !platform.is_fullscreen(app.win) {
				if tab_strip(app, platform.is_integrated_title(app.win)) { return }
				toolbar_row(app, t)   // chrome_style.odin
			}
			elem_fs := fullscreen_shell_active()   // a page's element in full screen: the page has the whole window
			if !elem_fs { crash_banner(app); find_bar(app, t) }   // crash_banner.odin
			// the page, and the developer tools docked next to it (devtools.odin): the page takes what the panel leaves
			dock, dev_on := devtools_dock(app, t)
			switch {
			case dev_on && dock == .Right:
				ui.next({width = ui.fill(), height = ui.fill()})
				if ui.row(.Start, {}, "###page_and_devtools") {
					page_view(app, t)
					devtools_splitter(app, true)
					devtools_panel(app, t, false, {width = ui.px(devtools_extent(app, true)), height = ui.fill()})
				}
			case dev_on && dock == .Left:
				ui.next({width = ui.fill(), height = ui.fill()})
				if ui.row(.Start, {}, "###devtools_and_page") {
					devtools_panel(app, t, false, {width = ui.px(devtools_extent(app, true)), height = ui.fill()})
					devtools_splitter(app, true)
					page_view(app, t)
				}
			case dev_on && dock == .Bottom:
				page_view(app, t)
				devtools_splitter(app, false)
				devtools_panel(app, t, false, {width = ui.fill(), height = ui.px(devtools_extent(app, false))})
			case:
				page_view(app, t)
			}
			// status bar (status_bar.odin)
			if !elem_fs { status_bar_build(app, t) }
			fullscreen_bars(app, t)
			devtools_floating(app, t)   // over the page when it is undocked
		}
	}
	context_menus_build(app)
	palette_build(app)   // palette.odin: the command palette, over everything else
	setup_build(app)   // setup_ui.odin: the Setup dialog (nothing while it is closed)
	// notices go over the page, not over the title bar's window buttons
	if app.page_rect.max.y > app.page_rect.min.y { ui.set_toast_area(app.page_rect) }
	ui.toasts_build()
}

// href of the nearest <a> at or above `h`.
anchor_href :: proc(d: ^dom.Document, h: base.Handle) -> (string, bool) {
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil { break }
		if n.kind == .Element && n.name == "a" {
			if v, ok := dom.get_attribute(d, cur, "href"); ok { return v, true }
		}
		cur = n.parent
	}
	return "", false
}

// Mouse and wheel events that land on the page become DOM events / scrolling.
route_page_input :: proc(app: ^App, events: []platform.Event) {
	t := current_tab(app)
	if t == nil || t.page == nil || t.kind != .Web { return }
	page_world_check("route_page_input: page input in a chrome frame, or during a page thread pass")
	scale := page_scale(app)
	last_move: platform.Event
	have_move := false
	defer if have_move && t.page != nil {
		hovered := base.NIL_HANDLE
		if draw.rect_contains(app.page_rect, last_move.pos) && t.layout.valid { hovered = hit_test(&t.layout, last_move.pos - app.page_rect.min, draw.rect_size(app.page_rect), t.scroll) }
		st := t.page.style_state
		was := st.hover
		st.hover = hovered
		page.set_style_state(t.page, st)
		page_pointer_events(app, t, was, hovered, last_move.pos)   // page_pointer.odin
	}
	for ev, index in events {
		inside := draw.rect_contains(app.page_rect, ev.pos)
		if dev.picking && (ev.kind == .Mouse_Move || ev.kind == .Mouse_Press || ev.kind == .Mouse_Release) && devtools_pick_event(app, t, int(ev.kind), ev.pos, ev.kind == .Mouse_Press) { continue }   // the element picker of the developer tools (devtools_elements.odin)
		if DEBUG_INPUT && ev.kind != .Mouse_Move { debug_log(fmt.tprintf("event %v at %v inside=%v rect=%v", ev.kind, ev.pos, inside, app.page_rect)) }
		if fullscreen_shell_escape(app, ev) { consume(index); continue }   // Escape leaves a page's full screen, the page does not see it (fullscreen_shell.odin)
		if !hud_captures(ev.pos) && scrollbar_event(app, t, ev) { continue }   // the page's scroll bars (smooth_scroll.odin)
		// pointer events over a frame, and the keyboard of a frame that has it, are its document's (frames_shell.odin)
		if !hud_captures(ev.pos) && frames_route_pointer(app, t, ev, index) { continue }
		if frames_route_keys(app, ev, index) { continue }
		// form controls first: keyboard for the focused field, the open drop-down list (forms_shell.odin)
		if forms_route_event(app, t, ev, index) { continue }
		if t.page == nil { return }
		if (ev.kind == .Mouse_Press || ev.kind == .Scroll) && hud_captures(ev.pos) { continue }   // the frame statistics panel
		#partial switch ev.kind {
		case .Mouse_Move:
			last_move, have_move = ev, true   // only the last position of the frame matters: hit test once, after the loop
			selection_pointer_move(app, t, ev.pos)
		case .Scroll:
			if inside && .Ctrl in ev.mods {
				// Ctrl+wheel zooms the page (wheel up = delta.y < 0 = bigger)
				if ev.delta.y != 0 { zoom_step(app, t, ev.delta.y < 0 ? 1 : -1) }
			} else if inside {
				d := ev.delta * wheel_step(app, (app.page_rect.max - app.page_rect.min) / max(scale, 0.01)) * scale   // platform convention: +y = towards the end of the content
				smooth_wheel(app, t, ev.pos - app.page_rect.min, d, wheel_is_precise(ev.delta))   // smooth_scroll.odin
			}
		case .Mouse_Press:
			if !inside || !t.layout.valid { continue }
			if ui.ctx_menu_any_open() { continue }   // the press closes the menu (the toolkit's)
			local := ev.pos - app.page_rect.min + {0, t.scroll}
			pressed := hit_test(&t.layout, ev.pos - app.page_rect.min, draw.rect_size(app.page_rect), t.scroll)
			t.scroll_target = pressed
			allowed := forms_pointer_down(app, t, ev, pressed, local)
			if t.page == nil { return }
			if ev.button == .Left { page_set_active(t.page, pressed) }   // :active while the button is held
			if ev.button == .Left { selection_pointer_down(app, t, ev, pressed, allowed) }
			if ev.button == .Right { page_context_press(app, t, ev.pos) }
		case .Mouse_Release:
			if ev.button == .Left { page_set_active(t.page, base.NIL_HANDLE) }
			if !t.layout.valid { continue }
			local := ev.pos - app.page_rect.min + {0, t.scroll}
			released := inside ? hit_test(&t.layout, ev.pos - app.page_rect.min, draw.rect_size(app.page_rect), t.scroll) : base.NIL_HANDLE
			dragged := selection_pointer_up(app, t, ev)
			target, clicked := forms_pointer_up(app, t, ev, released, local)
			if t.page == nil { return }
			if ev.button == .Right && inside { page_context_menu(app, t, released, ev.pos, local, .Shift in ev.mods) }
			if !clicked || t.page == nil || dragged { continue }
			not_prevented := forms_click(app, t, target, ev, local)
			if t.page == nil { return }
			// default action: following a link, unless a listener called preventDefault
			if not_prevented && ev.button == .Left {
				if href, ok := anchor_href(t.page.doc, target); ok {
					resolved, rok := url.parse(href, &t.page.env.location, context.temp_allocator)
					if !rok { tab_log(t, .Error, fmt.tprintf("invalid link %q", href)); continue }
					if page.follow_fragment_link(t.page, resolved) { continue }   // same document: page_draw scrolls to the target
					if page.follow_javascript_url(t.page, resolved) { continue }  // javascript: runs in the page (js_load_realm.odin)
					if frames_link_target(app, t, target, resolved.href) { continue }   // target="a frame's name" (frames_shell.odin)
					navigate(app, t, resolved.href, t.page, user_activation = true)
					have_move = false
					return   // the page is gone: the rest of this frame's events belong to the old one
				}
			}
		}
	}
}

////////////////////////////////
// Preferences and profile

profile_paths :: proc(app: ^App) -> (cookie_file, hsts_file, prefs_file: string) {
	return strings.concatenate({app.profile_dir, "/cookies.tsv"}, context.temp_allocator),
	       strings.concatenate({app.profile_dir, "/hsts.txt"}, context.temp_allocator),
	       strings.concatenate({app.profile_dir, "/prefs.txt"}, context.temp_allocator)
}

profile_load :: proc(app: ^App) {
	c, h, _ := profile_paths(app)
	if !app.cfg.persist_profile { return }
	cookies.load(&app.profile.jar, c)
	fetch.hsts_load(&app.profile.hsts, h, fetch.now_ms())
}

profile_save :: proc(app: ^App, force := false) {
	c, h, pf := profile_paths(app)
	if app.prefs.dirty || force { config.save_user(&app.prefs, pf) }
	session_save(app)   // session.odin (when it changed)
	if !app.cfg.persist_profile { return }
	if force || app.profile.jar.dirty { cookies.save(&app.profile.jar, c) }
	if force || app.profile.hsts.dirty { fetch.hsts_save(&app.profile.hsts, h, fetch.now_ms()) }
}

autosave :: proc(data: rawptr) { profile_save((^App)(data)) }

// (Re)arms the autosave timer from the current preference.
arm_autosave :: proc(app: ^App) {
	if app.autosave_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, app.autosave_timer); app.autosave_timer = base.NIL_HANDLE }
	if app.cfg.autosave_ms > 0 {
		app.autosave_timer = host.set_timer(&app.loop, f64(app.cfg.autosave_ms), f64(app.cfg.autosave_ms), autosave, app)
	}
}

// Every setting struct is derived from the registry; when any preference changes they are all refreshed and handed to
// their subsystems. Preferences marked "restart" are read again at the next start (the subsystem keeps what it opened with).
apply_prefs :: proc(app: ^App) {
	ns := net.settings_from_prefs(&app.prefs)
	net.client_apply(&app.client, ns)
	net.settings_destroy(&ns)

	fetch.settings_destroy(&app.profile.settings)
	app.profile.settings = fetch.settings_from_prefs(&app.prefs)
	app.profile.jar.settings = cookies.settings_from_prefs(&app.prefs)
	http_cache_apply(app)

	page.settings_destroy(&app.page_settings)
	app.page_settings = page.settings_from_prefs(&app.prefs)
	app.page_settings.internal_address = is_builtin_href
	for tab in app.tabs { if tab.page != nil { page.configure_styles(tab.page) } }

	delete(app.cfg.homepage)
	delete(app.cfg.ui_theme)
	app.cfg = settings_from_prefs(&app.prefs)
	memory_trim_settings(&app.prefs)   // memory_trim.odin
	app.show_console = app.cfg.show_console
	downloads_apply(app)
	app.loop.timer_slice_ns = i64(app.cfg.timer_slice_ms * 1e6)
	arm_autosave(app)
	app.frames_requested = max(app.frames_requested, 3)
}

on_pref_change :: proc(user: rawptr, name: string, p: ^config.Prefs) {
	if shell_defer({kind = .Prefs}) { return }   // (shell_frames.odin: pages' settings are not replaced under a running page)
	apply_prefs((^App)(user))
}
////////////////////////////////
// Loop

// The chrome's palette (browser.ui.theme) applied, and the base style of its boxes: every frame, full or chrome only.
chrome_frame_style :: proc(app: ^App) -> ui.Style {
	pal, pal_ok := ui.palette_named(app.cfg.ui_theme)   // browser.ui.theme
	if !pal_ok { pal = ui.PALETTE_GRAPHITE }
	ui.apply_palette(&app.theme, pal, render.blend_space(&app.r))
	platform.set_dark_title(app.win, pal.dark)
	// the system's frame line is half transparent along the top of an integrated title bar: the palette's, opaque
	platform.set_border_color(app.win, platform.is_integrated_title(app.win) ? Maybe(u32)(pal.border >> 8) : nil)
	return ui.Style{
		pref = {.X = ui.text_size(), .Y = ui.px(36)},
		font = app.ui_font, font_size = app.cfg.ui_font_size, text_pad = 7,
		cursor = .Arrow,
	}
}

frame :: proc(app: ^App, idled := false) {
	prof_frame_begin()
	prof_begin(.Wait)
	pacer_update(app)
	pacer_wait(app, idled)   // pacing.odin: the frame's time slot, then the swap chain (input is taken meanwhile)
	prof_end(.Wait)
	prof_begin(.Events)
	events := platform.poll_events(app.win, false)
	// back from another window (the Windows settings, say): the desktop integration may have changed there
	for e in events { if e.kind == .Activate { desktop_note_activate() } }
	remote_record_events(app, events)   // remote_extras.odin: a recording of the input, when one runs
	events = shell_frame_begin(app, events)   // shell_frames.odin: input held back by chrome frames first; the page phase
	pacer_begin_frame(app, events)
	if len(events) > 0 { app.frames_requested = max(app.frames_requested, 4) }
	prof_end(.Events)

	// network completions, timers and posted tasks run here, on the UI thread
	prof_begin(.Loop)
	ran := host.run_ready(&app.loop)
	ran -= host.quiet_take(&app.loop)   // (a media player's notices draw nothing: its pictures come on their own timer)
	if ran > 0 { app.frames_requested = max(app.frames_requested, 2) }
	images_shell_frame(app)
	events = shell_after_loop(app, events)   // (chrome frames made under the loop's scripts took the chrome's input)
	prof_end(.Loop)
	// a wake that brought nothing (a timer of the system for the window, a message of no consequence): no frame. (It
	// was one, and the status bar counted it, and armed its settle wake again: two frames every half second, forever.)
	// (a timed wake of the toolkit's, a caret blink or a tooltip delay, always draws)
	if idled && len(events) == 0 && ran == 0 && app.frames_requested == 0 && !ui.needs_frame(&app.ui_state) && ui.wake_ms(&app.ui_state) == 0 && !app.win.paint_requested {
		shell_page_phase_end(app, nil)
		free_all(context.temp_allocator)
		return
	}
	memory_trim_active()   // memory_trim.odin
	prof_begin(.Input)
	page_cursor_events(app, events)   // page_cursor.odin: a press on the page keeps its cursor
	route_page_input(app, events)
	events = forms_unconsumed_events(events)   // keys the page used do not reach the chrome
	events = history_tree_events(app, events)   // the wheel and zoom keys of about:history's tree (history_tree.odin)
	events = devtools_events(app, events)       // Ctrl+wheel and Ctrl +, -, 0 over the developer tools: their text size (devtools.odin)
	forms_shell_frame(app)
	selection_shell_frame(app)
	events = shell_after_input(app, events)   // (what is left is the chrome's: chrome frames from here on build with it)
	prof_end(.Input)

	fullscreen_shell_settle(app)   // the events of a change of full screen, before the frame's resize event (fullscreen_shell.odin)
	// page visibility, then the animation frame callbacks of the page about to be painted
	shown := app.win.size.x > 0 && app.win.size.y > 0
	for tab, i in app.tabs { if tab.page != nil { page.set_page_visible(tab.page, shown && i == app.current && tab.kind == .Web) } }
	// smooth scrolling moves the scrollers first: the scroll events of this frame (run_animation_frames) see where they
	// are painted
	if smooth_tick(app, current_tab(app)) { app.frames_requested = max(app.frames_requested, 2) }   // smooth_scroll.odin
	// the frame's time (pacing.odin: its vblank) is the animation frame callbacks' timestamp and the CSS clock
	if t := current_tab(app); t != nil && t.page != nil && page.page_visible(t.page) {
		prof_begin(.Animation)
		page.run_animation_frames(t.page, pacer.frame_ms)
		prof_end(.Animation)
		// (the loop counts this frame off after it: 2 = this one and the next)
		if page.wants_animation_frame(t.page) { app.frames_requested = max(app.frames_requested, 2) }
		if frames_tick(app, t, pacer.frame_ms) { app.frames_requested = max(app.frames_requested, 2) }   // (frames_shell.odin)
	}
	fullscreen_shell_frame(app)   // a page's full screen ends with its tab being shown (fullscreen_shell.odin)
	page_update(app)   // page_frame.odin: styles and layout, in the page phase (chrome frames can be made meanwhile)
	// the page's pixels are worth keeping for chrome frames (shell_capture) only when it may run a long pass this frame
	page_snapshot_wanted = ran > 0
	if t := current_tab(app); t != nil && t.page != nil {
		if t.layout.mutations != t.page.doc.mutations || page.wants_animation_frame(t.page) || page.animations_active(t.page) {
			page_snapshot_wanted = true
		}
	}
	events = shell_page_phase_end(app, events)   // shell_frames.odin: the scroll and the actions of chrome frames, before the build
	shell_snapshots_frame(app)

	render.resize(&app.r, app.win.size)
	size := draw.Vec2{f32(app.win.size.x), f32(app.win.size.y)}
	dt := pacer.dt

	base_style := chrome_frame_style(app)
	window_chrome_frame(app)   // window_chrome.odin
	prof_begin(.Build_UI)
	ui.begin_build(&app.ui_state, {
		window_size = size, events = events, dt = dt, animations = os_animations_enabled(app),
		dpi_scale = ui_scale_of(app), base = base_style, clipboard_get = clip_get, clipboard_set = clip_set,
		disable_zoom = true,   // Ctrl+Plus / Minus / 0 and Ctrl+wheel zoom the page (zoom.odin), not the chrome
		window = app.win, frame_ms = pacer.frame_ms,   // the integrated title bar's regions; scroll animations on the vblank clock
	})
	build_ui(app)
	instance_frame(app)   // instance_shell.odin: the notice of a first Wren that did not answer
	remote_notice(app)   // remote_shell.odin: the notice of a remote channel that did not start
	ui.end_build()
	prof_end(.Build_UI)
	window_cursor_apply(app)   // page_cursor.odin: the page's cursor over the page, else the chrome's
	if ui.needs_frame(&app.ui_state) { app.frames_requested = max(app.frames_requested, 2) }
	if t := current_tab(app); t != nil && t.page != nil && t.layout.mutations != t.page.doc.mutations { app.frames_requested = max(app.frames_requested, 2) }
	if t := current_tab(app); t != nil && t.page != nil && page.animations_active(t.page) { app.frames_requested = max(app.frames_requested, 2) }   // CSS animations: later changes wake the loop by timer

	shell_before_draw(app)   // (a chrome frame used the screen's slot)
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, {0, 0, 0, 1})
	prof_begin(.UI_Draw)
	ui.draw_tree(&app.ui_state, &app.dc)
	prof_end(.UI_Draw)
	prof_begin(.Submit)
	draw.end_frame(&app.dc)   // GPU time: the renderer's timestamp queries around its submit (hud.odin, prof.odin)
	prof_end(.Submit)
	prof_begin(.Present)
	render.frame_end(&app.r, !(pacer.resizing || pacer.input_frame))   // a resize step or an input frame is shown at once
	app.presented = true
	prof_end(.Present)
	pacer_end_frame(app)
	{
		items, nodes := 0, 0
		if t := current_tab(app); t != nil && t.page != nil { items, nodes = len(t.layout.items), t.page.doc.nodes.count }
		prof_frame_end(app, items, nodes)
	}
	free_all(context.temp_allocator)
}

wake_window :: proc(user: rawptr) { platform.wake((^platform.Window)(user)) }

// A switch without a value (`--setup`): taken out of the arguments; found when it was there.
extract_switch :: proc(args: []string, flag: string) -> (found: bool, rest: [dynamic]string) {
	rest = make([dynamic]string, context.temp_allocator)
	for a in args { if a == flag { found = true } else { append(&rest, a) } }
	return
}

// `--profile DIR` and `--policy FILE` are the shell's own flags; every other `--pref name=value` is a preference.
extract_flag :: proc(args: []string, flag: string) -> (value: string, rest: [dynamic]string) {
	rest = make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(args); i += 1 {
		if args[i] == flag && i + 1 < len(args) { value = args[i + 1]; i += 1; continue }
		append(&rest, args[i])
	}
	return
}

main :: proc() {
	context = base.process_context()   // the tracker of the check build (memcheck.odin)
	prof_mark(.Main)
	app := new(App)
	the_app = app

	// --- configuration: defaults < profile file < command line < policy file ---
	args := desktop.command_line_args(base.permanent_allocator())   // (UTF-8 from the UTF-16 command line: os.args is the C runtime's ANSI)
	// `wren ctl ...`: the remote control client, before anything else is set up (no profile opened, no window, no GPU, no
	// script engine): only as the first argument (a file or host named ctl is written ./ctl)
	if len(args) > 0 && args[0] == "ctl" { os.exit(ctl_main(args[1:])) }
	profile_override, a1 := extract_flag(args, "--profile")
	policy_file, a2 := extract_flag(a1[:], "--policy")
	cli_mode, a3, cli_bad := desktop.parse_cli(a2[:])   // --desktop-integration=install|remove|status (desktop_shell.odin)
	setup_requested, a4 := extract_switch(a3[:], "--setup")   // opens the Setup dialog (setup.odin)
	new_window, a5 := extract_switch(a4[:], "--new-window")   // a window of its own, not a tab of the Wren that runs (instance_shell.odin)
	no_single, a6 := extract_switch(a5[:], "--no-single-instance")
	remote_asked, remote_name, a7 := extract_remote(a6[:])   // --remote[=name]: the remote control channel (remote_shell.odin)
	headless_mode, a8 := extract_switch(a7[:], "--headless")   // the window is never shown (it renders all the same: remote captures read the frame)
	app.prefs = config.prefs_make()
	rest, arg_errors := config.apply_args(&app.prefs, a8[:], context.temp_allocator)   // (read before the first frame)
	cfg_dir := platform.config_dir(context.temp_allocator)
	portable_dir := profile_override == "" ? portable_profile_dir() : ""   // a copy with wren.portable beside it keeps its profile beside it (setup.odin)
	app.portable = portable_dir != ""
	app.profile_dir = strings.clone(profile_override != "" ? profile_override : (app.portable ? portable_dir : (cfg_dir == "" ? "build/profile" : strings.concatenate({cfg_dir, "/", APP_NAME}, context.temp_allocator))))
	_ = os.make_directory_all(app.profile_dir)
	net.user_agent_product = "Wren/" + APP_VERSION
	crashtrace.set_report_dir(strings.concatenate({app.profile_dir, "/crashes"}, context.temp_allocator), fmt.tprintf("%s %s (%s %s)", APP_NAME, APP_VERSION, app_commit(), APP_COMMIT_DATE))
	_, _, prefs_file := profile_paths(app)
	config.load_file(&app.prefs, prefs_file, .User)
	if policy_file == "" { policy_file = default_policy_file(desktop.executable_path(context.temp_allocator)) }   // beside the program, not in the working directory (policy_file.odin)
	if policy_file != "" { config.load_file(&app.prefs, policy_file, .Policy) }
	register_all_prefs(&app.prefs)
	app.cfg = settings_from_prefs(&app.prefs)
	memory_trim_settings(&app.prefs)   // memory_trim.odin
	prof_mark(.Prefs)
	if cli_bad != "" { desktop.console_write(fmt.tprintf("--desktop-integration: unknown mode %q (install, remove or status)\n", cli_bad)); os.exit(2) }
	// `ctl` as an address is nearly always `wren ctl ...` meant for the remote control client that did not run as such (an option before it:
	// `ctl` is only the first argument; or a wren.exe from before the client existed): it would open https://ctl, and in the user's Wren, not here
	if len(rest) > 0 && rest[0] == "ctl" {
		desktop.console_write("`ctl` is a command only as the first argument: wren ctl <command> [options]. To open a file or host named ctl, write ./ctl\n")
		os.exit(2)
	}
	if cli_mode != .None { os.exit(desktop_cli(app, cli_mode)) }   // no window: a script's call
	instance_early(app, rest[:], setup_requested, new_window || no_single || remote_asked || headless_mode)   // (a driven window is its own: it never hands its addresses to the user's Wren)   // instance_shell.odin: a second start hands over to the first and ends here
	desktop_early_init()   // the windows' AppUserModelID, before the first one exists
	recovery_start(app)   // crash_recovery.odin: how the last run ended, and this run's marker

	// Start-up order: the renderer's start-up (device, shader compilation) is by far the longest step and needs only the
	// window. Before it: fonts on a thread of their own (fonts_preload_start), then the network, the page machinery and
	// the first navigation, whose loads run on their own threads while the renderer starts.
	font.init(&app.fonts, font_settings_from_prefs(&app.prefs))
	preload := fonts_preload_start(app)   // the font state is the preload thread's until fonts_preload_finish
	app.win = platform.open_window(APP_NAME, {1280, 800}, transparent = config.bool_of(&app.prefs, "browser.window.fixed_surface"), integrated_title = config.bool_of(&app.prefs, "browser.window.integrated_titlebar"))
	prof_mark(.Window)

	host.loop_init(&app.loop, wake_window, app.win)
	instance_begin(app)   // instance_shell.odin: the window that takes the second starts' addresses
	crashtrace.begin_session()   // (a session that ended without a report: crashes\unclean exit <date>.txt at this start)
	app.loop.timer_slice_ns = i64(app.cfg.timer_slice_ms * 1e6)
	appearance_init(app)   // before any settings are derived: `system` colors, auto color scheme
	ns := net.settings_from_prefs(&app.prefs)
	if !net.client_init(&app.client, &app.loop, ns) { fmt.eprintln("network init failed"); return }
	net.settings_destroy(&ns)
	host.blocking_init(&app.blocking, &app.loop, app.cfg.blocking_threads)
	app.profile = fetch.profile_make(fetch.settings_from_prefs(&app.prefs), cookies.settings_from_prefs(&app.prefs))
	http_cache_start(app)   // http_cache_ui.odin: the profile's HTTP cache (its index loads on a thread meanwhile)
	fetch.loader_init(&app.loader, &app.loop, &app.client, &app.blocking, &app.profile)
	blocker_start(app)   // blocker_shell.odin: the content blocker listens to the loader from here on
	page.storage_manager_init(&app.storage, &app.loop, &app.blocking, app.cfg.persist_profile ? app.profile_dir : "")
	app.page_settings = page.settings_from_prefs(&app.prefs)
	app.page_settings.internal_address = is_builtin_href
	{
		rs := wasm.runtime_settings_from_prefs(&app.prefs, app.cfg.persist_profile ? app.profile_dir : "")   // nothing on disk without a kept profile
		wasm.configure(rs)
		wasm.runtime_settings_destroy(&rs)
	}
	if !page.register_imports() { fmt.eprintln("wasm runtime init failed"); return }
	page.js_startup(&app.prefs, app.cfg.persist_profile ? app.profile_dir : "")
	app.process = base.scope_make("process")
	app.config_view.rows = make(map[string]^Row_State)
	history_settings_init(app)   // history_settings.odin: before the first tab
	global_history_init(app)
	app.show_console = app.cfg.show_console

	profile_load(app)
	config.watch(&app.prefs, "", on_pref_change, app)
	arm_autosave(app)

	// the first tab: the address given on the command line, else the homepage
	prof_mark(.Shell)
	address := len(rest) > 0 ? command_line_address(rest[0]) : ""   // (a relative path of a file or folder: local_paths.odin)
	prof_mark(.Navigation)
	if !recovery_open(app, rest[:]) {   // crash_recovery.odin: the tabs of a session that ended abnormally (the command line's addresses follow them)
		if !(len(rest) == 0 && session_restore(app)) { tab_open(app, address, origin = .User) }   // session.odin
		if len(rest) > 1 {   // (an address each: the first is the first tab, the others follow it, as a second start's would)
			for a in rest[1:] { tab_open(app, command_line_address(a), origin = .User) }
			app.current = len(app.tabs) - len(rest)
		}
	}
	for e in arg_errors { tab_log(current_tab(app), .Warn, e) }
	remote_start(app, remote_asked, remote_name)   // remote_shell.odin: the pipe, when asked for   // (tab_log keeps its copy)
	desktop_watch_begin(app, profile_override != "")   // desktop_shell.odin: the system tells when the integration changes (the box in about:config and the Setup dialog follow it)
	setup_startup(app, profile_override != "", setup_requested)   // setup.odin: a copy that is not the installed one is offered Setup; --setup opens it
	update_startup(app, profile_override != "")   // update_check.odin: the daily check, when it is on and due

	app.r.swap_buffers = int(config.int_of(&app.prefs, "browser.frame.swap_buffers"))   // pacing.odin
	fixed_surface := config.bool_of(&app.prefs, "browser.window.fixed_surface")
	if !render.init(&app.r, app.win.hwnd, app.win.size, transparent = fixed_surface) { fonts_preload_finish(app, preload); fmt.eprintln("renderer init failed"); return }
	if fixed_size := fixed_surface_size(app, app.win.hwnd); fixed_size.x > 0 {
		// one surface, the monitor's size: the window shows its top-left part, 1:1, and keeps it while it is resized
		// (browser.window.fixed_surface; render.set_fixed_surface; the developer tools' window does the same)
		render.set_fixed_surface(&app.r, fixed_size)
	}
	render.set_teardown_wait(&app.r, int(config.int_of(&app.prefs, "browser.shell.shutdown_surface_wait_ms")))   // (see the preference: the compositor may be slow to let go of the surface)
	prof_mark(.Renderer)
	if !fonts_preload_finish(app, preload) { fmt.eprintln("cannot load the UI or icon font"); return }
	prof_mark(.UI_Fonts)
	draw.init(&app.dc, &app.r, &app.fonts)
	ui.init(&app.ui_state, &app.fonts, &app.theme)
	app.ui_state.icon_font = app.icons
	page_render_init(app)
	first_paint_init(app)
	interaction_init(app)
	fonts_preload_adopt(&page_render.fonts, preload)
	images_shell_init(app)
	canvas_shell_init(app)
	images_set_texture_api(renderer_texture_api(app))
	canvas_gpu_init(app)
	set_content_painter(forms_content_painter, app)
	page_render.bare = forms_bare_control
	frames_shell_init(app)   // frames_shell.odin: nested documents laid out, painted and given input

	prof_init(app)
	pacer_init(app)
	shell_frames_init(app)   // shell_frames.odin: chrome frames while a page holds the thread
	smooth_init(app)
	page_cursor_init(app)
	window_chrome_init(app)
	chrome_style_init(app)   // chrome_style.odin
	favicons_init(app)   // favicon.odin
	downloads_init(app)   // download.odin
	webauthn_shell_init(app)   // webauthn_shell.odin
	fullscreen_shell_init(app)   // fullscreen_shell.odin: the Fullscreen API
	clipboard_js_init(app)   // clipboard_win.odin: navigator.clipboard
	drop_files_init(app)   // local_paths.odin
	app_commands_init(app)   // app_commands.odin: the mouse's back / forward buttons
	hud_init(app)
	devtools_init(app)   // devtools.odin
	urlbar_init(app)   // urlbar.odin: the address bar's suggestions
	app.last_tick = time.tick_now()
	app.frames_requested = 4
	app.win.user = app
	app.win.on_frame = proc(user: rawptr) { window_frame((^App)(user)) }   // (shell_frames.odin: a chrome frame when the page holds the thread)
	if !headless_mode { platform.show_window(app.win) }
	prof_mark(.Loop)

	for !platform.is_closed(app.win) {
		idled := false
		if app.frames_requested == 0 && !ui.needs_frame(&app.ui_state) && !platform.take_paint_request(app.win) && !devtools_window_busy() {
			timeout := devtools_window_timeout(ui.wake_ms(&app.ui_state))
			if t := host.next_timeout_ms(&app.loop); t >= 0 && (timeout <= 0 || t < timeout) { timeout = max(t, 1) }
			prof_begin(.Idle)
			platform.wait_event(app.win, memcheck_wake(memory_trim_wake(timeout)))
			prof_end(.Idle)
			idled = true
		}
		frame(app, idled)
		devtools_window_tick(app)   // devtools_window.odin: the panel in a window of its own
		memcheck_drive(app)   // memcheck.odin: the check build's script, if any
		memory_trim_tick(app)   // memory_trim.odin
		if app.frames_requested > 0 { app.frames_requested -= 1 }
		remote_after_frame(app)   // remote_shell.odin: the waits of remote commands
	}

	win.ShowWindow(app.win.hwnd, win.SW_HIDE)   // closed means gone from the screen at once, whatever the teardown below takes
	host.shutdown_begin(strings.concatenate({app.profile_dir, "/shutdown.log"}, context.temp_allocator), int(config.int_of(&app.prefs, "browser.shell.shutdown_warn_ms")), int(config.int_of(&app.prefs, "browser.shell.shutdown_force_ms")))   // shutdown.odin (host): names what the teardown waits for
	host.shutdown_step("remote_stop")
	remote_stop(app)   // remote_shell.odin: the pipe and its clients
	if remote_fast_exit { recovery_end(app); crashtrace.end_session(); os.exit(remote_exit_code) }   // Browser.close {fast}: a throwaway profile; the teardown below is a quarter of a second
	host.shutdown_step("instance_end")
	instance_end()   // instance_shell.odin: later starts are told to wait, then the profile is free
	host.shutdown_step("prof_report")
	prof_report()
	wasm.host_profile_write()   // (WREN_HOST_PROFILE: before the pages are freed; the runtime's end writes it again)
	host.shutdown_step("desktop_shell_shutdown")
	desktop_shell_shutdown(app)   // desktop_shell.odin: a job still out finishes
	host.shutdown_step("shell_frames_destroy")
	shell_frames_destroy(app)   // (no chrome frame from here on: the pages' last scripts run unpreempted)
	fullscreen_shell_destroy(app)   // (the pages closing below do not restore a window that is going away)
	host.shutdown_step("session capture")
	for t in app.tabs { entry_capture_current(app, t); cache_prof_leave(t) }   // the session keeps where each tab was
	host.shutdown_step("profile_save")
	profile_save(app, force = true)
	host.shutdown_step("recovery_end")
	recovery_end(app)   // crash_recovery.odin: a normal end removes the marker and the snapshot
	host.shutdown_step("bfcache_shutdown")
	bfcache_shutdown(app)
	host.shutdown_step("tab_free")
	for t in app.tabs { tab_free(app, t) }   // (their session storage goes with the storage manager below)
	host.shutdown_step("clear")
	clear(&app.tabs)
	host.shutdown_step("urlbar_destroy")
	urlbar_destroy(app)   // urlbar.odin
	host.shutdown_step("global_history_shutdown")
	global_history_shutdown(app)
	host.shutdown_step("history_ui_destroy")
	history_ui_destroy()
	host.shutdown_step("history_settings_shutdown")
	history_settings_shutdown(app)
	host.shutdown_step("base.scope_close")
	base.scope_close(app.process)   // every tab, page and request
	host.shutdown_step("frames_shell_destroy")
	frames_shell_destroy()   // (their views went with their documents)
	host.shutdown_step("webauthn_shell_destroy")
	clipboard_js_destroy()
	webauthn_shell_destroy(app)   // passkey requests: their threads joined
	host.shutdown_step("favicons_destroy")
	favicons_destroy(app)
	host.shutdown_step("images_shell_destroy")
	images_shell_destroy(app)
	canvas_shell_destroy()
	host.shutdown_step("page.storage_manager_destroy")
	page.storage_manager_destroy(&app.storage)   // writes what is not saved yet
	host.shutdown_step("page.shutdown_threads")
	page.shutdown_threads()
	host.shutdown_step("page_thread_destroy")
	page_thread_destroy()   // page_thread.odin
	host.shutdown_step("lay.shutdown_threads")
	lay.shutdown_threads()
	host.shutdown_step("page.images_shutdown")
	page.images_shutdown()   // the image cache and its decoding threads
	host.shutdown_step("page.fonts_shutdown")
	page.fonts_shutdown()    // the decoded web fonts kept for every page
	host.shutdown_step("blocker_stop")
	blocker_stop(app)   // after the pages are gone, before the loader
	host.shutdown_step("fetch.loader_destroy")
	fetch.loader_destroy(&app.loader)
	host.shutdown_step("page.timeline_shutdown")
	page.timeline_shutdown()   // the requests the performance timeline still describes (no more events once the loader is gone)
	host.shutdown_step("http_cache_stop")
	http_cache_stop(app)   // writes what is pending and the index
	host.shutdown_step("host.blocking_destroy")
	host.blocking_destroy(&app.blocking)
	host.shutdown_step("downloads_shutdown")
	downloads_shutdown()   // (no write or dialog of theirs is running any more)
	host.shutdown_step("net.client_destroy")
	net.client_destroy(&app.client)
	host.shutdown_step("fetch.profile_destroy")
	fetch.profile_destroy(&app.profile)
	host.shutdown_step("appearance_destroy")
	appearance_destroy()
	host.shutdown_step("hud_destroy")
	devtools_destroy(app)
	hud_destroy(app)
	host.shutdown_step("smooth_shutdown")
	smooth_shutdown(app)
	host.shutdown_step("page_cursor_shutdown")
	page_cursor_shutdown(app)
	host.shutdown_step("drop_files_destroy")
	drop_files_destroy(app)
	host.shutdown_step("app_commands_destroy")
	app_commands_destroy()
	host.shutdown_step("window_chrome_destroy")
	window_chrome_destroy(app)
	chrome_style_destroy(app)
	host.shutdown_step("pacer_destroy")
	pacer_destroy(app)
	host.shutdown_step("font.set_color_ready_callback")
	font.set_color_ready_callback(&app.fonts, nil, nil)   // the color glyph thread no longer posts to the loop
	host.shutdown_step("page.compile_shutdown")
	page.compile_shutdown()   // the script compile threads post to the loop: stopped before it goes
	host.shutdown_step("host.loop_destroy")
	host.loop_destroy(&app.loop)
	host.shutdown_step("page.js_shutdown")
	page.js_shutdown()
	host.shutdown_step("wasm.runtime_destroy")
	wasm.runtime_destroy()
	host.shutdown_step("measure_destroy")
	measure_destroy(&app.measure)
	host.shutdown_step("forms_shell_destroy")
	forms_shell_destroy()
	host.shutdown_step("page_render_destroy")
	page_render_destroy()
	host.shutdown_step("config_view_destroy")
	config_view_destroy(&app.config_view)
	host.shutdown_step("interaction_destroy")
	interaction_destroy(app)
	host.shutdown_step("ui.field_destroy")
	ui.field_destroy(&app.address)
	host.shutdown_step("console_eval_destroy")
	console_eval_destroy()
	host.shutdown_step("session_destroy")
	session_destroy()
	recovery_destroy()
	host.shutdown_step("palette_destroy")
	palette_destroy()   // palette.odin (and the command registry)
	host.shutdown_step("ui.destroy")
	ui.destroy(&app.ui_state)
	host.shutdown_step("ui.theme_destroy")
	ui.theme_destroy(&app.theme)
	host.shutdown_step("draw.destroy")
	draw.destroy(&app.dc)
	host.shutdown_step("render.destroy")
	render.destroy(&app.r)
	host.shutdown_step("font.destroy")
	font.destroy(&app.fonts)
	host.shutdown_step("platform.destroy_window")
	platform.destroy_window(app.win)
	page.settings_destroy(&app.page_settings)
	delete(app.cfg.homepage)
	delete(app.cfg.ui_theme)
	config.prefs_destroy(&app.prefs)
	profile_dir := strings.clone(app.profile_dir, context.temp_allocator)
	delete(app.profile_dir)
	delete(app.tabs)
	free(app)
	the_app = nil
	host.shutdown_step("instance_release")
	instance_release()   // instance_shell.odin: the profile is written and free: a start that waited becomes the owner (before the watchdog's stop, which can wait for its next tick)
	host.shutdown_end()
	crashtrace.end_session()   // a clean end (a watchdog's exit or a kill leaves the file: the next start reports it)
	memcheck_exit(profile_dir)   // memcheck.odin: the leak report of the check build
	if remote_exit_code != 0 { os.exit(remote_exit_code) }   // Browser.close {exitCode}
}