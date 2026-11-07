package blocker

import "base:intrinsics"
import "core:fmt"
import "core:math/bits"
import "core:os"
import "core:strings"
import "core:time"
import "wb:adblock"
import "wb:base"
import "wb:fetch"
import "wb:host"
import "wb:i18n"

// The engine of the lists. A job runs on a thread of its own: at start-up it maps the compiled index the profile keeps (17 to 34
// ms for the default lists) and compiles the lists only when that index is not theirs; later it compiles what changed. It reads the lists,
// validates what was downloaded and stores it, builds the index, writes it to the profile's cache with its key, and loads it. The
// loop thread only installs the result. The compiled index and the text it was made from (`.src`, for the rule lines the journal
// shows) are written under a generation number so that the engine in use is never overwritten.

BASE_LIST_TEXT :: #load("base_list.txt", string)

BASE_LIST_ID   :: u8(0)
MY_FILTERS_ID  :: u8(255)

// The real index is not there yet: only the small base list is in force. A request let through now would escape every rule of the
// lists (the first page of a session, the YouTube player data in it, loaded unfiltered), so the loader parks the requests to the
// network until the job is done, or for at most BOOT_HOLD_MS (a profile with huge lists or a slow disk must not leave the browser
// without a network). With the profile's index the job is done before the window's first frame.
BOOT_HOLD_MS :: 20_000
// How many texts of filters are kept: once past this the cache starts over.
FILTER_TEXTS_CACHE_MAX :: 20000
// A job at start-up holds the network: it runs at the priority of the browser. A later compile does not: it yields.
BOOT_JOB_PRIORITY    :: host.Thread_Priority.Normal
REBUILD_JOB_PRIORITY :: host.Thread_Priority.Below_Normal
// The files of the cache, under <profile>/blocker/cache.
CACHE_KEY_FILE :: "engine.key"
CACHE_PREFIX   :: "engine-"
// The hash of a list's text in the key (text_hash): FNV's 64-bit prime and offset, and a rotation that spreads each step's high bits down.
TEXT_HASH_PRIME  :: u64(0x100000001b3)
TEXT_HASH_OFFSET :: u64(0xcbf29ce484222325)
TEXT_HASH_ROTATE :: 29

Job_List :: struct {
	id:       string,       // owned
	lid:      u8,
	name:     string,       // owned
	path:     string,       // owned
	new_body: []byte,       // owned: a download to validate and store
	etag, last_modified: string,   // owned: what came with the download
	// results
	accepted: bool,
	error:    string,       // owned
	size:     int,
}

Job_Kind :: enum u8 {
	Boot,      // the profile's index when it is the lists', else a compile; the network waits for it (boot_hold_begin)
	Rebuild,   // a compile of what changed; the engine in force stays until it is done
}

// What a job ended with.
Job_Outcome :: enum u8 {
	Failed,     // no engine: the one in force stays (j.failed says why, when it is said)
	Loaded,     // the index the profile kept, mapped
	Compiled,   // the lists compiled now
}

Job :: struct {
	kind:       Job_Kind,
	loop:       ^host.Loop,
	dir:        string,
	persist:    bool,
	cache:      bool,
	lists:      []Job_List,
	my_filters: string,
	gen:        u64,
	thread:     ^host.Thread,
	gate:       Job_Gate,
	// results
	outcome:    Job_Outcome,
	engine:     ^adblock.Engine,
	mapping:    base.File_Map,   // the file the engine reads, when it was loaded from the cache
	src_path:   string,
	compile_ms: f64,
	failed:     string,
	user:       rawptr,     // the blocker (only compared and passed back on the loop thread)
}

// Called on the job's thread before its work: a test holds the job there to see what the browser does meanwhile. Unset in the browser.
Job_Gate :: struct {
	wait: proc(user: rawptr),
	user: rawptr,
}

////////////////////////////////
// Files

write_file_atomic :: proc(path: string, data: []byte) -> bool { return base.file_write_atomic(path, data) }

read_text :: proc(path: string, allocator := context.allocator) -> (text: []byte, ok: bool) {
	data, err := os.read_entire_file(path, allocator)
	return data, err == nil
}

// `n` bytes of a file from `offset` (short at the end of the file).
read_at :: proc(path: string, offset: i64, n: int, allocator := context.temp_allocator) -> []byte {
	buf := make([]byte, n, allocator)
	got, ok := base.file_read_at(path, offset, buf)
	if !ok { return nil }
	return buf[:got]
}

