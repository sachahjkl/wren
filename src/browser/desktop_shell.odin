package browser

// Wren on the user's desktop: the shell side of the toolkit's desktop package (toolkit:desktop, with Wren's identity and
// preferences in src/desktop). That package knows how to add and remove
// the Start menu shortcut, the registration as a candidate browser, the freedesktop.org entry...; this file decides when,
// and shows the state:
//
//   * the "Desktop integration" row of about:config's Browser category (a switch): its state is read from the
//     disk (the registry) whenever the page is shown, never from a preference; ticking it adds the files, unticking it
//     removes them. A box ticked with "points to <old path>" means the files exist but run another executable (the
//     program was moved, or updated into another folder): "Update" makes them run this one. Its "Setup..." button opens the
//     Setup dialog (setup.odin), where the same things are done together with installing the program;
//   * the same two commands in the palette;
//   * `--desktop-integration=install|remove|status`, without a window (an uninstall script, the tests).
//
// What used to be here (the silent integration of the first run, the line under the address bar that offered to update it)
// is the Setup dialog now: setup.odin decides when it opens by itself, and the toolkit's setup package draws it (and
// watches the install itself while it is open).
//
// The disk is read and written by jobs of the blocking pool (COM and the registry are fast, but not the interface
// thread's business); the box shows "working" meanwhile.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import desktop "toolkit:desktop"
import process "toolkit:process"
import wren_desktop "wb:desktop"
import "wb:host"
import "wb:i18n"

DESKTOP_PREFS := [?]config.Def{
	{name = "browser.desktop_integration.on_first_run", kind = .Bool, default = {b = APP_CHANNEL == .Release},
		description = "At the start of a copy of Wren that is not the installed one, open the Setup dialog (install, replace the installed copy, repair, or \"Use standalone\" to carry on as it is: the answer is remembered in the profile). It also opens when the installed copy needs repair. Only the release build does by default; development builds, profiles given with --profile, profiles in the temporary folder and portable copies (a wren.portable file beside wren.exe) never do. Closing the dialog without answering asks again after the next update. The command \"Setup...\" and `wren.exe --setup` open it whatever this says."},
	{name = "browser.desktop_integration.status_refresh_ms", kind = .Int, default = {i = 30000}, bounded = true, min = 0, max = 60_000, unit = "ms",
		description = "Longest time about:config shows the state of the desktop integration read from the disk before reading it again. Coming back to the window reads it at once (the integration is changed elsewhere), and while the system watcher runs (it tells Wren when the registry keys or the Start menu shortcut change) nothing is read on a timer; this is the period when no watcher runs (a profile of its own, a platform without one). 0 = at every frame."},
}

register_desktop_shell_prefs :: proc(p: ^config.Prefs) {
	wren_desktop.register_prefs(p)
	config.register(p, DESKTOP_PREFS[:])
	config.register(p, SETUP_PREFS[:])
}

// What Wren is called on the desktop (src/desktop/identity.odin). A development build has its own entries (name, keys,
// AppUserModelID, link schemes), so it never takes over those of the release.
desktop_identity :: proc() -> desktop.Identity { return wren_desktop.identity(APP_NAME, APP_TAGLINE, IS_DEV_BUILD) }

// The prefix of the links this build registers (links.odin).
desktop_link_prefix :: proc() -> string { return wren_desktop.link_prefix(IS_DEV_BUILD) }

// The window's AppUserModelID is the shortcut's: before the first window exists.
desktop_early_init :: proc() {
	id := desktop_identity()
	desktop.set_process_identity(id)
	platform.set_app_id(id.slug)   // Linux: the windows' app_id and WM_CLASS, the name of the .desktop file the desktop finds the icon by
}

env_lookup :: proc(name: string) -> string {
	v, _ := os.lookup_env(name, context.temp_allocator)
	return v
}

// The options of an integration of this program, from the preferences (and WREN_DESKTOP_* roots of the environment).
desktop_options :: proc(app: ^App) -> desktop.Options {
	o := desktop.options_make(desktop_identity())
	wren_desktop.options_apply_prefs(&o, &app.prefs)
	o.icons = desktop_icons()
	o.launcher = console_launcher()   // console_launcher_*.odin
	desktop.roots_from_env(&o, env_lookup)
	return o
}

