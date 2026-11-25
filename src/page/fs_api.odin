package page

// Module "fs" (api/fs.widl): file handles for the engine (native/js/odin/web_fs.odin) over fs_store.odin, in every
// realm (documents, workers): the origin private file system (navigator.storage.getDirectory), the user's files and
// folders the pickers and drops give (File System Access), their permissions, writables and sync access handles.
//
// Concurrency and I/O design:
//   * On the UI thread (`p.worker == nil`), every File System Access disk operation runs on the blocking pool
//     (`page_blocking_pool`) and settles a host Promise on `p.loop`.
//   * In-flight jobs register a cancellation cleanup on `p.scope` (`base.on_close`); closing the page marks them
//     cancelled so queued jobs skip disk I/O and completed jobs drop results (closing any newly opened handle) with
//     zero leaks and zero UAF.
//   * Worker realms (`p.worker != nil`) already run off the UI thread; synchronous FileSystemSyncAccessHandle methods
//     stay synchronous on the worker thread while Promise-returning methods settle cleanly on the worker realm.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "wb:base"
import "wb:forms"
import "wb:host"
import "wb:url"

// Blocking pool for UI-thread pages (nil for workers, which run off the UI thread on their own loop, or pool-less tests).
@(private)
page_blocking_pool :: proc(p: ^Page) -> ^host.Blocking_Pool {
	if p == nil || p.worker != nil { return nil }
	if p.loader != nil && p.loader.blocking != nil { return p.loader.blocking }
	if p.web != nil && p.web.embedder.storage != nil && p.web.embedder.storage.blocking != nil { return p.web.embedder.storage.blocking }
	return nil
}

@(private)
fs_error_info :: proc(e: Fs_Error, what: string, allocator := context.temp_allocator) -> (code: Api_Error, msg: string) {
	switch e {
	case .None:          return .None, ""
	case .Not_Found:     return .Not_Found, fmt.aprintf("%s: the entry does not exist", what, allocator = allocator)
	case .Type_Mismatch: return .Invalid_State, fmt.aprintf("TypeMismatchError: %s: the entry is of the other kind", what, allocator = allocator)
	case .Invalid_Name:  return .Type, fmt.aprintf("%s: the name is not a valid file name", what, allocator = allocator)
	case .Not_Allowed:   return .Not_Allowed, fmt.aprintf("%s: permission is not granted", what, allocator = allocator)
	case .Locked:        return .No_Modification_Allowed, fmt.aprintf("%s: the entry is in use", what, allocator = allocator)
	case .Not_Empty:     return .Invalid_Modification, fmt.aprintf("%s: the directory is not empty", what, allocator = allocator)
	case .Quota:         return .Quota, fmt.aprintf("%s: opfs.max_bytes_per_origin", what, allocator = allocator)
	case .Io:            return .Invalid_State, fmt.aprintf("%s: the file could not be accessed", what, allocator = allocator)
	case .Security:      return .Security, fmt.aprintf("SecurityError: %s", what, allocator = allocator)
	}
	return .None, ""
}

@(private)
fs_fail :: proc(c: ^Call, e: Fs_Error, what: string) -> Api_Error {
	if e == .None { return .None }
	code, msg := fs_error_info(e, what, context.temp_allocator)
	return fail(c, code, msg)
}

@(private)
fs_reject_promise :: proc(p: ^Page, pr: u64, e: Fs_Error, what: string) {
	code, msg := fs_error_info(e, what, context.temp_allocator)
	promise_reject(p, pr, i64(code), msg)
}

@(private)
fs_max_bytes :: proc(c: ^Call) -> i64 { return c.page.settings.sw.opfs_max_bytes }

////////////////////////////////
// Async disk job engine (off UI thread with scope cancellation)

@(private = "file")
Fs_Api_Job_Kind :: enum u8 {
	Opfs_Root,
	Get_Entry,
	Remove_Entry,
	List,
	Get_File,
	Open,
	Write,
	Truncate,
	Close,
}

@(private = "file")
Fs_Api_Job :: struct {
	pages:       ^Pages,
	pool:        ^host.Blocking_Pool,
	page:        u64,
	promise:     u64,
	owner:       u32,
	kind:        Fs_Api_Job_Kind,
	cleanup:     base.Cleanup_Id,
	has_cleanup: bool,
	cancelled:   b32,             // atomic: set by base.on_close(p.scope) on UI thread

	// Inputs (owned with base.process_allocator())
	dir:         string,
	key:         string,
	root:        u64,
	path:        string,
	name:        string,
	flag1:       bool,            // directory / recursive / keep / commit
	flag2:       bool,            // create / sync_handle
	open_id:     u64,
	offset:      i64,             // at / size
	max_bytes:   i64,
	data:        []byte,

	// Outputs (owned with base.process_allocator())
	err:         Fs_Error,
	result_u64:  u64,
	result_i64:  i64,
	result_str:  string,
	file:        forms.File,
}

