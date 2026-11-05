# The JIT (`src/engine/jsrt/jit.odin`)

A hot loop of a function, or a hot function without loops of its own, is translated from its bytecode to a WebAssembly
function, which the host compiles with Cranelift and attaches to the engine's table (`src/js/jit.odin`,
`wasm.attach_function`); the interpreter then calls it like a C function pointer. WebAssembly stays the only execution
engine: the code made at run time lives in the engine's sandbox and reaches only the engine's memory, its table and the
helpers the engine exports to it.

## When a loop is compiled

The interpreter's hot loop counts back edges for the interrupt poll; every `INTERRUPT_POLL_EVERY` of them it leaves to
the full dispatch, which offers the back edge to `jit_back_edge`. A check falls on a loop in proportion to the part it has in
what runs: a loop met by `javascript.jit.loop_threshold` of them (`Jit_Loop.sightings`) is hot, one met once is not: compiled at
its first sighting, theverge.com translated 1 600 loops during its load for nothing it got back. It is then translated
(`jit_build`) and entered at its header (on-stack replacement), with the frame's arguments, locals and operand stack in
memory. While a loop of a function is compiled, the hot loop leaves at that loop's back edges only (`jit_loop_taken`);
the function's other loops stay in it.

A loop that runs few iterations per entry costs more to enter than the code saves: after `JIT_PROBE` entries with fewer
than `JIT_MIN_ITERS` iterations each on average it is left to the interpreter.

Before a loop is translated one iteration is recorded, up to its back edge (`Frame.recording`, below).

## When a function is compiled whole

A call of a plain function counts toward `javascript.jit.call_threshold` (`Function_Bytecode.jit_calls`, counted where
the interpreter pushes the callee's frame: `jit_pushed`, `jit_entered`, and in the helper of compiled code). Once it is
reached, the function is translated as the region `[0, end)` and entered at its call (`jit_fn_enter`): its arguments'
types guarded at entry, its locals in the frame's memory. Its loops are part of the region: a back edge to a leader but
the first sets `I_NEXT` and goes to the top of the code, a `br_table` to that leader (`Jc.inner`; only a region with
inner loops has it). A function that is refused counts no more (`JIT_CALLS_NEVER`).

## What the first runs met

At the threshold the function's next `JIT_RECORD_RUNS` calls are recorded (`jit_record`): the frame runs in the full
dispatch (`Frame.recording`, the hot loop leaves when it meets such a frame), and before each instruction with a site the
site takes what a learn exit would have told it, from the operands on the stack. Translated after that, code leaves little
to learn. Without it each site that had not been met was an exit and a translation: real functions reached
`JIT_MAX_LEARNS` first, and stayed interpreted. A run in a loop stops being recorded after `JIT_RECORD_EDGES` back edges.

The recorded runs also say which bytecode runs at all (`Jit_Loop.hit`): a block they did not reach is not compiled, only an
exit (`cold`) that marks it; `JIT_COLD_BATCH` such exits translate the region again. Past `JIT_MAX_LEARNS` such translations everything is
compiled. Cranelift's time is about proportional to the module, and most of a function is not what runs.

## What the translation does not do

No instruction keeps a region from being compiled (`jit_insn_or_slow`): what the translation emitted of the instruction is
taken back, and

- an instruction `jit_steppable` allows is made by the interpreter's own code (`j_slow_op`, the helper `jit_step`:
  `interp_run` with `Frame.recording` at `jit_stepping`, the full dispatch for one instruction). The written locals, the operand stack and the objects held
  are stored first, what it leaves comes back as V entries, the held arrays are taken again, as after a call. A closure may
  run, so a region with such an instruction keeps captured locals in memory (`Jit_Loop.slow`, `Jc.calls`). An exception stays
  pending: the code leaves through a throw exit with `JIT_AUX_PENDING`, which sets `Frame.pending_throw`, and the interpreter
  unwinds from there;
- any other instruction (`throw`, a `gosub`...) is where the code leaves: the interpreter goes on, and comes back at the
  next back edge or the next call.

`op_catch` is translated: its marker is a V entry, written to the frame with the stack when the code leaves. The handler is
only reached by the interpreter's unwinder: its code is not emitted when nothing else jumps there.

