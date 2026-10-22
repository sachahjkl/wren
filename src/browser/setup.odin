package browser

// Wren Setup: the one executable is its own installer. A modal dialog (setup_ui.odin) lets the user install this copy
// (into %LOCALAPPDATA%\Programs\Wren, "Wren Dev" for the development channel, or any folder), manage the installation
// (the integration options, repair, replace the installed copy by this one, uninstall) or carry on without installing
// ("Use standalone": remembered in the profile). This file is the logic: what is read from the disk, what each state of
// the dialog is, what Install / Modify / Replace / Repair / Uninstall do, and when the dialog opens by itself. The files
// and keys are package desktop's (src/desktop); the dialog never touches them from the interface thread: a job of the
// blocking pool reads and writes, the dialog shows "working" meanwhile.
//
// The state of the dialog is a fact of the disk, never a preference:
//   Not_Installed      no copy in the install folder
//   Running_Installed  this executable IS the installed copy, and its integration is as the options say
//   Other_Copy         a copy is installed and this is another one (same version or newer): "Replace installed copy"
//   Older              the same, and this copy is older than the installed one
//   Repair             this is the installed copy but a shortcut, a key or a file is missing or points elsewhere
//
// Opens by itself (setup_startup) at the start of a release build that is not the installed copy, once per version unless
// the user chose "Use standalone" (then never again); not for development builds, profiles given with --profile or kept in
// the temporary folder, portable copies (a wren.portable file beside the executable), nor with WREN_DESKTOP_INTEGRATION=off
// in the environment. The command "Setup…" (menu, palette) and `wren.exe --setup` open it whatever the build.

import "core:fmt"
import "core:os"
import "core:strings"
import "toolkit:ui"
import "wb:config"
import "wb:desktop"
import "wb:host"

// What tools\package.ps1 puts next to wren.exe, copied beside the installed executable when it exists (a development
// build, which has none of it, installs the executable alone).
SETUP_PAYLOAD := [?]string{"vcruntime140.dll", "LICENSE.txt", "THIRD_PARTY.md", "README.txt", "licenses", "demos", "examples", "testserver.exe", "demo.bat"}

SETUP_CHOICE_FILE :: "setup.txt"

Setup_Kind :: enum u8 { Loading, Not_Installed, Running_Installed, Other_Copy, Older, Repair }
Setup_Reason :: enum u8 { Command, Cli, Startup }
Setup_Opt :: enum u8 { Start_Menu, Desktop_Shortcut, Add_To_Path, Register_Browser, Check_Daily }

// What the disk says (owned by the dialog; read by a job).
Setup_Facts :: struct {
	kind:          Setup_Kind,
	running_exe:   string,
	installed_dir: string,              // where the installed copy is, or would be by default
	inst:          desktop.Install_Info,
	integ:         desktop.Status,      // the integration, measured against the installed executable (this one when none is installed)
	integ_exe:     string,              // ... which one that was
	integ_complete: bool,
	other_target:  string,              // an integration that runs a copy other than the one it is measured against (owned)
}

setup_facts_destroy :: proc(f: ^Setup_Facts) {
	delete(f.running_exe); delete(f.installed_dir); delete(f.integ_exe); delete(f.other_target)
	desktop.install_info_destroy(&f.inst)
	desktop.status_destroy(&f.integ)
	f^ = {}
}

// The state of the dialog from what was read. `running_version` and `inst.version` are compared as versions.
setup_classify :: proc(running_exe, running_version: string, inst: desktop.Install_Info, integ_complete: bool) -> Setup_Kind {
	if !inst.exe_present { return .Not_Installed }
	if desktop.same_path(running_exe, inst.exe) {
		return (integ_complete && inst.missing == 0 && inst.manifest) ? .Running_Installed : .Repair
	}
	if inst.version != "" && desktop.compare_versions(running_version, inst.version) < 0 { return .Older }
	return .Other_Copy
}

