package desktop

// Windows: the system's record of an installed copy, and the help it needs to delete a running program's files.
//
// The record is the key Settings > Apps lists programs from:
//   Software\Microsoft\Windows\CurrentVersion\Uninstall\<key>   DisplayName, DisplayVersion, Publisher, InstallLocation,
//   DisplayIcon, UninstallString (`"<exe>" --setup`: it opens the Setup dialog, whose Uninstall button does the work),
//   NoModify, NoRepair, and `WrenIntegration` (the AppUserModelID: the mark that makes the key ours).
// It is also how the program finds where its installed copy is when it was installed somewhere other than the default
// folder. The key sits under the injectable registry root like the rest, so a test never writes the real one.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"

@(private = "file")
uninstall_key :: proc(o: ^Options) -> string {
	return reg_join(registry_root_of(o), "Microsoft", "Windows", "CurrentVersion", "Uninstall", o.identity.key)
}

@(private)
windows_default_install_dir :: proc(o: ^Options, allocator: runtime.Allocator) -> string {
	base := known_folder(win.FOLDERID_LocalAppData)
	if base == "" { return "" }
	return strings.concatenate({base, "\\Programs\\", o.identity.name}, allocator)
}

// The folder of the recorded installation, when the record is ours and the executable is there.
@(private)
windows_locate :: proc(o: ^Options, allocator: runtime.Allocator) -> string {
	key := uninstall_key(o)
	if mark, _ := reg_get(key, MARK_VALUE); mark != o.identity.aumid { return "" }
	dir, ok := reg_get(key, "InstallLocation")
	if !ok || dir == "" { return "" }
	return strings.clone(dir, allocator)
}

@(private)
windows_record :: proc(o: ^Options, dir, version: string) -> Result {
	key := uninstall_key(o)
	exe := strings.concatenate({strings.trim_right(dir, "\\/"), "\\", exe_name_of(o.identity)}, context.temp_allocator)
	failed :: proc(key: string) -> Result { return {.System, strings.concatenate({"cannot write HKCU\\", key}, context.temp_allocator)} }
	ok := reg_set(key, "DisplayName", o.identity.name)
	ok = ok && reg_set(key, "DisplayVersion", version)
	ok = ok && reg_set(key, "Publisher", o.identity.vendor)
	ok = ok && reg_set(key, "InstallLocation", dir)
	ok = ok && reg_set(key, "DisplayIcon", strings.concatenate({exe, ",0"}, context.temp_allocator))
	ok = ok && reg_set(key, "UninstallString", strings.concatenate({"\"", exe, "\" --setup"}, context.temp_allocator))
	ok = ok && reg_set(key, MARK_VALUE, o.identity.aumid)
	ok = ok && reg_set_dword(key, "NoModify", 1) && reg_set_dword(key, "NoRepair", 1)
	if !ok { return failed(key) }
	return {}
}

@(private)
windows_unrecord :: proc(o: ^Options) -> Result {
	key := uninstall_key(o)
	if mark, _ := reg_get(key, MARK_VALUE); mark != o.identity.aumid { return {} }   // not ours (or already gone)
	if !reg_delete_tree(key) { return {.System, strings.concatenate({"cannot delete HKCU\\", key}, context.temp_allocator)} }
	return {}
}

////////////////////////////////
// Deleting files that a running program holds

// After process `pid` ends, deletes `files` and then `folder` (when empty): a batch file in the temporary folder, run
// by a hidden cmd.exe that checks for the process every second, then tries to delete (up to 30 times) and deletes
// itself. The caller has already renamed the files out of the way where it could; this is for the ones a running program
// holds. False when the helper could not be started.
@(private)
windows_cleanup_later :: proc(files: []string, folder: string, pid: u32) -> bool {
	tmp, err := os.temp_dir(context.temp_allocator)
	if err != nil || tmp == "" { return false }
	script := strings.concatenate({strings.trim_right(tmp, "\\/"), fmt.tprintf("\\wren_cleanup_%d.cmd", win.GetCurrentProcessId())}, context.temp_allocator)
	text := cleanup_script(files, folder, pid)
	if werr := os.write_entire_file(script, text); werr != nil { return false }

	shell := system_file("cmd.exe", .System)   // (by its full path: a bare name is looked for in the working directory first)
	if shell == "" { return false }
	command := fmt.tprintf("\"%s\" /d /c \"\"%s\"\"", shell, script)
	cmd := win.utf8_to_utf16(command, context.temp_allocator)
	cmd = append_nul(cmd)
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW), dwFlags = win.STARTF_USESHOWWINDOW, wShowWindow = u16(win.SW_HIDE)}
	pi: win.PROCESS_INFORMATION
	flags := win.DWORD(win.CREATE_NO_WINDOW)   // (a hidden console of its own: the tools it runs inherit it and show nothing)
	if !win.CreateProcessW(win.utf8_to_wstring(shell, context.temp_allocator), cstring16(raw_data(cmd)), nil, nil, false, flags, nil, nil, &si, &pi) { return false }
	win.CloseHandle(pi.hThread)
	win.CloseHandle(pi.hProcess)
	return true
}

@(private)
cleanup_script :: proc(files: []string, folder: string, pid: u32) -> string {
	sb := strings.builder_make(context.temp_allocator)
	w :: proc(sb: ^strings.Builder, parts: ..string) { for p in parts { strings.write_string(sb, p) }; strings.write_string(sb, "\r\n") }
	w(&sb, "@echo off")
	w(&sb, "set /a n=0")
	if pid != 0 {
		w(&sb, ":wait")
		w(&sb, fmt.tprintf("tasklist /nh /fi \"PID eq %d\" 2>nul | find \"%d\" >nul", pid, pid))
		w(&sb, "if errorlevel 1 goto go")
		w(&sb, "set /a n+=1")
		w(&sb, "if %n% geq 300 goto go")
		w(&sb, "ping -n 2 127.0.0.1 >nul")
		w(&sb, "goto wait")
	}
	w(&sb, ":go")
	w(&sb, "set /a n=0")
	w(&sb, ":again")
	for f in files { w(&sb, "del /f /q \"", bat_escape(f), "\" 2>nul") }
	for f in files { w(&sb, "if exist \"", bat_escape(f), "\" goto retry") }
	w(&sb, "goto done")
	w(&sb, ":retry")
	w(&sb, "set /a n+=1")
	w(&sb, "if %n% geq 30 goto done")
	w(&sb, "ping -n 2 127.0.0.1 >nul")
	w(&sb, "goto again")
	w(&sb, ":done")
	if folder != "" { w(&sb, "rmdir \"", bat_escape(folder), "\" 2>nul") }
	w(&sb, "(goto) 2>nul & del \"%~f0\"")
	return strings.to_string(sb)
}

@(private = "file")
append_nul :: proc(s: []u16) -> []u16 {
	out := make([]u16, len(s) + 1, context.temp_allocator)
	copy(out, s)
	return out
}

// A path in a batch file: a percent sign is doubled (% starts a variable there).
@(private = "file")
bat_escape :: proc(s: string) -> string {
	r, _ := strings.replace_all(s, "%", "%%", context.temp_allocator)
	return r
}
