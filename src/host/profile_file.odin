package host

// The profile's files, written off the interface thread, and what a failed write does, in one place for every package:
//   * A Profile_File is rewritten whole (base.file_write_atomic: a temporary file renamed over the old one) by a worker of
//     the blocking pool, one write at a time. A text given while a write runs waits; only the newest one waits.
//   * A failed write is logged with the file's path and made again later, each time twice as late (FILE_RETRY_FIRST_MS up
//     to FILE_RETRY_LAST_MS). The writer's `tell` tells the user once, until a write of that file works again
//     (file_write_report, which the owners of their own jobs use too).
//   * At exit (file_writer_flush) the writes that run finish, the texts that wait are written on the loop thread, and so is
//     every later text: the blocking pool stops soon after.
//   * Without a blocking pool (unit tests, tools, a writer not set up or nil) every text is written on the calling thread.
//   * The text of a file is made by its owner, on the owner's thread, only when what the file holds changed.
//   * file_put, file_drop, file_move and file_append are the direct writes of the product
//     (src/tools/test_all/lint_file_writes.odin fails on another one), for the owners whose job does more than give a
//     file's whole text: the cookies' copy, the history's journal, the crash snapshot. A nil writer means the program has
//     none yet (the start, before the loop). In the check build they panic on the interface thread while the blocking
//     pool could do the write.
// One File_Writer serves the whole program: the files of the shell and of the pages are flushed together at exit.

import "base:runtime"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "wb:base"

FILE_RETRY_FIRST_MS :: 2000
FILE_RETRY_LAST_MS :: 5 * 60 * 1000
// How many rounds of the blocking pool the exit waits for a write that runs (each round waits for the whole pool).
FILE_FLUSH_ROUNDS :: 50

// How long after the `failures`-th failure in a row the next try comes (pure: profile_file_test.odin).
file_retry_ms :: proc(failures: int) -> int {
	ms := FILE_RETRY_FIRST_MS
	for _ in 1 ..< max(failures, 1) {
		ms *= 2
		if ms >= FILE_RETRY_LAST_MS { return FILE_RETRY_LAST_MS }
	}
	return ms
}

// The failures of one file's writes.
Write_Health :: struct {
	failures: int,    // writes failed in a row
	warned:   bool,   // the user was told of this streak
}

// Tells the user that `path` could not be written. Returns false when it cannot be told now (no window): the next
// failure tries again.
File_Tell :: proc(user: rawptr, path: string) -> bool

File_Writer :: struct {
	ready:     bool,                       // file_writer_init ran (a zero writer writes everything on the calling thread)
	loop:      ^Loop,
	blocking:  ^Blocking_Pool,
	tell:      File_Tell,                  // nil: failures are logged only
	tell_user: rawptr,
	closing:   bool,                       // file_writer_flush ran: every text is written on the loop thread
	files:     [dynamic]^Profile_File,     // every file set up, for the flush at exit
	by_path:   map[string]^Profile_File,   // the files profile_write made (keys: the file's own path)
}

// Loop thread.
file_writer_init :: proc(w: ^File_Writer, loop: ^Loop, blocking: ^Blocking_Pool, tell: File_Tell = nil, tell_user: rawptr = nil) {
	w^ = {ready = true, loop = loop, blocking = blocking, tell = tell, tell_user = tell_user}
}

// At exit (loop thread): every file's running write finishes, what waits is written now, and later texts at once.
file_writer_flush :: proc(w: ^File_Writer) {
	if w == nil || !w.ready { return }
	w.closing = true
	// (by index: a task that blocking_settle runs can set up another file meanwhile)
	for i := 0; i < len(w.files); i += 1 { profile_file_flush(w.files[i]) }
}

// After file_writer_flush and the blocking pool's end. A Profile_File of an owner can be destroyed after this.
file_writer_destroy :: proc(w: ^File_Writer) {
	if w == nil || !w.ready { return }
	for _, f in w.by_path {
		profile_file_destroy(f)
		free(f)
	}
	delete(w.by_path)
	delete(w.files)
	w^ = {}
}