// mtime: the system's stamp (only compared with another one).
file_stat :: proc(path: string) -> (size: i64, mtime: i64, ok: bool) { return base.file_stat(path) }

////////////////////////////////
// The text of a rule

// The line of the list a filter came from, for display (cached per engine).
rule_text :: proc(b: ^Blocker, e: ^Engine_Ref, fid: u32) -> string {
	if e == nil || fid == adblock.NO_FILTER { return "" }
	if t, ok := e.texts[fid]; ok { return t }
	ref := adblock.filter_ref(e.engine, fid)
	text := ""
	if e.src_path != "" {
		for s in e.sources {
			if s.id != ref.list { continue }
			if ref.offset >= s.text_len { break }
			buf := read_at(e.src_path, i64(s.text_base) + i64(ref.offset), min(int(s.text_len - ref.offset), 1024))
			if len(buf) > 0 {
				line := string(buf)
				if nl := strings.index_byte(line, '\n'); nl >= 0 { line = line[:nl] }
				text = strings.trim_right_space(line)
			}
			break
		}
	}
	if text == "" { text = fmt.tprintf("(filter %d of %s)", fid, list_name(e, ref.list)) }
	if e.texts == nil { e.texts = make(map[u32]string) }
	if len(e.texts) > FILTER_TEXTS_CACHE_MAX {
		for _, v in e.texts { delete(v) }
		clear(&e.texts)
	}
	owned := strings.clone(text)
	e.texts[fid] = owned
	return owned
}

list_name :: proc(e: ^Engine_Ref, lid: u8) -> string {
	if e == nil { return "" }
	for s in e.sources { if s.id == lid { return s.name } }
	return ""
}

////////////////////////////////
// Boot

// The engine at start-up: the base list and the user's filters now (a few hundred rules: well under a millisecond), the index of the
// lists from a job. Nothing of the lists is read on this thread.
engine_boot :: proc(b: ^Blocker) {
	assign_list_ids(b)
	if b.persist {
		make_dirs(strings.concatenate({b.dir, "/lists"}, context.temp_allocator))
		make_dirs(strings.concatenate({b.dir, "/cache"}, context.temp_allocator))
	}
	lists := [?]adblock.List_Text{{BASE_LIST_ID, i18n.tr("Wren base list"), BASE_LIST_TEXT}, {MY_FILTERS_ID, i18n.tr("My filters"), b.conf.my_filters}}
	if blob := adblock.compile(lists[:], allocator = base.process_allocator()); blob != nil {
		if e, err := adblock.engine_load(blob, true, false, base.process_allocator()); err == .None {
			engine_install(b, make_ref(b, e, "", {}))
		}
	}
	if b.persist {
		start_job(b, nil, .Boot)
		if b.cfg.enabled && b.upd.job != nil { boot_hold_begin(b) }
	}
}

@(private)
boot_hold_begin :: proc(b: ^Blocker) {
	if b.loader == nil || b.loop == nil { return }
	fetch.hold_requests(b.loader, true)
	base.span_mark("blocker: the requests wait")
	b.hold_timer = host.set_timer(b.loop, BOOT_HOLD_MS, 0, boot_hold_timeout, b)
}

@(private)
boot_hold_timeout :: proc(data: rawptr) {
	b := (^Blocker)(data)
	b.hold_timer = base.NIL_HANDLE
	boot_hold_end(b)
}

@(private)
boot_hold_end :: proc(b: ^Blocker) {
	if b.hold_timer != base.NIL_HANDLE { host.clear_timer(b.loop, b.hold_timer); b.hold_timer = base.NIL_HANDLE }
	if b.loader != nil && b.loader.hold { fetch.hold_requests(b.loader, false); base.span_mark("blocker: the requests go") }
}

@(private)
make_ref :: proc(b: ^Blocker, e: ^adblock.Engine, src_path: string, mapping: base.File_Map) -> ^Engine_Ref {
	r := new(Engine_Ref)
	r.engine = e
	r.mapping = mapping
	r.src_path = strings.clone(src_path)
	r.sources = adblock.engine_sources(e)
	r.texts = make(map[u32]string)
	for s in r.sources { r.rules += int(s.net + s.cosmetic) }
	return r
}

@(private)
assign_list_ids :: proc(b: ^Blocker) {
	n := u8(1)
	for &l in b.conf.lists {
		if l.enabled { l.lid = n; n += 1 } else { l.lid = 0 }
		if n >= MY_FILTERS_ID { break }
	}
}

