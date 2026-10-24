package blocker

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "wb:adblock"
import "wb:base"
import "wb:fetch"
import "wb:host"
import "wb:i18n"

// Compiling the lists. A job runs on a thread of its own (named, below normal priority): it reads the lists, validates
// what was downloaded and stores it, builds the index, writes it to the profile's cache and loads it. The loop thread
// installs the result. The compiled index and the text it was made from (`.src`, for the rule lines the journal shows)
// are written under a generation number so that the engine in use is never overwritten.

BASE_LIST_TEXT :: #load("base_list.txt", string)

BASE_LIST_ID   :: u8(0)
MY_FILTERS_ID  :: u8(255)

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

Job :: struct {
	loop:       ^host.Loop,
	dir:        string,
	persist:    bool,
	cache:      bool,
	lists:      []Job_List,
	my_filters: string,
	gen:        u64,
	key:        string,
	thread:     ^host.Thread,
	// results
	engine:     ^adblock.Engine,
	src_path:   string,
	compile_ms: f64,
	failed:     string,
	user:       rawptr,     // the blocker (only compared and passed back on the loop thread)
}

////////////////////////////////
// Files

write_file_atomic :: proc(path: string, data: []byte) -> bool {
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	wtmp := win.utf8_to_wstring(tmp, context.temp_allocator)
	h := win.CreateFileW(wtmp, win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE { return false }
	off := 0
	for off < len(data) {
		n := min(len(data) - off, 1 << 24)
		written: win.DWORD
		if !win.WriteFile(h, raw_data(data[off:]), win.DWORD(n), &written, nil) || written == 0 { win.CloseHandle(h); win.DeleteFileW(wtmp); return false }
		off += int(written)
	}
	win.CloseHandle(h)
	return bool(win.MoveFileExW(wtmp, win.utf8_to_wstring(path, context.temp_allocator), win.MOVEFILE_REPLACE_EXISTING))
}

// A whole file in memory aligned to 8 bytes (an index is read in place).
read_aligned :: proc(path: string, allocator := context.allocator) -> []byte {
	h := win.CreateFileW(win.utf8_to_wstring(path, context.temp_allocator), win.GENERIC_READ, win.FILE_SHARE_READ, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE { return nil }
	defer win.CloseHandle(h)
	size: win.LARGE_INTEGER
	if !win.GetFileSizeEx(h, &size) || size <= 0 || size > 1 << 31 { return nil }
	words := make([]u64, (int(size) + 7) / 8, allocator)
	buf := ([^]byte)(raw_data(words))[:int(size)]
	off := 0
	for off < len(buf) {
		got: win.DWORD
		if !win.ReadFile(h, raw_data(buf[off:]), win.DWORD(min(len(buf) - off, 1 << 24)), &got, nil) || got == 0 { delete(words, allocator); return nil }
		off += int(got)
	}
	return buf
}

read_text :: proc(path: string, allocator := context.allocator) -> (text: []byte, ok: bool) {
	data, err := os.read_entire_file(path, allocator)
	return data, err == nil
}

// `n` bytes of a file from `offset` (short at the end of the file).
read_at :: proc(path: string, offset: i64, n: int, allocator := context.temp_allocator) -> []byte {
	h := win.CreateFileW(win.utf8_to_wstring(path, context.temp_allocator), win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE { return nil }
	defer win.CloseHandle(h)
	if !win.SetFilePointerEx(h, win.LARGE_INTEGER(offset), nil, win.FILE_BEGIN) { return nil }
	buf := make([]byte, n, allocator)
	got: win.DWORD
	if !win.ReadFile(h, raw_data(buf), win.DWORD(n), &got, nil) { return nil }
	return buf[:got]
}

file_stat :: proc(path: string) -> (size: i64, mtime: i64, ok: bool) {
	data: win.WIN32_FILE_ATTRIBUTE_DATA
	if !win.GetFileAttributesExW(win.utf8_to_wstring(path, context.temp_allocator), win.GetFileExInfoStandard, &data) { return 0, 0, false }
	size = i64(data.nFileSizeHigh) << 32 | i64(data.nFileSizeLow)
	mtime = i64(data.ftLastWriteTime.dwHighDateTime) << 32 | i64(data.ftLastWriteTime.dwLowDateTime)
	return size, mtime, true
}

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
	if len(e.texts) > 20000 {
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

// The engine at start-up: the cache when it is valid, else the base list now and the real index from a job.
engine_boot :: proc(b: ^Blocker) {
	assign_list_ids(b)
	if b.persist {
		make_dirs(strings.concatenate({b.dir, "/lists"}, context.temp_allocator))
		make_dirs(strings.concatenate({b.dir, "/cache"}, context.temp_allocator))
	}
	if b.cfg.engine_cache && b.persist && engine_load_cache(b) { cache_cleanup(b); return }
	// the base list and the user's filters right now (a few hundred rules: well under a millisecond)
	lists := [?]adblock.List_Text{{BASE_LIST_ID, i18n.tr("Wren base list"), BASE_LIST_TEXT}, {MY_FILTERS_ID, i18n.tr("My filters"), b.conf.my_filters}}
	if blob := adblock.compile(lists[:], allocator = base.process_allocator()); blob != nil {
		if e, err := adblock.engine_load(blob, true, false, base.process_allocator()); err == .None {
			engine_install(b, make_ref(b, e, ""))
		}
	}
	if b.persist {
		rebuild(b)
		if b.cfg.enabled && b.upd.job != nil { boot_hold_begin(b) }
	}
}

// The real index is not there yet (no valid cache): only the small base list is in force. A request let through now would escape every
// rule of the lists (the first page of a session, the YouTube player data in it, loaded unfiltered), so the loader parks the requests
// to the network until the compile job is done, or for at most BOOT_HOLD_MS (a profile with huge lists or a slow disk must not leave
// the browser without a network).
BOOT_HOLD_MS :: 20_000

@(private)
boot_hold_begin :: proc(b: ^Blocker) {
	if b.loader == nil || b.loop == nil { return }
	fetch.hold_requests(b.loader, true)
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
	if b.loader != nil { fetch.hold_requests(b.loader, false) }
}

@(private)
make_ref :: proc(b: ^Blocker, e: ^adblock.Engine, src_path: string) -> ^Engine_Ref {
	r := new(Engine_Ref)
	r.engine = e
	r.src_path = clone_str(src_path)
	r.sources = adblock.engine_sources(e)
	r.texts = make(map[u32]string)
	for s in r.sources { r.rules += int(s.net + s.cosmetic) }
	// the names point into the engine's blob: copy them (the ref outlives nothing, but the strings must stay valid for UI)
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

// What the cache must have been made from: the lists in force with the size and time of each file, the user's filters,
// the base list and the index format.
@(private)
cache_key :: proc(b: ^Blocker) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "v%d|base%d|my%d:%d|", adblock.VERSION, len(BASE_LIST_TEXT), len(b.conf.my_filters), adblock.hash_str(b.conf.my_filters))
	for l in b.conf.lists {
		if !l.enabled { continue }
		size, mtime, ok := file_stat(list_path(b, l.id))
		fmt.sbprintf(&sb, "%s:%d:%d:%v|", l.id, size, mtime, ok)
	}
	return strings.clone(strings.to_string(sb))
}

@(private)
engine_load_cache :: proc(b: ^Blocker) -> bool {
	kp := strings.concatenate({b.dir, "/cache/engine.key"}, context.temp_allocator)
	data, ok := read_text(kp, context.temp_allocator)
	if !ok { return false }
	lines := strings.split_lines(string(data), context.temp_allocator)
	if len(lines) < 2 { return false }
	key := cache_key(b)
	defer delete(key)
	if lines[1] != key { return false }
	gen := lines[0]
	bin := strings.concatenate({b.dir, "/cache/engine-", gen, ".bin"}, context.temp_allocator)
	blob := read_aligned(bin, base.process_allocator())
	if blob == nil { return false }
	e, err := adblock.engine_load(blob, true, true, base.process_allocator())
	if err != .None { delete(blob, base.process_allocator()); return false }
	src := strings.concatenate({b.dir, "/cache/engine-", gen, ".src"}, context.temp_allocator)
	ref := make_ref(b, e, src)
	apply_source_stats(b, ref)
	engine_install(b, ref)
	return true
}

// Deletes the generations that are not the one in force.
@(private)
cache_cleanup :: proc(b: ^Blocker) {
	if !b.persist || b.engine == nil { return }
	dir := strings.concatenate({b.dir, "/cache"}, context.temp_allocator)
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for fi in infos {
		if !strings.has_prefix(fi.name, "engine-") { continue }
		if b.engine.src_path != "" && (strings.has_suffix(b.engine.src_path, fi.name) || strings.has_suffix(strings.concatenate({b.engine.src_path[:len(b.engine.src_path) - 4], ".bin"}, context.temp_allocator), fi.name)) { continue }
		_ = os.remove(fi.fullpath)
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
// Jobs

// Asks for a new engine from the lists on disk (a list was switched, the user's filters changed).
rebuild :: proc(b: ^Blocker) {
	start_job(b, nil)
}

@(private)
start_job :: proc(b: ^Blocker, downloads: []Download) {
	if b.upd.job != nil {
		b.upd.rebuild_pending = true
		// downloads that arrive while a job runs wait for the next one
		for d in downloads { append(&b.upd.held, d) }
		return
	}
	assign_list_ids(b)
	j := new(Job, base.process_allocator())
	j.loop = b.loop
	j.persist = b.persist
	j.cache = b.cfg.engine_cache
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
		l.state = .Compiling
	}
	for d in all_downloads { delete(d.id); delete(d.etag); delete(d.last_modified) }
	j.lists = lists[:]
	j.key = ""
	b.upd.job = j
	j.thread = host.thread_start(compile_thread, j, 0, .Below_Normal, "wren-blocker-compile")
	if j.thread == nil { compile_thread(j) }
	touch(b)
}

@(private)
compile_thread :: proc(data: rawptr) {
	j := (^Job)(data)
	context.allocator = base.process_allocator()
	t0 := time.tick_now()
	builder: adblock.Builder
	adblock.builder_init(&builder)
	bodies := make([dynamic][]byte, context.temp_allocator)
	adblock.builder_add(&builder, BASE_LIST_ID, i18n.tr("Wren base list"), BASE_LIST_TEXT)
	lists_ok := 0
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
		if enabled && text != "" {
			adblock.builder_add(&builder, l.lid, l.name, text)
			lists_ok += 1
		}
	}
	adblock.builder_add(&builder, MY_FILTERS_ID, i18n.tr("My filters"), j.my_filters)
	blob := adblock.builder_build(&builder, base.process_allocator())

	if j.persist && j.cache {
		cache := strings.concatenate({j.dir, "/cache"}, context.temp_allocator)
		make_dirs(cache)
		gen := fmt.tprintf("%d", j.gen)
		src_path := strings.concatenate({cache, "/engine-", gen, ".src"}, context.temp_allocator)
		// the lists' text in the order the index knows it (the builder's own order)
		all := strings.builder_make(context.temp_allocator)
		for s in adblock.builder_sources(&builder) { strings.write_string(&all, s.text) }
		if write_file_atomic(src_path, transmute([]byte)strings.to_string(all)) && write_file_atomic(strings.concatenate({cache, "/engine-", gen, ".bin"}, context.temp_allocator), blob) {
			j.src_path = strings.clone(src_path, base.process_allocator())
			j.key = strings.clone(gen, base.process_allocator())
		}
	}
	adblock.builder_destroy(&builder)
	e, err := adblock.engine_load(blob, true, false, base.process_allocator())
	if err != .None { j.failed = fmt.aprintf(i18n.tr("the compiled index could not be loaded (%v)"), err, allocator = base.process_allocator()) } else { j.engine = e }
	for d in bodies { delete(d) }
	j.compile_ms = f64(time.tick_since(t0)) / 1e6
	host.post(j.loop, compile_done, j)
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
			delete(l.etag); l.etag = clone_str(jl.etag)
			delete(l.last_modified); l.last_modified = clone_str(jl.last_modified)
			l.updated, l.checked = now_s, now_s
			delete(l.error); l.error = ""
		} else if jl.error != "" {
			delete(l.error); l.error = strings.clone(jl.error)
		}
		if jl.size > 0 { l.size = jl.size }
	}
	if j.engine != nil {
		ref := make_ref(b, j.engine, j.src_path)
		j.engine = nil
		apply_source_stats(b, ref)
		engine_install(b, ref)
		b.upd.last_compile_ms = j.compile_ms
		if j.key != "" && b.persist {
			key := cache_key(b)
			content := strings.concatenate({j.key, "\n", key}, context.temp_allocator)
			delete(key)
			write_file_atomic(strings.concatenate({b.dir, "/cache/engine.key"}, context.temp_allocator), transmute([]byte)content)
			cache_cleanup(b)
		}
	} else if j.failed != "" {
		delete(b.upd.status); b.upd.status = strings.clone(j.failed)
	}
	conf_save(b)
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
	delete(j.dir, a); delete(j.my_filters, a); delete(j.key, a); delete(j.src_path, a); delete(j.failed, a)
	if j.engine != nil { adblock.engine_destroy(j.engine) }
	free(j, a)
}

_ :: runtime
