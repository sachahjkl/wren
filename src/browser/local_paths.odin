package browser

import "core:strings"
import win "core:sys/windows"
import "toolkit:platform"
import "toolkit:ui"
import "wb:config"
import "wb:fetch"
import "wb:host"
import "wb:instance"
import "wb:base"

////////////////////////////////
// Paths of this computer as addresses: what is typed or pasted in the address bar (`C:\dir\page.html`, `S:/site`, `C:`,
// `\\server\share\doc.html`, `"C:\quoted path"` as Explorer's "Copy as path" gives it, `~\Documents`), what is given
// on the command line, and files or folders dropped on the window, all become the file: URL of the path. A folder
// then opens its index.html or its listing (fetch/directory.odin). A relative path (`docs\a.html`) is ambiguous: it
// stays a search.

LOCAL_PATH_PREFS := [?]config.Def{
	{name = "browser.drop.open_files", kind = .Bool, default = {b = true},
		description = "Files and folders dropped on the window open: the first in the current tab, the others in new tabs."},
}

register_local_path_prefs :: proc(p: ^config.Prefs) { config.register(p, LOCAL_PATH_PREFS[:]) }

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
// Dropping files and folders on the window (WM_DROPFILES). The toolkit's window does not take drops: the shell
// subclasses the native window (comctl32), takes the paths in the window procedure and posts them to the loop, which
// opens them between frames like any navigation.

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

drop_files_init :: proc(app: ^App) {
	hwnd := app.win.hwnd
	if hwnd == nil { return }
	dnd_init(app)   // dnd_shell.odin: the OLE drop target (drags with their events to the page); WM_DROPFILES stays for an elevated browser
	win.SetWindowSubclass(hwnd, drop_subclass, DROP_SUBCLASS_ID, 0)   // (core:sys/windows declares it without its result)
	drop_hwnd = hwnd
	// an elevated browser still takes drops from Explorer (UIPI lets these three messages through). Only an elevated one: a normal
	// browser keeps the default, which refuses them from processes of a lower integrity (a sandbox would otherwise open any path)
	if instance.is_elevated() { for m in ([]win.UINT{win.WM_DROPFILES, win.WM_COPYDATA, WM_COPYGLOBALDATA}) { ChangeWindowMessageFilterEx(hwnd, m, MSGFLT_ALLOW, nil) } }
	drop_files_apply(app)
	config.watch(&app.prefs, "browser.drop.", proc(user: rawptr, name: string, p: ^config.Prefs) { drop_files_apply((^App)(user)) }, app)
}

@(private = "file")
drop_files_apply :: proc(app: ^App) {
	// (with the OLE target, OLE takes the drops: WM_DROPFILES is not asked for)
	if drop_hwnd != nil { win.DragAcceptFiles(drop_hwnd, win.BOOL(config.bool_of(&app.prefs, "browser.drop.open_files") && !platform.drop_target_enabled(app.win))) }
}

drop_files_destroy :: proc(app: ^App) {
	dnd_destroy(app)
	page_input_destroy(app)
	if drop_hwnd == nil { return }
	win.DragAcceptFiles(drop_hwnd, false)
	RemoveWindowSubclass(drop_hwnd, drop_subclass, DROP_SUBCLASS_ID)
	drop_hwnd = nil
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

// Files and folders dropped on the window: the first in the current tab, the others in new tabs (in the background).
open_dropped_paths :: proc(app: ^App, paths: []string) {
	wnd := active_window(app)
	first := -1
	for p, i in paths {
		address := fetch.file_url_from_path(p, false, context.temp_allocator)   // a folder is redirected to its URL with '/'
		if i == 0 && current_tab(app) != nil {
			first = wnd.current
			navigate(app, current_tab(app), address, origin = .User)
		} else {
			tab_open(app, address, origin = .User)
			if first < 0 { first = wnd.current }
		}
	}
	// the first one is shown (the others wait in their tabs, as when links open in the background)
	if first >= 0 && first < len(wnd.tabs) {
		wnd.current = first
		if t := current_tab(app); t != nil { ui.field_set(&wnd.address, t.url) }
	}
	request_frames(app, 3)
}
