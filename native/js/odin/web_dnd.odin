// web_dnd.odin: HTML drag and drop for JavaScript: DataTransfer (its store is the browser's: module dnd,
// src/page/dnd.odin; getData / setData / clearData / setDragImage / dropEffect / effectAllowed are bound to it directly
// by the generated binding), its items (DataTransferItemList, DataTransferItem), FileList (of a DataTransfer or of an
// <input type=file>) and HTMLInputElement.files. Files are the browser's (dropped, chosen), read on demand
// (web_blob.c, web_file_from_host). DragEvent and its dataTransfer are with the other UI events. Ported from
// native/js/runtime/web_dnd.c: same wjr_* symbols and behaviour; the host calls are declared in
// native/js/odin_abi/api_decl/dnd.odin and made through jsb.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

DataTransfer :: api_decl.DataTransfer

@(private = "file") none: abi.Nothing

@(private = "file") Iface :: enum { DataTransferItemList, DataTransferItem, FileList, File, HTMLInputElement }
@(private = "file") iface_names := [Iface]cstring{
	.DataTransferItemList = "DataTransferItemList", .DataTransferItem = "DataTransferItem", .FileList = "FileList",
	.File = "File", .HTMLInputElement = "HTMLInputElement",
}
@(private = "file") iface_cache := [Iface]i32{ .DataTransferItemList = -2, .DataTransferItem = -2, .FileList = -2, .File = -2, .HTMLInputElement = -2 }

@(private = "file")
iface_index :: proc "contextless" (i: Iface) -> i32 {
	if iface_cache[i] == -2 { iface_cache[i] = wj.iface(iface_names[i]) }
	return iface_cache[i]
}

// What a DataTransfer wrapper keeps: its [SameObject] items and files.
@(private = "file")
Dt_Impl :: struct { items, files: wj.JSValue }

@(private = "file")
dt_impl_free :: proc "c" (p: rawptr) {
	d := (^Dt_Impl)(p)
	rt := wj.web_rt()
	wj.JS_FreeValueRT(rt, d.items)
	wj.JS_FreeValueRT(rt, d.files)
	wj.libc_free(d)
}
@(private = "file")
dt_impl_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	d := (^Dt_Impl)(p)
	wj.wj_mark(rt, d.items, mark_func)
	wj.wj_mark(rt, d.files, mark_func)
}

// What a list object shows: the store of a DataTransfer, or the files of an <input type=file>.
@(private = "file")
Source :: union { DataTransfer, Input }
@(private = "file") Input :: distinct u64   // an <input type=file> node

// The state of an item list, an item or a file list: what it shows, the object it belongs to (kept alive), the
// Files made so far (FileList: the same File for an index while the list keeps its length), its index (an item).
@(private = "file")
List_Impl :: struct {
	source: Source,
	owner:  wj.JSValue,
	files:  wj.JSValue,
	index:  i32,
}

@(private = "file")
list_free :: proc "c" (p: rawptr) {
	l := (^List_Impl)(p)
	rt := wj.web_rt()
	wj.JS_FreeValueRT(rt, l.owner)
	wj.JS_FreeValueRT(rt, l.files)
	wj.libc_free(l)
}
@(private = "file")
list_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	l := (^List_Impl)(p)
	wj.wj_mark(rt, l.owner, mark_func)
	wj.wj_mark(rt, l.files, mark_func)
}

@(private = "file")
list_new :: proc "contextless" (ctx: ^wj.Context, iface: Iface, source: Source, owner: wj.JSValue, index: i32) -> wj.JSValue {
	l := (^List_Impl)(wj.libc_calloc(1, size_of(List_Impl)))
	if l == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	l^ = { source = source, owner = wj.JS_DupValue(ctx, owner), files = wj.UNDEFINED, index = index }
	obj := wj.wj_new_object(ctx, iface_index(iface), nil, nil)
	if wj.is_exception(obj) { list_free(l); return obj }
	wj.web_set_impl(obj, l, list_free, list_mark)
	return obj
}

@(private = "file")
list_of :: proc "contextless" (v: wj.JSValue, iface: Iface) -> ^List_Impl {
	return (^List_Impl)(wj.impl_of(wj.wj_unwrap(v, iface_index(iface))))
}

// `this` of a list member: its state, nil with a TypeError pending.
@(private = "file")
list_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, iface: Iface) -> ^List_Impl {
	if wj.wj_this(ctx, this_val, iface_index(iface)) == nil { return nil }
	return list_of(this_val, iface)
}