// `--desktop-integration=...`, `--uninstall [--purge]`: runs it without a window and returns the exit code.
// With `--purge` on an uninstall the profile folder is deleted too (preferences, history, cookies, session, crashes,
// licence); without it the profile is kept, so a reinstall finds everything as it was.
desktop_cli :: proc(app: ^App, mode: desktop.Cli_Mode, purge := false) -> int {
	o := desktop_options(app)
	code := desktop.cli_run(mode, &o, process.console_write)
	if mode == .Uninstall && purge && (code == 0 || code == desktop.CLI_UNINSTALL_LATER) {
		// delete the profile after the files (the profile is the browser's, not the desktop package's concern). A profile
		// given with --profile or a portable one is still removed when asked for, since --purge is an explicit request.
		if app.profile_dir != "" && os.is_dir(app.profile_dir) {
			if base.remove_tree(app.profile_dir) {
				process.console_write(fmt.tprintf("profile deleted: %s\n", app.profile_dir))
			} else {
				process.console_write(fmt.tprintf("the profile could not be fully deleted: %s\n", app.profile_dir))
				if code == 0 { code = 1 }
			}
		}
	}
	return code
}

////////////////////////////////
// State

Desktop_Job_Kind :: enum u8 { Read, Install, Remove }
Desktop_Reason :: enum u8 { Refresh, User }

Desktop_Job :: struct {
	app:    ^App,              // whose integration status it reports to
	kind:   Desktop_Job_Kind,
	reason: Desktop_Reason,
	opts:   desktop.Options,   // owned copy
	result: desktop.Result,    // the detail is cloned
	status: desktop.Status,    // read after the change too
}

Desktop_Shell :: struct {
	status:          desktop.Status,   // the last one read (owned)
	known:           bool,
	read_at:         time.Tick,
	jobs:            int,              // out in the pool
	writes:          int,              // of those, the ones that change the integration (install / remove)
	stale:           b32,              // atomic: the window came back, or the watcher saw a change on the disk
	watcher:         ^desktop.Watcher, // nil: no system watcher here, the periodic read below stays
	failure:         string,           // the last failed change, shown under the box (owned)
}


desktop_shell_destroy :: proc() {
	desktop.watch_stop(the_app.dsk.watcher)
	desktop.status_destroy(&the_app.dsk.status)
	delete(the_app.dsk.failure)
	the_app.dsk = {}
}

// Waits for the jobs out (their completion frees them); before the pool and the loop go.
desktop_shell_shutdown :: proc(app: ^App) {
	host.shutdown_step("desktop jobs")
	for app.dsk.jobs > 0 { host.blocking_settle(&app.blocking) }
	host.shutdown_step("desktop watcher")
	desktop_shell_destroy()   // (the watcher's thread is stopped and joined here)
	host.shutdown_step("setup jobs, uninstall helper")
	setup_shutdown(app)   // setup.odin: its jobs, and the deletion of what this process held
	host.shutdown_step("update_destroy")
	update_destroy(app)   // update_check.odin
}

@(private = "file")
desktop_job_start :: proc(app: ^App, kind: Desktop_Job_Kind, reason: Desktop_Reason) {
	job := new(Desktop_Job)
	job.app, job.kind, job.reason = app, kind, reason
	job.opts = desktop.options_clone(desktop_options(app))
	app.dsk.jobs += 1
	if kind != .Read { app.dsk.writes += 1 }
	host.run_blocking(&app.blocking, desktop_job_work, desktop_job_done, job)
}

@(private = "file")
desktop_job_work :: proc(data: rawptr) {
	job := (^Desktop_Job)(data)
	switch job.kind {
	case .Read:
	case .Install: job.result = desktop.install(&job.opts)
	case .Remove:  job.result = desktop.remove(&job.opts)
	}
	job.result.detail = strings.clone(job.result.detail)   // (the worker's temporary allocator is cleared after the job)
	job.status = desktop.status(&job.opts)
}

@(private = "file")
desktop_job_done :: proc(data: rawptr) {
	job := (^Desktop_Job)(data)
	defer {
		delete(job.result.detail)
		desktop.options_destroy(&job.opts)
		desktop.status_destroy(&job.status)
		if job.kind != .Read { the_app.dsk.writes = max(the_app.dsk.writes - 1, 0) }
		the_app.dsk.jobs -= 1
		free(job)   // (last: the lines above read it)
	}
	app := job.app
	changed := !app.dsk.known || app.dsk.status.state != job.status.state || app.dsk.status.stale_exe != job.status.stale_exe || app.dsk.status.incomplete != job.status.incomplete
	desktop.status_destroy(&app.dsk.status)
	app.dsk.status, job.status = job.status, {}
	app.dsk.known = true
	app.dsk.read_at = time.tick_now()

	if job.kind != .Read {
		delete(app.dsk.failure)
		app.dsk.failure = ""
		what := job.kind == .Install ? "install" : "remove"
		if job.result.error != .None {
			app.dsk.failure = fmt.aprintf("Could not %s the desktop integration: %s (%s)", what, desktop.error_text(job.result.error), job.result.detail)
			ui.toast(.Warn, "%s", app.dsk.failure)
		} else if job.reason == .User {
			ui.toast(.Info, job.kind == .Install ? "%s is integrated with the desktop (%s)" : "%s is no longer integrated with the desktop", APP_NAME, desktop.targets(browser = true))
		}
		changed = true
	}
	if changed { request_frames(app, 3) }
}

