# Writing Wren's JavaScript glue in Odin

Wren's JavaScript engine is QuickJS-ng compiled to one WebAssembly module (`build/js/wren_js.wasm`), run by Wasmtime.
Around the engine sits the *glue*: the code that implements the web platform's objects as QuickJS native functions and
wires them to the browser's `wr_*` imports. It is moving from hand-written C (`native/js/runtime/*.c`) to Odin
(`native/js/odin/`), in the same Wasm module: Odin and C objects are linked together by zig's `wasm-ld`.

This document is the rule book: where things go, how to declare them, how to add a domain. The generic ABI that will
replace the hand-written transmission layer is in [odin-abi.md](odin-abi.md).

## The layout

```
native/js/odin/            package odin_glue: the ported domains, one file per former .c (web_url.odin, dom_style.odin...)
  ifaces.odin              interface indices several domains share (resolved by name, cached)
  dicts.odin               mirrors of generated dictionaries (gen/bindings.h wjd_*) the glue reads
  wj_shim.c                NO code: _Static_assert of every C struct offset the Odin side mirrors
  jsb/                     package jsb: members bound to shared declarations (native/js/odin_abi/api_decl) and the
                           wr_* import that carries each, by comptime bridges (odin-abi.md)
  wj/                      package wj: the one helper layer every domain imports
    wj.odin                core types (JSValue = u64, Context, Runtime, Native/Getter/Setter)
    quickjs.odin           the QuickJS-ng C API (foreign) + its static inlines reimplemented on the NAN box
    engine.odin            the engine's structs mirrored (Obj, Realm, Interface, Listener, Buf), its globals
                           (wj_the_realm, wj_scratch, wj_interfaces, wj_class_*), obj_of / web_set_impl / realm_*
    host.odin              wj_* / web_* functions of the C that stays (native/js/engine, native/js/runtime)
    wr_imports.odin        GENERATED (src/tools/bindgen, from api/*.widl): every browser import wr_*
    strings.odin           Str, WJ_FETCH_STRING (fetch_string), scratch helpers, JS-string constructors
    values.odin            promises as values, blobs, FormData, Headers, streams, signals, structured clone
    errors.odin            throwers (wj_throw_*) and error values (web_dom_exception...)
    dom.odin               dom_internal.h: Dom_Impl (mirrored) and the dom_core.c helpers
    libc.odin              libc / libm (libc_malloc / libc_free, strlen, memcmp, snprintf, fmod...)
    convert.odin           Web IDL conversions (was engine/qjs_convert.c): wj_to_str, wj_to_int32, wj_to_handle...
    buffer.odin            BufferSource helpers (was runtime/buffer.c): wj_to_buffer_source, wj_*_from_host...
    promise.odin           browser promises (was runtime/promise.c): wj_promise_from_host, wj_host_promise_text
```

Every symbol is declared **once**. `odin check native/js/odin -target:freestanding_wasm32 -no-entry-point` fails with
"Redeclaration of ..." the moment a second declaration appears; that is the point.

## Where a helper goes

| What it is | Where |
|---|---|
| a QuickJS function with a real symbol (`JS_EXTERN` in quickjs.h) | `wj/quickjs.odin`, the `foreign` block, exact C name and signature |
| a quickjs.h `static inline` / macro (`JS_NewInt32`, `JS_IsString`, `JS_UNDEFINED`) | `wj/quickjs.odin`, reimplemented (NAN-box bit operations); never `foreign` |
| a `wj_*` / `web_*` function of the C that stays | `wj/host.odin` (objects, realm, events, iterators), `wj/values.odin` (values), `wj/errors.odin` (throwers), `wj/dom.odin` (dom_internal.h) |
| a helper of `wj.h` you port to Odin (a former engine/runtime .c everyone calls) | its own file in `wj/` (like `convert.odin`), `@(export, link_name = "<C name>")` so the remaining C links against it |
| a browser import `wr_*` | nowhere by hand: `wj/wr_imports.odin` is generated (see below) |
| a field of an engine struct | the mirror in `wj/engine.odin` / `wj/dom.odin`, plus its offset in `wj_shim.c` **and** the `#assert` block of `engine.odin` |
| a helper only one domain uses | `@(private = "file")` in that domain |
| a helper two domains use | `wj/` if it is generic (strings, values), `native/js/odin/<theme>.odin` (package odin_glue) if it is about the domains (ifaces.odin) |

