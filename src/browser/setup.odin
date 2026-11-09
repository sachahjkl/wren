package browser

// Wren Setup: the one executable is its own installer, with the toolkit's Setup dialog (toolkit:setup): install this copy
// (into the default folder, "Wren Dev" for the development channel, or one the user chooses), repair, upgrade or replace
// the installed copy, uninstall it, or carry on without installing ("Keep standalone", remembered in the profile). The
// dialog does its work on a thread of its own and follows the disk while it is open; Wren gives it its identity, its
// icons, the console launcher (Windows), the places of a test (WREN_DESKTOP_* roots) and three choices of its own:
// the PATH, the registration as a browser, and the daily update check.
//
// Opens by itself (setup_startup) at the start of a copy that is not the installed one when setup.wanted says so (no
// install, one to repair, an older one to upgrade; not again after "Keep standalone", nor for a version closed without an
// answer); never for a profile given with --profile or kept in the temporary folder, a portable copy (a wren.portable file
// beside the executable), a copy of the Nix store, nor with WREN_DESKTOP_INTEGRATION=off in the environment. The command
// "Setup…" (menu, palette) and `wren --setup` open it whatever the build.

import "core:os"
import "core:path/filepath"
import "core:strings"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import "wb:config"
import desktop "toolkit:desktop"
import process "toolkit:process"
import setup "toolkit:setup"
import "wb:host"
import wren_desktop "wb:desktop"

SETUP_CHOICE_FILE :: "setup.txt"

// The order of Wren's choices in the dialog (Config.choices).
Setup_Choice :: enum u8 { Add_To_Path, Register_Browser, Check_Daily }

SETUP_PREFS := [?]config.Def{
	{name = "browser.update.check_daily", kind = .Bool, default = {b = false},
		description = "Once a day, ask GitHub's releases API (api.github.com/repos/sachahjkl/wren/releases/latest) whether a newer Wren exists and say so with a notice. Nothing is downloaded or installed by itself; no other data is sent than an ordinary request with Wren's user agent. Off by default: no network request is made until you tick \"Check for updates once a day\" in Setup. The command \"Check for updates\" asks once, whatever this says."},
	{name = "browser.update.url", kind = .String, default = {s = "https://api.github.com/repos/sachahjkl/wren/releases/latest"},
		description = "The address the update check reads (a JSON document with tag_name and html_url, as GitHub's \"latest release\" answers). For tests and mirrors."},
	{name = "browser.update.base_url", kind = .String, default = {s = "https://github.com/sachahjkl/wren/releases/download/"},
		description = "Where the files of a release are fetched from when you install an update: <this>v<version>/update-windows-x64.json (the signed manifest), its .sig and the program. An address ending in /, https (or http on this computer). A mirror or a test server sets it; the signature is checked whatever the address."},
	{name = "browser.update.public_key", kind = .String, default = {s = ""},
		description = "The key (base64url of 32 bytes) that a release's manifest must be signed with, instead of the one built into Wren. Empty: the built-in one. For trying releases made with another key (the tests); setting it widens whom you trust to update Wren."},
	{name = "browser.update.require_signature", kind = .Bool, default = {b = true},
		description = "Install an update only when its manifest carries a valid signature of the key above (the built-in one, or browser.update.public_key). Turn it off only for a channel of your own that does not sign: the file's length and SHA-256 are then checked against an unsigned manifest, which proves nothing about who made it. A channel is: browser.update.url (what announces a release), browser.update.base_url (where its files are), this and browser.update.public_key."},
	{name = "browser.update.allow_development_build", kind = .Bool, default = {b = false},
		description = "Let a development build install a release over itself. For the tests of the updater only: a development build is updated by hand."},
}

// What Wren keeps of the dialog (App.stp).
Setup_State :: struct {
	d:          setup.Dialog,
	choices:    [len(Setup_Choice)]setup.Choice,   // the boxes' first values, from the preferences (setup_config; by Setup_Choice)
	file_types: string,                       // browser.desktop_integration.file_types when the dialog opened (owned): read by its thread
	deciding:   int,                          // the start's reading of the install, out on the blocking pool
	at_primary, at_uninstall, at_secondary: draw.Rect,   // where the last frame put its buttons (control_setup_state)
}