// The store of a DataTransfer and its kept members (made on first use).
@(private = "file")
dt_of :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> (^Dt_Impl, DataTransfer) {
	o := wj.wj_this(ctx, this_val, jsb.iface_of(DataTransfer))
	if o == nil { return nil, 0 }
	if o.impl == nil {
		d := (^Dt_Impl)(wj.libc_calloc(1, size_of(Dt_Impl)))
		if d == nil { wj.JS_ThrowOutOfMemory(ctx); return nil, 0 }
		d^ = { wj.UNDEFINED, wj.UNDEFINED }
		wj.web_set_impl(this_val, d, dt_impl_free, dt_impl_mark)
	}
	return (^Dt_Impl)(o.impl), DataTransfer(o.handle)
}

// ---- DataTransfer ----

@(export, link_name = "wjr_DataTransfer_constructor")
wjr_DataTransfer_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor DataTransfer requires 'new'") }
	h: DataTransfer
	jsb.host(&h, api_decl.DataTransfer_create, wj.wr_DataTransfer_create)
	if h == 0 { return wj.JS_ThrowOutOfMemory(ctx) }
	return wj.wj_wrap_owned(ctx, u64(h), jsb.iface_of(DataTransfer), new_target)
}

// Each "\n"-separated line of `text` as a string of a new array; an empty text is no line.
@(private = "file")
lines_array :: proc "contextless" (ctx: ^wj.Context, text: string, sep: u8) -> wj.JSValue {
	arr := wj.JS_NewArray(ctx)
	if wj.is_exception(arr) || len(text) == 0 { return arr }
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

@(export, link_name = "wjr_DataTransfer_get_types")
wjr_DataTransfer_get_types :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d, store := dt_of(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	types: string
	jsb.host(&types, api_decl.DataTransfer_typeList, wj.wr_DataTransfer_typeList, store)
	arr := lines_array(ctx, types, '\n')
	if wj.is_exception(arr) { return arr }
	if !wj.web_freeze(ctx, arr) { wj.JS_FreeValue(ctx, arr); return wj.EXCEPTION }
	return arr
}

// items / files: [SameObject], made on first use and kept by the DataTransfer
@(private = "file")
dt_member :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, files: bool) -> wj.JSValue {
	d, store := dt_of(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	slot := files ? &d.files : &d.items
	if wj.is_undefined(slot^) {
		slot^ = list_new(ctx, files ? .FileList : .DataTransferItemList, store, this_val, 0)
		if wj.is_exception(slot^) { slot^ = wj.UNDEFINED; return wj.EXCEPTION }
	}
	return wj.JS_DupValue(ctx, slot^)
}

@(export, link_name = "wjr_DataTransfer_get_items")
wjr_DataTransfer_get_items :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return dt_member(ctx, this_val, false) }
@(export, link_name = "wjr_DataTransfer_get_files")
wjr_DataTransfer_get_files :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return dt_member(ctx, this_val, true) }

// ---- DataTransferItemList ----

@(private = "file")
item_count :: proc(l: ^List_Impl) -> i32 {
	n: i32
	jsb.host(&n, api_decl.DataTransfer_itemCount, wj.wr_DataTransfer_itemCount, l.source.(DataTransfer))
	return max(n, 0)
}

@(export, link_name = "wjr_DataTransferItemList_get_length")
wjr_DataTransferItemList_get_length :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	l := list_this(ctx, this_val, .DataTransferItemList)
	if l == nil { return wj.EXCEPTION }
	n: i32
	jsb.host(&n, api_decl.DataTransfer_itemCount, wj.wr_DataTransfer_itemCount, l.source.(DataTransfer))
	return wj.new_int32(n)
}

@(export, link_name = "wjr_DataTransferItemList_length_hook")
wjr_DataTransferItemList_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 {
	context = jsb.glue_context()
	l := list_of(obj, .DataTransferItemList)
	return l != nil ? u32(item_count(l)) : 0
}

@(export, link_name = "wjr_DataTransferItemList_index_get")
wjr_DataTransferItemList_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue {
	context = jsb.glue_context()
	l := list_of(obj, .DataTransferItemList)
	if l == nil || index >= u32(item_count(l)) { found^ = false; return wj.UNDEFINED }
	found^ = true
	return list_new(ctx, .DataTransferItem, l.source, l.owner, i32(index))
}

