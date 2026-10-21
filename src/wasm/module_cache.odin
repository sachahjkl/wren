package wasm

// Compiled modules of the Wasmtime engine, keyed by the SHA-256 of the module image.
//
// Memory: entries kept up to wasm.cache.memory_bytes of compiled code, least recently used evicted first (an entry in
// use by an instantiation in progress is never freed under it; instances themselves do not need the entry: Wasmtime
// keeps what they use alive). Each entry holds the InstancePre of the module (imports resolved against the Linker
// once), rebuilt when host functions are added later.
//
// Disk (profile folder wasm-cache, wasm.cache.disk): the serialized code, written by a background thread, read back on
// the next start instead of compiling. Deserializing runs machine code produced from the file, so only files this
// profile wrote are accepted: each one carries an HMAC-SHA256 over its key and contents, with a 32-byte key generated
// for the profile and stored protected by DPAPI (current Windows user). A file whose MAC, key or format does not match,
// or that Wasmtime refuses (another version, configuration or CPU), is deleted and the module compiled again. The
// file name is derived from the module hash and the engine configuration (fingerprint), so a configuration change
// never reads stale code; the folder is trimmed to wasm.cache.disk_max_bytes, least recently used first.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "wb:base"

@(private) DISK_MAGIC :: "WRENWTC1"
@(private) DISK_EXT :: ".wtc"
@(private) KEY_FILE :: "cache-key.dpapi"

Cache_Stats :: struct {
	memory_hits:  int,
	disk_hits:    int,
	compiles:     int,
	disk_rejects: int,   // files refused (MAC, format, or Wasmtime) and deleted
	disk_writes:  int,
	disk_evictions: int,
	memory_evictions: int,
}

@(private)
Cached :: struct {
	key:           Digest,
	module:        wt_module,
	pre:           wt_instance_pre,
	pre_gen:       u64,
	imports:       []Cached_Import,
	link_error:    string,    // an import the browser cannot provide and that cannot be stubbed (not a function)
	memory_export: string,
	table_export:  string,
	memory64:      bool,      // memory 0 is 64-bit
	code_bytes:    int,
	users:         int,
	last_use:      u64,
	in_map:        bool,
}

@(private)
Cached_Import :: struct {
	module, name: string,
	kind:         u8,
}

@(private)
Disk_Job :: struct {
	path:    string,
	filekey: Digest,
	payload: []byte,
}

@(private)
Cache :: struct {
	lock:      sync.Mutex,
	entries:   map[Digest]^Cached,
	total:     int,
	clock:     u64,
	max_bytes: i64,
	dir:       string,
	key:       [32]u8,
	disk:      bool,
	disk_max:  i64,
	stats:     Cache_Stats,
	qlock:     sync.Mutex,
	qcond:     sync.Cond,
	queue:     [dynamic]Disk_Job,
	busy:      bool,
	stop:      bool,
	writer:    ^thread.Thread,
}

@(private)
cache: Cache

@(private)
cache_start :: proc(rs: Runtime_Settings) {
	context.allocator = base.process_allocator()
	cache.entries = make(map[Digest]^Cached)
	cache.max_bytes = rs.cache_memory_bytes
	cache.disk_max = rs.cache_disk_max_bytes
	if rs.cache_dir != "" && disk_key_load(rs.cache_dir) {
		cache.dir = strings.clone(rs.cache_dir)
		cache.disk = true
		cache.stop = false
		cache.writer = thread.create_and_start_with_data(nil, disk_writer_main)
	}
}

@(private)
cache_stop :: proc() {
	context.allocator = base.process_allocator()
	if cache.writer != nil {
		sync.mutex_lock(&cache.qlock)
		cache.stop = true
		sync.cond_broadcast(&cache.qcond)
		sync.mutex_unlock(&cache.qlock)
		thread.join(cache.writer)
		thread.destroy(cache.writer)
	}
	for j in cache.queue { delete(j.path); delete(j.payload) }
	delete(cache.queue)
	for _, c in cache.entries { cached_free(c) }
	delete(cache.entries)
	delete(cache.dir)
	cache = {}
}