A domain calls everything of the layer qualified: `wj.wj_to_str`, `wj.JS_NewStringLen`, `wj.wr_URL_get`. Nothing of
`wj` is redeclared in a domain.

## How to declare a browser import

You do not. `src/tools/bindgen` emits `native/js/odin/wj/wr_imports.odin` from `api/*.widl` on every `build.bat` (in
both `-emit:c` and `-emit:odin` modes), next to the C header `native/js/gen/wren_api.h`: same module, same names, same
types. If an import is missing, it is missing from the API description: add it to the `.widl` (and the host side in
`src/page`), run `build.bat`, and it appears as `wj.wr_<Name>`.

Better still, do not call it by hand: declare the function in `native/js/odin_abi/api_decl/<module>.odin` and call
`jsb.host(&out, api_decl.X, wj.wr_X, args...)` (or bind the member with `jsb.getter` / `jsb.method` /
`jsb.function`): the strings, the result buffer, the status and the wire shape are then the compiler's
([odin-abi.md](odin-abi.md), "How to migrate a domain"). `web_url.odin` is written that way.

The generated conventions, which a hand-written call follows:

* handles are `u64`, booleans `i32` (`relative ? 1 : 0`), enums `i32`, strings `(ptr: [^]u8, len: u32)`, string
  results `(_buf: [^]u8, _cap: u32) -> i32` (the full length, or a negative `wr_Error`);
* callbacks are a function-table index `i32`: `wj.table_index(rawptr(my_export))`;
* the calling convention is `"contextless"`: a proc-typed parameter that receives a `wr_*` import must be
  `proc "contextless" (...)`, not `proc "c"` (`wj.fetch_string(wj.wr_Window_origin)` works as is).

## How to add a domain

1. Port `native/js/runtime/<x>.c` to `native/js/odin/<x>.odin`, `package odin_glue`, `import "../odin/wj"`. Port the
   behaviour; for what only carries a call to the host, declare it in api_decl and bind it with jsb (odin-abi.md,
   the 10 steps) instead of translating the C line by line.
2. Keep every symbol the generated table (`native/js/gen/bindings.c`) or other C references: `@(export, link_name =
   "wjr_<Interface>_<member>")`, `proc "c"`, the `wj` types. Same behaviour, same error messages (WPT and the test
   pages compare them).
3. Interface indices by name, once: `wj.iface("Element")` cached in a file-private variable (or `ifaces.odin`).
4. Add `'<x>.c'` to `$odinified` in `tools/build_js.ps1`: one entry per line, sorted. The C file stays in the tree (the
   bindgen scans it for raw members) but is no longer compiled.
5. `odin check native/js/odin -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator`, then `build.bat`,
   then the tests of the domain (jstest, jsdomtest, jswebtest, the WPT folders; see the end).

## Pitfalls (each one was hit)

* **A global needs a link-time constant initializer.** The glue is an object with no Odin startup code: a file-scope
  variable whose initializer is not a constant is left **zero**. Numbers, enums, structs of numbers, `[N]string{...}`
  and `[N]cstring{"a", "b"}` are constant; a `nil` among cstring literals is not (`popover_states` read as all-zero:
  `HTMLElement.popover` returned `""`). Use `""` instead of `nil`, or build the value in the domain's preinit.
* **C varargs take C types.** `wj.wj_throw_type`, `wj.JS_ThrowTypeError`, `wj.snprintf` are `#c_vararg`: pass `cstring`,
  `[^]u8`, `i32`, `f64`. An Odin `string` (a `kind := cond ? "a" : "b"` is one) goes as a two-word struct and prints
  garbage: write `kind: cstring = ...`. `%.*s` takes an `i32` length then a pointer.
