// web_fs.odin: file handles for JavaScript (WHATWG File System, WICG File System Access; module fs,
// src/page/fs_api.odin): FileSystemHandle / FileSystemFileHandle / FileSystemDirectoryHandle, their async iterators,
// FileSystemWritableFileStream (a WritableStream, runtime/web_writable.c, on a sink of the browser's writable),
// FileSystemSyncAccessHandle (dedicated workers), navigator.storage.getDirectory(), showOpenFilePicker /
// showSaveFilePicker / showDirectoryPicker, DataTransferItem.getAsFileSystemHandle(), and the description a handle is
// structured-cloned as (runtime/clone.c). A handle is the browser's root id and a "/"-joined path below it; the
// browser checks names, permissions, locks and quotas, and names its errors ("TypeMismatchError: ..."). Ported from
// native/js/runtime/web_fs.c: same wjr_* / web_fs_* symbols and behaviour; the host calls are declared in
// native/js/odin_abi/api_decl/fs.odin and made through jsb.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") none: abi.Nothing

@(private = "file") Fs_Iface :: enum { Handle, File, Directory, Writable, Sync, Blob }
@(private = "file") fs_iface_names := [Fs_Iface]cstring{
	.Handle = "FileSystemHandle", .File = "FileSystemFileHandle", .Directory = "FileSystemDirectoryHandle",
	.Writable = "FileSystemWritableFileStream", .Sync = "FileSystemSyncAccessHandle", .Blob = "Blob",
}
@(private = "file") fs_iface_cache := [Fs_Iface]i32{ .Handle = -2, .File = -2, .Directory = -2, .Writable = -2, .Sync = -2, .Blob = -2 }

@(private = "file")
fs_iface :: proc "contextless" (i: Fs_Iface) -> i32 {
	if fs_iface_cache[i] == -2 { fs_iface_cache[i] = wj.iface(fs_iface_names[i]) }
	return fs_iface_cache[i]
}

// A handle: the browser's root and the path below it, its name, its kind. The strings are NUL-terminated copies on the
// libc heap (web_strndup), freed with the handle.
@(private = "file")
Fsh :: struct {
	root: u64,
	path: string,
	name: string,
	dir:  bool,
}

@(private = "file")
fsh_free :: proc "c" (p: rawptr) {
	h := (^Fsh)(p)
	wj.libc_free(raw_data(h.path))
	wj.libc_free(raw_data(h.name))
	wj.libc_free(h)
}

@(private = "file")
dup :: proc "contextless" (s: string) -> string {
	p := wj.web_strndup(wj.raw_bytes(s), uint(len(s)))
	return p != nil ? string(p[:len(s)]) : ""
}

// The browser's error as an exception: a DOMException named by the message's first word when it names one the status
// has no own name for (TypeMismatchError).
@(private = "file")
fs_throw :: proc(ctx: ^wj.Context, st: abi.Api_Error, what: cstring) -> wj.JSValue {
	PREFIX :: "TypeMismatchError: "
	msg: string
	jsb.host(&msg, api_decl.Exception_message, wj.wr_Exception_message)
	if len(msg) >= len(PREFIX) && msg[:len(PREFIX)] == PREFIX {
		rest := wj.web_strndup(raw_data(msg[len(PREFIX):]), uint(len(msg) - len(PREFIX)))
		e := wj.wj_throw_dom(ctx, "TypeMismatchError", rest != nil ? wj.cstr(rest) : "")
		wj.libc_free(rest)
		return e
	}
	return wj.wj_throw_status(ctx, i32(st), what)
}

@(private = "file")
fs_reject :: proc(ctx: ^wj.Context, st: abi.Api_Error, what: cstring) -> wj.JSValue {
	fs_throw(ctx, st, what)
	return wj.web_promise_reject_pending(ctx)
}

// A promise of `v` (taken), or the pending exception as a rejection when v is one.
@(private = "file")
settled :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> wj.JSValue {
	return wj.is_exception(v) ? wj.web_promise_reject_pending(ctx) : wj.web_promise_take(ctx, v)
}

// A handle of the browser's (root, path), a directory or a file named `name`.
@(private = "file")
handle_new :: proc "contextless" (ctx: ^wj.Context, root: u64, path: string, dir: bool, name: string) -> wj.JSValue {
	h := (^Fsh)(wj.libc_calloc(1, size_of(Fsh)))
	if h == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	h^ = { root = root, path = dup(path), name = dup(name), dir = dir }
	return wj.wj_new_object(ctx, fs_iface(dir ? .Directory : .File), h, fsh_free)
}

@(private = "file")
fsh_of :: proc "contextless" (v: wj.JSValue) -> ^Fsh { return (^Fsh)(wj.impl_of(wj.wj_unwrap(v, fs_iface(.Handle)))) }

@(private = "file")
fsh_this :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, iface: Fs_Iface) -> ^Fsh { return (^Fsh)(wj.this_impl(ctx, v, fs_iface(iface))) }

// The first `n` fields of `s` split at `sep` (the last one keeps the rest); missing fields keep their defaults.
@(private = "file")
fields :: proc "contextless" (s: string, sep: u8, out: []string) {
	rest := s
	for i in 0 ..< len(out) {
		if i == len(out) - 1 { out[i] = rest; return }
		cut := -1
		for j in 0 ..< len(rest) { if rest[j] == sep { cut = j; break } }
		if cut < 0 { out[i] = rest; return }
		out[i] = rest[:cut]
		rest = rest[cut + 1:]
	}
}

// A decimal number at the start of `s` (strtoull: digits only).
@(private = "file")
decimal :: proc "contextless" (s: string) -> u64 {
	v: u64
	for c in transmute([]u8)s {
		if c < '0' || c > '9' { break }
		v = v * 10 + u64(c - '0')
	}
	return v
}

// "root TAB path TAB f|d TAB name" -> a handle
@(private = "file")
handle_from_line :: proc "contextless" (ctx: ^wj.Context, line: string) -> wj.JSValue {
	f := [4]string{"", "", "f", ""}
	fields(line, '\t', f[:])
	for c, i in transmute([]u8)f[3] { if c == '\t' { f[3] = f[3][:i]; break } }   // (the name ends at a fifth field)
	return handle_new(ctx, decimal(f[0][:min(len(f[0]), 23)]), f[1], f[2] == "d", f[3])
}

// ---- FileSystemHandle ----

