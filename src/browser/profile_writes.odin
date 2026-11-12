package browser

// The profile's files written off the interface thread, and what a failed write does, in one place for every file:
//   * A Profile_File is rewritten whole (base.file_write_atomic: a temporary file renamed over the old one) by a worker of
//     the blocking pool, one write at a time. A text given while a write runs waits; only the newest one waits.
//   * A failed write is logged with the file's path and made again later, each time twice as late (PROFILE_RETRY_FIRST_MS
//     up to PROFILE_RETRY_LAST_MS). The user is told once, until a write of that file works again (profile_write_report,
//     which the history's own writes use too).
//   * At exit (profile_file_flush) the write that runs finishes, the text that waits is written on the loop thread, and so
//     is every later text: the blocking pool stops soon after.
//   * Without a blocking pool (unit tests, tools) every text is written on the calling thread.
//   * The cookies and the HSTS hosts (profile_stores_save) are copied on the loop thread and written by one job.
// The text of a file is made on the loop thread (it reads the App), by its owner, only when what it holds changed.

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:cookies"
import "wb:fetch"
import "wb:host"

PROFILE_RETRY_FIRST_MS :: 2000
PROFILE_RETRY_LAST_MS :: 5 * 60 * 1000
// How many rounds of the blocking pool the exit waits for a write that runs (each round waits for the whole pool).
@(private = "file") PROFILE_FLUSH_ROUNDS :: 50

// How long after the `failures`-th failure in a row the next try comes (pure: profile_writes_test.odin).
profile_retry_ms :: proc(failures: int) -> int {
	ms := PROFILE_RETRY_FIRST_MS
	for _ in 1 ..< max(failures, 1) {
		ms *= 2
		if ms >= PROFILE_RETRY_LAST_MS { return PROFILE_RETRY_LAST_MS }
	}
	return ms
}

// The failures of one file's writes.
Write_Health :: struct {
	failures: int,    // writes failed in a row
	warned:   bool,   // the user was told of this streak
}

// After a write of `path` (loop thread): a failure is logged and told to the user once per streak (`tell` false: logged
// only, as at exit when no window may be left). Returns when to try again (0: it worked).
profile_write_report :: proc(h: ^Write_Health, path: string, ok: bool, tell := true) -> (retry_ms: int) {
	if ok {
		if h.failures > 0 { log.infof("profile: %s written again after %d failed writes", path, h.failures) }
		h^ = {}
		return 0
	}
	h.failures += 1
	// (base.file_write_atomic says only that it failed: the system's reason is not kept)
	log.warnf("profile: cannot write %s (%d failed writes in a row)", path, h.failures)
	if tell && !h.warned {
		h.warned = true
		ui.toast(.Bad, "Could not save %s in the profile. Wren tries again.", filepath.base(path))
	}
	return profile_retry_ms(h.failures)
}

// Whether a failure can be told in a toast: the toolkit's interface exists while a window does (unit tests have none).
profile_can_tell :: proc(app: ^App) -> bool { return app != nil && len(app.windows) > 0 }

// Whether jobs can go to the blocking pool: it runs, and is not stopping.
profile_pool_ready :: proc(app: ^App) -> bool {
	return app != nil && len(app.blocking.threads) > 0 && !app.blocking.stopping
}

////////////////////////////////
// A file rewritten whole in the background

Profile_File :: struct {
	app:     ^App,
	path:    string,        // owned ("": not set up, nothing is written)
	flush:   bool,          // on the disk before the rename (fsync)
	busy:    bool,          // a write is out on the blocking pool
	next:    string,        // owned: the newest text not handed to a write
	waiting: bool,          // `next` is to be written
	remove:  bool,          // ... or rather the file removed
	health:  Write_Health,
	retry:   base.Handle,   // the timer of the next try after a failure
	closing: bool,          // profile_file_flush ran: texts are written on the loop thread
}

// Sets the file up (once: a second call keeps the first path).
profile_file_init :: proc(f: ^Profile_File, app: ^App, path: string, flush := false) {
	if f.path != "" { return }
	f.app, f.flush = app, flush
	f.path = strings.clone(path)
}

