# The generic Odin ABI for the engine boundary

Status: prototype (`native/js/odin_abi/`), a separate trunk that does not touch the main build. It shows the
guest ↔ host boundary built by Odin's compile-time generics from shared Odin declarations, with no code
generator — the plan Sacha set on 28/10 ("GARDER LE WASM"): the engine stays a Wasm module, the boundary becomes a
small generic ABI, and the only tool that remains extracts the documentation and the conformance report.

## Why

Today `src/tools/bindgen` reads `api/*.widl` (~5 000 lines of Odin) and writes ~40 000 lines: the host trampolines
(`src/page/api_generated.odin`), the Odin guest SDK (`sdk/odin/web/*`), the C guest header (`native/js/gen/wren_api.h`),
the docs and the conformance cases. Every function has one hand-shaped Wasm import and one hand-shaped host trampoline.
It is fast, but it is a generator: a second language to parse (`.widl`), emit and keep in step with the engine.

When the engine is written in Odin (`wasm32`), both ends of the boundary can read the **same Odin declarations** and let
the compiler instantiate the bridges. No `.widl`, no emitted C, no emitted Odin. One source of truth; a shape mismatch
becomes a compile error instead of a silent ABI drift.

## Shape of the boundary

Two wire shapes, one serialisation and one set of compile-time marshallers (`package abi`). Both ends read
`package api_decl`, so the host and the `wasm32` guest agree by construction.

### 1. The scalar fast path (hot)

Each argument stays a separate Wasm scalar in the call's raw cell array, decoded by a **constant index**; a string
result goes into a `(ptr, cap)` buffer and the call returns the length needed. This is byte-for-byte the current `wr_*`
ABI (handles `i64`, strings `(ptr, len)`, errors a negative `i32`), but the trampoline is **built by the compiler**
from the signature (`abi_host.register_scalar_*`) instead of generated. It carries the hot 0..N simple-parameter
functions (getters, setters, numeric calls).

### 2. The serialised path (general, cold)

One import per domain, `host_call(op, args_ptr, args_len, ret_ptr, ret_cap) -> status`. The guest packs the arguments
into its own memory and names the function by an operation number; the host validates the two spans against the
module's memory, decodes the arguments against the declaration, calls the implementation, and serialises the result
into the result buffer. A result that does not fit returns `Truncated`; the guest grows its buffer and retries. This
carries the shapes the fixed cell array cannot (long argument lists, growable results) and keeps the import table
small. It costs one copy per argument plus one indirect dispatch — about **+100 ns/call** over the scalar path
(measured below), so it is not used for the hot getters.

Both shapes exist because the measurement shows the serialised path is too expensive for the hottest functions, and the
scalar path cannot express everything (a 28-argument `URLPattern` constructor, a growable `getAll`).

## Serialisation

Little-endian, no padding (the only byte order `wasm32` and the host use), self-describing by static type:

| Odin type | wire |
|---|---|
| `bool`, `i32`, enum (`i32`) | 4 bytes |
| `i64`, `u64`, a handle (`distinct abi.Handle`) | 8 bytes |
| `f64` | 8 bytes |
| `string` | `u32` length, then the bytes; the host checks UTF-8 |
| `[]u8` / `abi.Bytes` | `u32` length, then the bytes; no check |
| `Maybe(string)` | length `== 0xFFFF_FFFF` (`ABSENT`) when absent, else as a string |
| `Maybe(T)` otherwise | a `u8` present-flag, then the value |
| a dictionary (`struct`) | its fields in declaration order (see "Out of scope") |

The result is the status cell followed by the return values in the same format. Reading and writing is a cursor
(`abi.Reader` / `abi.Writer`); a read past the end sets a flag the dispatcher turns into a trap, a write past `ret_cap`
sets `Truncated` and the length needed.

## The declarations (`package api_decl`)

One package both the host and the guest import (`when ODIN_ARCH == .wasm32` on the guest). It expresses:

- **handles** as distinct types (`URL :: distinct abi.Handle`), so the compiler keeps a `URL` from being passed where a
  `URLSearchParams` is wanted; on the wire a handle is a `u64`, resolved to the live object by the host binding;