@(private = "file")
Fs_Scope_Close :: struct {
	pages: ^Pages,
	pool:  ^host.Blocking_Pool,
	id:    u64,
}

@(private = "file")
fs_close_detached_work :: proc(data: rawptr) {
	sc := (^Fs_Scope_Close)(data)
	pa := base.process_allocator()
	prev_pages := the_pages
	the_pages = sc.pages
	prev_alloc := context.allocator
	context.allocator = pa
	_ = fs_close(sc.id, false, 0)
	context.allocator = prev_alloc
	the_pages = prev_pages
	free(sc, pa)
}

@(private = "file")
fs_close_detached :: proc(pages: ^Pages, pool: ^host.Blocking_Pool, id: u64) {
	if id == 0 || !fs_open_exists(pages, id) { return }
	pa := base.process_allocator()
	sc := new(Fs_Scope_Close, pa)
	sc^ = {pages = pages, pool = pool, id = id}
	if pool != nil {
		host.run_blocking(pool, fs_close_detached_work, nil, sc, fs_close_detached_work)
	} else {
		fs_close_detached_work(sc)
	}
}

@(private = "file")
fs_register_open_cleanup :: proc(p: ^Page, pages: ^Pages, pool: ^host.Blocking_Pool, id: u64) {
	pa := base.process_allocator()
	sc := new(Fs_Scope_Close, pa)
	sc^ = {pages = pages, pool = pool, id = id}
	base.on_close(p.scope, proc(data: rawptr) {
		sc := (^Fs_Scope_Close)(data)
		pa := base.process_allocator()
		if !fs_open_exists(sc.pages, sc.id) { free(sc, pa); return }
		if sc.pool != nil {
			host.run_blocking(sc.pool, fs_close_detached_work, nil, sc, fs_close_detached_work)
		} else {
			fs_close_detached_work(sc)
		}
	}, sc)
}

@(private = "file")
fs_api_job_free :: proc(j: ^Fs_Api_Job) {
	pa := base.process_allocator()
	delete(j.dir, pa)
	delete(j.key, pa)
	delete(j.path, pa)
	delete(j.name, pa)
	delete(j.data, pa)
	delete(j.result_str, pa)
	delete(j.file.path, pa)
	delete(j.file.name, pa)
	delete(j.file.mime, pa)
	delete(j.file.data, pa)
	free(j, pa)
}

@(private = "file")
fs_api_job_cancel :: proc(data: rawptr) {
	j := (^Fs_Api_Job)(data)
	sync.atomic_store(&j.cancelled, true)
}

@(private = "file")
fs_api_job_work :: proc(data: rawptr) {
	j := (^Fs_Api_Job)(data)
	if sync.atomic_load(&j.cancelled) { return }
	pa := base.process_allocator()
	prev_pages := the_pages
	the_pages = j.pages
	prev_alloc := context.allocator
	context.allocator = pa
	defer {
		context.allocator = prev_alloc
		the_pages = prev_pages
	}

	switch j.kind {
	case .Opfs_Root:
		id, e := fs_opfs_root(j.dir, j.key)
		j.result_u64, j.err = id, e
	case .Get_Entry:
		child, e := fs_get_entry(j.root, j.path, j.name, j.flag1, j.flag2)
		j.err = e
		if e == .None { j.result_str = strings.clone(child, pa) }
	case .Remove_Entry:
		j.err = fs_remove_entry(j.root, j.path, j.name, j.flag1)
	case .List:
		s, e := fs_list(j.root, j.path)
		j.err = e
		if e == .None { j.result_str = strings.clone(s, pa) }
	case .Get_File:
		r, ok := fs_root(j.root)
		if !ok { j.err = .Not_Found; return }
		if r.read != .Granted { j.err = .Not_Allowed; return }
		if r.kind == .Opfs {
			if ee := fs_opfs_ensure_dir(r); ee != .None { j.err = ee; return }
		}
		disk, e := fs_disk_path_safe(r, j.path)
		if e != .None { j.err = e; return }
		if r.kind == .Local && strings.trim(j.path, "/") != "" && fs_is_symlink(disk) { j.err = .Security; return }
		f, found := local_file_from_path(disk, pa)
		if !found { j.err = .Not_Found; return }
		// its name is the entry's (an origin private file system's file is stored under an encoded name)
		if j.path != "" {
			delete(f.name, pa)
			f.name = strings.clone(j.path[strings.last_index_byte(j.path, '/') + 1:], pa)
		}
		j.file = f
	case .Open:
		id, e := fs_open(j.root, j.path, j.flag1, j.flag2)
		if e == .None && sync.atomic_load(&j.cancelled) {
			_ = fs_close(id, false, 0)
			return
		}
		j.result_u64, j.err = id, e
	case .Write:
		n, e := fs_write(j.open_id, j.offset, j.data, j.max_bytes)
		j.result_i64, j.err = i64(n), e
	case .Truncate:
		j.err = fs_truncate(j.open_id, j.offset, j.max_bytes)
	case .Close:
		j.err = fs_close(j.open_id, j.flag1, j.max_bytes)
	}
}