setup_is_open :: proc(app: ^App) -> bool { return app.stp.d.open }

// While it is open the dialog takes every press and wheel turn: the page under it gets none.
setup_captures :: proc(app: ^App) -> bool { return app.stp.d.open }

// The dialog's Config: Wren's identity, version, icons and choices. Called on the interface thread; the dialog's thread
// keeps a copy, whose strings and `user` (the App) outlive it.
setup_config :: proc(app: ^App) -> setup.Config {
	p := &app.prefs
	app.stp.choices[Setup_Choice.Add_To_Path] = {label = "Add Wren to PATH", on = config.bool_of(p, "browser.desktop_integration.add_to_path")}
	app.stp.choices[Setup_Choice.Register_Browser] = {label = "Register as a browser", on = config.bool_of(p, "browser.desktop_integration.register_browser")}
	app.stp.choices[Setup_Choice.Check_Daily] = {label = "Check for updates once per day", on = config.bool_of(p, "browser.update.check_daily")}
	return setup.Config{
		identity = desktop_identity(), version = APP_VERSION, icons = desktop_icons(), choices = app.stp.choices[:],
		prepare = setup_prepare, folder = true, square = true, user = app,
	}
}

// Wren's part of the options, on whatever thread the dialog works on: nothing of the App but what it set before.
@(private = "file")
setup_prepare :: proc(o: ^desktop.Options, choices: []bool, user: rawptr) {
	app := (^App)(user)
	o.start_menu = true
	if len(choices) == len(Setup_Choice) {
		o.add_to_path = choices[Setup_Choice.Add_To_Path]
		o.register_browser = choices[Setup_Choice.Register_Browser]
	}
	o.file_types = wren_desktop.file_types_of(app.stp.file_types)
	when ODIN_OS == .Windows { o.launcher = CONSOLE_LAUNCHER }
	desktop.roots_from_env(o, env_lookup)   // (WREN_DESKTOP_* of a test: every place is the test's)
}

////////////////////////////////
// The profile's memory of what the user answered

// The choice of setup ("installed", "standalone", "dismissed:<version>", or "").
setup_choice :: proc(app: ^App) -> string {
	data, err := os.read_entire_file(strings.concatenate({app.profile_dir, "/", SETUP_CHOICE_FILE}, context.temp_allocator), context.temp_allocator)
	if err != nil { return "" }
	for line in strings.split_lines(string(data), context.temp_allocator) {
		if l := strings.trim_space(line); strings.has_prefix(l, "choice=") { return l[len("choice="):] }
	}
	return ""
}

@(private = "file")
setup_choice_write :: proc(app: ^App, choice: string) {
	if !app.cfg.persist_profile { return }
	text := strings.concatenate({"wren setup: what was answered\nchoice=", choice, "\nversion=", APP_VERSION, "\nchannel=", channel_name(), "\n"}, context.temp_allocator)
	_ = os.write_entire_file(strings.concatenate({app.profile_dir, "/", SETUP_CHOICE_FILE}, context.temp_allocator), text)
}

////////////////////////////////
// Opening, each frame, the end

// Opens the dialog (the command, --setup, the start).
setup_open :: proc(app: ^App) {
	if !desktop.supported() { ui.toast(.Info, "Setup is not available on this platform"); return }
	if app.stp.d.open { return }
	delete(app.stp.file_types)
	app.stp.file_types = strings.clone(config.string_of(&app.prefs, "browser.desktop_integration.file_types"))
	if ui.building() {
		ui.ctx_menu_close()
		if app.cpal.open { palette_close(app) }
	}
	setup.open(&app.stp.d, setup_config(app))
	request_frames(app, 3)
}