A site that leaves with nothing to learn (more shapes than it takes, an element outside the array, a callee that changes)
is marked slow after `JIT_SITE_MISSES` deopts and translated again: `j_slow_op`, or for a call `j_call_any`, the helper
whatever the callee is. A region is given up after `JIT_MAX_DEOPTS` only when more than one entry in `JIT_DEOPT_SHARE` still
leaves through a deopt.

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
loop's `hot_native_getter`: a DOM attribute's, Map's `size`) or a function of the script's, else the interpreter reads
it; the helper `wj_jit_get` (`jit_getter`) calls it (a native through `call_native`, a script's as compiled code calls
bytecode: its frame pushed, its compiled code run when it has some), the operand stack and the objects held written to
the frame first, the held arrays taken again after. A getter of the script's that can be compiled whole, the one the
translation sees (in the prototype that holds it, or in the object it sees), is called directly as a function is
(`j_direct_call`, below): its frame pushed by the code, `this` the object, the result at the read's place; any other
getter the read finds (a closure of other code, a native, one not compiled yet) goes through the helper. A write whose
site's first shape finds an accessor writes through setters the way the helper calls getters (`j_call_setter`,
`wj_jit_set`). An exception is exact: the helper puts the context's thrower in
the object's place (`Context.jit_thrower`, an object whose property of that name is an accessor with `jit_rethrow` as
its getter and its setter), the code leaves through a throw exit, and the interpreter makes the read or the write
again, which throws the exception pending. Host objects without exotic hooks
are ordinary objects there (`Object.host_exotic` checked where the code reads past one), so a DOM node's attributes and
methods are read through its prototypes.

A global's own accessor (`window.document`) is read the same way when the instruction after the read reads a named
property of its value (`get_field`, `get_field2`, `get_length`: `document.createElement(...)`): a read of a global has
no object on the stack to put the thrower in, so the helper puts it in the result's place, with that next property as
its accessor, and the throw exit resumes at the next instruction, which throws the exception pending. The interpreter's
code is unchanged (a throw exit of its own in its back edges cost 4 % of nodes10k with the JIT off, round 20). A global
accessor whose value is used otherwise keeps the loop interpreted.

A call whose callee the translation cannot tell (a method of an object a getter returned, unknown when the loop is
translated) leaves through a learn exit (`JIT_AUX_CALLEE`) the first time: the site keeps the callee it met
(`Jit_Site.callee`, a hint marked by the collector, never relied on), and the loop is translated again. A read of an
object the translation cannot tell, at a site that learned its shape, takes what the prototype holds for its hint (the
method `document.createElement` is, from `Document.prototype`).

What a site was compiled for is per site and bounded (`Jit_Site`: `JIT_SITE_SHAPES` shapes with their objects' class,
the type of the value read): taken from the frame's values when the loop is translated (the translation follows what
each entry held, as far as it can tell, for these hints), and learned when the site misses. A learn exit
(`JIT_AUX_LEARN`) hands the interpreter the state at the instruction; `jit_learn` looks at the object or the value, the
site takes its shape or a wider type, and the loop is translated again (`JIT_MAX_LEARNS` times at most). A miss with
nothing to learn (a shape the site does not take inline: an accessor, an exotic object, a frozen property for a write;
more shapes than the site takes) is a deopt, then a slow site (above).

A write of a property the object does not have appends it as `[[Set]]` does, when the site's shape is an ordinary
object's that is not a dictionary and the property is nowhere on its prototype chain: the shape's transition (made at
translation if it was not, `shape_transition`) is taken, the prototypes' shapes guarded, the object checked to be
ordinary and extensible, its slots grown by a helper (`wj_jit_reserve`) when they are full. The translation follows the
shapes the object it sees takes (`Jc.shadows`: a constructor's `this.x = x; this.y = y` is compiled for the shape after
`x` at the second write).

The shapes and objects the code compares against are kept alive by the loop (`Jit_Loop.keep` and the sites' shapes,
marked by the collector through `Function_Bytecode.jit`): an address the code holds is never another shape's.

## Objects made by compiled code

