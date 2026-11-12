// Wasm-first browser shell. The chrome (tabs, address bar, developer tools) is built with gui_toolkit's `ui`; the page is a
// custom-draw box painted from the DOM. Everything a tab starts lives in the tab's scope: closing a tab is one call.
//
// Every load goes through the policy layer (package fetch): the main document, its Wasm modules (in document order), and
// whatever the modules fetch afterwards. The profile (cookies, HSTS) is loaded at start-up and saved as it changes.
package browser

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import prefs_page "toolkit:prefs_page"
import "wb:canvas2d"
import "wb:base"
import "wb:config"
import "wb:cookies"
import desktop "toolkit:desktop"
import process "toolkit:process"
import wren_desktop "wb:desktop"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:html"
import "wb:http"
import "wb:net"
import "wb:page"
import "wb:url"
import "wb:wasm"

// How much of a text resource a tab shows in its <pre>.
SHOW_TEXT_MAX_BYTES :: 1 << 20
import "wb:crashtrace"   // a crash leaves its symbolized stack and a minidump in <profile>\crashes

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
	blank:      ^page.Page,              // the window's initial about:blank, until the response keeps its Window or closes it
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
	pushed:     bool,                    // the navigation added a history entry (it goes if the navigation ends with no document: nav_cancel)
	left_entry: u64,                     // a traversal: the entry it left (... the tab goes back there)
	action:     Doc_Action,              // what the answer is shown as (download.odin doc_action)
	cache:      fetch.Cache_Mode,        // the document's cache mode; Reload: its subresources too (http_cache_ui.odin)
	from_cache: fetch.Cache_Outcome,     // where the document came from (the status bar says so)
	started_ns: i64,                     // the loop clock when the navigation began (Navigation Timing)
	response_ns: i64,                    // ... and when the head of the answer arrived
}

Load_Failure :: enum u8 { None, Other, Tls }

Tab_Kind :: enum u8 { Web, Config, Settings, History, Blocker, Downloads, Bookmarks }   // Bookmarks: about:bookmarks (bookmarks_ui.odin)   // Settings: about:settings (settings_page.odin)   // Blocker: about:blocker (blocker_dashboard.odin)   // History: about:history (history_ui.odin)   // Downloads: about:downloads (downloads_ui.odin)

Tab :: struct {
	id:       u64,           // unique for the process: keys its boxes of the tab strip (tab_strip.odin)
	lazy:     bool,          // restored, not loaded yet: `url` loads when the tab is first shown (session.odin)
	art_empty: bool,         // it shows the art new tab with no painting yet: the first one to be ready replaces it (newtab_art_page.odin)
	icon:     Tab_Icon,      // its document's icon and title (favicon.odin)
	kind:     Tab_Kind,      // a web page, or the about:config view
	scope:    ^base.Scope,   // lives as long as the tab
	nav:      ^base.Scope,   // lives as long as the current navigation: the page and everything it started
	top:      ^Navigable,    // its window for scripts, across its documents (window.open, opener, name; page/auxiliary.odin)
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
	scroll_dpi: f32,            // the window scale `scroll` was in (zoom.odin tab_scale_follow; 0: not known yet)
	layout_ms: f64,             // page_thread.odin: how long its last layout pass took (whether the next goes to the page thread)
	layout_ms_known: bool,
	full_layout_ms: f64,        // how long its last whole layout pass took (what a chrome frame would pay to lay out animated values: shell_shown.odin)
	shown:    Shown_Layout,      // its layout for what a chrome frame shows of animated layout values (shell_shown.odin)
	scroll_target: base.Handle, // what keyboard scrolling moves: the last element pressed in the page (its scroll container)
	fragment_done: bool,         // the document scrolled to its fragment (page.scroll_to_fragment), or its entry is being restored
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
	view:     ^Page_View,        // non-nil: the tab of a page view (a frame's document, an extension's popup), not a window's tab (page_view.odin)
	keyboard_frame: Frame_Document,   // keyboard.odin: the frame document that had the keyboard when another tab took the window
	pinned:   bool,              // tab_groups.odin: at the start of the window's tabs, its icon alone
	group:    u64,               // tab_groups.odin: the id of its group in its window (0: none)
	parent:   u64,               // tab_tree.odin: the id of the tab that opened it in the window's tree (0: a root)
	fold:     bool,              // tab_tree.odin: its children are folded away in the sidebar
	muted:    bool,              // tab_sound.odin: its pages make no sound (they are not told)
	sound:    Tab_Sound,         // tab_sound.odin: whether it plays sound, as the last frame saw
}

Session_History :: page.Session_History   // (a field named `page` hides the package in the struct above)
Navigable :: page.Navigable

// The browser has several windows (windows.odin). What is a window's is read in the window itself, the active one being
// active_window(app): .win, .ui (its toolkit state), .tabs, .current, .address, .page_rect, .frames_requested
// (request_frames), .presented; window_own(app) for the chrome's state.
App :: struct {
	rates:    Loop_Rates,   // loop_rates.odin: turns, sleeps, frames and why
	r:        render.Renderer,
	fonts:    font.State,
	fonts_color: ^host.Thread,   // what color glyphs are drawn with, made meanwhile (fonts.odin fonts_color_start)
	dc:       draw.Context,
	theme:    ui.Theme,
	theme_shown: ui.Theme_Shown,   // what ui.theme_show applied last (chrome_frame_style)
	chrome_pal:  ui.Palette,       // the palette of the theme shown (chrome_palette), kept from theme_show to theme_show
	ui_font:  font.Font_Id,
	icons:    font.Font_Id,
	lucide:   font.Font_Id,   // the Lucide icons (toolkit:lucide): about:settings's pages

	loop:     host.Loop,
	client:   net.Client,
	blocking: host.Blocking_Pool,
	writer:   host.File_Writer,   // every file of the profile, the shell's and the pages' (profile_writes.odin)
	dialogs:  host.Dialogs,       // the system's modal dialogs, a thread each (a person answers them: no work of the blocking pool)
	prefs:    config.Prefs,   // every tunable of the browser (about:config)
	cfg:      Settings,       // the shell's own, derived from prefs
	page_settings: page.Settings,
	config_view:   Config_View,
	settings_view: prefs_page.Page,   // about:settings (settings_page.odin)
	autosave_timer: base.Handle,
	profile:  fetch.Profile,
	loader:   fetch.Loader,
	storage:  page.Storage_Manager,   // localStorage / sessionStorage of the profile
	profile_dir: string,
	portable: bool,           // wren.portable beside the executable: the profile is <executable folder>\data (setup.odin)
	process:  ^base.Scope,

	measure:  Measure,        // text measurement cache of the layout
	pacing:   Pacing,         // what the windows' pacers share: the preferences, the timer (pacing.odin)
	show_console:  bool,

	last_tick:        time.Tick,

	windows:  [dynamic]^Browser_Window,   // windows.odin
	tab_ids:  map[u64]^Tab,               // windows.odin tab_find: every tab from tab_adopt to tab_free, whatever its window (nil while there is none)
	made:     App_Stages,                 // app_make.odin: the stages of the App that are made (app_free ends them)
	active:   ^Browser_Window,            // the one the frame is for; nil: none (active_window is then App.bare)
	front:    ^Browser_Window,            // the one commands, remote calls and the tasks of the loop act on (the last used)
	bare:     Browser_Window,             // active_window of an App with no window (the tests'), or between two
	pass_first: bool,                     // the next frame of this pass of the loop is the first: it runs the tasks of the loop
	tasks_running: bool,                  // frame_tasks runs the loop's callbacks now: request_frames asks for the window of the page they work for
	task_own:   int,                      // ... the frames they asked for the active window as their page's own (not spilled to the others)
	layout_verify_seen: int,              // js_layout_shell.odin layout_trace: the incremental layout's verify failures reported
	rendering:  ^Tab,                     // the tab whose rendering update the frame runs (its animation frame callbacks, then its page phase): what it lays out, this frame paints
	headless:   bool,                     // no window at all (`--headless`)
	private:    bool,                     // a private Wren (--private): its profile is made for it and goes at its end (private_browsing.odin)
	hidden:     bool,                     // windows that are made and never shown (--hidden)
	frames_at_once: bool,                 // a program in this process drives the browser: a headless window's frames wait for nothing (control.odin)
	quitting:   bool,                     // the browser ends (a remote Browser.close): every window goes, none is closed on its own first

	// What the shell's subsystems keep for the App, the file that owns each named beside it (docs/architecture.md, Where state lives: what
	// is one App's is not a global, so that several Apps can live in one process)
	watches:       [Pref_Watch]int,          // the preference watches of the subsystems that follow their preferences
	cmds:          Command_Registry,         // commands.odin: the commands of the menu, the palette and the shortcuts
	ghist:         Global_History,           // global_history.odin: the profile's history
	bms:           Bookmarks,                // bookmarks.odin: the profile's bookmarks
	confirm:       Pending_Confirm,          // confirm_shell.odin: the question before an act not taken back
	sysicons:      System_Icons,             // system_icons.odin: the system's icons of files, as textures
	favs:          Favicons,                 // favicon.odin: the tabs' icons
	bf:            Bfcache,                  // bfcache.odin: the back/forward cache of the tabs
	dls:           Downloads,                // download.odin: the profile's downloads
	sengines:      Search_Engines,           // search_engines.odin: the profile's search engines
	hcfg:          History_Settings,         // history_settings.odin
	upd:           Update_State,             // update_check.odin: the daily check
	cpal:          Palette_State,            // palette.odin: the command palette
	stp:           Setup_State,              // setup.odin: the Setup dialog (toolkit:setup)
	wchrome:       Window_Chrome,            // window_chrome.odin: its preferences, the program's icon, the system menu asked for
	tsh:           Touch_Shell,              // touch_shell.odin: touch input and its preferences
	tab_drag:      Tab_Drag,                 // tab_drag.odin: the tab being dragged
	closed:        Closed_Tabs,              // closed_tabs.odin: what was closed, to reopen
	session_last:  string,                   // session.odin: the session written last (nothing is written when it did not change)
	rest_text:     string,                   // session.odin: a session whose windows from rest_from on are still to open
	rest_from:     int,
	rest_focus:    bool,                     // ... the last one comes to the front
	trim_state:    Trim_State,               // memory_trim.odin
	pass_order:    [dynamic]^Browser_Window, // windows.odin: the windows of a pass of the loop, in order
	pass_causes:   [dynamic]Frame_Causes,    // windows.odin: ... and why each draws
	wake_target:   rawptr,                   // windows.odin: the window the loop waits on (wake_window; read atomically, from any thread)
	print_last:    time.Tick,                // print.odin: the last window.print()
	render_settings: Render_Settings,        // render_settings.odin
	chrome_cfg:    Chrome_Style_Settings,    // chrome_style.odin
	ccfg:          Cursor_Settings,          // page_cursor.odin
	pcs:           Page_Cursor_State,        // page_cursor.odin: its preference watch and log
	autoscroll_cfg: Autoscroll_Settings_B,   // page_autoscroll.odin
	smooth_cfg:    Smooth_Settings,          // smooth_scroll.odin
	net_prefs:     Net_Prefs,                // devtools_net_model.odin
	vfast:         Video_Fast,               // video_fast_path.odin: what each video drew in the last page frame
	emoji_applied: string,                   // font_settings.odin: what the font state has: a path (heap), EMOJI_BUILTIN, or "" for none
	prefs_apply_counts: [Pref_Group]int,     // prefs_apply.odin: how many times each subsystem was configured again
	gpu_slow:      map[i32]Slow_Step,        // gpu_steps.odin: the slow GPU steps
	gpu_slow_frames: int,                    // gpu_steps.odin
	gpu_kept:      [dynamic][3]i32,          // gpu_steps.odin: per recorded frame: kept effect results reused, redrawn, kept anew
	net_owner:     map[u64]Net_Ref,          // devtools_net_model.odin: request id -> its tab and its entry there
	net_media:     Net_Media,                // devtools_net_media.odin: the media the Network tab plays
	dl_picking:    bool,                     // download.odin: the folder dialog of the downloads page is open
	drag_probe_moves: i32,                   // drag_probe.odin: the pointer moves of the frame whose events were just read
	inject_held:   platform.Mouse_Buttons,   // remote_methods.odin: the buttons a remote client holds
	native:        Native_Hooks,             // shell_native_*.odin: the system's windows the shell hooked (app commands, dropped files)
	pages:         page.Pages,               // what the App's pages share (page/pages.odin), bound to its loop's thread and its page thread
	// what the painting reads (preferences read once and on change, the frame's state)
	compositor_settings: Compositor_Settings,   // compositor.odin
	effects_settings: Effects_Settings,      // paint_effects.odin
	fx_settings:   Fx_Settings,              // effects_cache.odin
	plane_settings: Plane_Settings,          // paint_planes.odin
	plane_settle:  base.Handle,              // paint_planes.odin: the timer of the planes' settling
	gradient_dither: bool,                   // paint_backgrounds.odin: render.gradients.dither
	scheme_ui:     First_Paint_Settings,     // first_paint.odin
	ix:            Interaction_Settings,     // selection_shell.odin
	spaint:        Sel_Paint,                // selection_shell.odin: the painted selection
	cur_gap:       Cur_Gap,                  // chrome_style.odin: where the current tab of the window being drawn meets its toolbar
	phase_clock:   Phase_Clock,              // prof.odin: the phases of the frame being drawn
	gpu_steps_state: Gpu_Steps_State,        // gpu_steps.odin
	outline_cache: map[u64]^canvas2d.Path,   // canvas_shell.odin: the outlines of the canvases' text
	frame_views:   map[^page.Page]^Page_View,    // frames_shell.odin: the views of the frames (iframes) of the pages
	paint_stack:   [dynamic]^page.Page,      // frames_shell.odin: the documents being painted, innermost last
	os_anim:       Os_Anim,                  // os_settings.odin
	font_watch, text_watch: int,             // font_settings.odin: the preference watches
	look_watch:    Look_Watch,               // appearance_windows.odin: the system's colours, read and watched
	con_prefs:     Con_Prefs,                // devtools_console_log.odin
	tcfg:          Tree_Settings,            // history_tree.odin
	net_custom:    [dynamic]Net_Profile,     // devtools_net_throttle.odin: the profile's throttling profiles (owned strings)
	sa_queue:      [dynamic]^page.Storage_Access_Ask,   // storage_access_shell.odin: the pages' storage access prompts
	ask_state:     Ask_State,                // fs_shell.odin: a page's file system permission prompt
	notes:         Notification_Shell,       // notification_shell.odin: the pages' system notifications
	qr_url:        string,                   // qr_shell.odin: the address whose QR code is shown ("": none), owned
	vault:         Vault_Shell,              // vault_shell.odin: the Vault (src/vault) and its surfaces
	key_pin:       Key_Pin_Dialog,           // webauthn_shell.odin: the security key's PIN, asked while a ceremony runs
	drag_probe:    Drag_Probe,               // drag_probe.odin
	lm:            Load_Measure,             // blocker_measure.odin: WREN_BLOCKER_MEASURE
	lm_report_path: string,
	lm_settle_ms:  f64,
	lm_checked:    bool,
	dnd:           Dnd_Shell,                // dnd_shell.odin: drags of the system over the windows
	dnd_last_picture: Dnd_Picture,
	dsk:           Desktop_Shell,            // desktop_shell.odin: the desktop integration's job and status
	recovery:      Recovery,                 // crash_recovery.odin: the profile's marker and snapshot
	pt:            Page_Thread,              // page_thread.odin
	remote:        Remote,                   // remote_shell.odin: the remote control channel
	bl:            Bl_Shell,                 // blocker_shell.odin: the content blocker
	ext:           Ext_Shell,                // ext_shell.odin: browser extensions (their registry is app.pages.extensions)
	dash:          Dash,                     // blocker_dashboard.odin
	pick:          Picker,                   // blocker_picker.odin: the element picker
	ub:            Urlbar,                   // urlbar.odin: the history index and its build
	dview:         Downloads_View,           // downloads_ui.odin: about:downloads
	hview:         History_View,             // history_ui.odin: about:history
	bview:         Bookmarks_View,           // bookmarks_ui.odin: about:bookmarks, the bookmark dialog
	tview:         Tree_View_State,          // history_tree.odin: its tree
	vshell:        Video_Shell,              // video_shell.odin: the pages' video players
	cgpu:          Canvas_Gpu,               // canvas_gpu.odin: the canvases drawn on the renderer
	images_shell:  Images_Shell,             // images_shell.odin: the images' textures on the renderer
	// (the large ones last: the fields read at every frame stay together)
	page_render:   Page_Render,              // render.odin: the fonts of the pages, the painters
	chrome_frames: Shell_Frames,             // shell_frames.odin: chrome frames while a page holds the thread
	hud:           Hud,                      // hud.odin: the status bar's statistics
	art:           Art,                      // newtab_art.odin: the artistic new tab
	dtm:           Dt_Metrics,               // devtools_kit.odin: the developer tools' metrics
	dtc:           Dt_Colors,                // ... and colours
	shape_cache:   Shape_Cache,              // chrome_style.odin: the tabs' shapes (Classic_Colors.shapes)
	license_mem:   License_Memory,           // license_shell.odin: the key, when the profile is not kept
	frame_log:     Frame_Log,                // frame_log.odin: when the frames were presented (a ring of FRAME_LOG_CAP)
}

