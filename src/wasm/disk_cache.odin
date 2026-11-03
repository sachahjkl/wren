package wasm

// A cache of engine output in a folder of the profile, shared by the compiled-code cache (module_cache.odin) and the
// JavaScript bytecode cache (src/js): one file per key, "<magic>" | HMAC-SHA256(profile key, magic | key | payload) |
// payload, named by the key's hex. The profile key is 32 random bytes stored protected by DPAPI (current Windows user);
// a file whose MAC or format does not match is deleted. Writes go to a background thread (temporary file, then rename),
// each followed by a trim of the folder to `max_bytes`, least recently used first (a read touches the file's time).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "wb:base"

@(private) DISK_KEY_FILE :: "cache-key.dpapi"
@(private) DISK_FLUSH_POLL :: time.Millisecond   // disk_flush looks at the writer this often
@(private) DISK_STALE_TMP_AGE :: time.Hour       // a temporary file older than this was left by a run that ended; it is removed

Disk_Cache :: struct {
	// set before disk_start
	magic:       string,          // the first bytes of every file
	ext:         string,          // the files' extension
	max_bytes:   i64,
	stop_budget: time.Duration,   // when stopping, the writes still queued after this are dropped (0: every one is written)
	warn:        string,          // the prefix of the message printed when the folder cannot be used ("": none)

	dir:         string,
	key:         [32]u8,
	writes, rejects, evictions: int,   // files written, refused (and deleted), trimmed (atomic)
	qlock:       sync.Mutex,
	qcond:       sync.Cond,
	queue:       [dynamic]Disk_Job,
	writing:     bool,   // a job is taken off the queue and not finished (under qlock)
	stop:        bool,
	writer:      ^thread.Thread,
}

@(private)
Disk_Job :: struct {
	path:    string,
	key:     Digest,
	payload: []byte,
}

// Loads (or creates) the profile key of `dir` and starts the writer. False: no disk cache (the key can be neither read nor
// created).
disk_start :: proc(d: ^Disk_Cache, dir: string) -> bool {
	context.allocator = base.process_allocator()
	_ = os.make_directory_all(dir)
	path, perr := filepath.join({dir, DISK_KEY_FILE}, context.temp_allocator)
	if perr != nil { return false }
	if !disk_key_load(d, path) { return false }
	d.dir = strings.clone(dir)
	d.stop = false
	d.writer = thread.create_and_start_with_data(d, disk_writer_main)
	return true
}

@(private)
disk_key_load :: proc(d: ^Disk_Cache, path: string) -> bool {
	if blob, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		if key, ok := unprotect(blob, context.temp_allocator); ok && len(key) == len(d.key) {
			copy(d.key[:], key)
			return true
		}
	}
	// none, or unreadable (another user, another machine, damaged): a new key, so every old entry stops matching
	fail :: proc(d: ^Disk_Cache, path, why: string, err: os.Error = nil) -> bool {
		if d.warn != "" { fmt.eprintfln("%s disabled: %s %s (%v)", d.warn, why, path, err) }
		return false
	}
	if !random_fill(d.key[:]) { return fail(d, path, "no random key for") }
	blob, ok := protect(d.key[:], context.temp_allocator)
	if !ok { return fail(d, path, "the system cannot protect") }
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if err := os.write_entire_file(tmp, blob, {.Read_User, .Write_User}); err != nil { return fail(d, tmp, "cannot write", err) }
	if err := os.rename(tmp, path); err != nil { _ = os.remove(tmp); return fail(d, path, "cannot create", err) }
	return true
}

// Stops the writer (after the writes queued, within stop_budget) and frees everything.
disk_stop :: proc(d: ^Disk_Cache) {
	context.allocator = base.process_allocator()
	if d.writer != nil {
		sync.mutex_lock(&d.qlock)
		d.stop = true
		sync.cond_broadcast(&d.qcond)
		sync.mutex_unlock(&d.qlock)
		thread.join(d.writer)
		thread.destroy(d.writer)
	}
	for j in d.queue { delete(j.path); delete(j.payload) }
	delete(d.queue)
	delete(d.dir)
	d^ = {}
}

// Waits until the writer is idle: nothing queued and nothing being written. For measurements and tests.
disk_flush :: proc(d: ^Disk_Cache) {
	for {
		sync.mutex_lock(&d.qlock)
		idle := len(d.queue) == 0 && !d.writing
		sync.mutex_unlock(&d.qlock)
		if idle { return }
		time.sleep(DISK_FLUSH_POLL)
	}
}

// The file of `key` (the process heap).
disk_path :: proc(d: ^Disk_Cache, key: Digest) -> string {
	hex := strings.builder_make(context.temp_allocator)
	for b in key { fmt.sbprintf(&hex, "%02x", b) }
	strings.write_string(&hex, d.ext)
	p, _ := filepath.join({d.dir, strings.to_string(hex)}, base.process_allocator())
	return p
}

@(private)
disk_mac :: proc(d: ^Disk_Cache, key: Digest, payload: []byte) -> (Digest, bool) {
	key := key
	return sha256(transmute([]byte)d.magic, key[:], payload, key = d.key[:])
}

