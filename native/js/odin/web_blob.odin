// web_blob.odin: Blob, File and FileReader (File API), URL.createObjectURL / revokeObjectURL, ProgressEvent. Ported
// from native/js/runtime/web_blob.c: same wjr_* / web_blob_* / web_file_* symbols and behaviour.
//
// A Blob's bytes live in the engine, in a reference-counted store a slice shares (slicing copies nothing). Reading a
// Blob gives copies (text(), arrayBuffer(), bytes()); a browser function that takes the bytes reads them in place
// (web_blob_bytes). blob: URLs are known to this realm only: fetch() and XMLHttpRequest of this realm resolve them
// (web_blob_url_lookup), other loads of the page (an <img src="blob:...">) do not. The URL -> Blob table is a native
// map (the C kept a JavaScript Map made at pre-initialization).
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

// The shared bytes of a Blob and its slices.
@(private = "file")
Store :: struct {
	refs:  u32,
	bytes: []u8,
}

// A file of the browser behind a File the page was given (a drop, an <input type=file>): read on demand by the slice
// that needs it (File.slice(a, b).arrayBuffer() reads b - a bytes), shared by the slices, released with the last.
@(private = "file")
Host_File :: struct {
	refs:   u32,
	handle: api_decl.LocalFile,
}

@(private = "file")
Blob :: struct {
	store:         ^Store,       // nil for a host file not read yet
	hf:            ^Host_File,   // the browser's file, when the bytes come from there
	offset, len:   uint,         // in the store, or in the host file while store is nil
	type:          wj.JSValue,   // string
	name:          wj.JSValue,   // File: string, else undefined
	last_modified: f64,
}

@(private = "file")
store_new :: proc(p: []u8) -> ^Store {
	s := new(Store)
	if s == nil { return nil }
	s.refs = 1
	if len(p) > 0 {
		b, err := make([]u8, len(p))
		if err != nil { free(s); return nil }
		copy(b, p)
		s.bytes = b
	}
	return s
}

@(private = "file")
store_unref :: proc(s: ^Store) {
	if s == nil { return }
	s.refs -= 1
	if s.refs == 0 { delete(s.bytes); free(s) }
}

@(private = "file")
host_file_unref :: proc(hf: ^Host_File) {
	if hf == nil { return }
	hf.refs -= 1
	if hf.refs == 0 { wj.wr_Object_release(u64(hf.handle)); free(hf) }
}

@(private = "file")
blob_free :: proc "c" (p: rawptr) {
	context = wj.heap_context()
	b := (^Blob)(p)
	rt := wj.web_rt()
	store_unref(b.store)
	host_file_unref(b.hf)
	wj.JS_FreeValueRT(rt, b.type)
	wj.JS_FreeValueRT(rt, b.name)
	free(b)
}

@(private = "file")
blob_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	b := (^Blob)(p)
	wj.wj_mark(rt, b.type, mark_func)
	wj.wj_mark(rt, b.name, mark_func)
}

// The bytes of a host file's slice into a store of their own (once): false when the file cannot be read (gone,
// changed, too large for the engine's memory).
@(private = "file")
blob_load :: proc(b: ^Blob) -> bool {
	if b.store != nil || b.hf == nil { return true }
	bytes, err := make([]u8, b.len)
	if err != nil { return false }
	got: uint
	for got < b.len {
		chunk := min(b.len - got, 1 << 30)
		n: i64
		st := jsb.host(&n, api_decl.LocalFile_read, wj.wr_LocalFile_read, b.hf.handle, i64(b.offset + got), bytes[got:][:chunk])
		if st != .None || n <= 0 { delete(bytes); return false }
		got += uint(n)
	}
	s := new(Store)
	if s == nil { delete(bytes); return false }
	s^ = {refs = 1, bytes = bytes}
	b.store = s
	b.offset = 0
	return true
}

// The bytes of a Blob (read from the browser's file first when needed); ok false when that failed.
@(private = "file")
blob_bytes :: proc(b: ^Blob) -> (bytes: []u8, ok: bool) {
	if !blob_load(b) { return nil, false }
	if b.store == nil || b.len == 0 { return nil, true }
	return b.store.bytes[b.offset:][:b.len], true
}

@(private = "file")
not_readable :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	return wj.web_promise_rejected(ctx, wj.web_dom_exception(ctx, "NotReadableError", "The requested file could not be read, typically due to permission problems that have occurred after a reference to a file was acquired."))
}

@(private = "file")
blob_of :: proc "contextless" (v: wj.JSValue) -> ^Blob {
	return (^Blob)(wj.impl_of(wj.wj_unwrap(v, net_iface(.Blob))))
}

// The bytes of a Blob (or File) where they are: false when `v` is not one. A file that cannot be read gives no bytes
// (the caller sends or reads an empty body).
@(export, link_name = "web_blob_bytes")
web_blob_bytes :: proc "c" (v: wj.JSValue, ptr: ^[^]u8, length: ^uint) -> bool {
	context = wj.heap_context()
	b := blob_of(v)
	if b == nil { return false }
	bytes, ok := blob_bytes(b)
	ptr^ = ok && len(bytes) > 0 ? raw_data(bytes) : wj.empty_ptr()
	length^ = ok ? b.len : 0
	return true
}