// The preference watches of the App's subsystems (App.watches).
Pref_Watch :: enum u8 { Render, First_Paint, Planes, Effects, Effects_Font, History_Tree, History, Devtools, Autoscroll, Chrome_Style, Interaction, Smooth_Scroll }

// The App of this thread: the one whose loop it runs (app_start's thread), or whose page thread it is (page_thread.odin). What reaches
// the App through it is code that does not take the App yet (a callback of the system, a hook of a package): a thread of its own sees nil.
@(thread_local)
the_app: ^App

clip_get :: proc() -> string { return platform.get_clipboard(active_window(the_app).win, context.temp_allocator) }
clip_set :: proc(text: string) { platform.set_clipboard(active_window(the_app).win, text) }

current_tab :: proc(app: ^App) -> ^Tab {
	w := active_window(app)
	return len(w.tabs) > 0 ? w.tabs[w.current] : nil
}

////////////////////////////////
// Tabs

@(private = "file") tab_ids: u64   // (atomic: every App of the process numbers its tabs from it)

tab_open :: proc(app: ^App, address := "", from: ^page.Page = nil, origin := Nav_Origin.Page) -> ^Tab {
	wnd := active_window(app)
	t := tab_new(app)
	wnd.current = len(wnd.tabs) - 1
	if address != "" { t.url = strings.clone(address) }   // (what the field shows until navigate says better: that may wait for the page holding the thread)
	// an empty address opens the homepage; one that is refused (nav_trust.odin) leaves the homepage too, not an empty tab
	if !navigate(app, t, address, from, origin = origin) { navigate(app, t, "") }
	if from != nil { tab_tree_opened(app, t, tab_of_page(app, from)) }   // tab_tree.odin: under the tab of the page that opened it
	return t
}

// A new tab the user asked for (Ctrl+T, the + of the strip, the menus): the homepage. The address field is focused only
// when browser.newtab.focus_address says so (on by default, as Chromium does).
tab_open_new :: proc(app: ^App) -> ^Tab {
	t := tab_open(app)
	address_sync(app, active_window(app), drop_edit = true)   // (the user asked for a new tab: what was typed is not for it)
	if config.bool_of(&app.prefs, "browser.newtab.focus_address") { window_ask(app, .Address_Focus) }
	return t
}

// The tab of a frame or a page view: not in the strip nor in tab_ids, its id from the frames' own range (frames_shell.odin).
tab_alloc_frame :: proc(id: u64) -> ^Tab {
	t := new(Tab)
	t.id, t.kind, t.zoom = id, .Web, 1
	return t
}

// A Tab, numbered, at rest. The only place a Tab is allocated (src/tools/test_all/lint_app_make.odin): every tab has an id
// of the process's, and joins its App through tab_adopt.
@(private = "file")
tab_alloc :: proc() -> ^Tab {
	t := new(Tab)
	t.id = sync.atomic_add(&tab_ids, 1) + 1
	t.hist = -1
	t.zoom = 1
	return t
}

// A tab joins the App: the map of ids (tab_find: what a request's end, an extension or a remote call looks its tab up by)
// and, given a window, the end of its strip (nil: no strip, as an offscreen document). tab_new and every harness that
// makes tabs come through here, so an invariant of the App's tabs is kept in one place.
tab_adopt :: proc(app: ^App, w: ^Browser_Window, t: ^Tab) {
	if w != nil { append(&w.tabs, t) }
	if app.tab_ids == nil { app.tab_ids = make(map[u64]^Tab) }
	app.tab_ids[t.id] = t
}

// The tab leaves the map of ids (first: what its scope's closing ends looks its tab up and finds none).
@(private = "file")
tab_forget :: proc(app: ^App, t: ^Tab) {
	delete_key(&app.tab_ids, t.id)
	if len(app.tab_ids) == 0 { delete(app.tab_ids); app.tab_ids = nil }   // (made again by the next tab: nothing left over at the end)
}

// A tab with no page (no scope, no navigable): what a test or the chrome world lays out, moves and looks up. It is freed by
// tab_bare_free, else by app_free.
tab_new_bare :: proc(app: ^App, w: ^Browser_Window, url := "", title := "") -> ^Tab {
	t := tab_alloc()
	t.url = strings.clone(url)
	t.title = strings.clone(title)
	tab_adopt(app, w, t)
	return t
}

// A tab of tab_new_bare, out of the map of ids (its strip is the caller's). What the caller gave it besides is the caller's to free.
tab_bare_free :: proc(app: ^App, t: ^Tab) {
	tab_forget(app, t)
	delete(t.url); delete(t.title); delete(t.status)
	free(t)
}

// A tab at the end of the strip, showing nothing yet.
tab_new :: proc(app: ^App) -> ^Tab {
	t := tab_alloc()
	t.scope = base.scope_make("tab", app.process)
	t.top = page.navigable_top_new()
	t.title = strings.clone("New tab")
	tab_adopt(app, active_window(app), t)
	tab_history_limits(app, t)
	blocker_tab_new(app, t)   // blocker_shell.odin
	recovery_touch(app)   // crash_recovery.odin
	ext_tab_created(app, t)   // ext_window_api.odin: tabs.onCreated, from a task (the tab has its address then)
	return t
}

tab_close :: proc(app: ^App, index: int) { tab_close_in(app, app.active, index) }

// Closes the tab at `index` of the window `w`'s strip (active or not). A window that has no tab left closes, unless it is the
// only one: the browser then shows a new tab, as it always did.
tab_close_in :: proc(app: ^App, w: ^Browser_Window, index: int) {
	tabs := window_tabs(app, w)
	t := tabs[index]
	if shell_defer({kind = .Close_Tab, tab = t.id}) { return }   // (shell_frames.odin: its page may be the one running)
	closed_tab_push(app, w, t, index)   // closed_tabs.odin
	tree_forget(tabs[:], t)   // tab_tree.odin: its children move up a level
	ordered_remove(tabs, index)
	tab_groups_prune(tabs[:], &w.groups)   // tab_groups.odin: its group goes with its last tab
	key := strings.clone(tab_key(t), context.temp_allocator)
	tab_free(app, t)
	page.storage_drop_session(&app.storage, key)   // (once its page is gone)
	cur := window_current(app, w)
	if len(tabs) == 0 {
		if len(app.windows) > 1 { w.closing = true } else { tab_open(app) }
	} else {
		if index < cur^ { cur^ -= 1 }   // (the tabs after it shift down: the current one stays the current one)
		cur^ = clamp(cur^, 0, len(tabs) - 1)
	}
	recovery_touch(app)
}

// The user closes a tab (Ctrl+W, its close button, a middle click, the tab's menu). The last tab of the last window
// closes the window, and so Wren, as the window's close button does (browser.tabs.close_window_with_last_tab); a close
// by the program (a reset, the crash recovery's) takes tab_close_tab, which leaves a new tab instead.
tab_close_by_user :: proc(app: ^App, t: ^Tab) {
	w, _ := window_of_tab(app, t)
	if w != nil && app.favs.cfg.close_with_last_tab && len(app.windows) == 1 && len(window_tabs(app, w)) == 1 {
		platform.request_close(w.win)
		return
	}
	tab_close_tab(app, t)
}

// Closes a tab of any window.
tab_close_tab :: proc(app: ^App, t: ^Tab) {
	if w, i := window_of_tab(app, t); w != nil { tab_close_in(app, w, i) }
}

// Frees a tab taken out of the strip (closed, or at exit): its page and everything the shell keeps for it.
tab_free :: proc(app: ^App, t: ^Tab) {
	tab_forget(app, t)   // (first: what its scope's closing ends, a request, looks its tab up and finds none)
	bfcache_drop_tab(app, t)
	tab_nav_destroy(app, t)
	ext_tab_closed(app, t)   // ext_shell.odin: what the extensions kept for the tab (per-tab action state)
	base.scope_close(t.scope)   // page, instances, DOM, requests, timers: all gone (a held page too)
	page.navigable_top_free(t.top)   // (the windows holding it see it closed)
	hold_step(app, t, .Tab_Gone)
	page_fonts_drop(&app.page_render.fonts, t)   // its web fonts (fonts.odin)
	page.session_destroy(&t.session)
	delete(t.url); delete(t.title); delete(t.status)
	tab_icon_destroy(&t.icon)
	for h in t.history { delete(h) }
	delete(t.history)
	for l in t.console { delete(l) }
	delete(t.console)
	net_log_destroy(&t.net)
	console_log_destroy(t)
	layout_destroy(&t.layout)
	layout_destroy(&t.shown.layout)
	smooth_destroy(&t.smooth)
	free(t)
}

tab_log :: proc(t: ^Tab, level: page.Log_Level, message: string) { console_append(t, level, message) }