@(private = "file")
fs_api_job_settle :: proc(pg: ^Page, j: ^Fs_Api_Job) {
	defer fs_api_job_free(j)
	cancelled := sync.atomic_load(&j.cancelled)
	if pg != nil && !pg.closed && !cancelled && j.has_cleanup {
		base.forget_cleanup(pg.scope, j.cleanup)
		j.has_cleanup = false
	}
	if pg == nil || pg.closed || cancelled {
		if j.kind == .Open && j.err == .None && j.result_u64 != 0 {
			fs_close_detached(j.pages, j.pool, j.result_u64)
		}
		return
	}
	switch j.kind {
	case .Opfs_Root:
		if j.err == .Security {
			promise_reject(pg, j.promise, i64(Api_Error.Security), "SecurityError: this profile keeps no files (no profile folder)")
			return
		}
		if j.err != .None { fs_reject_promise(pg, j.promise, j.err, "getDirectory"); return }
		promise_resolve(pg, j.promise, i64(j.result_u64))
	case .Get_Entry:
		if j.err != .None { fs_reject_promise(pg, j.promise, j.err, j.flag1 ? "getDirectoryHandle" : "getFileHandle"); return }
		promise_resolve(pg, j.promise, 0, j.result_str)
	case .Remove_Entry:
		if j.err != .None { fs_reject_promise(pg, j.promise, j.err, "removeEntry"); return }
		promise_resolve(pg, j.promise, 0)
	case .List:
		if j.err != .None { fs_reject_promise(pg, j.promise, j.err, "entries"); return }
		promise_resolve(pg, j.promise, 0, j.result_str)
	case .Get_File:
		if j.err != .None { fs_reject_promise(pg, j.promise, j.err, "getFile"); return }
		h := local_file_object(pg, j.file, j.owner)
		promise_resolve_object(pg, j.promise, h)
	case .Open:
		if j.err != .None { fs_reject_promise(pg, j.promise, j.err, j.flag2 ? "createSyncAccessHandle" : "createWritable"); return }
		fs_register_open_cleanup(pg, j.pages, j.pool, j.result_u64)
		promise_resolve(pg, j.promise, i64(j.result_u64))
	case .Write:
		if j.err != .None { fs_reject_promise(pg, j.promise, j.err, "write"); return }
		promise_resolve(pg, j.promise, j.result_i64)
	case .Truncate:
		if j.err != .None { fs_reject_promise(pg, j.promise, j.err, "truncate"); return }
		promise_resolve(pg, j.promise, 0)
	case .Close:
		if j.err != .None { fs_reject_promise(pg, j.promise, j.err, "close"); return }
		promise_resolve(pg, j.promise, 0)
	}
}

@(private = "file")
fs_api_job_done :: proc(data: rawptr) {
	j := (^Fs_Api_Job)(data)
	pg := sync.atomic_load(&j.cancelled) ? nil : page_by_id(j.page)
	fs_api_job_settle(pg, j)
}

@(private = "file")
fs_api_job_discard :: proc(data: rawptr) {
	j := (^Fs_Api_Job)(data)
	if !sync.atomic_load(&j.cancelled) && j.has_cleanup {
		if pg := page_by_id(j.page); pg != nil && !pg.closed {
			base.forget_cleanup(pg.scope, j.cleanup)
		}
	}
	fs_api_job_free(j)
}

@(private = "file")
fs_api_job_start :: proc(c: ^Call, j: ^Fs_Api_Job) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	pool := page_blocking_pool(p)
	j.pages = the_pages
	j.pool = pool
	j.page = page_id(p)
	j.promise = pr
	j.owner = c.owner

	if pool != nil && p.web != nil && p.web.id != 0 {
		j.cleanup = base.on_close(p.scope, fs_api_job_cancel, j)
		j.has_cleanup = true
		host.run_blocking(pool, fs_api_job_work, fs_api_job_done, j, fs_api_job_discard)
		return pr
	}

	// Worker realm (already off UI thread) or pool-less unit test.
	fs_api_job_work(j)
	if p.worker != nil || p.loop == nil {
		fs_api_job_settle(p, j)
	} else {
		post_page_task(p, proc(pg: ^Page, data: rawptr) { fs_api_job_settle(pg, (^Fs_Api_Job)(data)) }, j)
	}
	return pr
}

////////////////////////////////
// Module "fs" host imports