// What each list contributed, from the engine's table, into the configuration shown by the dashboard.
apply_source_stats :: proc(b: ^Blocker, ref: ^Engine_Ref) {
	for &l in b.conf.lists {
		if !l.enabled || l.lid == 0 { continue }
		for s in ref.sources {
			if s.id == l.lid { l.rules = int(s.net + s.cosmetic); l.invalid = int(s.invalid); break }
		}
	}
}

////////////////////////////////
// The key of the cache (on the job's thread)

// engine.key, three lines: the generation; what the index was made from (the index format, the base list, the user's filters, and of
// each list in force its size and a hash of its text); the size and time of each list's file then. The third line is the quick check: a
// list whose file has another time (a profile copied or restored, a backup) is hashed again, and the index is still its own when the
// text is the same.

@(private)
key_head :: proc(j: ^Job) -> string {
	return fmt.tprintf("v%d|base%d|my%d:%d|", adblock.VERSION, len(BASE_LIST_TEXT), len(j.my_filters), adblock.hash_str(j.my_filters))
}

@(private)
key_digest :: proc(sb: ^strings.Builder, id: string, text: []byte) {
	fmt.sbprintf(sb, "%s:%d:%x|", id, len(text), text_hash(text))
}

// Whether a file still holds the text an index was made from: 8 bytes a step (22 MB in a few ms), not a defence against anyone.
text_hash :: proc "contextless" (data: []byte) -> u64 {
	h := TEXT_HASH_OFFSET ~ u64(len(data))
	i := 0
	for ; i + 8 <= len(data); i += 8 {
		h = bits.rotate_left64((h ~ intrinsics.unaligned_load((^u64)(&data[i]))) * TEXT_HASH_PRIME, TEXT_HASH_ROTATE)
	}
	for ; i < len(data); i += 1 { h = (h ~ u64(data[i])) * TEXT_HASH_PRIME }
	return h
}

// The lists' line read from their files (a list in force that is not there yet is an empty text).
@(private)
key_from_files :: proc(j: ^Job) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, key_head(j))
	for l in j.lists {
		if l.lid == 0 { continue }
		text, _ := read_text(l.path, context.temp_allocator)
		key_digest(&sb, l.id, text)
	}
	return strings.to_string(sb)
}

@(private)
key_stamps :: proc(j: ^Job) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for l in j.lists {
		if l.lid == 0 { continue }
		size, mtime, ok := file_stat(l.path)
		if !ok { size, mtime = -1, 0 }
		fmt.sbprintf(&sb, "%s:%d:%d|", l.id, size, mtime)
	}
	return strings.to_string(sb)
}

@(private)
key_write :: proc(j: ^Job, gen, made_of: string) {
	content := strings.concatenate({gen, "\n", made_of, "\n", key_stamps(j)}, context.temp_allocator)
	write_file_atomic(strings.concatenate({j.dir, "/cache/", CACHE_KEY_FILE}, context.temp_allocator), transmute([]byte)content)
}

// Deletes the generations that are not `gen`. (An older one still mapped by documents that hold its engine goes when they let it go:
// the mapping shares delete.)
@(private)
cache_cleanup :: proc(dir, gen: string) {
	cache := strings.concatenate({dir, "/cache"}, context.temp_allocator)
	infos, err := os.read_all_directory_by_path(cache, context.temp_allocator)
	if err != nil { return }
	keep := strings.concatenate({CACHE_PREFIX, gen, "."}, context.temp_allocator)
	for fi in infos {
		if !strings.has_prefix(fi.name, CACHE_PREFIX) || strings.has_prefix(fi.name, keep) { continue }
		_ = os.remove(fi.fullpath)
	}
}

////////////////////////////////
// Jobs

// Asks for a new engine from the lists on disk (a list was switched, the user's filters changed).
rebuild :: proc(b: ^Blocker) {
	start_job(b, nil, .Rebuild)
}