@(export, link_name = "wjr_FileSystemHandle_get_kind")
wjr_FileSystemHandle_get_kind :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	h := fsh_this(ctx, t, .Handle)
	if h == nil { return wj.EXCEPTION }
	return wj.new_string(ctx, h.dir ? "directory" : "file")
}

@(export, link_name = "wjr_FileSystemHandle_get_name")
wjr_FileSystemHandle_get_name :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	h := fsh_this(ctx, t, .Handle)
	return h != nil ? wj.new_string_len(ctx, h.name) : wj.EXCEPTION
}

@(export, link_name = "wjr_FileSystemHandle_isSameEntry")
wjr_FileSystemHandle_isSameEntry :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := fsh_this(ctx, t, .Handle)
	if h == nil { return wj.web_promise_reject_pending(ctx) }
	o := fsh_of(wj.arg(argc, argv, 0))
	if o == nil {
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'isSameEntry' on 'FileSystemHandle': parameter 1 is not of type 'FileSystemHandle'.")
		return wj.web_promise_reject_pending(ctx)
	}
	same := false
	if o.dir == h.dir { jsb.host(&same, api_decl.Fs_same, wj.wr_Fs_same, h.root, h.path, o.root, o.path) }
	return wj.web_promise_take(ctx, wj.new_bool(same))
}

// The `mode` of a FileSystemHandlePermissionDescriptor: write access asked. False with an exception pending.
@(private = "file")
mode_arg :: proc "contextless" (ctx: ^wj.Context, opt: wj.JSValue) -> (write: bool, ok: bool) {
	if !wj.web_dict_check(ctx, opt, "FileSystemHandlePermissionDescriptor") { return }
	m: wj.JSValue
	if !wj.web_dict_get(ctx, opt, "mode", &m) { return }
	if wj.is_undefined(m) { return false, true }
	s := wj.to_cstring(ctx, m)
	wj.JS_FreeValue(ctx, m)
	if s == nil { return }
	defer wj.free_cstring(ctx, s)
	switch string(s) {
	case "read":      return false, true
	case "readwrite": return true, true
	}
	wj.JS_ThrowTypeError(ctx, "The provided value is not a valid enum value of type FileSystemPermissionMode.")
	return
}

@(private = "file") state_names := [3]cstring{ "granted", "prompt", "denied" }

@(private = "file")
state_name :: proc "contextless" (s: i64) -> cstring { return state_names[s >= 0 && s < 3 ? s : 2] }

@(export, link_name = "wjr_FileSystemHandle_queryPermission")
wjr_FileSystemHandle_queryPermission :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := fsh_this(ctx, t, .Handle)
	if h == nil { return wj.web_promise_reject_pending(ctx) }
	write, ok := mode_arg(ctx, wj.arg(argc, argv, 0))
	if !ok { return wj.web_promise_reject_pending(ctx) }
	s: i32
	jsb.host(&s, api_decl.Fs_permission, wj.wr_Fs_permission, h.root, write)
	return wj.web_promise_take(ctx, wj.new_string(ctx, state_name(i64(s))))
}

@(private = "file")
settle_state :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	if state != 1 { reject^ = true; return wj.web_dom_exception(ctx, "NotAllowedError", "the permission could not be asked") }
	return wj.new_string(ctx, state_name(value))
}

@(export, link_name = "wjr_FileSystemHandle_requestPermission")
wjr_FileSystemHandle_requestPermission :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := fsh_this(ctx, t, .Handle)
	if h == nil { return wj.web_promise_reject_pending(ctx) }
	write, ok := mode_arg(ctx, wj.arg(argc, argv, 0))
	if !ok { return wj.web_promise_reject_pending(ctx) }
	p: abi.Handle
	if st := jsb.host(&p, api_decl.Fs_requestPermission, wj.wr_Fs_requestPermission, h.root, write); st != .None {
		return fs_reject(ctx, st, "requestPermission")
	}
	return wj.wj_promise_from_host(ctx, u64(p), wj.HOST_NUMBER, settle_state, wj.UNDEFINED)
}

// ---- FileSystemDirectoryHandle ----

// A boolean member of an options dictionary (false when absent). False with an exception pending.
@(private = "file")
bool_option :: proc "contextless" (ctx: ^wj.Context, opt: wj.JSValue, dict: cstring, member: cstring) -> (value: bool, ok: bool) {
	if !wj.web_dict_check(ctx, opt, dict) { return }
	v: wj.JSValue
	if !wj.web_dict_get(ctx, opt, member, &v) { return }
	value = wj.JS_ToBool(ctx, v) > 0
	wj.JS_FreeValue(ctx, v)
	return value, true
}

@(private = "file")
get_child :: proc(ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, dir: bool) -> wj.JSValue {
	h := fsh_this(ctx, t, .Directory)
	if h == nil { return wj.web_promise_reject_pending(ctx) }
	what: cstring = dir ? "getDirectoryHandle" : "getFileHandle"
	if argc < 1 { wj.wj_throw_arity(ctx, what, 1, argc); return wj.web_promise_reject_pending(ctx) }
	name: wj.Str
	if !wj.web_to_usv(ctx, argv[0], &name) { return wj.web_promise_reject_pending(ctx) }
	defer wj.wj_str_free(ctx, &name)
	create, ok := bool_option(ctx, wj.arg(argc, argv, 1), dir ? "FileSystemGetDirectoryOptions" : "FileSystemGetFileOptions", "create")
	if !ok { return wj.web_promise_reject_pending(ctx) }
	n := string(wj.str_slice(name))
	child: string
	if st := jsb.host(&child, api_decl.Fs_getEntry, wj.wr_Fs_getEntry, h.root, h.path, n, dir, create); st != .None {
		return fs_reject(ctx, st, what)
	}
	return settled(ctx, handle_new(ctx, h.root, child, dir, n))
}

@(export, link_name = "wjr_FileSystemDirectoryHandle_getFileHandle")
wjr_FileSystemDirectoryHandle_getFileHandle :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return get_child(ctx, t, argc, argv, false)
}
@(export, link_name = "wjr_FileSystemDirectoryHandle_getDirectoryHandle")
wjr_FileSystemDirectoryHandle_getDirectoryHandle :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return get_child(ctx, t, argc, argv, true)
}