- **enumerations** (`i32`);
- **dictionaries** as structs with default values, an absent member told apart by its `has_*` flag;
- **procedure signatures** (the arguments and the result), with `raises` expressed as an `abi.Api_Error` last return
  value, and ownership noted in the doc comment (`[Owned]` → the caller releases; a borrowed handle is called out).

The signatures carry no context: the host binds an implementation of shape `proc(ctx: ^Call, <args>) -> <result>` and
the guest a stub of shape `proc(<args>) -> <result>`; the bridge adds or drops the context. `abi_host.bind` checks at
compile time that the implementation is the declaration plus a leading context, same returns.

## The bridges (compile-time, `base:intrinsics`)

The crux is that Odin can walk a procedure type at compile time:
`type_proc_parameter_count`, `type_proc_parameter_type(P, <const>)`, `type_proc_return_count`, `type_proc_return_type`,
`type_is_enum`, `type_base_type`, `type_is_union` + `type_variant_type_of` (for `Maybe`). Two constraints shaped the
design:

- `type_proc_parameter_type(P, i)` needs a **constant** index and is a type only **inside a procedure body**, not in a
  signature. So the per-argument decode is written inline in an **arity ladder** (0..8 arguments after the context),
  one branch per parameter count; each branch decodes exactly its arguments and calls the implementation. The ladder is
  the whole "generic" cost, written once.
- a `proc "c"` Wasm callback **cannot capture** locals. The host trampoline is produced by a generic
  (`register_scalar_*` / `bind` → `install`) that captures the implementation value **at compile time**, so the stored
  trampoline closes over nothing at run time; the registry is reached through one process-global pointer and a
  specialised thunk.

Result encoding is by **procedure overloading** (`encode_returns`): void, a value, an `Api_Error`, or `(value,
Api_Error)` — the compiler picks the form from the call's return tuple, no run-time test. There is no reflection on the
hot path: every `decode_arg` / `encode_ret` resolves at compile time to the right load, check and store for that exact
type.

## Measurements

Machine: the author's Windows box, Cranelift (speed), `wasm32` guest over Wasmtime, 1 M calls each, median of 3
(`native/js/odin_abi/bench`). The scalar "hand-written" column is a `proc "c"` written exactly as `bindgen` emits it,
registered next to the comptime bridges under a sibling module, so all three are the same machine, engine and guest.

| shape | `wr_*` scalar (hand-written / generated) | scalar bridge (comptime) | serialised `host_call` (comptime) |
|---|---:|---:|---:|
| `URLSearchParams_size` (handle → i32) | ~50 ns/call | ~62 ns/call | ~150 ns/call |
| `URL_get .Pathname` (handle, enum → string) | ~135 ns/call | ~150 ns/call | ~245 ns/call |

Readings:

- **The comptime scalar bridge matches the generated trampoline** (within ~12 ns, from the one extra indirection to the
  config holder, which a real `package page` integration inlines through `api_begin`). The import structure confirms
  it: the guest's scalar calls are per-function imports, exactly as `wr_*` today; the serialised path is a single
  `host_call` import.
- **The serialised path costs ~+100 ns/call**: the per-argument copy and one indirect dispatch into the op table. Fine
  for constructors and cold functions, too much for the hottest getters — hence keeping the scalar path.

An in-process check (`native/js/odin_abi/check`, no Wasm instance, the exact guest bindings against the dispatcher)
exercises the whole domain (parse, getters, relative resolution, `searchParams` both-way link, the `URLPattern`
dictionary constructor, `test()`), each result checked against the native `wb:url`.

## Proof: two domains end to end

`native/js/odin_abi/` migrates the **URL / URLSearchParams / URLPattern** domain of `api/url.widl` end to end:

- `api_decl/url.odin` — the shared declarations (handles, enums, the `URLPatternInit` dictionary, 18 procedure
  signatures with `raises`).
- `abi_url/` — the host implementation, backed by the real `wb:url`, with its own handle pools (standalone so the
  prototype does not entangle `package page`). `build_registry` binds each declaration to its implementation;
  `URLPattern_create` uses the dictionary escape hatch (`bind_manual`).
- `abi_guest/guest_url.odin` — the guest bindings (the mirror of the shipped SDK), the same code that compiles to
  `wasm32`.
