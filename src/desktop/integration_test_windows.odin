package desktop

// The Windows backend on a scratch Start menu folder and a scratch registry key (HKCU\Software\WrenTest\<id>): never on
// the real desktop. One test touches the real one, and only when WREN_TEST_DESKTOP_REAL=1 is in the environment.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import win "core:sys/windows"

@(private = "file")
Scratch :: struct {
	dir:  string,   // a folder in %TEMP%
	menu: string,   // its "Start menu"
	exe:  string,   // a file standing for the program
	exe2: string,   // the program after an update into another folder
	root: string,   // Software\WrenTest\<id>
	desk: string,   // its "Desktop"
	env:  string,   // Software\WrenTest\<id>\Environment: what stands for HKCU\Environment
	opts: Options,
}

@(private = "file")
scratch_make :: proc() -> Scratch {
	tmp, _ := os.temp_dir(context.allocator)
	id := fmt.aprintf("%d_%d", win.GetCurrentProcessId(), time.to_unix_nanoseconds(time.now()), allocator = context.allocator)
	s: Scratch
	s.dir = fmt.aprintf("%s\\wren_desktop_test_%s", tmp, id)
	s.menu = fmt.aprintf("%s\\Start Menu\\Programs", s.dir)
	s.exe = fmt.aprintf("%s\\v1\\wren.exe", s.dir)
	s.exe2 = fmt.aprintf("%s\\v2\\wren.exe", s.dir)
	s.root = fmt.aprintf("Software\\WrenTest\\%s", id)
	s.desk = fmt.aprintf("%s\\Desktop", s.dir)
	s.env = fmt.aprintf("%s\\Environment", s.root)
	for p in ([]string{s.exe, s.exe2}) {
		dir := p[:strings.last_index_byte(p, '\\')]
		_ = os.make_directory_all(dir)
		_ = os.write_entire_file(p, "MZ not a program")
	}
	s.opts = Options{
		identity = Identity{name = "Wren", key = "Wren", slug = "wren", aumid = "FromentSoftware.Wren.Test", description = "A test.", vendor = "Froment Software"},
		exe = s.exe, register_browser = true, start_menu = true, file_types = split_list(".htm,.html,.svg,.webp", context.temp_allocator),
		menu_dir = s.menu, desktop_dir = s.desk, environment_root = s.env, registry_root = s.root, notify_system = false,
	}
	delete(tmp)
	delete(id)
	return s
}

@(private = "file")
scratch_destroy :: proc(s: ^Scratch) {
	RegDeleteTreeW(win.HKEY_CURRENT_USER, wide(s.root))
	RegDeleteKeyW(win.HKEY_CURRENT_USER, wide("Software\\WrenTest"))   // (fails while another test's key is in it: then it stays)
	_ = os.remove_all(s.dir)
	delete(s.dir); delete(s.menu); delete(s.exe); delete(s.exe2); delete(s.root); delete(s.desk); delete(s.env)
}

@(private = "file")
state_of :: proc(o: ^Options) -> (State, Status) {
	st := status(o, context.temp_allocator)
	return st.state, st
}