// The same as a slice (nil and false when `v` is not a Blob).
blob_slice :: proc(v: wj.JSValue) -> ([]u8, bool) {
	p: [^]u8
	n: uint
	if !web_blob_bytes(v, &p, &n) { return nil, false }
	return p[:n], true
}

// Whether the Blob's bytes can be had (a host file is read now): FileReader reports NotReadableError otherwise.
@(private = "file")
blob_readable :: proc(v: wj.JSValue) -> bool {
	b := blob_of(v)
	return b != nil && blob_load(b)
}

@(export, link_name = "web_blob_type")
web_blob_type :: proc "c" (ctx: ^wj.Context, v: wj.JSValue) -> wj.JSValue {
	b := blob_of(v)
	return b != nil ? wj.JS_DupValue(ctx, b.type) : wj.new_string_len(ctx, "")
}

// Blob type: lower case, or "" when a character is outside U+0020-U+007E.
@(private = "file")
normalize_type :: proc(ctx: ^wj.Context, t: string) -> wj.JSValue {
	small: [256]u8
	buf := small[:]
	if len(t) > len(small) {
		heap, e := make([]u8, len(t))
		if e != nil { return wj.JS_ThrowOutOfMemory(ctx) }
		buf = heap
	}
	defer if len(t) > len(small) { delete(buf) }
	for i in 0 ..< len(t) {
		c := t[i]
		if c < 0x20 || c > 0x7E { return wj.new_string_len(ctx, "") }
		buf[i] = c >= 'A' && c <= 'Z' ? c + 32 : c
	}
	return wj.new_string_len(ctx, buf[:len(t)])
}

// takes `store` (one reference) and `type`
@(private = "file")
blob_make :: proc(ctx: ^wj.Context, iface: i32, new_target: wj.JSValue, store: ^Store, off, n: uint, type: wj.JSValue) -> wj.JSValue {
	b := new(Blob)
	if b == nil { store_unref(store); wj.JS_FreeValue(ctx, type); return wj.JS_ThrowOutOfMemory(ctx) }
	b^ = {store = store, offset = off, len = n, type = type, name = wj.UNDEFINED}
	obj := wj.wj_new_object_for(ctx, iface, new_target, nil, nil)
	if wj.is_exception(obj) { blob_free(b); return obj }
	wj.web_set_impl(obj, b, blob_free, blob_mark)
	return obj
}

@(private = "file")
cstr_view :: #force_inline proc "contextless" (p: cstring, n: uint) -> string {
	return p != nil ? string(([^]u8)(rawptr(p))[:n]) : ""
}

// A new Blob holding a copy of the bytes (type: a MIME type or "").
@(export, link_name = "web_blob_new")
web_blob_new :: proc "c" (ctx: ^wj.Context, p: [^]u8, n: uint, type: cstring, type_len: uint) -> wj.JSValue {
	context = wj.heap_context()
	s := store_new(p[:n] if p != nil else nil)
	if s == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	return blob_make(ctx, net_iface(.Blob), wj.UNDEFINED, s, 0, n, normalize_type(ctx, cstr_view(type, type_len)))
}

// A new File.
@(export, link_name = "web_file_new")
web_file_new :: proc "c" (ctx: ^wj.Context, p: [^]u8, n: uint, type: cstring, type_len: uint, name: cstring, name_len: uint, last_modified: f64) -> wj.JSValue {
	context = wj.heap_context()
	s := store_new(p[:n] if p != nil else nil)
	if s == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	f := blob_make(ctx, net_iface(.File), wj.UNDEFINED, s, 0, n, normalize_type(ctx, cstr_view(type, type_len)))
	if wj.is_exception(f) { return f }
	b := blob_of(f)
	b.name = wj.new_string_len(ctx, cstr_view(name, name_len))
	b.last_modified = last_modified
	return f
}

// A File for a file of the browser (module dnd's LocalFile, taken: released with the last Blob that reads it).
@(export, link_name = "web_file_from_host")
web_file_from_host :: proc "c" (ctx: ^wj.Context, local_file: u64) -> wj.JSValue {
	context = wj.heap_context()
	if local_file == 0 { return wj.NULL }
	lf := api_decl.LocalFile(local_file)
	hf := new(Host_File)
	if hf == nil { wj.wr_Object_release(local_file); return wj.JS_ThrowOutOfMemory(ctx) }
	hf^ = {refs = 1, handle = lf}
	info: wj.wr_LocalFileInfo
	wj.wr_LocalFile_info(local_file, &info)
	text: string
	jsb.host(&text, api_decl.LocalFile_type, wj.wr_LocalFile_type, lf)
	type := normalize_type(ctx, text)
	f := blob_make(ctx, net_iface(.File), wj.UNDEFINED, nil, 0, info.size > 0 ? uint(info.size) : 0, type)
	if wj.is_exception(f) { host_file_unref(hf); return f }
	b := blob_of(f)
	b.hf = hf
	text = ""
	jsb.host(&text, api_decl.LocalFile_name, wj.wr_LocalFile_name, lf)
	b.name = wj.new_string_len(ctx, text)
	b.last_modified = info.last_modified
	return f
}

