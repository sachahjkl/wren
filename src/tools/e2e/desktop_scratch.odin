#+build windows
package e2e_scenarios

// Throwaway roots for what the desktop integration writes (WREN_DESKTOP_* of src/desktop/cli.odin): the Start menu, the Desktop, HKCU\Software, the
// install folder, in a test's folder and a key of its own under HKCU, gone with it. Nothing of the machine's own is written: `real_state` is what a
// test compares before and after to say so.

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "core:testing"
import "wb:e2e"

foreign import advapi32 "system:Advapi32.lib"
@(default_calling_convention = "system", private = "file")
foreign advapi32 {
	RegDeleteTreeW :: proc(key: win.HKEY, sub_key: cstring16) -> win.LSTATUS ---
	RegDeleteKeyW  :: proc(key: win.HKEY, sub_key: cstring16) -> win.LSTATUS ---
}

// Under HKCU: every test's key is under this one, which goes with the last.
@(private = "file") REGISTRY_PARENT :: `Software\WrenE2E`
@(private = "file") READ_KEY :: win.KEY_READ

Desktop_Scratch :: struct {
	env:       []string,   // what a program is started with so that these are its roots
	root:      string,     // the key of the registry, under HKCU
	menu, desktop, install: string,
}

// `folder`: a test's folder. The strings stay for the test.
desktop_scratch :: proc(t: ^testing.T, folder: string) -> Desktop_Scratch {
	d: Desktop_Scratch
	d.root = fmt.tprintf(`%s\%s`, REGISTRY_PARENT, e2e.unique())
	d.menu = fmt.tprintf("%s/StartMenu", folder)
	d.desktop = fmt.tprintf("%s/Desktop", folder)
	d.install = fmt.tprintf("%s/Programs/Wren Dev", folder)
	_ = os.make_directory_all(d.menu)
	_ = os.make_directory_all(d.desktop)
	env := make([]string, 5, context.temp_allocator)
	env[0] = fmt.tprintf("WREN_DESKTOP_MENU_DIR=%s", d.menu)
	env[1] = fmt.tprintf("WREN_DESKTOP_DESKTOP_DIR=%s", d.desktop)
	env[2] = fmt.tprintf("WREN_DESKTOP_REGISTRY_ROOT=%s", d.root)
	env[3] = fmt.tprintf(`WREN_DESKTOP_ENVIRONMENT_ROOT=%s\Environment`, d.root)
	env[4] = fmt.tprintf("WREN_DESKTOP_INSTALL_DIR=%s", d.install)
	d.env = env
	testing.cleanup(t, proc(p: rawptr) {
		root := string(cstring(p))
		RegDeleteTreeW(win.HKEY_CURRENT_USER, wide(root))
		RegDeleteKeyW(win.HKEY_CURRENT_USER, wide(REGISTRY_PARENT))   // (refused while another test's key is under it)
		delete(cstring(p))
	}, rawptr(strings.clone_to_cstring(d.root)))
	return d
}

@(private = "file")
wide :: proc(s: string) -> cstring16 { return cstring16(win.utf8_to_wstring(s, context.temp_allocator)) }

// A key exists, under HKCU.
registry_key_exists :: proc(path: string) -> bool {
	key: win.HKEY
	if win.RegOpenKeyExW(win.HKEY_CURRENT_USER, wide(path), 0, READ_KEY, &key) != 0 { return false }
	win.RegCloseKey(key)
	return true
}

// A value of the registry as the program's own record has it, under HKCU ("": none).
@(private = "file")
registry_text :: proc(path, name: string) -> string {
	buf: [1 << 15]u16
	size := win.DWORD(size_of(buf))
	if win.RegGetValueW(win.HKEY_CURRENT_USER, wide(path), wide(name), win.RRF_RT_REG_SZ | win.RRF_RT_REG_EXPAND_SZ | win.RRF_NOEXPAND, nil, &buf[0], &size) != 0 { return "" }
	text, _ := win.utf16_to_utf8(buf[:size / 2], context.temp_allocator)
	return string(text)
}

// What the machine's own desktop has of a Wren: what a run must leave as it found it.
real_state :: proc() -> string {
	appdata, _ := os.lookup_env("APPDATA", context.temp_allocator)
	return fmt.tprintf("PATH=%s menu=%v client=%v uninstall=%v",
		registry_text("Environment", "Path"),
		os.exists(fmt.tprintf(`%s\Microsoft\Windows\Start Menu\Programs\Wren Dev.lnk`, appdata)),
		registry_key_exists(`Software\Clients\StartMenuInternet\WrenDev`),
		registry_key_exists(`Software\Microsoft\Windows\CurrentVersion\Uninstall\WrenDev`))
}
