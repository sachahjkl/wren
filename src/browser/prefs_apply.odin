package browser

// Per-prefix preference bindings for the browser shell and its engine subsystems (config.bind / config.watch).
// Each subsystem follows only its own preference prefix instead of reconfiguring unrelated subsystems on every write.
// Changes that would replace page or fetch settings while a page holds the thread (shell_nested) are deferred to
// prefs_flush_deferred (shell_frames.odin).

import "core:os"
import "core:strings"
import config "toolkit:config"
import prefs_page "toolkit:prefs_page"
import "wb:base"
import "wb:cookies"
import "wb:fetch"
import "wb:host"
import "wb:net"
import "wb:page"

Pref_Group :: enum u8 { Net, Http_Cache, Downloads, Touch }

Pref_Deferred :: enum u8 { Net, Http_Cache, Fetch, Cookies, Page, Downloads, Touch }
Pref_Deferred_Set :: bit_set[Pref_Deferred; u8]

_ :: prefs_page   // used when UPDATES_SELF is true

// Binds every pure-data shell settings struct to its prefix once all definitions are registered (app_prefs_register).
// Runs without a loop, renderer, or window, so unit tests and early startup read typed structs directly.
app_prefs_bind_shell :: proc(app: ^App) {
	if app.shell_prefs_bound { return }
	app.shell_prefs_bound = true
	p := &app.prefs

	config.bind(p, "browser.", &app.cfg, settings_from_prefs, destroy = settings_destroy, on_change = on_shell_cfg_changed, user = app)
	on_cfg_extra :: proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		settings_destroy(&app.cfg)
		app.cfg = settings_from_prefs(p)
		on_shell_cfg_changed(user, name, p)
	}
	config.watch(p, "appearance.", on_cfg_extra, app)
	config.watch(p, "rendering.partial_redraw", on_cfg_extra, app)
	config.watch(p, "javascript.enabled", on_cfg_extra, app)
	config.watch(p, "wasm.wasmtime.compiler", on_cfg_extra, app)

	config.bind(p, "browser.memory.trim_idle_ms", &app.trim_state.idle_ms, trim_idle_ms_settings_from_prefs, on_change = proc(user: rawptr, name: string, p: ^config.Prefs) {
		(^App)(user).trim_state.active = shell_now_ns()
	}, user = app)
	app.trim_state.active = shell_now_ns()

	config.bind(p, "browser.session.", &app.session_cfg, session_settings_from_prefs)
	on_session_extra :: proc(user: rawptr, name: string, p: ^config.Prefs) { (^App)(user).session_cfg = session_settings_from_prefs(p) }
	config.watch(p, "browser.tabs.", on_session_extra, app)
	config.watch(p, "history.tree.max_nodes", on_session_extra, app)

	config.bind(p, "browser.dnd.", &app.dnd.cfg, dnd_settings_from_prefs)
	config.watch(p, "browser.drop.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		(^App)(user).dnd.cfg = dnd_settings_from_prefs(p)
	}, app)

	config.bind(p, "browser.touch.", &app.tsh.cfg, touch_settings_from_prefs, destroy = touch_settings_destroy)

	config.bind(p, "appearance.animations", &app.os_anim.cfg, os_anim_settings_from_prefs)
	config.watch(p, "browser.ui.os_settings_refresh_ms", proc(user: rawptr, name: string, p: ^config.Prefs) {
		(^App)(user).os_anim.cfg = os_anim_settings_from_prefs(p)
	}, app)

	config.bind(p, "browser.demos.", &app.demos_cfg, demos_settings_from_prefs, destroy = demos_settings_destroy)
	config.bind(p, "browser.license.", &app.license_cfg, license_settings_from_prefs, destroy = license_settings_destroy)

	config.bind(p, "browser.desktop_integration.", &app.desktop_cfg, desktop_settings_from_prefs, destroy = desktop_settings_destroy)
	when UPDATES_SELF {
		config.watch(p, prefs_page.UPDATE_AUTO_PREF, proc(user: rawptr, name: string, p: ^config.Prefs) {
			app := (^App)(user)
			desktop_settings_destroy(&app.desktop_cfg)
			app.desktop_cfg = desktop_settings_from_prefs(p)
		}, app)
	}

	config.bind(p, "font.", &app.font_cfg, font_generics_settings_from_prefs, destroy = font_generics_settings_destroy)

	config.bind(p, "browser.window.", &app.wchrome.cfg, window_settings_from_prefs, on_change = on_window_chrome_pref, user = app)
	on_window_extra :: proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		app.wchrome.cfg = window_settings_from_prefs(p)
		window_chrome_on_pref(app, name)
	}
	config.watch(p, "window.", on_window_extra, app)
	config.watch(p, "browser.address_bar.", on_window_extra, app)

	config.bind(p, "browser.frame.", &app.pacing.cfg, pacer_settings_from_prefs, on_change = on_pacer_pref, user = app)
	on_pacer_extra :: proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		app.pacing.cfg = pacer_settings_from_prefs(p)
		pacer_on_pref(app)
	}
	config.watch(p, "rendering.present", on_pacer_extra, app)
	config.watch(p, FRAME_RATE_PREF, on_pacer_extra, app)

	config.bind(p, "browser.tabs.", &app.favs.cfg, tab_settings_from_prefs, on_change = proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		if len(app.windows) > 0 { request_frames(app, 2) }
	}, user = app)

	config.bind(p, "browser.shell.", &app.chrome_frames.cfg, shell_frame_settings_from_prefs, on_change = on_shell_frames_pref, user = app)
	config.bind(p, "browser.devtools.", &app.devtools_cfg, devtools_settings_from_prefs, destroy = devtools_settings_destroy)
}

