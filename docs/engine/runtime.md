# The ECMAScript runtime (`src/engine/jsrt`)

The runtime is the "second half" of Wren's Odin JavaScript engine: it executes QuickJS‑ng 0.17
bytecode. It is written natively in Odin, builds for `windows_amd64`, `linux_amd64` and
`freestanding_wasm32` with an injected allocator and no OS dependency, and is designed to run inside
Wren's Wasm sandbox exactly as the current QuickJS‑in‑Wasm does.

The two halves of the engine meet at the **QuickJS‑ng 0.17 bytecode**: the compiler front‑end (agent
E1) and the reference QuickJS C compiler both emit the same serialized form, and this runtime reads
and runs it. That is why the serialized‑bytecode reader was built first — it lets the runtime be
exercised against real reference output before the Odin compiler exists (compile a script with
`qjsc`/`JS_WriteObject`, load the bytes, run them).

This is **not** a mechanical port of QuickJS. Where the C uses `#define` tags, manual refcount
bookkeeping and hand‑rolled dispatch, the Odin version uses tagged unions with exhaustive `switch`,
`defer`, arenas where they help, comptime‑generated opcode/atom tables, and `#soa`‑friendly layouts.
Divergences are deliberate and listed at the end.

## Value model (`value.odin`)

A `Value` is a 16‑byte tagged union: an 8‑bit `Tag` plus an 8‑byte payload. We chose a tagged union
over NaN‑boxing on purpose:

- It is identical on 64‑bit native and on wasm32. Under wasm32 pointers are 32‑bit, so a NaN‑boxed
  64‑bit word would need a side table or a shifted‑pointer scheme; the tagged union just works.
- The discriminant is an exhaustive Odin enum, so every `switch v.tag` is compiler‑checked — a
  correctness win QuickJS's integer tags do not get.
- 16 bytes still fits two values per cache line and keeps the hot path branch‑predictable.

Small integers stay unboxed in an `int32` lane (as QuickJS does); `-0`, non‑integral and
out‑of‑range numbers use the `float64` lane. Heap values (string, symbol, object, bigint, and the
raw function‑bytecode cell) hold a `^GC_Header`. The representation is isolated behind the
constructors/accessors, so switching to NaN‑boxing later (if measurement justifies it) is local.

## Strings (`string.odin`)

Strings are sequences of UTF‑16 code units stored compactly: a flat string is either **Latin‑1**
(one byte per unit, used whenever every unit is < 256) or **UTF‑16**. Concatenation builds a **rope**
(a `left ++ right` node) so `a + b + c …` in a loop is linear, not quadratic; a rope is flattened
lazily the first time it is indexed, hashed, compared or handed to code needing contiguous storage.
Strings are reference‑counted and never cyclic.

## Atoms (`atom.odin`, `atoms_table.odin`)

An atom is a 32‑bit interned property key, so lookups compare keys with a single integer compare.
Two encodings share the space exactly as QuickJS does: array‑index keys set bit 31 and never
allocate a string; everything else indexes `rt.atom_array`. The predefined atoms (seeded at startup)
and their order are generated from `quickjs-atom.h` so serialized bytecode references them by the
same indices.

## Shapes / hidden classes (`shape.odin`)

Objects that share the same properties in the same order share one `Shape`. A property access
resolves `atom -> slot` through the shape's open‑addressed hash, and the object stores only a flat
`[]Value` at those slots. Adding a property follows or creates a **transition** to a child shape, so
objects that grow the same way share shapes; deleting a property or heavy mutation drops the object
into a private "dictionary" shape. Shapes are the foundation for inline caches (planned): "if the
object's shape is S, the property is at slot N".

## Objects (`object.odin`)

An `Object` is a GC cell with a shape, a flat property store and an `exotic` tagged union carrying
the internal slots of exotic kinds — Array, Function, Native function, Bound function, the primitive
wrappers, ArrayBuffer/TypedArray/DataView, Map/Set, Proxy, Date, RegExp, Error, Iterator, Promise,
Generator and module Namespace — without a second allocation. Arrays keep a dense `[]Value` fast path
with a separate length; `length` and index access are synthesised in `exotic_get_own`/`exotic_set_own`
(`exotic.odin`), so pushing numbers never grows the shape.

## Memory management (`gc.odin`)

Reference counting plus a QuickJS‑style **cycle collector**. Acyclic cells (strings, symbols,
bigints) are freed the instant their count hits zero. Cells that can form cycles (objects, function
bytecode, closure upvalues, and shapes — a shape references its prototype object) are additionally
threaded on an intrusive list. `gc_run` is a two‑phase mark‑and‑sweep restricted to that list:

1. **Decrement:** copy each cell's refcount into `gc_ref`, then subtract the references held by other
   cells on the list. A cell whose `gc_ref` stays > 0 is rooted from outside the cyclic set.
2. **Mark & sweep:** mark everything reachable from a root black; the rest is garbage.

The sweep frees in **two passes** — first drop every garbage cell's outgoing edges (pinning each
garbage cell with a temporary reference so an unref triggered while clearing edges can never free a
sibling out from under the second pass), then free the now edge‑less structs. This is what makes
tearing down a whole cyclic set (e.g. the `constructor ↔ prototype` and `globalThis → global` cycles)
safe and leak‑free; the runtime verifies zero leaked allocations at teardown with the project's
tracking allocator.

