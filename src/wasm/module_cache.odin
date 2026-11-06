package wasm

// Compiled modules of the Wasmtime engine, keyed by the SHA-256 of the module image.
//
// Memory: entries kept up to wasm.cache.memory_bytes (their machine code and MODULE_BYTES each), least recently used evicted first (an entry in
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
import "core:strings"
import "core:sync"
import "core:time"
import "wb:base"
import "wb:host"

@(private) DISK_MAGIC :: "WRENWTC1"
@(private) DISK_EXT :: ".wtc"
@(private) DISK_STOP_BUDGET :: 1500 * time.Millisecond
// What a module costs beyond its machine code (its mappings, whole pages, and the engine's tables of it), measured: 1300 modules of the JIT, 14 KB of
// code each, took 40 KB each of private bytes. A session makes thousands of them: counted by their code alone, 256 MB of it were 700 MB.
@(private) MODULE_BYTES :: 32 << 10
// Flips a bit of the key of a module compiled for the engine without epoch checks.
@(private) CACHE_KEY_POLLED :: 1

Cache_Stats :: struct {
	memory_hits:  int,
	disk_hits:    int,
	compiles:     int,
	disk_rejects: int,   // files refused (MAC, format, or Wasmtime) and deleted
	disk_writes:  int,
	disk_evictions: int,
	memory_evictions: int,
	entries:      int,   // compiled modules in memory now
	code_bytes:   int,   // their machine code
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
	polled:        bool,      // compiled for the engine without epoch checks (poll.odin)
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
Cache :: struct {
	lock:      sync.Mutex,
	entries:   map[Digest]^Cached,
	total:     int,
	clock:     u64,
	max_bytes: i64,
	disk:      bool,
	files:     Disk_Cache,
	stats:     Cache_Stats,
}

@(private)
cache: Cache

@(private)
cache_start :: proc(rs: Runtime_Settings) {
	context.allocator = base.process_allocator()
	cache.entries = make(map[Digest]^Cached)
	cache.max_bytes = rs.cache_memory_bytes
	cache.files = {magic = DISK_MAGIC, ext = DISK_EXT, max_bytes = rs.cache_disk_max_bytes, stop_budget = DISK_STOP_BUDGET, warn = "wasm: compiled-code disk cache"}
	cache.disk = rs.cache_dir != "" && disk_start(&cache.files, rs.cache_dir)
}

@(private)
cache_stop :: proc() {
	context.allocator = base.process_allocator()
	disk_stop(&cache.files)
	host.shutdown_step("wasm.runtime_destroy: compiled modules")
	for _, c in cache.entries { cached_free(c) }
	delete(cache.entries)
	cache = {}
}

cache_stats :: proc() -> Cache_Stats {
	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)
	s := cache.stats
	s.entries, s.code_bytes = len(cache.entries), cache.total - len(cache.entries) * MODULE_BYTES
	s.disk_writes, s.disk_rejects, s.disk_evictions = sync.atomic_load(&cache.files.writes), sync.atomic_load(&cache.files.rejects), sync.atomic_load(&cache.files.evictions)
	return s
}

// Module instances alive now (every store).
instances_alive :: proc() -> int { return sync.atomic_load(&live_instances) }

// Drops every compiled module kept in memory (the disk cache stays). For measurements and tests.
cache_clear_memory :: proc() {
	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)
	context.allocator = base.process_allocator()
	for k, c in cache.entries {
		if c.users > 0 { continue }
		cache.total -= c.code_bytes + MODULE_BYTES
		delete_key(&cache.entries, k)
		cached_free(c)
	}
}