@(private = "file")
on_window_chrome_pref :: proc(user: rawptr, name: string, p: ^config.Prefs) {
	window_chrome_on_pref((^App)(user), name)
}

@(private = "file")
on_pacer_pref :: proc(user: rawptr, name: string, p: ^config.Prefs) {
	pacer_on_pref((^App)(user))
}

@(private = "file")
on_shell_frames_pref :: proc(user: rawptr, name: string, p: ^config.Prefs) {
	shell_frames_on_pref((^App)(user))
}

@(private = "file")
on_shell_cfg_changed :: proc(user: rawptr, name: string, p: ^config.Prefs) {
	app := (^App)(user)
	if .Loop not_in app.made { return }
	app.show_console = app.cfg.show_console
	app.loop.timer_slice_ns = i64(app.cfg.timer_slice_ms * 1e6)
	if app.cfg.autosave_ms != app.autosave_armed_ms { arm_autosave(app) }
	request_frames(app, 3)
}

// Defers an engine-level preference update while a page holds the thread (shell_frames.odin).
shell_defer_pref :: proc(app: ^App, g: Pref_Deferred) -> bool {
	if !shell_nested() { return false }
	was_empty := app.prefs_deferred == {}
	app.prefs_deferred += {g}
	if was_empty { shell_defer({kind = .Prefs}) }
	return true
}

// Runs any preference updates deferred during chrome frames (shell_run_action .Prefs).
prefs_flush_deferred :: proc(app: ^App) {
	d := app.prefs_deferred
	app.prefs_deferred = {}
	if .Net in d        { net_apply(app) }
	if .Http_Cache in d { http_cache_apply_counted(app) }
	if .Fetch in d      { fetch_settings_apply(app) }
	if .Cookies in d    { app.profile.jar.settings = cookies.settings_from_prefs(&app.prefs) }
	if .Page in d       { page_settings_apply(app) }
	if .Downloads in d  { downloads_apply_counted(app) }
	if .Touch in d      { touch_devices_apply(app) }
	if d != {} {
		profile_prefs_sync(app)
		request_frames(app, 3)
	}
}

