package browser

// Wren Setup: the one executable is its own installer, through the toolkit's install (prefs_page.Install over
// toolkit:setup): the offer at a start, the modal (the command "Setup…", `wren --setup`), the Installation page of
// about:settings, and the answer kept in the preferences (install.choice). Wren gives it its identity, its icons, the
// console launcher (Windows), the places of a test (WREN_DESKTOP_* roots) and choices of its own: the PATH, the
// registration as a browser, and (where Wren updates itself) the updates.
//
// The offer opens by itself at the start of a copy that is not the installed one when setup.wanted says so (no install,
// one to repair, an older one to upgrade; not again after "Keep standalone", nor for a version closed without an
// answer); never for a profile given with --profile or kept in the temporary folder, a portable copy (a wren.portable
// file beside the executable), with browser.desktop_integration.on_first_run off, nor with WREN_DESKTOP_INTEGRATION=off
// in the environment. A copy of the Nix store is never offered it (setup.wanted). The reading still runs then: the
// updater asks which copy runs (Install.known, running_it).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import desktop "toolkit:desktop"
import process "toolkit:process"
import prefs_page "toolkit:prefs_page"
import setup "toolkit:setup"
import wren_desktop "wb:desktop"

// The order of Wren's choices in the dialog (Setup_Options.choices). Update_By_Itself only where Wren updates itself
// (UPDATES_SELF: update.auto is registered there alone).
Setup_Choice :: enum u8 { Add_To_Path, Register_Browser, Update_By_Itself }
SETUP_CHOICES :: len(Setup_Choice) when UPDATES_SELF else len(Setup_Choice) - 1

// What Wren keeps around the toolkit's install (App.stp; the install itself is App.install).
Setup_State :: struct {
	choices:    [len(Setup_Choice)]setup.Choice,   // the boxes' first values, from the preferences (setup_follow_prefs)
	file_types: string,     // browser.desktop_integration.file_types (owned): read by the dialog's thread, replaced only while it is closed
	asked:      bool,       // setup_open: the next build of the window the person is in opens the modal
	at_primary, at_uninstall, at_secondary: draw.Rect,   // where the last frame put its buttons (control_setup_state)
}

setup_is_open :: proc(app: ^App) -> bool { return prefs_page.install_open_now(&app.install) || app.stp.asked }

// The setup's options: Wren's identity, version, icons and choices. Its strings are constants and `user` the App: the
// dialog's thread and Install keep a copy that outlives the call.
setup_config :: proc(app: ^App) -> setup.Setup_Options {
	setup_follow_prefs(app)
	return setup.Setup_Options{
		identity = desktop_identity(), version = APP_VERSION, icons = desktop_icons(), choices = app.stp.choices[:SETUP_CHOICES],
		prepare = setup_prepare, folder = true, square = true, user = app,
		running = instance_running, quit = instance_quit,   // instance_shell.odin: the Wren that runs on this profile
	}
}

// The boxes' first values and the file types, as the preferences say now: only while no dialog works (its thread
// reads both). Before the modal opens and before the Installation page builds (its controller starts there).
setup_follow_prefs :: proc(app: ^App) {
	if app.install.dialog.open || app.install.dialog.job != nil { return }
	app.stp.choices[Setup_Choice.Add_To_Path] = {label = "Add Wren to PATH", on = app.desktop_cfg.add_to_path}
	app.stp.choices[Setup_Choice.Register_Browser] = {label = "Register as a browser", on = app.desktop_cfg.register_browser}
	when UPDATES_SELF {
		app.stp.choices[Setup_Choice.Update_By_Itself] = {label = "Update by itself", on = app.desktop_cfg.update_auto}
	}
	types := app.desktop_cfg.file_types
	if types != app.stp.file_types {
		delete(app.stp.file_types)
		app.stp.file_types = strings.clone(types)
	}
}

// Wren's part of the options, on whatever thread the dialog works on: nothing of the App but what it set before.
@(private = "file")
setup_prepare :: proc(o: ^desktop.Integration_Options, choices: []bool, user: rawptr) {
	app := (^App)(user)
	o.start_menu = true
	if len(choices) >= 2 {
		o.add_to_path = choices[Setup_Choice.Add_To_Path]
		o.register_browser = choices[Setup_Choice.Register_Browser]
	}
	o.file_types = wren_desktop.file_types_of(app.stp.file_types)
	o.launcher = console_launcher()   // console_launcher_*.odin
	desktop.roots_from_env(o, env_lookup)   // (WREN_DESKTOP_* of a test: every place is the test's)
}

////////////////////////////////
// Opening, each frame, the end

// Opens the modal (the command, --setup, a second start's --setup): it opens in the next build of the window the person
// is in (setup_build), from a build or not.
setup_open :: proc(app: ^App) {
	if !desktop.supported() { announce(app, .Info, "Setup is not available on this platform"); return }
	if setup_is_open(app) { return }
	if ui.building() {
		ui.menu_close()
		palette_hide(app)
	}
	app.stp.asked = true
	request_frames(app, 3)
}