// The file is to hold `text` (copied).
profile_file_write :: proc(f: ^Profile_File, text: string) { profile_file_put(f, text, false) }

// The file is to go.
profile_file_remove :: proc(f: ^Profile_File) { profile_file_put(f, "", true) }

@(private = "file")
profile_file_put :: proc(f: ^Profile_File, text: string, remove: bool) {
	if f.path == "" { return }
	delete(f.next)
	f.next, f.remove, f.waiting = strings.clone(text), remove, true
	profile_file_kick(f)
}

@(private = "file")
File_Write_Job :: struct {
	file:   ^Profile_File,
	path:   string,   // owned
	text:   string,   // owned
	remove: bool,
	flush:  bool,
	ok:     bool,
}

@(private = "file")
file_write_work :: proc(data: rawptr) {
	j := (^File_Write_Job)(data)
	j.ok = profile_file_apply(j.path, j.text, j.remove, j.flush)
}

// What a write does (any thread).
@(private = "file")
profile_file_apply :: proc(path, text: string, remove, flush: bool) -> bool {
	if remove { return os.remove(path) == nil || !os.exists(path) }
	return base.file_write_atomic(path, transmute([]byte)text, flush = flush)
}

// Hands the text that waits to a write, when none runs and no retry is pending.
@(private = "file")
profile_file_kick :: proc(f: ^Profile_File) {
	if !f.waiting || f.busy || f.retry != base.NIL_HANDLE { return }
	text, remove := f.next, f.remove
	f.next, f.waiting, f.remove = "", false, false
	if f.closing || !profile_pool_ready(f.app) {
		ok := profile_file_apply(f.path, text, remove, f.flush)
		profile_write_report(&f.health, f.path, ok, tell = !f.closing && profile_can_tell(f.app))
		delete(text)
		return
	}
	job := new(File_Write_Job)
	job^ = {file = f, path = strings.clone(f.path), text = text, remove = remove, flush = f.flush}
	f.busy = true
	host.run_blocking(&f.app.blocking, file_write_work, file_write_done, job)
}

@(private = "file")
file_write_done :: proc(data: rawptr) {
	j := (^File_Write_Job)(data)
	f := j.file
	defer { delete(j.path); free(j) }
	host.quiet_note(&f.app.loop)   // (the disk, not the screen)
	f.busy = false
	retry := profile_write_report(&f.health, f.path, j.ok, tell = profile_can_tell(f.app))
	if j.ok {
		delete(j.text)
		profile_file_kick(f)
		return
	}
	// what failed is written again, unless a newer text came meanwhile; either way not before the delay
	if f.waiting { delete(j.text) } else { f.next, f.remove, f.waiting = j.text, j.remove, true }
	if f.closing { profile_file_kick(f); return }
	f.retry = host.set_timer(&f.app.loop, f64(retry), 0, proc(data: rawptr) {
		f := (^Profile_File)(data)
		f.retry = base.NIL_HANDLE
		host.quiet_note(&f.app.loop)
		profile_file_kick(f)
	}, f)
}

// At exit (loop thread): the write that runs finishes, what waits is written now, and later texts are written at once.
profile_file_flush :: proc(f: ^Profile_File) {
	f.closing = true   // (also for a file set up later: a write queued now could be dropped by the pool's end)
	if f.path == "" { return }
	if f.retry != base.NIL_HANDLE { host.clear_timer(&f.app.loop, f.retry); f.retry = base.NIL_HANDLE }
	for _ in 0 ..< PROFILE_FLUSH_ROUNDS {
		if !f.busy { break }
		host.blocking_settle(&f.app.blocking)
	}
	profile_file_kick(f)
}

// Frees what the file holds, after profile_file_flush (no write out, no retry timer: this may run after the loop ended).
profile_file_destroy :: proc(f: ^Profile_File) {
	delete(f.path)
	delete(f.next)
	f^ = {}
}

////////////////////////////////
// The session's files, the cookies and HSTS