Setup_Dialog :: struct {
	open:       bool,
	reason:     Setup_Reason,
	busy:       int,                    // jobs out in the pool
	facts:      Setup_Facts,
	known:      bool,

	path:       ui.Text_Field,
	path_ready: bool,                   // the field holds the install folder (set when the facts first arrive)
	path_text:  string,                 // the text the last validation was for (owned)
	path_problem: string,               // "" when fine (owned)
	opts:       [Setup_Opt]bool,
	baseline:   [Setup_Opt]bool,        // what the disk (or the preferences) said when the checkboxes were set
	opts_ready: bool,
	width_em:   f32,                    // the dialog's width, which the corner grip changes

	confirm_uninstall: bool,            // the first click on Uninstall asks, the second does it
	focus_primary:     bool,            // give the keyboard to the main button once it exists
	note:       string,                 // the outcome of the last action (owned)
	note_tone:  string,                 // "weak", "good", "bad", "warn"
	cleanup:    [dynamic]string,        // files that a running program holds: deleted after this process ends (owned)
	cleanup_dir: string,
	grip_width: f32,                    // the width when the grip was pressed
	mid_h:      f32,                    // the height of what scrolls, as laid out last frame
	fit_h:      f32,                    // the dialog's height as drawn last (it is placed higher in a short window)
	seen_changes: int,                  // desktop_changes() when the disk was last read (the system watcher moves it)
}

@(private) stp: Setup_Dialog

SETUP_PREFS := [?]config.Def{
	{name = "browser.update.check_daily", kind = .Bool, default = {b = false},
		description = "Once a day, ask GitHub's releases API (api.github.com/repos/sachahjkl/wren/releases/latest) whether a newer Wren exists and say so with a notice. Nothing is downloaded or installed by itself; no other data is sent than an ordinary request with Wren's user agent. Off by default: no network request is made until you tick \"Check for updates once per day\" in Setup. The command \"Check for updates\" asks once, whatever this says."},
	{name = "browser.update.url", kind = .String, default = {s = "https://api.github.com/repos/sachahjkl/wren/releases/latest"},
		description = "The address the update check reads (a JSON document with tag_name and html_url, as GitHub's \"latest release\" answers). For tests and mirrors."},
}

setup_destroy :: proc() {
	ui.field_destroy(&stp.path)
	setup_facts_destroy(&stp.facts)
	delete(stp.path_text); delete(stp.path_problem); delete(stp.note)
	for f in stp.cleanup { delete(f) }
	delete(stp.cleanup)
	delete(stp.cleanup_dir)
	stp = {}
}

setup_is_open :: proc() -> bool { return stp.open }

// While it is open the dialog takes every press and wheel turn: the page under it gets none.
setup_captures :: proc() -> bool { return stp.open }

////////////////////////////////
// The profile's memory of what the user answered

// "standalone" (never ask again), "dismissed" (asked, closed without answering: not again for this version), or "".
setup_choice :: proc(app: ^App) -> (choice, version: string) {
	data, err := os.read_entire_file(strings.concatenate({app.profile_dir, "/", SETUP_CHOICE_FILE}, context.temp_allocator), context.temp_allocator)
	if err != nil { return }
	for line in strings.split_lines(string(data), context.temp_allocator) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "choice=") { choice = l[len("choice="):] }
		if strings.has_prefix(l, "version=") { version = l[len("version="):] }
	}
	return
}

setup_choice_write :: proc(app: ^App, choice: string) {
	if !app.cfg.persist_profile { return }
	text := fmt.tprintf("wren setup: what was answered\nchoice=%s\nversion=%s\nchannel=%s\n", choice, APP_VERSION, channel_name())
	_ = os.write_entire_file(strings.concatenate({app.profile_dir, "/", SETUP_CHOICE_FILE}, context.temp_allocator), text)
}