// Whether jobs can go to the blocking pool: the writer is set up, its pool runs and is not stopping.
writer_pool_ready :: proc(w: ^File_Writer) -> bool {
	return w != nil && w.ready && w.blocking != nil && len(w.blocking.threads) > 0 && !w.blocking.stopping
}

// After a write of `path` (loop thread): a failure is logged and told to the user once per streak (`tell` false: logged
// only, as at exit when no window may be left). Returns when to try again (0: it worked).
file_write_report :: proc(w: ^File_Writer, h: ^Write_Health, path: string, ok: bool, tell := true) -> (retry_ms: int) {
	if ok {
		if h.failures > 0 { log.infof("profile: %s written again after %d failed writes", path, h.failures) }
		h^ = {}
		return 0
	}
	h.failures += 1
	// (base.file_write_atomic says only that it failed: the system's reason is not kept)
	log.warnf("profile: cannot write %s (%d failed writes in a row)", path, h.failures)
	if tell && !h.warned && w != nil && w.ready && w.tell != nil {
		h.warned = w.tell(w.tell_user, filepath.base(path))
	}
	return file_retry_ms(h.failures)
}

////////////////////////////////
// The direct writes

// Check build: a write on the interface thread while the blocking pool could make it is a bug. At exit, or without a
// pool, the calling thread is the only one left to write.
@(private = "file")
assert_off_interface :: proc(w: ^File_Writer, by: runtime.Source_Code_Location) {
	when base.TRACK_MEMORY {
		if !writer_pool_ready(w) || w.closing || w.loop == nil { return }
		if on_loop_thread(w.loop) { panic("a profile file written on the interface thread", by) }
	}
}

// Writes `data` to `path` whole and atomically (a temporary file renamed over it). A worker of the blocking pool; the
// loop thread only when `w` has no pool or is closing. `private`: readable by the user only.
file_put :: proc(w: ^File_Writer, path: string, data: []byte, flush := false, private := false, by := #caller_location) -> bool {
	assert_off_interface(w, by)
	return put_now(path, data, flush, private)
}

// Removes `path` (absent: done). The same threads as file_put.
file_drop :: proc(w: ^File_Writer, path: string, by := #caller_location) -> bool {
	assert_off_interface(w, by)
	return drop_now(path)
}

// Renames `from` to `to`, replacing it (a file kept aside, a download moved into place). The same threads as file_put.
file_move :: proc(w: ^File_Writer, from, to: string, by := #caller_location) -> bool {
	assert_off_interface(w, by)
	return os.rename(from, to) == nil
}

// Adds `data` at the end of `path`, which must exist (a journal: the global history's log), on the disk before it
// returns. The same threads as file_put. A failure can leave part of `data` written: the owner then rewrites it whole.
file_append :: proc(w: ^File_Writer, path: string, data: []byte, by := #caller_location) -> bool {
	assert_off_interface(w, by)
	f, err := os.open(path, {.Write, .Append})
	if err != nil { return false }
	defer os.close(f)
	rest := data
	for len(rest) > 0 {
		n, werr := os.write(f, rest)
		if werr != nil || n <= 0 { return false }
		rest = rest[n:]
	}
	return os.sync(f) == nil
}

@(private = "file")
put_now :: proc(path: string, data: []byte, flush, private: bool) -> bool {
	if base.file_write_atomic(path, data, flush = flush, private = private) { return true }
	// (a missing folder is made here, off the interface thread, so that no owner makes it on its own thread first)
	dir := filepath.dir(path)
	if dir == "" || dir == "." || os.exists(dir) || os.make_directory_all(dir) != nil { return false }
	return base.file_write_atomic(path, data, flush = flush, private = private)
}

@(private = "file")
drop_now :: proc(path: string) -> bool { return os.remove(path) == nil || !os.exists(path) }

////////////////////////////////
// A file rewritten whole in the background

