# Writing Wren's JavaScript glue in Odin

Wren's JavaScript engine is QuickJS-ng compiled to one WebAssembly module (`build/js/wren_js.wasm`). Around the engine
sits the *glue*: the code that implements the web platform's objects and functions as QuickJS native functions and wires
them to the browser's `wr_*` imports. Today most of that glue is hand-written C (`native/js/runtime/*.c`, ~47 000 lines)
plus generated C (`native/js/gen`, bindgen). The goal is to move it to **Odin**, keeping only the Rust libraries and the
upstream QuickJS C.

This document is the recipe. It is backed by two proofs in the tree:

* `native/js/odin_spike/` — the minimal link proof (Odin ↔ C ↔ JS in one module), run by `src/tools/spiketest`.
* `native/js/odin/` — the real glue layer (`wj`) and the first ported domain (`web_strategy.odin`), linked into the
  production engine by `tools/build_js.ps1` and exercised through `build/jsengine.exe`.

## What was proven

* An Odin procedure compiled to a wasm32 object links, with zig's `wasm-ld`, into the **same module** as the QuickJS
  objects that `zig cc` produces. It calls the QuickJS C API, is called from JavaScript as a native function, and C can
  call it directly. The reverse (C → Odin) works too.
* `CountQueuingStrategy` / `ByteLengthQueuingStrategy` (the Streams Standard queuing strategies) were ported from
  `native/js/runtime/web_strategy.c` to `native/js/odin/web_strategy.odin` with identical behaviour; the C file is
  dropped from the build and the generated binding table resolves to the Odin `wjr_*` functions unchanged.

## The ABI: `JSValue` is a `u64`

The single most important fact. On wasm32 (`INTPTR_MAX < INT64_MAX`), QuickJS-ng turns on **NAN boxing**
(`quickjs.h`: `#define JS_NAN_BOXING 1`, then `typedef uint64_t JSValue`). So a `JSValue` is a bare 64-bit integer, and
every glue function passes and returns it in a single wasm `i64`. There is **no struct-by-value ABI question** on this
target: Odin's `u64` matches C's `JSValue` exactly, by value, in parameters and results.

The native-function signature (`JSCFunction`) is therefore, in Odin:

```odin
proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue
```

which is byte-for-byte the C `JSValue (*)(JSContext *, JSValueConst, int, JSValueConst *)`. Getters and setters drop the
`argc/argv` the obvious way (`wj.Getter`, `wj.Setter`).

## Three kinds of symbol

When wasm-ld links the Odin object with the C objects, a name either resolves to a C definition in the module, or it
does not and becomes an **import from `env`** (which then traps at run time). So the glue layer must know, for each
engine function it uses, whether that function has a real symbol.

1. **Real symbols** — functions declared `JS_EXTERN` in `quickjs.h`, and the `wj_*` / `web_*` functions of
   `native/js/engine` and `native/js/runtime`. Declare them in an Odin `foreign` block with the exact C name and
   signature; wasm-ld resolves them to the C definitions. Examples: `JS_GetPropertyStr`, `JS_ToFloat64`,
   `JS_NewNumber`, `JS_ThrowTypeError`, `wj_new_object`, `web_this_impl`, `web_dict_get`.

2. **`static inline` helpers and macros** — the value constructors and predicates of `quickjs.h`/`qjs_backend.h`
   (`JS_NewInt32`, `JS_IsException`, the `JS_UNDEFINED` constant, `wj_arg`…). These have **no symbol**; a `foreign`
   declaration of them would become an unresolved import. Reimplement them in Odin. With NAN boxing they are a few bit
   operations — see `new_int32`, `is_exception`, `arg` in `native/js/odin/wj/wj.odin`.

3. **Fields of C global structs** — e.g. `wj_the_realm.global`. A struct field has no symbol either, and mirroring the
   `wj_realm` layout in Odin is fragile. Until `wj_the_realm` itself is ported, expose what you need through one tiny C
   accessor (`native/js/odin/wj_shim.c`: `wj_realm_global()`). This shim is *only* an accessor; it holds no logic and
   shrinks as more of the engine moves to Odin.

### Pitfall: reimplementing the NAN-box float encoding

`JS_NewInt32` is trivial (`(u64(tag) << 32) | u32(val)`) and reimplementing it in Odin works. The float constructor
`__JS_NewFloat64` is `bits(d) - (ADDEND << 32)` with u64 wraparound — and the Odin build miscomputed that 64-bit
wrapping subtraction for ordinary operands (a `3.5` came back as `NaN`). **Do not reimplement the float encoding.** Use
the engine's real `JS_NewNumber(ctx, d)` symbol instead (that is why `wj.new_float64` takes a `ctx`, unlike the inline
C version). It also chooses the int representation for integral doubles exactly as the engine expects. The lesson
generalises: when a real symbol exists, prefer it over reproducing the engine's internal bit tricks.

## The `wj` helper layer (`native/js/odin/wj/wj.odin`)

This is the Odin equivalent of `engine/wj.h` + `qjs_backend.h` + the parts of `runtime/web.h` a ported domain uses. It is
the artifact other agents build on. It provides:

* Types: `JSValue` (u64), `Context`/`Runtime` (opaque), `Native`/`Getter`/`Setter` (the function signatures).
* Value constructors/predicates (inline, NAN-box): `new_bool`, `new_int32`, `new_float64` (via `JS_NewNumber`),
  `is_exception/undefined/null/object/string/number`, the `UNDEFINED/NULL/EXCEPTION/TRUE/FALSE` constants, `arg`.
* Engine functions (real symbols) in `foreign` blocks: `JS_GetPropertyStr`, `JS_SetPrototype`, `JS_FreeValue`,
  `JS_DupValue`, `JS_ToFloat64`, `JS_ToInt32`, `JS_IsFunction`, `JS_ThrowTypeError` (C varargs via `#c_vararg`),
  `JS_ThrowOutOfMemory`, `JS_NewCFunction2` (+ the inline `new_cfunction`), `JS_GetGlobalObject`, `JS_NewNumber`.
* `wj.h` helpers: `wj_new_object`, `wj_malloc`/`wj_free` (aliased `malloc`/`free`), and `iface(name)` which resolves an
  interface index **by name** through `wj_interface_find` (so the glue never hardcodes the generated `WJ_IFACE_*`
  numbers and survives their renumbering).
* `web.h` helpers a domain needs: `web_this_impl`, `web_dict_check`, `web_dict_get`, `web_extra_get`, `web_extra_set`,
  and `realm_global()` (through the shim).

Grow this layer as you port domains: add the `foreign` declarations and inline helpers the new domain needs, keeping
names and signatures matched to the C.

## Writing a domain (worked example)

See `native/js/odin/web_strategy.odin`. The rules:

* The package is `odin_glue` (one package for all ported domains, so they share one object).
* Every function the generated binding table references keeps its **exact C name** via
  `@(export, link_name = "wjr_<Interface>_<member>")`. The table in `native/js/gen/bindings.c` is unchanged; wasm-ld
  resolves its forward references to your Odin exports.
* The signatures are `proc "c"` with the `wj` types.
* Engine-owned object data (the C `impl`) is allocated with `wj.malloc`, stored with `wj.wj_new_object(ctx, iface,
  impl, free_proc)`, and read back with `wj.web_this_impl(ctx, this, iface)`. The `free_proc` is a `proc "c"
  (p: rawptr)` that calls `wj.free`.
* Resolve interface indices once, by name, and cache them (see `count_iface` / `bytelen_iface`).

## Building

`tools/build_js.ps1` was taught to include the Odin glue:

* `native/js/odin/*.odin` → one wasm32 object (`odin build -build-mode:obj -target:freestanding_wasm32 -no-entry-point
  -default-to-nil-allocator -o:size`).
* `native/js/odin/wj_shim.c` is compiled with the rest of the C.
* A `$odinified` list names the C files that have been ported; they are dropped from the C sources. Today:
  `web_strategy.c`.
* **Linking:** the C is compiled to plain wasm objects (no `-flto`) and linked with the Odin object without LTO. Why:
  Odin's freestanding wasm runtime defines `memset`/`memcpy`/`memmove`/`bzero` as *strong* symbols (it assumes no
  libc), and so does wasi-libc. A one-shot **LTO** link rejects the duplicate as a hard error; a plain-object link only
  **warns** (the definitions are semantically identical). So the build drops cross-TU LTO while an Odin object is
  present.

### The LTO trade-off (known, measured)

* Dropping cross-TU LTO is the one real cost. In this spike it did **not** grow the module (the pre-initialized
  `wren_js.wasm` was *smaller* without LTO — 3901 KiB vs 5060 KiB — because LTO's aggressive inlining expands the memory
  image the snapshot captures). The runtime effect of losing LTO was not benchmarked here and is the lead's call.
* A bonus: per-TU compilation makes **incremental** engine builds much faster (zig caches unchanged objects: ~3 s to
  rebuild after a one-file change, vs ~32 s for the one-shot LTO build that recompiled everything).
* Paths to reclaim LTO later, if wanted: (a) stop Odin emitting the libc memory functions (needs an Odin option or a
  patched `base:runtime`); (b) do the final link with `wasm-ld` directly, placing the Odin object before `libc.a` so
  the libc members are never pulled (needs reproducing zig's sysroot link line); (c) weaken the Odin object's four
  memory symbols with `llvm-objcopy` before linking. None were needed to make the glue work.

## Reproduce

```powershell
# the minimal link proof
powershell -NoProfile -File native\js\odin_spike\build_spike.ps1
odin build src\tools\spiketest -collection:wb=src -vet -out:build\spike\spiketest.exe -o:speed -extra-linker-flags:/STACK:33554432
build\spike\spiketest.exe build\spike\spike.wasm        # "spike: all checks passed"

# the engine with the Odin-ported domain
powershell -NoProfile -File tools\build_js.ps1
build\jsengine.exe run -e "var c = new CountQueuingStrategy({highWaterMark: 7}); console.log(c.highWaterMark, c.size(0))"
#   -> 7 1
```