@(test)
windows_round_trip :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	lnk := fmt.tprintf("%s\\Wren.lnk", s.menu)
	client := fmt.tprintf("%s\\Clients\\StartMenuInternet\\Wren", s.root)
	progid := fmt.tprintf("%s\\Classes\\WrenHTML", s.root)

	state, st := state_of(o)
	testing.expect_value(t, state, State.Absent)
	testing.expect_value(t, st.error, Error.None)

	r := install(o)
	testing.expect_value(t, r.error, Error.None)
	if r.error != .None { testing.expect(t, false, r.detail); return }
	state, st = state_of(o)
	testing.expect_value(t, state, State.Installed)
	testing.expect(t, os.is_file(lnk), "the shortcut exists")

	// the shortcut: the executable, its AppUserModelID
	com := com_enter()
	target, aumid, read := read_shortcut(lnk)
	com_leave(com)
	testing.expect(t, read, "the shortcut reads back")
	testing.expect(t, same_path(target, s.exe), fmt.tprintf("shortcut target %q", target))
	testing.expect_value(t, aumid, "FromentSoftware.Wren.Test")

	// the registration, value by value
	get :: proc(t: ^testing.T, path, name, want: string) {
		v, ok := reg_get(path, name)
		testing.expectf(t, ok && v == want, "%s [%s] = %q (found %v), want %q", path, name, v, ok, want)
	}
	get(t, client, "", "Wren")
	get(t, fmt.tprintf("%s\\shell\\open\\command", client), "", fmt.tprintf("\"%s\"", s.exe))
	get(t, fmt.tprintf("%s\\DefaultIcon", client), "", fmt.tprintf("%s,0", s.exe))
	caps := fmt.tprintf("%s\\Capabilities", client)
	get(t, caps, "ApplicationName", "Wren")
	get(t, caps, "ApplicationIcon", fmt.tprintf("%s,0", s.exe))
	get(t, fmt.tprintf("%s\\URLAssociations", caps), "http", "WrenHTML")
	get(t, fmt.tprintf("%s\\URLAssociations", caps), "https", "WrenHTML")
	get(t, fmt.tprintf("%s\\FileAssociations", caps), ".html", "WrenHTML")
	get(t, fmt.tprintf("%s\\FileAssociations", caps), ".webp", "WrenHTML")
	get(t, fmt.tprintf("%s\\RegisteredApplications", s.root), "Wren", caps)
	get(t, fmt.tprintf("%s\\shell\\open\\command", progid), "", fmt.tprintf("\"%s\" \"%%1\"", s.exe))
	get(t, fmt.tprintf("%s\\Application", progid), "AppUserModelId", "FromentSoftware.Wren.Test")

	// again: nothing changes
	testing.expect_value(t, install(o).error, Error.None)
	state, st = state_of(o)
	testing.expect_value(t, state, State.Installed)

	// removal: all of it, and the status says so
	testing.expect_value(t, remove(o).error, Error.None)
	state, st = state_of(o)
	testing.expect_value(t, state, State.Absent)
	testing.expect(t, !os.exists(lnk), "the shortcut is gone")
	testing.expect(t, !reg_key_exists(client), "the browser entry is gone")
	testing.expect(t, !reg_key_exists(progid), "the ProgID is gone")
	_, still := reg_get(fmt.tprintf("%s\\RegisteredApplications", s.root), "Wren")
	testing.expect(t, !still, "the list entry is gone")
	// removing again is not an error
	testing.expect_value(t, remove(o).error, Error.None)
}

@(test)
windows_repair_states :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	testing.expect_value(t, install(o).error, Error.None)

	// the program moved: same integration, another executable
	moved := o^
	moved.exe = s.exe2
	state, st := state_of(&moved)
	testing.expect_value(t, state, State.Repair)
	testing.expect(t, same_path(st.stale_exe, s.exe), fmt.tprintf("points to the old executable, got %q", st.stale_exe))
	testing.expect(t, st.parts[.Launcher].stale && st.parts[.Registration].stale, "both parts are stale")
	testing.expect(t, !st.incomplete, "nothing is missing")
	testing.expect_value(t, install(&moved).error, Error.None)
	state, _ = state_of(&moved)
	testing.expect_value(t, state, State.Installed)

	// a piece of the registration is gone
	progid := fmt.tprintf("%s\\Classes\\WrenHTML", s.root)
	testing.expect(t, reg_delete_tree(progid), "delete the ProgID")
	state, st = state_of(&moved)
	testing.expect_value(t, state, State.Repair)
	testing.expect(t, st.incomplete, "incomplete")
	testing.expect(t, st.parts[.Registration].partial, "the registration is partial")
	testing.expect_value(t, install(&moved).error, Error.None)
	state, _ = state_of(&moved)
	testing.expect_value(t, state, State.Installed)

	// only the shortcut left (the keys were removed by hand): to repair
	client := fmt.tprintf("%s\\Clients\\StartMenuInternet\\Wren", s.root)
	reg_delete_tree(client)
	reg_delete_tree(progid)
	reg_delete_value(fmt.tprintf("%s\\RegisteredApplications", s.root), "Wren")
	state, st = state_of(&moved)
	testing.expect_value(t, state, State.Repair)
	testing.expect(t, !st.parts[.Registration].present, "no registration")

	// ... which is fine when the options do not ask for one
	no_reg := moved
	no_reg.register_browser = false
	state, _ = state_of(&no_reg)
	testing.expect_value(t, state, State.Installed)
	testing.expect_value(t, remove(&moved).error, Error.None)
	state, _ = state_of(&moved)
	testing.expect_value(t, state, State.Absent)
}

