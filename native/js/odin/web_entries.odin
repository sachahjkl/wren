// web_entries.odin: the File and Directory Entries API for files and folders the user dropped (module entries,
// src/page/dnd_entries.odin): FileSystemEntry and its file and directory kinds, FileSystemDirectoryReader, FileSystem.
// The browser lists folders and opens files on a background thread and settles a promise of its own; the callbacks of
// the API (success, error) run when it settles. Ported from native/js/runtime/web_entries.c: same wjr_* symbols and
// behaviour. The host calls are declared in native/js/odin_abi/api_decl/entries.odin and made through jsb; what is
// written here is the callback protocol, the error naming and the [SameObject] root.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

FileSystemEntry           :: api_decl.FileSystemEntry
FileSystemDirectoryEntry  :: api_decl.FileSystemDirectoryEntry
FileSystemDirectoryReader :: api_decl.FileSystemDirectoryReader

@(private = "file") iface_file_entry := i32(-2)
@(private = "file") iface_filesystem := i32(-2)

@(private = "file")
file_entry_iface :: proc "contextless" () -> i32 {
	if iface_file_entry == -2 { iface_file_entry = wj.iface("FileSystemFileEntry") }
	return iface_file_entry
}
@(private = "file")
filesystem_iface :: proc "contextless" () -> i32 {
	if iface_filesystem == -2 { iface_filesystem = wj.iface("FileSystem") }
	return iface_filesystem
}

// The wrapper of an entry handle: FileSystemDirectoryEntry or FileSystemFileEntry (owned: released with it). Also the
// web.h symbol web_entry_wrap.
@(export, link_name = "web_entry_wrap")
entry_wrap :: proc "c" (ctx: ^wj.Context, h: u64) -> wj.JSValue {
	if h == 0 { return wj.NULL }
	info: wj.wr_FsEntryInfo
	wj.wr_FsEntry_info(h, &info)
	return wj.wj_wrap_owned(ctx, h, info.is_dir != 0 ? jsb.iface_of(FileSystemDirectoryEntry) : file_entry_iface(), wj.UNDEFINED)
}

@(private = "file")
entry_is_dir :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> (is_dir: bool, ok: bool) {
	h := jsb.this(ctx, this_val, FileSystemEntry) or_return
	info: wj.wr_FsEntryInfo
	wj.wr_FsEntry_info(u64(h), &info)
	return info.is_dir != 0, true
}

@(export, link_name = "wjr_FileSystemEntry_get_isFile")
wjr_FileSystemEntry_get_isFile :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	d, ok := entry_is_dir(ctx, this_val)
	return ok ? wj.new_bool(!d) : wj.EXCEPTION
}

@(export, link_name = "wjr_FileSystemEntry_get_isDirectory")
wjr_FileSystemEntry_get_isDirectory :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	d, ok := entry_is_dir(ctx, this_val)
	return ok ? wj.new_bool(d) : wj.EXCEPTION
}

@(export, link_name = "wjr_FileSystemEntry_get_name")
wjr_FileSystemEntry_get_name :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, this_val, 0, nil, api_decl.FsEntry_name, wj.wr_FsEntry_name, "FileSystemEntry.name")
}

@(export, link_name = "wjr_FileSystemEntry_get_fullPath")
wjr_FileSystemEntry_get_fullPath :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, this_val, 0, nil, api_decl.FsEntry_fullPath, wj.wr_FsEntry_fullPath, "FileSystemEntry.fullPath")
}

// ---- FileSystem: its name (one per drop) and its [SameObject] root ----

@(private = "file")
Fs_Impl :: struct {
	name: [^]u8,   // web_strndup'ed (libc heap)
}

@(private = "file")
fs_impl_free :: proc "c" (p: rawptr) {
	f := (^Fs_Impl)(p)
	wj.libc_free(f.name)
	wj.libc_free(f)
}

