package page

// The File and Directory Entries API (WICG entries-api) for files and folders the user dropped (api/js_entries.widl,
// native/js/runtime/web_entries.c): item.webkitGetAsEntry() during drop gives an entry for a file item; an entry is a
// path below one dropped item (its `root`, an absolute path of this computer, and `rel`, "/" separated). Nothing is
// read before the page asks: a folder is listed one directory at a time when its reader is read, a file is looked at
// when file() is called, both on a background thread (host.run_blocking); the page gets the answer from a task.
// Paths never leave what was dropped: ".." and absolute paths are refused (SecurityError).

import "core:os"
import "core:strings"
import "core:time"
import "wb:forms"
import "wb:host"

Fs_Entry :: struct {
	root:   string,   // the dropped item (absolute path, owned)
	rel:    string,   // below it, "/" separated, "" for the item itself (owned)
	is_dir: bool,
	fs:     string,   // the file system's name (shared by the entries of one drop, owned)
}

Fs_Reader :: struct {
	dir:      Fs_Entry,       // owned strings
	listed:   bool,
	busy:     bool,
	names:    [dynamic]Fs_Listed,
	next:     int,
	batch:    [dynamic]u64,   // the entries of the last batch (released with the reader, or by the realm with their wrappers)
	owner:    u32,
}

@(private)
Fs_Listed :: struct { name: string, is_dir: bool }

@(private) FS_BATCH :: 100   // entries per readEntries() call, as Chromium

@(private)
fs_entry_free :: proc(e: ^Fs_Entry) { delete(e.root); delete(e.rel); delete(e.fs); e^ = {} }

@(private)
fs_entry_vt := Object_VTable{
	name = "FileSystemEntry",
	destroy = proc(p: ^Page, data: rawptr) {
		e := (^Fs_Entry)(data)
		fs_entry_free(e)
		free(e)
	},
}

@(private)
fs_reader_vt := Object_VTable{
	name = "FileSystemDirectoryReader",
	destroy = proc(p: ^Page, data: rawptr) {
		r := (^Fs_Reader)(data)
		fs_entry_free(&r.dir)
		for n in r.names { delete(n.name) }
		delete(r.names)
		delete(r.batch)
		free(r)
	},
}

lookup_FsEntry :: proc(c: ^Call, h: u64) -> ^Fs_Entry { return (^Fs_Entry)(object_data(c.page, h, &fs_entry_vt)) }
lookup_FsReader :: proc(c: ^Call, h: u64) -> ^Fs_Reader { return (^Fs_Reader)(object_data(c.page, h, &fs_reader_vt)) }

@(private)
fs_entry_new :: proc(p: ^Page, owner: u32, root, rel, fs: string, is_dir: bool) -> u64 {
	e := new(Fs_Entry)
	e^ = {root = strings.clone(root), rel = strings.clone(rel), is_dir = is_dir, fs = strings.clone(fs)}
	return object_create(p, &fs_entry_vt, e, owner)
}

// The path of this computer an entry stands for.
fs_entry_path :: proc(e: ^Fs_Entry, allocator := context.temp_allocator) -> string {
	if e.rel == "" { return strings.clone(e.root, allocator) }
	sep := strings.has_suffix(e.root, "\\") || strings.has_suffix(e.root, "/") ? "" : "/"
	return strings.concatenate({e.root, sep, e.rel}, allocator)
}

@(private)
root_name :: proc(root: string) -> string {
	r := strings.trim_right(root, "\\/")
	return r[strings.last_index_any(r, "\\/") + 1:]
}

DataTransfer_itemEntry :: proc(c: ^Call, dt: Api_DataTransfer, index: i32) -> (u64, Api_Error) {
	it, err := item_at(c, dt, index)
	if err != .None { return 0, err }
	if dt.data.mode == .Protected || !it.is_file || it.file.path == "" { return 0, .None }
	// one file system per drop: its name says which store it came from
	name := strings.concatenate({"wren-drop-", itoa_u64(dt.handle)}, context.temp_allocator)
	return fs_entry_new(c.page, c.owner, it.file.path, "", name, it.is_dir), .None
}

@(private)
itoa_u64 :: proc(v: u64) -> string {
	buf: [24]u8
	i := len(buf)
	x := v
	for {
		i -= 1
		buf[i] = u8('0' + x % 10)
		x /= 10
		if x == 0 { break }
	}
	return strings.clone(string(buf[i:]), context.temp_allocator)
}

FsEntry_info :: proc(c: ^Call, entry: Api_FsEntry) -> Api_FsEntryInfo { return {is_dir = entry.data.is_dir} }

FsEntry_name :: proc(c: ^Call, entry: Api_FsEntry) -> string {
	e := entry.data
	if e.rel == "" { return root_name(e.root) }
	return e.rel[strings.last_index_byte(e.rel, '/') + 1:]
}

