package desktop

// Watching the places an integration lives: the system tells the program when one of them changes, so that what shows
// the state reads it at that moment instead of on a timer. `wake` runs on the watcher's own thread and must only flag
// and wake the program's loop (never touch the integration itself).
//
// The platform files implement it: on Windows, the registry subtree the keys live in (RegNotifyChangeKeyValue) and the
// Start menu's Programs folder (FindFirstChangeNotificationW), on one named thread. A platform with no watcher returns
// nil from watch_start: the caller keeps a periodic check.

Watch_Proc :: proc(user: rawptr)

Watcher :: struct {
	user: rawptr,
	wake: Watch_Proc,
	impl: rawptr,   // the platform's own state (watch_windows.odin)
}

// Starts watching what `o` names. Nil when nothing could be watched (the platform has no watcher, a place could not be
// opened): the caller's periodic check stays.
watch_start :: proc(o: ^Options, wake: Watch_Proc, user: rawptr) -> ^Watcher {
	when ODIN_OS == .Windows { return watch_start_windows(o, wake, user) }
	return nil
}

watch_stop :: proc(w: ^Watcher) {
	if w == nil { return }
	when ODIN_OS == .Windows { watch_stop_windows(w) }
	free(w)
}