setup_choice_blocks :: proc(app: ^App) -> bool {
	choice, version := setup_choice(app)
	return choice == "standalone" || (choice == "dismissed" && version == APP_VERSION)
}

////////////////////////////////
// Reading

@(private)
Setup_Job_Kind :: enum u8 { Read, Apply, Uninstall, Clean }

@(private)
Setup_Job :: struct {
	kind:        Setup_Job_Kind,
	reason:      Setup_Reason,
	opts:        desktop.Options,      // the options the job works with (owned copy; exe is the executable the integration runs)
	running_exe: string,
	target_dir:  string,               // Apply: the folder to install into
	old_dir:     string,               // Apply: the folder of the copy being moved ("" when none)
	result:      desktop.Result,       // the detail is cloned
	leftovers:   [dynamic]string,      // what a running program holds: heap strings
	folder_left: string,
	facts:       Setup_Facts,          // read after the work
	installed_now: bool,
}

// The options of the integration of this copy (and of the dialog's checkboxes when `with_dialog`).
@(private)
setup_options :: proc(app: ^App) -> desktop.Options {
	o := desktop_options(app)
	return o
}

@(private)
setup_job_start :: proc(app: ^App, kind: Setup_Job_Kind, reason: Setup_Reason) {
	job := new(Setup_Job)
	job.kind, job.reason = kind, reason
	job.opts = desktop.options_clone(setup_options(app))
	job.running_exe = strings.clone(desktop.executable_path())
	stp.busy += 1
	host.run_blocking(&app.blocking, setup_job_work, setup_job_done, job)
}

@(private)
setup_job_work :: proc(data: rawptr) {
	job := (^Setup_Job)(data)
	o := &job.opts
	switch job.kind {
	case .Read:
	case .Apply:     setup_apply_work(job)
	case .Uninstall: setup_uninstall_work(job)
	case .Clean:     // the `.old` files an earlier replacement left beside this installed copy; nothing is read
		desktop.clean_old(desktop.parent_dir(job.running_exe))
		return
	}
	job.result.detail = strings.clone(job.result.detail)
	// the leftovers and the folder are in the worker's temporary allocator: copy them for the interface thread
	left := make([dynamic]string)
	for l in job.leftovers { append(&left, strings.clone(l)) }
	job.leftovers = left
	job.folder_left = strings.clone(job.folder_left)
	// the state, as it is now
	job.facts = setup_read_facts(o, job.running_exe)
	if job.kind == .Read || job.reason == .Startup { desktop.clean_old(desktop.parent_dir(job.running_exe)) }
}

// Reads the installed copy and the integration: what the dialog shows. Heap allocations: the caller owns them.
@(private)
setup_read_facts :: proc(o: ^desktop.Options, running_exe: string) -> Setup_Facts {
	f: Setup_Facts
	f.running_exe = strings.clone(running_exe)
	probe := o^
	probe.install_dir = ""
	probe.exe = running_exe
	dir := desktop.install_target(&probe)   // the recorded folder, else the default (the scratch root of a test: its install_dir)
	if o.install_dir != "" { dir = o.install_dir }
	f.installed_dir = strings.clone(dir)
	f.inst = desktop.installed_info(&probe, dir)
	// the integration is measured against the installed executable (this one when none is installed)
	measured := f.inst.exe_present ? f.inst.exe : running_exe
	f.integ_exe = strings.clone(measured)
	probe.exe = measured
	f.integ = desktop.status(&probe)
	f.integ_complete = f.integ.state == .Installed || (f.integ.state == .Absent && f.integ.wanted == {})
	if f.integ.stale_exe != "" { f.other_target = strings.clone(f.integ.stale_exe) }
	f.kind = setup_classify(running_exe, APP_VERSION, f.inst, f.integ_complete)
	return f
}

// The executable the options integrate: a copy on the heap, because the options own it (options_destroy frees it).
@(private)
set_exe :: proc(o: ^desktop.Options, exe: string) {
	delete(o.exe)
	o.exe = strings.clone(exe)
}

