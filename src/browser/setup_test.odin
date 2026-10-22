package browser

// Setup on scratch folders and a scratch registry root (Software\WrenTest\<id>): the states of the dialog, what Install,
// Replace, Repair and Uninstall do to the disk, and what the profile remembers. Nothing of the real desktop is touched.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import win "core:sys/windows"
import "wb:desktop"

@(private = "file")
Scene :: struct {
	root:    string,   // %TEMP%\wren_setup_test_<id>
	menu:    string,
	desk:    string,
	pkg:     string,   // an unpacked package: wren.exe, licenses\a.txt
	pkg2:    string,   // another one (a newer download)
	target:  string,   // the install folder (not made)
	reg:     string,   // Software\WrenTest\<id>
	opts:    desktop.Options,
}

@(private = "file")
scene_make :: proc() -> Scene {
	tmp, _ := os.temp_dir(context.allocator)
	defer delete(tmp)
	id := fmt.aprintf("setup_%d_%d", win.GetCurrentProcessId(), time.to_unix_nanoseconds(time.now()))
	defer delete(id)
	s: Scene
	s.root = fmt.aprintf("%s\\wren_%s", strings.trim_right(tmp, "\\/"), id)
	s.menu = fmt.aprintf("%s\\StartMenu", s.root)
	s.desk = fmt.aprintf("%s\\Desktop", s.root)
	s.pkg = fmt.aprintf("%s\\pkg1", s.root)
	s.pkg2 = fmt.aprintf("%s\\pkg2", s.root)
	s.target = fmt.aprintf("%s\\Programs\\Wren", s.root)
	s.reg = fmt.aprintf("Software\\WrenTest\\%s", id)
	for p in ([]string{s.pkg, s.pkg2}) {
		_ = os.make_directory_all(fmt.tprintf("%s\\licenses", p))
		_ = os.write_entire_file(fmt.tprintf("%s\\wren.exe", p), "MZ fake program")
		_ = os.write_entire_file(fmt.tprintf("%s\\licenses\\a.txt", p), "licence")
		_ = os.write_entire_file(fmt.tprintf("%s\\README.txt", p), "readme")
	}
	s.opts = desktop.Options{
		identity = Identity_for_test(),
		register_browser = true, start_menu = true, file_types = TEST_FILE_TYPES[:],
		menu_dir = s.menu, desktop_dir = s.desk, environment_root = fmt.aprintf("%s\\Environment", s.reg), registry_root = s.reg,
		install_dir = s.target, notify_system = false,
	}
	return s
}

@(private = "file") TEST_FILE_TYPES := [?]string{".html"}

@(private = "file")
Identity_for_test :: proc() -> desktop.Identity {
	id := desktop_identity()
	id.aumid = "FromentSoftware.Wren.SetupTest"   // never the real one
	return id
}

@(private = "file")
scene_destroy :: proc(s: ^Scene) {
	desktop.delete_scratch_root(s.reg)
	_ = os.remove_all(s.root)
	delete(s.root); delete(s.menu); delete(s.desk); delete(s.pkg); delete(s.pkg2); delete(s.target); delete(s.reg)
	delete(s.opts.environment_root)
}

@(private = "file")
job_for :: proc(s: ^Scene, kind: Setup_Job_Kind, running: string) -> Setup_Job {
	return Setup_Job{kind = kind, opts = s.opts, running_exe = running, target_dir = s.target}
}

@(private = "file")
exe_in :: proc(dir: string) -> string { return fmt.tprintf("%s\\wren.exe", dir) }