// The browser's file behind a File (0 for a File made by the page, or one already read: the bytes then go by value).
@(export, link_name = "web_file_host")
web_file_host :: proc "c" (v: wj.JSValue) -> u64 {
	b := blob_of(v)
	return b != nil && b.hf != nil && b.store == nil && b.offset == 0 ? u64(b.hf.handle) : 0
}

// name, type, lastModified of a File (for DataTransferItemList.add(file))
@(export, link_name = "web_file_meta")
web_file_meta :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, name: ^wj.Str, type: ^wj.Str, last_modified: ^f64) -> bool {
	b := blob_of(v)
	if b == nil { return false }
	last_modified^ = b.last_modified
	if !wj.is_string(b.name) { name^ = {wj.empty_ptr(), 0, false} }
	else if !wj.wj_to_str(ctx, b.name, name, 0, nil) { return false }
	if !wj.wj_to_str(ctx, b.type, type, 0, nil) { wj.wj_str_free(ctx, name); return false }
	return true
}

// ---- constructor: blob parts ----

@(private = "file")
Parts :: struct {
	buf:    [dynamic]u8,
	native: bool,   // endings: "native"
}

@(private = "file")
part_add :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	context = wj.heap_context()
	ps := (^Parts)(opaque)
	if bytes, ok := blob_slice(item); ok { append(&ps.buf, ..bytes); return true }
	if wj.wj_is_buffer_source(item) {
		q: [^]u8
		n: uint
		if !wj.wj_to_buffer_source(ctx, item, &q, &n, 0, "Blob") { return false }
		if n > 0 { append(&ps.buf, ..q[:n]) }
		return true
	}
	s: wj.Str
	if !wj.web_to_usv(ctx, item, &s) { return false }
	defer wj.wj_str_free(ctx, &s)
	text := wj.str_view(s)
	if !ps.native { append(&ps.buf, text); return true }
	// "native" line endings: CR LF on this platform
	for i := 0; i < len(text); i += 1 {
		switch text[i] {
		case '\r':
			append(&ps.buf, "\r\n")
			if i + 1 < len(text) && text[i + 1] == '\n' { i += 1 }
		case '\n':
			append(&ps.buf, "\r\n")
		case:
			append(&ps.buf, text[i])
		}
	}
	return true
}

// the options of Blob / File: type, endings (and lastModified for File)
@(private = "file")
blob_options :: proc(ctx: ^wj.Context, opt: wj.JSValue, type: ^wj.JSValue, native: ^bool, last_modified: ^f64) -> bool {
	type^ = wj.new_string_len(ctx, "")
	native^ = false
	if !wj.web_dict_check(ctx, opt, "Blob") { return false }
	v: wj.JSValue
	if !wj.web_dict_get(ctx, opt, "endings", &v) { return false }
	if !wj.is_undefined(v) {
		e, c, ok := wj.to_string_view(ctx, v)
		wj.JS_FreeValue(ctx, v)
		if !ok { return false }
		valid := e == "transparent" || e == "native"
		native^ = e == "native"
		wj.free_cstring(ctx, c)
		if !valid { wj.JS_ThrowTypeError(ctx, "The provided value is not a valid enum value of type EndingType."); return false }
	}
	if last_modified != nil {
		if !wj.web_dict_get(ctx, opt, "lastModified", &v) { return false }
		if !wj.is_undefined(v) {
			lm: i64
			ok := wj.wj_to_int64(ctx, v, &lm, 0)
			wj.JS_FreeValue(ctx, v)
			if !ok { return false }
			last_modified^ = f64(lm)
		}
	}
	if !wj.web_dict_get(ctx, opt, "type", &v) { return false }
	if !wj.is_undefined(v) {
		t: wj.Str
		ok := wj.wj_to_str(ctx, v, &t, 0, nil)
		wj.JS_FreeValue(ctx, v)
		if !ok { return false }
		wj.JS_FreeValue(ctx, type^)
		type^ = normalize_type(ctx, wj.str_view(t))
		wj.wj_str_free(ctx, &t)
	}
	return true
}

@(private = "file")
blob_construct :: proc(ctx: ^wj.Context, new_target: wj.JSValue, bits: wj.JSValue, opt: wj.JSValue, iface: i32, last_modified: ^f64) -> wj.JSValue {
	type: wj.JSValue
	ps: Parts
	defer delete(ps.buf)
	if !blob_options(ctx, opt, &type, &ps.native, last_modified) { wj.JS_FreeValue(ctx, type); return wj.EXCEPTION }
	if !wj.is_undefined(bits) {
		if !wj.is_object(bits) {
			wj.JS_FreeValue(ctx, type)
			return wj.wj_throw_type(ctx, "Failed to construct '%s': The provided value cannot be converted to a sequence.", wj.interfaces()[iface].name)
		}
		if !wj.web_for_of(ctx, bits, part_add, &ps) { wj.JS_FreeValue(ctx, type); return wj.EXCEPTION }
	}
	s := store_new(ps.buf[:])
	if s == nil { wj.JS_FreeValue(ctx, type); return wj.JS_ThrowOutOfMemory(ctx) }
	return blob_make(ctx, iface, new_target, s, 0, uint(len(ps.buf)), type)
}

@(export, link_name = "wjr_Blob_constructor")
wjr_Blob_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor Blob requires 'new'") }
	return blob_construct(ctx, new_target, wj.arg(argc, argv, 0), wj.arg(argc, argv, 1), net_iface(.Blob), nil)
}