// add(data, type) / add(file): the new item, or null when nothing was added
@(export, link_name = "wjr_DataTransferItemList_add")
wjr_DataTransferItemList_add :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	l := list_this(ctx, this_val, .DataTransferItemList)
	if l == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "DataTransferItemList.add", 1, argc) }
	store := l.source.(DataTransfer)
	st: abi.Api_Error
	if wj.wj_unwrap(argv[0], iface_index(.File)) != nil {
		if host := web_file_host(argv[0]); host != 0 {
			st = jsb.host(&none, api_decl.DataTransfer_addFile, wj.wr_DataTransfer_addFile, store, abi.Handle(host))
		} else {
			name, type: wj.Str
			lm: f64
			if !web_file_meta(ctx, argv[0], &name, &type, &lm) { return wj.EXCEPTION }
			p: [^]u8
			n: uint
			web_blob_bytes(argv[0], &p, &n)
			bytes := p != nil ? p[:n] : nil
			st = jsb.host(&none, api_decl.DataTransfer_addBytes, wj.wr_DataTransfer_addBytes, store,
				string(wj.str_slice(name)), string(wj.str_slice(type)), bytes, lm)
			wj.wj_str_free(ctx, &name)
			wj.wj_str_free(ctx, &type)
		}
	} else {
		if argc < 2 { return wj.wj_throw_arity(ctx, "DataTransferItemList.add", 2, argc) }
		data, type: wj.Str
		if !wj.wj_to_str(ctx, argv[0], &data, 0, nil) { return wj.EXCEPTION }
		if !wj.wj_to_str(ctx, argv[1], &type, 0, nil) { wj.wj_str_free(ctx, &data); return wj.EXCEPTION }
		st = jsb.host(&none, api_decl.DataTransfer_addString, wj.wr_DataTransfer_addString, store,
			string(wj.str_slice(data)), string(wj.str_slice(type)))
		wj.wj_str_free(ctx, &data)
		wj.wj_str_free(ctx, &type)
	}
	if st == .Invalid_State { return wj.NULL }   // (not in read/write mode: nothing added, null)
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "DataTransferItemList.add") }
	count: i32
	jsb.host(&count, api_decl.DataTransfer_itemCount, wj.wr_DataTransfer_itemCount, store)
	return list_new(ctx, .DataTransferItem, l.source, l.owner, count - 1)
}

@(export, link_name = "wjr_DataTransferItemList_remove")
wjr_DataTransferItemList_remove :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	l := list_this(ctx, this_val, .DataTransferItemList)
	if l == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "DataTransferItemList.remove", 1, argc) }
	i: u32
	if !wj.wj_to_uint32(ctx, argv[0], &i, 32, 0) { return wj.EXCEPTION }
	st := jsb.host(&none, api_decl.DataTransfer_removeItem, wj.wr_DataTransfer_removeItem, l.source.(DataTransfer), i32(i))
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "DataTransferItemList.remove") : wj.UNDEFINED
}

@(export, link_name = "wjr_DataTransferItemList_clear")
wjr_DataTransferItemList_clear :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	l := list_this(ctx, this_val, .DataTransferItemList)
	if l == nil { return wj.EXCEPTION }
	jsb.host(&none, api_decl.DataTransfer_clearItems, wj.wr_DataTransfer_clearItems, l.source.(DataTransfer))   // (outside read/write mode: nothing happens)
	return wj.UNDEFINED
}

// ---- DataTransferItem ----

@(export, link_name = "wjr_DataTransferItem_get_kind")
wjr_DataTransferItem_get_kind :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	l := list_this(ctx, this_val, .DataTransferItem)
	if l == nil { return wj.EXCEPTION }
	kind: api_decl.DragItemKind
	if jsb.host(&kind, api_decl.DataTransfer_itemKind, wj.wr_DataTransfer_itemKind, l.source.(DataTransfer), l.index) != .None {
		return wj.new_string(ctx, "")
	}
	switch kind {
	case .File:   return wj.new_string(ctx, "file")
	case .String: return wj.new_string(ctx, "string")
	}
	return wj.new_string(ctx, "string")
}

@(export, link_name = "wjr_DataTransferItem_get_type")
wjr_DataTransferItem_get_type :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	l := list_this(ctx, this_val, .DataTransferItem)
	if l == nil { return wj.EXCEPTION }
	type: string
	jsb.host(&type, api_decl.DataTransfer_itemType, wj.wr_DataTransfer_itemType, l.source.(DataTransfer), l.index)
	return wj.new_string_len(ctx, type)
}