cache_stats :: proc() -> Cache_Stats {
	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)
	return cache.stats
}

// Drops every compiled module kept in memory (the disk cache stays). For measurements and tests.
cache_clear_memory :: proc() {
	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)
	context.allocator = base.process_allocator()
	for k, c in cache.entries {
		if c.users > 0 { continue }
		cache.total -= c.code_bytes
		delete_key(&cache.entries, k)
		cached_free(c)
	}
}

// Waits until every queued disk write is done. For measurements and tests.
cache_flush :: proc() {
	for {
		sync.mutex_lock(&cache.qlock)
		idle := len(cache.queue) == 0 && !cache.busy
		sync.mutex_unlock(&cache.qlock)
		if idle { return }
		time.sleep(time.Millisecond)
	}
}

@(private)
cached_free :: proc(c: ^Cached) {
	context.allocator = base.process_allocator()
	if c.pre != nil { wasmtime_instance_pre_delete(c.pre) }
	if c.module != nil { wasmtime_module_delete(c.module) }
	for im in c.imports { delete(im.module); delete(im.name) }
	delete(c.imports)
	delete(c.link_error)
	delete(c.memory_export)
	delete(c.table_export)
	free(c)
}

// The compiled module of `image`, ready to instantiate (`pre`), or an error message (allocated). Pair with
// cache_release.
@(private)
cache_acquire :: proc(image: []byte, known: ^Digest = nil) -> (c: ^Cached, err: string) {
	caller := context.allocator
	context.allocator = base.process_allocator()
	key: Digest
	if known != nil {
		key = known^
	} else {
		hashed: bool
		key, hashed = sha256(image)
		if !hashed { return nil, strings.clone("cannot hash the module", caller) }
	}

	sync.mutex_lock(&cache.lock)
	if found, ok := cache.entries[key]; ok {
		found.users += 1
		cache.clock += 1
		found.last_use = cache.clock
		cache.stats.memory_hits += 1
		ensure_pre(found)
		sync.mutex_unlock(&cache.lock)
		return found, ""
	}
	sync.mutex_unlock(&cache.lock)

	info, aerr := analyze_image(image)
	if aerr != "" { return nil, strings.clone(aerr, caller) }
	filekey: Digest
	path: string
	defer delete(path)
	module: wt_module
	from_disk := false
	if cache.disk {
		filekey, _ = sha256(key[:], wt.fingerprint[:])
		path = disk_path(filekey)
		module = disk_load(path, filekey)
		from_disk = module != nil
	}
	if module == nil {
		patched, copied := patch_image(image, info)
		e := wasmtime_module_new(wt.engine, raw_data(patched), len(patched), &module)
		if copied { delete(patched) }
		if e != nil {
			text := wt_error_text(e, context.temp_allocator)
			wasmtime_error_delete(e)
			return nil, fmt.aprintf("compile failed: %s", text, allocator = caller)
		}
		if cache.disk { disk_queue(path, filekey, module) }
	}

	c = new(Cached)
	c.key = key
	c.module = module
	c.memory_export = strings.clone(info.memory_export)
	c.table_export = strings.clone(info.table_export)
	c.memory64 = info.memory64
	start, end: rawptr
	wasmtime_module_image_range(module, &start, &end)
	c.code_bytes = int(uintptr(end) - uintptr(start))
	read_imports(c)

	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)
	if from_disk { cache.stats.disk_hits += 1 } else { cache.stats.compiles += 1 }
	if found, ok := cache.entries[key]; ok {   // compiled by another thread meanwhile
		cached_free(c)
		found.users += 1
		ensure_pre(found)
		return found, ""
	}
	c.users = 1
	cache.clock += 1
	c.last_use = cache.clock
	ensure_pre(c)
	if cache.max_bytes > 0 {
		c.in_map = true
		cache.entries[key] = c
		cache.total += c.code_bytes
		evict_memory()
	}
	return c, ""
}