@(export, link_name = "wjr_File_constructor")
wjr_File_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor File requires 'new'") }
	if argc < 2 { return wj.wj_throw_arity(ctx, "File", 2, argc) }
	lm := wj.now_ms()
	name: wj.Str
	if !wj.web_to_usv(ctx, argv[1], &name) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &name)
	f := blob_construct(ctx, new_target, argv[0], wj.arg(argc, argv, 2), net_iface(.File), &lm)
	if wj.is_exception(f) { return f }
	b := blob_of(f)
	b.name = wj.new_string_len(ctx, wj.str_view(name))
	b.last_modified = lm
	return f
}

// ---- members ----

@(private = "file")
blob_this :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, k: Net_Iface = .Blob) -> ^Blob {
	return (^Blob)(wj.this_impl(ctx, this_val, net_iface(k)))
}

@(export, link_name = "wjr_Blob_get_size")
wjr_Blob_get_size :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	b := blob_this(ctx, this_val)
	return b != nil ? wj.new_float64(ctx, f64(b.len)) : wj.EXCEPTION
}

@(export, link_name = "wjr_Blob_get_type")
wjr_Blob_get_type :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	b := blob_this(ctx, this_val)
	return b != nil ? wj.JS_DupValue(ctx, b.type) : wj.EXCEPTION
}

@(export, link_name = "wjr_File_get_name")
wjr_File_get_name :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	b := blob_this(ctx, this_val, .File)
	return b != nil ? wj.JS_DupValue(ctx, b.name) : wj.EXCEPTION
}

@(export, link_name = "wjr_File_get_lastModified")
wjr_File_get_lastModified :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	b := blob_this(ctx, this_val, .File)
	return b != nil ? wj.new_float64(ctx, b.last_modified) : wj.EXCEPTION
}

@(export, link_name = "wjr_File_get_webkitRelativePath")
wjr_File_get_webkitRelativePath :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return blob_this(ctx, this_val, .File) != nil ? wj.new_string_len(ctx, "") : wj.EXCEPTION
}

// a relative position (slice()'s start / end) clamped to [0, size]
@(private = "file")
relative :: proc "contextless" (v: i64, size: uint) -> uint {
	if v < 0 { return i64(size) + v < 0 ? 0 : uint(i64(size) + v) }
	return u64(v) > u64(size) ? size : uint(v)
}

@(export, link_name = "wjr_Blob_slice")
wjr_Blob_slice :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	b := blob_this(ctx, this_val)
	if b == nil { return wj.EXCEPTION }
	start, end := i64(0), i64(b.len)
	a0, a1, a2 := wj.arg(argc, argv, 0), wj.arg(argc, argv, 1), wj.arg(argc, argv, 2)
	if !wj.is_undefined(a0) && !wj.wj_to_int64(ctx, a0, &start, wj.CLAMP) { return wj.EXCEPTION }
	if !wj.is_undefined(a1) && !wj.wj_to_int64(ctx, a1, &end, wj.CLAMP) { return wj.EXCEPTION }
	type: wj.JSValue
	if wj.is_undefined(a2) {
		type = wj.new_string_len(ctx, "")
	} else {
		t: wj.Str
		if !wj.wj_to_str(ctx, a2, &t, 0, nil) { return wj.EXCEPTION }
		type = normalize_type(ctx, wj.str_view(t))
		wj.wj_str_free(ctx, &t)
	}
	s, e := relative(start, b.len), relative(end, b.len)
	if e < s { e = s }
	if b.store != nil { b.store.refs += 1 }
	r := blob_make(ctx, net_iface(.Blob), wj.UNDEFINED, b.store, b.offset + s, e - s, type)
	// a host file not read yet: the slice reads its own part when asked
	if !wj.is_exception(r) && b.store == nil && b.hf != nil {
		nb := blob_of(r)
		nb.hf = b.hf
		b.hf.refs += 1
	}
	return r
}

// The kinds of read a Blob's promise members make.
@(private = "file")
Blob_Read :: enum { Text, Array_Buffer, Bytes }

@(private = "file")
blob_read :: proc(ctx: ^wj.Context, this_val: wj.JSValue, kind: Blob_Read) -> wj.JSValue {
	b := blob_this(ctx, this_val)
	if b == nil { return wj.web_promise_reject_pending(ctx) }
	bytes, ok := blob_bytes(b)
	if !ok { return not_readable(ctx) }
	v: wj.JSValue
	switch kind {
	case .Text:         v = wj.web_utf8_string(ctx, raw_data(bytes), uint(len(bytes)), true)
	case .Array_Buffer: v = wj.JS_NewArrayBufferCopy(ctx, raw_data(bytes), uint(len(bytes)))
	case .Bytes:        v = wj.JS_NewUint8ArrayCopy(ctx, len(bytes) > 0 ? raw_data(bytes) : wj.empty_ptr(), uint(len(bytes)))
	}
	if wj.is_exception(v) { return wj.web_promise_reject_pending(ctx) }
	return wj.web_promise_take(ctx, v)
}

@(export, link_name = "wjr_Blob_text")
wjr_Blob_text :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return blob_read(ctx, this_val, .Text)
}

