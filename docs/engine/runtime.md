# The ECMAScript runtime (`src/engine/jsrt`)

The runtime is the "second half" of Wren's Odin JavaScript engine: it executes QuickJS‑ng 0.17
bytecode. It is written natively in Odin, builds for `windows_amd64`, `linux_amd64` and
`freestanding_wasm32` with an injected allocator and no OS dependency, and runs inside Wren's Wasm
sandbox exactly as QuickJS‑in‑Wasm does (the sandbox is kept on purpose: it protects the host from
memory bugs of the engine).

The two halves of the engine meet at the **QuickJS‑ng 0.17 bytecode**: the Odin front‑end
([frontend.md](frontend.md)) and the reference QuickJS C compiler emit the same serialized form, and
this runtime reads and runs it. `compile_frontend.odin` calls the front‑end in process (a scratch
arena per compile), so `eval`, `Function(...)`, modules and `$262.evalScript` need no other compiler.

This is **not** a mechanical port of QuickJS. Where the C uses `#define` tags, manual refcounting
and hand‑rolled dispatch, the Odin version uses tagged unions with exhaustive `switch`, `defer`,
arenas where they help, comptime‑generated opcode/atom tables, and layouts friendly to `#soa`.
Divergences are deliberate and listed at the end.

## Conformance (test262)

`tools/jsrt_test262.ps1` builds the judge (`src/engine/jsrt/judge`) and runs the suite pinned by
`tools/test262.ps1` in worker processes (a crash or hang costs one test), with the rules of QuickJS‑ng's
`test262.conf`. The harness files and the `includes` / `flags` of each test's front matter are honoured
(`onlyStrict`, `raw`, `async`, `module`, `CanBlockIsFalse`); `$262` provides `createRealm`, `evalScript`,
`detachArrayBuffer`, `gc`, `IsHTMLDDA` and real `agent`s (threads with their own runtime, sharing
`SharedArrayBuffer` memory; `Atomics.wait`/`notify` go through a process‑wide waiter list).

| directory | passed | total | % | % of QuickJS‑ng |
|---|---:|---:|---:|---:|
| **all** | **43 233** | **43 267** | **99.92** | **100.00** |
| annexB | 1 053 | 1 060 | 99.3 | 100.0 |
| built-ins | 18 928 | 18 934 | 100.0 | 100.0 |
| harness | 116 | 116 | 100.0 | 100.0 |
| language | 23 136 | 23 157 | 99.9 | 100.0 |

Skipped by configuration: 5 453 (features QuickJS‑ng does not enable). The 34 failures are the tests
QuickJS‑ng itself fails: evaluation order of destructuring targets (7), `callexpression` as an assignment
target (7, Annex B), `AsyncFromSyncIterator` close on poisoned wrappers (6), ambiguous `export *` namespaces
(4), top‑level‑await ordering (2), `using` in imported modules (3), field named `get`/`set` followed by a
generator (2), `with` over a proxy environment (2), and a few single cases. The full list is in
`build/test262/jsrt_errors.txt`; every directory is at 100 % of what QuickJS‑ng passes.

## Value model (`value.odin`)

A `Value` is a 16‑byte tagged union: an 8‑bit `Tag` plus an 8‑byte payload (`int32`, `float64`, bool or
a pointer to a GC cell). A tagged union rather than NaN‑boxing, on purpose:

- It is identical on 64‑bit native and on wasm32; every `switch v.tag` is checked for exhaustiveness
  by the compiler.
- Small integers stay unboxed (`int32`, as QuickJS); `-0`, non‑integral and out‑of‑range numbers use
  the `float64` lane.

Heap values (string, symbol, object, bigint, raw function bytecode, module) hold a `^Cell`. The
representation is isolated behind constructors/accessors. The C API layer (below) encodes a `Value`
in the 64‑bit NaN‑boxed word QuickJS uses on wasm32, because Wren's glue is written against that.

## Strings, atoms, shapes, objects

- **Strings** (`string.odin`): UTF‑16 code units stored compactly — Latin‑1 (one byte per unit) or
  UTF‑16 — with **ropes** for concatenation (`a + b + c…` in a loop is linear; flattened on first
  index/hash/compare). Source text handed to the compiler keeps lone surrogates (WTF‑8), and
  `Function.prototype.toString` returns the real source text (the front‑end keeps each function's text
  with `Compile_Options.keep_source`; `Host_Config.strip_source` drops it).