// What profile_save writes besides the preferences (Recovery.writes: with the session's snapshot, the other session files).
Profile_Writes :: struct {
	session:        Profile_File,   // session.txt
	pinned:         Profile_File,   // pinned.txt
	session_serial: u64,            // bumped by recovery_touch: what the session file holds changed
	session_made:   u64,            // the serial the last text of session.txt was made at
	pinned_last:    string,         // owned: what pinned.txt holds, or will ("": no file)
	pinned_known:   bool,           // pinned_last is known (else the next save writes it once)
	stores_busy:    bool,           // the write of the cookies and the HSTS hosts is out
	prefs:          Profile_File,   // prefs.txt
	prefs_written:  u64,            // the prefs' user_version the last text of prefs.txt was made at
	cookies:        Write_Health,
	hsts:           Write_Health,
}

// At exit, after the last profile_save: every file of the profile still waiting is written (profile_save with `force`).
profile_files_flush :: proc(app: ^App) {
	w := &app.recovery.writes
	profile_file_flush(&w.prefs)
	profile_file_flush(&w.session)
	profile_file_flush(&w.pinned)
	profile_file_flush(&app.closed.file)
	profile_file_flush(&app.dls.file)
	profile_file_flush(&app.cpal.usage_file)
}

profile_writes_destroy :: proc(w: ^Profile_Writes) {
	profile_file_destroy(&w.prefs)
	profile_file_destroy(&w.session)
	profile_file_destroy(&w.pinned)
	delete(w.pinned_last)
	w^ = {}
}

// The preferences, when the user's layer changed since the last text (profile_save): the text is made here, on the loop
// thread that owns the registry, and the blocking pool writes it like any other profile file, so a slow disk never holds
// the interface. A change made while it is written moves user_version again: the next save has it. A failed write is
// tried again by the Profile_File, and at exit (profile_files_flush) what waits is written before the end.
profile_prefs_save :: proc(app: ^App, path: string) {
	w := &app.recovery.writes
	profile_file_init(&w.prefs, app, path, flush = true)
	if app.prefs.user_version == w.prefs_written { return }
	w.prefs_written = app.prefs.user_version
	profile_file_write(&w.prefs, config.serialize_user(&app.prefs, context.temp_allocator))
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

// The cookies and the HSTS hosts, when they changed (profile_save). With `force` (at exit) written here and now;
// otherwise copied here and written by the blocking pool, one write at a time.
profile_stores_save :: proc(app: ^App, cookie_path, hsts_path: string, force: bool) {
	if !app.cfg.persist_profile { return }
	w := &app.recovery.writes
	jar, hs := &app.profile.jar, &app.profile.hsts
	if force {
		for _ in 0 ..< PROFILE_FLUSH_ROUNDS {
			if !w.stores_busy { break }
			host.blocking_settle(&app.blocking)
		}
		profile_write_report(&w.cookies, cookie_path, cookies.save(jar, cookie_path), tell = false)
		profile_write_report(&w.hsts, hsts_path, fetch.hsts_save(hs, hsts_path, fetch.now_ms()), tell = false)
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
	host.run_blocking(&app.blocking, stores_work, stores_done, job)
}

@(private = "file")
stores_work :: proc(data: rawptr) {
	j := (^Stores_Job)(data)
	if j.has_cookies {
		// a jar of the copied cookies, only for cookies.save to write them (it reads nothing else of it)
		tmp: cookies.Jar
		tmp.cookies = make([dynamic]cookies.Cookie, 0, len(j.jar))
		append(&tmp.cookies, ..j.jar)
		j.cookies_ok = cookies.save(&tmp, j.cookie_path, j.now_ms)
		delete(tmp.cookies)
	}
	if j.has_hsts { j.hsts_ok = fetch.hsts_save(&j.hsts, j.hsts_path, j.now_ms) }
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
		profile_write_report(&w.cookies, j.cookie_path, j.cookies_ok, tell = profile_can_tell(app))
		cookies.copy_destroy(j.jar)
	}
	if j.has_hsts {
		if !j.hsts_ok { app.profile.hsts.dirty = true }
		profile_write_report(&w.hsts, j.hsts_path, j.hsts_ok, tell = profile_can_tell(app))
		fetch.hsts_destroy(&j.hsts)
	}
	delete(j.cookie_path)
	delete(j.hsts_path)
	free(j)
}
