package browser

// Wren on the user's desktop: the shell side of package desktop (src/desktop). That package knows how to add and remove
// the Start menu shortcut, the registration as a candidate browser, the freedesktop.org entry...; this file decides when,
// and shows the state:
//
//   * the box in about:config ("Integrate Wren with the desktop (Start menu, default apps)"): its state is read from the
//     disk (the registry) whenever the page is shown, never from a preference; ticking it adds the files, unticking it
//     removes them. A box ticked with "points to <old path>" means the files exist but run another executable (the
//     program was moved, or updated into another folder): "Update" makes them run this one. Its "Setup..." button opens the
//     Setup dialog (setup.odin), where the same things are done together with installing the program;
//   * the same two commands in the palette;
//   * `--desktop-integration=install|remove|status`, without a window (an uninstall script, the tests).
//
// What used to be here (the silent integration of the first run, the line under the address bar that offered to update it)
// is the Setup dialog now: setup.odin decides when it opens by itself, and setup_ui.odin draws it.
//
// The disk is read and written by jobs of the blocking pool (COM and the registry are fast, but not the interface
// thread's business); the box shows "working" meanwhile.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "toolkit:ui"
import "wb:config"
import "wb:desktop"
import "wb:host"

DESKTOP_PREFS := [?]config.Def{
	{name = "browser.desktop_integration.on_first_run", kind = .Bool, default = {b = APP_CHANNEL == .Release},
		description = "At the start of a copy of Wren that is not the installed one, open the Setup dialog (install, replace the installed copy, repair, or \"Use standalone\" to carry on as it is: the answer is remembered in the profile). It also opens when the installed copy needs repair. Only the release build does by default; development builds, profiles given with --profile, profiles in the temporary folder and portable copies (a wren.portable file beside wren.exe) never do. Closing the dialog without answering asks again after the next update. The command \"Setup...\" and `wren.exe --setup` open it whatever this says."},
	{name = "browser.desktop_integration.status_refresh_ms", kind = .Int, default = {i = 30000}, bounded = true, min = 0, max = 60_000, unit = "ms",
		description = "Longest time about:config shows the state of the desktop integration read from the disk before reading it again. Coming back to the window reads it at once (the integration is changed elsewhere), and while the system watcher runs (it tells Wren when the registry keys or the Start menu shortcut change) nothing is read on a timer; this is the period when no watcher runs (a profile of its own, a platform without one). 0 = at every frame."},
}

register_desktop_shell_prefs :: proc(p: ^config.Prefs) {
	desktop.register_prefs(p)
	config.register(p, DESKTOP_PREFS[:])
	config.register(p, SETUP_PREFS[:])
}

// What Wren is called on the desktop. A development build has its own entries (name, keys, AppUserModelID), so it never
// takes over those of the release.
desktop_identity :: proc() -> desktop.Identity {
	when IS_DEV_BUILD {
		return {name = APP_NAME + " Dev", key = APP_NAME + "Dev", slug = "wren-dev", aumid = "FromentSoftware.Wren.Dev", description = APP_TAGLINE, vendor = "Froment Software", exe_name = "wren.exe"}
	} else {
		return {name = APP_NAME, key = APP_NAME, slug = "wren", aumid = "FromentSoftware.Wren", description = APP_TAGLINE, vendor = "Froment Software", exe_name = "wren.exe"}
	}
}

// The window's AppUserModelID is the shortcut's: before the first window exists.
desktop_early_init :: proc() { desktop.set_process_identity(desktop_identity()) }

