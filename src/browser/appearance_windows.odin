package browser

import "core:sys/windows"
import "core:thread"
import "wb:css"
import "wb:style"

// Windows: the apps theme, accent color and selection colors read from the registry and GetSysColor (the same sources
// Windows' own settings write), and a thread that waits on registry change notifications (what WM_SETTINGCHANGE
// "ImmersiveColorSet" and WM_SYSCOLORCHANGE announce) and posts to the UI thread. The neutral callers are in
// appearance.odin; appearance_other.odin is the Linux counterpart.

foreign import advapi32_look "system:Advapi32.lib"
foreign import user32_look "system:User32.lib"

@(default_calling_convention = "system", private = "file")
foreign advapi32_look {
	RegNotifyChangeKeyValue :: proc(hKey: windows.HKEY, bWatchSubtree: windows.BOOL, dwNotifyFilter: windows.DWORD, hEvent: windows.HANDLE, fAsynchronous: windows.BOOL) -> windows.LSTATUS ---
}

@(default_calling_convention = "system", private = "file")
foreign user32_look {
	GetSysColor :: proc(nIndex: i32) -> windows.DWORD ---
}

@(private = "file") LOOK_KEYS := [?]string{
	`Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`,   // AppsUseLightTheme
	`Software\Microsoft\Windows\DWM`,                                  // AccentColor
	`Software\Microsoft\Windows\CurrentVersion\Explorer\Accent`,       // AccentColorMenu
	`Control Panel\Colors`,                                            // the system colors (Hilight, HilightText)
}

@(private = "file")
Look_Watch :: struct {
	thread: ^thread.Thread,
	stop:   windows.HANDLE,
	app:    ^App,
}

@(private = "file") look_watch: Look_Watch

@(private = "file")
reg_dword :: proc(key, value: string) -> (u32, bool) {
	v: windows.DWORD
	size := windows.DWORD(size_of(v))
	err := windows.RegGetValueW(windows.HKEY_CURRENT_USER, windows.utf8_to_wstring(key), windows.utf8_to_wstring(value), windows.RRF_RT_REG_DWORD, nil, &v, &size)
	return u32(v), err == 0
}

// The platform's appearance, now.
read_os_appearance :: proc() -> style.Os_Appearance {
	a := style.Os_Appearance{known = true}
	if light, ok := reg_dword(LOOK_KEYS[0], "AppsUseLightTheme"); ok { a.dark = light == 0 }
	// accent: 0xAABBGGRR
	abgr, ok := reg_dword(LOOK_KEYS[1], "AccentColor")
	if !ok { abgr, ok = reg_dword(LOOK_KEYS[2], "AccentColorMenu") }
	if ok {
		a.has_accent = true
		c := css.Color{f32(abgr & 0xff) / 255, f32((abgr >> 8) & 0xff) / 255, f32((abgr >> 16) & 0xff) / 255, 1}
		a.accent = {.Light = c, .Dark = c}
	}
	// the shades Windows derives from it (UISettings: AccentLight3..AccentDark3, as RGBA): controls use Dark1 on light
	// surfaces and Light2 on dark ones
	palette: [32]u8
	size := windows.DWORD(len(palette))
	if windows.RegGetValueW(windows.HKEY_CURRENT_USER, windows.utf8_to_wstring(LOOK_KEYS[2]), windows.utf8_to_wstring("AccentPalette"), windows.RRF_RT_REG_BINARY, nil, &palette, &size) == 0 && size >= 28 {
		shade := proc(p: [32]u8, i: int) -> css.Color { return {f32(p[i * 4]) / 255, f32(p[i * 4 + 1]) / 255, f32(p[i * 4 + 2]) / 255, 1} }
		a.has_accent = true
		a.accent = {.Light = shade(palette, 4), .Dark = shade(palette, 1)}
	}
	bgr := proc(c: windows.DWORD) -> css.Color { return {f32(c & 0xff) / 255, f32((c >> 8) & 0xff) / 255, f32((c >> 16) & 0xff) / 255, 1} }
	a.has_highlight = true
	a.highlight = bgr(GetSysColor(windows.COLOR_HIGHLIGHT))
	a.highlight_text = bgr(GetSysColor(windows.COLOR_HIGHLIGHT + 1))   // COLOR_HIGHLIGHTTEXT
	return a
}

appearance_watch_start :: proc(app: ^App) {
	look_watch.app = app
	look_watch.stop = windows.CreateEventW(nil, true, false, nil)
	if look_watch.stop == nil { return }
	look_watch.thread = thread.create_and_start(look_watch_run)
}

appearance_watch_stop :: proc() {
	if look_watch.stop == nil { return }
	windows.SetEvent(look_watch.stop)
	if look_watch.thread != nil { thread.join(look_watch.thread); thread.destroy(look_watch.thread) }
	windows.CloseHandle(look_watch.stop)
	look_watch = {}
}

@(private = "file")
look_watch_run :: proc() {
	keys: [len(LOOK_KEYS)]windows.HKEY
	events: [len(LOOK_KEYS) + 1]windows.HANDLE
	events[0] = look_watch.stop
	defer for k, i in keys {
		if k != nil { windows.RegCloseKey(k) }
		if events[i + 1] != nil { windows.CloseHandle(events[i + 1]) }
	}
	FILTER :: windows.REG_NOTIFY_CHANGE_LAST_SET | windows.REG_NOTIFY_CHANGE_NAME
	arm :: proc(k: windows.HKEY, ev: windows.HANDLE) { RegNotifyChangeKeyValue(k, false, FILTER, ev, true) }
	for path, i in LOOK_KEYS {
		if windows.RegOpenKeyExW(windows.HKEY_CURRENT_USER, windows.utf8_to_wstring(path), 0, windows.KEY_NOTIFY, &keys[i]) != 0 { keys[i] = nil; continue }
		events[i + 1] = windows.CreateEventW(nil, false, false, nil)
		arm(keys[i], events[i + 1])
	}
	handles := make([dynamic]windows.HANDLE, 0, len(events), context.temp_allocator)
	slot := make([dynamic]int, 0, len(events), context.temp_allocator)
	append(&handles, events[0]); append(&slot, -1)
	for i in 0 ..< len(keys) { if keys[i] != nil && events[i + 1] != nil { append(&handles, events[i + 1]); append(&slot, i) } }
	for {
		r := windows.WaitForMultipleObjects(windows.DWORD(len(handles)), raw_data(handles), false, windows.INFINITE)
		idx := int(r - windows.WAIT_OBJECT_0)
		if idx <= 0 || idx >= len(handles) { return }   // stop, or a failure
		k := slot[idx]
		arm(keys[k], events[k + 1])   // notifications are one-shot
		appearance_post(look_watch.app)
	}
}