console_sink :: proc(user: rawptr, level: page.Log_Level, message: string) {
	if the_app.remote.active && remote_take_console(message, (^Tab)(user).id) { return }   // (an answer of a remote script, not a message)
	t := (^Tab)(user)
	tab_log(t, level, message)
	if remote_subscribed() { remote_event("Runtime.consoleAPICalled", fmt.tprintf(`{{"tabId":%d,"type":%q,"text":%s}}`, t.id, level == .Error ? "error" : level == .Warn ? "warning" : "log", base.json_quote(message))) }
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
	if words, searched := home_search_words(target); searched && verdict.acts {
		// the start page's search box (about:home?q=...): what the address bar does with the same text
		target = strings.trim_space(words) == "" ? HOME_URL : strings.clone(normalize_address(address_or_search(app, words)), context.temp_allocator)
		verdict = nav_judge(origin, from != nil ? &from.env : nil, app.loader.profile.settings.file_access, target)
	}
	if verdict.refuse != "" { nav_refused(t, from, target, verdict.refuse); return false }
	accepted = true   // (from here on the early returns of the built-in pages are acceptances)
	address_let_go(app, t)
	target = verdict.address
	cache_prof_leave(t)   // (profile build: what the page cost, http_cache_ui.odin)
	// a window's initial about:blank stays, shown and in its scope, until the response says whether its Window is the next
	// document's (document_event); a navigation already under way leaves it as any page
	blank := t.load == nil && page.navigable_blank_window(t.top, t.page) ? t.page : nil
	if blank == nil { leave_page(app, t) }   // the entry being left keeps what it shows; the page may go to the back/forward cache
	nav_to(app, t, .Requested)
	pushed := false
	if record {
		cur := page.session_current(&t.session)
		pushed = cur == nil || cur.url != target   // (visiting the current entry's URL again adds none)
		history_push(app, t, target)
	}
	// built-in pages show at once (they paint in their first frame)
	entry := page.session_current(&t.session)
	restore_stop(app, t)
	if restore && entry != nil && app.hcfg.restore_zoom && entry.persisted.zoom > 0 { t.zoom = entry.persisted.zoom }
	if restore { timing_begin(t, false) }
	defer if restore { restore_begin(app, t, entry) }
	license_file := is_license_file_address(target) && verdict.acts   // license_shell.odin
	if is_builtin_address(target) || license_file || is_cache_address(target) || is_sites_address(target) || is_extensions_address(target) { hold_step(app, t, .Over); bfcache_take(app, t) }   // (show_* closes the tab's navigation scope)
	if target == "about:config" { show_config(app, t); return }
	if target == SETTINGS_URL { show_settings(app, t); return }
	if is_history_address(target) { show_history(app, t, target); return }
	if is_blocker_address(target) { show_blocker(app, t, target); return }   // blocker_dashboard.odin
	if is_downloads_address(target) { show_downloads(app, t, target); return }   // downloads_ui.odin
	if is_bookmarks_address(target) { show_bookmarks(app, t, target); return }   // bookmarks_ui.odin
	if target == HOME_URL { show_home(app, t); return }
	if strings.has_prefix(target, HOME_URL + "?") { home_query(app, t, target, verdict.acts); return }   // newtab_art_page.odin
	if target == DEMOS_URL { show_demos(app, t); return }
	if target == ABOUT_URL { show_about_pages(app, t); return }
	if is_wren_address(target) { show_wren_page(app, t, target, verdict.acts); return }   // about_wren.odin
	if license_file { license_open_file(app, t, target); return }
	if is_cache_address(target) { show_cache_page(app, t, target, verdict.acts); return }   // http_cache_ui.odin
	if is_sites_address(target) { show_sites_page(app, t, target, verdict.acts); return }   // site_data_ui.odin
	if is_extensions_address(target) { show_extensions_page(app, t, target, verdict.acts); return }   // ext_page.odin
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
	load.blank = blank
	if blank == nil {
		hold_step(app, t, .Navigation, target)
		nav_fresh(t, .Web)
	}
	load_measure_begin(app, t, target)   // blocker_measure.odin
	base.on_close(t.nav, load_closed, load)
	t.load = load
	t.scroll_target = base.NIL_HANDLE
	t.scroll = 0
	t.fragment_done = false   // a new document scrolls to its fragment
	console_reset(t)
	delete(t.url)
	t.url = strings.clone(shown)
	delete(t.title)
	t.title = default_tab_title(shown, context.allocator)   // until the document says better (favicon.odin)
	set_status(t, "loading...")

	load.task = fetch.start(&app.loader, {
		request = {
			url = target, mode = .Navigate, credentials = .Include, redirect = .Follow, destination = .Document,
			initiator = load.has_initiator ? &load.initiator : nil, user_activation = user_activation,
			method = method, body = body, headers = headers, cache = cache,
		},
		on_event = document_event, user = load, scope = t.nav, collect = true, peek = true,
	})
	return
}

history_push :: proc(app: ^App, t: ^Tab, target: string) {
	page.session_push(&t.session, target, 0, max_entries = app.page_settings.web.history_max_entries)
	sync_history(app, t)
}

// The chrome's view of the session history (back / forward buttons): the joint session history, the steps of the tab's
// frames between its entries, each shown as the tab's address (page/history_joint.odin).
sync_history :: proc(app: ^App, t: ^Tab) {
	for h in t.history { delete(h) }
	clear(&t.history)
	tops, cur := page.joint_view(&t.session)
	for e in tops { append(&t.history, strings.clone(e.url)) }
	t.hist = cur
	recovery_touch(app)   // (every change of a tab's history: a navigation, back, forward, a redirect)
}

// Back, forward: `delta` steps of the joint session history, in the tab's frames first when they have steps there.
go_history :: proc(app: ^App, t: ^Tab, delta: int) {
	if t == nil || delta == 0 { return }
	if shell_defer({kind = .History, tab = t.id, delta = delta}) { return }   // (shell_frames.odin)
	if t.page == nil || t.kind != .Web {
		go_entry(app, t, page.session_peek(&t.session, delta))
		return
	}
	switch move, e := page.joint_traverse(t.page, delta, user = true); move {
	case .None:
	case .Frames: sync_history(app, t)
	case .Top:
		sync_history(app, t)
		same_document_url(app, t, t.page.env.location.href)
	case .Other_Document: go_entry(app, t, e)
	}
}

// Makes `e` (any entry of the tab's history tree: the path to it becomes the active one) the current entry: popstate
// when it is the document's, else the page it had from the back/forward cache, else it loads again.
go_entry :: proc(app: ^App, t: ^Tab, e: ^page.History_Entry) {
	if t == nil || e == nil || e == page.session_current(&t.session) { return }
	if shell_defer({kind = .Entry, tab = t.id, entry = e.id}) { return }   // (shell_frames.odin)
	// an entry of the current document: popstate, no load
	if t.page != nil && t.kind == .Web {
		#partial switch page.history_traverse_to(t.page, e) {
		case .Canceled: return   // (a navigate listener of the document refused it)
		case .Same_Document:
			sync_history(app, t)
			same_document_url(app, t, t.page.env.location.href)
			return
		}
	}
	leave_page(app, t)
	left := page.session_current(&t.session)
	page.session_goto(&t.session, e)
	sync_history(app, t)
	if bfcache_restore(app, t, e) {
		if t.page != nil { page.joint_show_position(t.page) }   // (back among its frames' steps: they move there)
		return
	}
	navigate(app, t, strings.clone(e.url, context.temp_allocator), record = false, restore = true, cache = history_cache_mode(app), origin = .Replay)
	if t.load != nil && left != nil { t.load.left_entry = left.id }
}

same_document_url :: proc(app: ^App, t: ^Tab, address: string) {
	delete(t.url)
	t.url = strings.clone(address)
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
		if navigate(app, t, strings.clone(req.url, context.temp_allocator), p) && req.has_nav_state { page.session_set_nav_state(&t.session, req.nav_state, true) }
	case .Replace:
		// judged before the entry changes: a refused address (nav_trust.odin) must not replace the page's entry
		v := nav_judge(.Page, &p.env, app.loader.profile.settings.file_access, normalize_address(req.url))
		if v.refuse != "" {
			nav_refused(t, p, req.url, v.refuse)
			break
		}
		leave_page(app, t, keep = false, save = false)
		if cur := page.session_current(&t.session); cur != nil {
			// another document in the entry: nothing of the old one's comes back
			page.persisted_clear(&cur.persisted)
			page.joint_forget_document(&t.session, cur.doc)
		}
		page.session_replace(&t.session, v.address)
		if req.has_nav_state { page.session_set_nav_state(&t.session, req.nav_state, true) }
		sync_history(app, t)
		navigate(app, t, strings.clone(req.url, context.temp_allocator), p, record = false)
	case .Reload:
		if req.has_nav_state { page.session_set_nav_state(&t.session, req.nav_state, true) }
		reload(app, t)
	case .Traverse:
		go_entry(app, t, page.session_peek(&t.session, req.delta))
	case .Url_Changed:
		sync_history(app, t)
		same_document_url(app, t, req.url)
		global_history_visit(app, t, req.url, t.title)
	case .History_Changed:
		sync_history(app, t)
	}
	request_frames(app, 2)
}

// window.open, a link to a new window (page/auxiliary.odin): a tab at the end of the strip, shown, whose window starts on the
// initial about:blank document the page package makes, then loads the address as a link from the source would.
page_open_window :: proc(user: rawptr, p: ^page.Page, req: page.Open_Request) -> ^page.Navigable {
	app := the_app
	wnd := active_window(app)
	t := tab_new(app)
	wnd.current = len(wnd.tabs) - 1
	nav_fresh(t, .Web)
	nav_adopt(app, t, page.auxiliary_document(t.top, req, t.nav, console_sink, t))
	page.render_begin(t.page)
	if page.open_is_blank(req.url) {
		delete(t.url)
		t.url = strings.clone(req.url)
	} else {
		navigate(app, t, req.url, req.source)   // (a noreferrer window still sends the Referer: the shell's navigations have no such option)
	}
	if req.source != nil { tab_tree_opened(app, t, tab_of_page(app, req.source)) }   // tab_tree.odin
	request_frames(app, 2)
	return t.top
}

// window.close() of a tab a script opened (page/auxiliary.odin), from a task of its own.
page_close_window :: proc(user: rawptr, p: ^page.Page) {
	t := (^Tab)(user)
	if t.page != p { return }
	if ext_popup_closes(the_app, t) { return }   // ext_popup.odin: an extension's popup closes itself
	tab_close_tab(the_app, t)
}

// Connects a document to its tab: its window (the tab's navigable), navigation hook, session history, storage, new windows.
attach_page :: proc(app: ^App, t: ^Tab, p: ^page.Page) {
	page.navigable_attach(t.top, p)
	page.set_embedder(p, {navigate = page_navigate, user = t, session = &t.session, tab_key = tab_key(t), storage = &app.storage, print = page_print, leaving = page_entry_leaving,
		open = page_open_window, close = page_close_window})
	if cur := page.session_current(&t.session); cur != nil { bfcache_forget(app, t, cur.id) }   // a new document for the entry: an older one cached for it is stale
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

SETTINGS_URL :: "about:settings"

// about:settings, like about:config, is a view of the browser itself (settings_page.odin).
show_settings :: proc(app: ^App, t: ^Tab) {
	nav_show_view(app, t, .Settings)
	layout_reset(&t.layout)
	t.scroll_target = base.NIL_HANDLE
	console_reset(t)
	delete(t.url); t.url = strings.clone(SETTINGS_URL)
	delete(t.title); t.title = strings.clone("Settings")
	set_status(t, SETTINGS_URL)
	prefs_page.focus_search(&app.settings_view)
}

// about:config is a view of the browser itself, not a document: it has no page, no origin, no scripts.
show_config :: proc(app: ^App, t: ^Tab) {
	nav_show_view(app, t, .Config)
	layout_reset(&t.layout)
	t.scroll_target = base.NIL_HANDLE
	console_reset(t)
	delete(t.url); t.url = strings.clone("about:config")
	delete(t.title); t.title = strings.clone("Configuration")
	set_status(t, "about:config")
}

// An HTML page the browser makes up when a load fails, so the tab always shows something readable.
// (error_pages.odin writes it.)
show_error_page :: proc(app: ^App, load: ^Doc_Load, e: Error_Text) {
	t := load.tab
	if b := load.blank; b != nil {
		load.blank = nil
		blank_close(t, b)
	}
	if load.page == nil {
		load.page = page.page_create(&app.loop, &app.loader, &app.page_settings, t.nav, "about:blank", console_sink, t)
		nav_adopt(app, t, load.page)
	}
	load.failed = e.kind == .Tls ? .Tls : .Other
	title := error_tab_title(t.url)
	page.load_html(load.page, transmute([]byte)error_page_html(e, t.url, title))
	delete(t.title)
	t.title = strings.clone(title)
	set_status(t, e.headline)
	tab_log(t, .Error, fmt.tprintf("%s: %s", e.headline, e.detail))
}

// The window's initial about:blank a navigation kept (navigate) does not take the next document: it goes as a page left does.
blank_close :: proc(t: ^Tab, b: ^page.Page) {
	if t.page == b { t.page = nil }
	page.page_unload(b)
	page.page_close(b)
}

escape_html :: proc(s: string) -> string { return base.escaped(s, {.Quote}) }

document_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	load := (^Doc_Load)(user)
	t := load.tab
	app := the_app
	defer { request_frames(app, 3) }
	// (its bytes and the scan for what to ask for next are the document's work, not the browser's)
	scope := host.work_enter(&app.loop, load.page != nil ? page.page_work(load.page, .Arrival) : app.loop.work)
	defer host.work_leave(&app.loop, scope)
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
		// a window's initial about:blank: the document takes its Window when it may (HTML "navigate"), else it goes
		kept: ^page.Page
		if b := load.blank; b != nil {
			load.blank = nil
			if load.action == .Render && !load.view_source { kept = page.navigable_keep_window(t.top, b, r.url, r.headers) }
			if kept == nil { blank_close(t, b) }
		}
		set_status(t, fmt.tprintf("HTTP %d%s", r.status, cache_status_suffix(r.cache)))
		shown := load.view_source ? strings.concatenate({VIEW_SOURCE, r.url}, context.temp_allocator) : r.url
		delete(t.url)
		t.url = strings.clone(shown)
		// an image is shown by a document the browser writes once the image is in (download.odin show_image_document)
		if load.action == .Image && !load.view_source {
			nav_to(app, t, .Responded)
			return
		}
		// the document exists from here on, with the origin of its *final* URL
		if cc, ok := http.get_header(r.headers, "cache-control"); ok && base.ascii_contains_fold(cc, "no-store") { t.nav_state.no_store = true }
		// a redirect: the entry is the final address
		if cur := page.session_current(&t.session); cur != nil && !load.view_source && cur.url != r.url { page.session_replace(&t.session, r.url, set_state = false); sync_history(app, t) }
		load.page = kept != nil ? kept : page.page_create(&app.loop, &app.loader, &app.page_settings, t.nav, r.url, console_sink, t)
		if load.cache == .Reload { load.page.env.cache_override = .Reload }   // Ctrl+F5: everything it loads, from the network
		load.response_ns = host.now_ns(&app.loop)
		page.set_navigation_timing(load.page, {
			start_ns = load.started_ns, response_ns = load.response_ns, reload = load.cache == .Reload || load.cache == .No_Cache,
			status = r.status, from_cache = r.cache == .Hit, mime = load.mime, redirects = r.redirected ? 1 : 0,
		})
		nav_adopt(app, t, load.page)
		if !load.view_source && r.status < 400 { global_history_visit(app, t, r.url, "") }
		csp_h := http.get_all(r.headers, "content-security-policy")
		ro_h := http.get_all(r.headers, "content-security-policy-report-only")
		rp, _ := http.get_header(r.headers, "referrer-policy")
		page.apply_response_headers(load.page, csp_h, ro_h, rp)
		page.apply_isolation_headers(load.page, r.headers)
		if load.action == .Render && !load.view_source { page.preload_scan_begin(load.page, load.charset, load.mime) }
	case .Data:
		if load.page != nil { page.preload_scan_feed(load.page, ev.data) }
	case .Done:
		if load.page != nil { page.preload_scan_end(load.page) }
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
	page.parse_document(p, data, load.charset, document_parsed, load, load.mime)
}

