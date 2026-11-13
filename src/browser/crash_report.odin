package browser

// Crash reports: the toolkit's gt:crash writes one in <profile>/crashes when the browser dies (each thread's stack, the modules,
// the preferences the user changed), and a minidump beside it on Windows. A session killed without a report becomes an "unclean"
// report at the next start (crash.begin_session). That start keeps the newest report (crash.last_report): the crash recovery bar
// opens it (crash_recovery.odin). Nothing is sent anywhere. wrentool crash-symbolize names a release's frames from its map.

import "core:strings"
import "core:sync"
import crash "toolkit:crash"

// What the [settings] section of a report can hold: the user's preferences file, cut there.
@(private = "file") CRASH_SETTINGS_BYTES :: 16 * 1024

// The user's preferences as their file last had them, for the crash handler, which may neither allocate nor take a lock (a torn
// copy while a write is under way only cuts the section).
@(private = "file")
crash_settings: struct {
	buf: [CRASH_SETTINGS_BYTES]u8,
	n:   int,   // (atomic)
}

// The handler, once for the process, with the profile's folder: before anything that can crash.
crash_report_install :: proc(app: ^App) {
	_ = crash.install({
		program = APP_NAME, version = APP_VERSION, commit = app_commit(),
		report_dir = strings.concatenate({app.profile_dir, "/crashes"}, context.temp_allocator),
		minidump = true,   // (Windows: WinDbg reads what the text cannot say)
		settings = {crash_settings_text, nil},
	})
}

// The session of the process starts; the report the last one left, if any, goes to the recovery bar of the App that starts it
// (app.recovery.report). On that App's thread, before its loop (both read and write the report folder).
crash_report_begin :: proc(app: ^App) {
	crash.begin_session()
	if path, ok := crash.last_report(); ok { app.recovery.report = path }
}

// The clean end of the session: the next start reports nothing for it.
crash_report_end :: proc() { crash.end_session() }

// The user's preferences file as it was last written (profile_prefs_save): what the next report's [settings] says.
crash_settings_keep :: proc(text: string) {
	n := copy(crash_settings.buf[:], text)
	sync.atomic_store(&crash_settings.n, n)
}

@(private = "file")
crash_settings_text :: proc "contextless" (user: rawptr, buf: []u8) -> int {
	n := sync.atomic_load(&crash_settings.n)
	return copy(buf, crash_settings.buf[:n])
}