* **A C string stops at the first NUL.** A JS string may contain one; when the value matters (custom element names,
  keys), keep the `JSValue` (`JS_ToString`) instead of a `cstring` round trip.
* **`Str.ptr` is `[^]u8`** (may be nil for a nullable). Pass it to an import as `wj.cstr_bytes(s.ptr)`; compare with
  `wj.str_eq(p, "literal")` (accepts `[^]u8` or `cstring`).
* **`wj.wj_this` / `wj.wj_unwrap` return `^wj.Obj`**: read `o.handle`, `o.impl` directly (or `wj.handle_of(o)` /
  `wj.impl_of(o)` when `o` may be nil). `wj.obj_handle(v)` / `wj.obj_impl(v)` take a `JSValue`.
* **Do not reimplement the NAN-box float encoding**: `wj.new_float64(ctx, d)` goes through the engine's `JS_NewNumber`
  (an Odin copy of `__JS_NewFloat64` miscompiled a 64-bit wrapping subtraction). `JS_IsString` includes ropes,
  `JS_IsBigInt` short big ints: use `wj.is_string` / `wj.is_big_int`, never a single-tag compare.
* **Two heaps.** What the C freed with `free()` is freed with `wj.libc_free`; engine-owned data made for
  `wj_new_object` uses `wj.malloc` / `wj.free` (the engine's allocator); JS-owned bytes (`JS_ToCStringLen`, `js_malloc`)
  go back to the engine (`JS_FreeCString`, `js_free`).

## Struct mirrors and the shim

The engine's structs (`wj_obj`, `wj_realm`, `wj_interface`, `wj_listener`, `wj_buf`, `wj_str`, `dom_impl`,
`web_extracted`) are plain wasm32 C (natural alignment, no bitfields): Odin's default layout reproduces them, so the glue
reads `wj.wj_the_realm.protos[i]` or `o.impl` in place, without a call. The first ports went through one-line C
accessors per field (three shims, 13 accessors); they are gone.

`wj_shim.c` is what makes the mirrors safe: it holds only `_Static_assert(offsetof(...) == N)` for every mirrored
field, and `engine.odin` asserts the same numbers on the Odin side (`#assert(offset_of(Obj, impl) == 36)`). A change on
either side stops the build. Nothing else may go into the shim: a `static inline` is reimplemented in Odin, a field is
mirrored. The shim disappears with the last C struct.

Why no accessor is left in C: every remaining "C only" thing is either a real symbol (declared `foreign`), a
`static inline` (reimplemented), or a field (mirrored and asserted). There is no fourth case.

## Building

* `tools/build_js.ps1` compiles `native/js/odin` to one wasm32 object (`odin build -build-mode:obj
  -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -o:size`), compiles the C that is not in
  `$odinified` (plus `wj_shim.c`) to plain objects, and links them. The C is not LTO'd while an Odin object is present:
  Odin's freestanding runtime defines `memset`/`memcpy`/`memmove`/`bzero` as strong symbols, as wasi-libc does; a
  plain-object link only warns (`function signature mismatch: bzero`, harmless and expected), an LTO link refuses.
* `build.bat` runs bindgen first, so `wr_imports.odin` is always current.

## Testing a ported domain

Build: `cmd /c build.bat`. Then, as relevant to the domain: `jstest` (no server), `jsdomtest`, `jswebtest`,
`jsloadtest`, `workerstest`, `netapitest`, `mediatest` (each `odin build src/tools/<t> -use-separate-modules
-collection:wb=src -vet -out:build/<t>.exe -o:speed -extra-linker-flags:/STACK:33554432`, run with a test server from
`tools/test_env.ps1`), `tools/test262.ps1 -NoNative -Quick`, and `tools/wpt.ps1 -Only /<folder>/ -TimeoutMs 30000`
for the WPT folders of the domain (the folders must be in `wpt/suites.txt`). A WPT "regression" is relative to
`wpt/expectations`, which may be older than the code: compare with a build of the commit before the port before
concluding (url's worker `exclude=` variants and webstorage's `storage_session_window_noopener` were already
different before any port).