Fs_opfsRoot :: proc(c: ^Call, bucket: string) -> (u64, Api_Error) {
	p := c.page
	if !p.env.secure_context { return 0, fail(c, .Security, "SecurityError: the file system needs a secure context") }
	if p.env.origin.opaque { return 0, fail(c, .Security, "SecurityError: an opaque origin has no file system") }
	sm := p.web.embedder.storage
	dir := sm != nil && sm.ready ? sm.dir : ""
	key := p.worker != nil ? p.worker.storage_key : storage_origin_key(p)
	if bucket != "" {
		// a bucket's own file system (storage_buckets.odin: its key, estimated and deleted with it)
		if sm == nil || !bucket_exists(sm, key, bucket) { return 0, fail(c, .Invalid_State, "InvalidStateError: the bucket was deleted") }
		key = bucket_key(key, bucket)
	}
	if dir == "" { return 0, fail(c, .Security, "SecurityError: this profile keeps no files (no profile folder)") }
	pa := base.process_allocator()
	j := new(Fs_Api_Job, pa)
	j.kind = .Opfs_Root
	j.dir = strings.clone(dir, pa)
	j.key = strings.clone(key, pa)
	return fs_api_job_start(c, j), .None
}

Fs_getEntry :: proc(c: ^Call, root: u64, path, name: string, directory, create: bool) -> (u64, Api_Error) {
	pa := base.process_allocator()
	j := new(Fs_Api_Job, pa)
	j.kind = .Get_Entry
	j.root = root
	j.path = strings.clone(path, pa)
	j.name = strings.clone(name, pa)
	j.flag1 = directory
	j.flag2 = create
	return fs_api_job_start(c, j), .None
}

Fs_removeEntry :: proc(c: ^Call, root: u64, path, name: string, recursive: bool) -> (u64, Api_Error) {
	pa := base.process_allocator()
	j := new(Fs_Api_Job, pa)
	j.kind = .Remove_Entry
	j.root = root
	j.path = strings.clone(path, pa)
	j.name = strings.clone(name, pa)
	j.flag1 = recursive
	return fs_api_job_start(c, j), .None
}

Fs_list :: proc(c: ^Call, root: u64, path: string) -> (u64, Api_Error) {
	pa := base.process_allocator()
	j := new(Fs_Api_Job, pa)
	j.kind = .List
	j.root = root
	j.path = strings.clone(path, pa)
	return fs_api_job_start(c, j), .None
}

Fs_resolve :: proc(c: ^Call, root: u64, path: string, root2: u64, path2: string) -> (string, Api_Error) {
	s, ok := fsh_resolve(root, path, root2, path2)
	if !ok { return "", .Not_Found }
	return s, .None
}

Fs_same :: proc(c: ^Call, root: u64, path: string, root2: u64, path2: string) -> bool { return fs_same(root, path, root2, path2) }

// getFile(): a File of the entry as it is now (read when the page reads it; NotReadableError once it changed).
Fs_getFile :: proc(c: ^Call, root: u64, path: string) -> (u64, Api_Error) {
	pa := base.process_allocator()
	j := new(Fs_Api_Job, pa)
	j.kind = .Get_File
	j.root = root
	j.path = strings.clone(path, pa)
	return fs_api_job_start(c, j), .None
}

// createWritable / createSyncAccessHandle: an open entry, closed when the realm goes if the page does not close it.
Fs_open :: proc(c: ^Call, root: u64, path: string, keep, sync_handle: bool) -> (u64, Api_Error) {
	pa := base.process_allocator()
	j := new(Fs_Api_Job, pa)
	j.kind = .Open
	j.root = root
	j.path = strings.clone(path, pa)
	j.flag1 = keep
	j.flag2 = sync_handle
	return fs_api_job_start(c, j), .None
}

// Synchronous FileSystemSyncAccessHandle operations (dedicated worker thread).
Fs_write :: proc(c: ^Call, id: u64, at: i64, data: []u8) -> (i64, Api_Error) {
	n, e := fs_write(id, at, data, fs_max_bytes(c))
	if e != .None { return 0, fs_fail(c, e, "write") }
	return i64(n), .None
}

Fs_read :: proc(c: ^Call, id: u64, at: i64, into: []u8) -> (i64, Api_Error) {
	n, e := fs_read(id, at, into)
	if e != .None { return 0, fs_fail(c, e, "read") }
	return i64(n), .None
}

Fs_seek :: proc(c: ^Call, id: u64, position: i64) -> Api_Error { return fs_fail(c, fs_seek(id, position), "seek") }
Fs_truncate :: proc(c: ^Call, id: u64, size: i64) -> Api_Error { return fs_fail(c, fs_truncate(id, size, fs_max_bytes(c)), "truncate") }
Fs_flush :: proc(c: ^Call, id: u64) -> Api_Error { return fs_fail(c, fs_flush(id), "flush") }

