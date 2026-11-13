#+build windows
package e2e_scenarios

// The Setup dialog of a real wren.exe (setup.odin, the toolkit's setup package), and what it leaves on the disk and in the registry, against throwaway roots
// (desktop_scratch.odin): the Start menu, the Desktop, HKCU\Software and HKCU\Environment are the test's, the install folder and the profiles too. The
// dialog's input is Wren's own (no window of the system, no mouse): a key, a click at the place the dialog says its button is. What the real machine
// has is compared at the end.
//   A install with a click on the main button
//   B uninstall from the installed copy (two clicks; the running executable is deleted once the process has ended)
//   C "Use standalone" (remembered in the profile)
//   D the automatic opening at the first start, and not again after the answer
//   E nothing opens by itself with WREN_DESKTOP_INTEGRATION=off, with --profile, in a portable copy
//   F the daily update check

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:e2e"
import "wb:remote/api"

@(private = "file") INTEGRATION_ON :: "WREN_DESKTOP_INTEGRATION="   // (e2e sets it off for every program it starts)
@(private = "file") CHOICE_FILE :: "setup.txt"
@(private = "file") UPDATE_FILE :: "update.txt"
@(private = "file") FIRST_RUN_PREF :: "browser.desktop_integration.on_first_run=true"
@(private = "file") UPDATE_ON_PREF :: "update.auto=true"
// A release that is newer, as GitHub's API answers.
@(private = "file") NEWER_RELEASE :: "browser.update.url=data:application/json,%7B%22tag_name%22%3A%22v99.0.0%22%2C%22html_url%22%3A%22https%3A%2F%2Fgithub.com%2Fsachahjkl%2Fwren%2Freleases%2Ftag%2Fv99.0.0%22%7D"
@(private = "file") NEWER_STILL :: "browser.update.url=data:application/json,%7B%22tag_name%22%3A%22v100.0.0%22%7D"
// The profile's folder under APPDATA.
@(private = "file") PROFILE_IN_APPDATA :: "Wren"

// The environment of a start that finds its profile under `appdata`, and that does not take it for a throwaway one (a folder under its temporary folder is).
@(private = "file")
env_with :: proc(scratch: Desktop_Scratch, appdata: string, integration: string) -> []string {
	_ = os.make_directory_all(appdata)
	temp := fmt.tprintf("%s.temp", appdata)
	_ = os.make_directory_all(temp)
	all := make([dynamic]string, context.temp_allocator)
	append(&all, ..scratch.env)
	append(&all, fmt.tprintf("APPDATA=%s", appdata), fmt.tprintf("TEMP=%s", temp), fmt.tprintf("TMP=%s", temp), integration)
	return all[:]
}

// A barrier: the dialog holds, nothing is out.
@(private = "file")
setup_settled :: proc(s: ^api.Session) -> api.Setup_State {
	api.wait_until(s, proc(s: ^api.Session) -> bool {
		st, _ := api.setup_state(s)
		return st.busy == 0
	}, "Setup's jobs to end")
	st, _ := api.setup_state(s)
	return st
}

// The dialog is open, its facts read, its buttons placed.
@(private = "file")
setup_ready :: proc(s: ^api.Session) -> api.Setup_State {
	api.wait_until(s, proc(s: ^api.Session) -> bool {
		st, _ := api.setup_state(s)
		return st.open && st.known && st.busy == 0 && st.primary.w > 0
	}, "the Setup dialog")
	// (the frame after the facts: its buttons are placed there)
	api.wait_frames(s)
	return setup_still(s)
}

// The buttons are where they stay. What the dialog says takes frames to reach them: a box's rectangle is the last frame's layout (setup.Dialog.at), so
// that a click on what two frames later still said was in the old place: nothing there, and an uninstall that never began.
@(private = "file")
setup_still :: proc(s: ^api.Session) -> api.Setup_State {
	st, _ := api.setup_state(s)
	for same := 0; same < SETUP_STILL_FRAMES; same += 1 {
		api.wait_frames(s, 1)
		now, _ := api.setup_state(s)
		if now.uninstall != st.uninstall || now.primary != st.primary || now.secondary != st.secondary { same = -1 }
		st = now
	}
	return st
}
// More than the frames between a change and its place (three).
@(private = "file") SETUP_STILL_FRAMES :: 5

@(private = "file")
click_button :: proc(s: ^api.Session, r: api.Rect) { api.click_at(s, api.center(r), .Window) }