Profile_File :: struct {
	writer:  ^File_Writer,
	path:    string,        // owned ("": not set up, nothing is written)
	flush:   bool,          // on the disk before the rename (fsync)
	private: bool,          // readable by the user only
	busy:    bool,          // a write is out on the blocking pool
	next:    string,        // owned: the newest text not handed to a write
	waiting: bool,          // `next` is to be written
	remove:  bool,          // ... or rather the file removed
	health:  Write_Health,
	retry:   base.Handle,   // the timer of the next try after a failure
	closing: bool,          // profile_file_flush ran: texts are written on the loop thread
}

// Sets the file up (once: a second call keeps the first path). `w` nil or not set up: every text is written at once.
profile_file_init :: proc(f: ^Profile_File, w: ^File_Writer, path: string, flush := false, private := false) {
	if f.path != "" { return }
	f.writer, f.flush, f.private = w, flush, private
	f.path = strings.clone(path)
	if w != nil && w.ready { append(&w.files, f) }
}

// The file is to hold `text` (copied).
profile_file_write :: proc(f: ^Profile_File, text: string) { profile_file_put(f, text, false) }

// The file is to go.
profile_file_remove :: proc(f: ^Profile_File) { profile_file_put(f, "", true) }

// The file of `path` that the writer keeps, made on first use (loop thread): for an owner that keeps no Profile_File of
// its own. The first call's `flush` and `private` stay.
writer_file :: proc(w: ^File_Writer, path: string, flush := false, private := false) -> ^Profile_File {
	if f, ok := w.by_path[path]; ok { return f }
	f := new(Profile_File)
	profile_file_init(f, w, path, flush, private)
	w.by_path[f.path] = f
	return f
}

// `path` is to hold `text` (copied), through the writer's file of that path. Loop thread.
profile_write :: proc(w: ^File_Writer, path, text: string, flush := false, private := false) {
	if w == nil || !w.ready {
		h: Write_Health
		file_write_report(w, &h, path, put_now(path, transmute([]byte)text, flush, private), tell = false)
		return
	}
	profile_file_write(writer_file(w, path, flush, private), text)
}

// `path` is to go, through the writer's file of that path. Loop thread.
profile_remove :: proc(w: ^File_Writer, path: string) {
	if w == nil || !w.ready {
		h: Write_Health
		file_write_report(w, &h, path, drop_now(path), tell = false)
		return
	}
	profile_file_remove(writer_file(w, path))
}

// Whether a text of `path` given to profile_write is not on the disk yet (loop thread): its owner keeps what it holds in
// memory meanwhile, so that nothing reads the older file.
profile_pending :: proc(w: ^File_Writer, path: string) -> bool {
	if w == nil || !w.ready { return false }
	f, ok := w.by_path[path]
	return ok && (f.busy || f.waiting)
}

@(private = "file")
Posted_Text :: struct {
	w:          ^File_Writer,
	path, text: string,   // the process allocator's
}

// profile_write from any thread (a page's worker, under its owner's lock): the text goes to the loop thread, which hands
// it to the file. Always posted, from the loop thread too: the loop's tasks run in order, so a newer text never lands
// before an older one.
profile_post :: proc(w: ^File_Writer, path, text: string) {
	if w == nil || !w.ready {
		h: Write_Health
		file_write_report(w, &h, path, put_now(path, transmute([]byte)text, false, false), tell = false)
		return
	}
	pa := base.process_allocator()
	t := new(Posted_Text, pa)
	t^ = {w = w, path = strings.clone(path, pa), text = strings.clone(text, pa)}
	post(w.loop, proc(data: rawptr) {
		t := (^Posted_Text)(data)
		pa := base.process_allocator()
		if t.w.ready { profile_write(t.w, t.path, t.text) }
		delete(t.path, pa)
		delete(t.text, pa)
		free(t, pa)
	}, t)
}

@(private = "file")
profile_file_put :: proc(f: ^Profile_File, text: string, remove: bool) {
	if f.path == "" { return }
	delete(f.next)
	f.next, f.remove, f.waiting = strings.clone(text), remove, true
	profile_file_kick(f)
}