// The integration of this channel as it is on the disk now, read again when older than the preference says. Called
// while something shows it.
// The window came back from another program: the integration may have changed there (read again when shown).
desktop_note_activate :: proc() { sync.atomic_store(&the_app.dsk.stale, true) }

// The watcher's thread: a place the integration lives changed on the disk.
@(private = "file")
desktop_watch_wake :: proc(user: rawptr) {
	context = base.process_context()   // (the watcher's thread runs with the default context)
	app := (^App)(user)
	sync.atomic_store(&app.dsk.stale, true)
	if app != nil { host.post(&app.loop, desktop_changed_on_loop, app) }
}

// On the loop's thread (a woken idle loop builds no frame by itself): what shows the integration is drawn again. Nothing
// is drawn for the changes nobody looks at (HKCU\Software changes all the time).
@(private = "file")
desktop_changed_on_loop :: proc(data: rawptr) {
	app := (^App)(data)
	if t := current_tab(app); setup_is_open(app) || (t != nil && t.kind == .Config) { request_frames(app, 3) }
}

// After the first tab exists, before Setup's start-up: the system tells us when the integration changes (its registry
// keys, the Start menu shortcut), so nothing reads it on a timer and the Setup dialog follows what is done to it outside
// (Settings > Apps, another Wren). Not for the runs that must not look at the desktop (the same ones Setup leaves alone).
desktop_watch_begin :: proc(app: ^App, profile_explicit: bool) {
	if !desktop.supported() || app.dsk.watcher != nil { return }
	if v, ok := os.lookup_env("WREN_DESKTOP_INTEGRATION", context.temp_allocator); ok && v == "off" { return }   // src/e2e sets it for every test
	// The watcher now runs for --profile and for disposable profiles too (the temporary folder): the Setup state and the
	// menu's "installed" badge stay live in those runs as well, and the install folder is followed so an uninstall or a
	// reinstall by another Wren is seen at once. It only reads the shared desktop (registry keys, folders) and never
	// changes it, so it is safe for a throwaway profile; WREN_DESKTOP_INTEGRATION=off (the tests) still turns it off.
	desktop_watch_ensure(app)
}

// Starts the watcher whatever the run (also on the scratch roots of a test).
desktop_watch_ensure :: proc(app: ^App) {
	if !desktop.supported() || app.dsk.watcher != nil { return }
	o := desktop_options(app)
	app.dsk.watcher = desktop.watch_start(&o, desktop_watch_wake, app)
}

desktop_status_poll :: proc(app: ^App) {
	if app.dsk.jobs > 0 { return }
	stale := sync.atomic_load(&app.dsk.stale)
	if app.dsk.known && !stale && app.dsk.watcher != nil { return }   // the system tells us: no periodic read at all
	every := time.Duration(config.int_of(&app.prefs, "browser.desktop_integration.status_refresh_ms")) * time.Millisecond
	if app.dsk.known && !stale && time.tick_since(app.dsk.read_at) < every { return }
	if stale { sync.atomic_store(&app.dsk.stale, false) }
	desktop_job_start(app, .Read, .Refresh)
}

desktop_integrated :: proc() -> bool { return the_app.dsk.known && the_app.dsk.status.state != .Absent }

desktop_available :: proc() -> bool { return desktop.supported() }
desktop_has_default_apps :: proc() -> bool { return desktop.has_default_apps_page() }
desktop_open_default_apps :: proc() { desktop.open_default_apps() }

// For a menu item or the palette: the state, kept fresh while something shows it.
desktop_checked :: proc(app: ^App) -> bool {
	desktop_status_poll(app)
	return desktop_integrated()
}

// Ticks or unticks the box.
desktop_toggle :: proc(app: ^App) {
	if app.dsk.jobs > 0 { return }
	desktop_job_start(app, desktop_integrated() ? .Remove : .Install, .User)
}

// The palette's command: decides on the disk as it is now, not on what was read a moment ago.
desktop_command_toggle :: proc(app: ^App) {
	if app.dsk.jobs > 0 { return }
	o := desktop_options(app)
	s := desktop.status(&o, context.temp_allocator)
	desktop_job_start(app, s.state == .Absent ? .Install : .Remove, .User)
}

