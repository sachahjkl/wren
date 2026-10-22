package desktop

// The few registry operations the Windows backend needs, all under HKEY_CURRENT_USER and with paths given as plain
// strings. Nothing here reaches HKEY_LOCAL_MACHINE: an integration never needs administrator rights.

import "core:strings"
import win "core:sys/windows"

// The key that stands for HKCU\Software: "Software" itself, or a scratch key under it for the tests.
@(private)
registry_root_of :: proc(o: ^Options) -> string { return o.registry_root != "" ? o.registry_root : "Software" }

@(private)
reg_join :: proc(parts: ..string) -> string { return strings.join(parts, "\\", context.temp_allocator) }

// Sets a string value (the default value when `name` is empty), creating the key and its parents.
@(private)
reg_set :: proc(path, name, value: string) -> bool {
	key: win.HKEY
	if win.RegCreateKeyExW(win.HKEY_CURRENT_USER, wide(path), 0, nil, win.REG_OPTION_NON_VOLATILE, win.KEY_SET_VALUE | win.KEY_CREATE_SUB_KEY, nil, &key, nil) != 0 { return false }
	defer win.RegCloseKey(key)
	w := win.utf8_to_wstring(value, context.temp_allocator)
	units := 0
	for (cast([^]u16)w)[units] != 0 { units += 1 }
	return win.RegSetValueExW(key, name == "" ? nil : wide(name), 0, win.REG_SZ, cast(^win.BYTE)rawptr(w), win.DWORD((units + 1) * 2)) == 0
}

// A string value ("" and false when the key or the value is missing, or the value is not a string).
@(private)
reg_get :: proc(path, name: string) -> (value: string, ok: bool) {
	size: win.DWORD
	if win.RegGetValueW(win.HKEY_CURRENT_USER, wide(path), name == "" ? nil : wide(name), win.RRF_RT_REG_SZ, nil, nil, &size) != 0 || size < 2 { return "", false }
	buf := make([]u16, int(size) / 2 + 1, context.temp_allocator)
	if win.RegGetValueW(win.HKEY_CURRENT_USER, wide(path), name == "" ? nil : wide(name), win.RRF_RT_REG_SZ, nil, raw_data(buf), &size) != 0 { return "", false }
	return narrow(buf), true
}

// A REG_SZ or REG_EXPAND_SZ value as stored (%VARIABLES% not expanded), with whether it is the expanding kind.
@(private)
reg_get_any :: proc(path, name: string) -> (value: string, expand, ok: bool) {
	flags := win.DWORD(win.RRF_RT_REG_SZ | win.RRF_RT_REG_EXPAND_SZ | win.RRF_NOEXPAND)
	size, kind: win.DWORD
	if win.RegGetValueW(win.HKEY_CURRENT_USER, wide(path), name == "" ? nil : wide(name), flags, &kind, nil, &size) != 0 { return "", false, false }
	buf := make([]u16, int(size) / 2 + 1, context.temp_allocator)
	if win.RegGetValueW(win.HKEY_CURRENT_USER, wide(path), name == "" ? nil : wide(name), flags, &kind, raw_data(buf), &size) != 0 { return "", false, false }
	return narrow(buf), kind == win.REG_EXPAND_SZ, true
}

// Sets a string value of the given kind (REG_EXPAND_SZ when `expand`), creating the key.
@(private)
reg_set_kind :: proc(path, name, value: string, expand: bool) -> bool {
	key: win.HKEY
	if win.RegCreateKeyExW(win.HKEY_CURRENT_USER, wide(path), 0, nil, win.REG_OPTION_NON_VOLATILE, win.KEY_SET_VALUE | win.KEY_CREATE_SUB_KEY, nil, &key, nil) != 0 { return false }
	defer win.RegCloseKey(key)
	w := win.utf8_to_wstring(value, context.temp_allocator)
	units := 0
	for (cast([^]u16)w)[units] != 0 { units += 1 }
	kind := expand ? win.DWORD(win.REG_EXPAND_SZ) : win.DWORD(win.REG_SZ)
	return win.RegSetValueExW(key, name == "" ? nil : wide(name), 0, kind, cast(^win.BYTE)rawptr(w), win.DWORD((units + 1) * 2)) == 0
}

// A DWORD value (0 and false when missing).
@(private)
reg_set_dword :: proc(path, name: string, value: u32) -> bool {
	key: win.HKEY
	if win.RegCreateKeyExW(win.HKEY_CURRENT_USER, wide(path), 0, nil, win.REG_OPTION_NON_VOLATILE, win.KEY_SET_VALUE | win.KEY_CREATE_SUB_KEY, nil, &key, nil) != 0 { return false }
	defer win.RegCloseKey(key)
	v := value
	return win.RegSetValueExW(key, wide(name), 0, win.REG_DWORD, cast(^win.BYTE)&v, 4) == 0
}

@(private)
reg_key_exists :: proc(path: string) -> bool {
	key: win.HKEY
	if win.RegOpenKeyExW(win.HKEY_CURRENT_USER, wide(path), 0, win.KEY_READ, &key) != 0 { return false }
	win.RegCloseKey(key)
	return true
}

// Deletes the key and everything under it (true when it is gone, also when it never was there).
@(private)
reg_delete_tree :: proc(path: string) -> bool {
	r := RegDeleteTreeW(win.HKEY_CURRENT_USER, wide(path))
	return r == 0 || r == win.LSTATUS(win.ERROR_FILE_NOT_FOUND)
}

@(private)
reg_delete_value :: proc(path, name: string) -> bool {
	key: win.HKEY
	r := win.RegOpenKeyExW(win.HKEY_CURRENT_USER, wide(path), 0, win.KEY_SET_VALUE, &key)
	if r == win.LSTATUS(win.ERROR_FILE_NOT_FOUND) { return true }
	if r != 0 { return false }
	defer win.RegCloseKey(key)
	r = RegDeleteValueW(key, wide(name))
	return r == 0 || r == win.LSTATUS(win.ERROR_FILE_NOT_FOUND)
}

// The program a shell command line runs: `"C:\dir\wren.exe" "%1"` -> C:\dir\wren.exe.
@(private)
command_program :: proc(command: string) -> string {
	c := strings.trim_left_space(command)
	if c == "" { return "" }
	if c[0] == '"' {
		end := strings.index_byte(c[1:], '"')
		return end < 0 ? c[1:] : c[1:1 + end]
	}
	end := strings.index_any(c, " \t")
	return end < 0 ? c : c[:end]
}

// Deletes a scratch registry root (a test's, or a script's dry run): only keys under Software\WrenTest\ or
// Software\WrenSetupTest\ can be deleted, so a wrong argument cannot reach the real ones.
delete_scratch_root :: proc(root: string) -> bool {
	if !(strings.has_prefix(root, `Software\WrenTest\`) || strings.has_prefix(root, `Software\WrenSetupTest\`)) || strings.contains(root, "..") { return false }
	return reg_delete_tree(root)
}