@(test)
setup_states_of_the_dialog :: proc(t: ^testing.T) {
	present := desktop.Install_Info{exe = `C:\i\wren.exe`, exe_present = true, manifest = true, version = "0.3.0"}
	testing.expect_value(t, setup_classify(`C:\d\wren.exe`, "0.3.0", {}, false), Setup_Kind.Not_Installed)
	testing.expect_value(t, setup_classify(`C:\i\wren.exe`, "0.3.0", present, true), Setup_Kind.Running_Installed)
	testing.expect_value(t, setup_classify(`c:/I/WREN.exe`, "0.3.0", present, true), Setup_Kind.Running_Installed)   // (the same file)
	testing.expect_value(t, setup_classify(`C:\i\wren.exe`, "0.3.0", present, false), Setup_Kind.Repair)             // a shortcut is missing
	missing := present
	missing.missing = 2
	testing.expect_value(t, setup_classify(`C:\i\wren.exe`, "0.3.0", missing, true), Setup_Kind.Repair)             // a file is missing
	nomanifest := present
	nomanifest.manifest = false
	testing.expect_value(t, setup_classify(`C:\i\wren.exe`, "0.3.0", nomanifest, true), Setup_Kind.Repair)
	testing.expect_value(t, setup_classify(`C:\d\wren.exe`, "0.3.0", present, true), Setup_Kind.Other_Copy)         // same version, elsewhere
	testing.expect_value(t, setup_classify(`C:\d\wren.exe`, "0.4.0", present, true), Setup_Kind.Other_Copy)         // newer
	testing.expect_value(t, setup_classify(`C:\d\wren.exe`, "0.2.9", present, true), Setup_Kind.Older)
	unknown := present
	unknown.version = ""
	testing.expect_value(t, setup_classify(`C:\d\wren.exe`, "0.1.0", unknown, true), Setup_Kind.Other_Copy)       // (cannot say older)
}

@(test)
setup_offers_itself_for_every_state_but_a_good_installation :: proc(t: ^testing.T) {
	for k in Setup_Kind {
		f := Setup_Facts{kind = k}
		want := k != .Loading && k != .Running_Installed
		testing.expectf(t, setup_should_offer(&f) == want, "%v", k)
	}
}

