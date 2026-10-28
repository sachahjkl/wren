package browser

// Windows services the form shell asks the system for (forms_shell.odin has the neutral callers): the MIME type of a
// file from the registry, the common colour dialog for <input type=color>, and the caret-blink and double-click times.
// The Linux counterpart is forms_shell_other.odin.

import "core:strings"
import win "core:sys/windows"
import "toolkit:platform"

foreign import user32_fs "system:User32.lib"

@(default_calling_convention = "system", private = "file")
foreign user32_fs {
	GetCaretBlinkTime :: proc() -> u32 ---
	GetDoubleClickTime :: proc() -> u32 ---
}

// The MIME type for a file from the registry (HKCR\.ext "Content Type"), or "" when the system does not know it.
system_mime_of_path :: proc(path: string) -> string {
	dot := strings.last_index_byte(path, '.')
	slash := strings.last_index_any(path, "\\/")
	if dot > slash && dot >= 0 {
		ext := win.utf8_to_wstring(path[dot:], context.temp_allocator)
		buf: [128]u16
		size := u32(size_of(buf))
		if win.RegGetValueW(win.HKEY_CLASSES_ROOT, ext, win.L("Content Type"), win.RRF_RT_REG_SZ, nil, &buf, &size) == 0 {
			n := 0
			for n < len(buf) && buf[n] != 0 { n += 1 }
			if s, err := win.utf16_to_utf8(buf[:n], context.temp_allocator); err == nil && s != "" { return strings.clone(s) }
		}
	}
	return ""
}

// The system colour picker (the common colour dialog). `initial` / the result are 0x00BBGGRR (COLORREF). Runs on a
// worker thread (it blocks until the user answers), so it initialises COM for this thread.
system_pick_color :: proc(owner: ^platform.Window, initial: u32) -> (result: u32, ok: bool) {
	_ = win.CoInitializeEx(nil, .APARTMENTTHREADED)
	defer win.CoUninitialize()
	custom: [16]win.COLORREF
	hwnd := owner != nil ? owner.hwnd : nil
	cc := win.CHOOSECOLORW{lStructSize = size_of(win.CHOOSECOLORW), hwndOwner = hwnd, rgbResult = win.COLORREF(initial), lpCustColors = &custom[0], Flags = win.CC_RGBINIT | win.CC_FULLOPEN}
	if win.ChooseColorW(&cc) { return u32(cc.rgbResult), true }
	return 0, false
}

system_caret_blink_ms :: proc() -> int {
	sys := GetCaretBlinkTime()
	if sys == 0xFFFFFFFF { return -1 }   // INFINITE: the user turned blinking off
	return int(max(sys, 100))
}

system_double_click_ms :: proc() -> f64 { return f64(GetDoubleClickTime()) }