The heap is capped by a byte budget the host sets (`Host_Config.malloc_limit`); all allocation goes
through the injected allocator so the sandbox and native tests share one path, and the accounting
(`malloc_size`/`malloc_count`) feeds both the limit and leak checks.

## Serialized‑bytecode reader (`serialize.odin`)

Parses the output of `JS_WriteObject(..., JS_WRITE_OBJ_BYTECODE)` for `BC_VERSION 28`:

- Header: `u8` version (== 28), `u32` checksum (not verified; the writer may store `UINT32_MAX`),
  `leb128` atom count, then the atom table (predefined/const atoms inline, others as a type byte + a
  `JS_WriteString`).
- Body: one tagged value. Implemented tags: the primitives, string, BigInt (two's‑complement LE byte
  string), array, plain object, template object and **function bytecode**.

The two atom encodings are both honoured: `bc_get_atom` (func name, var/closure names, filename)
reads a `leb128` whose low bit flags a tagged int and whose high bits are an index; the **bytecode
stream** stores a raw `u32` atom index. Both resolve through `bc_idx_to_atom` semantics (index <
`first_atom` ⇒ predefined atom; else the per‑read decoded table). After the instruction stream is
read, its `atom`‑format operands are rewritten in place from stream indices to runtime atoms, using
the generated opcode table (`opcodes.odin`) to step instructions.

## Interpreter (`interp.odin`, `ops.odin`, `runtime_ops.odin`)

A `switch`‑dispatch loop over the QuickJS instruction set. Odin compiles a dense‑enum switch to a jump
table, so this is already close to computed‑goto dispatch; whether a hand‑rolled table with
`#no_bounds_check` or a block‑based loop beats it is a measurement left for later, and the decode is
isolated so that change stays local. Frames (`frame.odin`) are heap‑allocated so generators/async can
suspend them and so the engine's own stack‑depth budget — not the host C stack — bounds recursion.
The interrupt hook and an adaptive cycle‑collection trigger run on a budget from the loop back‑edge.

Operators (`ops.odin`) follow the spec: `+` is string‑or‑number via ToPrimitive, the other arithmetic
is ToNumber‑based (with BigInt paths), bitwise operators use the ModRing coercions, and the relational
and (loose/strict) equality algorithms match the spec. Try/catch is implemented with a per‑frame
handler stack driven by the `catch`/`gosub`/`ret`/`nip_catch` opcodes.

## Embedding interface (`embed.odin`)

The surface Wren's Odin glue (`native/js/odin/wj`) binds to, mirroring `JS_NewRuntime`/
`JS_NewContext`/`JS_Eval`/`JS_NewCFunction2`/`JS_NewClass` but with Odin types and no macros:

- `engine_new` / `engine_free`, `context_new` / `context_free`.
- `eval_bytecode(ctx, bytes)` — load serialized bytecode and run it; `eval_function` to run an
  already‑loaded top‑level function.
- Value construction (`new_int/number/bool/string/object/array/function`), property access
  (`get_property`/`set_property`/`set_global`), read‑back (`to_host_bool/f64/string`), reference
  management (`retain`/`release`), calling scripts (`call`), the microtask queue (`run_jobs`), the
  pending exception (`pending_exception`), and heap stats / `collect` for the host's memory
  accounting.

Native functions are plain `Native_Proc` values stored as an object's `Native_Data` exotic, so host
builtins and the standard library share one call path (`call.odin`).

## Standard library (`builtins.odin`, `realm.odin`)

Installed in waves, each to be verified by test262. Wave 1 (landed): the realm's intrinsic prototype
chain and global object; `Object` basics (`hasOwnProperty`, `toString`, `valueOf`, `keys`,
`getPrototypeOf`, `defineProperty`), `Function.prototype` (`call`, `apply`, `toString`), `Array`
essentials (`push`, `join`, `isArray`, the constructor), the global value properties (`undefined`,
`NaN`, `Infinity`, `globalThis`), and the native `Error` hierarchy. Later waves add String, Number/
Math/BigInt, RegExp (on `src/engine/regexp`), Date (on `src/engine/jsdate`), JSON, Map/Set,
Promise + jobs, generators/async, Reflect/Proxy, and ArrayBuffer/TypedArray/DataView/Atomics. `Intl`
stays on the host (Wren glue).

## Intended divergences from QuickJS

- **Tagged union over NaN‑boxing** for values (portability to wasm32, compiler‑checked switches).
- **Exhaustive Odin enums + `switch`** for tags, exotic kinds and opcodes, instead of `#define`s.
- **Comptime‑generated opcode and atom tables** from the QuickJS headers, so the two stay in lockstep
  with no hand transcription.
- **Two‑pass cycle sweep with pinning** for provably safe teardown of cyclic sets.
- **Rope strings with Latin‑1/UTF‑16 compaction** as the default string representation.

## Status and known gaps

Working end‑to‑end today: load real QuickJS bytecode, run top‑level scripts with variables,
arithmetic/bitwise/comparison/equality, global and local access, closures, property and array access,
function calls, and the wave‑1 builtins; refcounting + cycle collection are leak‑free at teardown
(verified with the tracking allocator). Not yet implemented: generators/async/modules (stubs raise a
clear error), the full Proxy trap set, many opcodes (iterators/`for‑of`, `with`, private fields,
class definition, spread/apply, super), and most of the standard library beyond wave 1. The try/catch
handler stack catches thrown values but its interaction with the `new`/constructor opcodes has a
known stack‑discipline bug to finish.