- **Atoms** (`atom.odin`, `atoms_table.odin`): 32‑bit interned property keys; array indices set bit 31
  and never allocate. The predefined atoms are generated from `quickjs-atom.h`, so serialized bytecode
  refers to the same indices. Atoms are never collected.
- **Shapes** (`shape.odin`/`object.odin`): hidden classes with transitions and an open‑addressed hash;
  an object stores a flat `[]Prop_Slot`; deleting a property or growing past 48 properties switches the
  object to a private dictionary shape.
- **Objects**: a GC cell with a shape, inline slots, and an `Object_Data` tagged union for the internal
  slots of exotic kinds (Array, Function, Native, Bound, wrappers, ArrayBuffer/TypedArray/DataView,
  Map/Set, Proxy, Date, RegExp, Promise, Generator, Module namespace, Host…). Arrays keep a dense
  `[]Value` fast path.

## Memory management (`gc.odin`)

A **precise, non‑moving, stop‑the‑world mark‑and‑sweep** collector (`rt.cells` is every live cell).
Copying a `Value` is a plain copy: there are no `dup`/`free` pairs in the interpreter and cycles need no
special pass.

- **Roots**: realms, the interpreter frame chain (arguments, locals, whole operand stacks, open closure
  cells), the job queue, the pending exception, atoms, the module registry, `temp_roots`, and the
  **host roots** (below).
- **Safe points** (function entry, loop back edge, entry of a native call) are the only places a
  collection starts; allocation never collects. Native code (builtins) keeps `Value`s in Odin locals the
  collector cannot see; `cell_new` and `get`/`call` push what they return on `temp_roots`, which a native
  call truncates when it returns. Builtins that read straight out of internal storage and then call back
  into JS root explicitly (`root`).
- **Weak references** (WeakMap/WeakSet keys, WeakRef, FinalizationRegistry) are ephemerons processed to a
  fixpoint after the strong marking; shape transition caches are weak too.
- **Host roots**: each `Cell` has a 32‑bit `ext` count. `persist`/`ext_ref` bump it (O(1), no table),
  `unpersist`/`ext_unref` drop it; cells with a non‑zero count are listed in `rt.ext_cells` and are roots.
- **Host classes** (`host_class.odin`): objects of a class the host registers carry an opaque pointer, a
  finalizer, and optionally the references the opaque data holds (`gc_mark`) and exotic hooks for
  properties the object does not store. Finalizers of dead host objects run before any cell of the
  collection is freed. `gc_mark` is used twice: to **subtract** those references from the host counts (a
  cycle through opaque data does not keep itself alive — QuickJS's trial deletion, restricted to the cells
  with host references) and to trace them when the owner is live.
- Small blocks (≤ 512 bytes: cells, inline slots, small arrays and string data) come from size‑class free
  lists carved out of 256 KiB chunks of the injected allocator (`mem_alloc` / `mem_free` / `mem_resize` in
  `gc.odin`; callers always pass the size they allocated with). A cell costs a pop and a push, not a host
  allocation.
- The heap is capped by `Host_Config.malloc_limit`; all allocation goes through the injected allocator.
  A collection runs when the heap passes `max(2 × live, live + 4 MiB)`.

### Where the memory of a realm and of a page goes (Wasm, `jsengine mem|startup`)

The linear memory of a Wasm module only grows, so what counts is the high-water mark.

- **Lazy members.** A Web IDL prototype (`native/js/odin/wj/qjs_platform.odin`, `wj_platform_preinit`) is marked lazy
  with `JS_SetLazyMembers`: its shape is private and flagged, and `shape_find`, the enumerations of a shape
  (`own_property_keys`, `plain_keys_object`) and `add_property` call `shape_realize` first, which runs the glue's callback
  (`lazy_proto_members`): it defines the members the eager code defined, with the same keys, order, descriptors, names and
  lengths, minus what the realm's scope hides and the touch handlers `browser.touch.expose` turned off, plus the
  unimplemented-throw members after the implemented ones. A realm creates the thousands of function objects of the
  interfaces a script looks at, not all of them. A prototype that pre-initialization touches after the members
  (iterator interfaces) is realized in the image. The interface objects, namespaces and the global object stay eager.
  Empty realm: 6 592 → 4 352 KiB of linear memory, 6 973 → 4 723 KiB private per realm, 2.3 → 1.3 ms to create.