// Waits until every queued disk write is done. For measurements and tests.
cache_flush :: proc() { disk_flush(&cache.files) }

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
// cache_release. `disk_only`: nil and no error when the module is neither in memory nor on disk (nothing compiled).
@(private)
cache_acquire :: proc(image: []byte, known: ^Digest = nil, disk_only := false, polled := false) -> (c: ^Cached, err: string) {
	caller := context.allocator
	engine := polled ? wt.polled_engine : wt.engine
	context.allocator = base.process_allocator()
	key: Digest
	if known != nil {
		key = known^
	} else {
		hashed: bool
		key, hashed = sha256(image)
		if !hashed { return nil, strings.clone("cannot hash the module", caller) }
	}
	if polled {
		key[0] ~= CACHE_KEY_POLLED   // (the same image for the other engine is another entry)
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
	if disk_only && !cache.disk { return nil, "" }

	info, aerr := analyze_image(image)
	if aerr != "" { return nil, strings.clone(aerr, caller) }
	filekey: Digest
	path: string
	defer delete(path)
	module: wt_module
	from_disk := false
	if cache.disk {
		fingerprint := polled ? wt.polled_fingerprint : wt.fingerprint
		filekey, _ = sha256(key[:], fingerprint[:])
		path = disk_path(&cache.files, filekey)
		module = disk_load(path, filekey, engine)
		from_disk = module != nil
	}
	if module == nil && disk_only { return nil, "" }
	if module == nil {
		patched, copied := patch_image(image, info)
		e := wasmtime_module_new(engine, raw_data(patched), len(patched), &module)
		if copied { delete(patched) }
		if e != nil {
			text := wt_error_text(e, context.temp_allocator)
			wasmtime_error_delete(e)
			return nil, fmt.aprintf("compile failed: %s", text, allocator = caller)
		}
		if cache.disk { disk_queue_module(path, filekey, module) }
	}

	c = new(Cached)
	c.key = key
	c.module = module
	c.memory_export = strings.clone(info.memory_export)
	c.table_export = strings.clone(info.table_export)
	c.memory64 = info.memory64
	c.polled = polled
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
		cache.total += c.code_bytes + MODULE_BYTES
		evict_memory()
	}
	return c, ""
}

// The compiled module of `image` read from the disk cache into memory ahead of its first instance (a process's first
// JavaScript realm: page.js_startup), its imports resolved. False when it was not (not on disk, or memory keeps no
// module): nothing is compiled. Any thread.
read_ahead :: proc(image: []byte, known: ^Digest = nil, opt: Options = {}) -> bool {
	if cache.max_bytes <= 0 { return false }
	_, polled := polled_image(image, opt)
	c, err := cache_acquire(image, known, disk_only = true, polled = polled)
	delete(err)
	if c == nil { return false }
	cache_release(c)
	return true
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
		cache.total -= victim.code_bytes + MODULE_BYTES
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
	l := c.polled ? wt.polled_linker : wt.linker
	clone: wt_linker
	shadow :: proc(clone: ^wt_linker, l: ^wt_linker, from: wt_linker) {
		if clone^ != nil { return }
		clone^ = wasmtime_linker_clone(from)
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
			shadow(&clone, &l, c.polled ? wt.polled_linker : wt.linker)
			if !define_import(clone, im, true) {
				c.link_error = fmt.aprintf("cannot link %s.%s with 64-bit addresses", mod, name)
				wasmtime_linker_delete(clone)
				return
			}
			continue
		}
		shadow(&clone, &l, c.polled ? wt.polled_linker : wt.linker)
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
// Disk (disk_cache.odin)

// A module from the disk cache, or nil (missing, refused: then the file is deleted).
@(private)
disk_load :: proc(path: string, filekey: Digest, engine: wt_engine) -> wt_module {
	data, payload := disk_read(&cache.files, path, filekey)
	if data == nil { return nil }
	defer delete(data, base.process_allocator())
	m: wt_module
	if e := wasmtime_module_deserialize(engine, raw_data(payload), len(payload), &m); e != nil {
		wasmtime_error_delete(e)
		disk_reject(&cache.files, path)
		return nil
	}
	return m
}

@(private)
disk_queue_module :: proc(path: string, filekey: Digest, m: wt_module) {
	v: wt_byte_vec
	if e := wasmtime_module_serialize(m, &v); e != nil { wasmtime_error_delete(e); return }
	payload := make([]byte, int(v.size), base.process_allocator())
	copy(payload, v.data[:v.size])
	wasm_byte_vec_delete(&v)
	disk_queue(&cache.files, path, filekey, payload)
}