@(private)
setup_apply_work :: proc(job: ^Setup_Job) {
	o := &job.opts
	id := o.identity
	if problem := desktop.check_install_dir(job.target_dir, probe = true); problem != "" {
		job.result = {.Bad_Options, problem}
		return
	}
	exe_name := desktop.exe_name_of(id)
	target_exe := strings.concatenate({strings.trim_right(job.target_dir, "\\/"), desktop.PATH_SEP, exe_name}, context.temp_allocator)
	plan := desktop.Install_Plan{
		src_exe = job.running_exe, dir = job.target_dir, exe_name = exe_name,
		payload = SETUP_PAYLOAD[:], version = APP_VERSION, channel = channel_name(),
	}
	if r := desktop.files_install(plan); r.error != .None { job.result = r; return }
	set_exe(o, target_exe)
	if r := desktop.install(o); r.error != .None { job.result = r; return }
	if r := desktop.record_install(o, job.target_dir, APP_VERSION); r.error != .None { job.result = r; return }
	job.installed_now = true

	// a copy that is moved: the old folder goes (its PATH entry, its files; what a running program holds is left for later)
	if job.old_dir != "" && !desktop.same_path(job.old_dir, job.target_dir) {
		old := o^
		old.exe = strings.concatenate({strings.trim_right(job.old_dir, "\\/"), desktop.PATH_SEP, exe_name}, context.temp_allocator)
		desktop.forget_path(&old, job.old_dir)
		rm := desktop.files_remove(&old, job.old_dir)
		for l in rm.leftovers { append(&job.leftovers, l) }
		if len(rm.leftovers) > 0 { job.folder_left = job.old_dir }
	}
}

@(private)
setup_uninstall_work :: proc(job: ^Setup_Job) {
	o := &job.opts
	dir := job.target_dir   // the installed folder
	exe_name := desktop.exe_name_of(o.identity)
	set_exe(o, dir != "" ? strings.concatenate({strings.trim_right(dir, "\\/"), desktop.PATH_SEP, exe_name}, context.temp_allocator) : job.running_exe)
	if r := desktop.remove(o); r.error != .None { job.result = r }   // (keep going: the files should go even when a key would not)
	if dir != "" {
		desktop.forget_path(o, dir)
		desktop.unrecord_install(o)
		rm := desktop.files_remove(o, dir)
		for l in rm.leftovers { append(&job.leftovers, l) }
		if len(rm.leftovers) > 0 { job.folder_left = dir }
	} else {
		desktop.unrecord_install(o)
	}
}

@(private)
setup_job_done :: proc(data: rawptr) {
	job := (^Setup_Job)(data)
	app := the_app
	defer {
		delete(job.result.detail)
		for l in job.leftovers { delete(l) }
		delete(job.leftovers)
		delete(job.folder_left)
		delete(job.running_exe)
		delete(job.target_dir)
		delete(job.old_dir)
		desktop.options_destroy(&job.opts)
		setup_facts_destroy(&job.facts)
		free(job)
		stp.busy -= 1
	}
	if app == nil { return }
	if job.kind == .Clean { return }
	setup_facts_destroy(&stp.facts)
	stp.facts, job.facts = job.facts, {}
	stp.known = true
	if job.reason == .Startup && job.kind == .Read {
		// the first run of a copy that is not the installed one (or an installation that wants attention): the dialog opens
		if !stp.open && setup_should_offer(&stp.facts) { stp.open, stp.reason = true, .Startup; stp.focus_primary = true }
	}
	if job.kind != .Read {
		stp.opts_ready = false   // the checkboxes follow the disk again
		stp.path_ready = false
		stp.confirm_uninstall = false
		for l in job.leftovers {
			append(&stp.cleanup, strings.clone(l))
		}
		if job.folder_left != "" && stp.cleanup_dir == "" { stp.cleanup_dir = strings.clone(job.folder_left) }
		verb := job.kind == .Apply ? "install" : "uninstall"
		if job.result.error != .None {
			setup_note(fmt.tprintf("Could not %s: %s (%s)", verb, desktop.error_text(job.result.error), job.result.detail), "bad")
			ui.toast(.Warn, "%s", stp.note)
		} else if job.kind == .Apply {
			setup_remember_options(app)
			setup_note(fmt.tprintf("%s is installed in %s. The Start menu and the other shortcuts open that copy.", APP_NAME, job.target_dir), "good")
			ui.toast(.Good, "%s is installed", APP_NAME)
			setup_choice_write(app, "installed")
			// installed again in the folder that was uninstalled while it ran: its manifest and folder are not for the helper to delete
			if desktop.same_path(stp.cleanup_dir, job.target_dir) { delete(stp.cleanup_dir); stp.cleanup_dir = "" }
		} else {
			msg := "Wren is uninstalled: its shortcuts, its entry in Settings > Apps and its files are gone."
			if len(job.leftovers) > 0 { msg = "Wren is uninstalled. The files of this running copy are deleted when you close it." }
			setup_note(msg, "good")
			ui.toast(.Good, "%s is uninstalled", APP_NAME)
		}
	}
	app.frames_requested = max(app.frames_requested, 3)
}