@(private)
cache_release :: proc(c: ^Cached) {
	context.allocator = base.process_allocator()
	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)
	c.users -= 1
	if !c.in_map && c.users == 0 { cached_free(c) }
}

// Under cache.lock.
@(private)
evict_memory :: proc() {
	for i64(cache.total) > cache.max_bytes {
		victim: ^Cached
		for _, e in cache.entries {
			if e.users > 0 { continue }
			if victim == nil || e.last_use < victim.last_use { victim = e }
		}
		if victim == nil { return }
		delete_key(&cache.entries, victim.key)
		cache.total -= victim.code_bytes
		cache.stats.memory_evictions += 1
		cached_free(victim)
	}
}

@(private)
read_imports :: proc(c: ^Cached) {
	context.allocator = base.process_allocator()
	v: wt_ptr_vec
	wasmtime_module_imports(c.module, &v)
	defer wasm_importtype_vec_delete(&v)
	list := make([]Cached_Import, int(v.size))
	for i in 0 ..< int(v.size) {
		it := wt_importtype(v.data[i])
		m := wasm_importtype_module(it)
		n := wasm_importtype_name(it)
		list[i] = Cached_Import{
			module = strings.clone(string(m.data[:m.size])),
			name = strings.clone(string(n.data[:n.size])),
			kind = wasm_externtype_kind(wasm_importtype_type(it)),
		}
	}
	c.imports = list
}

// Under cache.lock. Resolves the imports against the host functions. A memory64 module gets the 64-bit shape of every
// import that has addresses (shadowing the 32-bit one on a clone of the Linker). An import the browser lacks, or has
// with another type, becomes a function that traps when called; a missing import of another kind is an error.
@(private)
ensure_pre :: proc(c: ^Cached) {
	if c.pre != nil && c.pre_gen == wt.linker_gen { return }
	context.allocator = base.process_allocator()
	if c.pre != nil { wasmtime_instance_pre_delete(c.pre); c.pre = nil }
	delete(c.link_error)
	c.link_error = ""
	c.pre_gen = wt.linker_gen

	v: wt_ptr_vec
	wasmtime_module_imports(c.module, &v)
	defer wasm_importtype_vec_delete(&v)
	l := wt.linker
	clone: wt_linker
	shadow :: proc(clone: ^wt_linker, l: ^wt_linker) {
		if clone^ != nil { return }
		clone^ = wasmtime_linker_clone(wt.linker)
		wasmtime_linker_allow_shadowing(clone^, true)
		l^ = clone^
	}
	for i in 0 ..< int(v.size) {
		it := wt_importtype(v.data[i])
		m := wasm_importtype_module(it)
		n := wasm_importtype_name(it)
		mod, name := string(m.data[:m.size]), string(n.data[:n.size])
		et := wasm_importtype_type(it)
		kind := wasm_externtype_kind(et)
		if kind != WT_EXTERN_FUNC {
			what := kind == WT_EXTERN_MEMORY ? "memory" : kind == WT_EXTERN_TABLE ? "table" : kind == WT_EXTERN_GLOBAL ? "global" : "item"
			c.link_error = fmt.aprintf("imports the %s %s.%s, which the browser does not provide", what, mod, name)
			return
		}
		im := registry_find(mod, name)
		ty := wasm_externtype_as_functype_const(et)
		wide := c.memory64 && im != nil && im.wide_params != nil
		if im != nil && import_matches(ty, im, wide) {
			if !wide { continue }
			shadow(&clone, &l)
			if !define_import(clone, im, true) {
				c.link_error = fmt.aprintf("cannot link %s.%s with 64-bit addresses", mod, name)
				wasmtime_linker_delete(clone)
				return
			}
			continue
		}
		shadow(&clone, &l)
		s := new(Stub)
		if im == nil {
			s.message = fmt.aprintf("call to the import %s.%s, which the browser does not provide", mod, name)
		} else {
			s.message = fmt.aprintf("call to the import %s.%s with a type that does not match the browser's%s", mod, name, wide ? " (64-bit addresses for a memory64 module)" : "")
		}
		if e := wasmtime_linker_define_func_unchecked(clone, raw_data(mod), len(mod), raw_data(name), len(name), ty, wt_stub_call, s, wt_stub_free); e != nil {
			c.link_error = fmt.aprintf("cannot link %s.%s: %s", mod, name, wt_error_text(e, context.temp_allocator))
			wasmtime_error_delete(e)
			wasmtime_linker_delete(clone)
			return
		}
	}
	e := wasmtime_linker_instantiate_pre(l, c.module, &c.pre)
	if clone != nil { wasmtime_linker_delete(clone) }   // the InstancePre keeps what it needs
	if e != nil {
		c.link_error = fmt.aprintf("cannot link: %s", wt_error_text(e, context.temp_allocator))
		wasmtime_error_delete(e)
		c.pre = nil
	}
}