@(export, link_name = "wjr_FileSystemDirectoryHandle_removeEntry")
wjr_FileSystemDirectoryHandle_removeEntry :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := fsh_this(ctx, t, .Directory)
	if h == nil { return wj.web_promise_reject_pending(ctx) }
	if argc < 1 { wj.wj_throw_arity(ctx, "removeEntry", 1, argc); return wj.web_promise_reject_pending(ctx) }
	name: wj.Str
	if !wj.web_to_usv(ctx, argv[0], &name) { return wj.web_promise_reject_pending(ctx) }
	defer wj.wj_str_free(ctx, &name)
	recursive, ok := bool_option(ctx, wj.arg(argc, argv, 1), "FileSystemRemoveOptions", "recursive")
	if !ok { return wj.web_promise_reject_pending(ctx) }
	if st := jsb.host(&none, api_decl.Fs_removeEntry, wj.wr_Fs_removeEntry, h.root, h.path, string(wj.str_slice(name)), recursive); st != .None {
		return fs_reject(ctx, st, "removeEntry")
	}
	return wj.web_promise_take(ctx, wj.UNDEFINED)
}

@(export, link_name = "wjr_FileSystemDirectoryHandle_resolve")
wjr_FileSystemDirectoryHandle_resolve :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := fsh_this(ctx, t, .Directory)
	if h == nil { return wj.web_promise_reject_pending(ctx) }
	o := fsh_of(wj.arg(argc, argv, 0))
	if o == nil {
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'resolve' on 'FileSystemDirectoryHandle': parameter 1 is not of type 'FileSystemHandle'.")
		return wj.web_promise_reject_pending(ctx)
	}
	names: string
	if jsb.host(&names, api_decl.Fs_resolve, wj.wr_Fs_resolve, h.root, h.path, o.root, o.path) != .None {
		return wj.web_promise_take(ctx, wj.NULL)
	}
	return wj.web_promise_take(ctx, lines_split(ctx, names, '/'))
}

// Each `sep`-separated part of `text` as a string of a new array (an empty text is no part).
@(private = "file")
lines_split :: proc "contextless" (ctx: ^wj.Context, text: string, sep: u8) -> wj.JSValue {
	arr := wj.JS_NewArray(ctx)
	if len(text) == 0 { return arr }
	k: u32
	start := 0
	for i in 0 ..= len(text) {
		if i == len(text) || text[i] == sep {
			wj.JS_SetPropertyUint32(ctx, arr, k, wj.new_string_len(ctx, text[start:i]))
			k += 1
			start = i + 1
		}
	}
	return arr
}

// entries() / keys() / values(): an async iterator over the entries listed when it was made. Its `next` carries
// [handle, list (array of [name, isDir]), index (in an array), which].
@(private = "file")
Iter_Data :: enum i32 { Handle, List, Index, Which }
@(private = "file")
Iter_Kind :: enum i32 { Entries, Keys, Values }

@(private = "file")
iter_next :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	h := fsh_of(data[Iter_Data.Handle])
	i, which: i32
	iv := wj.JS_GetPropertyUint32(ctx, data[Iter_Data.Index], 0)
	wj.JS_ToInt32(ctx, &i, iv)
	wj.JS_FreeValue(ctx, iv)
	wj.JS_ToInt32(ctx, &which, data[Iter_Data.Which])
	n: i64
	wj.JS_GetLength(ctx, data[Iter_Data.List], &n)
	if h == nil || i64(i) >= n { return wj.web_promise_take(ctx, wj.web_iter_result(ctx, wj.UNDEFINED, true)) }
	wj.JS_SetPropertyUint32(ctx, data[Iter_Data.Index], 0, wj.new_int32(i + 1))
	e := wj.JS_GetPropertyUint32(ctx, data[Iter_Data.List], u32(i))
	name := wj.JS_GetPropertyUint32(ctx, e, 0)
	isdir := wj.JS_GetPropertyUint32(ctx, e, 1)
	wj.JS_FreeValue(ctx, e)
	nl: uint
	ns := wj.to_cstring_len(ctx, &nl, name)
	handle: wj.JSValue
	if ns == nil {
		handle = wj.JS_ThrowOutOfMemory(ctx)
	} else {
		child_name := string(([^]u8)(rawptr(ns))[:nl])
		// the child's path: path "/" name, or the name at the root
		total := len(h.path) + int(nl) + 1
		buf := ([^]u8)(wj.libc_malloc(uint(total) + 1))
		if buf == nil {
			handle = wj.JS_ThrowOutOfMemory(ctx)
		} else {
			k := 0
			if len(h.path) > 0 { k += copy(buf[:total], h.path); buf[k] = '/'; k += 1 }
			k += copy(buf[k:total], child_name)
			handle = handle_new(ctx, h.root, string(buf[:k]), wj.JS_ToBool(ctx, isdir) > 0, child_name)
			wj.libc_free(buf)
		}
		wj.free_cstring(ctx, ns)
	}
	wj.JS_FreeValue(ctx, isdir)
	if wj.is_exception(handle) { wj.JS_FreeValue(ctx, name); return wj.web_promise_reject_pending(ctx) }
	v: wj.JSValue
	switch Iter_Kind(which) {
	case .Entries:
		v = wj.JS_NewArray(ctx)
		wj.JS_SetPropertyUint32(ctx, v, 0, name)
		wj.JS_SetPropertyUint32(ctx, v, 1, handle)
	case .Keys:
		v = name
		wj.JS_FreeValue(ctx, handle)
	case .Values:
		v = handle
		wj.JS_FreeValue(ctx, name)
	}
	return wj.web_promise_take(ctx, wj.web_iter_result(ctx, v, false))
}

@(private = "file")
ret_data0 :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	return wj.JS_DupValue(ctx, data[0])
}

@(private = "file")
iter_self :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.JS_DupValue(ctx, this_val)
}

// The well-known symbol `name` (Symbol.asyncIterator...) as an atom (to free).
@(private = "file")
symbol_atom :: proc "contextless" (ctx: ^wj.Context, name: cstring) -> wj.Atom {
	sym := wj.JS_GetPropertyStr(ctx, wj.realm_global(), "Symbol")
	s := wj.JS_GetPropertyStr(ctx, sym, name)
	a := wj.JS_ValueToAtom(ctx, s)
	wj.JS_FreeValue(ctx, s)
	wj.JS_FreeValue(ctx, sym)
	return a
}