@(private = "file")
call_string_callback :: proc "c" (ctx: ^wj.Context, data: wj.JSValue) {
	cb := wj.JS_GetPropertyUint32(ctx, data, 0)
	s := wj.JS_GetPropertyUint32(ctx, data, 1)
	r := wj.JS_Call(ctx, cb, wj.UNDEFINED, 1, &s)
	if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
	wj.JS_FreeValue(ctx, s)
	wj.JS_FreeValue(ctx, cb)
}

// getAsString(callback): the callback gets the data from a task of its own, when the item is a string and the data can
// be read now (not in protected mode)
@(export, link_name = "wjr_DataTransferItem_getAsString")
wjr_DataTransferItem_getAsString :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	l := list_this(ctx, this_val, .DataTransferItem)
	if l == nil { return wj.EXCEPTION }
	cb := wj.arg(argc, argv, 0)
	if wj.is_nullish(cb) { return wj.UNDEFINED }
	if !wj.JS_IsFunction(ctx, cb) { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'getAsString' on 'DataTransferItem': parameter 1 is not a function.") }
	s: string
	if jsb.host(&s, api_decl.DataTransfer_itemString, wj.wr_DataTransfer_itemString, l.source.(DataTransfer), l.index) != .None {
		return wj.UNDEFINED
	}
	data := wj.JS_NewArray(ctx)
	wj.array_set(ctx, data, 0, wj.JS_DupValue(ctx, cb))
	wj.array_set(ctx, data, 1, wj.new_string_len(ctx, s))
	ok := wj.web_queue_task(ctx, call_string_callback, data)
	wj.JS_FreeValue(ctx, data)
	return ok ? wj.UNDEFINED : wj.EXCEPTION
}

@(export, link_name = "wjr_DataTransferItem_getAsFile")
wjr_DataTransferItem_getAsFile :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	l := list_this(ctx, this_val, .DataTransferItem)
	if l == nil { return wj.EXCEPTION }
	f: abi.Handle
	if jsb.host(&f, api_decl.DataTransfer_itemFile, wj.wr_DataTransfer_itemFile, l.source.(DataTransfer), l.index) != .None || f == 0 {
		return wj.NULL
	}
	return web_file_from_host(ctx, u64(f))
}

// getAsFileSystemHandle(): a FileSystemFileHandle / FileSystemDirectoryHandle of the dropped file or folder, read
// access granted (web_fs.odin), null for a string item
@(export, link_name = "wjr_DataTransferItem_getAsFileSystemHandle")
wjr_DataTransferItem_getAsFileSystemHandle :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	l := list_this(ctx, this_val, .DataTransferItem)
	if l == nil { return wj.web_promise_reject_pending(ctx) }
	return fs_item_handle(ctx, l.source.(DataTransfer), l.index)
}

// webkitGetAsEntry(): the entry of a dropped file or folder (web_entries.odin), null for a string item or outside drop
@(export, link_name = "wjr_DataTransferItem_webkitGetAsEntry")
wjr_DataTransferItem_webkitGetAsEntry :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	l := list_this(ctx, this_val, .DataTransferItem)
	if l == nil { return wj.EXCEPTION }
	e: FileSystemEntry
	if jsb.host(&e, api_decl.DataTransfer_itemEntry, wj.wr_DataTransfer_itemEntry, l.source.(DataTransfer), l.index) != .None || e == 0 {
		return wj.NULL
	}
	return entry_wrap(ctx, u64(e))
}

// ---- FileList ----

@(private = "file")
files_count :: proc(l: ^List_Impl) -> i32 {
	n: i32
	switch s in l.source {
	case DataTransfer: jsb.host(&n, api_decl.DataTransfer_fileCount, wj.wr_DataTransfer_fileCount, s)
	case Input:        jsb.host(&n, api_decl.InputFiles_count, wj.wr_InputFiles_count, abi.Handle(s))
	}
	return n
}

@(private = "file")
files_file :: proc(l: ^List_Impl, index: i32) -> abi.Handle {
	h: abi.Handle
	st: abi.Api_Error
	switch s in l.source {
	case DataTransfer: st = jsb.host(&h, api_decl.DataTransfer_file, wj.wr_DataTransfer_file, s, index)
	case Input:        st = jsb.host(&h, api_decl.InputFiles_item, wj.wr_InputFiles_item, abi.Handle(s), index)
	}
	return st == .None ? h : 0
}