// Each frame of the active window: the dialog (a modal while open), the work it collects, what its events leave.
setup_build :: proc(app: ^App) {
	logo: Maybe(setup.Logo)
	if app.wchrome.icon_px > 0 { logo = setup.Logo{app.wchrome.icon, {f32(app.wchrome.icon_px), f32(app.wchrome.icon_px)}} }
	d := &app.stp.d
	ev := setup.dialog(d, setup_config(app), ui.font_size(), logo)
	switch ev {
	case .None:
	case .Installed:
		setup_choice_write(app, setup.CHOICE_INSTALLED)
		// what was ticked is what the preferences say from now on (about:config's integration row, the update check)
		if len(d.choices) == len(Setup_Choice) {
			set_pref_bool(app, "browser.desktop_integration.add_to_path", d.choices[Setup_Choice.Add_To_Path])
			set_pref_bool(app, "browser.desktop_integration.register_browser", d.choices[Setup_Choice.Register_Browser])
			set_pref_bool(app, "browser.update.check_daily", d.choices[Setup_Choice.Check_Daily])
		}
		set_pref_bool(app, "browser.desktop_integration.desktop_shortcut", d.shortcut)
	case .Uninstalled:
	case .Kept_Standalone:
		setup_choice_write(app, setup.CHOICE_STANDALONE)
		ui.toast(.Info, "%s runs standalone. Setup is in the menu if you change your mind.", APP_NAME)
	case .Dismissed:
		saved := setup_choice(app)
		if setup.is_upgrade(d.facts, APP_VERSION) || (saved != setup.CHOICE_STANDALONE && saved != setup.CHOICE_INSTALLED) {
			setup_choice_write(app, setup.choice_dismissed(APP_VERSION))
		}
	case .Launched:
		app.quitting = true   // (the installed copy runs now: this one ends)
		platform.request_close(active_window(app).win)
	}
	// where its buttons are, for the remote channel (the tests click them)
	app.stp.at_primary, app.stp.at_uninstall, app.stp.at_secondary = d.at[.Install], d.at[.Uninstall], d.at[.Secondary]
	if d.open { request_frames(app, 1) }   // (the work it waits for comes back by a post; the frame after it reads it)
}

// At the end of the process: what an uninstall left because this process held it goes then; the dialog's thread is
// waited for. Before the interface goes.
setup_shutdown :: proc(app: ^App) {
	for app.stp.deciding > 0 { host.blocking_settle(&app.blocking) }
	setup.finish(&app.stp.d, setup_config(app))
	setup.destroy(&app.stp.d)
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

@(private = "file")
Setup_Start_Job :: struct {
	app:    ^App,
	cfg:    setup.Config,
	clean:  bool,   // the installed copy: the `.old` files of a replacement go
	choice: string, // owned
	wanted: bool,
}

// After the first tab exists. `force`: --setup (open it whatever the build and the profile).
setup_startup :: proc(app: ^App, profile_explicit: bool, force: bool) {
	if !desktop.supported() { return }
	if force { setup_open(app); return }
	exe := process.executable_path(context.temp_allocator)
	clean := os.exists(strings.concatenate({process.parent_dir(exe), filepath.SEPARATOR_STRING, desktop_identity().manifest_name}, context.temp_allocator))
	offer := true
	if v, ok := os.lookup_env("WREN_DESKTOP_INTEGRATION", context.temp_allocator); ok && v == "off" { offer = false }   // src/e2e sets it for every test
	if desktop_profile_is_disposable(app, profile_explicit) || app.portable || desktop.in_nix_store(exe) { offer = false }
	if !config.bool_of(&app.prefs, "browser.desktop_integration.on_first_run") { offer = false }
	if !offer && !clean { return }
	// what the disk says is read on the blocking pool; the dialog opens if there is something to do
	delete(app.stp.file_types)
	app.stp.file_types = strings.clone(config.string_of(&app.prefs, "browser.desktop_integration.file_types"))
	job := new(Setup_Start_Job)
	job.app, job.cfg, job.clean = app, setup_config(app), clean
	job.choice = offer ? strings.clone(setup_choice(app)) : ""
	job.wanted = offer   // (until the facts say)
	app.stp.deciding += 1
	host.run_blocking(&app.blocking, proc(data: rawptr) {
		j := (^Setup_Start_Job)(data)
		if j.clean {
			o := desktop.Options{identity = j.cfg.identity}
			desktop.clean_old(&o, process.parent_dir(process.executable_path(context.temp_allocator)))
		}
		if j.wanted { j.wanted = setup.wanted(setup.facts(j.cfg), APP_VERSION, j.choice) }
		free_all(context.temp_allocator)
	}, proc(data: rawptr) {
		j := (^Setup_Start_Job)(data)
		j.app.stp.deciding -= 1
		if j.wanted { setup_open(j.app) }
		request_frames(j.app, 2)
		delete(j.choice)
		free(j)
	}, job)
}