@(private)
setup_note :: proc(text, tone: string) {
	delete(stp.note)
	stp.note = strings.clone(text)
	stp.note_tone = tone
}

// Waits for the jobs out (their completion frees them); before the pool and the loop go.
setup_shutdown :: proc(app: ^App) {
	for stp.busy > 0 { host.blocking_settle(&app.blocking) }
	// files a running program held (this one's own): deleted once this process has ended
	if len(stp.cleanup) > 0 {
		files := make([dynamic]string, context.temp_allocator)
		for f in stp.cleanup { append(&files, f) }
		if stp.cleanup_dir != "" { append(&files, strings.concatenate({stp.cleanup_dir, desktop.PATH_SEP, desktop.MANIFEST_NAME}, context.temp_allocator)) }
		desktop.cleanup_later(files[:], stp.cleanup_dir, desktop.current_process_id())
	}
	setup_destroy()
}

////////////////////////////////
// Opening and closing

// Opens the dialog (the command, --setup): the disk is read again.
setup_open :: proc(app: ^App, reason := Setup_Reason.Command) {
	if !desktop.supported() { ui.toast(.Info, "Setup is not available on this platform"); return }
	if stp.open { return }
	stp.open, stp.reason = true, reason
	stp.opts_ready, stp.path_ready = false, false
	stp.confirm_uninstall = false
	stp.focus_primary = true
	if stp.width_em == 0 { stp.width_em = 46 }
	setup_note("", "weak")
	desktop_watch_ensure(app)   // desktop_shell.odin: the dialog follows the disk it shows
	stp.seen_changes = desktop_changes()
	if reason == .Command {   // (at start-up the interface does not exist yet)
		ui.ctx_menu_close()
		if cpal.open { palette_close(app) }
	}
	setup_job_start(app, .Read, reason)
	app.frames_requested = max(app.frames_requested, 3)
}

// While the dialog is open, the disk is read again when the system watcher (desktop_shell.odin) says the integration
// changed there (Settings > Apps, another Wren, a script): the state and the badge follow, the boxes the user is editing
// do not move. A job out reads the disk at its end, so the next frame after it looks again.
@(private)
setup_follow_disk :: proc(app: ^App) {
	n := desktop_changes()
	if n == stp.seen_changes || stp.busy > 0 || !stp.known { return }
	stp.seen_changes = n
	setup_job_start(app, .Read, .Command)
}

// The dialog was closed (X, Escape, a click outside): not an answer, so it is asked again after the next update.
setup_dismiss :: proc(app: ^App) {
	stp.open = false
	stp.confirm_uninstall = false
	if stp.reason == .Startup { setup_choice_write(app, "dismissed") }
	app.frames_requested = max(app.frames_requested, 2)
}