@(export, link_name = "wjr_FileSystemEntry_get_filesystem")
wjr_FileSystemEntry_get_filesystem :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, this_val, FileSystemEntry)
	if !ok { return wj.EXCEPTION }
	name: string
	jsb.host(&name, api_decl.FsEntry_filesystemName, wj.wr_FsEntry_filesystemName, h)
	f := (^Fs_Impl)(wj.libc_calloc(1, size_of(Fs_Impl)))
	if f == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	f.name = wj.web_strndup(raw_data(name), uint(len(name)))
	obj := wj.wj_new_object(ctx, filesystem_iface(), f, fs_impl_free)
	if !wj.is_exception(obj) {
		// the folder (or file) that was dropped, made now while the entry is alive
		root: FileSystemEntry
		jsb.host(&root, api_decl.FsEntry_root, wj.wr_FsEntry_root, h)
		wj.web_extra_set(ctx, obj, "root", entry_wrap(ctx, u64(root)))
	}
	return obj
}

@(export, link_name = "wjr_FileSystem_get_root")
wjr_FileSystem_get_root :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.this_impl(ctx, this_val, filesystem_iface()) == nil { return wj.EXCEPTION }
	r := wj.web_extra_get(ctx, this_val, "root")
	return wj.is_undefined(r) ? wj.NULL : r
}

@(export, link_name = "wjr_FileSystem_get_name")
wjr_FileSystem_get_name :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	f := (^Fs_Impl)(wj.this_impl(ctx, this_val, filesystem_iface()))
	if f == nil { return wj.EXCEPTION }
	return f.name != nil ? wj.new_string(ctx, wj.cstr(f.name)) : wj.new_string(ctx, "")
}

// ---- callbacks: success / error from a settled browser promise ----

// What a settled operation calls: the callbacks (undefined when absent) and what the settle function needs, kept as
// the bridge's `data` array [success, error, extra].
@(private = "file")
Callback :: enum u32 { Success = 0, Error = 1, Extra = 2 }

@(private = "file")
callbacks_data :: proc "contextless" (ctx: ^wj.Context, success, error, extra: wj.JSValue) -> wj.JSValue {
	d := wj.JS_NewArray(ctx)
	if wj.is_exception(d) { return d }
	wj.array_set(ctx, d, u32(Callback.Success), wj.JS_DupValue(ctx, wj.JS_IsFunction(ctx, success) ? success : wj.UNDEFINED))
	wj.array_set(ctx, d, u32(Callback.Error), wj.JS_DupValue(ctx, wj.JS_IsFunction(ctx, error) ? error : wj.UNDEFINED))
	wj.array_set(ctx, d, u32(Callback.Extra), wj.JS_DupValue(ctx, extra))
	return d
}

// Calls callback `which` of `data` with `arg` (taken); an exception it throws is reported.
@(private = "file")
call_back :: proc "contextless" (ctx: ^wj.Context, data: wj.JSValue, which: Callback, arg: wj.JSValue) {
	arg := arg
	cb := wj.JS_GetPropertyUint32(ctx, data, u32(which))
	if wj.JS_IsFunction(ctx, cb) {
		r := wj.JS_Call(ctx, cb, wj.UNDEFINED, 1, &arg)
		if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
	}
	wj.JS_FreeValue(ctx, cb)
	wj.JS_FreeValue(ctx, arg)
}

// A rejection as the DOMException the API names ("TypeMismatchError: ..." in the text: that name), else the error the
// code names.
@(private = "file")
error_of :: proc "contextless" (ctx: ^wj.Context, host: u64, code: i64) -> wj.JSValue {
	promise := host
	n := wj.fetch_string(proc "contextless" (user: rawptr, buf: [^]u8, cap: u32) -> i32 {
		return wj.wr_Promise_text((^u64)(user)^, buf, cap)
	}, &promise)
	text := string(wj.scratch_bytes(n))
	for i := 0; i < min(len(text), 40); i += 1 {
		if text[i] != ':' { continue }
		if i >= 5 && i + 2 <= len(text) && text[i - 5:i] == "Error" {
			name: [48]u8
			copy(name[:], text[:i])
			rest := text[i + 2:]
			msg := wj.web_strndup(raw_data(rest), uint(len(rest)))
			e := wj.web_dom_exception(ctx, cstring(&name[0]), msg != nil ? wj.cstr(msg) : "")
			wj.libc_free(msg)
			return e
		}
		break
	}
	return wj.web_error_value(ctx, i32(code), raw_data(text), uint(len(text)))
}