- `bench_guest/` + `bench/` — the `wasm32` guest and the host runner for the measurement.
- `check/` — the in-process round-trip, all assertions passing.

The engine today is QuickJS in C, so a real integration also needs a thin C guest that calls `host_call` (the shape is
one import plus a serialise/deserialise helper); that is the `native/js/runtime` glue, coordinated with the C↔Odin work.
The Odin guest path above is what the boundary becomes once the engine is Odin.

## The tool that remains

`apidoc` (`native/js/odin_abi/apidoc`) reads `package api_decl` with `core:odin/parser` + `core:odin/ast` and writes one
Markdown page per module (`docs/api/<module>.md`): the handles, enumerations, dictionaries and function signatures with
their doc comments — what `bindgen` produced from `.widl`. The conformance report is the same walk (the inventory of
declared functions, their arguments and whether they raise). This is the only generator-like step left, and it reads
the Odin declarations, not a second language.

## Migration plan, domain by domain

1. **Shared declarations.** For each `api/<domain>.widl`, write `api_decl/<domain>.odin`: handles, enums, dictionaries,
   procedure signatures. (This replaces the `.widl` as the source of truth; `bindgen` can emit it once as a starting
   point, then `.widl` is dropped.)
2. **Host.** Move the hand-written implementation (today in `src/page/bindings_<domain>.odin`) to take the declaration's
   arguments; bind each with `abi_host.bind` (scalar or serialised) in the domain's registry. The implementations keep
   using `package page` (its object pool, settings, lookups) — the standalone `abi_url` here is only to keep the
   prototype off the main build.
3. **Guest.** The guest bindings become the `abi_guest` stubs (or, for the C engine during the transition, the C glue
   over `host_call`).
4. **Choose the path per function.** Scalar for the hot 0..N simple-parameter functions (the budget check in
   `perf.ps1` tells which); serialised for the rest.
5. **Docs/conformance** come from `apidoc` on the new declarations; delete the `.widl` and the matching `bindgen`
   emitters once a domain is across.
6. Repeat; `bindgen` shrinks to nothing but the one-shot `.widl → api_decl` helper, then goes away with the last
   domain.

## Out of scope for the compile-time bridge (and how to express it)

- **Dictionaries with strings** (`URLPatternInit`): the generic marshaller stays pure (scalars, strings, handles,
  `Maybe`); a dictionary is carried by the **manual escape hatch** (`abi_host.bind_manual`), a small hand-written codec
  that reads the fields with the same wire helpers. Dictionaries are constructor/option-bag arguments, off the hot
  path, so this costs nothing in practice. A future improvement is a comptime struct-field walk, but it is not needed.
- **WebIDL overloads** (`foo(DOMString)` and `foo(long)` as one name): Web IDL only; resolved in the engine's JS glue by
  dispatching to two differently-named ABI functions, as today.
- **Unions** (`(DOMString or Blob)`): expressed as a tag `enum` plus the per-variant arguments, or a manual op.
- **`[Exposed]` / realms** (`Window` vs `Worker`): a bit on the binding, as today (`realms` on `wasm.Import`); set when
  binding, filtered by the worker import filter.
- **Mixins / inheritance**: a Web IDL authoring convenience; the declarations are already flat (one function per line),
  so there is nothing to express.
- **Callbacks** (an event listener handed to the host): a table index + a `user` word, unchanged; `call_guest` runs
  them. Not part of the argument marshalling.

## Files

```
native/js/odin_abi/
  abi/            abi.odin wire.odin marshal.odin invoke.odin   -- the wire format + the comptime marshallers
  abi_host/       host.odin dispatch.odin scalar.odin           -- the host bridge (bind/install, host_call, scalar)
  abi_guest/      guest.odin host_call.odin guest_url.odin      -- the guest transport + the URL bindings
  api_decl/       url.odin                                      -- the shared declarations
  abi_url/        host.odin impl.odin                           -- the URL domain implementation (real wb:url)
  bench_guest/    main.odin scalar.odin cm_scalar.odin          -- the wasm32 benchmark guest
  bench/          main.odin scalar_baseline.odin                -- the Wasmtime benchmark runner
  check/          main.odin                                     -- the in-process round-trip check
  apidoc/         main.odin                                     -- docs/conformance from api_decl (core:odin/parser)
```