@(export, link_name = "wjr_Blob_arrayBuffer")
wjr_Blob_arrayBuffer :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return blob_read(ctx, this_val, .Array_Buffer)
}

@(export, link_name = "wjr_Blob_bytes")
wjr_Blob_bytes :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return blob_read(ctx, this_val, .Bytes)
}

@(export, link_name = "wjr_Blob_stream")
wjr_Blob_stream :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	b := blob_this(ctx, this_val)
	if b == nil { return wj.EXCEPTION }
	bytes, ok := blob_bytes(b)
	if !ok { return wj.wj_throw_dom(ctx, "NotReadableError", "The requested file could not be read.") }
	return web_stream_from_bytes(ctx, raw_data(bytes), uint(len(bytes)))
}

// textStream(): the text in one chunk (the bytes decoded as UTF-8)
@(export, link_name = "wjr_Blob_textStream")
wjr_Blob_textStream :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	b := blob_this(ctx, this_val)
	if b == nil { return wj.EXCEPTION }
	bytes, ok := blob_bytes(b)
	if !ok { return wj.wj_throw_dom(ctx, "NotReadableError", "The requested file could not be read.") }
	text := wj.web_utf8_string(ctx, raw_data(bytes), uint(len(bytes)), true)
	if wj.is_exception(text) { return text }
	s := web_stream_of(ctx, text)
	wj.JS_FreeValue(ctx, text)
	return s
}

// ---- blob: URLs ----

// url (without its fragment) -> Blob (counted); the keys are heap copies.
@(private = "file") blob_urls: map[string]wj.JSValue

// The Blob a blob: URL of this realm stands for (URL.createObjectURL), or undefined.
@(export, link_name = "web_blob_url_lookup")
web_blob_url_lookup :: proc "c" (ctx: ^wj.Context, url: [^]u8, n: uint) -> wj.JSValue {
	context = wj.heap_context()
	u := string(url[:n]) if url != nil else ""
	if len(u) < 5 || u[:5] != "blob:" { return wj.UNDEFINED }
	// the fragment is not part of the key
	for i in 0 ..< len(u) { if u[i] == '#' { u = u[:i]; break } }
	b, found := blob_urls[u]
	return found ? wj.JS_DupValue(ctx, b) : wj.UNDEFINED
}

// The bytes of the in-memory Blob a blob: URL of this realm stands for (valid until JavaScript runs again); false when
// it is not one (or its Blob is a file not read).
@(export, link_name = "web_blob_url_bytes")
web_blob_url_bytes :: proc "c" (ctx: ^wj.Context, url: [^]u8, n: uint, p: ^[^]u8, length: ^uint) -> bool {
	b := web_blob_url_lookup(ctx, url, n)
	ok := !wj.is_undefined(b) && web_blob_bytes(b, p, length)
	wj.JS_FreeValue(ctx, b)   // (the table keeps the Blob: its bytes stay where they are)
	return ok
}

@(private = "file")
hex_byte :: proc "contextless" (dst: []u8, b: u8) {
	digits := "0123456789abcdef"
	dst[0] = digits[b >> 4]
	dst[1] = digits[b & 15]
}

@(export, link_name = "wjr_URL_static_createObjectURL")
wjr_URL_static_createObjectURL :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if argc < 1 { return wj.wj_throw_arity(ctx, "URL.createObjectURL", 1, argc) }
	// (Blob or MediaSource): a Media Source's URL is known to the browser, which plays it in a media element
	is_blob := blob_of(argv[0]) != nil
	source := is_blob ? nil : wj.wj_unwrap(argv[0], net_iface(.MediaSource))
	if !is_blob && source == nil { return wj.wj_throw_type(ctx, "Failed to execute 'createObjectURL' on 'URL': parameter 1 is not of type 'Blob'.") }
	r: [16]u8
	wj.arc4random_buf(&r[0], len(r))
	r[6] = (r[6] & 0x0F) | 0x40
	r[8] = (r[8] & 0x3F) | 0x80
	url: [dynamic]u8
	defer delete(url)
	append(&url, "blob:")
	origin := wj.JS_GetPropertyStr(ctx, wj.realm_global(), "origin")
	o: string
	oc: cstring
	ok: bool
	if wj.is_string(origin) { o, oc, ok = wj.to_string_view(ctx, origin) }
	append(&url, ok && o != "null" ? o : "null")
	if oc != nil { wj.free_cstring(ctx, oc) }
	wj.JS_FreeValue(ctx, origin)
	append(&url, '/')
	for i in 0 ..< len(r) {
		if i == 4 || i == 6 || i == 8 || i == 10 { append(&url, '-') }
		h: [2]u8
		hex_byte(h[:], r[i])
		append(&url, ..h[:])
	}
	if source != nil {
		// (a worker's MediaSource has none: URL.createObjectURL(MediaSource) is a window's, the worker transfers its
		// handle instead)
		if jsb.host(&none_m2, api_decl.MediaSource_registerObjectURL, wj.wr_MediaSource_registerObjectURL, api_decl.MediaSource(source.handle), string(url[:])) != .None {
			return wj.wj_throw_type(ctx, "Failed to execute 'createObjectURL' on 'URL': a MediaSource of a worker has no object URL (use its handle as the element's srcObject).")
		}
		return wj.new_string_len(ctx, url[:])
	}
	key := string(url[:])
	if old, found := blob_urls[key]; found {
		wj.JS_FreeValue(ctx, old)
		blob_urls[key] = wj.JS_DupValue(ctx, argv[0])
	} else {
		k, err := make([]u8, len(url))
		if err != nil { return wj.JS_ThrowOutOfMemory(ctx) }
		copy(k, url[:])
		blob_urls[string(k)] = wj.JS_DupValue(ctx, argv[0])
	}
	return wj.new_string_len(ctx, url[:])
}