@(private = "file")
make_iterator :: proc(ctx: ^wj.Context, t: wj.JSValue, which: Iter_Kind) -> wj.JSValue {
	h := fsh_this(ctx, t, .Directory)
	if h == nil { return wj.EXCEPTION }
	listing: string
	st := jsb.host(&listing, api_decl.Fs_list, wj.wr_Fs_list, h.root, h.path)
	list := wj.JS_NewArray(ctx)
	k: u32
	rest := listing
	for len(rest) > 0 {
		cut := len(rest)
		for j in 0 ..< len(rest) { if rest[j] == '\n' { cut = j; break } }
		line := rest[:cut]
		if len(line) > 2 {
			e := wj.JS_NewArray(ctx)
			wj.JS_SetPropertyUint32(ctx, e, 0, wj.new_string_len(ctx, line[2:]))
			wj.JS_SetPropertyUint32(ctx, e, 1, wj.new_bool(line[0] == 'd'))
			wj.JS_SetPropertyUint32(ctx, list, k, e)
			k += 1
		}
		rest = cut < len(rest) ? rest[cut + 1:] : ""
	}
	// (a listing that failed: the iterator rejects at its first step)
	it := wj.JS_NewObject(ctx)
	idx := wj.JS_NewArray(ctx)
	wj.JS_SetPropertyUint32(ctx, idx, 0, wj.new_int32(0))
	data := [Iter_Data]wj.JSValue{ .Handle = wj.JS_DupValue(ctx, t), .List = list, .Index = idx, .Which = wj.new_int32(i32(which)) }
	if st != .None {
		fs_throw(ctx, st, "entries")
		rej := wj.web_promise_rejected(ctx, wj.JS_GetException(ctx))
		wj.JS_SetPropertyStr(ctx, it, "next", wj.JS_NewCFunctionData(ctx, ret_data0, 0, 0, 1, &rej))
		wj.JS_FreeValue(ctx, rej)
	} else {
		wj.JS_SetPropertyStr(ctx, it, "next", wj.JS_NewCFunctionData(ctx, iter_next, 0, 0, i32(len(data)), &data[.Handle]))
	}
	for v in data { wj.JS_FreeValue(ctx, v) }
	a := symbol_atom(ctx, "asyncIterator")
	wj.JS_DefinePropertyValue(ctx, it, a, wj.new_cfunction(ctx, iter_self, "[Symbol.asyncIterator]", 0), wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
	wj.JS_FreeAtom(ctx, a)
	return it
}

@(export, link_name = "wjr_FileSystemDirectoryHandle_entries")
wjr_FileSystemDirectoryHandle_entries :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return make_iterator(ctx, t, .Entries)
}
@(export, link_name = "wjr_FileSystemDirectoryHandle_keys")
wjr_FileSystemDirectoryHandle_keys :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return make_iterator(ctx, t, .Keys)
}
@(export, link_name = "wjr_FileSystemDirectoryHandle_values")
wjr_FileSystemDirectoryHandle_values :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return make_iterator(ctx, t, .Values)
}

// ---- FileSystemFileHandle ----

@(export, link_name = "wjr_FileSystemFileHandle_getFile")
wjr_FileSystemFileHandle_getFile :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := fsh_this(ctx, t, .File)
	if h == nil { return wj.web_promise_reject_pending(ctx) }
	lf: abi.Handle
	if st := jsb.host(&lf, api_decl.Fs_getFile, wj.wr_Fs_getFile, h.root, h.path); st != .None { return fs_reject(ctx, st, "getFile") }
	return settled(ctx, web_file_from_host(ctx, u64(lf)))
}

// The writable's sink: each method carries [id (a number)].
@(private = "file")
data_id :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> u64 {
	d: f64
	wj.JS_ToFloat64(ctx, &d, v)
	return u64(d)
}

@(private = "file")
write_bytes :: proc(ctx: ^wj.Context, id: u64, at: i64, bytes: []u8) -> wj.JSValue {
	wrote: i64
	if st := jsb.host(&wrote, api_decl.Fs_write, wj.wr_Fs_write, id, at, bytes); st != .None { return fs_reject(ctx, st, "write") }
	return wj.web_promise_take(ctx, wj.UNDEFINED)
}

// A Blob's bytes read (arrayBuffer() settled): [id, position]
@(private = "file")
blob_read :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	p: [^]u8
	n: uint
	if argc < 1 || !wj.wj_to_buffer_source(ctx, argv[0], &p, &n, 0, "write") { return wj.EXCEPTION }
	at := f64(-1)
	wj.JS_ToFloat64(ctx, &at, data[1])
	wrote: i64
	if st := jsb.host(&wrote, api_decl.Fs_write, wj.wr_Fs_write, data_id(ctx, data[0]), i64(at), bytes_of(p, n)); st != .None {
		return fs_throw(ctx, st, "write")
	}
	return wj.UNDEFINED
}

@(private = "file")
bytes_of :: #force_inline proc "contextless" (p: [^]u8, n: uint) -> []u8 { return p != nil ? p[:n] : nil }

// Writes one chunk: a BufferSource, a Blob or a string
@(private = "file")
write_data :: proc(ctx: ^wj.Context, id: u64, data: wj.JSValue, at: i64) -> wj.JSValue {
	if wj.is_string(data) {
		n: uint
		s := wj.to_cstring_len(ctx, &n, data)
		if s == nil { return wj.web_promise_reject_pending(ctx) }
		defer wj.free_cstring(ctx, s)
		return write_bytes(ctx, id, at, ([^]u8)(rawptr(s))[:n])
	}
	if wj.wj_is_buffer_source(data) {
		p: [^]u8
		n: uint
		if !wj.wj_to_buffer_source(ctx, data, &p, &n, wj.BS_ALLOW_SHARED, "write") { return wj.web_promise_reject_pending(ctx) }
		return write_bytes(ctx, id, at, bytes_of(p, n))
	}
	bp: [^]u8
	bn: uint
	if web_blob_bytes(data, &bp, &bn) { return write_bytes(ctx, id, at, bytes_of(bp, bn)) }
	if wj.wj_unwrap(data, fs_iface(.Blob)) != nil {
		// a Blob of a file: its bytes first
		fn := wj.JS_GetPropertyStr(ctx, data, "arrayBuffer")
		pr := wj.JS_Call(ctx, fn, data, 0, nil)
		wj.JS_FreeValue(ctx, fn)
		if wj.is_exception(pr) { return wj.web_promise_reject_pending(ctx) }
		d := [2]wj.JSValue{ wj.new_float64(ctx, f64(id)), wj.new_float64(ctx, f64(at)) }
		r := wj.web_then(ctx, pr, rawptr(blob_read), nil, 2, &d[0])
		wj.JS_FreeValue(ctx, pr)
		return r
	}
	wj.JS_ThrowTypeError(ctx, "Failed to execute 'write' on 'FileSystemWritableFileStream': the data is not a BufferSource, a Blob, a string or a WriteParams.")
	return wj.web_promise_reject_pending(ctx)
}

