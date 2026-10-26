package page

// Module "fs" (api/fs.widl): file handles for the engine (native/js/runtime/web_fs.c) over fs_store.odin, in every
// realm (documents, workers): the origin private file system (navigator.storage.getDirectory), the user's files and
// folders the pickers and drops give (File System Access), their permissions, writables and sync access handles.

import "core:fmt"
import "core:os"
import "core:strings"
import "wb:base"
import "wb:forms"
import "wb:url"

@(private)
fs_fail :: proc(c: ^Call, e: Fs_Error, what: string) -> Api_Error {
	switch e {
	case .None: return .None
	case .Not_Found: return fail(c, .Not_Found, fmt.tprintf("%s: the entry does not exist", what))
	case .Type_Mismatch: return fail(c, .Invalid_State, fmt.tprintf("TypeMismatchError: %s: the entry is of the other kind", what))
	case .Invalid_Name: return fail(c, .Type, fmt.tprintf("%s: the name is not a valid file name", what))
	case .Not_Allowed: return fail(c, .Not_Allowed, fmt.tprintf("%s: permission is not granted", what))
	case .Locked: return fail(c, .No_Modification_Allowed, fmt.tprintf("%s: the entry is in use", what))
	case .Not_Empty: return fail(c, .Invalid_Modification, fmt.tprintf("%s: the directory is not empty", what))
	case .Quota: return fail(c, .Quota, fmt.tprintf("%s: opfs.max_bytes_per_origin", what))
	case .Io: return fail(c, .Invalid_State, fmt.tprintf("%s: the file could not be accessed", what))
	case .Security: return fail(c, .Security, fmt.tprintf("SecurityError: %s", what))
	}
	return .None
}

@(private)
fs_max_bytes :: proc(c: ^Call) -> i64 { return c.page.settings.sw.opfs_max_bytes }

Fs_opfsRoot :: proc(c: ^Call) -> (u64, Api_Error) {
	p := c.page
	if !p.env.secure_context { return 0, fail(c, .Security, "SecurityError: the file system needs a secure context") }
	if p.env.origin.opaque { return 0, fail(c, .Security, "SecurityError: an opaque origin has no file system") }
	sm := p.web.embedder.storage
	dir := sm != nil && sm.ready ? sm.dir : ""
	key := p.worker != nil ? p.worker.storage_key : storage_origin_key(p)
	id, e := fs_opfs_root(dir, key)
	if e == .Security { return 0, fail(c, .Security, "SecurityError: this profile keeps no files (no profile folder)") }
	if e != .None { return 0, fs_fail(c, e, "getDirectory") }
	return id, .None
}

Fs_getEntry :: proc(c: ^Call, root: u64, path, name: string, directory, create: bool) -> (string, Api_Error) {
	child, e := fs_get_entry(root, path, name, directory, create)
	if e != .None { return "", fs_fail(c, e, directory ? "getDirectoryHandle" : "getFileHandle") }
	return child, .None
}

Fs_removeEntry :: proc(c: ^Call, root: u64, path, name: string, recursive: bool) -> Api_Error {
	return fs_fail(c, fs_remove_entry(root, path, name, recursive), "removeEntry")
}

Fs_list :: proc(c: ^Call, root: u64, path: string) -> (string, Api_Error) {
	s, e := fs_list(root, path)
	if e != .None { return "", fs_fail(c, e, "entries") }
	return s, .None
}

Fs_resolve :: proc(c: ^Call, root: u64, path: string, root2: u64, path2: string) -> (string, Api_Error) {
	s, ok := fsh_resolve(root, path, root2, path2)
	if !ok { return "", .Not_Found }
	return s, .None
}

Fs_same :: proc(c: ^Call, root: u64, path: string, root2: u64, path2: string) -> bool { return fs_same(root, path, root2, path2) }

// getFile(): a File of the entry as it is now (read when the page reads it; NotReadableError once it changed).
Fs_getFile :: proc(c: ^Call, root: u64, path: string) -> (u64, Api_Error) {
	r, ok := fs_root(root)
	if !ok { return 0, fs_fail(c, .Not_Found, "getFile") }
	if r.read != .Granted { return 0, fs_fail(c, .Not_Allowed, "getFile") }
	disk, e := fs_disk_path(r, path)
	if e != .None { return 0, fs_fail(c, e, "getFile") }
	f, found := local_file_from_path(disk)
	if !found { return 0, fs_fail(c, .Not_Found, "getFile") }
	// its name is the entry's (an origin private file system's file is stored under an encoded name)
	name := path[strings.last_index_byte(path, '/') + 1:]
	if path != "" && f.name != name { delete(f.name); f.name = strings.clone(name) }
	return local_file_object(c.page, f, c.owner), .None
}

// createWritable / createSyncAccessHandle: an open entry, closed when the realm goes if the page does not close it.
Fs_open :: proc(c: ^Call, root: u64, path: string, keep, sync_handle: bool) -> (u64, Api_Error) {
	id, e := fs_open(root, path, keep, sync_handle)
	if e != .None { return 0, fs_fail(c, e, sync_handle ? "createSyncAccessHandle" : "createWritable") }
	base.on_close(c.page.scope, proc(data: rawptr) { fs_close(u64(uintptr(data)), false, 0) }, rawptr(uintptr(id)))
	return id, .None
}

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