@(test)
windows_without_browser_registration :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	o.register_browser = false
	testing.expect_value(t, install(o).error, Error.None)
	state, st := state_of(o)
	testing.expect_value(t, state, State.Installed)
	testing.expect(t, st.parts[.Launcher].present && !st.parts[.Registration].present, "only the shortcut")
	testing.expect(t, !reg_key_exists(fmt.tprintf("%s\\Clients\\StartMenuInternet\\Wren", s.root)), "no browser entry")

	// registering later completes it; turning it off again removes the keys
	o.register_browser = true
	state, _ = state_of(o)
	testing.expect_value(t, state, State.Repair)
	testing.expect_value(t, install(o).error, Error.None)
	state, _ = state_of(o)
	testing.expect_value(t, state, State.Installed)
	o.register_browser = false
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, !reg_key_exists(fmt.tprintf("%s\\Clients\\StartMenuInternet\\Wren", s.root)), "the keys went with the option")
}

@(test)
windows_removal_leaves_what_is_not_the_programs :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts

	// a shortcut of the same name made by someone else, keys of other programs, a user's default for .html
	_ = os.make_directory_all(s.menu)
	lnk := fmt.tprintf("%s\\Wren.lnk", s.menu)
	_ = os.write_entire_file(lnk, "not a shortcut at all")
	other := fmt.tprintf("%s\\Classes\\OtherHTML", s.root)
	testing.expect(t, reg_set(fmt.tprintf("%s\\shell\\open\\command", other), "", "\"C:\\other\\other.exe\" \"%1\""), "other ProgID")
	testing.expect(t, reg_set(fmt.tprintf("%s\\Classes\\.html", s.root), "", "OtherHTML"), "extension key")
	testing.expect(t, reg_set(fmt.tprintf("%s\\RegisteredApplications", s.root), "Other", "Software\\Other\\Capabilities"), "other registered app")
	testing.expect(t, reg_set(fmt.tprintf("%s\\Clients\\StartMenuInternet\\Other\\shell\\open\\command", s.root), "", "\"C:\\other\\other.exe\""), "other browser")

	state, _ := state_of(o)
	testing.expect_value(t, state, State.Absent)   // the unreadable file is not the program's
	testing.expect_value(t, remove(o).error, Error.None)
	testing.expect(t, os.is_file(lnk), "a file that is not the program's shortcut stays")

	// installed, then removed: the neighbours are untouched
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect_value(t, remove(o).error, Error.None)
	v, ok := reg_get(fmt.tprintf("%s\\Classes\\.html", s.root), "")
	testing.expect(t, ok && v == "OtherHTML", "the extension key is untouched")
	testing.expect(t, reg_key_exists(other), "another program's ProgID stays")
	_, ok = reg_get(fmt.tprintf("%s\\RegisteredApplications", s.root), "Other")
	testing.expect(t, ok, "another program's list entry stays")
	testing.expect(t, reg_key_exists(fmt.tprintf("%s\\Clients\\StartMenuInternet\\Other", s.root)), "another browser's entry stays")
}

// The windows of the process carry the AppUserModelID the shortcut has: what makes pinning and grouping work.
@(test)
windows_process_identity_is_the_shortcuts :: proc(t: ^testing.T) {
	id := Identity{name = "Wren", key = "Wren", slug = "wren", aumid = "FromentSoftware.Wren.ProcessTest"}
	set_process_identity(id)
	got: cstring16
	testing.expect(t, GetCurrentProcessExplicitAppUserModelID(&got) >= 0 && got != nil, "the process has an explicit AppUserModelID")
	if got == nil { return }
	defer win.CoTaskMemFree(rawptr(got))
	s, _ := win.wstring_to_utf8(got, -1, context.temp_allocator)
	testing.expect_value(t, s, id.aumid)
}

@(test)
windows_command_program :: proc(t: ^testing.T) {
	testing.expect_value(t, command_program(`"C:\a b\wren.exe" "%1"`), `C:\a b\wren.exe`)
	testing.expect_value(t, command_program(`C:\x\wren.exe %1`), `C:\x\wren.exe`)
	testing.expect_value(t, command_program(``), ``)
}