// WriteParams.type
@(private = "file")
Write_Command :: enum { Write, Seek, Truncate }

@(private = "file")
sink_write :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, fdata: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	id := data_id(ctx, fdata[0])
	chunk := wj.arg(argc, argv, 0)
	if !wj.is_object(chunk) || wj.wj_is_buffer_source(chunk) || wj.wj_unwrap(chunk, fs_iface(.Blob)) != nil {
		return write_data(ctx, id, chunk, -1)
	}
	// WriteParams
	type := wj.JS_GetPropertyStr(ctx, chunk, "type")
	ts := wj.is_undefined(type) ? nil : wj.to_cstring(ctx, type)
	wj.JS_FreeValue(ctx, type)
	if ts == nil { wj.JS_ThrowTypeError(ctx, "Failed to execute 'write': WriteParams needs a type."); return wj.web_promise_reject_pending(ctx) }
	kind: Write_Command
	known := true
	switch string(ts) {
	case "write":    kind = .Write
	case "seek":     kind = .Seek
	case "truncate": kind = .Truncate
	case:            known = false
	}
	wj.free_cstring(ctx, ts)
	if !known { wj.JS_ThrowTypeError(ctx, "The provided value is not a valid enum value of type WriteCommandType."); return wj.web_promise_reject_pending(ctx) }
	v := wj.JS_GetPropertyStr(ctx, chunk, kind == .Truncate ? "size" : "position")
	has := !wj.is_nullish(v)
	num := f64(-1)
	if has && wj.JS_ToFloat64(ctx, &num, v) < 0 { wj.JS_FreeValue(ctx, v); return wj.web_promise_reject_pending(ctx) }
	wj.JS_FreeValue(ctx, v)
	switch kind {
	case .Seek:
		if !has { wj.wj_throw_dom(ctx, "SyntaxError", "seek needs a position"); return wj.web_promise_reject_pending(ctx) }
		if st := jsb.host(&none, api_decl.Fs_seek, wj.wr_Fs_seek, id, i64(num)); st != .None { return fs_reject(ctx, st, "seek") }
		return wj.web_promise_take(ctx, wj.UNDEFINED)
	case .Truncate:
		if !has { wj.wj_throw_dom(ctx, "SyntaxError", "truncate needs a size"); return wj.web_promise_reject_pending(ctx) }
		if st := jsb.host(&none, api_decl.Fs_truncate, wj.wr_Fs_truncate, id, i64(num)); st != .None { return fs_reject(ctx, st, "truncate") }
		return wj.web_promise_take(ctx, wj.UNDEFINED)
	case .Write:
		d := wj.JS_GetPropertyStr(ctx, chunk, "data")
		if wj.is_nullish(d) { wj.JS_FreeValue(ctx, d); wj.wj_throw_dom(ctx, "SyntaxError", "write needs data"); return wj.web_promise_reject_pending(ctx) }
		r := write_data(ctx, id, d, has ? i64(num) : -1)
		wj.JS_FreeValue(ctx, d)
		return r
	}
	return wj.UNDEFINED
}

// close (magic 0: commit) and abort (magic 1)
@(private = "file")
sink_close :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, fdata: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	st := jsb.host(&none, api_decl.Fs_close, wj.wr_Fs_close, data_id(ctx, fdata[0]), magic == 0)
	return st != .None && magic == 0 ? fs_reject(ctx, st, "close") : wj.web_promise_take(ctx, wj.UNDEFINED)
}

@(export, link_name = "wjr_FileSystemFileHandle_createWritable")
wjr_FileSystemFileHandle_createWritable :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := fsh_this(ctx, t, .File)
	if h == nil { return wj.web_promise_reject_pending(ctx) }
	keep, ok := bool_option(ctx, wj.arg(argc, argv, 0), "FileSystemCreateWritableOptions", "keepExistingData")
	if !ok { return wj.web_promise_reject_pending(ctx) }
	id: u64
	if st := jsb.host(&id, api_decl.Fs_open, wj.wr_Fs_open, h.root, h.path, keep, false); st != .None { return fs_reject(ctx, st, "createWritable") }
	idv := wj.new_float64(ctx, f64(id))
	sink := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, sink, "write", wj.JS_NewCFunctionData(ctx, sink_write, 2, 0, 1, &idv))
	wj.JS_SetPropertyStr(ctx, sink, "close", wj.JS_NewCFunctionData(ctx, sink_close, 0, 0, 1, &idv))
	wj.JS_SetPropertyStr(ctx, sink, "abort", wj.JS_NewCFunctionData(ctx, sink_close, 1, 1, 1, &idv))
	s := web_writable_new(ctx, fs_iface(.Writable), sink, 1, wj.UNDEFINED)
	wj.JS_FreeValue(ctx, sink)
	wj.JS_FreeValue(ctx, idv)
	return settled(ctx, s)
}

@(export, link_name = "wjr_FileSystemWritableFileStream_write")
wjr_FileSystemWritableFileStream_write :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, fs_iface(.Writable)) == nil { return wj.web_promise_reject_pending(ctx) }
	if argc < 1 { wj.wj_throw_arity(ctx, "FileSystemWritableFileStream.write", 1, argc); return wj.web_promise_reject_pending(ctx) }
	return web_writable_write(ctx, t, argv[0])
}

// seek(position) / truncate(size): a WriteParams written through the stream
@(private = "file")
command :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, type: cstring, member: cstring) -> wj.JSValue {
	if wj.wj_this(ctx, t, fs_iface(.Writable)) == nil { return wj.web_promise_reject_pending(ctx) }
	v: f64
	if argc < 1 { wj.wj_throw_arity(ctx, type, 1, argc); return wj.web_promise_reject_pending(ctx) }
	if wj.JS_ToFloat64(ctx, &v, argv[0]) < 0 { return wj.web_promise_reject_pending(ctx) }
	params := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, params, "type", wj.new_string(ctx, type))
	wj.JS_SetPropertyStr(ctx, params, member, wj.new_float64(ctx, v))
	r := web_writable_write(ctx, t, params)
	wj.JS_FreeValue(ctx, params)
	return r
}

@(export, link_name = "wjr_FileSystemWritableFileStream_seek")
wjr_FileSystemWritableFileStream_seek :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return command(ctx, t, argc, argv, "seek", "position") }
@(export, link_name = "wjr_FileSystemWritableFileStream_truncate")
wjr_FileSystemWritableFileStream_truncate :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return command(ctx, t, argc, argv, "truncate", "size") }

