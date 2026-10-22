package desktop

// Windows: one thread waits on the change notifications of every place an integration lives, and on the watcher's stop
// event: the registry subtree HKCU\<registry_root> (the keys of the integration live under Software: Classes, Clients,
// RegisteredApplications, the Uninstall entry), the user's environment key (the PATH entry), the Start menu's Programs
// folder and the Desktop folder (the two shortcuts). A change wakes the program, which reads the state again when it
// shows it.

import win "core:sys/windows"
import "wb:host"

foreign import kernel32_watch "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32_watch {
	// not in core:sys/windows
	RegNotifyChangeKeyValue :: proc(hKey: win.HKEY, bWatchSubtree: win.BOOL, dwNotifyFilter: u32, hEvent: win.HANDLE, fAsynchronous: win.BOOL) -> win.LSTATUS ---
}

WATCH_KEYS  :: 2   // the registry subtree, the environment key
WATCH_DIRS  :: 2   // the Programs folder, the Desktop folder

Watch_Key :: struct {
	key:     win.HKEY,
	event:   win.HANDLE,   // signalled by the registry
	subtree: bool,
}

Watch_State :: struct {
	keys:   [WATCH_KEYS]Watch_Key,
	dirs:   [WATCH_DIRS]win.HANDLE,   // the folders' notifications (nil: not watched)
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
	st.stop = win.CreateEventW(nil, true, false, nil)
	if st.stop == nil {
		watch_state_free(st)
		return nil
	}

	// the registry subtree is the one that must be watched: without it there is nothing to follow (the others may be
	// missing, a fresh profile has no Desktop key... and that is no reason not to watch the rest)
	if !watch_key_open(&st.keys[0], registry_root_of(o), true) {
		watch_state_free(st)
		return nil
	}
	_ = watch_key_open(&st.keys[1], env_key(o), false)

	// the shortcuts live in the Programs folder and the Desktop folder; either may be missing
	menu := o.menu_dir != "" ? o.menu_dir : programs_folder()
	st.dirs[0] = watch_dir_open(menu)
	desktop := o.desktop_dir != "" ? o.desktop_dir : known_folder(win.FOLDERID_Desktop)
	st.dirs[1] = watch_dir_open(desktop)

	st.thread = host.thread_start(watch_thread, st, name = "wren-desktop-watch")
	if st.thread == nil {
		watch_state_free(st)
		return nil
	}
	w := new(Watcher)
	w.user, w.wake, w.impl = user, wake, st
	return w
}

@(private = "file")
watch_key_open :: proc(k: ^Watch_Key, subkey: string, subtree: bool) -> bool {
	k.subtree = subtree
	if win.RegOpenKeyExW(win.HKEY_CURRENT_USER, win.utf8_to_wstring(subkey, context.temp_allocator), 0, win.KEY_NOTIFY, &k.key) != 0 {
		k.key = nil
		return false
	}
	k.event = win.CreateEventW(nil, true, false, nil)
	if k.event == nil || RegNotifyChangeKeyValue(k.key, win.BOOL(subtree), REG_FILTER, k.event, true) != 0 {
		watch_key_close(k)
		return false
	}
	return true
}

@(private = "file")
watch_key_close :: proc(k: ^Watch_Key) {
	if k.event != nil { win.CloseHandle(k.event) }
	if k.key != nil { win.RegCloseKey(k.key) }
	k^ = {}
}

@(private = "file")
watch_dir_open :: proc(dir: string) -> win.HANDLE {
	if dir == "" { return nil }
	h := win.FindFirstChangeNotificationW(cast([^]u16)win.utf8_to_wstring(dir, context.temp_allocator), false, DIR_FILTER)
	return h == win.INVALID_HANDLE_VALUE ? nil : h
}

@(private)
watch_thread :: proc(data: rawptr) {
	st := (^Watch_State)(data)
	handles: [1 + WATCH_KEYS + WATCH_DIRS]win.HANDLE
	// what each handle is: the stop event, a key (index into keys), a folder (index into dirs)
	Kind :: enum { Stop, Key, Dir }
	kinds: [len(handles)]Kind
	slots: [len(handles)]int
	n := 1
	handles[0] = st.stop
	for k, i in st.keys { if k.event != nil { handles[n], kinds[n], slots[n] = k.event, .Key, i; n += 1 } }
	for d, i in st.dirs { if d != nil { handles[n], kinds[n], slots[n] = d, .Dir, i; n += 1 } }

	for {
		r := win.WaitForMultipleObjects(u32(n), &handles[0], false, win.INFINITE)
		if r == win.WAIT_FAILED { return }
		i := int(r - win.WAIT_OBJECT_0)
		if i < 0 || i >= n { return }
		switch kinds[i] {
		case .Stop: return
		case .Key:
			k := &st.keys[slots[i]]
			win.ResetEvent(k.event)
			if RegNotifyChangeKeyValue(k.key, win.BOOL(k.subtree), REG_FILTER, k.event, true) != 0 { return }
		case .Dir:
			if !win.FindNextChangeNotification(st.dirs[slots[i]]) { return }
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

@(private = "file")
watch_state_free :: proc(st: ^Watch_State) {
	for d in st.dirs { if d != nil { win.FindCloseChangeNotification(d) } }
	for &k in st.keys { watch_key_close(&k) }
	if st.stop != nil { win.CloseHandle(st.stop) }
	free(st)
}