FsEntry_fullPath :: proc(c: ^Call, entry: Api_FsEntry) -> string {
	e := entry.data
	if e.rel == "" { return strings.concatenate({"/", root_name(e.root)}, context.temp_allocator) }
	return strings.concatenate({"/", root_name(e.root), "/", e.rel}, context.temp_allocator)
}

FsEntry_filesystemName :: proc(c: ^Call, entry: Api_FsEntry) -> string { return entry.data.fs }

FsEntry_parent :: proc(c: ^Call, entry: Api_FsEntry) -> u64 {
	e := entry.data
	rel := ""
	if i := strings.last_index_byte(e.rel, '/'); i >= 0 { rel = e.rel[:i] }
	return fs_entry_new(c.page, c.owner, e.root, rel, e.fs, true)
}

FsEntry_root :: proc(c: ^Call, entry: Api_FsEntry) -> u64 {
	e := entry.data
	is_dir := true
	if info, err := os.stat(e.root, context.temp_allocator); err == nil { is_dir = info.type == .Directory }
	return fs_entry_new(c.page, c.owner, e.root, "", e.fs, is_dir)
}

// A path below `base` (entries-api "resolve a relative path"): ".", "" parts dropped, ".." refused (it would leave
// what was dropped), "/" at the start counts from the dropped item. ok = false: refused.
fs_resolve :: proc(base, path: string, allocator := context.temp_allocator) -> (string, bool) {
	parts := make([dynamic]string, context.temp_allocator)
	if !strings.has_prefix(path, "/") && base != "" {
		rest := base
		for part in strings.split_iterator(&rest, "/") { append(&parts, part) }
	}
	rest := path
	for part in strings.split_iterator(&rest, "/") {
		switch part {
		case "", ".": continue
		case "..": return "", false
		}
		if strings.contains_any(part, "\\:*?\"<>|") { return "", false }
		append(&parts, part)
	}
	return strings.join(parts[:], "/", allocator), true
}

@(private)
Fs_Job :: struct {
	page:    u64,
	promise: u64,
	owner:   u32,
	path:    string,     // owned
	// what to look at, and what was found
	kind:    enum u8 { File, Lookup, List },
	want_dir: bool,
	rel:     string,     // Lookup: the entry's path below the root (owned)
	root:    string,     // owned
	fs:      string,     // owned
	reader:  u64,
	found:   bool,
	is_dir:  bool,
	file:    forms.File,
	names:   [dynamic]Fs_Listed,
}

@(private)
fs_job_free :: proc(j: ^Fs_Job) {
	delete(j.path); delete(j.rel); delete(j.root); delete(j.fs)
	forms.file_destroy(&j.file)
	for n in j.names { delete(n.name) }
	delete(j.names)
	free(j)
}

@(private)
fs_job_start :: proc(p: ^Page, j: ^Fs_Job) {
	if p.loader == nil || p.loader.blocking == nil {
		// no background pool (tests without a loader): the same work now, its answer from a task
		fs_job_work(j)
		post_page_task(p, proc(pg: ^Page, data: rawptr) { fs_job_done_on(pg, (^Fs_Job)(data)) }, j)
		return
	}
	host.run_blocking(p.loader.blocking, fs_job_work, proc(data: rawptr) {
		j := (^Fs_Job)(data)
		fs_job_done_on(page_by_id(j.page), j)
	}, j)
}

@(private)
fs_job_work :: proc(data: rawptr) {
	j := (^Fs_Job)(data)
	switch j.kind {
	case .File, .Lookup:
		info, err := os.stat(j.path, context.temp_allocator)
		if err != nil { break }
		j.found, j.is_dir = true, info.type == .Directory
		if j.kind == .File && !j.is_dir {
			slash := strings.last_index_any(j.path, "\\/")
			j.file = forms.File{
				path = strings.clone(j.path), name = strings.clone(j.path[slash + 1:]), mime = strings.clone(mime_type_for_name(j.path)),
				size = info.size, modified_ms = f64(time.to_unix_nanoseconds(info.modification_time)) / 1e6,
			}
		}
	case .List:
		h, err := os.open(j.path)
		if err != nil { break }
		defer os.close(h)
		infos, rerr := os.read_dir(h, -1, context.temp_allocator)
		if rerr != nil { break }
		j.found = true
		for fi in infos { append(&j.names, Fs_Listed{name = strings.clone(fi.name), is_dir = fi.type == .Directory}) }
	}
	free_all(context.temp_allocator)
}