// Makes the integration run this executable (the box's "Update").
desktop_update :: proc(app: ^App) {
	if app.dsk.jobs > 0 { return }
	desktop_job_start(app, .Install, .User)
}

// A profile that is temporary or given on the command line is a test's, a tool's, an agent's: nothing is offered or asked
// for there (Setup, the update check).
desktop_profile_is_disposable :: proc(app: ^App, explicit: bool) -> bool {
	if explicit || !app.cfg.persist_profile { return true }
	tmp, err := os.temp_dir(context.temp_allocator)
	if err != nil || tmp == "" { return false }
	norm :: proc(s: string) -> string {
		r, _ := strings.replace_all(strings.to_lower(s, context.temp_allocator), "\\", "/", context.temp_allocator)
		return strings.trim_right(r, "/")
	}
	return strings.has_prefix(norm(app.profile_dir), strings.concatenate({norm(tmp), "/"}, context.temp_allocator))
}

////////////////////////////////
// The box in about:config

// The integration is a row of about:config's Browser category (config_ui.odin builds the row and its title; this file
// fills in the state, the switch and the buttons).

// Whether the switch can be used now: a background read changes nothing on the disk, so the switch keeps its state and
// stays usable (a "Working..." every second made the row jump); only a change being written or the first read is work.
desktop_config_busy :: proc() -> bool { return the_app.dsk.writes > 0 || !the_app.dsk.known }

// What the row says under its title: what the files run, or what failed (temp memory), and its tone tag.
desktop_config_note :: proc() -> (note: string, tone: string) {
	state := the_app.dsk.known ? the_app.dsk.status.state : .Absent
	tone = "weak"
	switch {
	case the_app.dsk.failure != "": note, tone = the_app.dsk.failure, "bad"
	case desktop_config_busy(): note = i18n.tr("Working\u2026")
	case state == .Repair && the_app.dsk.status.stale_exe != "": note = fmt.tprintf(i18n.tr("Points to %s \u2014 Update makes it run this copy of %s."), the_app.dsk.status.stale_exe, APP_NAME)
	case state == .Repair:  note = i18n.tr("Some of its files are missing \u2014 Repair puts them back.")
	case state == .Installed: note = fmt.tprintf(i18n.tr("Installed. %s is listed as a program that can open web addresses; the default is yours to pick."), APP_NAME)
	case: note = fmt.tprintf(i18n.tr("Adds %s to the Start menu and to the programs that can open web addresses."), APP_NAME)
	}
	return
}

// The row's buttons (under its note): Update / Repair, the system's page of default programs, Setup.
desktop_config_buttons :: proc(app: ^App) {
	em := ui.font_size()
	busy := desktop_config_busy()
	state := app.dsk.known ? app.dsk.status.state : .Absent
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
	if ui.row(.Center) {
		if state == .Repair {
			ui.next({width = ui.text_size(em * 0.8), height = ui.px(ui.dense(em * 1.8))})
			if ui.disabled(busy) { if ui.button(app.dsk.status.stale_exe != "" ? i18n.tr("Update###desktop_update") : i18n.tr("Repair###desktop_update")).clicked { desktop_update(app) } }
			ui.spacer(ui.px(em * 0.4))
		}
		if desktop.has_default_apps_page() {
			ui.next({width = ui.text_size(em * 0.8), height = ui.px(ui.dense(em * 1.8))})
			if ui.tags("ghost_button") { if ui.button(i18n.tr("Open default apps###desktop_defaults")).clicked { desktop.open_default_apps() } }
			ui.spacer(ui.px(em * 0.4))
		}
		ui.next({width = ui.text_size(em * 0.8), height = ui.px(ui.dense(em * 1.8))})
		if ui.tags("ghost_button") { if ui.button(i18n.tr("Setup\u2026###desktop_setup")).clicked { setup_open(app) } }
	}
}

// The row's switch (in the editor column); true when it was flipped.
desktop_config_switch :: proc(app: ^App) -> bool {
	em := ui.font_size()
	checked := app.dsk.known && app.dsk.status.state != .Absent
	ui.next({width = ui.px(em * 3.4), height = ui.px(ui.dense(em * 2))})
	flipped := false
	if ui.disabled(desktop_config_busy()) {
		ui.a11y({name = i18n.tr("Integrate with the desktop")})
		if ui.toggle("###desktop_box", "", &checked).clicked { desktop_toggle(app); flipped = true }
	}
	return flipped
}

// The integration's subtitle: what it touches ("Start menu, default apps").
desktop_config_targets :: proc() -> string { return desktop.targets(browser = true) }