// Is the dialog shown by a start that has settled? (The jobs of the start are counted before its channel answers: nothing more can open it.)
@(private = "file")
opened_by_itself :: proc(t: ^testing.T, o: e2e.Process_Options) -> bool {
	p := e2e.launch(t, o)
	st := setup_settled(p.s)
	e2e.quit(p)
	return st.open
}

@(test)
install_uninstall_standalone :: proc(t: ^testing.T) {
	before := real_state()
	dir := e2e.temp_folder(t)
	scratch := desktop_scratch(t, dir)
	profile := fmt.tprintf("%s/profile", dir)
	installed := fmt.tprintf("%s/wren.exe", scratch.install)
	shortcut := fmt.tprintf("%s/Wren Dev.lnk", scratch.menu)
	client := fmt.tprintf(`%s\Clients\StartMenuInternet\WrenDev`, scratch.root)
	apps := fmt.tprintf(`%s\Microsoft\Windows\CurrentVersion\Uninstall\WrenDev`, scratch.root)
	manifest := fmt.tprintf("%s/wren_install.txt", scratch.install)
	options := e2e.Process_Options{profile = profile, extra = {"--setup"}, start = {env = scratch.env}}

	// A: the main button
	p := e2e.launch(t, options)
	st := setup_ready(p.s)
	click_button(p.s, st.primary)
	e2e.wait_file(t, manifest)
	e2e.wait_file(t, shortcut)
	e2e.wait_for(t, apps, proc(key: string) -> bool { return registry_key_exists(key) }, "the Settings > Apps record")
	st = setup_settled(p.s)
	testing.expectf(t, os.exists(installed), "wren.exe is in the install folder: %s", st.note)
	testing.expect(t, registry_key_exists(client), "registered as a browser (the throwaway key)")
	testing.expect(t, !os.exists(fmt.tprintf("%s/Wren Dev.lnk", scratch.desktop)), "no desktop shortcut (not ticked)")
	testing.expect_value(t, e2e.quit(p), 0)

	// B: the two clicks, from the installed copy
	options.exe = installed
	p = e2e.launch(t, options)
	st = setup_ready(p.s)
	click_button(p.s, st.uninstall)
	// (what it asks takes more lines: the button goes down)
	st = setup_still(p.s)
	testing.expect(t, st.confirm_uninstall && os.exists(installed), "the first click only asks")
	click_button(p.s, st.uninstall)
	e2e.wait_gone(t, shortcut)
	e2e.wait_for(t, client, proc(key: string) -> bool { return !registry_key_exists(key) }, "the browser registration to go")
	e2e.wait_for(t, apps, proc(key: string) -> bool { return !registry_key_exists(key) }, "the Settings > Apps record to go")
	setup_settled(p.s)
	// What stays is the running copy and what lists it, for the cleanup after it ends (waited for below): renamed out of the way when the
	// system lets it, else under its own name. A rename fails while another program holds the file without sharing its deletion (a
	// scanner that reads a new executable does), and the uninstall then keeps the name (desktop/install.odin files_remove): what the
	// check read once was that moment, not a defect.
	for f in e2e.files_with_prefix(scratch.install, "") {
		name := f[max(strings.last_index_byte(f, '/'), strings.last_index_byte(f, '\\')) + 1:]
		testing.expectf(t, name == "wren.exe" || name == "wren_install.txt" || strings.has_suffix(name, ".old") || strings.has_suffix(name, ".dll"), "only the running copy and what it holds stay, the rest is gone: %s", name)
	}
	testing.expect_value(t, e2e.quit(p), 0)
	e2e.wait_gone(t, scratch.install)
	// (the helper batch file deletes itself last)
	e2e.wait_gone(t, fmt.tprintf("%s/wren_cleanup_%d.cmd", base_temp(), p.wren.pid))

	// C: "Use standalone"
	options.exe = ""
	p = e2e.launch(t, options)
	st = setup_ready(p.s)
	click_button(p.s, st.secondary)
	choice := fmt.tprintf("%s/%s", profile, CHOICE_FILE)
	e2e.wait_file(t, choice, "choice=standalone")
	testing.expect_value(t, e2e.quit(p), 0)
	testing.expect_value(t, real_state(), before)
}

@(private = "file")
base_temp :: proc() -> string {
	dir, _ := os.lookup_env("TEMP", context.temp_allocator)
	return dir
}