@(export, link_name = "wjr_URL_static_revokeObjectURL")
wjr_URL_static_revokeObjectURL :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if argc < 1 { return wj.wj_throw_arity(ctx, "URL.revokeObjectURL", 1, argc) }
	key := wj.JS_ToString(ctx, argv[0])
	if wj.is_exception(key) { return key }
	defer wj.JS_FreeValue(ctx, key)
	k, kc, ok := wj.to_string_view(ctx, key)
	if !ok { return wj.EXCEPTION }
	defer wj.free_cstring(ctx, kc)
	if len(k) >= 5 && k[:5] == "blob:" { jsb.host(&none_m2, api_decl.MediaSource_revokeObjectURL, wj.wr_MediaSource_revokeObjectURL, k) }
	if k in blob_urls {
		stored_key, b := delete_key(&blob_urls, k)
		wj.JS_FreeValue(ctx, b)
		delete(stored_key)
	}
	return wj.UNDEFINED
}

// ---- FileReader ----

@(private = "file") FR_State  :: enum i32 { Empty, Loading, Done }
@(private = "file") FR_Format :: enum { Array_Buffer, Binary, Text, Data_URL }

@(private = "file")
File_Reader :: struct {
	state:      FR_State,
	format:     FR_Format,
	generation: u32,   // abort() and a new read make a queued read obsolete
	blob, encoding, result, error: wj.JSValue,
}

@(private = "file")
fr_free :: proc "c" (p: rawptr) {
	context = wj.heap_context()
	r := (^File_Reader)(p)
	rt := wj.web_rt()
	wj.JS_FreeValueRT(rt, r.blob)
	wj.JS_FreeValueRT(rt, r.encoding)
	wj.JS_FreeValueRT(rt, r.result)
	wj.JS_FreeValueRT(rt, r.error)
	free(r)
}

@(private = "file")
fr_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	r := (^File_Reader)(p)
	wj.wj_mark(rt, r.blob, mark_func)
	wj.wj_mark(rt, r.encoding, mark_func)
	wj.wj_mark(rt, r.result, mark_func)
	wj.wj_mark(rt, r.error, mark_func)
}

@(export, link_name = "wjr_FileReader_constructor")
wjr_FileReader_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor FileReader requires 'new'") }
	obj := wj.wj_wrap_owned(ctx, wj.wr_EventTarget_create(), net_iface(.FileReader), new_target)
	if wj.is_exception(obj) { return obj }
	r := new(File_Reader)
	if r == nil { wj.JS_FreeValue(ctx, obj); return wj.JS_ThrowOutOfMemory(ctx) }
	r^ = {blob = wj.UNDEFINED, encoding = wj.UNDEFINED, result = wj.NULL, error = wj.NULL}
	wj.web_set_impl(obj, r, fr_free, fr_mark)
	return obj
}

// A ProgressEvent of the engine (FileReader, XMLHttpRequest) fired at `target`.
fire_progress :: proc "contextless" (ctx: ^wj.Context, target: wj.JSValue, type: cstring, loaded, total: f64, computable: bool) {
	ev := wj.web_event_new(ctx, net_iface(.ProgressEvent), type, false, false)
	if wj.is_exception(ev) { wj.wj_report_pending(ctx); return }
	wj.web_extra_set(ctx, ev, "lengthComputable", wj.new_bool(computable))
	wj.web_extra_set(ctx, ev, "loaded", wj.new_float64(ctx, loaded))
	wj.web_extra_set(ctx, ev, "total", wj.new_float64(ctx, total))
	wj.web_event_fire(ctx, target, ev)
	wj.JS_FreeValue(ctx, ev)
}

@(private = "file")
data_url :: proc(ctx: ^wj.Context, type: wj.JSValue, p: []u8) -> wj.JSValue {
	b64 := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	t, tc, ok := wj.to_string_view(ctx, type)
	if !ok { return wj.EXCEPTION }
	b: [dynamic]u8
	defer delete(b)
	append(&b, "data:")
	append(&b, len(t) > 0 ? t : "application/octet-stream")
	append(&b, ";base64,")
	wj.free_cstring(ctx, tc)
	n := len(p)
	for i := 0; i < n; i += 3 {
		v := u32(p[i]) << 16 | (i + 1 < n ? u32(p[i + 1]) << 8 : 0) | (i + 2 < n ? u32(p[i + 2]) : 0)
		q := [4]u8{b64[v >> 18], b64[(v >> 12) & 63], i + 1 < n ? b64[(v >> 6) & 63] : '=', i + 2 < n ? b64[v & 63] : '='}
		append(&b, ..q[:])
	}
	return wj.new_string_len(ctx, b[:])
}

