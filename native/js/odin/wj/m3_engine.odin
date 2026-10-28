// m3_engine.odin: the engine and runtime symbols the storage, file and clipboard domains need beyond the rest of the
// layer (IndexedDB, caches, file handles and entries, drag and drop, the clipboard, credentials): UTF-16 strings, dates,
// proxies, constructors, JSON, atoms, host auto-init properties, the C runtime's growable buffer and header
// serializer. Real symbols (quickjs.h JS_EXTERN, runtime/web.h, libunicode.h), one declaration each; the inline
// JS_NewCFunctionMagic is reimplemented over JS_NewCFunction2.
package wj

import jscapi "wb:engine/jscapi"

// JSCFunctionEnum (quickjs.h): the kinds a native function is made as.
CFUNC_getter_magic  :: 10
CFUNC_setter_magic  :: 11


// JSHostAutoInitFunc (a Wren patch of quickjs.h): the value of a global property, made on its first use.
Host_Auto_Init :: jscapi.Host_Auto_Init
// JSCFunctionMagic: a native function with a magic number (getter_magic / setter_magic are cast to it, as the C does).

when !WJ_JSRT {
@(default_calling_convention = "c")
foreign {
	JS_IsProxy             :: proc(v: JSValue) -> bool ---
	JS_ToCStringLenUTF16   :: proc(ctx: ^Context, plen: ^uint, v: JSValue) -> [^]u16 ---
	JS_FreeCStringUTF16    :: proc(ctx: ^Context, p: [^]u16) ---
	JS_NewStringUTF16      :: proc(ctx: ^Context, buf: [^]u16, len: uint) -> JSValue ---
	JS_CallConstructor2    :: proc(ctx: ^Context, func_obj: JSValue, new_target: JSValue, argc: i32, argv: [^]JSValue) -> JSValue ---
	JS_SetLength           :: proc(ctx: ^Context, obj: JSValue, len: i64) -> i32 ---
	JS_DefineHostAutoInitProperty :: proc(ctx: ^Context, obj: JSValue, prop: Atom, fn: Host_Auto_Init, flags: i32) -> i32 ---
	js_mallocz             :: proc(ctx: ^Context, size: uint) -> rawptr ---

	// libunicode.h: ID_Start / ID_Continue (without '$', '_', ZWNJ, ZWJ)
	lre_is_id_start    :: proc(c: u32) -> bool ---
	lre_is_id_continue :: proc(c: u32) -> bool ---
}
}   // when !WJ_JSRT

@(default_calling_convention = "c")
foreign {
	// "name: value\r\n" lines of a Headers object, for the browser
	// a Response's URL (fetch's response URL list), for a Response made from a cache entry
	// DOMString -> what the browser takes as UTF-8: each lone surrogate's CESU-8 bytes replaced in place by U+FFFD's
	// the time value of a Date
	// WritableStream (web_writable.c) on an underlying sink, and its writer's write()
	// the realm's microtask checkpoint, now
}

web_buf_puts :: #force_inline proc "contextless" (b: ^Web_Buf, s: string) {
	if len(s) > 0 { web_buf_put(b, raw_data(s), uint(len(s))) }
}
web_buf_bytes :: #force_inline proc "contextless" (b: ^Web_Buf) -> []u8 { return b.p != nil ? b.p[:b.len] : nil }