@(test)
the_first_start_opens_setup_by_itself_once :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	scratch := desktop_scratch(t, dir)
	appdata := fmt.tprintf("%s/appdata", dir)
	env := env_with(scratch, appdata, INTEGRATION_ON)
	choice := fmt.tprintf("%s/%s/%s", appdata, PROFILE_IN_APPDATA, CHOICE_FILE)
	options := e2e.Process_Options{own_profile = true, prefs = {FIRST_RUN_PREF}, start = {env = env}}

	p := e2e.launch(t, options)
	setup_ready(p.s)
	api.key(p.s, "Escape")
	e2e.wait_file(t, choice, "choice=dismissed")
	st, _ := api.setup_state(p.s)
	testing.expect(t, !st.open, "Escape closes it, and is remembered as dismissed")
	testing.expect_value(t, e2e.quit(p), 0)

	// answered "standalone": not again
	e2e.write_text(choice, "choice=standalone\nversion=0.0.1\n")
	testing.expect(t, !opened_by_itself(t, options), "after standalone it does not open")
	testing.expect_value(t, e2e.read_text(choice), "choice=standalone\nversion=0.0.1\n")
}

@(test)
nothing_opens_setup_by_itself_in_a_driven_portable_or_named_profile :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	scratch := desktop_scratch(t, dir)
	appdata := fmt.tprintf("%s/appdata", dir)

	off := e2e.Process_Options{own_profile = true, prefs = {FIRST_RUN_PREF}, start = {env = env_with(scratch, appdata, "WREN_DESKTOP_INTEGRATION=off")}}
	testing.expect(t, !opened_by_itself(t, off), "WREN_DESKTOP_INTEGRATION=off")

	on := env_with(scratch, appdata, INTEGRATION_ON)
	named := e2e.Process_Options{profile = fmt.tprintf("%s/profile2", dir), prefs = {FIRST_RUN_PREF}, start = {env = on}}
	testing.expect(t, !opened_by_itself(t, named), "--profile")

	portable := fmt.tprintf("%s/portable", dir)
	_ = os.make_directory_all(portable)
	exe := fmt.tprintf("%s/wren.exe", portable)
	testing.expect_value(t, os.copy_file(exe, e2e.wren_exe()), nil)
	e2e.write_text(fmt.tprintf("%s/wren.portable", portable), "")
	appdata2 := fmt.tprintf("%s/appdata2", dir)
	copy := e2e.Process_Options{exe = exe, own_profile = true, prefs = {FIRST_RUN_PREF}, start = {env = env_with(scratch, appdata2, INTEGRATION_ON)}}
	testing.expect(t, !opened_by_itself(t, copy), "a portable copy")
	testing.expect(t, os.exists(fmt.tprintf("%s/data", portable)), "a portable copy keeps its profile in <folder>/data")
	testing.expect(t, !os.exists(fmt.tprintf("%s/%s", appdata2, PROFILE_IN_APPDATA)), "a portable copy writes nothing to APPDATA")
}

// The request's end, seen from the channel; and the file of the check.
@(private = "file")
update_settled :: proc(s: ^api.Session) {
	api.wait_until(s, proc(s: ^api.Session) -> bool {
		checking, _ := api.update_checking(s)
		return !checking
	}, "the update check to end")
}

@(test)
the_daily_update_check :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	appdata := fmt.tprintf("%s/appdata", dir)
	env := env_with(desktop_scratch(t, dir), appdata, INTEGRATION_ON)
	file := fmt.tprintf("%s/%s/%s", appdata, PROFILE_IN_APPDATA, UPDATE_FILE)

	p := e2e.launch(t, {own_profile = true, prefs = {UPDATE_ON_PREF, NEWER_RELEASE}, start = {env = env}})
	e2e.wait_file(t, file, "notified=")
	e2e.quit(p)
	text := e2e.read_text(file)
	testing.expectf(t, strings.contains(text, "latest=99.0.0") && strings.contains(text, "notified=99.0.0") && strings.contains(text, "url=https://github.com/sachahjkl/wren/releases/tag/v99.0.0"), "a newer version is recorded: %q", text)

	// asked once a day: the channel answers once the start has decided, and no request is out
	p = e2e.launch(t, {own_profile = true, prefs = {UPDATE_ON_PREF, NEWER_STILL}, start = {env = env}})
	checking, _ := api.update_checking(p.s)
	testing.expect(t, !checking, "a second start the same day does not ask again")
	e2e.quit(p)
	testing.expect(t, strings.contains(e2e.read_text(file), "latest=99.0.0"), "... and keeps what it knows")

	// off by default: no request, nothing written
	os.remove(file)
	p = e2e.launch(t, {own_profile = true, start = {env = env}})
	checking, _ = api.update_checking(p.s)
	testing.expect(t, !checking, "off by default: no request")
	e2e.quit(p)
	testing.expect(t, !os.exists(file), "... nothing written")
}
