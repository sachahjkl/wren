# The loop JIT (`src/engine/jsrt/jit.odin`)

A hot loop of a function is translated from its bytecode to a WebAssembly function, which the host compiles with
Cranelift and attaches to the engine's table (`src/js/jit.odin`, `wasm.attach_function`); the interpreter then calls it
like a C function pointer. WebAssembly stays the only execution engine: the code made at run time lives in the engine's
sandbox and reaches only the engine's memory and the helpers the engine exports to it.

## When a loop is compiled

The interpreter's hot loop counts back edges for the interrupt poll; every `INTERRUPT_POLL_EVERY` of them it leaves to
the full dispatch, which offers the back edge to `jit_back_edge`. A loop seen there for the first time is translated
(`jit_build`) and entered at its header (on-stack replacement), with the frame's arguments, locals and operand stack in
memory. While a loop of a function is compiled, the hot loop leaves at that loop's back edges only (`jit_loop_taken`);
the function's other loops stay in it.

A loop that runs few iterations per entry costs more to enter than the code saves: after `JIT_PROBE` entries with fewer
than `JIT_MIN_ITERS` iterations each on average it is left to the interpreter.

## What the code holds

The translation follows the operand stack with a type per entry:

| type | what | Wasm locals |
|---|---|---|
| I | an int32 | i32 |
| F | a double | f64 |
| B | a bool | i32 |
| L | the exact result (at most 2^53) of an int `+ - *` that may have left the int32 range | i64 |
| O | an array or typed array held by a local the loop does not write (its elements through the `Jit_Arr` the interpreter fills at entry) | none |
| P | an object | i32 (its address) |
| V | any value | i32 (tag) and i64 (payload) |
| M | an entry under the loop's own stack (a `try`'s catch offset, an iterator), left in the frame's memory | none |

Locals the loop uses as ints, doubles or objects are read once at entry, guarded by their tags, and written back when the
code leaves; the others stay in the frame's memory (read as V).

## Properties

A named property read or written (`get_field`, `get_field2`, `put_field`, `get_length`, the globals' `get_var` and
`put_var`) is a guard of the object's own shape against the shapes the site was compiled for, then the slot at a
constant index: in the object, or in the prototype that holds it, whose shape (and those of the prototypes before it)
is guarded too. A shape that is not a dictionary never changes, so the guard is a check of data in the object: there is
nothing to invalidate when a prototype or an object changes. A dictionary shape changes in place: a holder's (or an
object's own) is checked by the key, kind and flags at the index. A global is read from the realm's lexical
declarations or from the global object, the declarations' shape guarded (none of them shadows it). A closure's
variable is read and written where its cell points. A string's `length` is read from the string, its other properties
from `String.prototype` (the value's tag checked, then the prototype's shape) once the site has met a string.

What a site was compiled for is per site and bounded (`Jit_Site`: `JIT_SITE_SHAPES` shapes with their objects' class,
the type of the value read): taken from the frame's values when the loop is translated (the translation follows what
each entry held, as far as it can tell, for these hints), and learned when the site misses. A learn exit
(`JIT_AUX_LEARN`) hands the interpreter the state at the instruction; `jit_learn` looks at the object or the value, the
site takes its shape or a wider type, and the loop is translated again (`JIT_MAX_LEARNS` times at most). A miss with
nothing to learn (a shape the site does not take inline: an accessor, an exotic object, a frozen property for a write;
more shapes than the site takes) is a deopt.

The shapes and objects the code compares against are kept alive by the loop (`Jit_Loop.keep` and the sites' shapes,
marked by the collector through `Function_Bytecode.jit`): an address the code holds is never another shape's.

## Calls

- **Inlined**: a call of a small function (`JIT_INLINE_MAX_CODE` bytes of bytecode, no closure cells of its own,
  straight-line code, no effect but on its own locals: it reads properties, globals and elements, computes, calls
  functions that are inlined in their turn, one level down) is translated in place, its arguments and locals stack
  entries. The callee is guarded (the object the call finds is the one it was inlined for); a deopt anywhere in it
  leaves the call itself to the interpreter, with the caller's stack as it was, so nothing it did is done twice. The
  first such exit translates the loop again with the callee's numbers taken for doubles (`inl_wide`), the second
  (`JIT_AUX_NO_INLINE`) leaves the call to the interpreter for good.
- **Math and strings**: `Math.abs`, `floor`, `ceil`, `trunc`, `sqrt`, `min`, `max`, `imul` of numbers are computed
  inline, and `s.charCodeAt(i)` of a flat string and an index within it, the callee guarded (a rope, an index out of
  the string: the interpreter makes the call, and flattens the rope).
- **Natives**: any other call of a native function goes through the helper `wj_jit_call` (`jit_call`): the operand
  stack is stored in the frame first and the objects the loop holds in locals written back (the collector's roots), the
  helper makes the call as the interpreter does, its result comes back as a V. An exception leaves through a throw exit
  and the interpreter unwinds from the call. After the call the arrays the loop holds are taken again (`wj_jit_array`: a
  call may have grown, moved or detached them). Locals a closure may reach (captured ones, the arguments of a function
  with a mapped `arguments`) stay in the frame's memory in a loop that calls.
- A call of bytecode that is not inlined keeps the loop interpreted: through the helper it is a nested `interp_run`,
  slower than the interpreter's own call (measured: 84 -> 130 ns for a small function).

Compiled code may run the same loop again in a nested frame (a call that recurses): the exit of the outer one checks
that the loop is still the code it ran (`jl.index`) before it changes the loop's state.

## Exits

The code returns an exit word (kind, pc, sp, aux) and the interpreter carries on at (pc, sp):

| exit | when |
|---|---|
| leave | a jump out of the region (aux: the iterations this entry ran) |
| ret | a return (the value in the frame's `stack[0]`) |
| guard | an entry guard failed (aux: the slot): the slot is widened or left in memory, translated again |
| deopt | a speculation failed in the loop (int overflow, -0, a bound, a type): aux a slot to widen, `JIT_AUX_LEARN`, `JIT_AUX_NO_INLINE` or none |
| budget | every `JIT_BUDGET` iterations: the interpreter's safe point (interrupts, collection) runs |
| throw | a call made through the helper threw |

## Tests

- `build\jsengine_jit.exe verify -jit -jit-sync examples\jsbench\jitcheck.js`: the script runs interpreted, then with
  the JIT, and what it prints must be the same. Its loops run long enough to be compiled, then are called again with
  other shapes, prototypes, getters, frozen objects, proxies, values of other types, more shapes than a site takes,
  callees replaced, exceptions in natives and in inlined callees, arrays that grow, collections while compiled code
  holds objects. `test_all` runs it (and test262 with the JIT).
- A build of the engine with `WREN_ODIN_FLAGS="-define:JSRT_GC_STRESS=8192;-define:JSRT_GC_POISON=true"` (buildjs
  `-out` elsewhere) collects every 8 KiB and traps on a value that points at a collected cell: jitcheck under it finds
  what compiled code would leave unrooted.
- `JIT_*` bounds and what was measured: [docs/performance.md](../performance.md), the JIT round.