// The real desktop: only with WREN_TEST_DESKTOP_REAL=1, with an identity of its own that no installed Wren shares.
@(test)
windows_real_desktop :: proc(t: ^testing.T) {
	if v, ok := os.lookup_env("WREN_TEST_DESKTOP_REAL", context.temp_allocator); !ok || v != "1" { return }
	exe := executable_path()
	o := Options{
		identity = Identity{name = "Wren Desktop Test", key = "WrenDesktopTest", slug = "wren-desktop-test", aumid = "FromentSoftware.Wren.DesktopTest", description = "Removed by its own test."},
		exe = exe, register_browser = true, start_menu = true, file_types = {".html"}, notify_system = true,
	}
	defer remove(&o)
	testing.expect_value(t, install(&o).error, Error.None)
	state, _ := state_of(&o)
	testing.expect_value(t, state, State.Installed)
	testing.expect_value(t, remove(&o).error, Error.None)
	state, _ = state_of(&o)
	testing.expect_value(t, state, State.Absent)
}

////////////////////////////////
// The parts Setup adds: the desktop shortcut, the PATH, the Apps-list record, the file a running program holds

@(test)
windows_desktop_shortcut_is_an_option :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	desk_lnk := fmt.tprintf("%s\\Wren.lnk", s.desk)
	start_lnk := fmt.tprintf("%s\\Wren.lnk", s.menu)

	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, os.is_file(start_lnk) && !os.exists(desk_lnk), "only the Start menu entry by default")

	o.desktop_shortcut = true
	state, st := state_of(o)
	testing.expect_value(t, state, State.Repair)   // wanted and missing
	testing.expect(t, !st.parts[.Desktop_Shortcut].present, "not there yet")
	testing.expect_value(t, install(o).error, Error.None)
	state, st = state_of(o)
	testing.expect_value(t, state, State.Installed)
	testing.expect(t, st.parts[.Desktop_Shortcut].present && !st.parts[.Desktop_Shortcut].stale, "present and running this exe")
	com := com_enter()
	target, aumid, read := read_shortcut(desk_lnk)
	com_leave(com)
	testing.expect(t, read && same_path(target, s.exe) && aumid == "FromentSoftware.Wren.Test", "the desktop shortcut runs the exe with the AppUserModelID")

	// the program moved: the desktop shortcut is stale too
	moved := o^
	moved.exe = s.exe2
	state, st = state_of(&moved)
	testing.expect_value(t, state, State.Repair)
	testing.expect(t, st.parts[.Desktop_Shortcut].stale, "the desktop shortcut points to the old executable")
	testing.expect_value(t, install(&moved).error, Error.None)
	state, _ = state_of(&moved)
	testing.expect_value(t, state, State.Installed)

	// turning it off removes it (and only it)
	moved.desktop_shortcut = false
	testing.expect_value(t, install(&moved).error, Error.None)
	testing.expect(t, !os.exists(desk_lnk) && os.is_file(start_lnk), "the desktop shortcut went with the option, the menu entry stays")

	// the Start menu is an option too
	moved.start_menu = false
	testing.expect_value(t, install(&moved).error, Error.None)
	testing.expect(t, !os.exists(start_lnk), "the Start menu entry went with its option")
	testing.expect_value(t, remove(&moved).error, Error.None)
}

@(test)
windows_other_programs_shortcut_on_the_desktop_stays :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	_ = os.make_directory_all(s.desk)
	desk_lnk := fmt.tprintf("%s\\Wren.lnk", s.desk)
	_ = os.write_entire_file(desk_lnk, "somebody else's file")
	o.desktop_shortcut = false
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect_value(t, remove(o).error, Error.None)
	testing.expect(t, os.is_file(desk_lnk), "a file that is not the program's shortcut stays")
}

@(private = "file")
path_value :: proc(s: ^Scratch) -> (string, bool) {
	v, _, ok := reg_get_any(s.env, "Path")
	return v, ok
}

