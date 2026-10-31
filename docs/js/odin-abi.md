# The generic Odin ABI for the engine boundary

Status: in use for one domain (URL / URLSearchParams in the engine, `native/js/odin/web_url.odin`); the standalone
trunk `native/js/odin_abi/` proves every shape on both paths. The plan is Sacha's of 28/10 ("GARDER LE WASM"): the
engine stays a Wasm module, the boundary becomes a small generic ABI whose bridges the compiler instantiates from shared
Odin declarations, with no code generator; the only tool left extracts documentation and conformance.

## The pieces

```
native/js/odin_abi/
  abi/          abi.odin apply.odin marshal.odin wire.odin invoke.odin   -- shapes, cells, apply, the codecs
  api_decl/     url.odin abitest.odin                                    -- the shared declarations
  abi_host/     host.odin dispatch.odin scalar.odin                      -- host bridges: bind (serialised), register_scalar
  abi_guest/    guest.odin host_call.odin guest_url.odin guest_abitest.odin -- the guest's serialised stubs
  abi_url/      host.odin impl.odin abitest.odin                         -- a standalone URL host (real wb:url)
  check/        in-process round trip of every shape, serialised
  bench/ bench_guest/  Wasmtime runner + wasm32 guest: scalar vs serialised vs hand-written, and scalar == serialised
  apidoc/       docs/conformance from api_decl (core:odin/parser)
native/js/odin/jsb/   the JavaScript side inside the engine: JS values <-> declaration types, lowering onto wr_* imports
```

## Declarations (`package api_decl`)

One package both ends import. A declaration is a procedure type: the arguments and the results, nothing else.

```odin
URL :: distinct abi.Handle                       // a handle kind: named after its interface
URLComponent :: enum i32 { Href, Protocol, ... }
URL_get :: #type proc(url: URL, component: URLComponent) -> (string, abi.Api_Error)
URLPattern_create :: #type proc(init: URLPatternInit) -> (URLPattern, abi.Api_Error)   // a dictionary argument
Abi_Make :: #type proc(href: string) -> (abi.Owned(URL), abi.Api_Error)               // the caller releases
```

The shapes the boundary carries (abi.Shape):

| shape | Odin type | scalar wire (today's wr_*) | serialised wire |
|---|---|---|---|
| bool / i32 / enum | `bool`, an integer of 4 bytes or less, `enum i32` | one i32 | 4 bytes (bool: 1) |
| i64 / handle / Owned | `i64`, `u64`, `distinct abi.Handle`, `abi.Owned(H)` | one i64 | 8 bytes |
| float | `f32`, `f64` | one f32 / f64 | 4 / 8 bytes |
| string / bytes | `string` (UTF-8 checked), `abi.Bytes` / `[]u8` | (ptr, len) | u32 length + bytes |
| optional span | `Maybe(string)`, `Maybe(Bytes)` | (ptr, len), len = ABSENT when absent | length ABSENT when absent |
| optional scalar | `Maybe(T)` | (present i32, value) | u8 flag + value |
| slice | `[]T` | (ptr, count) | u32 count + the elements |
| dictionary | a struct | serialised only | its fields in declaration order (any shape above, nested) |

Results: nothing; a value; `abi.Api_Error`; `(value, abi.Api_Error)`. On the scalar wire a string result is a
(buffer, capacity) pair after the arguments and the return is the full length (negative: the error); a
`(value, error)` result is one more parameter, the address the value is stored at, and the return is the status; an
absent `Maybe(string)` result is Not_Found.

## The bridges, comptime

Everything reduces to two steps.

1. **Decode** the arguments, from wherever they arrive, into one `abi.Cell` per declared parameter (a scalar in `a`; a
   span `a` = address, `b` = length; an optional with its marker). Each source is a compile-time recursion over the
   declaration's parameter types (`proc(..., $P: typeid, $i, $n: int)`, `intrinsics.type_proc_parameter_type(P, i)`
   with `i` constant), one specialised step per parameter:
   - `abi_host.register_scalar`: the raw cells of a Wasm call (bounds-checked spans, UTF-8 check);
   - `abi.decode_params`: a serialised buffer (dictionaries through a run-time type-information walk, the cold path);
   - `jsb.args`: the JSValues of a JS call (`wj_to_str` / `web_to_usv`, `wj_to_int32`, `wj_to_handle`...).
2. **Apply** the procedure: `abi.apply(cells, P, p, &r0, &r1)`. Odin can walk a procedure type at compile time but
   cannot build a call of variable arity, so `apply` is the one place where arities 0..16 are spelled out; it serves
   every source and every return shape.