////////////////////////////////
// Disk

@(private)
disk_path :: proc(filekey: Digest) -> string {
	hex := strings.builder_make(context.temp_allocator)
	for b in filekey { fmt.sbprintf(&hex, "%02x", b) }
	strings.write_string(&hex, DISK_EXT)
	p, _ := filepath.join({cache.dir, strings.to_string(hex)}, base.process_allocator())
	return p
}

// The profile's MAC key, created on first use. False (no disk cache) when it can be neither read nor created.
@(private)
disk_key_load :: proc(dir: string) -> bool {
	_ = os.make_directory_all(dir)
	path, perr := filepath.join({dir, KEY_FILE}, context.temp_allocator)
	if perr != nil { return false }
	if blob, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		if key, ok := unprotect(blob, context.temp_allocator); ok && len(key) == 32 {
			copy(cache.key[:], key)
			return true
		}
	}
	// none, or unreadable (another user, another machine, damaged): a new key, so every old entry stops matching
	fail :: proc(path, why: string, err: os.Error = nil) -> bool {
		fmt.eprintfln("wasm: compiled-code disk cache disabled: %s %s (%v)", why, path, err)
		return false
	}
	if !random_fill(cache.key[:]) { return fail(path, "no random key for") }
	blob, ok := protect(cache.key[:], context.temp_allocator)
	if !ok { return fail(path, "DPAPI cannot protect") }
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if err := os.write_entire_file(tmp, blob); err != nil { return fail(tmp, "cannot write", err) }
	if err := os.rename(tmp, path); err != nil { _ = os.remove(tmp); return fail(path, "cannot create", err) }
	return true
}

@(private)
disk_mac :: proc(filekey: Digest, payload: []byte) -> (Digest, bool) {
	filekey := filekey
	return sha256(transmute([]byte)string(DISK_MAGIC), filekey[:], payload, key = cache.key[:])
}

// A module from the disk cache, or nil (missing, refused: then the file is deleted).
@(private)
disk_load :: proc(path: string, filekey: Digest) -> wt_module {
	data, err := os.read_entire_file(path, base.process_allocator())
	if err != nil { return nil }
	defer delete(data, base.process_allocator())
	head := len(DISK_MAGIC) + 32
	reject := proc(path: string) -> wt_module {
		_ = os.remove(path)
		sync.mutex_lock(&cache.lock)
		cache.stats.disk_rejects += 1
		sync.mutex_unlock(&cache.lock)
		return nil
	}
	if len(data) <= head || string(data[:len(DISK_MAGIC)]) != DISK_MAGIC { return reject(path) }
	payload := data[head:]
	mac, ok := disk_mac(filekey, payload)
	if !ok || !digest_equal(mac[:], data[len(DISK_MAGIC):head]) { return reject(path) }
	m: wt_module
	if e := wasmtime_module_deserialize(wt.engine, raw_data(payload), len(payload), &m); e != nil {
		wasmtime_error_delete(e)
		return reject(path)
	}
	now := time.now()
	_ = os.change_times(path, now, now)   // least recently used order
	return m
}