// ---- FileSystemSyncAccessHandle (dedicated workers) ----

@(private = "file")
Sync_Impl :: struct { id: u64, closed: bool }

@(private = "file")
sync_free :: proc "c" (p: rawptr) {
	context = jsb.glue_context()
	s := (^Sync_Impl)(p)
	if !s.closed { jsb.host(&none, api_decl.Fs_close, wj.wr_Fs_close, s.id, false) }
	wj.libc_free(s)
}

@(export, link_name = "wjr_FileSystemFileHandle_createSyncAccessHandle")
wjr_FileSystemFileHandle_createSyncAccessHandle :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := fsh_this(ctx, t, .File)
	if h == nil { return wj.web_promise_reject_pending(ctx) }
	id: u64
	if st := jsb.host(&id, api_decl.Fs_open, wj.wr_Fs_open, h.root, h.path, true, true); st != .None { return fs_reject(ctx, st, "createSyncAccessHandle") }
	s := (^Sync_Impl)(wj.libc_calloc(1, size_of(Sync_Impl)))
	if s == nil {
		jsb.host(&none, api_decl.Fs_close, wj.wr_Fs_close, id, false)
		wj.JS_ThrowOutOfMemory(ctx)
		return wj.web_promise_reject_pending(ctx)
	}
	s.id = id
	return settled(ctx, wj.wj_new_object(ctx, fs_iface(.Sync), s, sync_free))
}

@(private = "file")
sync_this :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue) -> ^Sync_Impl {
	s := (^Sync_Impl)(wj.this_impl(ctx, t, fs_iface(.Sync)))
	if s != nil && s.closed { wj.wj_throw_dom(ctx, "InvalidStateError", "The access handle was closed."); return nil }
	return s
}

@(private = "file") MAX_SAFE_INTEGER :: 9007199254740991.0

// FileSystemReadWriteOptions.at: -1 when absent. False with an exception pending.
@(private = "file")
at_option :: proc "contextless" (ctx: ^wj.Context, opt: wj.JSValue) -> (at: i64, ok: bool) {
	at = -1
	if !wj.web_dict_check(ctx, opt, "FileSystemReadWriteOptions") { return }
	v: wj.JSValue
	if !wj.web_dict_get(ctx, opt, "at", &v) { return }
	if wj.is_undefined(v) { return at, true }
	d: f64
	converted := wj.JS_ToFloat64(ctx, &d, v) == 0
	wj.JS_FreeValue(ctx, v)
	if !converted { return }
	if !(d >= 0) || d > MAX_SAFE_INTEGER { wj.JS_ThrowTypeError(ctx, "Value is outside the 'unsigned long long' value range."); return }
	return i64(d), true
}

@(private = "file")
sync_rw :: proc(ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, write: bool) -> wj.JSValue {
	s := sync_this(ctx, t)
	if s == nil { return wj.EXCEPTION }
	what: cstring = write ? "write" : "read"
	if argc < 1 { return wj.wj_throw_arity(ctx, what, 1, argc) }
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, argv[0], &p, &n, wj.BS_ALLOW_SHARED, what) { return wj.EXCEPTION }
	at, ok := at_option(ctx, wj.arg(argc, argv, 1))
	if !ok { return wj.EXCEPTION }
	done: i64
	st := write ? jsb.host(&done, api_decl.Fs_write, wj.wr_Fs_write, s.id, at, bytes_of(p, n)) : jsb.host(&done, api_decl.Fs_read, wj.wr_Fs_read, s.id, at, bytes_of(p, n))
	if st != .None { return fs_throw(ctx, st, what) }
	return wj.new_int64(ctx, done)
}

@(export, link_name = "wjr_FileSystemSyncAccessHandle_read")
wjr_FileSystemSyncAccessHandle_read :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return sync_rw(ctx, t, argc, argv, false)
}
@(export, link_name = "wjr_FileSystemSyncAccessHandle_write")
wjr_FileSystemSyncAccessHandle_write :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return sync_rw(ctx, t, argc, argv, true)
}

@(export, link_name = "wjr_FileSystemSyncAccessHandle_truncate")
wjr_FileSystemSyncAccessHandle_truncate :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	s := sync_this(ctx, t)
	if s == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "truncate", 1, argc) }
	d: f64
	if wj.JS_ToFloat64(ctx, &d, argv[0]) < 0 { return wj.EXCEPTION }
	if !(d >= 0) || d > MAX_SAFE_INTEGER { return wj.JS_ThrowTypeError(ctx, "Value is outside the 'unsigned long long' value range.") }
	if st := jsb.host(&none, api_decl.Fs_truncate, wj.wr_Fs_truncate, s.id, i64(d)); st != .None { return fs_throw(ctx, st, "truncate") }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_FileSystemSyncAccessHandle_getSize")
wjr_FileSystemSyncAccessHandle_getSize :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	s := sync_this(ctx, t)
	if s == nil { return wj.EXCEPTION }
	n: i64
	if st := jsb.host(&n, api_decl.Fs_size, wj.wr_Fs_size, s.id); st != .None { return fs_throw(ctx, st, "getSize") }
	return wj.new_int64(ctx, n)
}

@(export, link_name = "wjr_FileSystemSyncAccessHandle_flush")
wjr_FileSystemSyncAccessHandle_flush :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	s := sync_this(ctx, t)
	if s == nil { return wj.EXCEPTION }
	if st := jsb.host(&none, api_decl.Fs_flush, wj.wr_Fs_flush, s.id); st != .None { return fs_throw(ctx, st, "flush") }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_FileSystemSyncAccessHandle_close")
wjr_FileSystemSyncAccessHandle_close :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	s := (^Sync_Impl)(wj.this_impl(ctx, t, fs_iface(.Sync)))
	if s == nil { return wj.EXCEPTION }
	if !s.closed {
		s.closed = true
		jsb.host(&none, api_decl.Fs_close, wj.wr_Fs_close, s.id, false)
	}
	return wj.UNDEFINED
}

// ---- getDirectory, pickers, drops ----