The wire shape of a scalar import (its Wasm parameter list) is filled by the same recursion as its decoding, so they
cannot disagree. A binding is proved against its declaration at compile time:

- `abi.must_bind(Decl, Impl)` (host): Impl is Decl plus a leading context, same results;
- `abi.must_match(Decl, Stub)` (guest stubs);
- `jsb`'s lowering asserts that the generated import has the declaration's wire shape (a span is a pointer then a
  4-byte length, a string result two more parameters, a `(value, error)` result one address). Two imports of the same
  shape (`URL_get` and `URL_set` are both `(u64, i32, ptr, u32) -> i32`) cannot be told apart by types; the name in the
  binding is the remaining guarantee.

Each failure is a compile error naming the parameter (a `where` clause on a constant index).

## Measurements

1 M calls, wasm32 guest over Wasmtime (Cranelift), best of five batches (the machine is shared: a median of three moved
by 2x between runs), `native/js/odin_abi/bench`, 28/10:

| shape | wr_* scalar (hand-written) | scalar bridge (comptime) | serialised host_call (comptime) |
|---|---:|---:|---:|
| URLSearchParams_size (handle -> i32) | 5.4 ns | 7.7 ns | 34.1 ns |
| URL_get .Pathname (handle, enum -> string) | 32.3 ns | 33.1 ns | 71.1 ns |
| URLSearchParams_has (handle, string, Maybe(string) -> bool) | 20.0 ns | 30.1 ns | 81.2 ns |
| Abi_Mix8 (i32 i64 f64 bool enum string Maybe(string) handle -> i64) | - | 33.5 ns | 119.3 ns |

Readings:

- **The comptime scalar bridge is the generated trampoline, plus 2–10 ns**: the embedder's `begin`/`end` and the UTF-8
  check go through function pointers (the hand-written baseline calls nothing for size and validates inline for has).
  With eight mixed arguments it stays at ~34 ns.
- **The serialised path costs ~+30–90 ns** (one copy per argument, a dispatch through the op table): constructors,
  dictionaries, cold functions; not the hot getters.
- Inside the engine, a URL getter bound through `jsb` (`url.pathname` 200 000 times in a page) costs ~205 ns against
  ~190 ns for the hand-written port: +15 ns for the cells and the generic `this`.

`bench` also checks that every shape gives the same answer through the scalar bridge and the serialised path
(`check_shapes`), and `check` verifies the serialised answers against the expected values in process.

## Inside the engine: `jsb`

The engine reaches the host through the generated `wr_*` imports (`native/js/odin/wj/wr_imports.odin`).
`jsb` binds a WebIDL member to a declaration and the import that carries it, with no per-function code:

```odin
jsb.getter(ctx, this_val, api_decl.URL_get, wj.wr_URL_get, URLComponent.Pathname, "URL")      // an attribute
jsb.method(ctx, this_val, argc, argv, api_decl.URLSearchParams_toString, wj.wr_URLSearchParams_toString, "URLSearchParams.toString")
jsb.function(ctx, argc, argv, api_decl.URL_canParse, wj.wr_URL_canParse, "URL.canParse", .USV)  // static
jsb.host(&count, api_decl.URLSearchParams_count, wj.wr_URLSearchParams_count, p, name)          // from behaviour code
```

`this` is the declaration's first parameter (its interface comes from the handle kind's name); the JS arguments are
converted by the declaration's types (a trailing `Maybe` is optional, the arity error is computed); the declaration is
lowered onto the import (strings to (ptr, len), `Maybe(string)` to WR_ABSENT, the string-result buffer grown and
retried once, the `(value, error)` address); the result goes back to JS by type, an `Api_Error` throws
(`wj_throw_status`).

## How to migrate a domain (10 steps)

The example is `web_url` (commit `bdd9a031`): 327 lines with every host call typed by hand, 256 lines with none.

1. **Read the domain and sort it.** In the ported `native/js/odin/<domain>.odin` (or the `.c`), mark what only carries a
   call across (category A: getters, setters, numeric calls, `toString`), what adapts (B: defaults, optional
   arguments, dictionaries), and what is behaviour (C: caches, sequences and records, iterators, bespoke messages).
2. **Declare.** For each host function the domain calls, write its declaration in `native/js/odin_abi/api_decl/<module>.odin`
   from `api/<module>.widl`: handle kinds as `distinct abi.Handle` named after their interface, enums `i32`, `raises`
   as an `abi.Api_Error` last result (a string getter that fails on a released handle raises), ownership as
   `abi.Owned(H)`, a dictionary as a struct.
