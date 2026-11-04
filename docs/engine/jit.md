# The JIT (`src/engine/jsrt/jit.odin`)

A hot loop of a function, or a hot function without loops of its own, is translated from its bytecode to a WebAssembly
function, which the host compiles with Cranelift and attaches to the engine's table (`src/js/jit.odin`,
`wasm.attach_function`); the interpreter then calls it like a C function pointer. WebAssembly stays the only execution
engine: the code made at run time lives in the engine's sandbox and reaches only the engine's memory, its table and the
helpers the engine exports to it.

## When a loop is compiled

The interpreter's hot loop counts back edges for the interrupt poll; every `INTERRUPT_POLL_EVERY` of them it leaves to
the full dispatch, which offers the back edge to `jit_back_edge`. A loop seen there for the first time is translated
(`jit_build`) and entered at its header (on-stack replacement), with the frame's arguments, locals and operand stack in
memory. While a loop of a function is compiled, the hot loop leaves at that loop's back edges only (`jit_loop_taken`);
the function's other loops stay in it.

A loop that runs few iterations per entry costs more to enter than the code saves: after `JIT_PROBE` entries with fewer
than `JIT_MIN_ITERS` iterations each on average it is left to the interpreter.

## When a function is compiled whole

A call of a plain function counts toward `javascript.jit.call_threshold` (`Function_Bytecode.jit_calls`, counted where
the interpreter pushes the callee's frame: `jit_pushed`, `jit_entered`, and in the helper of compiled code). Once it is
reached, a function whose backward jumps (if any) go to its start is translated as the region `[0, end)` and entered
at its call (`jit_fn_enter`): its arguments' types guarded at entry, its locals in the frame's memory. A function with
loops of its own is left to the loop JIT; a function that is refused counts no more (`JIT_CALLS_NEVER`).

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
object's own) is checked by the key, kind and flags at the index; one the read walks past (a Web IDL prototype, made a
dictionary for its lazy members) by its version (`Shape.version`, bumped by every change in place: a key added or
removed, an attribute, the prototype), so that a key added to it later, which would shadow what was found further, is
seen. A global is read from the realm's lexical
declarations or from the global object, the declarations' shape guarded (none of them shadows it). A closure's
variable is read and written where its cell points. A string's `length` is read from the string, its other properties
from `String.prototype` (the value's tag checked, then the prototype's shape) once the site has met a string.

A read whose site's first shape finds an accessor reads through getters (`j_call_getter`): the shapes guarded as for a
data property, the getter read from its `Getset` and checked to be a native function called as a function (as the hot
loop's `hot_native_getter`: a DOM attribute's, Map's `size`), else the interpreter reads it; the helper `wj_jit_get`
(`jit_getter`) calls it, the operand stack and the objects held written to the frame first, the held arrays taken
again after. An exception is exact: the helper puts the context's thrower in the object's place (`Context.jit_thrower`,
an object whose property of that name is an accessor with `jit_rethrow` as its getter), the code leaves through a throw
exit, and the interpreter makes the read again, which throws the exception pending. Host objects without exotic hooks
are ordinary objects there (`Object.host_exotic` checked where the code reads past one), so a DOM node's attributes and
methods are read through its prototypes. A global's accessor (`window.document`) is not called: a read of a global has
no object on the stack to put the thrower in, and an exception would have no exact way back into the interpreter but a
throw exit in its back edges (round 20: 4 % of nodes10k with the JIT off).

What a site was compiled for is per site and bounded (`Jit_Site`: `JIT_SITE_SHAPES` shapes with their objects' class,
the type of the value read): taken from the frame's values when the loop is translated (the translation follows what
each entry held, as far as it can tell, for these hints), and learned when the site misses. A learn exit
(`JIT_AUX_LEARN`) hands the interpreter the state at the instruction; `jit_learn` looks at the object or the value, the
site takes its shape or a wider type, and the loop is translated again (`JIT_MAX_LEARNS` times at most). A miss with
nothing to learn (a shape the site does not take inline: an accessor, an exotic object, a frozen property for a write;
more shapes than the site takes) is a deopt.

A write of a property the object does not have appends it as `[[Set]]` does, when the site's shape is an ordinary
object's that is not a dictionary and the property is nowhere on its prototype chain: the shape's transition (made at
translation if it was not, `shape_transition`) is taken, the prototypes' shapes guarded, the object checked to be
ordinary and extensible, its slots grown by a helper (`wj_jit_reserve`) when they are full. The translation follows the
shapes the object it sees takes (`Jc.shadows`: a constructor's `this.x = x; this.y = y` is compiled for the shape after
`x` at the second write).