Fs_size :: proc(c: ^Call, id: u64) -> (i64, Api_Error) {
	n, e := fs_size(id)
	if e != .None { return 0, fs_fail(c, e, "getSize") }
	return n, .None
}

Fs_close :: proc(c: ^Call, id: u64, commit: bool) -> Api_Error { return fs_fail(c, fs_close(id, commit, fs_max_bytes(c)), "close") }

// Asynchronous FileSystemWritableFileStream operations (off the UI thread).
Fs_writeAsync :: proc(c: ^Call, id: u64, at: i64, data: []u8) -> (u64, Api_Error) {
	pa := base.process_allocator()
	j := new(Fs_Api_Job, pa)
	j.kind = .Write
	j.open_id = id
	j.offset = at
	j.max_bytes = fs_max_bytes(c)
	if len(data) > 0 { j.data = slice.clone(data, pa) }
	return fs_api_job_start(c, j), .None
}

Fs_truncateAsync :: proc(c: ^Call, id: u64, size: i64) -> (u64, Api_Error) {
	pa := base.process_allocator()
	j := new(Fs_Api_Job, pa)
	j.kind = .Truncate
	j.open_id = id
	j.offset = size
	j.max_bytes = fs_max_bytes(c)
	return fs_api_job_start(c, j), .None
}

Fs_closeAsync :: proc(c: ^Call, id: u64, commit: bool) -> (u64, Api_Error) {
	pa := base.process_allocator()
	j := new(Fs_Api_Job, pa)
	j.kind = .Close
	j.open_id = id
	j.flag1 = commit
	j.max_bytes = fs_max_bytes(c)
	return fs_api_job_start(c, j), .None
}

// queryPermission: 0 granted, 1 prompt, 2 denied.
Fs_permission :: proc(c: ^Call, root: u64, write: bool) -> i32 {
	r, ok := fs_root(root)
	if !ok { return 2 }
	return i32(write ? r.write : r.read)
}

// A root as structuredClone keeps it: "o" (the realm's origin private file system; "o TAB bucket" a bucket's) or "l", the origin, the folder.
Fs_describe :: proc(c: ^Call, root: u64) -> string {
	r, ok := fs_root(root)
	if !ok { return "" }
	if r.kind == .Opfs {
		// (a storage bucket's: its name follows; storage_buckets.odin bucket_key)
		if i := strings.index(r.key, "\x00bucket="); i >= 0 { return fmt.tprintf("o\t%s", r.key[i + 8:]) }
		return "o"
	}
	return fmt.tprintf("l\t%s\t%s", r.key, r.dir)
}

// The root a description stands for in this realm: the realm's own origin private file system, or a folder of the
// user's disk given to this origin (its grants of this session, else "prompt"). Pure in-memory (no disk I/O).
Fs_restore :: proc(c: ^Call, desc: string) -> (u64, Api_Error) {
	if desc == "o" || strings.has_prefix(desc, "o\t") {
		bucket := desc == "o" ? "" : desc[2:]
		p := c.page
		if !p.env.secure_context { return 0, fail(c, .Security, "SecurityError: the file system needs a secure context") }
		if p.env.origin.opaque { return 0, fail(c, .Security, "SecurityError: an opaque origin has no file system") }
		sm := p.web.embedder.storage
		dir := sm != nil && sm.ready ? sm.dir : ""
		key := p.worker != nil ? p.worker.storage_key : storage_origin_key(p)
		if bucket != "" {
			if sm == nil || !bucket_exists(sm, key, bucket) { return 0, fail(c, .Invalid_State, "InvalidStateError: the bucket was deleted") }
			key = bucket_key(key, bucket)
		}
		id, e := fs_opfs_root_register(dir, key)
		if e == .Security { return 0, fail(c, .Security, "SecurityError: this profile keeps no files (no profile folder)") }
		if e != .None { return 0, fs_fail(c, e, "getDirectory") }
		return id, .None
	}
	f := strings.split(desc, "\t", context.temp_allocator)
	if len(f) != 3 || f[0] != "l" { return 0, fail(c, .Data_Clone, "DataCloneError: not a file handle") }
	origin := url.origin_serialize(c.page.env.origin, context.temp_allocator)
	if f[1] != origin { return 0, fail(c, .Data_Clone, "DataCloneError: a handle of another origin") }
	return fs_local_root(origin, f[2], .Prompt, .Prompt), .None
}