// navigator.storage.getDirectory() and StorageBucket.getDirectory(): an origin private file system's root (the
// bucket's name, "" for the default one).
@(export, link_name = "web_fs_get_directory")
web_fs_get_directory :: proc "c" (ctx: ^wj.Context, bucket: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	b: wj.Str
	if wj.is_string(bucket) && !wj.web_to_usv(ctx, bucket, &b) { return wj.web_promise_reject_pending(ctx) }
	root: u64
	st := jsb.host(&root, api_decl.Fs_opfsRoot, wj.wr_Fs_opfsRoot, string(wj.str_slice(b)))
	wj.wj_str_free(ctx, &b)
	if st != .None { return fs_reject(ctx, st, "getDirectory") }
	return settled(ctx, handle_new(ctx, root, "", true, ""))
}

// The picker's handles: `data` is 1 when the result is a sequence (showOpenFilePicker).
@(private = "file")
settle_picked :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	text := wj.wj_host_promise_text(ctx, host)
	n: uint
	s := wj.to_cstring_len(ctx, &n, text)
	lines := s != nil ? string(([^]u8)(rawptr(s))[:n]) : ""
	r: wj.JSValue
	if state != 1 {
		reject^ = true
		r = wj.web_error_value(ctx, i32(value), wj.raw_bytes(lines), uint(len(lines)))
	} else {
		seq: i32
		wj.JS_ToInt32(ctx, &seq, data)
		arr := wj.JS_NewArray(ctx)
		k: u32
		rest := lines
		for len(rest) > 0 {
			cut := len(rest)
			for j in 0 ..< len(rest) { if rest[j] == '\n' { cut = j; break } }
			if cut > 0 {
				h := handle_from_line(ctx, rest[:cut])
				if !wj.is_exception(h) { wj.JS_SetPropertyUint32(ctx, arr, k, h); k += 1 }
			}
			rest = cut < len(rest) ? rest[cut + 1:] : ""
		}
		if seq != 0 { r = arr } else { r = wj.JS_GetPropertyUint32(ctx, arr, 0); wj.JS_FreeValue(ctx, arr) }
	}
	if s != nil { wj.free_cstring(ctx, s) }
	wj.JS_FreeValue(ctx, text)
	return r
}

// types: [{description, accept: {mime: ext | [ext]}}] -> "description TAB *.ext TAB ..." lines
@(private = "file")
types_spec :: proc "contextless" (ctx: ^wj.Context, types: wj.JSValue, out: ^wj.Web_Buf) -> bool {
	if wj.is_undefined(types) { return true }
	n: i64
	if wj.JS_GetLength(ctx, types, &n) < 0 { return false }
	for i in 0 ..< n {
		t := wj.JS_GetPropertyInt64(ctx, types, i)
		d := wj.JS_GetPropertyStr(ctx, t, "description")
		acc := wj.JS_GetPropertyStr(ctx, t, "accept")
		ds := wj.is_undefined(d) ? nil : wj.to_cstring(ctx, d)
		if ds != nil { wj.web_buf_puts(out, string(ds)); wj.free_cstring(ctx, ds) }
		ok := wj.is_object(acc) ? accept_spec(ctx, acc, out) : true
		wj.web_buf_puts(out, "\n")
		wj.JS_FreeValue(ctx, d)
		wj.JS_FreeValue(ctx, acc)
		wj.JS_FreeValue(ctx, t)
		if !ok { return false }
	}
	return true
}

// The extensions of an `accept` record (each MIME type must be type/subtype; each extension starts with '.' and has
// at most 16 characters after it).
@(private = "file")
accept_spec :: proc "contextless" (ctx: ^wj.Context, acc: wj.JSValue, out: ^wj.Web_Buf) -> bool {
	props: [^]wj.Property_Enum
	np: u32
	if wj.JS_GetOwnPropertyNames(ctx, &props, &np, acc, wj.GPN_STRING_MASK | wj.GPN_ENUM_ONLY) != 0 { return true }
	defer wj.JS_FreePropertyEnum(ctx, props, np)
	for k in 0 ..< np {
		ml: uint
		mime := wj.JS_AtomToCStringLen(ctx, &ml, props[k].atom)
		has_slash := false
		if mime != nil { for c in string(mime) { if c == '/' { has_slash = true; break } } }
		if mime != nil { wj.free_cstring(ctx, mime) }
		if !has_slash { wj.JS_ThrowTypeError(ctx, "The accept member names an invalid MIME type."); return false }
		ev := wj.JS_GetProperty(ctx, acc, props[k].atom)
		list: wj.JSValue
		if wj.is_string(ev) {
			list = wj.JS_NewArray(ctx)
			wj.JS_SetPropertyUint32(ctx, list, 0, wj.JS_DupValue(ctx, ev))
		} else {
			list = wj.JS_DupValue(ctx, ev)
		}
		m: i64
		wj.JS_GetLength(ctx, list, &m)
		ok := true
		for j in 0 ..< m {
			e := wj.JS_GetPropertyInt64(ctx, list, j)
			es := wj.to_cstring(ctx, e)
			wj.JS_FreeValue(ctx, e)
			ext := es != nil ? string(es) : ""
			if es == nil || len(ext) == 0 || ext[0] != '.' || len(ext) > 17 {
				if es != nil { wj.free_cstring(ctx, es) }
				wj.JS_ThrowTypeError(ctx, "An extension must start with '.' and be at most 16 characters.")
				ok = false
				break
			}
			wj.web_buf_puts(out, "\t*")
			wj.web_buf_puts(out, ext)
			wj.free_cstring(ctx, es)
		}
		wj.JS_FreeValue(ctx, list)
		wj.JS_FreeValue(ctx, ev)
		if !ok { return false }
	}
	return true
}

@(private = "file")
Picker :: enum i32 { Open = 0, Save = 1, Directory = 2 }

@(private = "file")
well_known_dirs := [6]string{ "desktop", "documents", "downloads", "music", "pictures", "videos" }

