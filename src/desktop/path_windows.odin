package desktop

// The user's PATH (HKEY_CURRENT_USER\Environment, value Path): the program's folder goes in it so that `wren` runs from
// any terminal. The value is a REG_EXPAND_SZ (it may hold %USERPROFILE% and the like: entries are compared after
// expansion), never written twice for the same folder, and the open programs are told ("Environment" in a
// WM_SETTINGCHANGE broadcast) unless the roots are a test's.
//
// The mark: a value of our own, `PathDir`, in Software\FromentSoftware\<key> (under the injectable registry root) names the
// folder the program added. Turning the option off or removing the integration takes out only the folder that mark names:
// a folder the user put on the PATH by hand stays. (Uninstalling the copy takes its folder out whatever the mark says:
// the folder is about to be deleted.)

import "core:strings"
import win "core:sys/windows"

foreign import user32_env "system:User32.lib"
@(default_calling_convention = "system", private = "file")
foreign user32_env {
	SendMessageTimeoutW :: proc(hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, flags: win.UINT, timeout: win.UINT, result: ^win.DWORD_PTR) -> win.LRESULT ---
}

@(private = "file") SMTO_ABORTIFHUNG :: 0x0002

@(private = "file")
env_key :: proc(o: ^Options) -> string { return o.environment_root != "" ? o.environment_root : "Environment" }

@(private = "file")
mark_key :: proc(o: ^Options) -> string { return reg_join(registry_root_of(o), "FromentSoftware", o.identity.key) }

@(private = "file")
MARK_PATH :: "PathDir"

// One PATH entry as a plain folder: quotes off, variables expanded, no trailing separator.
@(private = "file")
entry_folder :: proc(entry: string) -> string {
	e := strings.trim_space(entry)
	if len(e) >= 2 && e[0] == '"' && e[len(e) - 1] == '"' { e = e[1:len(e) - 1] }
	if strings.index_byte(e, '%') >= 0 {
		w := wide(e)
		buf: [4096]u16
		n := win.ExpandEnvironmentStringsW(w, raw_data(buf[:]), win.DWORD(len(buf)))
		if n > 0 && int(n) <= len(buf) { e = narrow(buf[:]) }
	}
	return strings.trim_right(e, "\\/")
}

@(private = "file")
entries_of :: proc(value: string) -> []string {
	parts := strings.split(value, ";", context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	for p in parts { if strings.trim_space(p) != "" { append(&out, p) } }
	return out[:]
}

// Is `dir` one of the entries of the user's PATH?
@(private)
path_contains :: proc(o: ^Options, dir: string) -> bool {
	value, _, ok := reg_get_any(env_key(o), "Path")
	if !ok { return false }
	want := strings.trim_right(dir, "\\/")
	for e in entries_of(value) { if same_path(entry_folder(e), want) { return true } }
	return false
}

// Puts `dir` at the end of the user's PATH (nothing when it is there), and marks it as ours.
@(private)
path_add :: proc(o: ^Options, dir: string) -> Result {
	key := env_key(o)
	value, _, ok := reg_get_any(key, "Path")
	want := strings.trim_right(dir, "\\/")
	if !ok { value = "" }
	already := false
	for e in entries_of(value) { if same_path(entry_folder(e), want) { already = true; break } }
	if !already {
		next := strings.trim_right(value, "; \t")
		next = next == "" ? want : strings.concatenate({next, ";", want}, context.temp_allocator)
		if !reg_set_kind(key, "Path", next, true) { return {.System, "cannot write HKCU\\Environment\\Path"} }
		_ = reg_set(mark_key(o), MARK_PATH, want)
	}   // else it was there before us: not ours to take out (no mark)
	return {}
}

// Takes `dir` out of the user's PATH. `force`: whatever the mark says; else only when the mark names this folder.
@(private)
path_take_out :: proc(o: ^Options, dir: string, force: bool) -> Result {
	want := strings.trim_right(dir, "\\/")
	marked, has_mark := reg_get(mark_key(o), MARK_PATH)
	ours := has_mark && same_path(marked, want)
	if !force && !ours { return {} }
	key := env_key(o)
	if value, _, ok := reg_get_any(key, "Path"); ok {
		kept := make([dynamic]string, context.temp_allocator)
		changed := false
		for e in entries_of(value) {
			if same_path(entry_folder(e), want) { changed = true } else { append(&kept, e) }
		}
		if changed {
			if len(kept) == 0 {
				if !reg_delete_value(key, "Path") { return {.System, "cannot delete HKCU\\Environment\\Path"} }
			} else if !reg_set_kind(key, "Path", strings.join(kept[:], ";", context.temp_allocator), true) {
				return {.System, "cannot write HKCU\\Environment\\Path"}
			}
		}
	}
	if ours { reg_delete_value(mark_key(o), MARK_PATH) }
	return {}
}

// Open programs (Explorer, new terminals) read the environment again.
@(private)
broadcast_environment :: proc() {
	result: win.DWORD_PTR
	SendMessageTimeoutW(win.HWND_BROADCAST, win.WM_SETTINGCHANGE, 0, win.LPARAM(uintptr(rawptr(wide("Environment")))), SMTO_ABORTIFHUNG, 3000, &result)
}

@(private)
windows_path_remove :: proc(o: ^Options, dir: string) -> Result {
	r := path_take_out(o, dir, force = true)
	if o.notify_system { broadcast_environment() }
	return r
}