Compiled code allocates a plain object itself (`j_alloc`): the start of an object literal (`object`), and the object a
construction makes when the constructor's own `prototype` is the object the translation saw (`j_ctor_proto`: the
callee's shape and the slot's value guarded; the root shape of that prototype is a constant). It does what `cell_new`
and `object_new_shape` do: a block of the object's pool class popped from the free list (zeroed) or cut from the bump
chunk (`j_pool_take`), linked first in the runtime's cells, counted and charged to the heap (`j_cell_new`), the
object's class, bits, shape and inline slots written (`j_object_init`). An array literal (`array_from`) is made the
same way as `array_from_values` makes it: three blocks (its values, its one slot, the object), the entries stored into
the values, the length into the slot, the data an `Array_Data` (the union's tag written as an `Object_Data` of that
variant has it); a literal of more entries than a pool block holds (`JIT_ARR_MAX`) goes to the helper. An empty free
list at the chunk's end gives back the blocks already taken (as `raw_free` does) and, like a guard that fails, makes
the object through the helper `wj_jit_new` (`jit_new`), which also makes the other constructions
(`create_from_ctor`). The collector's contract is the engine's own either way: allocation never collects,
a collection runs only at a safe point, and the compiled code reaches one only through a call (whose helper writes the
operand stack and the objects held in locals to the frame first) or an exit; the helper drops the temporary roots of
the allocation (`temp_roots` back to the frame's height) and the code's own allocation pushes none, the object being in
the code's hands until then. An object literal's fields (`define_field`) need no guard: the translation knows the shape
of the object it made until the next join (`Jit_State.k`), and appends each field through the transition, its slots
grown when full.

A construction `new F(...)` of a constructor that can be compiled whole (not a derived class's) is a direct call
(below): the object made by the helper is the callee's `this`, new.target the constructor, the result the callee's
when it returns an object, else the object. A function without an operand stack (`function Empty() {}`: its only
return is `return_undef`) is compiled whole too; its frame begins where its stack would, so its code writes no result
and its callers take undefined (`jit_result`).

## Numbers of other values

An arithmetic or bitwise instruction takes a V entry as a number: its tag guarded to be an int (or a double, once the
site met one), else a learn exit. A bitwise operation's site that met undefined, null or a bool (`Jit_Site.odd`) takes
them too, as ToInt32 makes them (0, 0, 0 or 1): `m.get(k) | 0` of a key the map does not have stays compiled.

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
  (`JIT_AUX_NO_INLINE`) leaves the call to the interpreter for good. A call site keeps the functions it met
  (`Jit_Site.callees`, `JIT_SITE_SHAPES` of them: the one the translation sees, and each one a guard's miss learns);
  with two or more, each is inlined behind a check of the callee (`j_inline_poly`, at the loop's own level), its result
  a value; another callee is a learn exit while the site takes more, else the call is made (directly or through the
  helper).
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
  caller (a getter's: the object's place takes the context's thrower, as the helper of getters leaves it). Any check that fails (another callee, not compiled, no room in the value stack's segment, too deep) makes
  the call through the helper instead, which pushes the frame the same way and enters the callee's code if it has
  some, else interprets it.
- A call of bytecode that cannot be compiled whole (a generator, a function too large...) goes through the helper
  (`j_call_any`): a nested `interp_run`, slower than the interpreter's own call (measured in round 20: 84 -> 130 ns for a
  small function), but what is around it stays compiled.

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
| budget | every `JIT_BUDGET` iterations, and in a loop that calls once its calls count for a poll (`interrupt_counter`, as the interpreter counts them): the interpreter's safe point (interrupts, collection) runs |
| cold | a block the recorded runs did not reach: it is marked, translated again after `JIT_COLD_BATCH` of them |
| throw | a call made through the helper threw (the interpreter makes it again, its callee rethrows); aux `JIT_AUX_PENDING`: an instruction made by `jit_step` threw, the interpreter unwinds |

## Why code stays in the interpreter

`WREN_JS_PROFILE=<prefix>` (or `jsengine run -jit -jit-trace`) ends the page's profile with what the JIT said, counted: each
deopt, what it refused or left to the interpreter's code, and at each interrupt check where the interpreter was
(`jit: sample in ...`, `jit_note_sample`). `compiled, interpreted here` is mostly compiled code: its budget exit is where it polls.

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