// A handle of a file or folder the user gave (a picker, a drop): "root TAB path TAB kind (f or d) TAB name".
@(private)
fs_given_handle :: proc(p: ^Page, disk_path: string, directory: bool, write: bool, b: ^strings.Builder) {
	origin := url.origin_serialize(p.env.origin, context.temp_allocator)
	clean, _ := strings.replace_all(disk_path, "\\", "/", context.temp_allocator)
	clean = strings.trim_right(clean, "/")
	if directory {
		root := fs_local_root(origin, clean, .Granted, write ? .Granted : .Prompt)
		name := clean[strings.last_index_byte(clean, '/') + 1:]
		fmt.sbprintf(b, "%d\t\td\t%s\n", root, name)
		return
	}
	slash := strings.last_index_byte(clean, '/')
	dir, name := clean[:max(slash, 0)], clean[slash + 1:]
	root := fs_local_root(origin, dir, .Granted, write ? .Granted : .Prompt)
	fmt.sbprintf(b, "%d\t%s\tf\t%s\n", root, name, name)
}

////////////////////////////////
// Pickers and permission prompts (the shell's: browser/fs_shell.odin)

Fs_Picker_Kind :: enum i32 { Open, Save, Directory }

Fs_Pick_Filter :: struct { name: string, patterns: []string }   // "*.png"

// A picker the page asked for (owned by the page package; the shell reads it and answers fs_pick_done).
Fs_Pick :: struct {
	page:        u64,
	promise:     u64,
	kind:        Fs_Picker_Kind,
	filters:     [dynamic]Fs_Pick_Filter,
	all_files:   bool,
	multiple:    bool,
	suggested:   string,
	start_dir:   string,       // a folder of a handle given as startIn ("" : none)
	start_known: string,       // "desktop", "documents", "downloads", "music", "pictures", "videos" ("" : none)
	id:          string,       // the page's id of the picker (the system remembers its last folder per origin and id)
	readwrite:   bool,
}

// A permission the page asks for (requestPermission).
Fs_Ask :: struct {
	page:    u64,
	promise: u64,
	root:    u64,
	write:   bool,
	what:    string,   // the folder or file, as the prompt names it
	origin:  string,
}

Fs_Embedder :: struct {
	pick: proc(user: rawptr, p: ^Page, req: ^Fs_Pick),   // shows the system's dialog; fs_pick_done(req, ...) later
	ask:  proc(user: rawptr, p: ^Page, req: ^Fs_Ask),    // asks the user; fs_ask_done(req, granted) later
	user: rawptr,
}

@(private)
fs_pick_free :: proc(r: ^Fs_Pick) {
	pa := base.process_allocator()
	for f in r.filters { delete(f.name, pa); for x in f.patterns { delete(x, pa) }; delete(f.patterns, pa) }
	delete(r.filters); delete(r.suggested, pa); delete(r.start_dir, pa); delete(r.start_known, pa); delete(r.id, pa)
	free(r, pa)
}

@(private = "file")
Fs_Pick_Start_Job :: struct {
	pages:       ^Pages,
	req:         ^Fs_Pick,
	start_root:  u64,
	start_path:  string,
	cleanup:     base.Cleanup_Id,
	has_cleanup: bool,
	cancelled:   b32,
}

@(private = "file")
fs_pick_start_job_free :: proc(j: ^Fs_Pick_Start_Job, free_req: bool) {
	pa := base.process_allocator()
	if free_req && j.req != nil { fs_pick_free(j.req) }
	delete(j.start_path, pa)
	free(j, pa)
}

@(private = "file")
fs_pick_start_work :: proc(data: rawptr) {
	j := (^Fs_Pick_Start_Job)(data)
	if sync.atomic_load(&j.cancelled) { return }
	pa := base.process_allocator()
	prev_pages := the_pages
	the_pages = j.pages
	prev_alloc := context.allocator
	context.allocator = pa
	defer {
		context.allocator = prev_alloc
		the_pages = prev_pages
	}
	if r, ok := fs_root(j.start_root); ok {
		if d, e := fs_disk_path_safe(r, j.start_path); e == .None { j.req.start_dir = strings.clone(d, pa) }
		if is_dir, e := fs_kind(j.start_root, j.start_path); e == .None && !is_dir && j.req.start_dir != "" {
			// a file as startIn: its folder
			d := j.req.start_dir
			j.req.start_dir = strings.clone(d[:max(strings.last_index_byte(d, '/'), 0)], pa)
			delete(d, pa)
		}
	}
}

@(private = "file")
fs_pick_start_done :: proc(data: rawptr) {
	j := (^Fs_Pick_Start_Job)(data)
	cancelled := sync.atomic_load(&j.cancelled)
	p := cancelled ? nil : page_by_id(j.req.page)
	if p != nil && !p.closed && j.has_cleanup {
		base.forget_cleanup(p.scope, j.cleanup)
		j.has_cleanup = false
	}
	if p == nil || p.closed || cancelled || the_pages.fs_embedder.pick == nil {
		fs_pick_start_job_free(j, true)
		return
	}
	req := j.req
	j.req = nil
	fs_pick_start_job_free(j, false)
	the_pages.fs_embedder.pick(the_pages.fs_embedder.user, p, req)
}