// Each frame of each window, in its build: the modal opened when asked, its marks once the renderer exists, the work it
// collects, what its events leave beyond install.choice (which the toolkit keeps).
setup_build :: proc(app: ^App) {
	if app.install.prefs == nil { return }   // (setup_startup did not run: a test's App)
	if .Renderer in app.made {
		// (the 256 px picture: the window's icon, a title bar's 16 to 24 px drawn at 4 em, was blurred)
		// (Install.logo is the program's to make and free: install_end frees the vendor's mark alone)
		if app.install.logo == nil {
			if l, ok := setup.logo_make(&app.r, APP_LOGO_PNG); ok { app.install.logo = l }
		}
		_ = prefs_page.install_vendor_mark(&app.install, &app.r, FROMENT_LOGO_PNG)   // (once: later calls do nothing)
	}
	if app.stp.asked && window_is_front(app) {
		app.stp.asked = false
		setup_follow_prefs(app)   // (the boxes start as the preferences say now: Install's options share their array)
		prefs_page.install_open(&app.install)
	}
	d := &app.install.dialog
	#partial switch prefs_page.install_frame(&app.install) {
	case .Installed:
		// what was ticked is what the preferences say from now on (about:config's integration row, the updates)
		if len(d.choices) >= 2 {
			set_pref_bool(app, "browser.desktop_integration.add_to_path", d.choices[Setup_Choice.Add_To_Path])
			set_pref_bool(app, "browser.desktop_integration.register_browser", d.choices[Setup_Choice.Register_Browser])
		}
		when UPDATES_SELF {
			if len(d.choices) == len(Setup_Choice) { set_pref_bool(app, prefs_page.UPDATE_AUTO_PREF, d.choices[Setup_Choice.Update_By_Itself]) }
		}
		set_pref_bool(app, "browser.desktop_integration.desktop_shortcut", d.shortcut)
	case .Kept_Standalone:
		announce(app, .Info, fmt.tprintf("%s runs standalone. Setup is in the menu if you change your mind.", APP_NAME))
	case .Launched:
		// (the installed copy starts once this one has ended and let go of its profile: setup_shutdown, app_stop)
		app.quitting = true
		platform.request_close(active_window(app).win)
	}
	// where its buttons are, for the remote channel (the tests click them)
	app.stp.at_primary, app.stp.at_uninstall, app.stp.at_secondary = d.at[.Install], d.at[.Uninstall], d.at[.Secondary]
	if d.open { request_frames(app, 1) }   // (the work it waits for comes back by a post; the frame after it reads it)
}

// At the end of the process, before the windows' states and the renderer go: what an uninstall left because this process
// held it goes then, the dialog's thread is waited for; the installed copy to start after the end is kept (App.relaunch).
setup_shutdown :: proc(app: ^App) {
	if app.install.prefs != nil {
		if app.install.launch != "" {
			delete(app.relaunch)
			app.relaunch, app.install.launch = app.install.launch, ""
		}
		prefs_page.install_end(&app.install)
	}
	if .Renderer in app.made { setup.logo_destroy(&app.r, &app.install.logo) }
	app.install = {}
	delete(app.stp.file_types)
	app.stp = {}
}

////////////////////////////////
// Start-up

// A copy that keeps everything beside its executable: a file `wren.portable` next to it. Its profile (preferences,
// cookies, history, session, crash reports, licence) is the folder `data` there, so the whole folder can be carried on a
// stick; it never offers Setup by itself. `--profile DIR` still wins. "" when the copy is not portable.
PORTABLE_MARKER :: "wren.portable"

portable_profile_dir :: proc() -> string {
	exe := process.executable_path(context.temp_allocator)
	dir := process.parent_dir(exe)
	if dir == "" { return "" }
	if !os.exists(strings.concatenate({dir, filepath.SEPARATOR_STRING, PORTABLE_MARKER}, context.temp_allocator)) { return "" }
	return strings.concatenate({dir, filepath.SEPARATOR_STRING, "data"}, context.temp_allocator)
}

// Once the first window's interface exists (its State takes the reading's answer). `force`: --setup (the modal whatever
// the build and the profile).
setup_startup :: proc(app: ^App, profile_explicit: bool, force: bool) {
	if !desktop.supported() { return }
	prefs_page.install_init(&app.install, &app.prefs, setup_config(app), &app.announcer)   // (install_follow says there when the desktop refuses general.menu or general.autostart)
	offer := app.desktop_cfg.on_first_run
	if v, ok := os.lookup_env("WREN_DESKTOP_INTEGRATION", context.temp_allocator); ok && v == "off" { offer = false }   // src/e2e sets it for every test
	if desktop_profile_is_disposable(app, profile_explicit) || app.portable || force { offer = false }
	// (always read: the installed copy deletes what an update replaced, and the updater learns which copy runs)
	prefs_page.install_offer(&app.install, active_window(app).ui, offer)
	if force { setup_open(app) }
}