@(private = "file")
File_Write_Job :: struct {
	file:    ^Profile_File,
	writer:  ^File_Writer,
	path:    string,   // owned
	text:    string,   // owned
	remove:  bool,
	flush:   bool,
	private: bool,
	ok:      bool,
}

@(private = "file")
file_write_work :: proc(data: rawptr) {
	j := (^File_Write_Job)(data)
	j.ok = j.remove ? file_drop(j.writer, j.path) : file_put(j.writer, j.path, transmute([]byte)j.text, j.flush, j.private)
}

// The pool ended before the job started: the text waits again (profile_file_destroy frees it).
@(private = "file")
file_write_discard :: proc(data: rawptr) {
	j := (^File_Write_Job)(data)
	f := j.file
	f.busy = false
	if f.waiting { delete(j.text) } else { f.next, f.remove, f.waiting = j.text, j.remove, true }
	delete(j.path)
	free(j)
}

// Hands the text that waits to a write, when none runs and no retry is pending.
@(private = "file")
profile_file_kick :: proc(f: ^Profile_File) {
	if !f.waiting || f.busy || f.retry != base.NIL_HANDLE { return }
	text, remove := f.next, f.remove
	f.next, f.waiting, f.remove = "", false, false
	w := f.writer
	at_exit := f.closing || (w != nil && w.closing)
	if at_exit || !writer_pool_ready(w) {
		// (the exit, or no pool: this thread is the only one left to write. A file flushed alone, by an owner that stops,
		// is written here too: what it holds must be on the disk before the owner frees it.)
		ok := remove ? drop_now(f.path) : put_now(f.path, transmute([]byte)text, f.flush, f.private)
		file_write_report(w, &f.health, f.path, ok, tell = !at_exit)
		delete(text)
		return
	}
	job := new(File_Write_Job)
	job^ = {file = f, writer = w, path = strings.clone(f.path), text = text, remove = remove, flush = f.flush, private = f.private}
	f.busy = true
	run_blocking(w.blocking, file_write_work, file_write_done, job, file_write_discard)
}

@(private = "file")
file_write_done :: proc(data: rawptr) {
	j := (^File_Write_Job)(data)
	f := j.file
	w := j.writer
	defer { delete(j.path); free(j) }
	quiet_note(w.loop)   // (the disk, not the screen)
	f.busy = false
	retry := file_write_report(w, &f.health, f.path, j.ok)
	if j.ok {
		delete(j.text)
		profile_file_kick(f)
		return
	}
	// what failed is written again, unless a newer text came meanwhile; either way not before the delay
	if f.waiting { delete(j.text) } else { f.next, f.remove, f.waiting = j.text, j.remove, true }
	if f.closing || w.closing { profile_file_kick(f); return }
	f.retry = set_timer(w.loop, f64(retry), 0, proc(data: rawptr) {
		f := (^Profile_File)(data)
		f.retry = base.NIL_HANDLE
		quiet_note(f.writer.loop)
		profile_file_kick(f)
	}, f)
}

// At exit (loop thread): the write that runs finishes, what waits is written now, and later texts are written at once.
profile_file_flush :: proc(f: ^Profile_File) {
	f.closing = true   // (also for a file set up later: a write queued now could be dropped by the pool's end)
	if f.path == "" { return }
	w := f.writer
	if f.retry != base.NIL_HANDLE { clear_timer(w.loop, f.retry); f.retry = base.NIL_HANDLE }
	for _ in 0 ..< FILE_FLUSH_ROUNDS {
		if !f.busy { break }
		blocking_settle(w.blocking)
	}
	profile_file_kick(f)
}

// Frees what the file holds, after profile_file_flush (no write out, no retry timer: this may run after the loop ended).
profile_file_destroy :: proc(f: ^Profile_File) {
	if w := f.writer; w != nil && w.ready {
		for g, i in w.files { if g == f { unordered_remove(&w.files, i); break } }
	}
	delete(f.path)
	delete(f.next)
	f^ = {}
}
