package browser

// Which subsystems a preference write configures again (apply_prefs, main.odin). Every write used to hand the network
// client, the HTTP cache and the downloads their settings again (the client re-examines its queues, the cache its
// limits): a drag of the tab sidebar's edge, which writes browser.tabs.sidebar_width at every step, did all that work
// for nothing. Each subsystem now only takes the writes of its own preferences; "" (an unknown or bulk change: a reset,
// the appearance of the system) still configures everything.

import "core:os"
import "core:strings"
import "wb:base"
import "wb:host"
import "wb:net"
import "wb:page"

Pref_Group :: enum u8 { Net, Http_Cache, Downloads, Touch }
Pref_Groups :: bit_set[Pref_Group; u8]

PREF_GROUPS_ALL :: Pref_Groups{.Net, .Http_Cache, .Downloads, .Touch}

// The subsystems a write of preference `name` concerns. Pure.
pref_groups_of :: proc(name: string) -> Pref_Groups {
	switch {
	case name == "": return PREF_GROUPS_ALL
	case strings.has_prefix(name, "network.cache."): return {.Http_Cache}
	case strings.has_prefix(name, "network."): return {.Net}
	case strings.has_prefix(name, "browser.download."): return {.Downloads}
	case name == "browser.touch.expose": return {.Touch}
	}
	return {}
}

// The network client's settings again (limits and timeouts at once; its queues are looked at again).
net_apply :: proc(app: ^App) {
	ns := net.settings_from_prefs(&app.prefs)
	net.client_apply(&app.client, ns)
	net.settings_destroy(&ns)
	app.prefs_apply_counts[.Net] += 1
}

////////////////////////////////
// User stylesheet cache (loaded once off the UI thread when style.user_stylesheet changes)

User_Stylesheet_Cache :: struct {
	path:   string,   // owned: path whose contents are in `css` or currently loading
	css:    string,   // owned: loaded stylesheet text
	serial: u64,      // bumped on each path change so stale loads are ignored
}

@(private = "file")
User_Stylesheet_Job :: struct {
	app:       ^App,
	path:      string,   // process_allocator
	css:       string,   // process_allocator
	max_bytes: int,
	serial:    u64,
}

@(private = "file")
user_stylesheet_work :: proc(data: rawptr) {
	j := (^User_Stylesheet_Job)(data)
	pa := base.process_allocator()
	raw, err := os.read_entire_file(j.path, pa)
	if err != nil { return }
	if len(raw) > j.max_bytes {
		delete(raw, pa)
		return
	}
	j.css = string(raw)
}

@(private = "file")
user_stylesheet_discard :: proc(data: rawptr) {
	j := (^User_Stylesheet_Job)(data)
	pa := base.process_allocator()
	delete(j.path, pa)
	delete(j.css, pa)
	free(j, pa)
}

@(private = "file")
user_stylesheet_done :: proc(data: rawptr) {
	j := (^User_Stylesheet_Job)(data)
	defer user_stylesheet_discard(j)
	app := j.app
	if j.serial != app.user_css.serial { return }
	delete(app.user_css.css)
	app.user_css.css = strings.clone(j.css)
	delete(app.page_settings.style.user_stylesheet_css)
	app.page_settings.style.user_stylesheet_css = strings.clone(app.user_css.css)
	for tab in tabs_all(app) {
		if tab.page != nil { page.configure_styles(tab.page) }
	}
	request_frames(app, 2)
}

// Ensures app.page_settings.style.user_stylesheet_css holds the cached text for style.user_stylesheet.
// Loads the file once on the blocking pool when the path changes so engine_reset_builtin_sheets never touches disk.
user_stylesheet_sync :: proc(app: ^App) {
	want := app.page_settings.style.user_stylesheet
	if want == "" {
		if app.user_css.path != "" || app.user_css.css != "" {
			delete(app.user_css.path); app.user_css.path = ""
			delete(app.user_css.css); app.user_css.css = ""
			app.user_css.serial += 1
		}
		return
	}
	if want == app.user_css.path {
		delete(app.page_settings.style.user_stylesheet_css)
		app.page_settings.style.user_stylesheet_css = strings.clone(app.user_css.css)
		return
	}
	delete(app.user_css.path)
	app.user_css.path = strings.clone(want)
	delete(app.user_css.css)
	app.user_css.css = ""
	app.user_css.serial += 1

	pa := base.process_allocator()
	job := new(User_Stylesheet_Job, pa)
	job^ = {
		app       = app,
		path      = strings.clone(want, pa),
		max_bytes = app.page_settings.style.max_sheet_bytes,
		serial    = app.user_css.serial,
	}
	if profile_pool_ready(app) {
		host.run_blocking(&app.blocking, user_stylesheet_work, user_stylesheet_done, job, user_stylesheet_discard)
	} else {
		user_stylesheet_work(job)
		user_stylesheet_done(job)
	}
}

user_stylesheet_destroy :: proc(app: ^App) {
	if .Loop in app.made {
		host.discard_posted(&app.loop, user_stylesheet_done, user_stylesheet_discard)
	}
	delete(app.user_css.path)
	delete(app.user_css.css)
	app.user_css = {}
}
