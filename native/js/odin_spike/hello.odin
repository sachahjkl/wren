// hello.odin: the Odin side of the link spike (native/js/odin_spike).
//
// It is compiled to a wasm32 object (odin build -build-mode:obj -target:freestanding_wasm32) and linked by zig's
// wasm-ld with the QuickJS-ng objects that zig cc produced, into one module. It shows:
//   * an Odin proc with the exact ABI of a JSCFunction (the QuickJS native-function signature) being registered with
//     JS_NewCFunction2 and called from JavaScript (odin_add(a, b));
//   * that proc calling the QuickJS C API (JS_ToInt32, JS_NewInt32, JS_NewStringLen), i.e. C <- Odin;
//   * a plain C -> Odin call (spike_setup, exported, invoked by the C harness) and Odin -> C (the API calls above);
//   * JSValue passed and returned by value as a single u64 (QuickJS-ng uses NAN boxing on wasm32: see quickjs.h, the
//     `typedef uint64_t JSValue` branch), so there is no struct-by-value ABI question on this target.
//
// No Odin runtime is pulled in: the package is freestanding, procs are "contextless", and nothing here allocates or
// uses `context`. The engine's malloc (wasi-libc's dlmalloc, already in the module) is the shared allocator; this
// spike does not need it, but a real glue port would call it through the same C API.
package odin_spike

import "base:intrinsics"

// JSValue and JSContext as the wasm32 engine sees them. On wasm32 QuickJS-ng selects NAN boxing, so JSValue is a bare
// 64-bit integer: Odin passes and returns it in a single wasm i64, matching the C ABI exactly.
JSValue  :: u64
JSContext :: struct {}   // opaque; only ever used behind a pointer

// The QuickJS C functions this spike calls. Only the engine's *exported* (JS_EXTERN) symbols can be named here: they
// are ordinary statically resolved symbols in the same module. QuickJS's value *constructors* (JS_NewInt32, JS_NewBool,
// JS_UNDEFINED...) are `static inline` in quickjs.h and have no symbol, so wasm-ld would turn a foreign declaration of
// them into an unresolved import from env. We reimplement those inline helpers in Odin below instead (js_new_int32).
@(default_calling_convention = "c")
foreign {
	JS_ToInt32      :: proc(ctx: ^JSContext, pres: ^i32, val: JSValue) -> i32 ---   // JS_EXTERN: a real symbol
	JS_NewStringLen :: proc(ctx: ^JSContext, str: [^]u8, len: uint) -> JSValue ---  // JS_EXTERN: a real symbol
}

// QuickJS-ng's NAN-boxed value encoding (wasm32): JS_MKVAL(tag, val) == ((u64)tag << 32) | (u32)val. These mirror the
// `static inline` constructors of quickjs.h exactly; the glue layer (wj in Odin) will provide the full set.
JS_TAG_INT :: 0
js_new_int32 :: #force_inline proc "contextless" (val: i32) -> JSValue {
	return (u64(u32(JS_TAG_INT)) << 32) | u64(u32(val))
}

// A JSCFunction: (ctx, this_val, argc, argv) -> result. Exported so the C harness can take its address and hand it to
// JS_NewCFunction2. The address of an exported wasm function is a table index the engine can call indirectly, which is
// exactly how JS_NewCFunction2 stores and later invokes it.
@(export, link_name = "odin_add")
odin_add :: proc "c" (ctx: ^JSContext, this_val: JSValue, argc: i32, argv: [^]JSValue) -> JSValue {
	a, b: i32
	if argc > 0 { JS_ToInt32(ctx, &a, argv[0]) }   // Odin -> C: coerce JS args to int32 through the engine
	if argc > 1 { JS_ToInt32(ctx, &b, argv[1]) }
	return js_new_int32(a + b)   // build a JS number inline (NAN-box encoding), as quickjs.h's JS_NewInt32 does
}

// A second native function, returning a string built through the engine, to exercise JS_NewStringLen (a JSValue
// result that is a heap-allocated string: proves the shared allocator and refcounting work across the boundary).
@(export, link_name = "odin_greet")
odin_greet :: proc "c" (ctx: ^JSContext, this_val: JSValue, argc: i32, argv: [^]JSValue) -> JSValue {
	msg := "hello from Odin"
	return JS_NewStringLen(ctx, raw_data(msg), len(msg))
}

// A plain exported entry (not a JSCFunction) the C harness calls to prove a direct C -> Odin call with scalar args and
// result. Returns the two addresses the harness needs so it does not have to name the symbols itself (belt and
// suspenders: the export_name attributes already make them linkable).
@(export, link_name = "odin_add_addr")
odin_add_addr :: proc "c" () -> u32 {
	return u32(uintptr(rawptr(odin_add)))
}

@(export, link_name = "odin_greet_addr")
odin_greet_addr :: proc "c" () -> u32 {
	return u32(uintptr(rawptr(odin_greet)))
}

// C -> Odin with a scalar: the harness calls this and checks the result, independently of QuickJS.
@(export, link_name = "odin_mul")
odin_mul :: proc "c" (a: i32, b: i32) -> i32 {
	return a * b
}

// Keep intrinsics imported-and-used so -vet stays quiet if this grows; harmless no-op reference.
_ :: intrinsics
