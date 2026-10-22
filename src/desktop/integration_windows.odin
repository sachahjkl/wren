package desktop

// Windows: everything in the user's profile (the user's Start menu folder, HKEY_CURRENT_USER), nothing that needs
// administrator rights.
//
//   Start menu          <Programs>\<name>.lnk  made with IShellLinkW + IPersistFile: the executable, its own icon,
//                       and the AppUserModelID (IPropertyStore, PKEY_AppUserModel_ID) that the program's windows also
//                       declare (set_process_identity), so that pinning the shortcut to the taskbar and grouping the
//                       windows under it work.
//   Candidate browser   Windows does not let a program make itself the default browser: the user picks one in
//                       Settings > Apps > Default apps. Registering is what lists the program there:
//                         Software\Clients\StartMenuInternet\<key>        (name, icon, command, Capabilities: the
//                                                                          URL schemes and file types it can open)
//                         Software\RegisteredApplications                 (<key> -> its Capabilities key)
//                         Software\Classes\<key>HTML                      (the ProgID: `"<exe>" "%1"`)
//                       then SHChangeNotify(SHCNE_ASSOCCHANGED), so open windows of Settings notice.
//
// Marks: the shortcut carries the AppUserModelID; the keys carry `WrenIntegration` (the AppUserModelID) or run the
// executable. Removal deletes what has a mark and nothing else.

import "base:runtime"
import "core:os"
import "core:strings"
import win "core:sys/windows"

@(private = "file")
WINDOWS_BACKEND := Backend{
	name = "windows",
	targets = "Start menu, default apps",
	parts = {.Launcher, .Registration},
	status = windows_status,
	install = windows_install,
	remove = windows_remove,
	open_defaults = windows_open_defaults,
}

@(private)
platform_backend :: proc() -> ^Backend { return &WINDOWS_BACKEND }

// The name Windows groups this process's windows under: call before the first window exists.
set_process_identity :: proc(id: Identity) {
	if id.aumid != "" { SetCurrentProcessExplicitAppUserModelID(wide(id.aumid)) }
}

MARK_VALUE :: "WrenIntegration"

////////////////////////////////
// Where things are

@(private = "file")
Layout :: struct {
	menu_dir:     string,
	lnk:          string,   // the shortcut's path
	capabilities: string,   // Software\Clients\StartMenuInternet\<key>\Capabilities (relative to HKCU)
	client:       string,   // Software\Clients\StartMenuInternet\<key>
	progid:       string,   // Software\Classes\<key>HTML
	registered:   string,   // Software\RegisteredApplications
	progid_name:  string,   // <key>HTML
}

@(private = "file")
layout_of :: proc(o: ^Options) -> (l: Layout, ok: bool) {
	root := registry_root_of(o)
	l.menu_dir = o.menu_dir != "" ? o.menu_dir : programs_folder()
	if l.menu_dir == "" { return {}, false }
	l.lnk = strings.concatenate({l.menu_dir, "\\", o.identity.name, ".lnk"}, context.temp_allocator)
	l.client = reg_join(root, "Clients", "StartMenuInternet", o.identity.key)
	l.capabilities = reg_join(l.client, "Capabilities")
	l.progid_name = strings.concatenate({o.identity.key, "HTML"}, context.temp_allocator)
	l.progid = reg_join(root, "Classes", l.progid_name)
	l.registered = reg_join(root, "RegisteredApplications")
	return l, true
}

// The user's Start menu Programs folder (%APPDATA%\Microsoft\Windows\Start Menu\Programs).
programs_folder :: proc() -> string {
	id := win.FOLDERID_Programs
	path: win.LPWSTR
	if win.SHGetKnownFolderPath(&id, 0, nil, &path) < 0 || path == nil { return "" }
	defer win.CoTaskMemFree(path)
	n := 0
	for (cast([^]u16)path)[n] != 0 { n += 1 }
	s, err := win.utf16_to_utf8((cast([^]u16)path)[:n], context.temp_allocator)
	return err == nil ? s : ""
}

////////////////////////////////
// Status

