package page

// File handles (WHATWG File System, WICG File System Access), the browser's side, shared by every realm and thread (one
// mutex for the registries, never held during a realm's code; the file operations themselves run on the calling
// thread, outside it).
//
//   * A handle is (root, path, kind): `path` is the "/"-joined names from the root ("" is the root itself). A root is
//     the origin private file system of a storage key (<profile>/opfs/<key>/, names encoded so that any valid name,
//     case and all, is a distinct file on any disk: fs_encode_name), or a folder of the user's disk given by a picker
//     or a drop (names are the disk's own; a single file's root is its folder, its handle the file's name).
//   * Permissions are per root: the origin private file system is always granted; a root of the user's disk has a
//     read and a readwrite state (granted, prompt, denied), asked with requestPermission.
//   * Writes: createWritable writes a temporary file next to the target (a ".crswap" sibling, or in the origin's
//     hidden ".tmp" folder) and close() renames it over the target in one step (an abort removes it); a sync access
//     handle writes the file in place, under an exclusive lock. Locks are per entry: writables share, a sync access
//     handle excludes everything; removing a locked entry is refused.
//   * Quota: what the origin private file system of a key holds (kept up to date, computed by a walk the first time)
//     never goes past opfs.max_bytes_per_origin (QuotaExceededError); navigator.storage.estimate() counts it.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

Fs_Root_Kind :: enum u8 { Opfs, Local }
Fs_Permission :: enum u8 { Granted, Prompt, Denied }

Fs_Root :: struct {
	id:     u64,
	kind:   Fs_Root_Kind,
	key:    string,         // Opfs: the storage key; Local: the origin it was given to
	dir:    string,         // its folder on the disk
	read, write: Fs_Permission,
	usage:  i64,            // Opfs: bytes held (-1: not computed yet)
}

Fs_Error :: enum u8 { None, Not_Found, Type_Mismatch, Invalid_Name, Not_Allowed, Locked, Not_Empty, Quota, Io, Security }

@(private)
Fs_Lock :: struct { shared: int, exclusive: bool }

// An open writable stream (temporary file) or sync access handle.
Fs_Open :: struct {
	id:      u64,
	root:    u64,
	path:    string,         // the entry
	target:  string,         // its file on the disk
	temp:    string,         // a writable's temporary file ("" for a sync access handle)
	file:    ^os.File,
	cursor:  i64,
	size:    i64,
	base:    i64,            // the entry's size when it was opened (quota: what the commit adds)
	sync_handle: bool,
}

@(private)
Fs_Store :: struct {
	mu:     sync.Mutex,
	roots:  map[u64]^Fs_Root,
	locks:  map[string]Fs_Lock,   // by "root id:path"
	opens:  map[u64]^Fs_Open,
	next:   u64,
}

@(private) fs_store: Fs_Store

////////////////////////////////
// Names

// File System "valid file name" (and what a disk of this system cannot hold: NUL, the other separator).
fs_name_valid :: proc(name: string) -> bool {
	if name == "" || name == "." || name == ".." { return false }
	for i in 0 ..< len(name) {
		c := name[i]
		if c == '/' || c == '\\' || c == 0 { return false }
	}
	return true
}

// A name of a folder of the user's disk must also be one the disk accepts (Windows: no <>:"|?* nor control
// characters, no trailing dot or space, no reserved device name).
fs_disk_name_valid :: proc(name: string) -> bool {
	if !fs_name_valid(name) { return false }
	for i in 0 ..< len(name) {
		c := name[i]
		if c < 0x20 || strings.index_byte(`<>:"|?*`, c) >= 0 { return false }
	}
	last := name[len(name) - 1]
	if last == '.' || last == ' ' { return false }
	stem := strings.to_lower(name[:strings.index_byte(name, '.') if strings.index_byte(name, '.') > 0 else len(name)], context.temp_allocator)
	switch stem {
	case "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
	     "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9": return false
	}
	return true
}

