# bindgen: Odin output and Odin input

`src/tools/bindgen` generates every copy of the web API from one description. Historically the description was written
in `.widl` (a small dialect of Web IDL, see `docs/api/README.md`) and the low-level glue the JavaScript engine links
against was generated in **C** (`native/js/gen/*`). Two changes move the whole chain to Odin, so no C is written by us:

1. `-emit:odin` generates the engine glue in **Odin** instead of C.
2. The description itself can be written in **Odin** (`-convert-widl` migrates the existing `.widl`), read with a
   dedicated Odin reader.

Both are off by default: `bindgen` with no flag, and `build.bat`, still emit C from `.widl`. Nothing in the current
build changes until the engine is Odin (agent `spk`'s `wj` layer).

## `-emit:odin` : the engine glue in Odin

`bindgen -emit:odin` writes, instead of `native/js/gen/*`:

| file | what | C counterpart |
|---|---|---|
| `native/js/odin/wr_imports.odin` | the browser's imports for an Odin guest: `wr_*` handle / enum / flags / struct / callback types and one `foreign` block per module with the raw ABI (`@(link_name=...)`, the Wasm import module on `foreign import`) | `native/js/gen/wren_api.h` |
| `native/js/odin/js_interfaces_table.odin` | the realm's interface table: `IFACE_*` index constants, the member tables (`[]wj.Member`), and the interface table (`[]wj.Interface`) with names, kinds, flags, constants, `[Exposed]`, inheritance ranges and the legacy platform-object class | `native/js/gen/bindings.c` + `bindings.h` |

The generated Odin is written against **`native/js/odin/wj_iface.odin`**: the Odin counterpart of the interface-table
part of `native/js/engine/wj.h` (the types `Interface`, `Member`, the `Expose` / `Member_Flag` / `Interface_Flag`
bit-sets, the `Native` / `Getter` / `Setter` glue signatures, and the conversion / wrap / throw surface the trampolines
call). No macros: tagged enums, `bit_set`, and plain slice literals.

`wj_iface.odin` is **stubs** today: every procedure panics or returns a sentinel. It defines exactly what the generated
code and the hand-written members expect, so `spk` can implement it (or re-point the generated `import` at `spk`'s
package) without touching a line of the generated output. The member *glue bodies* (the per-member trampolines that
marshal strings, bytes, handles, `raises` → status, `[Owned]`) are **not** generated in Odin yet: they are the part most
tightly coupled to the engine's value type and conversions. The table's `fn` / `get` / `set` slots are left `nil` with
the member recorded in `docs/js/coverage.md`; generating them is the follow-up once `wj_iface.odin` is backed for real.

Verify: `build\bindgen.exe -emit:odin` then `odin check native/js/odin -vet -no-entry-point`.

## The Odin description form

`bindgen -convert-widl` writes one `.odin` next to each `api/*.widl` (see the convention in
`src/tools/bindgen/idl/convert.odin` and the reader `src/tools/bindgen/idl/odin_in.odin`). A module is one file:

```odin
//@wb module name=url order=58 exposed=(Window,Worker)
/// URL and URLSearchParams ...
package api_url

//@wb handle parent=Object host=Url_Object lookup=lookup_URL
/// A parsed absolute URL.
URL :: distinct Handle

/// A component of a URL.
URLComponent :: enum i32 { Href, Protocol, /* ... */ Origin }

//@wb flags base=u32
Opts :: enum u32 { X, Y }                      // bit numbers in order, like .widl flags

S :: struct { a: i32, kind: URLComponent, on: bool }

//@wb callback
Done :: #type proc "contextless" (user: i32, thing: Thing)

//@wb fn raises optional=base
/// new URL(input, base) ...
URL_parse :: proc(input: string, base: string = "") -> URL
```

Odin's own syntax carries the shape (distinct handle types, `enum`, `struct`, `#type proc`, `proc`). A `//@wb`
directive comment carries what Odin cannot say: the module's `[Exposed]` and declaration `order`; a handle's parent,
host type and lookup; a function's `raises` / `[Owned]` (`owned`) / `[Effects]` (`effects`) / `[Exposed]` / `[On]` /
`[Host]`, and which parameters are `optional` or `out` (named, so the proc stays a plain parameter list). `///` doc
comments are kept verbatim.

A module split across several `.widl` files (e.g. `dom`, declared in `dom.widl` and extended by ~18 `partial module dom`
blocks) converts to several files; the directive's `name=` merges them back, and `order=` restores the original
declaration order so every generated output is byte-identical.

### Why a hand-written reader, not `core:odin/parser`

`core:odin/ast` is syntactic (no resolved types — the brief's point) and drops the `///` / `//@wb` comments unless they
are collected and re-attached by position. The reader (`odin_in.odin`) is a small tokenizer modelled on the `.widl`
parser (`parse.odin`): it keeps the docs and directives exact and makes the round-trip deterministic. It fills the same
`Api` / `Module` / `Decl` the `.widl` parser does, so every downstream emitter (host, SDK, docs, conformance, imports)
is untouched.

### Guardrails (read time, with file and line)

`odin_in.odin` rejects, by name and position:

* a parameter or field named like an **Odin keyword** (`context`, `map`, `proc`, `in`, ...): the generated glue would
  not compile;
* an `out` parameter that is not `bytes` (an out parameter is a host-filled buffer);
* an enum / flags **base** that is not `i32` / `u32` (it would truncate in the ABI).

The shared `check` still enforces the `.widl`-era rules (reserved host locals `c` / `a` / `f` / `_…`, unknown types,
duplicate imports, ...).

## Verifying the migration is lossless

`bindgen -convert-widl` then `bindgen -verify-roundtrip` loads both `api/*.widl` and the converted `api/*.odin`,
generates the host trampolines, every guest SDK module, the docs, the conformance tests and the Odin imports from each,
and reports the first byte that differs. It prints `identical (host, guests, docs, conformance, imports)` when the Odin
form reproduces the exact output (the docs' `Source:` line, which names the file, is normalized away — the migration
renames the source, not the API).

## What `spk` must provide

`native/js/odin/wj_iface.odin` is the contract. `spk` backs it with the engine-agnostic Odin layer (the `wj.h`
equivalent): the real `Ctx` / `Val`, the `to_*` conversions, `wrap_node` / `wrap_host` / `wrap_owned`, the `throw_*`
helpers, the scratch buffer, and it publishes `interfaces` / `interface_count` (the generated `@(init)` already assigns
them). The member-glue body generator (the Odin equivalent of `jsgen`'s `emit_import_glue`) comes once that surface is
real.