@(private)
start_job :: proc(b: ^Blocker, downloads: []Download, kind: Job_Kind) {
	if b.upd.job != nil {
		b.upd.rebuild_pending = true
		// downloads that arrive while a job runs wait for the next one
		for d in downloads { append(&b.upd.held, d) }
		return
	}
	assign_list_ids(b)
	j := new(Job, base.process_allocator())
	j.kind = kind
	j.loop = b.loop
	j.persist = b.persist
	j.cache = b.cfg.engine_cache
	j.gate = b.job_gate
	j.dir = strings.clone(b.dir, base.process_allocator())
	j.my_filters = strings.clone(b.conf.my_filters, base.process_allocator())
	j.gen = u64(unix_ms())
	j.user = b
	lists := make([dynamic]Job_List, 0, len(b.conf.lists), base.process_allocator())
	all_downloads := make([dynamic]Download, context.temp_allocator)
	append(&all_downloads, ..b.upd.held[:])
	append(&all_downloads, ..downloads)
	clear(&b.upd.held)
	for &l in b.conf.lists {
		jl := Job_List{id = strings.clone(l.id, base.process_allocator()), lid = l.lid, name = strings.clone(l.title, base.process_allocator())}
		jl.path = strings.clone(list_path(b, l.id), base.process_allocator())
		for d in all_downloads {
			if d.id == l.id {
				jl.new_body = d.body
				jl.etag = strings.clone(d.etag, base.process_allocator())
				jl.last_modified = strings.clone(d.last_modified, base.process_allocator())
			}
		}
		if !l.enabled && jl.new_body == nil { delete(jl.id, base.process_allocator()); delete(jl.name, base.process_allocator()); delete(jl.path, base.process_allocator()); continue }
		append(&lists, jl)
		if kind == .Rebuild { l.state = .Compiling }
	}
	for d in all_downloads { delete(d.id); delete(d.etag); delete(d.last_modified) }
	j.lists = lists[:]
	b.upd.job = j
	j.thread = host.thread_start(job_thread, j, 0, kind == .Boot ? BOOT_JOB_PRIORITY : REBUILD_JOB_PRIORITY, "wren-blocker-compile")
	if j.thread == nil { job_thread(j) }
	touch(b)
}

@(private)
job_thread :: proc(data: rawptr) {
	j := (^Job)(data)
	context.allocator = base.process_allocator()
	if j.gate.wait != nil { j.gate.wait(j.gate.user) }
	t0 := time.tick_now()
	at := base.span_now()
	if j.kind == .Boot && j.persist && j.cache && job_load_cache(j) {
		base.span_add(.Off_Thread, at, "blocker: the profile's index mapped")
	} else {
		job_compile(j)
		base.span_add(.Off_Thread, at, "blocker: the lists compiled")
	}
	j.compile_ms = f64(time.tick_since(t0)) / 1e6
	host.post(j.loop, compile_done, j)
}

// The index the profile kept, when it was made from the lists in force: mapped, checked, its tables of hashes built.
@(private)
job_load_cache :: proc(j: ^Job) -> bool {
	data, ok := read_text(strings.concatenate({j.dir, "/cache/", CACHE_KEY_FILE}, context.temp_allocator), context.temp_allocator)
	if !ok { return false }
	lines := strings.split_lines(string(data), context.temp_allocator)
	if len(lines) < 3 || !strings.has_prefix(lines[1], key_head(j)) { return false }
	gen, made_of, stamps := lines[0], lines[1], lines[2]
	if stamps != key_stamps(j) {
		if made_of != key_from_files(j) { return false }
		key_write(j, gen, made_of)   // the same text under other times: the quick check passes next time
	}
	m, mapped := base.file_map(strings.concatenate({j.dir, "/cache/", CACHE_PREFIX, gen, ".bin"}, context.temp_allocator))
	if !mapped { return false }
	e, err := adblock.engine_load(m.data, false, true, base.process_allocator())
	if err != .None { base.file_unmap(&m); return false }
	j.engine, j.mapping, j.outcome = e, m, .Loaded
	j.src_path = strings.concatenate({j.dir, "/cache/", CACHE_PREFIX, gen, ".src"}, base.process_allocator())
	cache_cleanup(j.dir, gen)   // (what a compile cut short left)
	return true
}

