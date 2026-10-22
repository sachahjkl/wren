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
	for p in ([]string{s.exe, s.exe2}) {
		dir := p[:strings.last_index_byte(p, '\\')]
		_ = os.make_directory_all(dir)
		_ = os.write_entire_file(p, "MZ not a program")
	}
	s.opts = Options{
		identity = Identity{name = "Wren", key = "Wren", slug = "wren", aumid = "FromentSoftware.Wren.Test", description = "A test.", vendor = "Froment Software"},
		exe = s.exe, register_browser = true, file_types = split_list(".htm,.html,.svg,.webp", context.temp_allocator),
		menu_dir = s.menu, registry_root = s.root, notify_system = false,
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
	delete(s.dir); delete(s.menu); delete(s.exe); delete(s.exe2); delete(s.root)
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
		exe = exe, register_browser = true, file_types = {".html"}, notify_system = true,
	}
	defer remove(&o)
	testing.expect_value(t, install(&o).error, Error.None)
	state, _ := state_of(&o)
	testing.expect_value(t, state, State.Installed)
	testing.expect_value(t, remove(&o).error, Error.None)
	state, _ = state_of(&o)
	testing.expect_value(t, state, State.Absent)
}