@(private = "file")
windows_status :: proc(o: ^Options, allocator: runtime.Allocator) -> Status {
	s: Status
	l, ok := layout_of(o)
	if !ok { s.error = .System; return s }
	com := com_enter()
	defer com_leave(com)

	// the shortcut: ours when it carries the AppUserModelID or runs the executable
	if os.is_file(l.lnk) {
		target, aumid, read := read_shortcut(l.lnk)
		mine := read && (aumid == o.identity.aumid || same_path(target, o.exe))
		if mine {
			ps := &s.parts[.Launcher]
			ps.present = true
			ps.target = clone_or_empty(target, allocator)
			ps.stale = !same_path(target, o.exe)
			ps.partial = aumid != o.identity.aumid   // a shortcut without the AppUserModelID does not group with the windows
		}
	}

	// the registration: three pieces; each one is ours when it has the mark or runs the executable
	client_cmd, client_cmd_ok := reg_get(reg_join(l.client, "shell", "open", "command"), "")
	client_mark, _ := reg_get(l.client, MARK_VALUE)
	progid_cmd, progid_cmd_ok := reg_get(reg_join(l.progid, "shell", "open", "command"), "")
	progid_mark, _ := reg_get(reg_join(l.progid, "Application"), "AppUserModelId")
	registered, registered_ok := reg_get(l.registered, o.identity.key)

	client_prog, progid_prog := command_program(client_cmd), command_program(progid_cmd)
	client_mine := client_mark == o.identity.aumid || (client_cmd_ok && same_path(client_prog, o.exe))
	progid_mine := progid_mark == o.identity.aumid || (progid_cmd_ok && same_path(progid_prog, o.exe))
	registered_mine := registered_ok && strings.equal_fold(registered, l.capabilities)
	if client_mine || progid_mine || registered_mine {
		ps := &s.parts[.Registration]
		ps.present = true
		ps.partial = !(client_mine && client_cmd_ok && progid_mine && progid_cmd_ok && registered_mine && reg_key_exists(l.capabilities))
		if client_mine && client_cmd_ok && !same_path(client_prog, o.exe) { ps.stale, ps.target = true, clone_or_empty(client_prog, allocator) }
		if progid_mine && progid_cmd_ok && !same_path(progid_prog, o.exe) {
			if ps.target == "" { ps.target = clone_or_empty(progid_prog, allocator) }
			ps.stale = true
		}
		if ps.target == "" && client_cmd_ok { ps.target = clone_or_empty(client_prog, allocator) }
	}
	return s
}

// What a shortcut runs and its AppUserModelID; read = false when the file is not a shortcut the shell can load.
@(private)
read_shortcut :: proc(path: string) -> (target, aumid: string, read: bool) {
	link: ^IShellLinkW
	if win.CoCreateInstance(&CLSID_ShellLink, nil, win.CLSCTX_INPROC_SERVER, &IID_IShellLinkW, cast(^rawptr)&link) < 0 || link == nil { return }
	defer link->Release()
	file: ^IPersistFile
	if link->QueryInterface(&IID_IPersistFile, cast(^rawptr)&file) < 0 || file == nil { return }
	defer file->Release()
	if file->Load(wide(path), STGM_READ) < 0 { return }
	buf: [win.MAX_PATH_WIDE]u16
	if link->GetPath(raw_data(buf[:]), i32(len(buf)), nil, SLGP_RAWPATH) >= 0 { target = narrow(buf[:]) }
	read = true
	store: ^IPropertyStore
	if link->QueryInterface(&IID_IPropertyStore, cast(^rawptr)&store) >= 0 && store != nil {
		defer store->Release()
		pv: Prop_Variant
		if store->GetValue(&PKEY_AppUserModel_ID, &pv) >= 0 {
			if pv.vt == VT_LPWSTR && pv.pointer != nil {
				w := cast([^]u16)pv.pointer
				n := 0
				for w[n] != 0 { n += 1 }
				aumid = narrow(w[:n + 1])
			}
			PropVariantClear(&pv)
		}
	}
	return
}

////////////////////////////////
// Install

@(private = "file")
windows_install :: proc(o: ^Options) -> Result {
	l, ok := layout_of(o)
	if !ok { return {.System, "the Start menu folder is unknown"} }
	if !ensure_dir(l.menu_dir) { return {.Io, strings.concatenate({"cannot create ", l.menu_dir}, context.temp_allocator)} }
	com := com_enter()
	defer com_leave(com)

	if r := write_shortcut(o, l.lnk); r.error != .None { return r }

	if o.register_browser {
		if r := write_registration(o, l); r.error != .None { return r }
	} else {
		remove_registration(o, l)   // an earlier install that registered: the option says it should not
	}
	if o.notify_system { notify_associations() }
	return {}
}

