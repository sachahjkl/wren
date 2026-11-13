package browser

// The browser's side of the profile's writer (host.File_Writer, src/host/profile_file.odin, which says how every profile file
// is written): App.writer, how a failed write is told to the user, and the files whose text the shell makes.
//   * The cookies and the HSTS hosts (profile_stores_save) are copied on the loop thread and written by one job.
// The text of a file is made on the loop thread (it reads the App), by its owner, only when what it holds changed.

import "core:fmt"
import "core:strings"
import "wb:config"
import "wb:cookies"
import "wb:fetch"
import "wb:host"

// Sets App.writer up (app_pools_init): its failures are told in a toast while a window exists.
profile_writer_init :: proc(app: ^App) {
	host.file_writer_init(&app.writer, &app.loop, &app.blocking, profile_tell, app)
}

@(private = "file")
profile_tell :: proc(user: rawptr, name: string) -> bool {
	app := (^App)(user)
	if !profile_can_tell(app) { return false }
	announce(app, .Bad, fmt.tprintf("Could not save %s in the profile. Wren tries again.", name))
	return true
}

// Whether a failure can be told in a toast: the toolkit's interface exists while a window does (unit tests have none).
profile_can_tell :: proc(app: ^App) -> bool { return app != nil && len(app.windows) > 0 }

// Whether jobs can go to the blocking pool: it runs, and is not stopping.
profile_pool_ready :: proc(app: ^App) -> bool { return app != nil && host.writer_pool_ready(&app.writer) }

////////////////////////////////
// The session's files, the cookies and HSTS

// What profile_save writes besides the preferences (Recovery.writes: with the session's snapshot, the other session files).
Profile_Writes :: struct {
	session:        host.Profile_File,   // session.txt
	pinned:         host.Profile_File,   // pinned.txt
	session_serial: u64,            // bumped by recovery_touch: what the session file holds changed
	session_made:   u64,            // the serial the last text of session.txt was made at
	pinned_last:    string,         // owned: what pinned.txt holds, or will ("": no file)
	pinned_known:   bool,           // pinned_last is known (else the next save writes it once)
	stores_busy:    bool,           // the write of the cookies and the HSTS hosts is out
	prefs:          host.Profile_File,   // prefs.txt
	prefs_written:  u64,            // the prefs' user_version the last text of prefs.txt was made at
	cookies:        host.Write_Health,
	hsts:           host.Write_Health,
}

// At exit, before the last profile_save (profile_save with `force`): every file of the profile still waiting, of the shell
// and of the pages, is written, and so is every later text, on this thread.
profile_files_flush :: proc(app: ^App) { host.file_writer_flush(&app.writer) }

profile_writes_destroy :: proc(w: ^Profile_Writes) {
	host.profile_file_destroy(&w.prefs)
	host.profile_file_destroy(&w.session)
	host.profile_file_destroy(&w.pinned)
	delete(w.pinned_last)
	w^ = {}
}

// The preferences, when the user's layer changed since the last text (profile_save): the text is made here, on the loop
// thread that owns the registry, and the blocking pool writes it like any other profile file, so a slow disk never holds
// the interface. A change made while it is written moves user_version again: the next save has it. A failed write is
// tried again by the Profile_File, and at exit (profile_files_flush) what waits is written before the end.
profile_prefs_save :: proc(app: ^App, path: string) {
	w := &app.recovery.writes
	host.profile_file_init(&w.prefs, &app.writer, path, flush = true)
	if app.prefs.user_version == w.prefs_written { return }
	w.prefs_written = app.prefs.user_version
	text := config.export(&app.prefs, .Own, allocator = context.temp_allocator)
	crash_settings_keep(text)   // crash_report.odin: what a report says of the settings
	host.profile_file_write(&w.prefs, text)
}

@(private = "file")
Stores_Job :: struct {
	app:          ^App,
	cookie_path:  string,           // owned
	hsts_path:    string,           // owned
	now_ms:       i64,
	jar:          []cookies.Cookie, // a copy (cookies.copy_all)
	has_cookies:  bool,
	cookies_ok:   bool,
	hsts:         fetch.Hsts,       // a copy
	has_hsts:     bool,
	hsts_ok:      bool,
}