// each byte as the code point of the same value (readAsBinaryString)
@(private = "file")
binary_string :: proc(ctx: ^wj.Context, p: []u8) -> wj.JSValue {
	q, err := make([]u8, len(p) * 2 + 1)
	if err != nil { return wj.JS_ThrowOutOfMemory(ctx) }
	defer delete(q)
	w := 0
	for c in p {
		if c < 0x80 { q[w] = c; w += 1 }
		else { q[w] = 0xC0 | (c >> 6); q[w + 1] = 0x80 | (c & 0x3F); w += 2 }
	}
	return wj.new_string_len(ctx, q[:w])
}

// text in the encoding asked for (or UTF-8) through the browser's decoder (one call: a decoder's output is read back
// with TextDecoder_output, not decoded twice)
decode_text :: proc(ctx: ^wj.Context, label: string, p: []u8) -> wj.JSValue {
	dec: u64
	if wj.wr_TextDecoder_create(wj.raw_bytes(label), u32(len(label)), 0, &dec) < 0 &&
	   wj.wr_TextDecoder_create(wj.raw_bytes("utf-8"), 5, 0, &dec) < 0 {
		return wj.web_utf8_string(ctx, raw_data(p), uint(len(p)), true)
	}
	defer wj.wr_Object_release(dec)
	if wj.wj_scratch.data == nil && !wj.wj_scratch_grow(256) { return wj.JS_ThrowOutOfMemory(ctx) }
	m := wj.wr_TextDecoder_decode(dec, len(p) > 0 ? raw_data(p) : wj.empty_ptr(), u32(len(p)), 0, wj.wj_scratch.data, wj.wj_scratch.cap)
	if m > 0 && u32(m) > wj.wj_scratch.cap {
		if !wj.wj_scratch_grow(u32(m)) { return wj.JS_ThrowOutOfMemory(ctx) }
		m = wj.wr_TextDecoder_output(dec, wj.wj_scratch.data, wj.wj_scratch.cap)
	}
	return wj.scratch_string(ctx, m)
}

@(private = "file")
fr_text :: proc(ctx: ^wj.Context, r: ^File_Reader, p: []u8) -> wj.JSValue {
	label := wj.Str{wj.raw_bytes("utf-8"), 5, false}
	if !wj.is_undefined(r.encoding) && !wj.wj_to_str(ctx, r.encoding, &label, 0, "utf-8") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &label)
	return decode_text(ctx, wj.str_view(label), p)
}

// the read's task: loadstart was fired; now progress, load (or error), loadend
@(private = "file")
fr_run :: proc "c" (ctx: ^wj.Context, data: wj.JSValue) {
	context = wj.heap_context()
	target := wj.JS_GetPropertyUint32(ctx, data, 0)
	defer wj.JS_FreeValue(ctx, target)
	gen := wj.JS_GetPropertyUint32(ctx, data, 1)
	r := (^File_Reader)(wj.obj_impl(target))
	g: i32
	wj.JS_ToInt32(ctx, &g, gen)
	if r == nil || u32(g) != r.generation || r.state != .Loading { return }
	readable := blob_readable(r.blob)
	p, _ := blob_slice(r.blob)
	n := f64(len(p))
	res: wj.JSValue
	if !readable {
		res = wj.JS_ThrowInternalError(ctx, "not readable")
	} else {
		switch r.format {
		case .Array_Buffer: res = wj.JS_NewArrayBufferCopy(ctx, raw_data(p), uint(len(p)))
		case .Binary:       res = binary_string(ctx, p)
		case .Text:         res = fr_text(ctx, r, p)
		case .Data_URL:
			t := web_blob_type(ctx, r.blob)
			res = data_url(ctx, t, p)
			wj.JS_FreeValue(ctx, t)
		}
	}
	fire_progress(ctx, target, "progress", n, n, true)
	if u32(g) != r.generation || r.state != .Loading { wj.JS_FreeValue(ctx, res); return }
	r.state = .Done
	if wj.is_exception(res) {
		wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))
		wj.JS_FreeValue(ctx, r.error)
		r.error = wj.web_dom_exception(ctx, "NotReadableError", "the file could not be read")
		fire_progress(ctx, target, "error", 0, n, true)
	} else {
		wj.JS_FreeValue(ctx, r.result)
		r.result = res
		fire_progress(ctx, target, "load", n, n, true)
	}
	if r.state != .Loading { fire_progress(ctx, target, "loadend", n, n, true) }
}