// file(): the File. (An error goes to the error callback: the bridge's own promise is not a rejection anyone sees.)
@(private = "file")
settle_file :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	reject^ = false
	if state == 1 { call_back(ctx, data, .Success, wj.web_file_from_host(ctx, u64(value))) }
	else { call_back(ctx, data, .Error, error_of(ctx, host, value)) }
	return wj.UNDEFINED
}

// getFile / getDirectory: the entry
@(private = "file")
settle_entry :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	reject^ = false
	if state == 1 { call_back(ctx, data, .Success, entry_wrap(ctx, u64(value))) }
	else { call_back(ctx, data, .Error, error_of(ctx, host, value)) }
	return wj.UNDEFINED
}

// readEntries(): an array of the batch's entries
@(private = "file")
settle_batch :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	context = jsb.glue_context()
	reject^ = false
	if state != 1 { call_back(ctx, data, .Error, error_of(ctx, host, value)); return wj.UNDEFINED }
	reader := wj.JS_GetPropertyUint32(ctx, data, u32(Callback.Extra))
	o := wj.wj_unwrap(reader, jsb.iface_of(FileSystemDirectoryReader))
	arr := wj.JS_NewArray(ctx)
	for i in 0 ..< (o != nil ? i32(value) : 0) {
		e: FileSystemEntry
		jsb.host(&e, api_decl.FsReader_entry, wj.wr_FsReader_entry, FileSystemDirectoryReader(o.handle), i)
		wj.array_set(ctx, arr, u32(i), entry_wrap(ctx, u64(e)))
	}
	wj.JS_FreeValue(ctx, reader)
	call_back(ctx, data, .Success, arr)
	return wj.UNDEFINED
}

// Starts the browser's operation `host` with the callbacks; the API returns undefined.
@(private = "file")
start :: proc "contextless" (ctx: ^wj.Context, host: abi.Handle, settle: wj.Host_Settle, success, error, extra: wj.JSValue) -> wj.JSValue {
	d := callbacks_data(ctx, success, error, extra)
	if wj.is_exception(d) { return d }
	p := wj.wj_promise_from_host(ctx, u64(host), wj.HOST_UNDEFINED, settle, d)
	wj.JS_FreeValue(ctx, d)
	wj.JS_FreeValue(ctx, p)
	return wj.UNDEFINED
}

@(private = "file")
check_callback :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, required: bool, what: cstring) -> bool {
	if wj.JS_IsFunction(ctx, v) || (!required && wj.is_nullish(v)) { return true }
	wj.JS_ThrowTypeError(ctx, "Failed to execute '%s': the callback provided is not a function.", what)
	return false
}

@(export, link_name = "wjr_FileSystemFileEntry_file")
wjr_FileSystemFileEntry_file :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, file_entry_iface())
	if o == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "FileSystemFileEntry.file", 1, argc) }
	ok, err := argv[0], wj.arg(argc, argv, 1)
	if !check_callback(ctx, ok, true, "file") || !check_callback(ctx, err, false, "file") { return wj.EXCEPTION }
	p: abi.Handle
	jsb.host(&p, api_decl.FsEntry_file, wj.wr_FsEntry_file, FileSystemEntry(o.handle))
	return start(ctx, p, settle_file, ok, err, wj.UNDEFINED)
}

// getParent(): the folder above, answered from a task as the other operations
@(private = "file")
parent_task :: proc "c" (ctx: ^wj.Context, data: wj.JSValue) {
	call_back(ctx, data, .Success, wj.JS_GetPropertyUint32(ctx, data, u32(Callback.Extra)))
}