// The file at `path` (the process heap: free `data`) and its payload, nil when missing or refused (then deleted).
disk_read :: proc(d: ^Disk_Cache, path: string, key: Digest) -> (data, payload: []byte) {
	err: os.Error
	data, err = os.read_entire_file(path, base.process_allocator())
	if err != nil { return nil, nil }
	head := len(d.magic) + len(Digest)
	mac: Digest
	ok := false
	if len(data) > head && string(data[:len(d.magic)]) == d.magic { mac, ok = disk_mac(d, key, data[head:]) }
	if !ok || !digest_equal(mac[:], data[len(d.magic):head]) {
		delete(data, base.process_allocator())
		disk_reject(d, path)
		return nil, nil
	}
	now := time.now()
	_ = os.change_times(path, now, now)   // least recently used order
	return data, data[head:]
}

// Deletes a file the cache cannot use.
disk_reject :: proc(d: ^Disk_Cache, path: string) {
	_ = os.remove(path)
	sync.atomic_add(&d.rejects, 1)
}

// Queues `payload` (the process heap: the cache owns it from now) for the file at `path` (copied).
disk_queue :: proc(d: ^Disk_Cache, path: string, key: Digest, payload: []byte) {
	sync.mutex_lock(&d.qlock)
	append(&d.queue, Disk_Job{path = strings.clone(path, base.process_allocator()), key = key, payload = payload})
	sync.cond_signal(&d.qcond)
	sync.mutex_unlock(&d.qlock)
}

@(private)
disk_writer_main :: proc(data: rawptr) {
	d := (^Disk_Cache)(data)
	context.allocator = base.process_allocator()
	stopped_at: time.Tick   // when the writer first saw the stop request
	for {
		sync.mutex_lock(&d.qlock)
		for len(d.queue) == 0 && !d.stop { sync.cond_wait(&d.qcond, &d.qlock) }
		if len(d.queue) == 0 {
			sync.mutex_unlock(&d.qlock)
			return
		}
		if d.stop && d.stop_budget > 0 {
			// Closing the program: a page that compiled many modules leaves many writes queued, and each one scans the
			// folder (disk_trim); waiting for all of them keeps a closed window on screen for seconds. The cache is only
			// an optimisation: after the budget the writes still queued are dropped.
			if stopped_at == {} { stopped_at = time.tick_now() }
			if time.tick_since(stopped_at) > d.stop_budget {
				for j in d.queue { delete(j.path); delete(j.payload) }
				clear(&d.queue)
				sync.mutex_unlock(&d.qlock)
				return
			}
		}
		job := pop_front(&d.queue)
		d.writing = true
		last := len(d.queue) == 0
		sync.mutex_unlock(&d.qlock)

		if disk_write(d, job) {
			sync.atomic_add(&d.writes, 1)
			if last || !d.stop { disk_trim(d) }
		}
		delete(job.path)
		delete(job.payload)
		free_all(context.temp_allocator)
		sync.mutex_lock(&d.qlock)
		d.writing = false   // after the counts: disk_flush returns once they are up to date
		sync.mutex_unlock(&d.qlock)
	}
}

@(private)
disk_write :: proc(d: ^Disk_Cache, job: Disk_Job) -> bool {
	mac, ok := disk_mac(d, job.key, job.payload)
	if !ok { return false }
	head := len(d.magic) + len(Digest)
	buf := make([]byte, head + len(job.payload))
	defer delete(buf)
	copy(buf, d.magic)
	copy(buf[len(d.magic):], mac[:])
	copy(buf[head:], job.payload)
	nonce: [8]u8
	random_fill(nonce[:])
	tmp := fmt.tprintf("%s.%x.tmp", job.path, transmute(u64)nonce)
	if we := os.write_entire_file(tmp, buf); we != nil { _ = os.remove(tmp); return false }
	if re := os.rename(tmp, job.path); re != nil { _ = os.remove(tmp); return false }
	return true
}

// Keeps the folder under max_bytes: least recently used entries go first. Stray temporary files of an interrupted write
// are removed too.
@(private)
disk_trim :: proc(d: ^Disk_Cache) {
	infos, err := os.read_all_directory_by_path(d.dir, context.temp_allocator)
	if err != nil { return }
	entries := make([dynamic]os.File_Info, context.temp_allocator)
	total: i64
	for fi in infos {
		if strings.has_suffix(fi.name, ".tmp") && time.diff(fi.modification_time, time.now()) > DISK_STALE_TMP_AGE { _ = os.remove(fi.fullpath); continue }
		if !strings.has_suffix(fi.name, d.ext) { continue }
		append(&entries, fi)
		total += fi.size
	}
	if total <= d.max_bytes { return }
	slice.sort_by(entries[:], proc(a, b: os.File_Info) -> bool { return time.diff(a.modification_time, b.modification_time) > 0 })
	for fi in entries {
		if total <= d.max_bytes { break }
		if os.remove(fi.fullpath) == nil {
			total -= fi.size
			sync.atomic_add(&d.evictions, 1)
		}
	}
}