@(private = "file")
write_shortcut :: proc(o: ^Options, path: string) -> Result {
	link: ^IShellLinkW
	if win.CoCreateInstance(&CLSID_ShellLink, nil, win.CLSCTX_INPROC_SERVER, &IID_IShellLinkW, cast(^rawptr)&link) < 0 || link == nil { return {.System, "the shell link class is not available"} }
	defer link->Release()
	dir := exe_dir(o.exe)
	failed :: proc(what: string) -> Result { return {.System, strings.concatenate({"IShellLink: ", what}, context.temp_allocator)} }
	if link->SetPath(wide(o.exe)) < 0 { return failed("SetPath") }
	if dir != "" { link->SetWorkingDirectory(wide(dir)) }   // policies.txt is read from the working directory
	if link->SetIconLocation(wide(o.exe), 0) < 0 { return failed("SetIconLocation") }
	if o.identity.description != "" { link->SetDescription(wide(o.identity.description)) }
	link->SetShowCmd(win.SW_SHOWNORMAL)

	store: ^IPropertyStore
	if link->QueryInterface(&IID_IPropertyStore, cast(^rawptr)&store) < 0 || store == nil { return failed("IPropertyStore") }
	defer store->Release()
	pv := Prop_Variant{vt = VT_LPWSTR}
	pv.pointer = co_string(o.identity.aumid)
	if pv.pointer == nil { return failed("out of memory") }
	hr := store->SetValue(&PKEY_AppUserModel_ID, &pv)
	PropVariantClear(&pv)   // frees the string
	if hr < 0 { return failed("PKEY_AppUserModel_ID") }
	if store->Commit() < 0 { return failed("Commit") }

	file: ^IPersistFile
	if link->QueryInterface(&IID_IPersistFile, cast(^rawptr)&file) < 0 || file == nil { return failed("IPersistFile") }
	defer file->Release()
	if file->Save(wide(path), true) < 0 { return {.Io, strings.concatenate({"cannot write ", path}, context.temp_allocator)} }
	return {}
}

// A string in COM's allocator (what a PROPVARIANT of type VT_LPWSTR owns).
@(private = "file")
co_string :: proc(s: string) -> rawptr {
	w := win.utf8_to_wstring(s, context.temp_allocator)
	units := 0
	for (cast([^]u16)w)[units] != 0 { units += 1 }
	p := win.CoTaskMemAlloc(win.SIZE_T((units + 1) * 2))
	if p == nil { return nil }
	copy((cast([^]u16)p)[:units + 1], (cast([^]u16)w)[:units + 1])
	return p
}

@(private = "file")
exe_dir :: proc(exe: string) -> string {
	i := max(strings.last_index_byte(exe, '\\'), strings.last_index_byte(exe, '/'))
	return i > 0 ? exe[:i] : ""
}

