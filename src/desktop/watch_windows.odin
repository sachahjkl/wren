package desktop

// Windows: one thread waits on the change notifications of every place an integration lives, and on the watcher's stop
// event: the registry subtree HKCU\<registry_root> (the keys of the integration live under Software: Classes, Clients,
// RegisteredApplications, the Uninstall entry), the user's environment key (the PATH entry), the Start menu's Programs
// folder, the Desktop folder (the two shortcuts) and the install folder (a reinstall, a repair, a file removed, an
// uninstall of the installed copy by another Wren). A change wakes the program, which reads the state again when it
// shows it.
//
// A place that disappears (its key or folder is deleted: that is a change too) cannot be waited on any more: the thread
// lets it go, wakes the program, and tries to open it again every few seconds, so that it is watched again when it comes
// back (the first Start menu shortcut of a fresh profile creates the folder). The watcher never ends because one place
// did.

import "core:strings"
import win "core:sys/windows"
import "wb:host"

foreign import kernel32_watch "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32_watch {
	// not in core:sys/windows
	RegNotifyChangeKeyValue :: proc(hKey: win.HKEY, bWatchSubtree: win.BOOL, dwNotifyFilter: u32, hEvent: win.HANDLE, fAsynchronous: win.BOOL) -> win.LSTATUS ---
}

WATCH_KEYS :: 2   // the registry subtree, the environment key
WATCH_DIRS :: 3   // the Programs folder, the Desktop folder, the install folder
WATCH_RETRY_MS :: 3000

Watch_Key :: struct {
	path:    string,      // under HKCU (owned)
	subtree: bool,
	key:     win.HKEY,    // nil: not open now
	event:   win.HANDLE,  // signalled by the registry
}

Watch_Dir :: struct {
	path:   string,       // owned ("" = nothing to watch: the folder is unknown)
	handle: win.HANDLE,   // nil: not open now
}

Watch_State :: struct {
	keys:   [WATCH_KEYS]Watch_Key,
	dirs:   [WATCH_DIRS]Watch_Dir,
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
	st.keys[0] = {path = strings.clone(registry_root_of(o)), subtree = true}
	st.keys[1] = {path = strings.clone(env_key(o))}
	menu := o.menu_dir != "" ? o.menu_dir : programs_folder()
	desktop := o.desktop_dir != "" ? o.desktop_dir : known_folder(win.FOLDERID_Desktop)
	st.dirs[0].path = strings.clone(menu)
	st.dirs[1].path = strings.clone(desktop)
	// the install folder: where the copy is recorded, else the default. A fresh profile has none yet; the thread opens it
	// when it comes (watch_dir_open retries), so a first install starts being followed too.
	st.dirs[2].path = strings.clone(install_target(o, context.temp_allocator))

	// the registry subtree is the one that must exist now: without it there is nothing to follow. The others may be
	// missing (a fresh profile has no Desktop key...): they are tried again by the thread
	if !watch_key_open(&st.keys[0]) {
		watch_state_free(st)
		return nil
	}
	_ = watch_key_open(&st.keys[1])
	for &d in st.dirs { _ = watch_dir_open(&d) }

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
watch_key_open :: proc(k: ^Watch_Key) -> bool {
	if k.key != nil { return true }
	if win.RegOpenKeyExW(win.HKEY_CURRENT_USER, win.utf8_to_wstring(k.path, context.temp_allocator), 0, win.KEY_NOTIFY, &k.key) != 0 {
		k.key = nil
		return false
	}
	if k.event == nil { k.event = win.CreateEventW(nil, true, false, nil) }
	win.ResetEvent(k.event)
	if k.event == nil || RegNotifyChangeKeyValue(k.key, win.BOOL(k.subtree), REG_FILTER, k.event, true) != 0 {
		watch_key_close(k)
		return false
	}
	return true
}

// Lets go of the key (the event stays for the next open).
@(private = "file")
watch_key_close :: proc(k: ^Watch_Key) {
	if k.key != nil { win.RegCloseKey(k.key) }
	k.key = nil
}

@(private = "file")
watch_dir_open :: proc(d: ^Watch_Dir) -> bool {
	if d.handle != nil { return true }
	if d.path == "" { return false }
	h := win.FindFirstChangeNotificationW(cast([^]u16)win.utf8_to_wstring(d.path, context.temp_allocator), false, DIR_FILTER)
	if h == win.INVALID_HANDLE_VALUE { return false }
	d.handle = h
	return true
}

@(private = "file")
watch_dir_close :: proc(d: ^Watch_Dir) {
	if d.handle != nil { win.FindCloseChangeNotification(d.handle) }
	d.handle = nil
}

@(private)
watch_thread :: proc(data: rawptr) {
	st := (^Watch_State)(data)
	Kind :: enum { Stop, Key, Dir }
	handles: [1 + WATCH_KEYS + WATCH_DIRS]win.HANDLE
	kinds: [len(handles)]Kind
	slots: [len(handles)]int

	for {
		// what is open now (rebuilt: a place may have gone, or come back)
		n := 1
		handles[0] = st.stop
		missing := false
		for k, i in st.keys {
			if k.key != nil { handles[n], kinds[n], slots[n] = k.event, .Key, i; n += 1 } else { missing = true }
		}
		for d, i in st.dirs {
			if d.handle != nil { handles[n], kinds[n], slots[n] = d.handle, .Dir, i; n += 1 } else if d.path != "" { missing = true }
		}

		r := win.WaitForMultipleObjects(u32(n), &handles[0], false, missing ? WATCH_RETRY_MS : win.INFINITE)
		if r == win.WAIT_FAILED { return }
		if r == win.WAIT_TIMEOUT {
			// a place that was gone: watched again if it is back (which is a change)
			back := false
			for &k in st.keys { if k.key == nil && watch_key_open(&k) { back = true } }
			for &d in st.dirs { if d.handle == nil && watch_dir_open(&d) { back = true } }
			if back { st.wake(st.user) }
			continue
		}
		i := int(r - win.WAIT_OBJECT_0)
		if i < 0 || i >= n { return }
		switch kinds[i] {
		case .Stop: return
		case .Key:
			k := &st.keys[slots[i]]
			win.ResetEvent(k.event)
			if RegNotifyChangeKeyValue(k.key, win.BOOL(k.subtree), REG_FILTER, k.event, true) != 0 { watch_key_close(k) }   // (deleted)
		case .Dir:
			d := &st.dirs[slots[i]]
			if !win.FindNextChangeNotification(d.handle) { watch_dir_close(d) }   // (deleted)
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
	for &d in st.dirs { watch_dir_close(&d); delete(d.path) }
	for &k in st.keys {
		watch_key_close(&k)
		if k.event != nil { win.CloseHandle(k.event) }
		delete(k.path)
	}
	if st.stop != nil { win.CloseHandle(st.stop) }
	free(st)
}