@(test)
setup_install_then_every_state_then_uninstall :: proc(t: ^testing.T) {
	s := scene_make()
	defer scene_destroy(&s)
	exe := exe_in(s.pkg)
	installed_exe := exe_in(s.target)

	// nothing installed
	f := setup_read_facts(&s.opts, exe)
	testing.expect_value(t, f.kind, Setup_Kind.Not_Installed)
	setup_facts_destroy(&f)

	// Install: copies the executable and the payload, writes the manifest, the shortcut, the keys, the record
	job := job_for(&s, .Apply, exe)
	setup_apply_work(&job)
	testing.expectf(t, job.result.error == .None, "install: %v %s", job.result.error, job.result.detail)
	testing.expect(t, os.is_file(installed_exe) && os.is_file(fmt.tprintf("%s\\licenses\\a.txt", s.target)) && os.is_file(fmt.tprintf("%s\\README.txt", s.target)), "the files")
	testing.expect(t, os.is_file(fmt.tprintf("%s\\wren_install.txt", s.target)), "the manifest")
	testing.expect(t, os.is_file(fmt.tprintf("%s\\%s.lnk", s.menu, s.opts.identity.name)), "the Start menu shortcut")

	// run from the downloaded copy: another copy; run from the installed one: installed
	f = setup_read_facts(&s.opts, exe)
	testing.expect_value(t, f.kind, Setup_Kind.Other_Copy)
	testing.expect_value(t, f.inst.version, APP_VERSION)
	setup_facts_destroy(&f)
	f = setup_read_facts(&s.opts, installed_exe)
	testing.expect_value(t, f.kind, Setup_Kind.Running_Installed)
	testing.expect(t, f.integ_complete, "the integration is complete")
	setup_facts_destroy(&f)

	// an installed copy newer than this one: this one is older
	manifest := fmt.tprintf("%s\\wren_install.txt", s.target)
	data, _ := os.read_entire_file(manifest, context.temp_allocator)
	newer, _ := strings.replace_all(string(data), fmt.tprintf("version=%s", APP_VERSION), "version=99.0.0", context.temp_allocator)
	_ = os.write_entire_file(manifest, newer)
	f = setup_read_facts(&s.opts, exe)
	testing.expect_value(t, f.kind, Setup_Kind.Older)
	setup_facts_destroy(&f)
	_ = os.write_entire_file(manifest, string(data))

	// Repair: the shortcut is gone while the installed copy runs
	_ = os.remove(fmt.tprintf("%s\\%s.lnk", s.menu, s.opts.identity.name))
	f = setup_read_facts(&s.opts, installed_exe)
	testing.expect_value(t, f.kind, Setup_Kind.Repair)
	setup_facts_destroy(&f)
	job = job_for(&s, .Apply, installed_exe)
	setup_apply_work(&job)   // (Modify / Repair from the installed copy: nothing to copy)
	testing.expectf(t, job.result.error == .None, "repair: %v %s", job.result.error, job.result.detail)
	f = setup_read_facts(&s.opts, installed_exe)
	testing.expect_value(t, f.kind, Setup_Kind.Running_Installed)
	setup_facts_destroy(&f)

	// Replace: a newer download replaces the installed copy
	_ = os.write_entire_file(exe_in(s.pkg2), "MZ fake program, newer")
	job = job_for(&s, .Apply, exe_in(s.pkg2))
	setup_apply_work(&job)
	testing.expectf(t, job.result.error == .None, "replace: %v %s", job.result.error, job.result.detail)
	got, _ := os.read_entire_file(installed_exe, context.temp_allocator)
	testing.expect_value(t, string(got), "MZ fake program, newer")

	// Uninstall: everything goes, the keys with it
	job = job_for(&s, .Uninstall, exe_in(s.pkg))
	setup_uninstall_work(&job)
	testing.expectf(t, job.result.error == .None, "uninstall: %v %s", job.result.error, job.result.detail)
	testing.expect_value(t, len(job.leftovers), 0)
	delete(job.leftovers)
	testing.expect(t, !os.exists(s.target), "the install folder is gone")
	testing.expect(t, !os.exists(fmt.tprintf("%s\\%s.lnk", s.menu, s.opts.identity.name)), "the shortcut is gone")
	f = setup_read_facts(&s.opts, exe)
	testing.expect_value(t, f.kind, Setup_Kind.Not_Installed)
	testing.expect_value(t, f.integ.state, desktop.State.Absent)
	testing.expect(t, !desktop.supported() || desktop.install_target(&s.opts) == s.target, "(install_dir is the scratch folder)")
	setup_facts_destroy(&f)
}

@(test)
setup_options_apply_and_modify :: proc(t: ^testing.T) {
	s := scene_make()
	defer scene_destroy(&s)
	exe := exe_in(s.pkg)
	s.opts.desktop_shortcut = true
	s.opts.add_to_path = true
	job := job_for(&s, .Apply, exe)
	setup_apply_work(&job)
	testing.expectf(t, job.result.error == .None, "install: %v %s", job.result.error, job.result.detail)
	testing.expect(t, os.is_file(fmt.tprintf("%s\\%s.lnk", s.desk, s.opts.identity.name)), "the desktop shortcut")
	f := setup_read_facts(&s.opts, exe_in(s.target))
	testing.expect(t, f.integ.parts[.Path].present && f.integ.parts[.Desktop_Shortcut].present, "read back: PATH and desktop shortcut")
	testing.expect_value(t, f.kind, Setup_Kind.Running_Installed)
	setup_facts_destroy(&f)

	// Modify: the options that are unticked go
	s.opts.desktop_shortcut = false
	s.opts.add_to_path = false
	s.opts.register_browser = false
	job = job_for(&s, .Apply, exe_in(s.target))
	setup_apply_work(&job)
	testing.expectf(t, job.result.error == .None, "modify: %v %s", job.result.error, job.result.detail)
	testing.expect(t, !os.exists(fmt.tprintf("%s\\%s.lnk", s.desk, s.opts.identity.name)), "the desktop shortcut went")
	f = setup_read_facts(&s.opts, exe_in(s.target))
	testing.expect(t, !f.integ.parts[.Path].present && !f.integ.parts[.Registration].present, "PATH and registration went")
	testing.expect(t, f.integ.parts[.Launcher].present, "the Start menu entry stayed")
	testing.expect_value(t, f.kind, Setup_Kind.Running_Installed)
	setup_facts_destroy(&f)

	job = job_for(&s, .Uninstall, exe_in(s.target))
	setup_uninstall_work(&job)
	testing.expect_value(t, job.result.error, desktop.Error.None)
}