@(private = "file")
write_registration :: proc(o: ^Options, l: Layout) -> Result {
	id := o.identity
	exe := o.exe
	icon := strings.concatenate({exe, ",0"}, context.temp_allocator)
	command := strings.concatenate({"\"", exe, "\""}, context.temp_allocator)
	open_one := strings.concatenate({"\"", exe, "\" \"%1\""}, context.temp_allocator)
	caps := l.capabilities
	failed :: proc(path: string) -> Result { return {.System, strings.concatenate({"cannot write HKCU\\", path}, context.temp_allocator)} }

	// the browser entry
	if !reg_set(l.client, "", id.name) || !reg_set(l.client, MARK_VALUE, id.aumid) { return failed(l.client) }
	if !reg_set(reg_join(l.client, "DefaultIcon"), "", icon) { return failed(l.client) }
	if !reg_set(reg_join(l.client, "shell", "open", "command"), "", command) { return failed(l.client) }
	if !reg_set(caps, "ApplicationName", id.name) || !reg_set(caps, "ApplicationIcon", icon) { return failed(caps) }
	if !reg_set(caps, "ApplicationDescription", id.description != "" ? id.description : id.name) { return failed(caps) }
	if !reg_set(reg_join(caps, "Startmenu"), "StartMenuInternet", id.key) { return failed(caps) }
	// a rewrite starts from empty association lists: a type taken out of the preference goes away
	reg_delete_tree(reg_join(caps, "URLAssociations"))
	reg_delete_tree(reg_join(caps, "FileAssociations"))
	for scheme in ([]string{"http", "https"}) {
		if !reg_set(reg_join(caps, "URLAssociations"), scheme, l.progid_name) { return failed(caps) }
	}
	for ft in o.file_types {
		ext := normalize_extension(ft)
		if ext == "" { continue }
		if !reg_set(reg_join(caps, "FileAssociations"), ext, l.progid_name) { return failed(caps) }
	}

	// the ProgID the associations name
	if !reg_set(l.progid, "", strings.concatenate({id.name, " HTML Document"}, context.temp_allocator)) { return failed(l.progid) }
	if !reg_set(reg_join(l.progid, "DefaultIcon"), "", icon) { return failed(l.progid) }
	if !reg_set(reg_join(l.progid, "shell", "open", "command"), "", open_one) { return failed(l.progid) }
	app := reg_join(l.progid, "Application")
	if !reg_set(app, "ApplicationName", id.name) || !reg_set(app, "ApplicationIcon", icon) || !reg_set(app, "AppUserModelId", id.aumid) { return failed(app) }
	if id.vendor != "" && !reg_set(app, "ApplicationCompany", id.vendor) { return failed(app) }
	if id.description != "" && !reg_set(app, "ApplicationDescription", id.description) { return failed(app) }

	// and the list Settings reads
	if !reg_set(l.registered, id.key, caps) { return failed(l.registered) }
	return {}
}

// Tells the shell that file associations changed (Settings and Explorer read them again).
@(private = "file")
notify_associations :: proc() { win.SHChangeNotify(win.SHCNE_ASSOCCHANGED, 0, nil, nil) }

////////////////////////////////
// Remove

@(private = "file")
windows_remove :: proc(o: ^Options) -> Result {
	l, ok := layout_of(o)
	if !ok { return {.System, "the Start menu folder is unknown"} }
	com := com_enter()
	defer com_leave(com)
	res: Result
	if os.is_file(l.lnk) {
		target, aumid, read := read_shortcut(l.lnk)
		if read && (aumid == o.identity.aumid || same_path(target, o.exe)) {
			if err := os.remove(l.lnk); err != nil { res = {.Io, strings.concatenate({"cannot delete ", l.lnk}, context.temp_allocator)} }
		}
	}
	if r := remove_registration(o, l); r.error != .None && res.error == .None { res = r }
	if o.notify_system { notify_associations() }
	return res
}

// Deletes the keys that are the program's (a mark, or its executable in the command) and the list entry that names
// its Capabilities key.
@(private = "file")
remove_registration :: proc(o: ^Options, l: Layout) -> Result {
	res: Result
	failed :: proc(path: string) -> Result { return {.System, strings.concatenate({"cannot delete HKCU\\", path}, context.temp_allocator)} }

	client_cmd, client_cmd_ok := reg_get(reg_join(l.client, "shell", "open", "command"), "")
	client_mark, _ := reg_get(l.client, MARK_VALUE)
	if client_mark == o.identity.aumid || (client_cmd_ok && same_path(command_program(client_cmd), o.exe)) {
		if !reg_delete_tree(l.client) { res = failed(l.client) }
	}
	progid_cmd, progid_cmd_ok := reg_get(reg_join(l.progid, "shell", "open", "command"), "")
	progid_mark, _ := reg_get(reg_join(l.progid, "Application"), "AppUserModelId")
	if progid_mark == o.identity.aumid || (progid_cmd_ok && same_path(command_program(progid_cmd), o.exe)) {
		if !reg_delete_tree(l.progid) && res.error == .None { res = failed(l.progid) }
	}
	if registered, ok := reg_get(l.registered, o.identity.key); ok && strings.equal_fold(registered, l.capabilities) {
		if !reg_delete_value(l.registered, o.identity.key) && res.error == .None { res = failed(l.registered) }
	}
	return res
}

////////////////////////////////
// The system's page of default programs

@(private = "file")
windows_open_defaults :: proc() -> bool {
	r := win.ShellExecuteW(nil, win.L("open"), win.L("ms-settings:defaultapps"), nil, nil, win.SW_SHOWNORMAL)
	return uintptr(r) > 32
}