@(export, link_name = "wjr_FileSystemEntry_getParent")
wjr_FileSystemEntry_getParent :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, hok := jsb.this(ctx, this_val, FileSystemEntry)
	if !hok { return wj.EXCEPTION }
	ok, err := wj.arg(argc, argv, 0), wj.arg(argc, argv, 1)
	if !check_callback(ctx, ok, false, "getParent") || !check_callback(ctx, err, false, "getParent") { return wj.EXCEPTION }
	up: FileSystemEntry
	jsb.host(&up, api_decl.FsEntry_parent, wj.wr_FsEntry_parent, h)
	parent := entry_wrap(ctx, u64(up))
	if wj.is_exception(parent) { return parent }
	d := callbacks_data(ctx, ok, err, parent)
	wj.JS_FreeValue(ctx, parent)
	if wj.is_exception(d) { return d }
	queued := wj.web_queue_task(ctx, parent_task, d)
	wj.JS_FreeValue(ctx, d)
	return queued ? wj.UNDEFINED : wj.EXCEPTION
}

// getFile(path, options, success, error) / getDirectory(...): options.create is refused (what was dropped is read only)
@(private = "file")
lookup :: proc(ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, directory: bool, what: cstring) -> wj.JSValue {
	h, hok := jsb.this(ctx, this_val, FileSystemDirectoryEntry)
	if !hok { return wj.EXCEPTION }
	opts := wj.arg(argc, argv, 1)
	ok, err := wj.arg(argc, argv, 2), wj.arg(argc, argv, 3)
	if !check_callback(ctx, ok, false, what) || !check_callback(ctx, err, false, what) { return wj.EXCEPTION }
	if !wj.web_dict_check(ctx, opts, what) { return wj.EXCEPTION }
	create := wj.UNDEFINED
	if !wj.web_dict_get(ctx, opts, "create", &create) { return wj.EXCEPTION }
	creating := wj.JS_ToBool(ctx, create) > 0
	wj.JS_FreeValue(ctx, create)
	path: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 0), &path, wj.STR_NULLABLE | wj.STR_OPTIONAL | wj.STR_USV, nil) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &path)
	if creating {
		d := callbacks_data(ctx, ok, err, wj.UNDEFINED)
		if wj.is_exception(d) { return d }
		call_back(ctx, d, .Error, wj.web_dom_exception(ctx, "SecurityError", "What was dropped cannot be changed."))
		wj.JS_FreeValue(ctx, d)
		return wj.UNDEFINED
	}
	p: abi.Handle
	jsb.host(&p, api_decl.FsEntry_lookup, wj.wr_FsEntry_lookup, h, string(wj.str_slice(path)), directory)
	return start(ctx, p, settle_entry, ok, err, wj.UNDEFINED)
}

@(export, link_name = "wjr_FileSystemDirectoryEntry_getFile")
wjr_FileSystemDirectoryEntry_getFile :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return lookup(ctx, this_val, argc, argv, false, "getFile")
}
@(export, link_name = "wjr_FileSystemDirectoryEntry_getDirectory")
wjr_FileSystemDirectoryEntry_getDirectory :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return lookup(ctx, this_val, argc, argv, true, "getDirectory")
}

@(export, link_name = "wjr_FileSystemDirectoryEntry_createReader")
wjr_FileSystemDirectoryEntry_createReader :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, ok := jsb.this(ctx, this_val, FileSystemDirectoryEntry)
	if !ok { return wj.EXCEPTION }
	r: FileSystemDirectoryReader
	jsb.host(&r, api_decl.FsEntry_createReader, wj.wr_FsEntry_createReader, h)
	if r == 0 { return wj.JS_ThrowOutOfMemory(ctx) }
	return wj.wj_wrap_owned(ctx, u64(r), jsb.iface_of(FileSystemDirectoryReader), wj.UNDEFINED)
}

@(export, link_name = "wjr_FileSystemDirectoryReader_readEntries")
wjr_FileSystemDirectoryReader_readEntries :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h, hok := jsb.this(ctx, this_val, FileSystemDirectoryReader)
	if !hok { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "FileSystemDirectoryReader.readEntries", 1, argc) }
	ok, err := argv[0], wj.arg(argc, argv, 1)
	if !check_callback(ctx, ok, true, "readEntries") || !check_callback(ctx, err, false, "readEntries") { return wj.EXCEPTION }
	p: abi.Handle
	jsb.host(&p, api_decl.FsReader_read, wj.wr_FsReader_read, h)
	return start(ctx, p, settle_batch, ok, err, this_val)
}
