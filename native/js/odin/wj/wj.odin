// package wj: the Odin side of Wren's JavaScript glue — the one shared helper layer every ported domain imports.
//
// This is the Odin equivalent of native/js/engine/wj.h + qjs_backend.h + the parts of native/js/runtime/web.h that a
// ported domain uses. A domain written in Odin (native/js/odin/web_*.odin, qjs_convert.odin, ...) imports this package
// instead of including those headers; the whole lot is compiled to one wasm32 object (odin build native/js/odin) and
// linked by zig's wasm-ld with the QuickJS-ng objects and the remaining C glue into the one engine module, exactly as
// native/js/odin_spike proved. See docs/js/odin-glue.md for the rules (where a new helper goes, how to declare an
// import, how to add a domain, and how the G1/G4 agents rebase onto this unified layer).
//
// ONE declaration per symbol. The layer used to be four files (wj.odin + a wj_gN.odin per porting agent), each
// redeclaring the QuickJS API and the wj_*/web_* imports it happened to need; that collided ("Redeclaration of ...")
// the moment two of them were compiled together. The symbols now live once, grouped by theme:
//
//   wj.odin       this file: the package doc and the core opaque types (JSValue, Context, Runtime, the proc shapes).
//   quickjs.odin  the QuickJS-ng public C API (quickjs.h JS_EXTERN) as `foreign`, plus the `static inline`
//                 constructors / predicates of quickjs.h reimplemented on the NAN box (no symbol to link to).
//   host.odin     the wj_*/web_* functions of native/js/engine and native/js/runtime (real symbols), the realm
//                 singletons / kinds, and the tiny C field accessors of wj_shim.c (fields of global C structs).
//   strings.odin  the string conversions, the scratch buffer and WJ_FETCH_STRING, cstring helpers.
//   values.odin   buffers, typed arrays, iterators, promises-as-values, events, streams, the clone serialiser.
//   errors.odin   the error throwers and the error-as-value constructors.
//   libc.odin     the few libc / libm symbols the ported engine layer (qjs_convert) needs.
//
// Three kinds of symbol live in the layer:
//   * a function with a real symbol (JS_EXTERN in quickjs.h, a wj_*/web_* of engine/runtime) -> a `foreign` block;
//     wasm-ld resolves it to the C definition in the same module. Names and signatures match the C exactly.
//   * a `static inline` / macro of the headers (JS_NewInt32, JS_IsException, the JS_UNDEFINED constant, WJ_FETCH_STRING)
//     -> reimplemented inline here (a few NAN-box bit operations, or a small proc).
//   * a *field of a global C struct* (wj_the_realm.global/.ctx/.protos, wj_scratch, wj_obj.handle/impl) -> a one-line
//     C accessor in native/js/odin/wj_shim.c, because a field has no symbol wasm-ld can resolve.
//
// Nothing here allocates Odin memory or uses `context`: procs are "contextless" and the engine's malloc (shared, in the
// same module) is reached through wj.malloc / wj.free when a domain needs raw memory.
package wj

// ---- core types (qjs_backend.h) ----

// On wasm32 QuickJS-ng selects NAN boxing: `typedef uint64_t JSValue` (quickjs.h). Odin passes and returns it in one
// wasm i64, matching the C ABI with no struct-by-value question. A glue proc takes and returns JSValue by value.
JSValue :: u64
Context :: struct {}   // opaque JSContext; only ever used behind a pointer
Runtime :: struct {}   // opaque JSRuntime

// A method / constructor / function: (ctx, this, argc, argv) -> result or EXCEPTION. The exact JSCFunction signature.
Native :: #type proc "c" (ctx: ^Context, this_val: JSValue, argc: i32, argv: [^]JSValue) -> JSValue
// An attribute getter: (ctx, this) -> result.
Getter :: #type proc "c" (ctx: ^Context, this_val: JSValue) -> JSValue
// An attribute setter: (ctx, this, value) -> result (undefined or EXCEPTION).
Setter :: #type proc "c" (ctx: ^Context, this_val: JSValue, value: JSValue) -> JSValue

// The browser's own handle types the glue passes around (wren_api.h).
Handle :: u64        // wr_Object / a node / a port end; 0 is "none"
WR_ABSENT :: u32(0xFFFF_FFFF)   // an absent optional length (UINT32_MAX)