- **Native functions.** A function object has exactly the two slots (`length`, `name`) it is born with; a C function of
  the glue without user data keeps its pointer in `Native_Data.data` (low bit set, `native_data_is_raw`) and its
  prototype in which `bridge_*` procedure it calls (no block of values); its `name` is the string of the property key's
  atom when there is one (`str_interned`).
- **The compiler** (`compile_alloc.odin`): the front-end's allocator takes blocks up to 2 KiB from the arena, recycles
  them by size class (a larger free block is cut for a smaller request), and takes larger ones from the host heap, one by
  one, so that a table that dies is given back at once. `js_create_function` frees a function's tables
  (`free_func_def`) as soon as its bytecode exists, the passes free their buffers, and the serialized stream is built in
  one buffer (`serialize.odin`). The 650 KiB bundle of `examples/jsbench/page_gen.js` asked the arena for 14.6 MB, now 6.5.

## Serialized‑bytecode reader and verifier (`serialize.odin`)

Parses `JS_WriteObject(..., JS_WRITE_OBJ_BYTECODE)` for `BC_VERSION 28`: header, atom table (both atom
encodings of the format), function bytecode (flags, vardefs, closure vars, cpool, bytecode, debug info,
source), BigInt, arrays, objects, modules. After the instruction stream is read, its atom operands are
rewritten in place and a **stack‑height verifier** checks the code. The interpreter trusts the *types* of
operands (as QuickJS does: bytecode comes from the compiler); the reader and verifier guarantee shape and
stack discipline, not type correctness.

## Interpreter (`interp.odin`, `ops.odin`, `coro.odin`)

A `switch`‑dispatch loop over the QuickJS instruction set. The common instructions (locals, arguments,
integer / float arithmetic, comparisons, branches, `get_field` / `put_field` with the prototype walk, array
reads and writes, global variables through a per‑realm slot cache, **calls and returns**) run in
`interp_hot.odin`, a loop with raw pointers whose few live values stay in registers; everything else, and
every fast path that does not apply, leaves it with the pc on the instruction for the full dispatch in
`interp.odin`. The hot loop is inlined into `interp_run` (measured: a separate procedure is 20‑25 % slower).
Frames come from segmented value stacks so generators and async functions can suspend them (`coro.odin`:
generators, async functions, async generators, `for await`, `yield*`). A plain JS‑to‑JS call does not
recurse natively: `frame_push` puts the callee's `Frame` at the end of its value‑stack block and the same
`interp_run` activation runs it (`Frame.stackless`); native callees (`c_function`) are called from the hot
loop without a frame. The engine's own stack budget and call depth bound recursion
(`Host_Config.max_stack_bytes`, `max_stack_depth`; a `RangeError` instead of a crash). The interrupt hook
runs on a budget from the loop back edge. Operators follow the spec (`+` through ToPrimitive, ModRing bitwise, BigInt paths, loose and
strict equality). Try/catch uses a per‑frame handler stack (`catch`/`gosub`/`ret`/`nip_catch`).

## Standard library

Everything QuickJS‑ng 0.17 ships, in `b_*.odin`: Object, Function, Array, String (with Unicode case
mapping and normalization from `src/engine/unicode`), Number/Math/BigInt (`numconv`, `bigint`), Symbol,
JSON (with source text access), RegExp, Date (`datetime`), Map/Set/WeakMap/WeakSet/WeakRef/
FinalizationRegistry, Promise, generators, Reflect/Proxy, ArrayBuffer (resizable, immutable)/
SharedArrayBuffer (growable)/TypedArray/Float16Array/DataView/Atomics, Iterator helpers and
`Iterator.concat`, `Array.fromAsync`, `DisposableStack`/`AsyncDisposableStack`/`SuppressedError`,
Uint8Array base64/hex, `Error.prototype.stack`. `Intl` stays on the host (Wren's glue).

**Regular expressions.** Literals reach the runtime already compiled by the front‑end to the **bytecode of
QuickJS's libregexp**; `lre_exec.odin` executes that format (and a verifier checks it before use), so
literals and `new RegExp` share one matcher. Unicode properties, case folding and the properties of strings
(`\p{RGI_Emoji}` …) come from tables generated from the pinned UCD.

## Embedding interface (`embed.odin`, `runtime.odin`)

`engine_new` / `context_new` / `eval_source` / `eval_bytecode` / `call_function` / `run_jobs` /
`retain` / `release` / `heap_stats`, with the hooks in `Host_Config`: `compile`, `load_module`,
`import_meta`, `interrupt`, `rejection`, `gc_prologue`, `compile_strings`, `dynamic_import`,
`atomics_wait`/`atomics_notify`, `can_block`, `malloc_limit`. Values handed to the host live until the
next call into the engine unless retained.

`src/engine/jsrt/wasm` is the freestanding module (`jsrt_init/new/alloc/eval/run_jobs/free`).

## The QuickJS C API on this runtime (`src/engine/jscapi`)

Wren's glue is written against `quickjs.h`. `jscapi` implements that API (167 procedures, `proc "c"`,
exported under their QuickJS names with `-define:JSCAPI_EXPORT=true`) over `jsrt`; see
[jscapi.md](jscapi.md) for the ownership model, the classes and the plan of what is left.