// The file name an origin private file system's entry has on the disk: lower-case ASCII letters, digits, "-", "_"
// and "." (not first) as they are, every other byte as %XX. Distinct names stay distinct on a disk that ignores case,
// and none is a device name or ends with a dot.
fs_encode_name :: proc(name: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(name) {
		c := name[i]
		plain := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || (c == '.' && i > 0 && i < len(name) - 1)
		// (the first letter of a would-be device name is escaped: "con" -> "%63on")
		if plain && i == 0 && fs_reserved_stem(name) { plain = false }
		if plain { strings.write_byte(&b, c) } else { strings.write_byte(&b, '%'); strings.write_byte(&b, HEX[c >> 4]); strings.write_byte(&b, HEX[c & 15]) }
	}
	return strings.to_string(b)
}

@(private)
fs_reserved_stem :: proc(name: string) -> bool {
	dot := strings.index_byte(name, '.')
	stem := dot > 0 ? name[:dot] : name
	switch stem {
	case "con", "prn", "aux", "nul": return true
	}
	return len(stem) == 4 && (strings.has_prefix(stem, "com") || strings.has_prefix(stem, "lpt")) && stem[3] >= '0' && stem[3] <= '9'
}

// The inverse (ok false: not a name this encoding makes, such as the hidden ".tmp").
fs_decode_name :: proc(enc: string, allocator := context.allocator) -> (string, bool) {
	b := make([dynamic]byte, 0, len(enc), allocator)
	hexv :: proc(c: u8) -> int {
		switch {
		case c >= '0' && c <= '9': return int(c - '0')
		case c >= 'A' && c <= 'F': return int(c - 'A') + 10
		}
		return -1
	}
	for i := 0; i < len(enc); i += 1 {
		c := enc[i]
		if c == '%' {
			if i + 2 >= len(enc) { delete(b); return "", false }
			h, l := hexv(enc[i + 1]), hexv(enc[i + 2])
			if h < 0 || l < 0 { delete(b); return "", false }
			append(&b, u8(h << 4 | l))
			i += 2
			continue
		}
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || (c == '.' && i > 0) { append(&b, c); continue }
		delete(b)
		return "", false
	}
	return string(b[:]), true
}

////////////////////////////////
// Roots

