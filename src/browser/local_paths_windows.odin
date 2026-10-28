package browser

// Windows: paths with drive letters (`C:\dir\page.html`, `S:/site`, `C:`), UNC shares (`\\server\share\doc.html`,
// `\\?\C:\...`), Explorer's quoted "Copy as path", and `~\Documents` (%USERPROFILE%). Plus the WM_DROPFILES hook for the
// elevated browser, where the OLE drop target is refused by UIPI: the shell subclasses the native window (comctl32),
// takes the paths in the window procedure and posts them to the loop, which opens them between frames like any navigation.

import "core:strings"
import win "core:sys/windows"
import "toolkit:platform"
import "wb:config"
import "wb:fetch"
import "wb:host"
import "toolkit:instance"
import "wb:base"

@(private = "file")
is_letter :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }

// The file: URL of a local path, or ok = false when `input` is not one (a URL, words, a relative path).
local_path_url :: proc(input: string, allocator := context.temp_allocator) -> (address: string, ok: bool) {
	s := strings.trim_space(input)
	if len(s) >= 2 && s[0] == '"' && s[len(s) - 1] == '"' { s = strings.trim_space(s[1:len(s) - 1]) }
	switch {
	case len(s) == 2 && is_letter(s[0]) && s[1] == ':':                                           // C:
	case len(s) >= 3 && is_letter(s[0]) && s[1] == ':' && (s[2] == '\\' || s[2] == '/'):          // C:\dir, C:/dir
	case len(s) > 2 && strings.has_prefix(s, `\\`) && s[2] != '\\' && s[2] != '/':                 // \\server\share, \\?\C:\...
	case s == "~" || strings.has_prefix(s, `~\`) || strings.has_prefix(s, "~/"):
		home := user_home()
		if home == "" { return "", false }
		s = strings.concatenate({home, "\\", s[min(2, len(s)):]}, context.temp_allocator)
	case:
		return "", false
	}
	if strings.contains_any(s, "\x00<>|*\"") { return "", false }   // not a path Windows could name (? is the \\?\ prefix)
	directory := strings.has_suffix(s, "\\") || strings.has_suffix(s, "/")
	return fetch.file_url_from_path(s, directory, allocator), true
}

// The address given on the command line: a relative path that names an existing file or folder (`wren.exe demos`,
// `wren.exe page.html`) is taken from the current folder, as other browsers do; anything else is an address.
command_line_address :: proc(arg: string) -> string {
	s := strings.trim_space(arg)
	if s == "" || strings.contains(s, ":") { return s }   // a URL, about:, a drive path (local_path_url takes those)
	ws := win.utf8_to_wstring(s)
	if win.GetFileAttributesW(ws) == win.INVALID_FILE_ATTRIBUTES { return s }
	buf: [1024]u16
	n := win.GetFullPathNameW(ws, u32(len(buf)), cstring16(raw_data(buf[:])), nil)
	if n == 0 || int(n) >= len(buf) { return s }
	full, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil { return s }
	return fetch.file_url_from_path(full, false, context.temp_allocator)
}

// %USERPROFILE%, without a final separator ("" when unknown).
@(private = "file")
user_home :: proc() -> string {
	buf: [win.MAX_PATH_WIDE]u16
	n := win.GetEnvironmentVariableW(win.utf8_to_wstring("USERPROFILE"), raw_data(buf[:]), u32(len(buf)))
	if n == 0 || int(n) >= len(buf) { return "" }
	s, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil { return "" }
	return strings.trim_right(s, "\\/")
}

////////////////////////////////
// WM_DROPFILES (the elevated browser)

foreign import comctl32 "system:Comctl32.lib"
@(default_calling_convention = "system", private = "file")
foreign comctl32 {
	DefSubclassProc      :: proc(hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT ---
	RemoveWindowSubclass :: proc(hwnd: win.HWND, pfn: win.SUBCLASSPROC, id: win.UINT_PTR) -> win.BOOL ---
}

foreign import user32_drop "system:User32.lib"
@(default_calling_convention = "system", private = "file")
foreign user32_drop {
	ChangeWindowMessageFilterEx :: proc(hwnd: win.HWND, message: win.UINT, action: win.DWORD, filter: rawptr) -> win.BOOL ---
}

@(private = "file") DROP_SUBCLASS_ID :: 0x5752_4450   // "WRDP"
@(private = "file") WM_COPYGLOBALDATA :: 0x0049
@(private = "file") MSGFLT_ALLOW :: 1

@(private = "file")
Dropped :: struct { paths: [dynamic]string }

@(private = "file") drop_hwnd: win.HWND

drop_files_platform_init :: proc(app: ^App) {
	hwnd := active_window(app).win.hwnd
	if hwnd == nil { return }
	win.SetWindowSubclass(hwnd, drop_subclass, DROP_SUBCLASS_ID, 0)   // (core:sys/windows declares it without its result)
	drop_hwnd = hwnd
	// an elevated browser still takes drops from Explorer (UIPI lets these three messages through). Only an elevated one: a normal
	// browser keeps the default, which refuses them from processes of a lower integrity (a sandbox would otherwise open any path)
	if instance.is_elevated() { for m in ([]win.UINT{win.WM_DROPFILES, win.WM_COPYDATA, WM_COPYGLOBALDATA}) { ChangeWindowMessageFilterEx(hwnd, m, MSGFLT_ALLOW, nil) } }
}

drop_files_platform_destroy :: proc(app: ^App) {
	if drop_hwnd == nil { return }
	win.DragAcceptFiles(drop_hwnd, false)
	RemoveWindowSubclass(drop_hwnd, drop_subclass, DROP_SUBCLASS_ID)
	drop_hwnd = nil
}

// Whether the shell asks the window for WM_DROPFILES: only when the toolkit drop target is off (an elevated browser) and
// the preference allows it. Called by drop_files_apply (local_paths.odin) on start-up and when the preference changes.
drop_files_platform_apply :: proc(app: ^App) {
	if drop_hwnd != nil { win.DragAcceptFiles(drop_hwnd, win.BOOL(config.bool_of(&app.prefs, "browser.drop.open_files") && !platform.drop_target_enabled(active_window(app).win))) }
}

@(private = "file")
drop_subclass :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, id: win.UINT_PTR, ref: win.DWORD_PTR) -> win.LRESULT {
	if msg != win.WM_DROPFILES { return DefSubclassProc(hwnd, msg, wparam, lparam) }
	context = base.process_context()
	hdrop := win.HDROP(wparam)
	d := new(Dropped)
	count := win.DragQueryFileW(hdrop, 0xFFFF_FFFF, nil, 0)
	for i in 0 ..< count {
		n := win.DragQueryFileW(hdrop, i, nil, 0)
		if n == 0 { continue }
		// (the heap: the temporary allocator is the frame's, and this runs inside the frame's event polling)
		buf := make([]u16, n + 1)
		got := win.DragQueryFileW(hdrop, i, raw_data(buf), n + 1)
		if s, err := win.utf16_to_utf8(buf[:got], context.allocator); err == nil { append(&d.paths, s) }
		delete(buf)
	}
	win.DragFinish(hdrop)
	if the_app != nil && len(d.paths) > 0 {
		host.post(&the_app.loop, drop_open, d)
	} else {
		dropped_free(d)
	}
	return 0
}

@(private = "file")
dropped_free :: proc(d: ^Dropped) {
	for p in d.paths { delete(p) }
	delete(d.paths)
	free(d)
}

@(private = "file")
drop_open :: proc(data: rawptr) {
	d := (^Dropped)(data)
	defer dropped_free(d)
	app := the_app
	if !config.bool_of(&app.prefs, "browser.drop.open_files") { return }
	open_dropped_paths(app, d.paths[:])
}