@(private = "file")
fs_pick_start_discard :: proc(data: rawptr) {
	j := (^Fs_Pick_Start_Job)(data)
	if !sync.atomic_load(&j.cancelled) && j.has_cleanup {
		if p := page_by_id(j.req.page); p != nil && !p.closed {
			base.forget_cleanup(p.scope, j.cleanup)
		}
	}
	fs_pick_start_job_free(j, true)
}

// showOpenFilePicker / showSaveFilePicker / showDirectoryPicker: a promise of the chosen handles' descriptions
// (fs_given_handle lines); AbortError when the user cancels. `types`: one line per accepted type, "description TAB
// pattern TAB pattern...". Security without transient activation (file_system.user_activation_ms) or in a frame of
// another origin; Not_Supported when the shell has no pickers.
Fs_showPicker :: proc(c: ^Call, kind: i32, types: string, multiple, exclude_all: bool, suggested, start_in: string, start_root: u64, start_path, id: string, readwrite: bool) -> (u64, Api_Error) {
	p := c.page
	if p.worker != nil { return 0, fail(c, .Not_Supported, "NotSupportedError: pickers are a document's") }
	if !p.settings.sw.fs_pickers || the_pages.fs_embedder.pick == nil { return 0, fail(c, .Not_Supported, "NotSupportedError: file pickers are disabled (file_system.pickers)") }
	if top := page_top(p); top != p && !url.same_origin(top.env.origin, p.env.origin) { return 0, fail(c, .Security, "SecurityError: a cross-origin frame cannot show a file picker") }
	age, had := activation_age_ns(p)
	if !had || age > i64(p.settings.sw.fs_activation_ms) * 1_000_000 { return 0, fail(c, .Security, "SecurityError: a file picker needs a user gesture (transient activation)") }
	pa := base.process_allocator()
	req := new(Fs_Pick, pa)
	req.page, req.kind, req.multiple, req.all_files, req.readwrite = page_id(p), Fs_Picker_Kind(kind), multiple, !exclude_all, readwrite || kind == 1
	req.suggested, req.start_known, req.id = strings.clone(suggested, pa), strings.clone(start_in, pa), strings.clone(id, pa)
	req.filters = make([dynamic]Fs_Pick_Filter, pa)
	rest := types
	for line in strings.split_lines_iterator(&rest) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 2 { continue }
		pats := make([dynamic]string, pa)
		for x in f[1:] { if x != "" { append(&pats, strings.clone(x, pa)) } }
		append(&req.filters, Fs_Pick_Filter{name = strings.clone(f[0], pa), patterns = pats[:]})
	}
	req.promise = promise_create(p, c.owner)
	pr := req.promise
	if start_root != 0 {
		if pool := page_blocking_pool(p); pool != nil && p.web != nil && p.web.id != 0 {
			j := new(Fs_Pick_Start_Job, pa)
			j^ = {pages = the_pages, req = req, start_root = start_root, start_path = strings.clone(start_path, pa)}
			j.cleanup = base.on_close(p.scope, proc(d: rawptr) { sync.atomic_store(&(^Fs_Pick_Start_Job)(d).cancelled, true) }, j)
			j.has_cleanup = true
			host.run_blocking(pool, fs_pick_start_work, fs_pick_start_done, j, fs_pick_start_discard)
			return pr, .None
		}
		if r, ok := fs_root(start_root); ok {
			if d, e := fs_disk_path_safe(r, start_path); e == .None { req.start_dir = strings.clone(d, pa) }
			if is_dir, e := fs_kind(start_root, start_path); e == .None && !is_dir && req.start_dir != "" {
				d := req.start_dir
				req.start_dir = strings.clone(d[:max(strings.last_index_byte(d, '/'), 0)], pa)
				delete(d, pa)
			}
		}
	}
	the_pages.fs_embedder.pick(the_pages.fs_embedder.user, p, req)
	return pr, .None
}

@(private = "file")
Fs_Save_Create_Job :: struct {
	page:        u64,
	promise:     u64,
	readwrite:   bool,
	paths:       []string,
	cleanup:     base.Cleanup_Id,
	has_cleanup: bool,
	cancelled:   b32,
}

@(private = "file")
fs_save_create_job_free :: proc(j: ^Fs_Save_Create_Job) {
	pa := base.process_allocator()
	for s in j.paths { delete(s, pa) }
	delete(j.paths, pa)
	free(j, pa)
}

@(private = "file")
fs_save_create_work :: proc(data: rawptr) {
	j := (^Fs_Save_Create_Job)(data)
	if sync.atomic_load(&j.cancelled) { return }
	for path in j.paths {
		if !os_exists(path) { _ = os_write_empty(path) }
	}
}

