package desktop

// Windows: one thread waits on three handles — the registry's change notification for HKCU\<registry_root> (the keys
// of the integration live under Software: Classes, Clients, RegisteredApplications), the Start menu's Programs folder,
// and the watcher's stop event. A change wakes the program, which reads the state again when it shows it.

import "core:strings"
import win "core:sys/windows"
import "wb:host"

foreign import kernel32_watch "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32_watch {
	// not in core:sys/windows
	RegNotifyChangeKeyValue :: proc(hKey: win.HKEY, bWatchSubtree: win.BOOL, dwNotifyFilter: u32, hEvent: win.HANDLE, fAsynchronous: win.BOOL) -> win.LSTATUS ---
}

Watch_State :: struct {
	subkey: string,       // owned: the registry root watched
	key:    win.HKEY,
	reg:    win.HANDLE,   // signalled by the registry
	dir:    win.HANDLE,   // the Programs folder's notification
	stop:   win.HANDLE,
	thread: ^host.Thread,
	wake:   Watch_Proc,
	user:   rawptr,
}

REG_FILTER :: win.REG_NOTIFY_CHANGE_NAME | win.REG_NOTIFY_CHANGE_LAST_SET
DIR_FILTER :: win.FILE_NOTIFY_CHANGE_FILE_NAME | win.FILE_NOTIFY_CHANGE_DIR_NAME | win.FILE_NOTIFY_CHANGE_LAST_WRITE

watch_start_windows :: proc(o: ^Options, wake: Watch_Proc, user: rawptr) -> ^Watcher {
	st := new(Watch_State)
	st.wake, st.user = wake, user
	st.subkey = strings.clone(o.registry_root != "" ? o.registry_root : "Software")

	if win.RegOpenKeyExW(win.HKEY_CURRENT_USER, win.utf8_to_wstring(st.subkey, context.temp_allocator), 0, win.KEY_NOTIFY, &st.key) != 0 {
		watch_state_free(st)
		return nil
	}
	st.reg = win.CreateEventW(nil, true, false, nil)
	st.stop = win.CreateEventW(nil, true, false, nil)
	if st.reg == nil || st.stop == nil {
		watch_state_free(st)
		return nil
	}
	if RegNotifyChangeKeyValue(st.key, true, REG_FILTER, st.reg, true) != 0 {
		watch_state_free(st)
		return nil
	}
	// the shortcut lives in the Programs folder; the folder itself may be missing (a fresh profile), which is no reason
	// not to watch the registry
	menu := o.menu_dir != "" ? o.menu_dir : programs_folder()
	if menu != "" {
		if h := win.FindFirstChangeNotificationW(cast([^]u16)win.utf8_to_wstring(menu, context.temp_allocator), false, DIR_FILTER); h != win.INVALID_HANDLE_VALUE {
			st.dir = h
		}
	}

	st.thread = host.thread_start(watch_thread, st, name = "wren-desktop-watch")
	if st.thread == nil {
		watch_state_free(st)
		return nil
	}
	w := new(Watcher)
	w.user, w.wake, w.impl = user, wake, st
	return w
}

@(private)
watch_thread :: proc(data: rawptr) {
	st := (^Watch_State)(data)
	handles: [3]win.HANDLE
	stop_i, reg_i, dir_i := 0, -1, -1
	handles[0] = st.stop
	n := 1
	if st.reg != nil { reg_i = n; handles[n] = st.reg; n += 1 }
	if st.dir != nil { dir_i = n; handles[n] = st.dir; n += 1 }

	for {
		r := win.WaitForMultipleObjects(u32(n), &handles[0], false, win.INFINITE)
		if r == win.WAIT_FAILED { return }
		i := int(r - win.WAIT_OBJECT_0)
		if i == stop_i { return }
		if i == reg_i {
			win.ResetEvent(st.reg)
			if RegNotifyChangeKeyValue(st.key, true, REG_FILTER, st.reg, true) != 0 { return }
		} else if i == dir_i {
			if !win.FindNextChangeNotification(st.dir) { return }
		}
		st.wake(st.user)
	}
}

watch_stop_windows :: proc(w: ^Watcher) {
	st := (^Watch_State)(w.impl)
	if st == nil { return }
	if st.stop != nil { win.SetEvent(st.stop) }
	if st.thread != nil { host.thread_join(st.thread) }
	watch_state_free(st)
	w.impl = nil
}

@(private)
watch_state_free :: proc(st: ^Watch_State) {
	if st.dir != nil && st.dir != win.INVALID_HANDLE_VALUE { win.FindCloseChangeNotification(st.dir) }
	if st.reg != nil { win.CloseHandle(st.reg) }
	if st.stop != nil { win.CloseHandle(st.stop) }
	if st.key != nil { win.RegCloseKey(st.key) }
	delete(st.subkey)
	free(st)
}
