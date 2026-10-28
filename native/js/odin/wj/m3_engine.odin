// m3_engine.odin: the engine and runtime symbols the storage, file and clipboard domains need beyond the rest of the
// layer (IndexedDB, caches, file handles and entries, drag and drop, the clipboard, credentials): UTF-16 strings, dates,
// proxies, constructors, JSON, atoms, host auto-init properties, the C runtime's growable buffer and header
// serializer. Real symbols (quickjs.h JS_EXTERN, runtime/web.h, libunicode.h), one declaration each; the inline
// JS_NewCFunctionMagic is reimplemented over JS_NewCFunction2.
package wj

// JSCFunctionEnum (quickjs.h): the kinds a native function is made as.
CFUNC_generic_magic :: 1
CFUNC_constructor   :: 2
CFUNC_getter_magic  :: 10
CFUNC_setter_magic  :: 11

PROP_THROW :: 1 << 14   // JS_PROP_THROW

// JSHostAutoInitFunc (a Wren patch of quickjs.h): the value of a global property, made on its first use.
Host_Auto_Init :: #type proc "c" (ctx: ^Context, atom: Atom) -> JSValue
// JSCFunctionMagic: a native function with a magic number (getter_magic / setter_magic are cast to it, as the C does).
Native_Magic :: #type proc "c" (ctx: ^Context, this_val: JSValue, argc: i32, argv: [^]JSValue, magic: i32) -> JSValue

@(default_calling_convention = "c")
foreign {
	JS_NewDate             :: proc(ctx: ^Context, epoch_ms: f64) -> JSValue ---
	JS_IsProxy             :: proc(v: JSValue) -> bool ---
	JS_ToCStringLenUTF16   :: proc(ctx: ^Context, plen: ^uint, v: JSValue) -> [^]u16 ---
	JS_FreeCStringUTF16    :: proc(ctx: ^Context, p: [^]u16) ---
	JS_NewStringUTF16      :: proc(ctx: ^Context, buf: [^]u16, len: uint) -> JSValue ---
	JS_ThrowInternalError  :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---
	JS_NewAtomUInt32       :: proc(ctx: ^Context, n: u32) -> Atom ---
	JS_AtomToCStringLen    :: proc(ctx: ^Context, plen: ^uint, atom: Atom) -> cstring ---
	JS_SetProperty         :: proc(ctx: ^Context, this_obj: JSValue, prop: Atom, val: JSValue) -> i32 ---
	JS_DefinePropertyValue :: proc(ctx: ^Context, this_obj: JSValue, prop: Atom, val: JSValue, flags: i32) -> i32 ---
	JS_CallConstructor2    :: proc(ctx: ^Context, func_obj: JSValue, new_target: JSValue, argc: i32, argv: [^]JSValue) -> JSValue ---
	JS_ParseJSON           :: proc(ctx: ^Context, buf: [^]u8, buf_len: uint, filename: cstring) -> JSValue ---
	JS_SetLength           :: proc(ctx: ^Context, obj: JSValue, len: i64) -> i32 ---
	JS_SetConstructor      :: proc(ctx: ^Context, func_obj: JSValue, proto: JSValue) -> i32 ---
	JS_DefineHostAutoInitProperty :: proc(ctx: ^Context, obj: JSValue, prop: Atom, fn: Host_Auto_Init, flags: i32) -> i32 ---
	js_mallocz             :: proc(ctx: ^Context, size: uint) -> rawptr ---
	js_realloc             :: proc(ctx: ^Context, ptr: rawptr, size: uint) -> rawptr ---

	// libunicode.h: ID_Start / ID_Continue (without '$', '_', ZWNJ, ZWJ)
	lre_is_id_start    :: proc(c: u32) -> bool ---
	lre_is_id_continue :: proc(c: u32) -> bool ---
}

// JS_NewCFunctionMagic (inline in quickjs.h).
new_cfunction_magic :: #force_inline proc "contextless" (ctx: ^Context, fn: Native_Magic, name: cstring, length: i32, cproto: i32, magic: i32) -> JSValue {
	return JS_NewCFunction2(ctx, Native(rawptr(fn)), name, length, cproto, magic)
}

// web_buf (web.h): the runtime's growable byte buffer (malloc'ed; `failed` after an allocation failure).
Web_Buf :: struct {
	p:      [^]u8,
	len:    uint,
	cap:    uint,
	failed: bool,
}

@(default_calling_convention = "c")
foreign {
	web_buf_put           :: proc(b: ^Web_Buf, p: rawptr, n: uint) ---
	web_buf_free          :: proc(b: ^Web_Buf) ---
	// "name: value\r\n" lines of a Headers object, for the browser
	web_headers_serialize :: proc(headers: JSValue, out: ^Web_Buf) ---
	// a Response's URL (fetch's response URL list), for a Response made from a cache entry
	web_response_set_url  :: proc(ctx: ^Context, resp: JSValue, url: [^]u8, len: uint) ---
	// DOMString -> what the browser takes as UTF-8: each lone surrogate's CESU-8 bytes replaced in place by U+FFFD's
	web_usv_fix           :: proc(p: [^]u8, n: uint) ---
	// the time value of a Date
	web_date_time         :: proc(ctx: ^Context, v: JSValue, t: ^f64) -> bool ---
	// WritableStream (web_writable.c) on an underlying sink, and its writer's write()
	web_writable_new      :: proc(ctx: ^Context, iface: i32, sink: JSValue, hwm: f64, proto_from: JSValue) -> JSValue ---
	web_writable_write    :: proc(ctx: ^Context, stream: JSValue, chunk: JSValue) -> JSValue ---
	// the realm's microtask checkpoint, now
	wj_run_jobs           :: proc() -> i32 ---
}

web_buf_puts :: #force_inline proc "contextless" (b: ^Web_Buf, s: string) {
	if len(s) > 0 { web_buf_put(b, raw_data(s), uint(len(s))) }
}
web_buf_bytes :: #force_inline proc "contextless" (b: ^Web_Buf) -> []u8 { return b.p != nil ? b.p[:b.len] : nil }