document_parsed :: proc(p: ^page.Page, user: rawptr, d: ^page.Parsed_Document) {
	load := (^Doc_Load)(user)
	t := load.tab
	app := the_app
	request_frames(app, 3)
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
	dom.set_text_content(p.doc, pre, string(d.text[:min(len(d.text), SHOW_TEXT_MAX_BYTES)]))
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
	request_frames(the_app, 3)
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
	wnd := active_window(app)
	wnd.page_rect = b.rect
	t := current_tab(app)
	if shell_nested() {
		// a chrome frame (shell_frames.odin): the page holds the thread; its last frame, nothing of it runs (painted again from
		// its last layout where the shell scrolled it or a drag selects: shell_paint_layout)
		web := t != nil && t.kind == .Web
		if web && shell_layout_wanted(app, t) {
			shell_paint_layout(app, t, dc, b.rect)
		} else if !web || !shell_paint_page(app, t, dc, b.rect) {
			draw.rect(dc, b.rect, to_draw(expected_canvas(app)))
		}
		// the video fast path: keep a video playing over the frozen page (video_fast_path.odin)
		if t != nil && t.kind == .Web { video_fast_path_overlay(app, t, dc, b.rect) }
		if t != nil { loading_bar(app, t, dc, b.rect) }   // (the full frames draw it: it would blink between the two kinds)
		return
	}
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

// HTML "try to scroll to the fragment" of a new document, at its first layout (page.scroll_to_fragment: the indicated
// part, the target element; the page does it itself when the URL changes within the document). It jumps.
scroll_to_fragment :: proc(app: ^App, t: ^Tab) {
	if t.fragment_done || !t.layout.valid { return }
	t.fragment_done = true
	page.scroll_to_fragment(t.page, animate = false)
}

// The page's own box (or the view of a built-in page): what fills the room the developer tools leave.
page_view :: proc(app: ^App, t: ^Tab) {
	ui.next({width = ui.fill(), height = ui.fill()})
	if t != nil && t.kind == .Config {
		config_page(app, &app.config_view, &app.prefs)
	} else if t != nil && t.kind == .Settings {
		settings_page(app)   // settings_page.odin
	} else if t != nil && t.kind == .History {
		history_page(app, t)   // history_ui.odin
	} else if t != nil && t.kind == .Blocker {
		blocker_page(app, t)   // blocker_dashboard.odin
	} else if t != nil && t.kind == .Downloads {
		downloads_page(app, t)   // downloads_ui.odin
	} else if t != nil && t.kind == .Bookmarks {
		bookmarks_page(app, t)   // bookmarks_ui.odin
	} else {
		// a Tab stop of the chrome: reaching it hands the keyboard to the page (forms_focus_from_chrome)
		pb := ui.custom("###page_area", page_draw, nil, {.Focusable})
		page_area_focus(app, t, pb)
		page_a11y_graft(app, t, pb)   // a11y_page.odin: the page's tree for screen readers
		blocker_picker_frame(app, t)   // blocker_picker.odin
	}
}

// What is under the toolbar (beside the sidebar when the tabs are in one): the crash banner, the find bar, the page and the
// developer tools docked next to it.
// `width`: the column's (physical px): the window's, less the tabs' sidebar beside it. The developer tools docked at the bottom
// are laid out at it (they took the window's width beside a sidebar, and their right end was cut off).
page_column :: proc(app: ^App, t: ^Tab, elem_fs: bool, width: f32) {
	if !elem_fs { bookmarks_bar(app, t); crash_banner(app); find_bar(app, t) }   // bookmarks_bar.odin, crash_banner.odin
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
		devtools_panel(app, t, false, {width = ui.fill(), height = ui.px(devtools_extent(app, false))}, fill = {width, 0})
	case:
		page_view(app, t)
	}
}