@(private = "file")
fetch_settings_apply :: proc(app: ^App) {
	fetch.settings_destroy(&app.profile.settings)
	app.profile.settings = fetch.settings_from_prefs(&app.prefs)
}

@(private = "file")
http_cache_apply_counted :: proc(app: ^App) {
	http_cache_apply(app)
	app.prefs_apply_counts[.Http_Cache] += 1
}

@(private = "file")
downloads_apply_counted :: proc(app: ^App) {
	downloads_apply(app)
	app.prefs_apply_counts[.Downloads] += 1
}

// Refreshes page_settings, syncs any user stylesheet off the UI thread, and restyles every live tab.
page_settings_apply :: proc(app: ^App) {
	page.settings_destroy(&app.page_settings)
	app.page_settings = page.settings_from_prefs(&app.prefs)
	user_stylesheet_sync(app)
	for tab in tabs_all(app) { if tab.page != nil { page.configure_styles(tab.page) } }
	request_frames(app, 3)
}

// Binds the runtime subsystems (network, HTTP cache, fetch, cookies, pages, downloads, touch, and prefs.txt persistence)
// to their own preference prefixes (app_start, once the loop, network client, profile and page settings exist).
prefs_bind_runtime :: proc(app: ^App) {
	p := &app.prefs

	// Network transport (excluding network.cache.*, which belongs to the HTTP cache) + fetch network policy.
	config.watch(p, "network.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		if strings.has_prefix(name, "network.cache.") { return }
		app := (^App)(user)
		if !shell_defer_pref(app, .Net) { net_apply(app) }
		if !shell_defer_pref(app, .Fetch) { fetch_settings_apply(app) }
		request_frames(app, 3)
	}, app)

	config.watch(p, "network.cache.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		if !shell_defer_pref(app, .Http_Cache) { http_cache_apply_counted(app) }
		request_frames(app, 3)
	}, app)

	on_fetch_pref :: proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		if !shell_defer_pref(app, .Fetch) { fetch_settings_apply(app) }
		request_frames(app, 3)
	}
	for prefix in ([?]string{"file.", "privacy.", "security.", "storage."}) { config.watch(p, prefix, on_fetch_pref, app) }

	app.profile.jar.settings = cookies.settings_from_prefs(p)
	config.watch(p, "cookies.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		if !shell_defer_pref(app, .Cookies) {
			app.profile.jar.settings = cookies.settings_from_prefs(p)
		}
		request_frames(app, 3)
	}, app)

	on_page_pref :: proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		if !shell_defer_pref(app, .Page) { page_settings_apply(app) }
	}
	for prefix in ([?]string{
		"page.", "style.", "html.", "wasm.", "forms.", "images.", "javascript.", "webauthn.",
		"media.", "canvas.", "indexeddb.", "webaudio.", "webcodecs.", "webgl.", "eventsource.", "websocket.",
		"workers.", "shared_workers.", "service_workers.", "caches.", "opfs.", "file_system.",
		"frames.", "fullscreen.", "performance.", "timers.", "crypto.", "dom.", "navigator.",
		"url.", "history.", "privacy.", "security.", "storage.", "font.",
		"browser.scroll.css_smooth", "browser.touch.expose",
	}) { config.watch(p, prefix, on_page_pref, app) }

	config.watch(p, "browser.download.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		if !shell_defer_pref(app, .Downloads) { downloads_apply_counted(app) }
		request_frames(app, 3)
	}, app)

	config.watch(p, "browser.touch.expose", proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		if !shell_defer_pref(app, .Touch) { touch_devices_apply(app) }
		request_frames(app, 3)
	}, app)

	// Any user-layer change schedules a background write of prefs.txt (O(1) user_version comparison).
	config.watch(p, "", proc(user: rawptr, name: string, p: ^config.Prefs) {
		profile_prefs_sync((^App)(user))
	}, app)
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