The shapes and objects the code compares against are kept alive by the loop (`Jit_Loop.keep` and the sites' shapes,
marked by the collector through `Function_Bytecode.jit`): an address the code holds is never another shape's.

## Objects made by compiled code

Compiled code makes objects through the helper `wj_jit_new` (`jit_new`): a plain object (`object`, the start of an
object literal), an Array of entries (`array_from`, an array literal), the object a construction makes
(`create_from_ctor`). The allocator and the collector's contract are the engine's own: allocation never collects, a
collection runs only at a safe point, and the compiled code reaches one only through a call (whose helper writes the
operand stack and the objects held in locals to the frame first) or an exit; the helper drops the temporary roots of
the allocation (`temp_roots` back to the frame's height), the object being in the code's hands until then. An object
literal's fields (`define_field`) need no guard: the translation knows the shape of the object it made until the next
join (`Jit_State.k`), and appends each field through the transition, its slots grown when full.

A construction `new F(...)` of a constructor that can be compiled whole (not a derived class's) is a direct call
(below): the object made by the helper is the callee's `this`, new.target the constructor, the result the callee's
when it returns an object, else the object.

## Strings

A `+` whose site met a string adds values through the helper `wj_jit_add` (`jit_add`): the two entries written to the
frame, `op_add` makes the string (a rope or an append buffer, as the engine builds them), the result a V; `s += x` of
a local the loop leaves in memory is added there (`add_loc`). The helper makes only what cannot run code or throw (no
object, symbol or BigInt operand, a result that fits a string); otherwise it does nothing and the interpreter makes the
instruction (a deopt), so a conversion's effects happen once. `===` and `!==` of two strings compare the pointers,
then the contents through `wj_jit_streq` (`str_eq`); a string against another type is false by the tags.

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
  helper makes the call as the hot loop does (`call_native` for a native function, `call_internal` for the other
  kinds), its result comes back as a V. An exception leaves through a throw exit:
  the helper put `jit_rethrow` in the callee's place, the interpreter makes the call again, which throws the exception
  pending, and unwinds from there. After the call the arrays the loop holds are taken again (`wj_jit_array`: a
  call may have grown, moved or detached them). Locals a closure may reach (captured ones, the arguments of a function
  with a mapped `arguments`) stay in the frame's memory in a loop that calls.
- **Compiled functions, directly** (`j_direct_call`): a call of a function that can be compiled whole, with no closure
  cells of its own, is made by the compiled code itself when the callee is a function of that bytecode (any of its
  closures) and its code is compiled: the callee's frame is pushed on the value stack exactly as `frame_push` pushes it
  (so the collector, a deopt and an exception see an interpreter's frame), its code is called through the engine's
  table (imported by the module, `"e" "table"`), the frame is popped as `frame_pop` pops it. Nothing of the caller
  lives across the call but in its frame (its operand stack materialized, its objects written back), so no register
  state is saved. When the callee's code leaves other than by its return, the helper `wj_jit_finish`
  (`jit_call_finish`) interprets the rest of the call on its frame; an exception comes back as a throw exit of the
  caller. Any check that fails (another callee, not compiled, no room in the value stack's segment, too deep) makes
  the call through the helper instead, which pushes the frame the same way and enters the callee's code if it has
  some, else interprets it.
- A call of bytecode that cannot be compiled whole (a function with loops, a generator...) keeps the loop interpreted:
  through the helper it is a nested `interp_run`, slower than the interpreter's own call (measured in round 20: 84 ->
  130 ns for a small function). A callee refused after the caller was compiled makes the helper hand the call back to
  the interpreter (a deopt), until the caller is left to the interpreter.

Compiled code nested on the host stack (a compiled call of compiled code, a helper's call of a native that calls
compiled code) is bounded by `JIT_MAX_NEST` (`Runtime.jit_depth`): deeper calls are interpreted, with the interpreter's
own depth limit, so a recursion goes as deep as it does interpreted. Compiled code may run the same region again in a
nested frame (a call that recurses): the exit of the outer one checks that the region is still the code it ran
(`jl.index`) before it changes the region's state.

## Exits

The code returns an exit word (kind, pc, sp, aux) and the interpreter carries on at (pc, sp):

| exit | when |
|---|---|
| leave | a jump out of the region (aux: the iterations this entry ran) |
| ret | a return (the value in the frame's `stack[0]`; an exact integer is an int when it fits, as the interpreter has it) |
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