@(private = "file")
files_item :: proc(ctx: ^wj.Context, l: ^List_Impl, index: u32) -> wj.JSValue {
	n := files_count(l)
	if n <= 0 || index >= u32(n) { return wj.NULL }
	// the same File for an index while the list keeps its length
	if wj.is_undefined(l.files) { l.files = wj.JS_NewArray(ctx) }
	cached: i64
	wj.JS_GetLength(ctx, l.files, &cached)
	if cached != i64(n) {
		wj.JS_FreeValue(ctx, l.files)
		l.files = wj.JS_NewArray(ctx)
		wj.JS_SetLength(ctx, l.files, i64(n))
	}
	f := wj.JS_GetPropertyUint32(ctx, l.files, index)
	if !wj.is_undefined(f) { return f }
	h := files_file(l, i32(index))
	if h == 0 { return wj.NULL }
	f = web_file_from_host(ctx, u64(h))
	if wj.is_exception(f) { return f }
	wj.JS_SetPropertyUint32(ctx, l.files, index, wj.JS_DupValue(ctx, f))
	return f
}

@(export, link_name = "wjr_FileList_get_length")
wjr_FileList_get_length :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, this_val, iface_index(.FileList)) == nil { return wj.EXCEPTION }
	l := list_of(this_val, .FileList)
	return wj.new_int32(l != nil ? max(files_count(l), 0) : 0)
}

@(export, link_name = "wjr_FileList_item")
wjr_FileList_item :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, this_val, iface_index(.FileList)) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "FileList.item", 1, argc) }
	i: u32
	if !wj.wj_to_uint32(ctx, argv[0], &i, 32, 0) { return wj.EXCEPTION }
	l := list_of(this_val, .FileList)
	return l != nil ? files_item(ctx, l, i) : wj.NULL
}

@(export, link_name = "wjr_FileList_length_hook")
wjr_FileList_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 {
	context = jsb.glue_context()
	l := list_of(obj, .FileList)
	return l != nil ? u32(max(files_count(l), 0)) : 0
}

@(export, link_name = "wjr_FileList_index_get")
wjr_FileList_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue {
	context = jsb.glue_context()
	l := list_of(obj, .FileList)
	if l == nil { found^ = false; return wj.UNDEFINED }
	f := files_item(ctx, l, index)
	found^ = !wj.is_null(f)
	return found^ ? f : wj.UNDEFINED
}

// ---- HTMLInputElement.files ----

@(private = "file")
is_file_input :: proc "contextless" (node: u64) -> bool {
	n := wj.fetch_string_el(node, wj.raw_bytes("type"), 4)
	return n == 4 && wj.web_ascii_ieq(wj.scratch_data(), 4, "file")
}

@(export, link_name = "wjr_HTMLInputElement_get_files")
wjr_HTMLInputElement_get_files :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, iface_index(.HTMLInputElement))
	if o == nil { return wj.EXCEPTION }
	if !is_file_input(o.handle) { return wj.NULL }
	return list_new(ctx, .FileList, Input(o.handle), this_val, 0)
}

// input.files = fileList: the list's files become the selection (null, or another element than a file input: nothing)
@(export, link_name = "wjr_HTMLInputElement_set_files")
wjr_HTMLInputElement_set_files :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, iface_index(.HTMLInputElement))
	if o == nil { return wj.EXCEPTION }
	if wj.is_null(v) { return wj.UNDEFINED }
	l := list_of(v, .FileList)
	if l == nil { return wj.JS_ThrowTypeError(ctx, "Failed to set the 'files' property on 'HTMLInputElement': The provided value is not of type 'FileList'.") }
	if !is_file_input(o.handle) { return wj.UNDEFINED }
	input := abi.Handle(o.handle)
	switch s in l.source {
	case DataTransfer:
		jsb.host(&none, api_decl.InputFiles_assign, wj.wr_InputFiles_assign, input, s)
	case Input:
		// another input's list: through a store of its own
		tmp: DataTransfer
		jsb.host(&tmp, api_decl.DataTransfer_create, wj.wr_DataTransfer_create)
		for i in 0 ..< files_count(l) {
			if f := files_file(l, i); f != 0 {
				jsb.host(&none, api_decl.DataTransfer_addFile, wj.wr_DataTransfer_addFile, tmp, f)
				wj.wr_Object_release(u64(f))
			}
		}
		jsb.host(&none, api_decl.InputFiles_assign, wj.wr_InputFiles_assign, input, tmp)
		wj.wr_Object_release(u64(tmp))
	}
	return wj.UNDEFINED
}