@(test)
setup_install_moves_the_installation :: proc(t: ^testing.T) {
	s := scene_make()
	defer scene_destroy(&s)
	s.opts.add_to_path = true
	job := job_for(&s, .Apply, exe_in(s.pkg))
	setup_apply_work(&job)
	testing.expect_value(t, job.result.error, desktop.Error.None)

	// "Move installation": the new folder is installed, the old one removed (its PATH entry too)
	moved := fmt.tprintf("%s\\Elsewhere\\Wren", s.root)
	s.opts.install_dir = moved
	job = job_for(&s, .Apply, exe_in(s.target))
	job.target_dir = moved
	job.old_dir = s.target
	setup_apply_work(&job)
	testing.expectf(t, job.result.error == .None, "move: %v %s", job.result.error, job.result.detail)
	testing.expect(t, os.is_file(exe_in(moved)), "the new copy")
	testing.expect(t, !os.exists(exe_in(s.target)) && !os.exists(s.target), "the old copy is gone")
	f := setup_read_facts(&s.opts, exe_in(moved))
	testing.expect(t, f.integ.parts[.Path].present, "the new folder is on the PATH")
	testing.expect_value(t, f.kind, Setup_Kind.Running_Installed)
	setup_facts_destroy(&f)
	job = job_for(&s, .Uninstall, exe_in(moved))
	job.target_dir = moved
	setup_uninstall_work(&job)
	testing.expect_value(t, job.result.error, desktop.Error.None)
}

@(test)
setup_refuses_a_bad_folder_before_touching_anything :: proc(t: ^testing.T) {
	s := scene_make()
	defer scene_destroy(&s)
	job := job_for(&s, .Apply, exe_in(s.pkg))
	job.target_dir = `C:\Windows\Wren`
	setup_apply_work(&job)
	testing.expect_value(t, job.result.error, desktop.Error.Bad_Options)
	testing.expect(t, !os.exists(fmt.tprintf("%s\\%s.lnk", s.menu, s.opts.identity.name)), "no shortcut was made")
	f := setup_read_facts(&s.opts, exe_in(s.pkg))
	testing.expect_value(t, f.kind, Setup_Kind.Not_Installed)
	setup_facts_destroy(&f)
}