@(test)
windows_path_is_added_once_and_taken_out_with_its_mark :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	dir := fmt.tprintf("%s\\v1", s.dir)
	testing.expect(t, reg_set_kind(s.env, "Path", `C:\Tools;%USERPROFILE%\bin`, true), "the user's PATH")

	o.add_to_path = true
	testing.expect_value(t, install(o).error, Error.None)
	v, ok := path_value(&s)
	testing.expect(t, ok && v == fmt.tprintf("C:\\Tools;%%USERPROFILE%%\\bin;%s", dir), fmt.tprintf("appended, %%VARS%% untouched: %q", v))
	_, expand, _ := reg_get_any(s.env, "Path")
	testing.expect(t, expand, "REG_EXPAND_SZ")
	state, st := state_of(o)
	testing.expect_value(t, state, State.Installed)
	testing.expect(t, st.parts[.Path].present, "the PATH part is present")

	// again, and with a trailing separator or another spelling: no second entry
	testing.expect_value(t, install(o).error, Error.None)
	v, _ = path_value(&s)
	testing.expect_value(t, strings.count(v, dir), 1)
	testing.expect(t, reg_set_kind(s.env, "Path", fmt.tprintf("%s\\;C:\\Tools", strings.to_upper(dir, context.temp_allocator)), true), "another spelling")
	testing.expect_value(t, install(o).error, Error.None)
	v, _ = path_value(&s)
	testing.expect_value(t, strings.count(strings.to_lower(v, context.temp_allocator), strings.to_lower(dir, context.temp_allocator)), 1)

	// the option off: the folder goes (it was ours), the rest stays
	testing.expect(t, reg_set_kind(s.env, "Path", fmt.tprintf("C:\\Tools;%s", dir), true), "reset")
	testing.expect(t, reg_set(fmt.tprintf("%s\\FromentSoftware\\Wren", s.root), "PathDir", dir), "the mark")
	o.add_to_path = false
	testing.expect_value(t, install(o).error, Error.None)
	v, _ = path_value(&s)
	testing.expect_value(t, v, `C:\Tools`)
	_, marked := reg_get(fmt.tprintf("%s\\FromentSoftware\\Wren", s.root), "PathDir")
	testing.expect(t, !marked, "the mark went too")
}

@(test)
windows_path_entry_the_user_added_is_not_taken_out :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	dir := fmt.tprintf("%s\\v1", s.dir)
	testing.expect(t, reg_set_kind(s.env, "Path", fmt.tprintf("C:\\Tools;%s", dir), false), "the user put it there, as REG_SZ")
	o.add_to_path = true
	testing.expect_value(t, install(o).error, Error.None)
	v, _ := path_value(&s)
	testing.expect_value(t, strings.count(v, dir), 1)   // already there: nothing added, and no mark
	o.add_to_path = false
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect_value(t, remove(o).error, Error.None)
	v, _ = path_value(&s)
	testing.expect_value(t, strings.count(v, dir), 1)   // not ours: still there
	// but a folder that is about to be deleted comes out whatever put it there
	testing.expect_value(t, forget_path(o, dir).error, Error.None)
	v, _ = path_value(&s)
	testing.expect_value(t, v, `C:\Tools`)
	testing.expect_value(t, forget_path(o, dir).error, Error.None)   // again: fine
}

@(test)
windows_path_value_is_deleted_when_it_empties :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	o.add_to_path = true
	testing.expect_value(t, install(o).error, Error.None)   // no Path value at all before: made by us
	_, ok := path_value(&s)
	testing.expect(t, ok, "made")
	testing.expect_value(t, remove(o).error, Error.None)
	_, ok = path_value(&s)
	testing.expect(t, !ok, "an empty PATH is not left behind")
}

@(test)
windows_record_locates_the_installed_copy :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	dir := fmt.tprintf("%s\\installed", s.dir)
	testing.expect_value(t, windows_locate(o, context.temp_allocator), "")
	testing.expect_value(t, record_install(o, dir, "0.3.0").error, Error.None)
	key := fmt.tprintf("%s\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Wren", s.root)
	get :: proc(t: ^testing.T, key, name, want: string) {
		v, ok := reg_get(key, name)
		testing.expectf(t, ok && v == want, "%s [%s] = %q, want %q", key, name, v, want)
	}
	get(t, key, "DisplayName", "Wren")
	get(t, key, "DisplayVersion", "0.3.0")
	get(t, key, "InstallLocation", dir)
	get(t, key, "UninstallString", fmt.tprintf("\"%s\\%s\" --setup", dir, exe_name_of(o.identity)))
	testing.expect_value(t, windows_locate(o, context.temp_allocator), dir)
	testing.expect_value(t, install_target(o), dir)   // no install_dir option: the record says where
	o.install_dir = `X:\elsewhere`
	testing.expect_value(t, install_target(o), `X:\elsewhere`)   // the option wins
	o.install_dir = ""

	// a key of the same name that is not ours is neither read nor deleted
	other := fmt.tprintf("%s\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Wren", s.root)
	reg_delete_tree(other)
	testing.expect(t, reg_set(other, "InstallLocation", `D:\not ours`), "someone else's key")
	testing.expect_value(t, windows_locate(o, context.temp_allocator), "")
	testing.expect_value(t, unrecord_install(o).error, Error.None)
	testing.expect(t, reg_key_exists(other), "not deleted")
	reg_delete_tree(other)

	testing.expect_value(t, record_install(o, dir, "0.3.0").error, Error.None)
	testing.expect_value(t, unrecord_install(o).error, Error.None)
	testing.expect(t, !reg_key_exists(key), "the record is removed")
}