## Measurements (Windows x64, Odin `-o:speed`, Zig 0.15 `-O2` for QuickJS)

| | jsrt | QuickJS‑ng C |
|---|---:|---:|
| `examples/jsbench/micro.js`, geometric mean of 20 cases | 100 % of QuickJS speed (was 68 %) | 100 % |
| `examples/jsbench/macro.js` (JSON, regexp, strings, array methods, Map/Set, classes, generators…), 28 cases | 119 % of QuickJS speed | 100 % |
| best / worst case (micro) | for‑of 233 %, global variables 126 % | switch 62 %, nested int loops 69 % |
| peak working set, 300 k objects + 100 k Map entries (`examples/jsbench/cases/memory.js`) | 188 MiB (was 244) | 135 MiB |
| freestanding wasm32 module, runtime + compiler (`-o:size`) | 1.63 MB (`-o:speed`: 1.99 MB) | `wren_js.wasm` (QuickJS + glue + bindings) 4.26 MB |

`tools/jsrt_ab.ps1` compares several builds (and QuickJS)
interleaved, best of N, on `micro.js` or `macro.js`; `tools/jsrt_prof.ps1` is a sampling profiler (hot
functions and source lines; `JSRT_PROF=1` on `judge eval`); `tools/jsrt_mem.ps1` measures the peak working
set. `JSRT_MEMPROF=1` on `judge eval` prints a census of the heap by kind of cell (count, cell bytes, bytes owned
out of line, slack; `memprof.odin`), `jsengine mem [-image m.wasm] file.js` does the same inside the wasm32 image
(sizes of the cells on wasm32, linear memory of the module, which only grows), and `WREN_JS_MEMPROF=1` makes
`jsdomtest` print it for each page. `examples/jsbench/page_gen.js` generates a 650 KB framework-like bundle for
page-load memory (the compile arena dominates it). Timings on this machine swing by ±30 % from run to run when other builds are running, and a change that
adds no work to the hot loop can still move an unrelated case by ±10 % (code layout), so compare interleaved
and keep the best. Fuzzing: `judge fuzz <dir>` mutates serialized bytecode
and loads it (reader + verifier; 40 000 mutants, no crash; running accepted mutants is opt‑in with
`JSRT_FUZZ_RUN=1`, since a type‑confused image can crash any interpreter that trusts the compiler);
`judge fuzzsrc <dir>` mutates source text, compiles with the Odin front‑end and runs under an interrupt
budget (30 000 mutants on `language/` and `built-ins/`, no crash).

## Intended divergences from QuickJS

- **Tagged union over NaN‑boxing** for values; **precise tracing GC** instead of reference counting plus
  a cycle collector (the C API layer re‑creates the counted‑reference contract for the glue).
- **Exhaustive Odin enums + `switch`** for tags, exotic kinds and opcodes; **comptime‑generated opcode and
  atom tables** from the QuickJS headers.
- **Rope strings with Latin‑1/UTF‑16 compaction** as the default string representation.
- Atoms are permanent; `JS_WriteObject` of data (structured clone format) is not implemented.

## Known gaps

The 34 test262 failures above (all shared with QuickJS‑ng). Speed is at parity with QuickJS on the micro
benchmarks; the slow cases are the ones that pay one dispatch per bytecode (`switch` on integers 62 %,
nested integer loops 69 %: next step is superinstructions or a pre‑decoded code array), native‑to‑JS
callbacks (`sort` comparators, `forEach`: a new `interp_run` activation each, ~1.9× slower than QuickJS) and
destructuring. Memory is 1.4× QuickJS on allocation‑heavy scripts (a plain object costs 168 bytes: `Object`
104 + 4 inline slots; a string header is 80 bytes; both can shrink).