// <profile>/opfs/<key, bytes outside [a-z0-9.-] as _XX> ("" without a profile folder: no origin private file system).
@(private)
opfs_dir :: proc(profile_dir, key: string, allocator := context.allocator) -> string {
	if profile_dir == "" { return "" }
	b := strings.builder_make(allocator)
	strings.write_string(&b, profile_dir)
	strings.write_string(&b, "/opfs/")
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(key) {
		c := key[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-' { strings.write_byte(&b, c) } else { strings.write_byte(&b, '_'); strings.write_byte(&b, HEX[c >> 4]); strings.write_byte(&b, HEX[c & 15]) }
	}
	return strings.to_string(b)
}

// The root of the origin private file system of `key` (made on first use).
fs_opfs_root :: proc(profile_dir, key: string) -> (u64, Fs_Error) {
	dir := opfs_dir(profile_dir, key, context.temp_allocator)
	if dir == "" { return 0, .Security }
	sync.mutex_lock(&fs_store.mu)
	defer sync.mutex_unlock(&fs_store.mu)
	for id, r in fs_store.roots { if r.kind == .Opfs && r.dir == dir { return id, .None } }
	if os.make_directory_all(dir) != nil && !os.exists(dir) { return 0, .Io }
	return fs_root_add_locked(.Opfs, key, dir, .Granted, .Granted), .None
}

// A root for a folder of the user's disk given to `origin` (the same folder given again: the same root and its grants).
fs_local_root :: proc(origin, dir: string, read, write: Fs_Permission) -> u64 {
	sync.mutex_lock(&fs_store.mu)
	defer sync.mutex_unlock(&fs_store.mu)
	for id, r in fs_store.roots {
		if r.kind == .Local && r.key == origin && strings.equal_fold(r.dir, dir) {
			if read == .Granted { r.read = .Granted }
			if write == .Granted { r.write = .Granted }
			return id
		}
	}
	return fs_root_add_locked(.Local, origin, dir, read, write)
}

@(private)
fs_root_add_locked :: proc(kind: Fs_Root_Kind, key, dir: string, read, write: Fs_Permission) -> u64 {
	if fs_store.roots == nil { fs_store.roots = make(map[u64]^Fs_Root) }
	fs_store.next += 1
	r := new(Fs_Root)
	r^ = Fs_Root{id = fs_store.next, kind = kind, key = strings.clone(key), dir = strings.clone(dir), read = read, write = write, usage = -1}
	fs_store.roots[r.id] = r
	return r.id
}

// A copy of a root's description (ok false: unknown).
fs_root :: proc(id: u64) -> (r: Fs_Root, ok: bool) {
	sync.mutex_lock(&fs_store.mu)
	defer sync.mutex_unlock(&fs_store.mu)
	x, found := fs_store.roots[id]
	if !found { return {}, false }
	r = x^
	r.key, r.dir = strings.clone(x.key, context.temp_allocator), strings.clone(x.dir, context.temp_allocator)
	return r, true
}

fs_set_permission :: proc(id: u64, write: bool, state: Fs_Permission) {
	sync.mutex_lock(&fs_store.mu)
	defer sync.mutex_unlock(&fs_store.mu)
	if r, ok := fs_store.roots[id]; ok {
		if write { r.write = state; if state == .Granted { r.read = .Granted } } else { r.read = state }
	}
}

// The disk path of an entry of root `r` (the names checked: Invalid_Name for one that is not valid).
fs_disk_path :: proc(r: Fs_Root, path: string, allocator := context.temp_allocator) -> (string, Fs_Error) {
	b := strings.builder_make(allocator)
	strings.write_string(&b, r.dir)
	rest := path
	for name in strings.split_iterator(&rest, "/") {
		if name == "" { continue }
		if !fs_name_valid(name) || (r.kind == .Local && !fs_disk_name_valid(name)) { return "", .Invalid_Name }
		strings.write_byte(&b, '/')
		strings.write_string(&b, r.kind == .Opfs ? fs_encode_name(name, context.temp_allocator) : name)
	}
	return strings.to_string(b), .None
}

@(private)
fs_join :: proc(path, name: string, allocator := context.temp_allocator) -> string {
	return path == "" ? strings.clone(name, allocator) : strings.concatenate({path, "/", name}, allocator)
}

@(private)
fs_lock_key :: proc(root: u64, path: string) -> string { return fmt.tprintf("%d:%s", root, path) }

////////////////////////////////
// Entries

// The kind of the entry at `path` (ok false: none).
fs_kind :: proc(root: u64, path: string) -> (is_dir: bool, err: Fs_Error) {
	r, ok := fs_root(root)
	if !ok { return false, .Not_Found }
	if r.read != .Granted { return false, .Not_Allowed }
	p := fs_disk_path(r, path) or_return
	info, e := os.stat(p, context.temp_allocator)
	if e != nil { return false, .Not_Found }
	return info.type == .Directory, .None
}

// getFileHandle / getDirectoryHandle(name, {create}): the child's path.
fs_get_entry :: proc(root: u64, dir_path, name: string, directory, create: bool) -> (result: string, err: Fs_Error) {
	r, ok := fs_root(root)
	if !ok { return "", .Not_Found }
	if !fs_name_valid(name) || (r.kind == .Local && !fs_disk_name_valid(name)) { return "", .Invalid_Name }
	if r.read != .Granted { return "", .Not_Allowed }
	parent := fs_disk_path(r, dir_path) or_return
	if pinfo, e := os.stat(parent, context.temp_allocator); e != nil || pinfo.type != .Directory { return "", .Not_Found }
	child := fs_join(dir_path, name)
	p := fs_disk_path(r, child) or_return
	if info, e := os.stat(p, context.temp_allocator); e == nil {
		if (info.type == .Directory) != directory { return "", .Type_Mismatch }
		return child, .None
	}
	if !create { return "", .Not_Found }
	if r.write != .Granted { return "", .Not_Allowed }
	if directory {
		if os.make_directory(p) != nil { return "", .Io }
	} else {
		f, e := os.open(p, {.Write, .Create, .Excl})
		if e != nil { return "", .Io }
		os.close(f)
	}
	return child, .None
}

// removeEntry(name, {recursive}).
fs_remove_entry :: proc(root: u64, dir_path, name: string, recursive: bool) -> Fs_Error {
	r, ok := fs_root(root)
	if !ok { return .Not_Found }
	if !fs_name_valid(name) || (r.kind == .Local && !fs_disk_name_valid(name)) { return .Invalid_Name }
	if r.write != .Granted { return .Not_Allowed }
	child := fs_join(dir_path, name)
	p := fs_disk_path(r, child) or_return
	info, e := os.stat(p, context.temp_allocator)
	if e != nil { return .Not_Found }
	if fs_locked_under(root, child) { return .Locked }
	freed: i64
	if info.type == .Directory {
		entries, _ := os.read_all_directory_by_path(p, context.temp_allocator)
		if len(entries) > 0 && !recursive { return .Not_Empty }
		freed = fs_dir_bytes(p)
		if os.remove_all(p) != nil { return .Io }
	} else {
		freed = info.size
		if os.remove(p) != nil { return .Io }
	}
	if r.kind == .Opfs { fs_usage_add(root, -freed) }
	return .None
}

// Whether the entry or one under it is locked.
@(private)
fs_locked_under :: proc(root: u64, path: string) -> bool {
	sync.mutex_lock(&fs_store.mu)
	defer sync.mutex_unlock(&fs_store.mu)
	prefix := fs_lock_key(root, path)
	for k, l in fs_store.locks {
		if (l.shared > 0 || l.exclusive) && (k == prefix || strings.has_prefix(k, strings.concatenate({prefix, "/"}, context.temp_allocator))) { return true }
	}
	return false
}

// The entries of a directory, sorted by name: "f" or "d", a tab, the name, one per line (temporary).
fs_list :: proc(root: u64, dir_path: string) -> (listing: string, err: Fs_Error) {
	r, ok := fs_root(root)
	if !ok { return "", .Not_Found }
	if r.read != .Granted { return "", .Not_Allowed }
	p := fs_disk_path(r, dir_path) or_return
	entries, e := os.read_all_directory_by_path(p, context.temp_allocator)
	if e != nil { return "", .Not_Found }
	b := strings.builder_make(context.temp_allocator)
	for x in entries {
		name := x.name
		if r.kind == .Opfs {
			n, good := fs_decode_name(x.name, context.temp_allocator)
			if !good { continue }   // (".tmp": the temporary files of writables)
			name = n
		} else if strings.has_suffix(name, ".crswap") {
			continue
		}
		if strings.builder_len(b) > 0 { strings.write_byte(&b, '\n') }
		strings.write_string(&b, x.type == .Directory ? "d\t" : "f\t")
		strings.write_string(&b, name)
	}
	return strings.to_string(b), .None
}

// resolve(): the names from `a` down to `b` ("" for `b` == `a`), ok false when `b` is not under `a`.
fsh_resolve :: proc(root_a: u64, path_a: string, root_b: u64, path_b: string) -> (string, bool) {
	ra, oka := fs_root(root_a)
	rb, okb := fs_root(root_b)
	if !oka || !okb { return "", false }
	da, ea := fs_disk_path(ra, path_a)
	db, eb := fs_disk_path(rb, path_b)
	if ea != .None || eb != .None { return "", false }
	if ra.kind != rb.kind { return "", false }
	if strings.equal_fold(da, db) && (ra.kind == .Local || da == db) { return "", true }
	if !strings.has_prefix(strings.to_lower(db, context.temp_allocator), strings.to_lower(strings.concatenate({da, "/"}, context.temp_allocator), context.temp_allocator)) { return "", false }
	// the names below `a`, read from b's own path when both are of one root, else from the disk path's tail
	if root_a == root_b { return path_a == "" ? path_b : path_b[len(path_a) + 1:], true }
	tail := db[len(da) + 1:]
	if rb.kind == .Opfs {
		out := strings.builder_make(context.temp_allocator)
		rest := tail
		for part in strings.split_iterator(&rest, "/") {
			n, good := fs_decode_name(part, context.temp_allocator)
			if !good { return "", false }
			if strings.builder_len(out) > 0 { strings.write_byte(&out, '/') }
			strings.write_string(&out, n)
		}
		return strings.to_string(out), true
	}
	return tail, true
}

// isSameEntry
fs_same :: proc(root_a: u64, path_a: string, root_b: u64, path_b: string) -> bool {
	ra, oka := fs_root(root_a)
	rb, okb := fs_root(root_b)
	if !oka || !okb || ra.kind != rb.kind { return false }
	da, ea := fs_disk_path(ra, path_a)
	db, eb := fs_disk_path(rb, path_b)
	if ea != .None || eb != .None { return false }
	return ra.kind == .Opfs ? da == db : strings.equal_fold(da, db)
}

////////////////////////////////
// Quota

@(private)
fs_dir_bytes :: proc(dir: string) -> i64 {
	total: i64
	entries, e := os.read_all_directory_by_path(dir, context.temp_allocator)
	if e != nil { return 0 }
	for x in entries {
		if x.type == .Directory { total += fs_dir_bytes(strings.concatenate({dir, "/", x.name}, context.temp_allocator)) } else { total += x.size }
	}
	return total
}

// What the origin private file system of `key` holds (navigator.storage.estimate()).
opfs_usage :: proc(profile_dir, key: string) -> i64 {
	dir := opfs_dir(profile_dir, key, context.temp_allocator)
	if dir == "" { return 0 }
	sync.mutex_lock(&fs_store.mu)
	for _, r in fs_store.roots {
		if r.kind == .Opfs && r.dir == dir && r.usage >= 0 { u := r.usage; sync.mutex_unlock(&fs_store.mu); return u }
	}
	sync.mutex_unlock(&fs_store.mu)
	return fs_dir_bytes(dir)
}

@(private)
fs_usage_of :: proc(root: u64) -> i64 {
	sync.mutex_lock(&fs_store.mu)
	r, ok := fs_store.roots[root]
	if !ok { sync.mutex_unlock(&fs_store.mu); return 0 }
	if r.usage >= 0 { u := r.usage; sync.mutex_unlock(&fs_store.mu); return u }
	dir := strings.clone(r.dir, context.temp_allocator)
	sync.mutex_unlock(&fs_store.mu)
	u := fs_dir_bytes(dir)
	sync.mutex_lock(&fs_store.mu)
	if r2, ok2 := fs_store.roots[root]; ok2 && r2.usage < 0 { r2.usage = u }
	sync.mutex_unlock(&fs_store.mu)
	return u
}

@(private)
fs_usage_add :: proc(root: u64, delta: i64) {
	sync.mutex_lock(&fs_store.mu)
	defer sync.mutex_unlock(&fs_store.mu)
	if r, ok := fs_store.roots[root]; ok && r.usage >= 0 { r.usage = max(r.usage + delta, 0) }
}

// Whether growing the root's files by `delta` stays within `max_bytes` (a root of the user's disk has no quota).
@(private)
fs_quota_ok :: proc(root: u64, delta: i64, max_bytes: i64) -> bool {
	r, ok := fs_root(root)
	if !ok || r.kind != .Opfs || delta <= 0 { return true }
	return fs_usage_of(root) + delta <= max_bytes
}

// "Clear site data": the origin private file system of the key is gone (open handles fail from now on).
opfs_clear :: proc(profile_dir, key: string) {
	dir := opfs_dir(profile_dir, key, context.temp_allocator)
	if dir == "" { return }
	_ = os.remove_all(dir)
	sync.mutex_lock(&fs_store.mu)
	defer sync.mutex_unlock(&fs_store.mu)
	for _, r in fs_store.roots { if r.kind == .Opfs && r.dir == dir { r.usage = 0 } }
}

////////////////////////////////
// Writables and sync access handles

// createWritable({keepExistingData}) / createSyncAccessHandle(): an open entry (its id).
fs_open :: proc(root: u64, path: string, keep: bool, sync_handle: bool) -> (open_id: u64, open_err: Fs_Error) {
	r, ok := fs_root(root)
	if !ok { return 0, .Not_Found }
	if r.write != .Granted { return 0, .Not_Allowed }
	target := fs_disk_path(r, path) or_return
	info, e := os.stat(target, context.temp_allocator)
	if e != nil { return 0, .Not_Found }
	if info.type == .Directory { return 0, .Type_Mismatch }
	key := fs_lock_key(root, path)
	sync.mutex_lock(&fs_store.mu)
	l := fs_store.locks[key]
	if l.exclusive || (sync_handle && l.shared > 0) { sync.mutex_unlock(&fs_store.mu); return 0, .Locked }
	if sync_handle { l.exclusive = true } else { l.shared += 1 }
	if _, had := fs_store.locks[key]; had { fs_store.locks[key] = l } else { fs_store.locks[strings.clone(key)] = l }
	fs_store.next += 1
	id := fs_store.next
	sync.mutex_unlock(&fs_store.mu)

	o := new(Fs_Open)
	o.id, o.root, o.path, o.target, o.sync_handle, o.base = id, root, strings.clone(path), strings.clone(target), sync_handle, info.size
	err: Fs_Error
	if sync_handle {
		f, oe := os.open(target, {.Read, .Write})
		if oe != nil { err = .Io } else { o.file = f; o.size = info.size }
	} else {
		// the temporary file: beside the target on the user's disk, in the origin's hidden folder for the origin's own
		if r.kind == .Opfs {
			tmp_dir := strings.concatenate({r.dir, "/.tmp"}, context.temp_allocator)
			_ = os.make_directory_all(tmp_dir)
			o.temp = fmt.aprintf("%s/%d-%d", tmp_dir, id, time.time_to_unix_nano(time.now()))
		} else {
			o.temp = strings.concatenate({target, ".crswap"})
		}
		if keep { if os.copy_file(o.temp, target) != nil { err = .Io } else { o.size = info.size } }
		if err == .None {
			f, oe := os.open(o.temp, keep ? {.Read, .Write} : {.Read, .Write, .Create, .Trunc})
			if oe != nil { err = .Io } else { o.file = f }
		}
	}
	if err != .None { fs_open_free(o, false); fs_unlock(root, path, sync_handle); return 0, err }
	sync.mutex_lock(&fs_store.mu)
	if fs_store.opens == nil { fs_store.opens = make(map[u64]^Fs_Open) }
	fs_store.opens[id] = o
	sync.mutex_unlock(&fs_store.mu)
	return id, .None
}

@(private)
fs_unlock :: proc(root: u64, path: string, exclusive: bool) {
	sync.mutex_lock(&fs_store.mu)
	defer sync.mutex_unlock(&fs_store.mu)
	key := fs_lock_key(root, path)
	l, ok := fs_store.locks[key]
	if !ok { return }
	if exclusive { l.exclusive = false } else { l.shared = max(l.shared - 1, 0) }
	if l.shared == 0 && !l.exclusive {
		stored, _ := delete_key(&fs_store.locks, key)
		delete(stored)
	} else {
		fs_store.locks[key] = l
	}
}

@(private)
fs_open_free :: proc(o: ^Fs_Open, remove_temp := true) {
	if o.file != nil { os.close(o.file) }
	if remove_temp && o.temp != "" { _ = os.remove(o.temp) }
	delete(o.path); delete(o.target); delete(o.temp)
	free(o)
}

@(private)
fs_open_get :: proc(id: u64) -> ^Fs_Open {
	sync.mutex_lock(&fs_store.mu)
	defer sync.mutex_unlock(&fs_store.mu)
	return fs_store.opens[id]
}

// Writes `data` at `at` (-1: the cursor), which moves past it. Quota for what the file grows by.
fs_write :: proc(id: u64, at: i64, data: []byte, max_bytes: i64) -> (int, Fs_Error) {
	o := fs_open_get(id)
	if o == nil || o.file == nil { return 0, .Not_Found }
	pos := at >= 0 ? at : o.cursor
	end := pos + i64(len(data))
	grow := max(end, o.size) - max(o.size, o.base)
	if o.sync_handle && !fs_quota_ok(o.root, grow, max_bytes) { return 0, .Quota }
	if !o.sync_handle && !fs_quota_ok(o.root, max(end, o.size) - o.base, max_bytes) { return 0, .Quota }
	if pos > o.size {
		// (a write past the end: the gap is zeros)
		if os.truncate(o.file, pos) != nil { return 0, .Io }
	}
	n, e := os.write_at(o.file, data, pos)
	if e != nil { return n, .Io }
	o.cursor = pos + i64(n)
	if o.cursor > o.size {
		if o.sync_handle { fs_usage_add(o.root, o.cursor - max(o.size, o.base)) }
		o.size = o.cursor
		if o.sync_handle { o.base = o.size }
	}
	return n, .None
}

// Reads into `into` from `at` (-1: the cursor), which moves past what was read.
fs_read :: proc(id: u64, at: i64, into: []byte) -> (int, Fs_Error) {
	o := fs_open_get(id)
	if o == nil || o.file == nil { return 0, .Not_Found }
	pos := at >= 0 ? at : o.cursor
	if pos >= o.size { o.cursor = pos; return 0, .None }
	n, e := os.read_at(o.file, into[:min(i64(len(into)), o.size - pos)], pos)
	if e != nil && n == 0 { return 0, .Io }
	o.cursor = pos + i64(n)
	return n, .None
}

fs_seek :: proc(id: u64, pos: i64) -> Fs_Error {
	o := fs_open_get(id)
	if o == nil { return .Not_Found }
	o.cursor = pos
	return .None
}

// truncate(size): the cursor stays before the new end.
fs_truncate :: proc(id: u64, size: i64, max_bytes: i64) -> Fs_Error {
	o := fs_open_get(id)
	if o == nil || o.file == nil { return .Not_Found }
	if !fs_quota_ok(o.root, size - max(o.size, o.base), max_bytes) { return .Quota }
	if os.truncate(o.file, size) != nil { return .Io }
	if o.sync_handle { fs_usage_add(o.root, size - o.size); o.base = size }
	o.size = size
	o.cursor = min(o.cursor, size)
	return .None
}

fs_size :: proc(id: u64) -> (i64, Fs_Error) {
	o := fs_open_get(id)
	if o == nil { return 0, .Not_Found }
	return o.size, .None
}

fs_flush :: proc(id: u64) -> Fs_Error {
	o := fs_open_get(id)
	if o == nil || o.file == nil { return .Not_Found }
	return os.sync(o.file) == nil ? .None : .Io
}

// close(): a writable's temporary file replaces the target in one rename (`commit` false: it is dropped); a sync
// access handle lets its lock go.
fs_close :: proc(id: u64, commit: bool, max_bytes: i64) -> Fs_Error {
	sync.mutex_lock(&fs_store.mu)
	o, ok := fs_store.opens[id]
	if ok { delete_key(&fs_store.opens, id) }
	sync.mutex_unlock(&fs_store.mu)
	if !ok { return .Not_Found }
	err: Fs_Error
	if !o.sync_handle && commit {
		if !fs_quota_ok(o.root, o.size - o.base, max_bytes) {
			err = .Quota
		} else {
			os.close(o.file)
			o.file = nil
			if os.rename(o.temp, o.target) != nil {
				err = .Io
			} else {
				if r, okr := fs_root(o.root); okr && r.kind == .Opfs { fs_usage_add(o.root, o.size - o.base) }
				delete(o.temp)
				o.temp = ""
			}
		}
	}
	fs_unlock(o.root, o.path, o.sync_handle)
	fs_open_free(o)
	return err
}

// Process end: open entries are dropped (writables' temporary files removed).
fs_store_shutdown :: proc() {
	sync.mutex_lock(&fs_store.mu)
	defer sync.mutex_unlock(&fs_store.mu)
	for _, o in fs_store.opens { fs_open_free(o) }
	delete(fs_store.opens)
	for k in fs_store.locks { delete(k) }
	delete(fs_store.locks)
	for _, r in fs_store.roots { delete(r.key); delete(r.dir); free(r) }
	delete(fs_store.roots)
	fs_store = {}
}
