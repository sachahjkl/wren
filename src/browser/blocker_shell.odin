package browser

import "core:fmt"
import "core:strings"
import "wb:blocker"
import "wb:fetch"
import "wb:page"

// The content blocker in the shell (package blocker does the work): start-up and shutdown, the tabs it knows about, what
// it tells the shell (a request was blocked: a console line and a redraw), and a few helpers the icon, the panel and the
// dashboard share.

Bl_Shell :: struct {
	b:            blocker.Blocker,
	started:      bool,
	console_log:  bool,
	seen_version: u64,
	panel_scope_global: bool,     // the matrix edits global rules (source *), not this site's
	reload_pending: bool,         // a switch changed: the page loads again when the panel closes
}

bl: Bl_Shell

blocker_start :: proc(app: ^App) {
	if bl.started { return }
	bl.started = true
	bl.b.on_event = blocker_event
	blocker.start(&bl.b, &app.loop, &app.client, &app.loader, &app.prefs, app.cfg.persist_profile ? app.profile_dir : "")
}

blocker_stop :: proc(app: ^App) {
	if !bl.started { return }
	blocker.shutdown(&bl.b, &app.loader)
	bl.started = false
}

blocker_tab_new :: proc(app: ^App, t: ^Tab) {
	if bl.started { blocker.tab_register(&bl.b, t.id, t.scope) }
}

@(private = "file")
blocker_event :: proc(user: rawptr, ev: ^blocker.Event) {
	app := the_app
	if app == nil { return }
	switch ev.kind {
	case .Blocked:
		if bl.b.cfg.console && ev.tab != 0 {
			for t in app.tabs {
				if t.id != ev.tab { continue }
				rule := ev.rule != "" ? fmt.tprintf(" (%s)", ev.rule) : ""
				tab_log(t, .Warn, fmt.tprintf("Failed to load resource: net::ERR_BLOCKED_BY_CLIENT %s%s", ev.url, rule))
				break
			}
		}
		if t := current_tab(app); t != nil && t.id == ev.tab { app.frames_requested = max(app.frames_requested, 1) }
	case .Changed, .Lists:
		app.frames_requested = max(app.frames_requested, 1)
	}
}

// The state the blocker keeps for a tab (nil before the first page).
blocker_tab :: proc(t: ^Tab) -> ^blocker.Tab_State {
	if t == nil || !bl.started { return nil }
	return blocker.tab_state(&bl.b, t.id)
}

// The host the icon and the panel speak about: the page's, when it is an http(s) page.
blocker_page_host :: proc(t: ^Tab) -> (host: string, ok: bool) {
	if t == nil || t.kind != .Web || t.page == nil { return "", false }
	loc := &t.page.env.location
	if loc.scheme != "http" && loc.scheme != "https" { return "", false }
	return loc.host, loc.host != ""
}

// The key the site switches use for a page: its registrable domain, so that www.example.com and example.com share them.
blocker_site_key :: proc(host: string) -> string { return blocker.site_key(host) }

blocker_site_enabled :: proc(host: string) -> bool {
	return .Off not_in blocker.site_flags(&bl.b, host)
}

// Switches filtering on or off for a site and reloads the page.
blocker_set_site_enabled :: proc(app: ^App, t: ^Tab, host: string, on: bool) {
	blocker.site_toggle(&bl.b, blocker_site_key(host), .Off, !on)
	if t != nil { reload(app, t) }
}

blocker_open_dashboard :: proc(app: ^App, tab_name := "") {
	address := tab_name == "" ? "about:blocker" : strings.concatenate({"about:blocker#", tab_name}, context.temp_allocator)
	if t := current_tab(app); t != nil && t.kind == .Blocker {
		navigate(app, t, address)
		return
	}
	tab_open(app, address)
}

_ :: fetch
_ :: page

blocker_update_now :: proc() { if bl.started { blocker.updater_round(&bl.b, true) } }