// The cookies and the HSTS hosts, when they changed (profile_save). With `force` (at exit, after profile_files_flush:
// the writer is closing) written here and now;
// otherwise copied here and written by the blocking pool, one write at a time.
profile_stores_save :: proc(app: ^App, cookie_path, hsts_path: string, force: bool) {
	if !app.cfg.persist_profile { return }
	w := &app.recovery.writes
	jar, hs := &app.profile.jar, &app.profile.hsts
	if force {
		for _ in 0 ..< host.FILE_FLUSH_ROUNDS {
			if !w.stores_busy { break }
			host.blocking_settle(&app.blocking)
		}
		now := fetch.now_ms()
		cookies_ok := host.file_put(&app.writer, cookie_path, transmute([]byte)cookies.serialize(jar, now, context.temp_allocator))
		if cookies_ok { jar.dirty = false }
		host.file_write_report(&app.writer, &w.cookies, cookie_path, cookies_ok, tell = false)
		hsts_ok := host.file_put(&app.writer, hsts_path, transmute([]byte)fetch.hsts_serialize(hs, now, context.temp_allocator))
		if hsts_ok { hs.dirty = false }
		host.file_write_report(&app.writer, &w.hsts, hsts_path, hsts_ok, tell = false)
		return
	}
	if w.stores_busy || (!jar.dirty && !hs.dirty) { return }
	job := new(Stores_Job)
	job.app, job.now_ms = app, fetch.now_ms()
	job.cookie_path, job.hsts_path = strings.clone(cookie_path), strings.clone(hsts_path)
	if jar.dirty {
		job.jar, job.has_cookies = cookies.copy_all(jar), true
		jar.dirty = false   // (a failed write sets it again)
	}
	if hs.dirty {
		job.hsts, job.has_hsts = fetch.hsts_make(), true
		for k, e in hs.hosts { job.hsts.hosts[strings.clone(k, job.hsts.allocator)] = e }
		hs.dirty = false
	}
	if !profile_pool_ready(app) {
		stores_work(job)
		stores_done(job)
		return
	}
	w.stores_busy = true
	host.run_blocking(&app.blocking, stores_work, stores_done, job, stores_discard)
}

@(private = "file")
stores_work :: proc(data: rawptr) {
	j := (^Stores_Job)(data)
	if j.has_cookies {
		// a jar of the copied cookies, only for cookies.serialize to read them (it reads nothing else of it)
		tmp: cookies.Jar
		tmp.cookies = make([dynamic]cookies.Cookie, 0, len(j.jar))
		append(&tmp.cookies, ..j.jar)
		j.cookies_ok = host.file_put(&j.app.writer, j.cookie_path, transmute([]byte)cookies.serialize(&tmp, j.now_ms, context.temp_allocator))
		delete(tmp.cookies)
	}
	if j.has_hsts {
		j.hsts_ok = host.file_put(&j.app.writer, j.hsts_path, transmute([]byte)fetch.hsts_serialize(&j.hsts, j.now_ms, context.temp_allocator))
	}
}

// The pool ended before the job started: what it copied is left to the save at exit.
@(private = "file")
stores_discard :: proc(data: rawptr) {
	j := (^Stores_Job)(data)
	app := j.app
	app.recovery.writes.stores_busy = false
	if j.has_cookies { app.profile.jar.dirty = true; cookies.copy_destroy(j.jar) }
	if j.has_hsts { app.profile.hsts.dirty = true; fetch.hsts_destroy(&j.hsts) }
	delete(j.cookie_path)
	delete(j.hsts_path)
	free(j)
}

@(private = "file")
stores_done :: proc(data: rawptr) {
	j := (^Stores_Job)(data)
	app := j.app
	w := &app.recovery.writes
	host.quiet_note(&app.loop)
	w.stores_busy = false
	if j.has_cookies {
		if !j.cookies_ok { app.profile.jar.dirty = true }   // (the next autosave tries again)
		host.file_write_report(&app.writer, &w.cookies, j.cookie_path, j.cookies_ok)
		cookies.copy_destroy(j.jar)
	}
	if j.has_hsts {
		if !j.hsts_ok { app.profile.hsts.dirty = true }
		host.file_write_report(&app.writer, &w.hsts, j.hsts_path, j.hsts_ok)
		fetch.hsts_destroy(&j.hsts)
	}
	delete(j.cookie_path)
	delete(j.hsts_path)
	free(j)
}