// "Use standalone": carry on without installing, and do not ask again.
setup_use_standalone :: proc(app: ^App) {
	stp.open = false
	setup_choice_write(app, "standalone")
	ui.toast(.Info, "%s runs standalone. Setup is in the menu if you change your mind.", APP_NAME)
	app.frames_requested = max(app.frames_requested, 2)
}

////////////////////////////////
// Start-up

// Should the dialog open by itself for what was read? Not for an installation that is as it should be.
setup_should_offer :: proc(f: ^Setup_Facts) -> bool {
	switch f.kind {
	case .Loading, .Running_Installed: return false
	case .Not_Installed, .Other_Copy, .Older, .Repair: return true
	}
	return false
}

// A copy that keeps everything beside its executable: a file `wren.portable` next to it. Its profile (preferences,
// cookies, history, session, crash reports, licence) is the folder `data` there, so the whole folder can be carried on a
// stick; it never offers Setup by itself. `--profile DIR` still wins. "" when the copy is not portable.
PORTABLE_MARKER :: "wren.portable"

portable_profile_dir :: proc() -> string {
	exe := desktop.executable_path(context.temp_allocator)
	dir := desktop.parent_dir(exe)
	if dir == "" { return "" }
	if !os.exists(strings.concatenate({dir, desktop.PATH_SEP, PORTABLE_MARKER}, context.temp_allocator)) { return "" }
	return strings.concatenate({dir, desktop.PATH_SEP, "data"}, context.temp_allocator)
}

// After the first tab exists. `force`: --setup (open it whatever the build and the profile).
setup_startup :: proc(app: ^App, profile_explicit: bool, force: bool) {
	if !desktop.supported() { return }
	// an installed copy removes what a replacement left beside it (the `.old` files), whatever else is decided below
	if os.exists(strings.concatenate({desktop.parent_dir(desktop.executable_path(context.temp_allocator)), desktop.PATH_SEP, desktop.MANIFEST_NAME}, context.temp_allocator)) { setup_job_start(app, .Clean, .Startup) }
	if force { setup_open(app, .Cli); return }
	if v, ok := os.lookup_env("WREN_DESKTOP_INTEGRATION", context.temp_allocator); ok && v == "off" { return }   // tools\test_env.ps1: every script's runs
	if desktop_profile_is_disposable(app, profile_explicit) { return }
	if app.portable { return }
	if !config.bool_of(&app.prefs, "browser.desktop_integration.on_first_run") { return }
	if setup_choice_blocks(app) { return }
	setup_job_start(app, .Read, .Startup)
}

////////////////////////////////
// Doing

// The folder the field names (trimmed).
@(private)
setup_target :: proc() -> string { return strings.trim_space(ui.field_string(&stp.path)) }

// Is the folder asked for another than the one of the installed copy?
setup_moving :: proc() -> bool {
	return stp.facts.inst.exe_present && !desktop.same_path(stp.facts.inst.dir, setup_target())
}

setup_apply :: proc(app: ^App) {
	if stp.busy > 0 || !stp.known || stp.path_problem != "" { return }
	job := new(Setup_Job)
	job.kind, job.reason = .Apply, .Command
	o := setup_options(app)
	o.start_menu = stp.opts[.Start_Menu]
	o.desktop_shortcut = stp.opts[.Desktop_Shortcut]
	o.add_to_path = stp.opts[.Add_To_Path]
	o.register_browser = stp.opts[.Register_Browser]
	job.opts = desktop.options_clone(o)
	job.running_exe = strings.clone(desktop.executable_path())
	job.target_dir = strings.clone(setup_target())
	if stp.facts.inst.exe_present && setup_moving() { job.old_dir = strings.clone(stp.facts.inst.dir) }
	// the checkboxes are the preferences from now on (Modify, --desktop-integration and the box in about:config agree)
	setup_remember_options(app)
	stp.busy += 1
	host.run_blocking(&app.blocking, setup_job_work, setup_job_done, job)
	setup_note("Working…", "weak")
	app.frames_requested = max(app.frames_requested, 3)
}