@(private)
fs_job_done_on :: proc(p: ^Page, j: ^Fs_Job) {
	defer fs_job_free(j)
	if p == nil || p.closed { return }
	switch j.kind {
	case .File:
		switch {
		case !j.found: promise_reject(p, j.promise, i64(Api_Error.Not_Found), "NotFoundError: the file is gone")
		case j.is_dir: promise_reject(p, j.promise, i64(Api_Error.Not_Found), "TypeMismatchError: the entry is a folder")
		case:
			h := local_file_object(p, j.file, j.owner)
			promise_resolve_object(p, j.promise, h)
		}
	case .Lookup:
		switch {
		case !j.found: promise_reject(p, j.promise, i64(Api_Error.Not_Found), "NotFoundError: no such file or folder")
		case j.is_dir != j.want_dir: promise_reject(p, j.promise, i64(Api_Error.Not_Found), j.want_dir ? "TypeMismatchError: it is a file" : "TypeMismatchError: it is a folder")
		case:
			h := fs_entry_new(p, j.owner, j.root, j.rel, j.fs, j.is_dir)
			promise_resolve_object(p, j.promise, h)
		}
	case .List:
		r := (^Fs_Reader)(object_data(p, j.reader, &fs_reader_vt))
		if r == nil { promise_reject(p, j.promise, i64(Api_Error.Invalid_State), "InvalidStateError: the reader is gone"); return }
		r.busy = false
		if !j.found { promise_reject(p, j.promise, i64(Api_Error.Not_Found), "NotFoundError: the folder cannot be read"); return }
		r.listed = true
		r.names, j.names = j.names, r.names
		fs_reader_batch(p, r, j.promise)
	}
}

FsEntry_file :: proc(c: ^Call, entry: Api_FsEntry) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	e := entry.data
	j := new(Fs_Job)
	j^ = {page = p.web.id, promise = pr, owner = c.owner, kind = .File, path = strings.clone(fs_entry_path(e))}
	fs_job_start(p, j)
	return pr
}

FsEntry_lookup :: proc(c: ^Call, dir: Api_FsEntry, path: string, directory: bool) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	e := dir.data
	rel, ok := fs_resolve(e.rel, path)
	if !ok { promise_reject(p, pr, i64(Api_Error.Security), "SecurityError: the path leaves what was dropped"); return pr }
	sub := Fs_Entry{root = e.root, rel = rel}
	j := new(Fs_Job)
	j^ = {page = p.web.id, promise = pr, owner = c.owner, kind = .Lookup, want_dir = directory, path = strings.clone(fs_entry_path(&sub)),
		rel = strings.clone(rel), root = strings.clone(e.root), fs = strings.clone(e.fs)}
	fs_job_start(p, j)
	return pr
}

FsEntry_createReader :: proc(c: ^Call, dir: Api_FsEntry) -> u64 {
	e := dir.data
	r := new(Fs_Reader)
	r.dir = Fs_Entry{root = strings.clone(e.root), rel = strings.clone(e.rel), is_dir = e.is_dir, fs = strings.clone(e.fs)}
	r.owner = c.owner
	return object_create(c.page, &fs_reader_vt, r, c.owner)
}

// The next batch: up to FS_BATCH entries made now from the listing, 0 at the end.
@(private)
fs_reader_batch :: proc(p: ^Page, r: ^Fs_Reader, pr: u64) {
	clear(&r.batch)
	for r.next < len(r.names) && len(r.batch) < FS_BATCH {
		n := r.names[r.next]
		r.next += 1
		rel := r.dir.rel == "" ? n.name : strings.concatenate({r.dir.rel, "/", n.name}, context.temp_allocator)
		append(&r.batch, fs_entry_new(p, r.owner, r.dir.root, rel, r.dir.fs, n.is_dir))
	}
	promise_resolve(p, pr, i64(len(r.batch)))
}

FsReader_read :: proc(c: ^Call, reader: Api_FsReader) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	r := reader.data
	if r.busy { promise_reject(p, pr, i64(Api_Error.Invalid_State), "InvalidStateError: readEntries is already running"); return pr }
	if !r.dir.is_dir { promise_reject(p, pr, i64(Api_Error.Not_Found), "TypeMismatchError: not a folder"); return pr }
	if r.listed {
		// from a task, as the first batch
		Later :: struct { reader, promise: u64 }
		l := new(Later)
		l^ = {reader.handle, pr}
		post_page_task(p, proc(pg: ^Page, data: rawptr) {
			l := (^Later)(data)
			defer free(l)
			if pg == nil { return }
			if rd := (^Fs_Reader)(object_data(pg, l.reader, &fs_reader_vt)); rd != nil { fs_reader_batch(pg, rd, l.promise) } else { promise_reject(pg, l.promise, i64(Api_Error.Invalid_State), "InvalidStateError: the reader is gone") }
		}, l)
		return pr
	}
	r.busy = true
	j := new(Fs_Job)
	j^ = {page = p.web.id, promise = pr, owner = c.owner, kind = .List, path = strings.clone(fs_entry_path(&r.dir)), reader = reader.handle}
	fs_job_start(p, j)
	return pr
}

FsReader_entry :: proc(c: ^Call, reader: Api_FsReader, index: i32) -> u64 {
	r := reader.data
	if index < 0 || int(index) >= len(r.batch) { return 0 }
	h := r.batch[index]
	r.batch[index] = 0   // (the realm owns it now)
	return h
}