@(private = "file")
show_picker :: proc(ctx: ^wj.Context, kind: Picker, opt: wj.JSValue) -> wj.JSValue {
	if !wj.web_dict_check(ctx, opt, "FilePickerOptions") { return wj.web_promise_reject_pending(ctx) }
	v: wj.JSValue
	multiple, exclude, readwrite: bool
	spec: wj.Web_Buf
	defer wj.web_buf_free(&spec)
	suggested, id: wj.Str
	defer wj.wj_str_free(ctx, &suggested)
	defer wj.wj_str_free(ctx, &id)
	start_in: string
	start_root: u64
	start_path: string
	if kind != .Directory {
		types := wj.UNDEFINED
		ok := wj.web_dict_get(ctx, opt, "types", &types) && types_spec(ctx, types, &spec)
		wj.JS_FreeValue(ctx, types)
		if !ok { return wj.web_promise_reject_pending(ctx) }
		if wj.web_dict_get(ctx, opt, "excludeAcceptAllOption", &v) { exclude = wj.JS_ToBool(ctx, v) > 0; wj.JS_FreeValue(ctx, v) }
		if exclude && spec.len == 0 { wj.JS_ThrowTypeError(ctx, "excludeAcceptAllOption needs types."); return wj.web_promise_reject_pending(ctx) }
	}
	if kind == .Open && wj.web_dict_get(ctx, opt, "multiple", &v) { multiple = wj.JS_ToBool(ctx, v) > 0; wj.JS_FreeValue(ctx, v) }
	if kind == .Save && wj.web_dict_get(ctx, opt, "suggestedName", &v) {
		if !wj.is_nullish(v) { wj.web_to_usv(ctx, v, &suggested) }
		wj.JS_FreeValue(ctx, v)
	}
	if kind == .Directory && wj.web_dict_get(ctx, opt, "mode", &v) {
		m := wj.is_undefined(v) ? nil : wj.to_cstring(ctx, v)
		readwrite = m != nil && string(m) == "readwrite"
		if m != nil { wj.free_cstring(ctx, m) }
		wj.JS_FreeValue(ctx, v)
	}
	if wj.web_dict_get(ctx, opt, "id", &v) {
		if !wj.is_undefined(v) { wj.wj_to_str(ctx, v, &id, 0, "") }
		wj.JS_FreeValue(ctx, v)
	}
	if wj.web_dict_get(ctx, opt, "startIn", &v) {
		if sh := fsh_of(v); sh != nil {
			start_root = sh.root
			start_path = sh.path   // (the handle outlives the call: the options object keeps it)
		} else if wj.is_string(v) {
			s := wj.to_cstring(ctx, v)
			known := false
			for d in well_known_dirs {
				if s != nil && string(s) == d { start_in = d; known = true }
			}
			if s != nil { wj.free_cstring(ctx, s) }
			if !known {
				wj.JS_FreeValue(ctx, v)
				wj.JS_ThrowTypeError(ctx, "The provided value is not a valid enum value of type WellKnownDirectory.")
				return wj.web_promise_reject_pending(ctx)
			}
		}
		wj.JS_FreeValue(ctx, v)
	}
	host: abi.Handle
	st := jsb.host(&host, api_decl.Fs_showPicker, wj.wr_Fs_showPicker, i32(kind), string(wj.web_buf_bytes(&spec)), multiple, exclude,
		string(wj.str_slice(suggested)), start_in, start_root, start_path, string(wj.str_slice(id)), readwrite)
	if st != .None { return fs_reject(ctx, st, "showPicker") }
	return wj.wj_promise_from_host(ctx, u64(host), wj.HOST_NUMBER, settle_picked, wj.new_int32(kind == .Open ? 1 : 0))
}

@(export, link_name = "wjr_Window_showOpenFilePicker")
wjr_Window_showOpenFilePicker :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return show_picker(ctx, .Open, wj.arg(argc, argv, 0))
}
@(export, link_name = "wjr_Window_showSaveFilePicker")
wjr_Window_showSaveFilePicker :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return show_picker(ctx, .Save, wj.arg(argc, argv, 0))
}
@(export, link_name = "wjr_Window_showDirectoryPicker")
wjr_Window_showDirectoryPicker :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return show_picker(ctx, .Directory, wj.arg(argc, argv, 0))
}

// getAsFileSystemHandle() of a dropped item (web_dnd.odin gives the data transfer and the index)
fs_item_handle :: proc(ctx: ^wj.Context, dt: api_decl.DataTransfer, index: i32) -> wj.JSValue {
	line: string
	if st := jsb.host(&line, api_decl.DataTransfer_itemFsHandle, wj.wr_DataTransfer_itemFsHandle, dt, index); st != .None {
		return fs_reject(ctx, st, "getAsFileSystemHandle")
	}
	if len(line) == 0 { return wj.web_promise_take(ctx, wj.NULL) }
	// (the line lives in the scratch buffer: handle_from_line copies what it keeps before any other host call)
	return settled(ctx, handle_from_line(ctx, line))
}

// Pre-initialization: a directory handle is async iterable (its @@asyncIterator is entries, Web IDL).
@(export, link_name = "web_fs_preinit")
web_fs_preinit :: proc "c" (ctx: ^wj.Context) -> i32 {
	proto := wj.realm_proto(fs_iface(.Directory))
	if !wj.is_object(proto) { return 0 }
	entries := wj.JS_GetPropertyStr(ctx, proto, "entries")
	a := symbol_atom(ctx, "asyncIterator")
	if wj.JS_IsFunction(ctx, entries) {
		wj.JS_DefinePropertyValue(ctx, proto, a, wj.JS_DupValue(ctx, entries), wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
	}
	wj.JS_FreeAtom(ctx, a)
	wj.JS_FreeValue(ctx, entries)
	return 0
}

// ---- structured clone (runtime/clone.c) ----

// "root description \n path \n f|d \n name" (on the libc heap: clone.c frees it), nil when the root is unknown
@(export, link_name = "web_fs_handle_describe")
web_fs_handle_describe :: proc "c" (ctx: ^wj.Context, v: wj.JSValue) -> [^]u8 {
	context = jsb.glue_context()
	h := fsh_of(v)
	if h == nil { return nil }
	desc: string
	jsb.host(&desc, api_decl.Fs_describe, wj.wr_Fs_describe, h.root)
	if len(desc) == 0 { return nil }
	parts := [?]string{ desc, "\n", h.path, "\n", h.dir ? "d" : "f", "\n", h.name }
	total := 0
	for p in parts { total += len(p) }
	out := ([^]u8)(wj.libc_malloc(uint(total) + 1))
	if out == nil { return nil }
	k := 0
	for p in parts { k += copy(out[k:total], p) }
	out[k] = 0
	return out
}

@(export, link_name = "web_fs_handle_restore")
web_fs_handle_restore :: proc "c" (ctx: ^wj.Context, desc: [^]u8, length: uint) -> wj.JSValue {
	context = jsb.glue_context()
	f := [4]string{"", "", "f", ""}
	fields(string(desc[:length]), '\n', f[:])
	root: u64
	if st := jsb.host(&root, api_decl.Fs_restore, wj.wr_Fs_restore, f[0]); st != .None { return fs_throw(ctx, st, "structuredClone") }
	return handle_new(ctx, root, f[1], f[2] == "d", f[3])
}