@(private)
setup_remember_options :: proc(app: ^App) {
	set :: proc(app: ^App, name: string, v: bool) { _ = config.set_from_string(&app.prefs, name, v ? "true" : "false", .User) }
	set(app, "browser.desktop_integration.start_menu", stp.opts[.Start_Menu])
	set(app, "browser.desktop_integration.desktop_shortcut", stp.opts[.Desktop_Shortcut])
	set(app, "browser.desktop_integration.add_to_path", stp.opts[.Add_To_Path])
	set(app, "browser.desktop_integration.register_browser", stp.opts[.Register_Browser])
	set(app, "browser.update.check_daily", stp.opts[.Check_Daily])
}

setup_uninstall :: proc(app: ^App) {
	if stp.busy > 0 || !stp.known { return }
	job := new(Setup_Job)
	job.kind, job.reason = .Uninstall, .Command
	job.opts = desktop.options_clone(setup_options(app))
	job.running_exe = strings.clone(desktop.executable_path())
	job.target_dir = stp.facts.inst.exe_present || stp.facts.inst.manifest ? strings.clone(stp.facts.inst.dir) : ""
	stp.busy += 1
	host.run_blocking(&app.blocking, setup_job_work, setup_job_done, job)
	setup_note("Working…", "weak")
	app.frames_requested = max(app.frames_requested, 3)
}

// The dialog's checkboxes and field follow the disk (or the preferences when nothing is installed).
@(private)
setup_sync_inputs :: proc(app: ^App) {
	if !stp.known { return }
	f := &stp.facts
	if !stp.path_ready {
		ui.field_set(&stp.path, f.installed_dir)
		stp.path_ready = true
	}
	if !stp.opts_ready {
		installed := f.inst.exe_present
		pref :: proc(app: ^App, name: string) -> bool { return config.bool_of(&app.prefs, name) }
		// what the boxes show: the disk for an installation that is as it should be (they say what IS there), and what was
		// chosen (the preferences) for anything else; an installation to repair keeps what is still there too, so that
		// Repair puts back what is missing and takes nothing away
		from_disk := installed && (f.kind == .Running_Installed || f.kind == .Other_Copy || f.kind == .Older)
		both := installed && f.kind == .Repair
		part :: proc(f: ^Setup_Facts, p: desktop.Part, wanted, from_disk, both: bool) -> bool {
			present := f.integ.parts[p].present
			switch {
			case from_disk: return present
			case both:      return present || wanted
			}
			return wanted
		}
		stp.opts[.Start_Menu] = part(f, .Launcher, pref(app, "browser.desktop_integration.start_menu"), from_disk, both)
		stp.opts[.Desktop_Shortcut] = part(f, .Desktop_Shortcut, pref(app, "browser.desktop_integration.desktop_shortcut"), from_disk, both)
		stp.opts[.Add_To_Path] = part(f, .Path, pref(app, "browser.desktop_integration.add_to_path"), from_disk, both)
		stp.opts[.Register_Browser] = part(f, .Registration, pref(app, "browser.desktop_integration.register_browser"), from_disk, both)
		stp.opts[.Check_Daily] = pref(app, "browser.update.check_daily")
		stp.baseline = stp.opts
		stp.opts_ready = true
	}
}

// The field's text has changed: is it a folder Wren can be installed in?
@(private)
setup_validate :: proc() {
	text := setup_target()
	if text == stp.path_text && stp.path_ready { return }
	delete(stp.path_text)
	stp.path_text = strings.clone(text)
	delete(stp.path_problem)
	stp.path_problem = strings.clone(desktop.check_install_dir(text))
}