@(test)
setup_uninstalling_the_running_copy_leaves_its_file_for_later :: proc(t: ^testing.T) {
	s := scene_make()
	defer scene_destroy(&s)
	job := job_for(&s, .Apply, exe_in(s.pkg))
	setup_apply_work(&job)
	installed := exe_in(s.target)
	// stands for the running program: its file cannot be deleted
	h := win.CreateFileW(win.utf8_to_wstring(installed, context.temp_allocator), win.GENERIC_READ, win.FILE_SHARE_READ, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	testing.expect(t, h != win.INVALID_HANDLE_VALUE, "opened")
	job = job_for(&s, .Uninstall, installed)
	setup_uninstall_work(&job)
	testing.expect_value(t, job.result.error, desktop.Error.None)
	testing.expect_value(t, len(job.leftovers), 1)
	testing.expect_value(t, job.folder_left, s.target)
	f := setup_read_facts(&s.opts, installed)
	testing.expect(t, f.integ.state == .Absent, "the integration is gone")
	setup_facts_destroy(&f)
	win.CloseHandle(h)
	// the helper's job, done by hand: the files go, then the folder
	for l in job.leftovers { _ = os.remove(l) }
	delete(job.leftovers)
	_ = os.remove(fmt.tprintf("%s\\wren_install.txt", s.target))
	testing.expect(t, os.remove(s.target) == nil, "the folder goes once empty")
}

@(test)
setup_remembers_the_answer_in_the_profile :: proc(t: ^testing.T) {
	s := scene_make()
	defer scene_destroy(&s)
	_ = os.make_directory_all(s.root)
	app: App
	app.cfg.persist_profile = true
	app.profile_dir = s.root
	choice, version := setup_choice(&app)
	testing.expect_value(t, choice, "")
	testing.expect(t, !setup_choice_blocks(&app), "nothing answered: ask")

	setup_choice_write(&app, "dismissed")
	choice, version = setup_choice(&app)
	testing.expect_value(t, choice, "dismissed")
	testing.expect_value(t, version, APP_VERSION)
	testing.expect(t, setup_choice_blocks(&app), "closed without answering: not asked again for this version")
	// ... but asked again after an update
	_ = os.write_entire_file(fmt.tprintf("%s\\%s", s.root, SETUP_CHOICE_FILE), "choice=dismissed\nversion=0.0.1\n")
	testing.expect(t, !setup_choice_blocks(&app), "a dismissal of an older version does not count")

	setup_choice_write(&app, "standalone")
	_ = os.write_entire_file(fmt.tprintf("%s\\%s", s.root, SETUP_CHOICE_FILE), "choice=standalone\nversion=0.0.1\n")
	testing.expect(t, setup_choice_blocks(&app), "standalone is for good")

	app.cfg.persist_profile = false
	_ = os.remove(fmt.tprintf("%s\\%s", s.root, SETUP_CHOICE_FILE))
	setup_choice_write(&app, "standalone")
	testing.expect(t, !os.exists(fmt.tprintf("%s\\%s", s.root, SETUP_CHOICE_FILE)), "a profile that is not kept keeps nothing")
}

@(test)
setup_portable_marker :: proc(t: ^testing.T) {
	// the test executable has no wren.portable beside it
	testing.expect_value(t, portable_profile_dir(), "")
}

@(test)
setup_update_document_is_read_carefully :: proc(t: ^testing.T) {
	tag, page, ok := update_parse(transmute([]byte)string(`{"tag_name":"v0.4.0","html_url":"https://github.com/sachahjkl/wren/releases/tag/v0.4.0","draft":false}`))
	testing.expect(t, ok && tag == "v0.4.0" && strings.has_prefix(page, "https://github.com/"), "a release")
	_, _, ok = update_parse(transmute([]byte)string(`{"tag_name":"v0.5.0","prerelease":true}`))
	testing.expect(t, !ok, "a prerelease is not offered")
	_, _, ok = update_parse(transmute([]byte)string(`{"tag_name":"v0.5.0","draft":true}`))
	testing.expect(t, !ok, "a draft is not offered")
	_, _, ok = update_parse(transmute([]byte)string(`{"message":"Not Found"}`))
	testing.expect(t, !ok, "an error document")
	_, _, ok = update_parse(transmute([]byte)string(`<html>`))
	testing.expect(t, !ok, "not JSON")
	_, page, ok = update_parse(transmute([]byte)string(`{"tag_name":"v1","html_url":"javascript:alert(1)"}`))
	testing.expect(t, ok && page == "", "only an https page is kept")
	_, page, ok = update_parse(transmute([]byte)string(`{"tag_name":"v1"}`))
	testing.expect(t, ok && page == "", "no page")
}