@(private = "file")
fr_read :: proc(ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, format: FR_Format) -> wj.JSValue {
	r := (^File_Reader)(wj.this_impl(ctx, this_val, net_iface(.FileReader)))
	if r == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "FileReader.read", 1, argc) }
	b := blob_of(argv[0])
	if b == nil { return wj.wj_throw_type(ctx, "Failed to execute 'read' on 'FileReader': parameter 1 is not of type 'Blob'.") }
	if r.state == .Loading { return wj.wj_throw_dom(ctx, "InvalidStateError", "The object is already busy reading Blobs.") }
	r.state = .Loading
	r.format = format
	r.generation += 1
	wj.JS_FreeValue(ctx, r.blob)
	r.blob = wj.JS_DupValue(ctx, argv[0])
	wj.JS_FreeValue(ctx, r.encoding)
	r.encoding = format == .Text && argc > 1 && !wj.is_undefined(argv[1]) ? wj.JS_DupValue(ctx, argv[1]) : wj.UNDEFINED
	wj.JS_FreeValue(ctx, r.result)
	r.result = wj.NULL
	wj.JS_FreeValue(ctx, r.error)
	r.error = wj.NULL
	data := wj.JS_NewArray(ctx)
	wj.array_set(ctx, data, 0, wj.JS_DupValue(ctx, this_val))
	wj.array_set(ctx, data, 1, wj.new_int32(i32(r.generation)))
	// loadstart, then the rest from a task of its own (File API "read operation")
	queued := wj.web_queue_task(ctx, fr_run, data)
	wj.JS_FreeValue(ctx, data)
	if !queued { return wj.EXCEPTION }
	fire_progress(ctx, this_val, "loadstart", 0, f64(b.len), true)   // (a host file is read by the task, not now)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_FileReader_readAsArrayBuffer")
wjr_FileReader_readAsArrayBuffer :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return fr_read(ctx, this_val, argc, argv, .Array_Buffer)
}
@(export, link_name = "wjr_FileReader_readAsBinaryString")
wjr_FileReader_readAsBinaryString :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return fr_read(ctx, this_val, argc, argv, .Binary)
}
@(export, link_name = "wjr_FileReader_readAsText")
wjr_FileReader_readAsText :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return fr_read(ctx, this_val, argc, argv, .Text)
}
@(export, link_name = "wjr_FileReader_readAsDataURL")
wjr_FileReader_readAsDataURL :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return fr_read(ctx, this_val, argc, argv, .Data_URL)
}

@(export, link_name = "wjr_FileReader_abort")
wjr_FileReader_abort :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	r := (^File_Reader)(wj.this_impl(ctx, this_val, net_iface(.FileReader)))
	if r == nil { return wj.EXCEPTION }
	if r.state == .Empty || r.state == .Done { wj.JS_FreeValue(ctx, r.result); r.result = wj.NULL; return wj.UNDEFINED }
	r.state = .Done
	r.generation += 1
	wj.JS_FreeValue(ctx, r.result)
	r.result = wj.NULL
	fire_progress(ctx, this_val, "abort", 0, 0, true)
	if r.state != .Loading { fire_progress(ctx, this_val, "loadend", 0, 0, true) }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_FileReader_get_readyState")
wjr_FileReader_get_readyState :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := (^File_Reader)(wj.this_impl(ctx, this_val, net_iface(.FileReader)))
	return r != nil ? wj.new_int32(i32(r.state)) : wj.EXCEPTION
}

@(export, link_name = "wjr_FileReader_get_result")
wjr_FileReader_get_result :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := (^File_Reader)(wj.this_impl(ctx, this_val, net_iface(.FileReader)))
	return r != nil ? wj.JS_DupValue(ctx, r.result) : wj.EXCEPTION
}

@(export, link_name = "wjr_FileReader_get_error")
wjr_FileReader_get_error :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := (^File_Reader)(wj.this_impl(ctx, this_val, net_iface(.FileReader)))
	return r != nil ? wj.JS_DupValue(ctx, r.error) : wj.EXCEPTION
}

// ---- ProgressEvent (XMLHttpRequest, FileReader) ----

@(export, link_name = "wjr_ProgressEvent_constructor")
wjr_ProgressEvent_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	ev := wj.wj_event_construct(ctx, new_target, argc, argv, net_iface(.ProgressEvent), "ProgressEvent")
	if wj.is_exception(ev) { return ev }
	init := wj.arg(argc, argv, 1)
	if wj.is_object(init) {
		names := [3]cstring{"lengthComputable", "loaded", "total"}
		for name, i in names {
			v := wj.JS_GetPropertyStr(ctx, init, name)
			if wj.is_exception(v) { wj.JS_FreeValue(ctx, ev); return v }
			if wj.is_undefined(v) { continue }
			c: wj.JSValue
			if i == 0 {
				c = wj.new_bool(wj.JS_ToBool(ctx, v) > 0)
			} else {
				d: f64
				if !wj.wj_to_double(ctx, v, &d, true) { wj.JS_FreeValue(ctx, v); wj.JS_FreeValue(ctx, ev); return wj.EXCEPTION }
				c = wj.new_float64(ctx, d)
			}
			wj.JS_FreeValue(ctx, v)
			wj.web_extra_set(ctx, ev, name, c)
		}
	}
	return ev
}

@(private = "file")
progress_field :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, name: cstring, def: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, net_iface(.ProgressEvent)) == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, name)
	return wj.is_undefined(v) ? def : v
}

@(export, link_name = "wjr_ProgressEvent_get_lengthComputable")
wjr_ProgressEvent_get_lengthComputable :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return progress_field(ctx, this_val, "lengthComputable", wj.FALSE) }
@(export, link_name = "wjr_ProgressEvent_get_loaded")
wjr_ProgressEvent_get_loaded :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return progress_field(ctx, this_val, "loaded", wj.new_int32(0)) }
@(export, link_name = "wjr_ProgressEvent_get_total")
wjr_ProgressEvent_get_total :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return progress_field(ctx, this_val, "total", wj.new_int32(0)) }

// the result of a host call that has none
@(private) none_m2: abi.Nothing