// queryPermission: 0 granted, 1 prompt, 2 denied.
Fs_permission :: proc(c: ^Call, root: u64, write: bool) -> i32 {
	r, ok := fs_root(root)
	if !ok { return 2 }
	return i32(write ? r.write : r.read)
}

// A root as structuredClone keeps it: "o" (the realm's origin private file system) or "l", the origin, the folder.
Fs_describe :: proc(c: ^Call, root: u64) -> string {
	r, ok := fs_root(root)
	if !ok { return "" }
	if r.kind == .Opfs { return "o" }
	return fmt.tprintf("l\t%s\t%s", r.key, r.dir)
}

// The root a description stands for in this realm: the realm's own origin private file system, or a folder of the
// user's disk given to this origin (its grants of this session, else "prompt").
Fs_restore :: proc(c: ^Call, desc: string) -> (u64, Api_Error) {
	if desc == "o" { return Fs_opfsRoot(c) }
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
	page:      u64,
	promise:   u64,
	kind:      Fs_Picker_Kind,
	filters:   [dynamic]Fs_Pick_Filter,
	all_files: bool,
	multiple:  bool,
	suggested: string,
	start_dir: string,       // a folder of a handle given as startIn ("" : none)
	start_known: string,     // "desktop", "documents", "downloads", "music", "pictures", "videos" ("" : none)
	id:        string,       // the page's id of the picker (the system remembers its last folder per origin and id)
	readwrite: bool,
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

fs_embedder: Fs_Embedder

@(private)
fs_pick_free :: proc(r: ^Fs_Pick) {
	for f in r.filters { delete(f.name); for x in f.patterns { delete(x) }; delete(f.patterns) }
	delete(r.filters); delete(r.suggested); delete(r.start_dir); delete(r.start_known); delete(r.id)
	free(r)
}

// showOpenFilePicker / showSaveFilePicker / showDirectoryPicker: a promise of the chosen handles' descriptions
// (fs_given_handle lines); AbortError when the user cancels. `types`: one line per accepted type, "description TAB
// pattern TAB pattern...". Security without transient activation (file_system.user_activation_ms) or in a frame of
// another origin; Not_Supported when the shell has no pickers.
Fs_showPicker :: proc(c: ^Call, kind: i32, types: string, multiple, exclude_all: bool, suggested, start_in: string, start_root: u64, start_path, id: string, readwrite: bool) -> (u64, Api_Error) {
	p := c.page
	if p.worker != nil { return 0, fail(c, .Not_Supported, "NotSupportedError: pickers are a document's") }
	if !p.settings.sw.fs_pickers || fs_embedder.pick == nil { return 0, fail(c, .Not_Supported, "NotSupportedError: file pickers are disabled (file_system.pickers)") }
	if top := page_top(p); top != p && !url.same_origin(top.env.origin, p.env.origin) { return 0, fail(c, .Security, "SecurityError: a cross-origin frame cannot show a file picker") }
	age, had := activation_age_ns(p)
	if !had || age > i64(p.settings.sw.fs_activation_ms) * 1_000_000 { return 0, fail(c, .Security, "SecurityError: a file picker needs a user gesture (transient activation)") }
	req := new(Fs_Pick)
	req.page, req.kind, req.multiple, req.all_files, req.readwrite = page_id(p), Fs_Picker_Kind(kind), multiple, !exclude_all, readwrite || kind == 1
	req.suggested, req.start_known, req.id = strings.clone(suggested), strings.clone(start_in), strings.clone(id)
	if start_root != 0 {
		if r, ok := fs_root(start_root); ok {
			if d, e := fs_disk_path(r, start_path); e == .None { req.start_dir = strings.clone(d) }
			if is_dir, e := fs_kind(start_root, start_path); e == .None && !is_dir && req.start_dir != "" {
				// a file as startIn: its folder
				d := req.start_dir
				req.start_dir = strings.clone(d[:max(strings.last_index_byte(d, '/'), 0)])
				delete(d)
			}
		}
	}
	rest := types
	for line in strings.split_lines_iterator(&rest) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 2 { continue }
		pats := make([dynamic]string)
		for x in f[1:] { if x != "" { append(&pats, strings.clone(x)) } }
		append(&req.filters, Fs_Pick_Filter{name = strings.clone(f[0]), patterns = pats[:]})
	}
	req.promise = promise_create(p, c.owner)
	pr := req.promise
	fs_embedder.pick(fs_embedder.user, p, req)
	return pr, .None
}

// The shell's answer to a picker: the chosen paths (none: cancelled).
fs_pick_done :: proc(req: ^Fs_Pick, paths: []string) {
	defer fs_pick_free(req)
	p := page_by_id(req.page)
	if p == nil || p.closed { return }
	if len(paths) == 0 { promise_reject(p, req.promise, i64(Api_Error.Abort), "AbortError: the user cancelled the picker"); return }
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
	if fs_embedder.ask == nil || !had || age > i64(p.settings.sw.fs_activation_ms) * 1_000_000 {
		// (no prompt without a user gesture: the state stays what it is)
		promise_resolve(p, pr, i64(state))
		return pr, .None
	}
	req := new(Fs_Ask)
	req^ = Fs_Ask{page = page_id(p), promise = pr, root = root, write = write, what = strings.clone(r.dir), origin = strings.clone(url.origin_serialize(p.env.origin, context.temp_allocator))}
	fs_embedder.ask(fs_embedder.user, p, req)
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