@(test)
windows_remove_files_reports_what_a_program_holds :: proc(t: ^testing.T) {
	tr := tree_make()
	defer tree_destroy(&tr)
	testing.expect_value(t, files_install(plan_of(&tr)).error, Error.None)
	held := fmt.tprintf("%s\\wren.exe", tr.dst)
	// open without FILE_SHARE_DELETE: it can be neither deleted nor renamed, which is what a loaded image is for delete
	h := win.CreateFileW(win.utf8_to_wstring(held, context.temp_allocator), win.GENERIC_READ, win.FILE_SHARE_READ, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	testing.expect(t, h != win.INVALID_HANDLE_VALUE, "opened")
	r := files_remove(&tr.opts, tr.dst)
	testing.expect_value(t, len(r.leftovers), 1)
	testing.expect(t, len(r.leftovers) == 1 && same_path(r.leftovers[0], held), "the held file is reported")
	testing.expect(t, !os.exists(fmt.tprintf("%s\\vcruntime140.dll", tr.dst)), "the others are gone")
	testing.expect(t, os.is_file(fmt.tprintf("%s\\%s", tr.dst, MANIFEST_NAME)), "the manifest stays while something is left")
	testing.expect(t, !r.folder, "and so does the folder")
	win.CloseHandle(h)
	// after the program ends: the next removal finishes
	r = files_remove(&tr.opts, tr.dst)
	testing.expect_value(t, len(r.leftovers), 0)
	testing.expect(t, r.folder && !os.exists(tr.dst), "everything is gone")
}

@(test)
windows_cleanup_script_waits_for_the_process_and_escapes_percent :: proc(t: ^testing.T) {
	text := cleanup_script({`C:\a b\wren.exe`, `C:\100%\x.dll`}, `C:\a b`, 4242)
	testing.expect(t, strings.contains(text, `tasklist /nh /fi "PID eq 4242"`), "waits for the process")
	testing.expect(t, strings.contains(text, `del /f /q "C:\a b\wren.exe"`), "deletes a file with a space in its path")
	testing.expect(t, strings.contains(text, `"C:\100%%\x.dll"`), "a percent sign is doubled")
	testing.expect(t, strings.contains(text, `rmdir "C:\a b"`), "then the folder")
	testing.expect(t, strings.contains(text, `del "%~f0"`), "and itself")
	testing.expect(t, !strings.contains(cleanup_script({`C:\x`}, "", 0), "tasklist"), "no process to wait for")
}

// The helper for real: a process stands for the running program; once it has ended, the files it held are deleted, then the
// folder, and the batch file deletes itself.
@(test)
windows_cleanup_later_deletes_after_the_process_ends :: proc(t: ^testing.T) {
	tr := tree_make()
	defer tree_destroy(&tr)
	dir := fmt.tprintf("%s\\held", tr.root)
	_ = os.make_directory_all(dir)
	a, b := fmt.tprintf("%s\\a.exe.old", dir), fmt.tprintf("%s\\wren_install.txt", dir)
	_ = os.write_entire_file(a, "x")
	_ = os.write_entire_file(b, "x")
	p, err := os.process_start(os.Process_Desc{command = {"cmd.exe", "/d", "/c", "ping -n 4 127.0.0.1 >nul"}})
	testing.expect(t, err == nil, "a process to wait for")
	if err != nil { return }
	ok := cleanup_later({a, b}, dir, u32(p.pid))
	testing.expect(t, ok, "the helper starts")
	t0 := time.now()
	for time.since(t0) < 20 * time.Second && os.exists(dir) { time.sleep(200 * time.Millisecond) }
	_, _ = os.process_wait(p)
	testing.expect(t, !os.exists(a) && !os.exists(b), "the files are deleted")
	testing.expect(t, !os.exists(dir), "and the folder")
	script := fmt.tprintf("%s\\wren_cleanup_%d.cmd", strings.trim_right(os.temp_dir(context.temp_allocator) or_else "", "\\/"), win.GetCurrentProcessId())
	for time.since(t0) < 20 * time.Second && os.exists(script) { time.sleep(200 * time.Millisecond) }
	testing.expect(t, !os.exists(script), "the batch file deleted itself")
}