@(private = "file")
fs_save_create_done :: proc(data: rawptr) {
	j := (^Fs_Save_Create_Job)(data)
	defer fs_save_create_job_free(j)
	cancelled := sync.atomic_load(&j.cancelled)
	p := cancelled ? nil : page_by_id(j.page)
	if p != nil && !p.closed && j.has_cleanup {
		base.forget_cleanup(p.scope, j.cleanup)
		j.has_cleanup = false
	}
	if p == nil || p.closed || cancelled { return }
	b := strings.builder_make(context.temp_allocator)
	for path in j.paths { fs_given_handle(p, path, false, j.readwrite, &b) }
	promise_resolve(p, j.promise, i64(len(j.paths)), strings.to_string(b))
}

@(private = "file")
fs_save_create_discard :: proc(data: rawptr) {
	j := (^Fs_Save_Create_Job)(data)
	if !sync.atomic_load(&j.cancelled) && j.has_cleanup {
		if p := page_by_id(j.page); p != nil && !p.closed {
			base.forget_cleanup(p.scope, j.cleanup)
		}
	}
	fs_save_create_job_free(j)
}

// The shell's answer to a picker: the chosen paths (none: cancelled).
fs_pick_done :: proc(req: ^Fs_Pick, paths: []string) {
	defer fs_pick_free(req)
	p := page_by_id(req.page)
	if p == nil || p.closed { return }
	if len(paths) == 0 { promise_reject(p, req.promise, i64(Api_Error.Abort), "AbortError: the user cancelled the picker"); return }
	if req.kind == .Save {
		if pool := page_blocking_pool(p); pool != nil {
			pa := base.process_allocator()
			j := new(Fs_Save_Create_Job, pa)
			j.page, j.promise, j.readwrite = req.page, req.promise, req.readwrite
			j.paths = make([]string, len(paths), pa)
			for s, i in paths { j.paths[i] = strings.clone(s, pa) }
			j.cleanup = base.on_close(p.scope, proc(d: rawptr) { sync.atomic_store(&(^Fs_Save_Create_Job)(d).cancelled, true) }, j)
			j.has_cleanup = true
			host.run_blocking(pool, fs_save_create_work, fs_save_create_done, j, fs_save_create_discard)
			return
		}
	}
	b := strings.builder_make(context.temp_allocator)
	for path in paths {
		if req.kind == .Save {
			// the file the user named exists from now on (empty when new: the page writes it)
			if !os_exists(path) { _ = os_write_empty(path) }
		}
		fs_given_handle(p, path, req.kind == .Directory, req.readwrite, &b)
	}
	promise_resolve(p, req.promise, i64(len(paths)), strings.to_string(b))
}

// requestPermission({mode}): granted at once when it is, denied when it was, else the user is asked
// (file_system.write_permission: "ask", "allow" or "deny"). A promise of 0 granted / 2 denied.
Fs_requestPermission :: proc(c: ^Call, root: u64, write: bool) -> (u64, Api_Error) {
	p := c.page
	r, ok := fs_root(root)
	if !ok { return 0, fs_fail(c, .Not_Found, "requestPermission") }
	pr := promise_create(p, c.owner)
	state := write ? r.write : r.read
	// (a worker cannot ask: its copy of the settings does not even keep this preference's text)
	if state != .Prompt || r.kind == .Opfs || p.worker != nil { promise_resolve(p, pr, i64(state)); return pr, .None }
	switch p.settings.sw.fs_permission {
	case "allow": fs_set_permission(root, write, .Granted); promise_resolve(p, pr, 0); return pr, .None
	case "deny": promise_resolve(p, pr, 2); return pr, .None
	}
	age, had := activation_age_ns(p)
	if the_pages.fs_embedder.ask == nil || !had || age > i64(p.settings.sw.fs_activation_ms) * 1_000_000 {
		// (no prompt without a user gesture: the state stays what it is)
		promise_resolve(p, pr, i64(state))
		return pr, .None
	}
	req := new(Fs_Ask)
	req^ = Fs_Ask{page = page_id(p), promise = pr, root = root, write = write, what = strings.clone(r.dir), origin = strings.clone(url.origin_serialize(p.env.origin, context.temp_allocator))}
	the_pages.fs_embedder.ask(the_pages.fs_embedder.user, p, req)
	return pr, .None
}

fs_ask_done :: proc(req: ^Fs_Ask, granted: bool) {
	defer { delete(req.what); delete(req.origin); free(req) }
	fs_set_permission(req.root, req.write, granted ? .Granted : .Denied)
	if p := page_by_id(req.page); p != nil && !p.closed { promise_resolve(p, req.promise, granted ? 0 : 2) }
}

// The page's origin as text (temporary).
page_origin :: proc(p: ^Page) -> string { return url.origin_serialize(p.env.origin, context.temp_allocator) }

@(private)
os_exists :: proc(path: string) -> bool { return os.exists(path) }

@(private)
os_write_empty :: proc(path: string) -> bool { return os.write_entire_file(path, nil) == nil }

_ :: forms.File