build_ui :: proc(app: ^App) {	session_lazy_load(app)   // session.odin: a restored tab loads when it is first shown
	chrome_shortcuts(app)
	ext_watch(app)   // ext_window_api.odin: the extensions' view of the windows, tabs and input changes
	t := current_tab(app)
	if ui.style({width = ui.fill(), height = ui.fill()}) {
		ui.next({axis = .Y})
		root := ui.build_box({.Draw_Background}, "###window")
		if ui.parent(root) {
			// tab strip (the window's title bar when integrated: window_chrome.odin), navigation, security chip,
			// address, menu; in full screen they come over the page on demand (fullscreen_bars)
			// the tabs in a sidebar (tab_sidebar.odin): the toolbar is the title bar (integrated; else its own row under
			// the system's), and the sidebar and the page share what is below it
			side := tabs_in_sidebar(app)
			// (an extension's popout window: its page only, no tab strip and no toolbar: ext_window_api.odin)
			if !platform.is_fullscreen(active_window(app).win) && !ext_is_popout(app, active_window(app)) {
				if side && platform.is_integrated_title(active_window(app).win) {
					sidebar_titlebar(app, t)
				} else {
					if !side { tab_strip(app, platform.is_integrated_title(active_window(app).win)) }
					toolbar_row(app, t)   // chrome_style.odin
				}
			}
			elem_fs := fullscreen_shell_active(app.active)   // a page's element in full screen: the page has the whole window
			if side {
				pos := app.favs.cfg.position
				side_now := sidebar_extent_now(app, pos)
				ui.next({width = ui.fill(), height = ui.fill()})
				if ui.row(.Start, {}, "###sidebar_row") {
					if pos == .Left { tab_sidebar(app, pos, side_now) }
					ui.next({width = ui.fill(), height = ui.fill()})
					if ui.column(.Start, {}, "###page_column") { page_column(app, t, elem_fs, f32(active_window(app).win.size.x) - side_now.extent) }
					if pos == .Right { tab_sidebar(app, pos, side_now) }
				}
			} else {
				window_own(app).sidebar.shown = false
				page_column(app, t, elem_fs, f32(active_window(app).win.size.x))
			}
			// status bar (status_bar.odin)
			if !elem_fs { status_bar_build(app, t) }
			fullscreen_bars(app, t)
			link_bubble(app, t)   // status_bar.odin: where the link under the pointer goes, over the page's corner (under the floating developer tools)
			devtools_floating(app, t)   // over the page when it is undocked
		}
	}
	context_menus_build(app)
	palette_build(app)   // palette.odin: the command palette, over everything else
	setup_build(app)   // setup.odin: the Setup dialog (toolkit:setup; it also collects the work of its thread)
	fs_shell_build(app)   // fs_shell.odin: a page's file permission prompt (nothing while none waits)
	notification_shell_build(app)   // notification_shell.odin: a page's notification permission prompt
	qr_build(app)   // qr_shell.odin: the QR code of the page's address
	webauthn_pin_build(app)    // webauthn_shell.odin: a security key's PIN, asked while a ceremony runs
	vault_dialogs_build(app)   // vault_shell.odin: the Vault's login / unlock dialog, the question before a fill
	bookmarks_dialog_build(app)   // bookmarks_ui.odin: the dialog that names a bookmark
	bookmarks_bar_menus(app)   // bookmarks_bar.odin: the bar's menus
	confirm_build(app)   // confirm_shell.odin: a question before an act not taken back
	storage_access_shell_build(app)   // storage_access_shell.odin: a frame's storage access prompt
	// notices go over the page, not over the title bar's window buttons
	if pr := active_window(app).page_rect; pr.max.y > pr.min.y { ui.set_toast_area(pr) }
	ui.toasts_build()
	keyboard_follow(app)   // (what this build did to the focus: the paint asks who has the keyboard)
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

// The last position of a frame's pointer moves over the page: its hover state and its pointer events (route_page_input).
@(private = "file")
page_move_flush :: proc(app: ^App, t: ^Tab, last_move: platform.Event) {
	wnd := active_window(app)
	hovered := base.NIL_HANDLE
	// (the pointer over a menu, a chrome widget that overlaps the page or the statistics panel is not over the page: its hover state and
	// its pointer events stay where they were: the card under a menu used to light up as the pointer crossed the menu)
	over_chrome := ui.ctx_menu_any_open() || ui.hot_key() != 0 || hud_captures(app, last_move.pos)
	scrollbar_over_move(app, t, last_move.pos, !over_chrome && draw.rect_contains(wnd.page_rect, last_move.pos))
	if !over_chrome && draw.rect_contains(wnd.page_rect, last_move.pos) && t.layout.valid { hovered = hit_or_root(t, hit_test(&t.layout, last_move.pos - wnd.page_rect.min, draw.rect_size(wnd.page_rect), t.scroll)) }
	st := t.page.style_state
	was := st.hover
	st.hover = hovered
	page.set_style_state(t.page, st)
	page_pointer_events(app, t, was, hovered, last_move.pos, dom_buttons(last_move.buttons), last_move.emulated)   // page_pointer.odin
}

// Mouse and wheel events that land on the page become DOM events / scrolling.
route_page_input :: proc(app: ^App, events: []platform.Event) {
	wnd := active_window(app)
	gesture_follow(app)
	t := current_tab(app)
	if t == nil || t.page == nil || t.kind != .Web { return }
	page_world_check("route_page_input: page input in a chrome frame, or during a page thread pass")
	scale := page_scale(app)
	g := gesture_of(app)
	last_move: platform.Event
	have_move := false
	defer if have_move && t.page != nil { page_move_flush(app, t, last_move) }
	for ev, index in events {
		inside := draw.rect_contains(wnd.page_rect, ev.pos)
		// the pointer got where it is before the button went down or up: the move's events (mouseover of a handle a script reads
		// on the press, mousemove) come first, in the order they happened
		if (ev.kind == .Mouse_Press || ev.kind == .Mouse_Release) && have_move && t.page != nil {
			page_move_flush(app, t, last_move)
			have_move = false
			if t.page == nil { return }
		}
		if ev.kind == .Mouse_Leave { scrollbar_over_move(app, t, ev.pos, false) }
		gesture_follow(app)
		gesture_note(app, ev, inside)
		if ev.lost { gesture_spent_event(g, ev); continue }   // (the system took the pointer: its release is nobody's, no mouseup, no click)
		// who holds the pointer has it first; what it leaves goes on below
		took := false
		switch g.owner {
		case .Idle, .Page_Press, .Press_Pending, .Selecting:
		case .Spent:          took = gesture_spent_event(g, ev)
		case .Drag_Candidate: took = dnd_candidate_event(app, t, ev)      // dnd_shell.odin
		case .Page_Drag:      took = dnd_drag_event(app, t, ev)
		case .Thumb:          took = scrollbar_thumb_event(app, t, ev)    // smooth_scroll.odin
		case .Arrow:          took = scrollbar_arrow_event(app, t, ev)
		case .Autoscroll:     took = autoscroll_page_event(app, ev, index)   // page_autoscroll.odin
		case .Frame:          took = (ev.kind == .Mouse_Move || ev.kind == .Mouse_Release) && frames_route_pointer(app, t, ev, index)   // frames_shell.odin
		}
		if t.page == nil { return }
		if took { continue }
		ended: Ended_Press
		if ev.kind == .Mouse_Release { ended = gesture_release(app, ev) }
		// fingers and pens, a cancelled touch's mouse emulation (page_input.odin)
		if route_device_pointer(app, t, ev) || page_drop_emulated(app, ev) { if t.page == nil { return }; continue }
		if dev().picking && (ev.kind == .Mouse_Move || ev.kind == .Mouse_Press || ev.kind == .Mouse_Release) && devtools_pick_event(app, t, int(ev.kind), ev.pos, ev.kind == .Mouse_Press) { continue }   // the element picker of the developer tools (devtools_elements.odin)
		if DEBUG_INPUT && ev.kind != .Mouse_Move { debug_log(fmt.tprintf("event %v at %v inside=%v rect=%v", ev.kind, ev.pos, inside, wnd.page_rect)) }
		if fullscreen_shell_escape(app, ev) { consume(app, index); continue }   // Escape leaves a page's full screen, the page does not see it (fullscreen_shell.odin)
		if !hud_captures(app, ev.pos) && scrollbar_press(app, t, ev) { continue }   // the page's scroll bars (smooth_scroll.odin)
		// pointer events over a frame, and the keyboard of a frame that has it, are its document's (frames_shell.odin); a press elsewhere keeps its moves
		if !hud_captures(app, ev.pos) && (ev.kind != .Mouse_Move || gesture_free(g)) && frames_route_pointer(app, t, ev, index) { continue }
		if frames_route_keys(app, ev, index) { continue }
		// form controls first: keyboard for the focused field, the open drop-down list (forms_shell.odin)
		if forms_route_event(app, t, ev, index) { continue }
		if t.page == nil { return }
		if (ev.kind == .Mouse_Press || ev.kind == .Scroll) && hud_captures(app, ev.pos) { continue }   // the frame statistics panel
		#partial switch ev.kind {
		case .Mouse_Move:
			last_move, have_move = ev, true   // only the last position of the frame matters: hit test once, after the loop
			selection_pointer_move(app, t, ev.pos)
		case .Scroll:
			if inside && .Ctrl in ev.mods {
				// Ctrl+wheel zooms the page (wheel up = delta.y < 0 = bigger)
				if ev.delta.y != 0 { zoom_step(app, t, ev.delta.y < 0 ? 1 : -1) }
			} else if inside {
				d := wheel_axes(ev) * wheel_step(app, (wnd.page_rect.max - wnd.page_rect.min) / max(scale, 0.01)) * scale   // platform convention: +y = towards the end of the content
				smooth_wheel(app, t, ev.pos - wnd.page_rect.min, d, wheel_is_precise(ev.delta))   // smooth_scroll.odin
			}
		case .Mouse_Press:
			if side_button_command(ev.button) != .None { continue }   // (the release acts, and a page has no such button to be told of)
			if !inside || !t.layout.valid { continue }
			if ui.ctx_menu_any_open() { continue }   // the press closes the menu (the toolkit's)
			local := ev.pos - wnd.page_rect.min + doc_scroll_vec(t)
			pressed := hit_test(&t.layout, ev.pos - wnd.page_rect.min, draw.rect_size(wnd.page_rect), t.scroll)
			t.scroll_target = pressed
			free := gesture_free(g)
			if ev.button == .Left && free { gesture_press(app, t, t.page, .Page_Press, ev) }
			allowed := forms_pointer_down(app, t, ev, pressed, local)
			if t.page == nil { return }
			// the middle button starts autoscroll when the page did not cancel the mousedown and it is not a link
			if ev.button == .Middle && free && autoscroll_page_press(app, t, ev, pressed, allowed) { continue }
			// the left one decides who owns the press
			if ev.button == .Left && g.owner == .Page_Press {
				page_set_active(t.page, pressed)   // :active while the button is held
				draggable := allowed && dnd_press(app, t, ev, pressed)   // dnd_shell.odin: a press that may become a drag selects nothing
				if !draggable { selection_pointer_down(app, t, ev, pressed, allowed) }
			}
			if ev.button == .Right { page_context_press(app, t, ev.pos) }
		case .Mouse_Release:
			if c := side_button_command(ev.button); c != .None {
				host.post(&app.loop, app_command_run, new_clone(App_Command_Post{app, c}), .Input)
				continue
			}
			if !t.layout.valid { continue }
			local := ev.pos - wnd.page_rect.min + doc_scroll_vec(t)
			released := inside ? hit_test(&t.layout, ev.pos - wnd.page_rect.min, draw.rect_size(wnd.page_rect), t.scroll) : base.NIL_HANDLE
			target, clicked := forms_pointer_up(app, t, ev, released, local, ended)
			if t.page == nil { return }
			// a middle release on a link opens it in a new tab (Chrome: autoscroll bailed on the link at the press);
			// forms_pointer_up only reports `clicked` for the left button, so the middle case is handled here
			if ev.button == .Middle && inside && released != base.NIL_HANDLE {
				if href, ok := anchor_href(t.page.doc, released); ok {
					if resolved, rok := page.resolve_link(t.page, href, released); rok {
						open_in_new_tab(app, resolved.href, t.page, origin = .Page)
						continue
					}
				}
			}
			if ev.button == .Right && inside { page_context_menu(app, t, released, ev.pos, local, .Shift in ev.mods) }
			if !clicked || t.page == nil || ended.dragged { continue }
			not_prevented := forms_click(app, t, target, ev, local)
			if t.page == nil { return }
			// default action: following a link, unless a listener called preventDefault
			if not_prevented && ev.button == .Left {
				if href, ok := anchor_href(t.page.doc, target); ok {
					resolved, rok := page.resolve_link(t.page, href, target)
					if !rok { tab_log(t, .Error, fmt.tprintf("invalid link %q", href)); continue }
					if page.follow_fragment_link(t.page, resolved) { continue }   // same document: page_draw scrolls to the target
					if page.follow_javascript_url(t.page, resolved) { continue }  // javascript: runs in the page (js_load_realm.odin)
					if frames_link_target(app, t, target, resolved.href) { continue }   // target="a frame's name" (frames_shell.odin)
					if .Ctrl in ev.mods {
						// Ctrl+click: a new tab, the page stays (under it in the tree: tab_tree.odin)
						open_in_new_tab(app, resolved.href, t.page, origin = .Page)
						continue
					}
					if link_opens_window(t.page, target, resolved.href) { continue }   // target=_blank or a name nothing has
					if page.navigation_link(t.page, resolved) { continue }   // the document's navigate listener took it (Navigation API)
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

// The profile's files that changed: the texts are made here, the blocking pool writes them (profile_writes.odin). With `force`
// (at exit) everything is written before it returns.
profile_save :: proc(app: ^App, force := false) {
	c, h, pf := profile_paths(app)
	if force { profile_files_flush(app) }   // (first: what follows is written on this thread, after what waited)
	profile_prefs_save(app, pf)   // profile_writes.odin (when the user's layer changed)
	session_save(app, force)   // session.odin (when it changed)
	profile_stores_save(app, c, h, force)   // the cookies and the HSTS hosts
}

autosave :: proc(data: rawptr) {
	app := (^App)(data)
	host.quiet_note(&app.loop)   // (what is on the disk: nothing to draw)
	profile_save(app)
}

// (Re)arms the autosave timer from the current preference.
arm_autosave :: proc(app: ^App) {
	if app.autosave_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, app.autosave_timer); app.autosave_timer = base.NIL_HANDLE }
	if app.cfg.autosave_ms > 0 {
		app.autosave_timer = host.set_timer(&app.loop, f64(app.cfg.autosave_ms), f64(app.cfg.autosave_ms), autosave, app)
	}
}

// Every setting struct is derived from the registry; when any preference changes they are all refreshed and handed to
// their subsystems. Preferences marked "restart" are read again at the next start (the subsystem keeps what it opened with).
// `changed`: the preference written ("" = any): the network, the HTTP cache, the downloads and the touch devices are
// configured again only for their own (prefs_apply.odin).
apply_prefs :: proc(app: ^App, changed := "") {
	groups := pref_groups_of(changed)
	if .Net in groups { net_apply(app) }

	fetch.settings_destroy(&app.profile.settings)
	app.profile.settings = fetch.settings_from_prefs(&app.prefs)
	app.profile.jar.settings = cookies.settings_from_prefs(&app.prefs)
	if .Http_Cache in groups { http_cache_apply(app); app.prefs_apply_counts[.Http_Cache] += 1 }
	if .Touch in groups { touch_devices_apply(app) }

	page.settings_destroy(&app.page_settings)
	app.page_settings = page.settings_from_prefs(&app.prefs)
	app.page_settings.internal_address = is_builtin_href
	for tab in tabs_all(app) { if tab.page != nil { page.configure_styles(tab.page) } }

	delete(app.cfg.homepage)
	delete(app.cfg.ui_theme)
	app.cfg = settings_from_prefs(&app.prefs)
	memory_trim_settings(app, &app.prefs)   // memory_trim.odin
	app.show_console = app.cfg.show_console
	if .Downloads in groups { downloads_apply(app); app.prefs_apply_counts[.Downloads] += 1 }
	app.loop.timer_slice_ns = i64(app.cfg.timer_slice_ms * 1e6)
	arm_autosave(app)
	request_frames(app, 3)
}

on_pref_change :: proc(user: rawptr, name: string, p: ^config.Prefs) {
	if shell_defer({kind = .Prefs}) { return }   // (shell_frames.odin: pages' settings are not replaced under a running page)
	apply_prefs((^App)(user), name)
}
////////////////////////////////
// Loop

// The interface's theme as asked (browser.ui.theme, browser.ui.theme_mode).
chrome_theme_choice :: proc(app: ^App) -> ui.Theme_Choice {
	// (the machined style is the toolkit's machined finish: its widgets bevelled, its fields sunken; chrome_style.odin)
	machined := machined_on(app)
	return {name = app.cfg.ui_theme, mode = app.cfg.ui_theme_mode, finish = machined ? .Machined : .Flat, glow = machined && app.chrome_cfg.glow ? 1 : 0}
}

// The palette of the interface's theme, in the version its mode shows now (the first theme for a name that is none).
chrome_palette :: proc(app: ^App) -> ui.Palette {
	c := chrome_theme_choice(app)
	def, _, ok := ui.theme_find(ui.THEMES[:], c.name)
	if !ok { def = ui.THEMES[0] }
	return ui.theme_palette(def, ui.theme_wants_light(c.mode), c.finish)
}

// The chrome's theme shown (ui.theme_show: applied when the choice, the system's light or dark or the blend space
// changed), and the base style of its boxes: every frame, full or chrome only.
chrome_frame_style :: proc(app: ^App) -> ui.Style {
	wnd := active_window(app)
	if ui.theme_show(&app.theme, ui.THEMES[:], chrome_theme_choice(app), &app.theme_shown, render.blend_space(&app.r)) { app.chrome_pal = chrome_palette(app) }
	pal := app.chrome_pal
	platform.set_dark_title(wnd.win, !app.theme_shown.light)
	// the system's frame line is half transparent along the top of an integrated title bar: the palette's, opaque
	platform.set_border_color(wnd.win, platform.is_integrated_title(wnd.win) ? Maybe(u32)(pal.border >> 8) : nil)
	return ui.Style{
		pref = {.X = ui.text_size(), .Y = ui.px(36)},
		font = app.ui_font, font_size = app.cfg.ui_font_size, text_pad = 7,
		cursor = .Arrow,
	}
}

// The loop's network completions, timers and posted tasks that are ready, run by the first frame of a pass (in its wait for
// its slot, else in its page phase). A callback that works for a page (host.Task.work) draws its page's window: by itself
// (a frame there, for what it may have changed), and what it asks of the frames goes there (request_frames). The browser's
// own work, and a page that is no tab's, may concern any window: what they ask goes to every window (windows.odin
// windows_spill). Returns how many ran that draw something in the active window.
frame_tasks :: proc(app: ^App) -> int {
	wnd := active_window(app)
	asked := wnd.frames_requested
	was_running, was_own := app.tasks_running, app.task_own
	app.tasks_running, app.task_own = true, 0
	host.run_ready(&app.loop)
	app.tasks_running = was_running
	host.quiet_take(&app.loop)   // (a media player's notices draw nothing: its pictures come on their own timer)
	browser, pages := host.ran_take(&app.loop)
	ran := browser
	if browser > 0 { window_request(app, wnd, 2) }
	for id in pages {
		w := window_of_page_work(app, id)
		if w == nil {
			ran += 1
			window_request(app, wnd, 2)   // (whose it is is not known: every window, as the browser's)
		} else if w == wnd {
			ran += 1
			app.task_own = max(app.task_own, 2)
		} else {
			window_request(app, w, 2)
		}
	}
	images_shell_frame(app)
	if wnd.frames_requested > asked { windows_spill(app, wnd.frames_requested) }
	if app.task_own > 0 { window_request(app, wnd, app.task_own) }   // (after the spill: its page's own)
	app.task_own = was_own
	return ran
}

// `causes`: what the loop knew of when it decided on this frame (windows_pass; the system's loop: its repaint); `idled`: it slept before
// it, or this window had no cause. What the turn's tasks and events add is looked at here: nothing at all, and no frame is made.
frame :: proc(app: ^App, idled := false, causes: Frame_Causes = {.Repaint}) {
	// (windows.odin: the frame gate. A frame made by a loop of the system inside another frame's poll puts back that one's
	// stage. The callers ask the gate first: a refusal here would be a frame asked for where none may begin.)
	gate := platform.frame_gate()
	gate_token, admitted := platform.frame_gate_begin(gate, .Full)
	if !admitted { active_window(app).win.paint_requested = true; return }
	wnd := active_window(app)   // (the window the frame is for, all along: a loop of the system's frame puts it back)
	defer {
		platform.frame_gate_end(gate, gate_token)
		window_chrome_after_frame(app)   // the system menu, outside the frame (its loop paints the window)
	}
	prof_frame_begin()
	prof_begin(.Wait)
	pacer_update(app)
	pacer_wait(app, idled)   // pacing.odin: the frame's time slot, then the swap chain (input is taken meanwhile)
	prof_end(.Wait)
	prof_begin(.Events)
	events := platform.poll_events(active_window(app).win, false)
	tab_scale_follow(app, current_tab(app))   // zoom.odin: the window changed monitor, or the tab came from a window of another scale
	platform.frame_gate_stage(gate, .Work)   // the page phase (chrome frames may be made in it: shell_frames.odin)
	// back from another window (the Windows settings, say): the desktop integration may have changed there
	for e in events {
		if e.kind == .Activate { desktop_note_activate() }
		// the window the user is in is the one the process acts on outside a frame (windows.odin)
		if (e.kind == .Activate && active_window(app).win.active) || e.kind == .Mouse_Press || e.kind == .Key_Press { window_set_front(app, app.active) }
	}
	shell_actions_run(app)   // shell_frames.odin: what the last build asked of the list of tabs (a tab closed, a tab out of its bar)
	tab_drag_events(app, events)   // tab_drag.odin: a tab carried by this window's press
	remote_record_events(app, events)   // remote_extras.odin: a recording of the input, when one runs
	notification_events(app, events)   // notification_shell.odin: a click on a page's notification, its end
	events = shell_frame_begin(app, events)   // shell_frames.odin: input held back by chrome frames first; the page phase
	pacer_begin_frame(app, events)
	if len(events) > 0 { request_frames(app, 4) }
	vault_shell_activity(app, events)   // vault_shell.odin: a key or the pointer postpones the Vault's idle lock
	prof_end(.Events)

	// network completions, timers and posted tasks run here, on the UI thread, unless the frame ran them as it waited for its slot
	prof_begin(.Loop)
	ran := wnd.pacer.ran
	if app.pass_first {
		app.pass_first = false
		if !wnd.pacer.tasks_run { ran += frame_tasks(app) }   // (what came after the wait's own run: the next frame's wait)
	}
	events = shell_after_loop(app, events)   // (chrome frames made under the loop's scripts took the chrome's input)
	// a window whose last tab just left (a move: the window closes at the end of the pass) has nothing to build
	if len(wnd.tabs) == 0 && len(app.windows) > 1 {
		shell_page_phase_end(app, nil)
		free_all(context.temp_allocator)
		return
	}
	prof_end(.Loop)
	// a wake that brought nothing (a timer of the system for the window, a message of no consequence): no frame. (It
	// was one, and the status bar counted it, and armed its settle wake again: two frames every half second, forever.)
	// (a timed wake of the toolkit's, a caret blink or a tooltip delay, always draws)
	// (callbacks that changed nothing are `quiet` and not counted in `ran`: the page may still have changed meanwhile, or want a frame)
	page_wants_frame := false
	if t := current_tab(app); t != nil && t.page != nil {
		page_wants_frame = t.layout.mutations != t.page.doc.mutations || page.wants_animation_frame(t.page) || page.animations_active(t.page)
	}
	why := causes
	if len(events) > 0 { why += {.Input} }
	if ran > 0 { why += {.Task} }
	if page_wants_frame { why += {.Page} }
	if wnd.frames_requested != 0 { why += {.Asked} }
	if ui.needs_frame(wnd.ui) { why += {.Interface_Animation} }
	if ui.wake_due(wnd.ui) { why += {.Interface_Wake} }
	if platform.take_paint_request(wnd.win) { why += {.Repaint} }
	if (idled && why == {}) || resize_echo_frame(app, events, ran, page_wants_frame) {   // (pacing.odin: a copy of a resize step's picture is not presented)
		shell_page_phase_end(app, nil)
		free_all(context.temp_allocator)
		return
	}
	loop_rates_frame(&app.rates, why, .Task in why ? app.loop.last_ran : wnd.asked_by, loop_ms(app, time.tick_now()))
	// a frame on an errand, or for a timed wake of the toolkit (a caret of the interface, a tooltip), is no activity: the browser stays at rest
	// (the memory given back, the status bar's numbers at 0)
	if why != {.Asked} { wnd.errands = {} }
	if wnd.errands == {} && why != {.Interface_Wake} { memory_trim_active(app) } else { app.hud.settle_skip = true }   // memory_trim.odin; hud.odin: no sample
	forms_view(app).caret_painted = {}
	prof_begin(.Input)
	events = ext_popup_events(app, events)   // ext_popup.odin: an extension's open popup takes its keys and the pointer over it
	events = image_document_events(app, events)   // image_document_shell.odin: an image opened by itself takes its wheel, drags and keys
	page_cursor_events(app, events)   // page_cursor.odin: a press on the page keeps its cursor
	dnd_events(app, events)           // dnd_shell.odin: drags of other applications over the window
	route_page_input(app, events)
	events = forms_unconsumed_events(app, events)   // keys the page used do not reach the chrome
	events = history_tree_events(app, events)   // the wheel and zoom keys of about:history's tree (history_tree.odin)
	events = chrome_zoom_events(app, events)    // Ctrl+wheel and Ctrl +, -, 0 for the interface itself (chrome_zoom.odin)
	events = devtools_events(app, events)       // Ctrl+wheel and Ctrl +, -, 0 over the developer tools: their text size (devtools.odin)
	forms_shell_frame(app)
	selection_shell_frame(app)
	events = shell_after_input(app, events)   // (what is left is the chrome's: chrome frames from here on build with it)
	prof_end(.Input)

	fullscreen_shell_settle(app, app.active)   // the events of a change of full screen, before the frame's resize event (fullscreen_shell.odin)
	// page visibility, then the animation frame callbacks of the page about to be painted
	shown := active_window(app).win.size.x > 0 && active_window(app).win.size.y > 0
	for tab, i in wnd.tabs { if tab.page != nil { page.set_page_visible(tab.page, shown && i == wnd.current && tab.kind == .Web) } }
	// smooth scrolling moves the scrollers first: the scroll events of this frame (run_animation_frames) see where they
	// are painted
	if autoscroll_tick(app, current_tab(app)) { request_frames(app, 2) }   // page_autoscroll.odin: drives the scroller before smooth_tick samples it
	if smooth_tick(app, current_tab(app)) { request_frames(app, 2) }   // smooth_scroll.odin
	// from here to the end of the page phase the tab's styles and layout are this frame's: a script's reading lays out what this frame paints (js_layout_shell.odin)
	app.rendering = current_tab(app)
	// the frame's time (pacing.odin: its vblank) is the animation frame callbacks' timestamp and the CSS clock
	if t := current_tab(app); t != nil && t.page != nil && page.page_visible(t.page) {
		prof_begin(.Animation)
		page.run_animation_frames(t.page, wnd.pacer.frame_ms)
		prof_end(.Animation)
		// (the loop counts this frame off after it: 2 = this one and the next)
		if page.wants_animation_frame(t.page) { request_frames(app, 2) }
		if frames_tick(app, t, wnd.pacer.frame_ms) { request_frames(app, 2) }   // (frames_shell.odin)
	}
	fullscreen_shell_frame(app, app.active)   // a page's full screen ends with its tab being shown (fullscreen_shell.odin)
	page_update(app)   // page_frame.odin: styles and layout, in the page phase (chrome frames can be made meanwhile)
	ext_popup_frame(app)   // ext_popup.odin: the popup's animation frames, layout and size
	app.rendering = nil
	events = shell_page_phase_end(app, events)   // shell_frames.odin: the scroll and the actions of chrome frames, before the build
	platform.frame_gate_stage(gate, .Building)
	shell_snapshots_frame(app)

	render.resize(&app.r, active_window(app).win.size)
	size := draw.Vec2{f32(active_window(app).win.size.x), f32(active_window(app).win.size.y)}
	// (a program in this process makes frames as fast as it asks for them: the interface's animations go by frames of the usual length, so that what a barrier waits for ends in a few of them, the same way each time)
	dt := frame_seconds(app)

	base_style := chrome_frame_style(app)
	window_chrome_frame(app)   // window_chrome.odin
	prof_begin(.Build_UI)
	chrome_ui_apply(app, active_window(app).ui)
	ui.begin_build(active_window(app).ui, {
		window_size = size, events = events, dt = dt, animations = os_animations_enabled(app),
		dpi_scale = ui_scale_of(app), base = base_style, clipboard_set = ui.window_clipboard_set,
		disable_zoom = true,   // Ctrl+Plus / Minus / 0 and Ctrl+wheel zoom the page (zoom.odin), not the chrome
		window = active_window(app).win, frame_ms = wnd.pacer.frame_ms,   // the integrated title bar's regions; scroll animations on the vblank clock
		inactive = !window_is_front(app),   // a window in the back shows no caret in its fields (windows.odin)
	})
	build_ui(app)
	instance_frame(app)   // instance_shell.odin: the notice of a first Wren that did not answer
	remote_notice(app)   // remote_shell.odin: the notice of a remote channel that did not start
	ui.end_build()
	page_a11y_frame(app)   // a11y_page.odin: the page's tree, after the chrome's that grafts it
	prof_end(.Build_UI)
	window_cursor_apply(app)   // page_cursor.odin: the page's cursor over the page, else the chrome's
	if ui.needs_frame(active_window(app).ui) { request_frames(app, 2) }
	if t := current_tab(app); t != nil && t.page != nil && t.layout.mutations != t.page.doc.mutations { request_frames(app, 2) }
	if t := current_tab(app); t != nil && t.page != nil && page.animations_active(t.page) { request_frames(app, 2) }   // CSS animations: later changes wake the loop by timer

	shell_before_draw(app)   // (a chrome frame used the screen's slot)
	platform.frame_gate_stage(gate, .Drawing)
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, {0, 0, 0, 1})
	prof_begin(.UI_Draw)
	// (the toolkit's automatic damage: each box is compared with its last frame; the page, replayed, is drawn every frame)
	ui.set_partial_redraw(active_window(app).ui, app.cfg.partial_redraw && !pixels_skipped(app))   // (headless_pixels.odin: its damage would be drawn)
	ui.draw_tree(active_window(app).ui, &app.dc)
	dnd_paint(app, &app.dc)   // dnd_image.odin: the picture of a drag from the page, over everything
	autoscroll_paint(app, &app.dc)   // page_autoscroll.odin: the autoscroll anchor marker, over everything
	prof_end(.UI_Draw)
	// nothing asked for more since (window_request cleared it), the caret is where it was, and the status bar is what this window last drew: only the caret's pixels are drawn
	// again. (A frame's GPU time lands frames later, and another window's frames make samples too. Such a frame is whole, and no sample: it brings no more of them.)
	own := &wnd.own
	if caret := forms_view(app).caret_painted; wnd.errands == {.Caret} && caret.exact && own.status_drawn == app.hud.changes {
		draw.damage_begin(&app.dc)
		draw.damage(&app.dc, caret.at)
	}
	own.status_drawn = app.hud.changes
	pixels_skip_frame(app)   // headless_pixels.odin: a test that reads no pixel
	prof_begin(.Submit)
	draw.end_frame(&app.dc)   // GPU time: the renderer's timestamp queries around its submit (hud.odin, prof.odin)
	prof_end(.Submit)
	prof_begin(.Present)
	platform.frame_gate_stage(gate, .Presenting)
	remote_capture_arm(app)   // remote_shell.odin: a capture of this window
	render.frame_end(&app.r, !pacer_at_once(app))   // a resize step, the frames right after it, or an input frame are shown at once
	wnd.presented = true
	prof_end(.Present)
	frame_log_presented(app, pacer_at_once(app))
	pacer_end_frame(app)
	{
		items, nodes := 0, 0
		if t := current_tab(app); t != nil && t.page != nil { items, nodes = len(t.layout.items), t.page.doc.nodes.count }
		prof_frame_end(app, items, nodes)
	}
	free_all(context.temp_allocator)
}

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
	host.thread_temp_hot()
	host.main_stack_ensure()   // (Linux: main_stack_linux.odin)
	host.thread_raise_interface()   // above the browser's background threads (host.Thread_Priority)
	host.thread_name_self("wren-window")   // (what profilers and debuggers show)
	base.spans_start()   // (WREN_SPANS)
	base.test_world_from_env()   // (WREN_TEST_WORLD)
	net.record_from_env()   // (WREN_TEST_RECORD)
	trace_start()   // prof.odin: Tracy, ETW, when built in
	prof_mark(.Main)
	// (UTF-8 from the UTF-16 command line: os.args is the C runtime's ANSI)
	app := app_start(process.command_line_args(base.permanent_allocator()))
	if app == nil { return }
	host.shutdown_stacks_program = process.executable_path(base.permanent_allocator())   // (`wren ctl stacks`: a teardown that hangs says where)
	for app_turn(app) {}
	app_stop(app, process_ends = true)
	host.process_end(remote_exit_code)   // (at once: unloading the system's libraries takes longer than the whole teardown, and leaves nothing done)
}

// One browser in this process, on this thread: what its command line says, up to the first frame. nil: it could not start (said on the
// console). The program's main and the end-to-end tests (src/e2e) come through here; a browser needs app_turn to go on and app_stop to end.
// A headless window draws on the system's software rasterizer, whatever GPU the machine has: set by a program in this process before app_start, for a test
// (e2e.Options.software) of what shows only there, where a frame's GPU time is many times longer.
@(thread_local)
headless_software: bool   // (read once, by the app_start of this thread)

app_start :: proc(args: []string) -> ^App {
	app := app_make()   // app_make.odin: the stages of the App, shared with the tests and the chrome world
	frame_gate_init()   // windows.odin: the frames of this thread, one state machine
	platform.dragdrop_thread_init()   // OLE on this thread before any decoder joins it to the multithreaded apartment (dnd_shell.odin)

	// --- configuration: defaults < profile file < command line < policy file ---
	// `wren ctl ...`: the remote control client, before anything else is set up (no profile opened, no window, no GPU, no
	// script engine): only as the first argument (a file or host named ctl is written ./ctl)
	if len(args) > 0 && args[0] == "ctl" { os.exit(ctl_main(args[1:])) }
	// `wren --version`, `wren version`, `wren --help`, `wren help` (cli_usage.odin): said on the console, nothing else is set up
	if info := cli_info_of(args); info != .None { process.console_write(cli_info_text(info)); os.exit(0) }
	host.phase("arguments and preferences")
	// `--open-url wren-https://...` (what a link of a web page runs) and the links among the arguments: addresses from here on, or nothing opens (desktop/links.odin)
	linked, link_err := wren_desktop.links_in_args(args, {desktop_link_prefix(), wren_desktop.LINK_PREFIX})
	if link_err != .None { process.console_write(fmt.tprintf("refused: %s\n", wren_desktop.link_error_text(link_err))); os.exit(wren_desktop.LINK_REFUSED_EXIT) }
	profile_override, a1 := extract_flag(linked[:], "--profile")
	policy_file, a2 := extract_flag(a1[:], "--policy")
	purge_requested, a2b := extract_switch(a2[:], "--purge")   // with --uninstall: also delete the profile (desktop_shell.odin)
	cli_mode, a3, cli_bad := desktop.parse_cli(desktop_identity(), a2b[:])   // --desktop-integration=install|remove|status|uninstall, --uninstall (desktop_shell.odin)
	setup_requested, a4 := extract_switch(a3[:], "--setup")   // opens the Setup dialog (setup.odin)
	new_window, a5 := extract_switch(a4[:], "--new-window")   // a window of its own, not a tab of the Wren that runs (instance_shell.odin)
	no_single, a6 := extract_switch(a5[:], "--no-single-instance")
	remote_asked, remote_name, a7 := extract_remote(a6[:])   // --remote[=name]: the remote control channel (remote_shell.odin)
	hidden_mode, a7h := extract_switch(a7[:], "--hidden")   // a window that is made but never shown (UI Automation, the system's hit test and the remote channel still see it): `wren ctl start`
	headless_mode, a8p := extract_switch(a7h[:], "--headless")   // the window is never shown (it renders all the same: remote captures read the frame)
	private_mode, a8 := extract_switch(a8p[:], "--private")   // private browsing: a profile of its own, gone at the end (private_browsing.odin)
	// a system where no window exists unseen (Wayland, X11): a hidden Wren is a headless one, or `wren ctl start` would put a
	// window on the user's desktop
	if hidden_mode && !platform.can_hide_windows() { hidden_mode, headless_mode = false, true }
	cdp_port, cdp_have_port, cdp_address, a9 := cdp_extract_args(a8[:])   // --remote-debugging-port[=N] / --remote-debugging-address (cdp.odin)
	app_prefs_begin(app)
	rest, arg_errors := config.apply_args(&app.prefs, a9[:], context.temp_allocator)   // (read before the first frame)
	cfg_dir := platform.user_dir(.Config, "", context.temp_allocator)
	portable_dir := profile_override == "" ? portable_profile_dir() : ""   // a copy with wren.portable beside it keeps its profile beside it (setup.odin)
	app.portable = portable_dir != ""
	app.profile_dir = strings.clone(profile_override != "" ? profile_override : (app.portable ? portable_dir : (cfg_dir == "" ? "build/profile" : strings.concatenate({cfg_dir, "/", APP_NAME}, context.temp_allocator))))
	if private_mode {
		// a profile of its own in the temporary folder, with the user's settings copied in (private_browsing.odin)
		if dir := private_profile_make(app.profile_dir); dir != "" {
			delete(app.profile_dir)
			app.profile_dir = dir
			app.private = true
			no_single = true
		}
	}
	_ = os.make_directory_all(app.profile_dir)
	net.user_agent_product = "Wren/" + APP_VERSION
	crashtrace.set_report_dir(strings.concatenate({app.profile_dir, "/crashes"}, context.temp_allocator), fmt.tprintf("%s %s (%s %s)", APP_NAME, APP_VERSION, app_commit(), APP_COMMIT_DATE))
	_, _, prefs_file := profile_paths(app)
	config.load_file(&app.prefs, prefs_file, .User)
	if policy_file == "" { policy_file = default_policy_file(process.executable_path(context.temp_allocator)) }   // beside the program, not in the working directory (policy_file.odin)
	if policy_file != "" { config.load_file(&app.prefs, policy_file, .Policy) }
	app_prefs_register(app)   // (and a private Wren's own values)
	app_settings_read(app)
	prof_mark(.Prefs)
	if cli_bad != "" { process.console_write(fmt.tprintf("--desktop-integration: unknown mode %q (install, remove, status or uninstall)\n", cli_bad)); os.exit(2) }
	// `ctl` as an address is nearly always `wren ctl ...` meant for the remote control client that did not run as such (an option before it:
	// `ctl` is only the first argument; or a wren.exe from before the client existed): it would open https://ctl, and in the user's Wren, not here
	if len(rest) > 0 && is_info_word(rest[0]) {
		process.console_write(fmt.tprintf("`%s` is a command only as the first argument (wren ctl <command>, wren help, wren version). To open a file or host named %s, write ./%s\n", rest[0], rest[0], rest[0]))
		os.exit(2)
	}
	if cli_mode != .None { os.exit(desktop_cli(app, cli_mode, purge_requested)) }   // no window: a script's call
	host.phase("instance_early")
	instance_early(app, rest[:], setup_requested, new_window || no_single, remote_asked || headless_mode || hidden_mode || cdp_have_port)   // (a driven window is its own: it never hands its addresses to the user's Wren)   // instance_shell.odin: a second start hands over to the first and ends here
	desktop_early_init()   // the windows' AppUserModelID, before the first one exists
	recovery_start(app)   // crash_recovery.odin: how the last run ended, and this run's marker

	// Start-up order: the renderer's start-up is by far the longest step, and most of it is the graphics device (the
	// driver's first load in the process). The device is made on a thread of its own from here (render.preload_device:
	// what render.init_window / init_offscreen take below, waiting for it if it is not ready); the swap chain needs the
	// window and is made there. Beside it, fonts on a thread of their own (fonts_preload_start), then the network, the
	// page machinery and the first navigation, whose loads run on their own threads meanwhile.
	host.phase("device and fonts started")
	_ = render.preload_device(warp = headless_mode && headless_software)   // (the kind of device the renderer asks for below)
	app_fonts_init(app)
	preload := fonts_preload_start(app)   // the font state is the preload thread's until fonts_preload_finish
	app.headless = headless_mode
	app.hidden = hidden_mode
	host.phase("window")
	first_window: ^platform.Window
	if headless_mode {
		// a real headless window: no HWND at all, so it works with no desktop session (a service, SSH, CI). It renders to an
		// offscreen target the capture reads. The size and the DPI are physical pixels at the emulated scale (window --size /
		// --dpi, or a remote client's setDeviceMetricsOverride, resize it). The scale is browser.ui.scale (0: no display to
		// follow, so 1).
		scale := f32(config.float_of(&app.prefs, "browser.ui.scale"))
		if scale <= 0 { scale = 1 }
		first_window = platform.open_window_offscreen(APP_NAME, {int(1280 * scale + 0.5), int(800 * scale + 0.5)}, dpi_scale = scale)
	} else {
		first_window = platform.open_window(APP_NAME, {1280, 800}, transparent = config.bool_of(&app.prefs, "browser.window.fixed_surface"), integrated_title = config.bool_of(&app.prefs, "browser.window.integrated_titlebar"))
	}
	if first_window == nil { fmt.eprintln("cannot open the window"); return nil }
	window_adopt_primary(app, first_window)   // windows.odin: the window the App's per-window fields are about
	prof_mark(.Window)

	host.phase("loop, network, cache, blocker")
	app_loop_init(app, wake_window, app)   // (any thread wakes it: the App is its user)
	instance_begin(app)   // instance_shell.odin: the window that takes the second starts' addresses
	app.loop.timer_slice_ns = i64(app.cfg.timer_slice_ms * 1e6)
	appearance_init(app)   // before any settings are derived: `system` colors, auto color scheme
	ns := net.settings_from_prefs(&app.prefs)
	if !net.client_init(&app.client, &app.loop, ns) { fmt.eprintln("network init failed"); return nil }
	net.settings_destroy(&ns)
	app_pools_init(app, app.cfg.blocking_threads)
	host.dialogs_init(&app.dialogs, &app.loop)
	app.profile = fetch.profile_make(fetch.settings_from_prefs(&app.prefs), cookies.settings_from_prefs(&app.prefs))
	http_cache_start(app)   // http_cache_ui.odin: the profile's HTTP cache (its index loads on a thread meanwhile)
	fetch.loader_init(&app.loader, &app.loop, &app.client, &app.blocking, &app.profile)
	blocker_start(app)   // blocker_shell.odin: the content blocker listens to the loader from here on
	host.phase("storage")
	page.storage_manager_init(&app.storage, &app.loop, &app.blocking, app.cfg.persist_profile ? app.profile_dir : "", &app.writer)
	app.page_settings = page.settings_from_prefs(&app.prefs)
	app.page_settings.internal_address = is_builtin_href
	host.phase("script runtime")
	if !process_share_join(app) { fmt.eprintln("wasm runtime init failed"); return nil }   // process_share.odin: the Wasm engine, the bytecode cache... (the first App sets them up)
	app.process = base.scope_make("process")
	app.config_view.rows = make(map[string]^Row_State)
	history_settings_init(app)   // history_settings.odin: before the first tab
	global_history_init(app)
	bookmarks_init(app)   // bookmarks.odin
	app.show_console = app.cfg.show_console

	host.phase("profile_load")
	profile_load(app)
	config.watch(&app.prefs, "", on_pref_change, app)
	arm_autosave(app)
	vault_shell_init(app)   // vault_shell.odin: the Vault (off unless vault.enabled; its helper starts only at a login or an unlock)

	// the first tab: the address given on the command line, else the homepage
	prof_mark(.Shell)
	host.phase("first tab")
	address := len(rest) > 0 ? command_line_address(rest[0]) : ""   // (a relative path of a file or folder: local_paths.odin)
	prof_mark(.Navigation)
	if !recovery_open(app, rest[:]) {   // crash_recovery.odin: the tabs of a session that ended abnormally (the command line's addresses follow them)
		if !(len(rest) == 0 && session_restore(app)) {   // session.odin
			app.closed.session_waits = true   // (Ctrl+Shift+T brings it back: closed_tabs.odin)
			pinned_restore(app)   // (the pinned tabs come back without the session: browser.tabs.restore_pinned)
			tab_open(app, address, origin = .User)
		}
		if len(rest) > 1 {   // (an address each: the first is the first tab, the others follow it, as a second start's would)
			for a in rest[1:] { tab_open(app, command_line_address(a), origin = .User) }
			wnd := active_window(app)
			wnd.current = len(wnd.tabs) - len(rest)
		}
	}
	for e in arg_errors { tab_log(current_tab(app), .Warn, e) }
	host.phase("remote, desktop watch, setup, update")
	remote_start(app, remote_asked, remote_name)   // remote_shell.odin: the pipe, when asked for   // (tab_log keeps its copy)
	cdp_start(app, cdp_port, cdp_have_port, cdp_address)   // cdp.odin: the CDP / WebDriver BiDi WebSocket, when asked for
	desktop_watch_begin(app, profile_override != "")   // desktop_shell.odin: the system tells when the integration changes (the box in about:config and the Setup dialog follow it)
	setup_startup(app, profile_override != "", setup_requested)   // setup.odin: a copy that is not the installed one is offered Setup; --setup opens it
	update_startup(app, profile_override != "")   // update_check.odin: the daily check, when it is on and due

	host.phase("renderer")   // (the device made early, then the swap chain or the offscreen target)
	app.r.swap_buffers = int(config.int_of(&app.prefs, "browser.frame.swap_buffers"))   // pacing.odin
	fixed_surface := config.bool_of(&app.prefs, "browser.window.fixed_surface")
	if headless_mode {
		// no window: the renderer draws into an offscreen target of the window's size. Captures read it (render.capture_*,
		// on both backends). It resizes with the window (window_resize_offscreen).
		if !render.init_offscreen(&app.r, active_window(app).win.size, warp = headless_software) { fonts_preload_finish(app, preload); fmt.eprintln("offscreen renderer init failed"); return nil }
	} else {
		if !render.init_window(&app.r, active_window(app).win, active_window(app).win.size, transparent = fixed_surface) { fonts_preload_finish(app, preload); fmt.eprintln("renderer init failed"); return nil }
	}
	fixed_size: [2]int
	if !headless_mode { fixed_size = fixed_surface_size(app, active_window(app).win) }
	if fixed_size.x > 0 {
		// one surface, the monitor's size: the window shows its top-left part, 1:1, and keeps it while it is resized
		// (browser.window.fixed_surface; render.set_fixed_surface; the developer tools' window does the same)
		render.set_fixed_surface(&app.r, fixed_size)
	}
	render.set_teardown_wait(&app.r, int(config.int_of(&app.prefs, "browser.shell.shutdown_surface_wait_ms")))   // (see the preference: the compositor may be slow to let go of the surface)
	prof_mark(.Renderer)
	host.phase("fonts finish")
	if !fonts_preload_finish(app, preload) { fmt.eprintln("cannot load the UI or icon font"); return nil }
	prof_mark(.UI_Fonts)
	host.phase("draw, ui, page render, shells")
	app_draw_init(app)
	draw.set_partial_redraw(&app.dc, true)   // a frame that marks a region draws only that (a caret's toggle: frame()); others are whole
	app_ui_init(app)
	chrome_a11y_init()   // (what screen readers call the caption buttons: a11y_chrome.odin)
	page_render_init(app)
	first_paint_init(app)
	interaction_init(app)
	fonts_preload_adopt(&app.page_render.fonts, preload)
	fonts_color_start(app)
	images_shell_init(app)
	canvas_shell_init(app)
	images_set_texture_api(renderer_texture_api(app))
	canvas_gpu_init(app)
	set_content_painter(forms_content_painter, app)
	app.page_render.bare = forms_bare_control
	frames_shell_init(app)   // frames_shell.odin: nested documents laid out, painted and given input

	host.phase("pacer and shells")
	prof_init(app)
	pacer_init(app)
	shell_frames_init(app)   // shell_frames.odin: chrome frames while a page holds the thread
	smooth_init(app)
	autoscroll_init(app)   // page_autoscroll.odin (syncs every window's toolkit regions)
	autoscroll_toolkit_setup(app, active_window(app).ui)
	page_cursor_init(app)
	app_interface_init(app)   // app_make.odin: the window's chrome, its style, the tabs' icons, the status bar, the developer tools, the address bar
	art_init(app)   // newtab_art.odin: the artistic new tab (no network until the first art new tab is shown)
	downloads_init(app)   // download.odin
	webauthn_shell_init(app)   // webauthn_shell.odin
	fullscreen_shell_init(app)   // fullscreen_shell.odin: the Fullscreen API
	sw_shell_init(app)   // sw_shell.odin: clients.openWindow, WindowClient.focus
	fs_shell_init(app)   // fs_shell.odin: file pickers and file permission prompts
	notification_shell_init(app)   // notification_shell.odin: system notifications of pages
	ext_shell_start(app)   // ext_shell.odin: browser extensions (their list and packages load off the loop thread)
	storage_access_shell_init(app)
	clipboard_js_init(app)   // clipboard_win.odin: navigator.clipboard
	drop_files_init(app)   // local_paths.odin
	app_commands_init(app)   // app_commands.odin: the mouse's back / forward buttons
	host.phase("first windows")
	app.last_tick = time.tick_now()
	active_window(app).frames_requested = 4
	active_window(app).win.on_frame = window_on_frame   // (shell_frames.odin: a chrome frame when the page holds the thread)
	if windows_shown(app) { window_show(app.active) }
	session_open_other_windows(app)   // session.odin: the other windows of a restored session
	prof_mark(.Loop)
	host.phase("loop")
	return app
}

// One turn of the browser's loop: the frames of the windows that have a cause (it sleeps until one has, or a task or timer is due).
// false: it has been told to end (app_stop next).
app_turn :: proc(app: ^App) -> bool {
	if !windows_pass(app) { return false }   // windows.odin: a frame for each window that has a cause (devtools_window_tick for the front one)
	memcheck_drive(app)   // memcheck.odin: the check build's script, if any
	memory_trim_tick(app)   // memory_trim.odin
	remote_after_frame(app)   // remote_shell.odin: the waits of remote commands
	return true
}

// The browser ends: what it keeps is written, everything it holds is let go, the renderer's device above all, here and under the watchdog. A
// process that ends holding its device leaves that to the system, inside the end of the process, where nothing can hurry or end it: with
// every core busy the process stayed there 6 to 15 s (a `wren ctl quit` that waits for it, past 20 s), against 40 ms once it had let go.
// `process_ends`: the process ends right after this.
app_stop :: proc(app: ^App, process_ends := false) {
	profile_dir := strings.clone(app.profile_dir, context.temp_allocator)
	// closed means gone from the screen at once, whatever the teardown below takes (a headless window has no surface anyway)
	native_hide_all(app)   // shell_native_*.odin
	windows_shutdown_begin(app)   // windows.odin: the other windows give up their own state
	host.shutdown_begin(strings.concatenate({app.profile_dir, "/shutdown.log"}, context.temp_allocator), int(config.int_of(&app.prefs, "browser.shell.shutdown_warn_ms")), int(config.int_of(&app.prefs, "browser.shell.shutdown_force_ms")))   // shutdown.odin (host): names what the teardown waits for
	host.shutdown_step("remote_stop")
	cdp_stop(app)      // cdp.odin: the CDP / BiDi WebSocket server and its clients
	remote_stop(app)   // remote_shell.odin: the pipe and its clients
	host.shutdown_step("instance_end")
	instance_end(app)   // instance_shell.odin: later starts are told to wait, then the profile is free
	host.shutdown_step("prof_report")
	prof_report(app)
	wasm.host_profile_write()   // (WREN_HOST_PROFILE: before the pages are freed; the runtime's end writes it again)
	base.spans_write()
	host.shutdown_step("desktop_shell_shutdown")
	desktop_shell_shutdown(app)   // desktop_shell.odin: a job still out finishes
	host.shutdown_step("shell_frames_destroy")
	shell_frames_destroy(app)   // (no chrome frame from here on: the pages' last scripts run unpreempted)
	fullscreen_shell_destroy(app)   // (the pages closing below do not restore a window that is going away)
	sw_shell_destroy(app)
	fs_shell_destroy(app)
	notification_shell_destroy(app)
	ext_shell_stop(app)   // ext_shell.odin: backgrounds stopped, storage written (before the pages and the service workers go)
	delete(app.qr_url); app.qr_url = ""
	storage_access_shell_destroy(app)
	host.shutdown_step("vault_shell_destroy")
	vault_shell_destroy(app)   // vault_shell.odin: a helper still at work is stopped (it holds keys: it never outlives the browser)
	host.shutdown_step("session capture")
	for t in tabs_all(app) { entry_capture_current(app, t); cache_prof_leave(t) }   // the session keeps where each tab was
	host.shutdown_step("profile_save")
	profile_save(app, force = true)
	host.shutdown_step("recovery_end")
	recovery_end(app)   // crash_recovery.odin: a normal end removes the marker and the snapshot
	host.shutdown_step("bfcache_shutdown")
	bfcache_shutdown(app)
	host.shutdown_step("tab_free")
	// (out of the strips first, as a tab closed by hand: a request that ends with its tab looks the tabs up, net_observe)
	tabs := tabs_all(app)
	windows_forget_tabs(app)
	for t in tabs { tab_free(app, t) }   // (their session storage goes with the storage manager below)
	host.shutdown_step("urlbar_destroy")
	urlbar_destroy(app)   // urlbar.odin
	sidebar_destroy(&window_own(app).sidebar)   // tab_sidebar.odin
	status_cache_destroy(&window_own(app).status)   // status_bar.odin
	host.shutdown_step("global_history_shutdown")
	global_history_shutdown(app)
	host.shutdown_step("bookmarks_shutdown")
	bookmarks_shutdown(app)
	bookmarks_ui_destroy(app)
	confirm_destroy(app)
	host.shutdown_step("history_ui_destroy")
	history_ui_destroy()
	downloads_ui_destroy()
	host.shutdown_step("history_settings_shutdown")
	history_settings_shutdown(app)
	host.shutdown_step("base.scope_close")
	base.scope_close(app.process)   // every tab, page and request
	host.shutdown_step("frames_shell_destroy")
	frames_shell_destroy(app)   // (their views went with their documents)
	host.shutdown_step("webauthn_shell_destroy")
	clipboard_js_destroy(app)
	webauthn_shell_destroy(app)   // passkey requests: their threads joined
	host.shutdown_step("art_destroy")
	art_destroy(app)   // newtab_art.odin: its requests cancelled, its cache files kept (temporary folder)
	host.shutdown_step("favicons_destroy")
	favicons_destroy(app)
	system_icons_destroy(app)   // system_icons.odin
	host.shutdown_step("images_shell_destroy")
	images_shell_destroy(app)
	canvas_shell_destroy(app)
	host.shutdown_step("page.storage_manager_destroy")
	page.storage_manager_destroy(&app.storage)   // writes what is not saved yet
	host.shutdown_step("page.shutdown_threads")
	page.shutdown_threads()   // the App's style threads
	host.shutdown_step("page_thread_destroy")
	page_thread_destroy(app)   // page_thread.odin
	// what the pages' threads posted last (a worker's "exited", a link's drain): run now that every page is closed, so that it
	// frees what it owns instead of being dropped with the loop
	host.shutdown_step("host.loop_drain")
	host.loop_drain(&app.loop)
	host.shutdown_step("page.images_shutdown")
	page.images_shutdown()   // the App's image cache (the decoding threads are the process's)
	host.shutdown_step("blocker_stop")
	blocker_stop(app)   // after the pages are gone, before the loader
	host.shutdown_step("fetch.loader_destroy")
	fetch.loader_destroy(&app.loader)
	host.shutdown_step("page.timeline_shutdown")
	page.timeline_shutdown()   // the requests the performance timeline still describes (no more events once the loader is gone)
	host.shutdown_step("http_cache_stop")
	http_cache_stop(app)   // writes what is pending and the index
	host.shutdown_step("host.dialogs_destroy")
	host.dialogs_destroy(&app.dialogs)   // (a dialog still open is let go: nobody waits for its answer)
	host.shutdown_step("host.blocking_destroy")
	app_pools_end(app)
	host.shutdown_step("downloads_shutdown")
	downloads_shutdown(app)   // (no write or dialog of theirs is running any more)
	host.shutdown_step("net.client_destroy")
	net.client_destroy(&app.client)
	host.shutdown_step("fetch.profile_destroy")
	fetch.profile_destroy(&app.profile)
	host.shutdown_step("appearance_destroy")
	appearance_destroy(app)
	host.shutdown_step("hud_destroy")
	devtools_destroy(app)
	hud_destroy(app)
	host.shutdown_step("smooth_shutdown")
	smooth_shutdown(app)
	autoscroll_shutdown(app)   // page_autoscroll.odin
	host.shutdown_step("page_cursor_shutdown")
	page_cursor_shutdown(app)
	host.shutdown_step("drop_files_destroy")
	drop_files_destroy(app)
	host.shutdown_step("app_commands_destroy")
	app_commands_destroy(app)
	host.shutdown_step("window_chrome_destroy")
	window_chrome_destroy(app)
	chrome_style_destroy(app)
	app.made -= {.Interface}   // (its parts went one by one above, each where the teardown needs it; the command registry goes with the palette)
	host.shutdown_step("pacer_destroy")
	pacer_destroy(app)
	host.shutdown_step("font.set_color_ready_callback")
	font.set_color_ready_callback(&app.fonts, nil, nil)   // the color glyph thread no longer posts to the loop
	host.shutdown_step("page.compile_shutdown")
	page.compile_shutdown()   // the script compile threads post to the loop: stopped before it goes
	host.shutdown_step("page.discard_page_tasks")
	page.discard_page_tasks(&app.loop)   // the tasks of pages that were queued and never ran free their data
	host.shutdown_step("host.loop_destroy")
	app_loop_end(app)
	host.shutdown_step("page.frames_shutdown")
	page.frames_shutdown()   // the registry of navigables (every page is closed): a top-level page asks for its navigable on first use
	host.shutdown_step("page stores")
	page.cache_store_shutdown()   // the Cache API's index of every origin
	page.fs_store_shutdown()   // file system roots, open writables and sync handles, locks
	host.shutdown_step("process_share_leave")
	process_share_leave()   // process_share.odin: the last App lets go of the Wasm engine, the bytecode cache, the decoders, the layout threads
	host.shutdown_step("measure_destroy")
	measure_destroy(&app.measure)
	host.shutdown_step("forms_shell_destroy")
	forms_shell_destroy(forms_view(app))
	page_a11y_destroy(&window_own(app).a11y)
	host.shutdown_step("page_render_destroy")
	page_render_destroy()
	host.shutdown_step("config_view_destroy")
	config_view_destroy(&app.config_view)
	prefs_page.destroy(&app.settings_view)
	host.shutdown_step("interaction_destroy")
	interaction_destroy(app)
	host.shutdown_step("ui.field_destroy")
	address_destroy(&app.bare)   // (the windows' with their toolkit states: windows_destroy_ui)
	host.shutdown_step("console_eval_destroy")
	console_eval_destroy()
	host.shutdown_step("session_destroy")
	session_destroy(app)
	recovery_destroy()
	host.shutdown_step("palette_destroy")
	palette_destroy(app)   // palette.odin (and the command registry)
	host.shutdown_step("ui.destroy")
	app_ui_end(app)   // (the windows' toolkit states, the theme)
	host.shutdown_step("render.destroy")
	app_renderer_end(app)   // (the drawing context, the windows' swap chains, the renderer)
	host.shutdown_step("font.destroy")
	fonts_color_join(app)
	app_fonts_end(app)
	host.shutdown_step("platform.destroy_window")
	app_windows_end(app)
	page.settings_destroy(&app.page_settings)
	if app.private { base.remove_tree(app.profile_dir) }   // (a private Wren's profile goes with it)
	delete(app.profile_dir)
	app_free(app)   // app_make.odin: the preferences, and the App
	host.shutdown_step("instance_release")
	instance_release()   // instance_shell.odin: the profile is written and free: a start that waited becomes the owner (before the watchdog's stop, which can wait for its next tick)
	host.shutdown_step("shutdown_end")
	host.shutdown_end()
	if process_ends { memcheck_exit(profile_dir) }   // memcheck.odin: the leak report of the check build (a program that goes on after this reports once it has let go of its own: src/e2e)
	host.phase("exit")
}