@(private)
disk_queue :: proc(path: string, filekey: Digest, m: wt_module) {
	v: wt_byte_vec
	if e := wasmtime_module_serialize(m, &v); e != nil { wasmtime_error_delete(e); return }
	payload := make([]byte, int(v.size), base.process_allocator())
	copy(payload, v.data[:v.size])
	wasm_byte_vec_delete(&v)
	sync.mutex_lock(&cache.qlock)
	append(&cache.queue, Disk_Job{path = strings.clone(path, base.process_allocator()), filekey = filekey, payload = payload})
	sync.cond_signal(&cache.qcond)
	sync.mutex_unlock(&cache.qlock)
}

@(private)
disk_writer_main :: proc(_: rawptr) {
	context.allocator = base.process_allocator()
	for {
		sync.mutex_lock(&cache.qlock)
		for len(cache.queue) == 0 && !cache.stop { sync.cond_wait(&cache.qcond, &cache.qlock) }
		if len(cache.queue) == 0 {
			sync.mutex_unlock(&cache.qlock)
			return
		}
		job := pop_front(&cache.queue)
		cache.busy = true
		sync.mutex_unlock(&cache.qlock)

		if disk_write(job) {
			sync.mutex_lock(&cache.lock)
			cache.stats.disk_writes += 1
			sync.mutex_unlock(&cache.lock)
			disk_trim()
		}
		delete(job.path)
		delete(job.payload)
		free_all(context.temp_allocator)
		sync.mutex_lock(&cache.qlock)
		cache.busy = false
		sync.mutex_unlock(&cache.qlock)
	}
}

@(private)
disk_write :: proc(job: Disk_Job) -> bool {
	mac, ok := disk_mac(job.filekey, job.payload)
	if !ok { return false }
	head := len(DISK_MAGIC) + 32
	buf := make([]byte, head + len(job.payload))
	defer delete(buf)
	copy(buf, DISK_MAGIC)
	copy(buf[len(DISK_MAGIC):], mac[:])
	copy(buf[head:], job.payload)
	nonce: [8]u8
	random_fill(nonce[:])
	tmp := fmt.tprintf("%s.%x.tmp", job.path, transmute(u64)nonce)
	if we := os.write_entire_file(tmp, buf); we != nil { _ = os.remove(tmp); return false }
	if re := os.rename(tmp, job.path); re != nil { _ = os.remove(tmp); return false }
	return true
}

// Keeps the folder under wasm.cache.disk_max_bytes: least recently used entries go first. Stray temporary files of
// an interrupted write are removed too.
@(private)
disk_trim :: proc() {
	infos, err := os.read_all_directory_by_path(cache.dir, context.temp_allocator)
	if err != nil { return }
	entries := make([dynamic]os.File_Info, context.temp_allocator)
	total: i64
	for fi in infos {
		if strings.has_suffix(fi.name, ".tmp") && time.diff(fi.modification_time, time.now()) > time.Hour { _ = os.remove(fi.fullpath); continue }
		if !strings.has_suffix(fi.name, DISK_EXT) { continue }
		append(&entries, fi)
		total += fi.size
	}
	if total <= cache.disk_max { return }
	slice.sort_by(entries[:], proc(a, b: os.File_Info) -> bool { return time.diff(a.modification_time, b.modification_time) > 0 })
	for fi in entries {
		if total <= cache.disk_max { break }
		if os.remove(fi.fullpath) == nil {
			total -= fi.size
			sync.mutex_lock(&cache.lock)
			cache.stats.disk_evictions += 1
			sync.mutex_unlock(&cache.lock)
		}
	}
}