3. **Check the wire.** The generated import `wj.wr_<Name>` must be the declaration's lowering (the table in "Shapes").
   `jsb` asserts it when you bind; a mismatch is the declaration being wrong, not the import.
4. **Replace the pass-through members** by one line each: `jsb.getter` (an attribute selected by a constant),
   `jsb.method` (`this` + JS arguments), `jsb.function` (static / global). Choose `.USV` where the IDL says USVString.
   The error text is `what`: keep the C's (`"URL"`, `"URLSearchParams.toString"`).
5. **Rewrite behaviour on `jsb.host`.** Every remaining host call becomes `jsb.host(&out, api_decl.X, wj.wr_X, args...)`:
   the operand structs, fill callbacks, `WJ_FETCH_STRING` loops, `(ptr, len)` / WR_ABSENT lowering and status checks
   disappear. A string result lives in the scratch buffer until the next host call: convert it first.
6. **Replace `this` checks and interface caches** by `jsb.this(ctx, this_val, Kind)` and `jsb.iface_of(Kind)`.
7. **Keep the exported names.** Every `wjr_*` the generated binding table references stays `@(export, link_name = ...)`
   with the same signature; nothing changes in `native/js/gen`.
8. **Build and check:** `odin check native/js/odin -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -vet`,
   then `cmd /c build.bat`.
9. **Test what the domain touches:** jstest, the e2e tool of the domain (jswebtest for url), `tools\wpt.ps1 -Only
   /<folder>/ -TimeoutMs 30000`. The judge is "the same subtests pass as before", against a build of the commit
   before the migration when `wpt/expectations` is older than the code.
10. **Measure the hot members** (a page timing 200 000 calls, `wren ctl run --eval`), report the before/after, commit.

Before (hand-typed transmission, one of each kind):

```odin
@(private = "file") Comp_Op :: struct { handle: u64, component: i32 }
@(private = "file")
fill_url_get :: proc "contextless" (user: rawptr, buf: [^]u8, cap: u32) -> i32 {
	op := (^Comp_Op)(user)
	return wj.wr_URL_get(op.handle, op.component, buf, cap)
}
@(private = "file")
url_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, component: i32) -> wj.JSValue {
	h, ok := url_handle(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	op := Comp_Op{ h, component }
	n := wj.fetch_string(fill_url_get, &op)
	if n < 0 { return wj.wj_throw_status(ctx, n, "URL") }
	return wj.new_string_len(ctx, wj.scratch_bytes(n))
}
@(export, link_name = "wjr_URL_get_href") wjr_URL_get_href :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return url_get(ctx, t, URLC_HREF) }

url_parse :: proc "c" (input: ^wj.Str, base: ^wj.Str, status: ^i32) -> u64 {
	h := u64(0)
	base_len := base.ptr != nil ? u32(base.len) : WR_ABSENT
	status^ = wj.wr_URL_parse(input.ptr, u32(input.len), base.ptr, base_len, &h)
	return status^ < 0 ? 0 : h
}
```

After:

```odin
@(export, link_name = "wjr_URL_get_href") wjr_URL_get_href :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, .Href) }
// with, once for the ten components:
get :: #force_inline proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, component: URLComponent) -> wj.JSValue {
	return jsb.getter(ctx, t, api_decl.URL_get, wj.wr_URL_get, component, "URL")
}

url_parse :: proc(input: wj.Str, base: wj.Str) -> URL {
	u: URL
	b: Maybe(string) = base.ptr != nil ? str_of(base) : nil
	if jsb.host(&u, api_decl.URL_parse, wj.wr_URL_parse, str_of(input), b) != .None { return 0 }
	return u
}
```

## The host side, next

The host still serves `module url` through the bindgen trampolines (`src/page/api_generated.odin`). The same
declarations bind its implementations with `abi_host.register_scalar` (the wire is identical, so the engine does not
change): move `src/page`'s URL implementations to the declaration's shape (`proc(c: ^Call, <arguments>) -> <results>`),
register them, and drop the module from bindgen's host emitter. `abi_url` is that binding, standalone.

## What stays out of the comptime bridge

- **WebIDL overloads and unions** (`foo(DOMString)` / `foo(long)`, `(DOMString or Blob)`): resolved in the JS binding,
  by hand, dispatching to differently named declarations.
- **Callbacks** (a listener handed to the host): a function-table index (`wj.table_index`) and a `user` word, unchanged.
- **Same-shape imports** (two declarations whose lowering is identical): only the name tells them apart.
- **Enums from JS**: a WebIDL enum is a string in JS; `jsb` does not convert it (a member takes it by hand, or the
  declaration takes a string).