// The icons of the theme on freedesktop.org desktops (Windows uses the executable's own).
when ODIN_OS == .Windows {
	@(private = "file") desktop_icons :: proc() -> []desktop.Icon { return nil }
} else {
	@(private = "file") DESKTOP_ICON_SET := [?]desktop.Icon{
		{16, #load("../../assets/dev/logo_16.png") when IS_DEV_BUILD else #load("../../assets/logo_16.png")},
		{32, #load("../../assets/dev/logo_32.png") when IS_DEV_BUILD else #load("../../assets/logo_32.png")},
		{64, #load("../../assets/dev/logo_64.png") when IS_DEV_BUILD else #load("../../assets/logo_64.png")},
		{256, #load("../../assets/dev/logo_256.png") when IS_DEV_BUILD else #load("../../assets/logo_256.png")},
		{512, #load("../../assets/dev/logo.png") when IS_DEV_BUILD else #load("../../assets/logo.png")},
	}
	@(private = "file") desktop_icons :: proc() -> []desktop.Icon { return DESKTOP_ICON_SET[:] }
}

@(private = "file")
env_lookup :: proc(name: string) -> string {
	v, _ := os.lookup_env(name, context.temp_allocator)
	return v
}

// The options of an integration of this program, from the preferences (and WREN_DESKTOP_* roots of the environment).
desktop_options :: proc(app: ^App) -> desktop.Options {
	o := desktop.options_make(desktop_identity())
	desktop.options_apply_prefs(&o, &app.prefs)
	o.icons = desktop_icons()
	when ODIN_OS == .Windows { o.launcher = CONSOLE_LAUNCHER }
	desktop.roots_from_env(&o, env_lookup)
	return o
}

// `--desktop-integration=...`: runs it and returns the exit code.
desktop_cli :: proc(app: ^App, mode: desktop.Cli_Mode) -> int {
	o := desktop_options(app)
	return desktop.cli_run(mode, &o, desktop.console_write)
}

////////////////////////////////
// State

Desktop_Job_Kind :: enum u8 { Read, Install, Remove }
Desktop_Reason :: enum u8 { Refresh, User }

Desktop_Job :: struct {
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
	changes:         int,              // atomic: how many times the watcher saw the disk change (the Setup dialog reads again when it moves)
	failure:         string,           // the last failed change, shown under the box (owned)
}

@(private = "file") dsk: Desktop_Shell

desktop_shell_destroy :: proc() {
	desktop.watch_stop(dsk.watcher)
	desktop.status_destroy(&dsk.status)
	delete(dsk.failure)
	dsk = {}
}

// Waits for the jobs out (their completion frees them); before the pool and the loop go.
desktop_shell_shutdown :: proc(app: ^App) {
	host.shutdown_step("desktop jobs")
	for dsk.jobs > 0 { host.blocking_settle(&app.blocking) }
	host.shutdown_step("desktop watcher")
	desktop_shell_destroy()   // (the watcher's thread is stopped and joined here)
	host.shutdown_step("setup jobs, uninstall helper")
	setup_shutdown(app)   // setup.odin: its jobs, and the deletion of what this process held
	host.shutdown_step("update_destroy")
	update_destroy()   // update_check.odin
}

@(private = "file")
desktop_job_start :: proc(app: ^App, kind: Desktop_Job_Kind, reason: Desktop_Reason) {
	job := new(Desktop_Job)
	job.kind, job.reason = kind, reason
	job.opts = desktop.options_clone(desktop_options(app))
	dsk.jobs += 1
	if kind != .Read { dsk.writes += 1 }
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
	app := the_app
	defer {
		delete(job.result.detail)
		desktop.options_destroy(&job.opts)
		desktop.status_destroy(&job.status)
		free(job)
		if job.kind != .Read { dsk.writes = max(dsk.writes - 1, 0) }
		dsk.jobs -= 1
	}
	if app == nil { return }
	changed := !dsk.known || dsk.status.state != job.status.state || dsk.status.stale_exe != job.status.stale_exe || dsk.status.incomplete != job.status.incomplete
	desktop.status_destroy(&dsk.status)
	dsk.status, job.status = job.status, {}
	dsk.known = true
	dsk.read_at = time.tick_now()

	if job.kind != .Read {
		delete(dsk.failure)
		dsk.failure = ""
		what := job.kind == .Install ? "install" : "remove"
		if job.result.error != .None {
			dsk.failure = fmt.aprintf("Could not %s the desktop integration: %s (%s)", what, desktop.error_text(job.result.error), job.result.detail)
			ui.toast(.Warn, "%s", dsk.failure)
		} else if job.reason == .User {
			ui.toast(.Info, job.kind == .Install ? "%s is integrated with the desktop (%s)" : "%s is no longer integrated with the desktop", APP_NAME, desktop.targets())
		}
		changed = true
	}
	if changed { app.frames_requested = max(app.frames_requested, 3) }
}

// The integration of this channel as it is on the disk now, read again when older than the preference says. Called
// while something shows it.
// The window came back from another program: the integration may have changed there (read again when shown).
desktop_note_activate :: proc() { sync.atomic_store(&dsk.stale, true) }

// The watcher's thread: a place the integration lives changed on the disk.
@(private = "file")
desktop_watch_wake :: proc(user: rawptr) {
	app := (^App)(user)
	sync.atomic_store(&dsk.stale, true)
	sync.atomic_add(&dsk.changes, 1)
	if app != nil { host.post(&app.loop, desktop_changed_on_loop, nil) }
}

// On the loop's thread (a woken idle loop builds no frame by itself): what shows the integration is drawn again. Nothing
// is drawn for the changes nobody looks at (HKCU\Software changes all the time).
@(private = "file")
desktop_changed_on_loop :: proc(_: rawptr) {
	app := the_app
	if app == nil { return }
	if t := current_tab(app); setup_is_open() || (t != nil && t.kind == .Config) { app.frames_requested = max(app.frames_requested, 3) }
}

// After the first tab exists, before Setup's start-up: the system tells us when the integration changes (its registry
// keys, the Start menu shortcut), so nothing reads it on a timer and the Setup dialog follows what is done to it outside
// (Settings > Apps, another Wren). Not for the runs that must not look at the desktop (the same ones Setup leaves alone).
desktop_watch_begin :: proc(app: ^App, profile_explicit: bool) {
	if !desktop.supported() || dsk.watcher != nil { return }
	if v, ok := os.lookup_env("WREN_DESKTOP_INTEGRATION", context.temp_allocator); ok && v == "off" { return }   // tools\test_env.ps1: every script's runs
	if desktop_profile_is_disposable(app, profile_explicit) { return }
	desktop_watch_ensure(app)
}

// Starts the watcher whatever the run (the Setup dialog asks for it when it opens: it must follow the disk it shows, also
// on the scratch roots of a test).
desktop_watch_ensure :: proc(app: ^App) {
	if !desktop.supported() || dsk.watcher != nil { return }
	o := desktop_options(app)
	dsk.watcher = desktop.watch_start(&o, desktop_watch_wake, app)
}

// How many changes the watcher has seen (Setup compares it with the one it read at).
desktop_changes :: proc() -> int { return sync.atomic_load(&dsk.changes) }

desktop_status_poll :: proc(app: ^App) {
	if dsk.jobs > 0 { return }
	stale := sync.atomic_load(&dsk.stale)
	if dsk.known && !stale && dsk.watcher != nil { return }   // the system tells us: no periodic read at all
	every := time.Duration(config.int_of(&app.prefs, "browser.desktop_integration.status_refresh_ms")) * time.Millisecond
	if dsk.known && !stale && time.tick_since(dsk.read_at) < every { return }
	if stale { sync.atomic_store(&dsk.stale, false) }
	desktop_job_start(app, .Read, .Refresh)
}

desktop_integrated :: proc() -> bool { return dsk.known && dsk.status.state != .Absent }

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
	if dsk.jobs > 0 { return }
	desktop_job_start(app, desktop_integrated() ? .Remove : .Install, .User)
}

// The palette's command: decides on the disk as it is now, not on what was read a moment ago.
desktop_command_toggle :: proc(app: ^App) {
	if dsk.jobs > 0 { return }
	o := desktop_options(app)
	s := desktop.status(&o, context.temp_allocator)
	desktop_job_start(app, s.state == .Absent ? .Install : .Remove, .User)
}

// Makes the integration run this executable (the box's "Update").
desktop_update :: proc(app: ^App) {
	if dsk.jobs > 0 { return }
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

// Above the list of preferences: the box, what it found on the disk, and the system's page of default programs.
desktop_config_panel :: proc(app: ^App) {
	if !desktop.supported() { return }
	desktop_status_poll(app)
	em := ui.font_size()
	// a background read changes nothing on the disk: the box keeps its state and stays usable (a "Working..." every
	// second made the panel jump), only a change being written or the first read shows as work
	busy := dsk.writes > 0
	first := !dsk.known
	state := dsk.known ? dsk.status.state : .Absent

	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.8))
		checked := dsk.known && state != .Absent
		label := fmt.aprintf("Integrate %s with the desktop (%s)", APP_NAME, desktop.targets(), allocator = ui.frame_allocator())
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
		if ui.disabled(busy || first) {
			if ui.checkbox("###desktop_box", label, &checked).clicked { desktop_toggle(app) }
		}
		ui.spacer(ui.px(em * 0.5))
		if state == .Repair {
			ui.next({width = ui.text_size(em * 0.8), height = ui.px(ui.dense(em * 2))})
			if ui.disabled(busy || first) { if ui.button(dsk.status.stale_exe != "" ? "Update###desktop_update" : "Repair###desktop_update").clicked { desktop_update(app) } }
			ui.spacer(ui.px(em * 0.5))
		}
		if desktop.has_default_apps_page() {
			ui.next({width = ui.text_size(em * 0.8), height = ui.px(ui.dense(em * 2))})
			if ui.tags("ghost_button") { if ui.button("Open default apps###desktop_defaults").clicked { desktop.open_default_apps() } }
			ui.spacer(ui.px(em * 0.5))
		}
		ui.next({width = ui.text_size(em * 0.8), height = ui.px(ui.dense(em * 2))})
		if ui.tags("ghost_button") { if ui.button("Setup\u2026###desktop_setup").clicked { setup_open(app) } }
		ui.spacer(ui.px(em * 0.8))
	}
	// the facts under it: what the files run, or what failed
	note := ""
	tone := "weak"
	switch {
	case dsk.failure != "": note, tone = dsk.failure, "bad"
	case busy || first:    note = "Working..."
	case state == .Repair && dsk.status.stale_exe != "": note = fmt.tprintf("Points to %s \u2014 Update makes it run this copy of %s.", dsk.status.stale_exe, APP_NAME)
	case state == .Repair:  note = "Some of its files are missing \u2014 Repair puts them back."
	case state == .Installed: note = fmt.tprintf("Installed. %s is listed as a program that can open web addresses; the default is yours to pick.", APP_NAME)
	}
	if note != "" {
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.8 + em * 2.0))
			if ui.tags(tone) {
				ui.next({width = ui.fill(), text_pad = 0})
				ui.paragraph(fmt.aprintf("%s###desktop_note", note, allocator = ui.frame_allocator()))
			}
			ui.spacer(ui.px(em * 0.8))
		}
	}
	ui.spacer(ui.px(em * 0.3))
}