@(private)
job_compile :: proc(j: ^Job) {
	builder: adblock.Builder
	adblock.builder_init(&builder)
	bodies := make([dynamic][]byte, context.temp_allocator)
	adblock.builder_add(&builder, BASE_LIST_ID, i18n.tr("Wren base list"), BASE_LIST_TEXT)
	made_of := strings.builder_make(context.temp_allocator)
	strings.write_string(&made_of, key_head(j))
	for &l in j.lists {
		text: string
		if l.new_body != nil {
			valid, _ := adblock.validate_list(string(l.new_body))
			if valid == 0 {
				l.error = strings.clone(i18n.tr("the answer is not a filter list"))
			} else {
				l.accepted = true
				text = string(l.new_body)
				if j.persist { write_file_atomic(l.path, l.new_body) }
			}
		}
		enabled := l.lid != 0
		if text == "" && enabled && j.persist {
			if data, ok := read_text(l.path, context.allocator); ok { append(&bodies, data); text = string(data) }
		}
		l.size = len(text)
		if enabled { key_digest(&made_of, l.id, transmute([]byte)text) }
		if enabled && text != "" { adblock.builder_add(&builder, l.lid, l.name, text) }
	}
	adblock.builder_add(&builder, MY_FILTERS_ID, i18n.tr("My filters"), j.my_filters)
	blob := adblock.builder_build(&builder, base.process_allocator())

	if j.persist && j.cache {
		cache := strings.concatenate({j.dir, "/cache"}, context.temp_allocator)
		make_dirs(cache)
		gen := fmt.tprintf("%d", j.gen)
		src_path := strings.concatenate({cache, "/", CACHE_PREFIX, gen, ".src"}, context.temp_allocator)
		// the lists' text in the order the index knows it (the builder's own order)
		all := strings.builder_make(context.temp_allocator)
		for s in adblock.builder_sources(&builder) { strings.write_string(&all, s.text) }
		if write_file_atomic(src_path, transmute([]byte)strings.to_string(all)) && write_file_atomic(strings.concatenate({cache, "/", CACHE_PREFIX, gen, ".bin"}, context.temp_allocator), blob) {
			j.src_path = strings.clone(src_path, base.process_allocator())
			key_write(j, gen, strings.to_string(made_of))
			cache_cleanup(j.dir, gen)
		}
	}
	adblock.builder_destroy(&builder)
	e, err := adblock.engine_load(blob, true, false, base.process_allocator())
	if err != .None {
		j.failed = fmt.aprintf(i18n.tr("the compiled index could not be loaded (%v)"), err, allocator = base.process_allocator())
	} else {
		j.engine, j.outcome = e, .Compiled
	}
	for d in bodies { delete(d) }
}

@(private)
compile_done :: proc(data: rawptr) {
	j := (^Job)(data)
	b := (^Blocker)(j.user)
	if b == nil || the_blocker != b || b.shutting_down {
		if j.thread != nil { host.thread_join(j.thread) }
		job_free(j)
		return
	}
	if j.thread != nil { host.thread_join(j.thread) }
	b.upd.job = nil
	defer boot_hold_end(b)   // after the engine is installed below: the requests parked since start-up go through the real rules
	now_s := unix_ms() / 1000
	for jl in j.lists {
		l := list_by_id(&b.conf, jl.id)
		if l == nil { continue }
		l.state = .Idle
		if jl.accepted {
			delete(l.etag); l.etag = strings.clone(jl.etag)
			delete(l.last_modified); l.last_modified = strings.clone(jl.last_modified)
			l.updated, l.checked = now_s, now_s
			delete(l.error); l.error = ""
		} else if jl.error != "" {
			delete(l.error); l.error = strings.clone(jl.error)
		}
		if jl.size > 0 { l.size = jl.size }
	}
	b.upd.last_outcome = j.outcome
	switch j.outcome {
	case .Loaded, .Compiled:
		ref := make_ref(b, j.engine, j.src_path, j.mapping)
		j.engine, j.mapping = nil, {}
		apply_source_stats(b, ref)
		engine_install(b, ref)
		if j.outcome == .Compiled { b.upd.last_compile_ms = j.compile_ms }
	case .Failed:
		if j.failed != "" { delete(b.upd.status); b.upd.status = strings.clone(j.failed) }
	}
	if j.outcome != .Loaded { conf_save(b) }   // (a load changed nothing the configuration says)
	job_free(j)
	if b.upd.rebuild_pending { b.upd.rebuild_pending = false; rebuild(b) }
	if b.on_event != nil { ev := Event{kind = .Lists}; b.on_event(b.event_user, &ev) }
	touch(b)
}

@(private)
job_free :: proc(j: ^Job) {
	a := base.process_allocator()
	for l in j.lists { delete(l.id, a); delete(l.name, a); delete(l.path, a); delete(l.new_body, a); delete(l.etag, a); delete(l.last_modified, a); delete(l.error, a) }
	delete(j.lists, a)
	delete(j.dir, a); delete(j.my_filters, a); delete(j.src_path, a); delete(j.failed, a)
	if j.engine != nil { adblock.engine_destroy(j.engine) }
	base.file_unmap(&j.mapping)
	free(j, a)
}
