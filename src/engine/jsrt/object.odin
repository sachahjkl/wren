package jsrt

// Objects and shapes (hidden classes).
//
// An Object is a cell with a Shape (its prototype plus the ordered list of own property keys and
// attributes) and a flat array of property slots addressed by the shape's indices. Objects that grow
// the same way share shapes through a transition cache; an object that deletes properties or changes
// attributes gets a private "dictionary" shape it mutates in place. The class-specific internal
// slots ([[ArrayData]], [[BoundTargetFunction]], [[MapData]], ...) live in `data`, an Odin tagged
// union, so each exotic kind is checked by the compiler instead of being a cast from an opaque pointer.

import "base:runtime"
import "wb:engine/bigint"

Prop_Flag :: enum u8 {configurable, writable, enumerable}
Prop_Flags :: bit_set[Prop_Flag;u8]

CWE :: Prop_Flags{.configurable, .writable, .enumerable}
CW :: Prop_Flags{.configurable, .writable}

Prop_Kind :: enum u8 {
	data,
	accessor, // slot.getset
	var_ref,  // slot.var_ref (mapped arguments, module namespaces): the value lives in a closure cell
	lazy_prototype, // a function's `prototype`, not made yet (function_prototype_make): the slot is empty; only what looks at a property's value meets it
}

Shape_Prop :: struct {
	atom:  Atom,
	flags: Prop_Flags,
	kind:  Prop_Kind,
}

Transition :: struct {
	atom:  Atom,
	flags: Prop_Flags,
	kind:  Prop_Kind,
	to:    ^Shape, // weak: swept when unreachable
	walked: u32,   // the Runtime.chain_generation in which a set found this key nowhere on the prototypes: until it moves, a set of `a` on an ordinary object of this shape need not look (set_property)
}

Shape :: struct {
	using cell:  Cell,
	proto:       ^Object,
	props:       [dynamic]Shape_Prop,
	hash:        []u32, // index+1 into props, built when len(props) > SHAPE_LINEAR_MAX
	lazy:        ^Lazy_Members, // the members of the object that are not defined yet (see object_set_lazy)
	version:     u32,  // a dictionary shape's changes in place (its keys, their attributes, its prototype): compiled code
	                   // guards it with the shape (jit.odin)
	is_dict:     bool,
	// (what a lookup reads is above, in as few cache lines as it can be: a get_field that misses waits on each of them)
	transitions: [dynamic]Transition,
	transition_hash: []u32, // index+1 into transitions, kept past TRANSITIONS_LINEAR_MAX (the shape every `{}` starts from has a transition per first key)
}

// An object whose members are defined when first needed (a Web IDL prototype: most pages touch a few of the hundreds
// of interfaces, and each member is a function object). The object has a private shape marked lazy; shape_find, the
// enumerations of the shape and add_property call `fn` first, which defines the members the way the eager code would
// have (the same keys in the same order, after the properties already there).
Lazy_Proc :: #type proc(ctx: ^Context, o: ^Object, p: rawptr, user: i32)

Lazy_Members :: struct {
	ctx:  ^Context,
	o:    ^Object,
	fn:   Lazy_Proc,
	p:    rawptr,
	user: i32,
}

SHAPE_LINEAR_MAX :: 8
TRANSITIONS_LINEAR_MAX :: 8
SHAPE_SHARED_MAX :: 48 // beyond this many properties an object switches to a dictionary shape

Getset :: struct {
	getter: ^Object,
	setter: ^Object,
}

Prop_Slot :: struct #raw_union {
	value:   Value,
	getset:  Getset,
	var_ref: ^Var_Ref,
}

// Cell.flags of an object: it was once a WeakMap or WeakSet key, a WeakRef target or a FinalizationRegistry target or
// token (never cleared). An object that was never one can only be told apart from a copy of itself by a reference to it.
OBJ_HELD_WEAKLY :: u8(1 << 0)
// On the prototype chain of a transition that says it was walked (Transition.walked): what could stop a set on that chain moves Runtime.chain_generation.
OBJ_ON_WALKED_CHAIN :: u8(1 << 1)

// Whether `o` is as it was made with prototype `proto`: no own property, extensible, never held weakly. A host may then
// let it go and make the same object again when a script asks for it (src/engine/jscapi JS_IsUntouched).
object_untouched :: proc "contextless" (o: ^Object, proto: ^Object) -> bool {
	return o.extensible && o.flags & OBJ_HELD_WEAKLY == 0 && !o.shape.is_dict && len(o.shape.props) == 0 && o.shape.lazy == nil && o.shape.proto == proto
}

Object :: struct {
	using cell:     Cell,
	class:          Class_ID,
	using bits:     bit_field u8 {
		extensible:     bool | 1,
		is_constructor: bool | 1,
		fast_array:     bool | 1, // Array/Arguments: integer keys live in data.(Array_Data)
		is_htmldda:     bool | 1,
		is_class_ctor:  bool | 1,
		watch_index:    bool | 1, // Array.prototype / Object.prototype: an index key or a new [[Prototype]] disables array fast paths
		ctor_only:      bool | 1, // a native function that throws when called without `new` (Native_Kind.constructor_only)
		host_exotic:    bool | 1, // a host object whose class has exotic hooks, or had none defined when it was made
	},
	magic:          i16, // a native function's: here, it would make Native_Data the largest variant of the union
	shape:          ^Shape,
	slots:          [^]Prop_Slot,
	slot_cap:       u32,
	data:           Object_Data,
}

Object_Data :: union {
	Array_Data,
	Mapped_Args_Data,
	Func_Data,
	Native_Data,
	^Bound_Data,
	^Prim_Data,
	^Date_Data,
	^RegExp_Data,
	^Map_State,
	^Weak_Ref_Data,
	^Fin_Rec_Data,
	^Array_Buffer,
	^Typed_Array,
	^Proxy_Data,
	^Promise_Data,
	^Coro,
	^Iter_State,
	^Module,
	^Disposable_Data,
	^Host_Object,
	Internal_Data,
}

Array_Data :: struct {
	values: [^]Value,
	count:  u32,
	cap:    u32,
}

Mapped_Args_Data :: struct {
	refs:  [^]^Var_Ref,
	count: u32,
}

Func_Data :: struct {
	bc:       ^Function_Bytecode,
	var_refs: [^]^Var_Ref,
	home:     ^Object,
}

Native_Proc :: #type proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value
// A native closure: `data` values are passed through ctx-free access via native_data().
Native_Kind :: enum u8 {
	function,        // callable only (TypeError on `new`)
	constructor,     // `new` passes new_target as `this`; a plain call passes undefined
	constructor_only,// TypeError when called without `new`
}

// 12 bytes on wasm32, as the array variant, the largest of the union in Object: the kind and the magic live in the object
// (ctor_only, is_constructor: native_kind; Object.magic) and the number of data values in the block of `data`.
Native_Data :: struct {
	fn:    Native_Proc,
	realm: ^Context,
	data:  [^]Value, // after an 8-byte count (native_data_len), allocated with native_data_alloc
}

NATIVE_DATA_HEADER :: 8

// A native function that carries no values of its own (the C functions of the glue: a plain C function pointer and
// nothing else) keeps that pointer in `data` itself, shifted up by one with the low bit set, instead of a block of
// values: the blocks are 8-aligned, so the bit tells them apart. Saves 40 bytes in each of thousands of functions.
native_data_is_raw :: #force_inline proc "contextless" (nd: ^Native_Data) -> bool {
	return uintptr(nd.data) & 1 != 0
}

native_data_set_raw :: #force_inline proc "contextless" (nd: ^Native_Data, p: rawptr) {
	nd.data = cast([^]Value)((uintptr(p) << 1) | 1)
}

native_data_raw :: #force_inline proc "contextless" (nd: ^Native_Data) -> rawptr {
	return rawptr(uintptr(nd.data) >> 1)
}

native_data_len :: #force_inline proc "contextless" (nd: ^Native_Data) -> int {
	if nd.data == nil || native_data_is_raw(nd) {return 0}
	return int((cast(^u32)(uintptr(nd.data) - NATIVE_DATA_HEADER))^)
}

native_data_alloc :: proc(rt: ^Runtime, nd: ^Native_Data, n: int) {
	p := cast([^]byte)mem_alloc(rt, NATIVE_DATA_HEADER + n * size_of(Value))
	(cast(^u32)p)^ = u32(n)
	nd.data = cast([^]Value)(p[NATIVE_DATA_HEADER:])
}

native_data_free :: proc(rt: ^Runtime, nd: ^Native_Data) {
	if nd.data == nil || native_data_is_raw(nd) {return}
	mem_free(rt, rawptr(uintptr(nd.data) - NATIVE_DATA_HEADER), NATIVE_DATA_HEADER + native_data_len(nd) * size_of(Value))
	nd.data = nil
}

native_kind :: #force_inline proc "contextless" (o: ^Object) -> Native_Kind {
	if o.ctor_only {return .constructor_only}
	return o.is_constructor ? .constructor : .function
}

set_native_kind :: #force_inline proc "contextless" (o: ^Object, kind: Native_Kind) {
	o.is_constructor = kind != .function
	o.ctor_only = kind == .constructor_only
}

Bound_Data :: struct {
	target: Value,
	this:   Value,
	args:   []Value,
}

Prim_Data :: struct {
	v: Value,
}

Date_Data :: struct {
	t: f64,
}

Internal_Data :: struct {
	values: [^]Value,
	count:  u32,
}

// Map/Set/WeakMap/WeakSet: insertion-ordered hash table with tombstones so live iterators keep their
// place across deletions; compacted when no iterator is active.
Map_State :: struct {
	entries:   [dynamic]Map_Entry,
	index:     []i32, // hash -> entry index+1 (0 empty, -1 deleted)
	live:      int,
	iterators: int, // active iterators (blocks compaction)
	is_weak:   bool,
}

Map_Entry :: struct {
	key:     Value,
	value:   Value,
	deleted: bool,
}

Weak_Ref_Data :: struct {
	target: Value,
}

Fin_Rec_Cell :: struct {
	target: Value, // weak
	held:   Value,
	token:  Value, // weak
}

Fin_Rec_Data :: struct {
	callback: Value,
	cells:    [dynamic]Fin_Rec_Cell,
	realm:    ^Context,
}

Array_Buffer :: struct {
	data:         [^]u8,
	byte_length:  int,
	max_byte_length: int, // -1: not resizable
	alloc_len:    int,
	detached:     bool,
	shared:       bool,
	immutable:    bool, // created by transferToImmutable / sliceToImmutable
	external:     bool, // `data` belongs to another agent's buffer (shared_buffer_attach): never freed here
	free_proc:    proc(data: [^]u8, user: rawptr), // adopted host memory: how to release it
	free_user:    rawptr,
	views:        [dynamic]^Object, // typed arrays/data views over this buffer (weak-ish: views keep buffer alive)
	host:         ^Buffer_Host,     // the bytes are outside this engine's memory: `data` is nil unless pinned
}

// A buffer whose bytes are not in this engine's memory (a WebAssembly.Memory of the page): reached through the embedder.
// One element is one call; a builtin that works on a range pins it (host_pin): a copy `data` points at for that time.
// `shared`: other agents reach the bytes too: Atomics go to the embedder, and writes do not wait in a cache (host_line).
Buffer_Host :: struct {
	read:  proc "contextless" (user: u64, offset: int, dst: [^]u8, n: int),
	write: proc "contextless" (user: u64, offset: int, src: [^]u8, n: int),
	user:  u64,
	shared: ^Host_Shared,
	owned: bool,      // the script's own use of the bytes (shared.release when collected)
	rt:    ^Runtime,
	pin:   [^]u8,   // the copy of [pin_lo, pin_hi), while pinned
	pin_lo, pin_hi: int,
	pin_depth: int,
	pin_dirty: bool,
}

// What the embedder does for a SharedArrayBuffer whose bytes it holds (its realm's buffers: runtime config host_shared).
Host_Shared :: struct {
	read:    proc "contextless" (user: u64, offset: int, dst: [^]u8, n: int),
	write:   proc "contextless" (user: u64, offset: int, src: [^]u8, n: int),
	create:  proc "contextless" (byte_length, max_byte_length: i64) -> (user: u64, ok: bool),
	release: proc "contextless" (user: u64),
	length:  proc "contextless" (user: u64) -> int,
	grow:    proc "contextless" (user: u64, byte_length: i64) -> bool,
	// the element of `size` bytes at `offset`: the value it held. `op`: an Atomic_Op
	atomic:  proc "contextless" (user: u64, op: i32, offset: int, size: int, a, b: u64) -> u64,
	// 0 woken, 1 not equal, 2 timed out (`timeout_ms` < 0: none)
	wait:    proc "contextless" (user: u64, offset: int, size: int, expected: u64, timeout_ms: f64) -> i32,
	notify:  proc "contextless" (user: u64, offset: int, count: u32) -> i32,
}

Typed_Array :: struct {
	buffer:      ^Object,
	offset:      int,
	length:      int, // element count (or byte length for DataView) at creation
	track_rab:   bool, // length follows a resizable buffer
}

Proxy_Data :: struct {
	target:     Value,
	handler:    Value,
	is_func:    bool,
	revoked:    bool,
}

Promise_State :: enum u8 {pending, fulfilled, rejected}

Promise_Reaction :: struct {
	is_reject: bool,
	handler:   Value,
	resolve:   Value, // capability
	reject:    Value,
	promise:   Value,
}

Promise_Data :: struct {
	state:      Promise_State,
	result:     Value,
	reactions:  [dynamic]Promise_Reaction,
	is_handled: bool,
}

Disposable_Data :: struct {
	stack:    [dynamic]Value, // (value, method, kind) triples flattened
	disposed: bool,
}

// The primitive a wrapper object (or an Error's [[ErrorData]]) holds, and the time value of a Date: out of line, so
// that the union in Object stays small. Set again in place by the setters.
set_prim :: proc(rt: ^Runtime, o: ^Object, v: Value) {
	if p, ok := o.data.(^Prim_Data); ok {p.v = v; return}
	p := cast(^Prim_Data)mem_alloc(rt, size_of(Prim_Data))
	p.v = v
	o.data = p
}

set_date :: proc(rt: ^Runtime, o: ^Object, t: f64) {
	if p, ok := o.data.(^Date_Data); ok {p.t = t; return}
	p := cast(^Date_Data)mem_alloc(rt, size_of(Date_Data))
	p.t = t
	o.data = p
}

// What a page's heap is made of, on the target that ships (docs/engine/runtime.md): a plain object is its 40 bytes and 4 inline slots.
when ODIN_ARCH == .wasm32 {
	#assert(size_of(Cell) == 8 && size_of(Object) == 40 && size_of(Object_Data) == 16 && size_of(Var_Ref) == 32 && size_of(JS_String) == 28)
}

// --- shapes ---

shape_new :: proc(rt: ^Runtime, proto: ^Object) -> ^Shape {
	sh := cell_new(rt, Shape, .shape)
	sh.proto = proto
	sh.props = make([dynamic]Shape_Prop, rt_allocator(rt))
	sh.transitions = make([dynamic]Transition, rt_allocator(rt))
	return sh
}

shape_finalize :: proc(rt: ^Runtime, sh: ^Shape) {
	if sh.lazy != nil {mem_free(rt, sh.lazy, size_of(Lazy_Members))}
	delete(sh.props)
	delete(sh.transitions)
	if sh.hash != nil {delete(sh.hash, rt_allocator(rt))}
	if sh.transition_hash != nil {delete(sh.transition_hash, rt_allocator(rt))}
}

// The shared empty shape for objects created with `proto`.
shape_root_for :: proc(rt: ^Runtime, proto: ^Object) -> ^Shape {
	if sh, ok := rt.shape_root[proto]; ok {return sh}
	sh := shape_new(rt, proto)
	rt.shape_root[proto] = sh
	return sh
}

@(private = "file")
shape_build_hash :: proc(rt: ^Runtime, sh: ^Shape) {
	n := len(sh.props)
	if n <= SHAPE_LINEAR_MAX {
		if sh.hash != nil {delete(sh.hash, rt_allocator(rt)); sh.hash = nil}
		return
	}
	size := 16
	for size < n * 2 {size *= 2}
	if sh.hash == nil || len(sh.hash) != size {
		if sh.hash != nil {delete(sh.hash, rt_allocator(rt))}
		sh.hash = make([]u32, size, rt_allocator(rt))
	} else {
		for i in 0 ..< size {sh.hash[i] = 0}
	}
	mask := u32(size - 1)
	for p, idx in sh.props {
		h := atom_mix(p.atom) & mask
		for sh.hash[h] != 0 {h = (h + 1) & mask}
		sh.hash[h] = u32(idx + 1)
	}
}

atom_mix :: #force_inline proc "contextless" (a: Atom) -> u32 {
	return (a * 0x9E3779B1) ~ (a >> 15)
}

// Defines the members of a lazy shape's object (once: the mark is cleared first, the definitions look their keys up).
shape_realize :: #force_no_inline proc "contextless" (sh: ^Shape) {
	context = runtime.default_context() // memcheck: the JavaScript engine's own heap (a guest allocator), not the browser's process memory
	lz := sh.lazy
	sh.lazy = nil
	lz.fn(lz.ctx, lz.o, lz.p, lz.user)
	mem_free(lz.ctx.rt, lz, size_of(Lazy_Members))
}

// For the code that reads shape.props directly.
shape_ensure :: #force_inline proc "contextless" (sh: ^Shape) {
	if sh.lazy != nil {shape_realize(sh)}
}

// Marks `o` lazy: `fn(ctx, o, p, user)` will define its members. Call it after the properties that must come first
// are defined (it gives o a private shape).
object_set_lazy :: proc(ctx: ^Context, o: ^Object, fn: Lazy_Proc, p: rawptr, user: i32) {
	rt := ctx.rt
	shape_ensure(o.shape)
	object_make_dict(rt, o)
	lz := cast(^Lazy_Members)mem_alloc(rt, size_of(Lazy_Members))
	lz^ = {ctx, o, fn, p, user}
	o.shape.lazy = lz
}

object_is_lazy :: #force_inline proc "contextless" (o: ^Object) -> bool {return o.shape.lazy != nil}

shape_find :: #force_inline proc "contextless" (sh: ^Shape, a: Atom) -> int {
	if sh.lazy != nil {shape_realize(sh)}
	return shape_lookup(sh, a)
}

// shape_find in a shape whose members are defined (not lazy): calls nothing.
shape_lookup :: #force_inline proc "contextless" (sh: ^Shape, a: Atom) -> int {
	if sh.hash == nil {
		for p, i in sh.props {
			if p.atom == a {return i}
		}
		return -1
	}
	mask := u32(len(sh.hash) - 1)
	h := atom_mix(a) & mask
	for {
		v := sh.hash[h]
		if v == 0 {return -1}
		if sh.props[v - 1].atom == a {return int(v - 1)}
		h = (h + 1) & mask
	}
}

@(private = "file")
shape_clone :: proc(rt: ^Runtime, src: ^Shape, dict: bool) -> ^Shape {
	sh := shape_new(rt, src.proto)
	reserve(&sh.props, len(src.props) + 1)
	append(&sh.props, ..src.props[:])
	sh.is_dict = dict
	shape_build_hash(rt, sh)
	return sh
}

// Give `o` a private, mutable shape.
object_make_dict :: proc(rt: ^Runtime, o: ^Object) {
	if o.shape.is_dict {return}
	o.shape = shape_clone(rt, o.shape, true)
}

// --- slots ---

@(private = "file")
slots_reserve :: proc(rt: ^Runtime, o: ^Object, n: int) {
	if u32(n) <= o.slot_cap {return}
	new_cap := max(n, int(o.slot_cap) * 3 / 2, 4)
	if slots_are_inline(o) {
		ns := cast([^]Prop_Slot)mem_alloc(rt, new_cap * size_of(Prop_Slot))
		for i in 0 ..< int(o.slot_cap) {ns[i] = o.slots[i]}
		o.slots = ns
	} else {
		o.slots = cast([^]Prop_Slot)mem_resize(rt, o.slots, int(o.slot_cap) * size_of(Prop_Slot), new_cap * size_of(Prop_Slot))
	}
	for i in int(o.slot_cap) ..< new_cap {o.slots[i] = {}}
	o.slot_cap = u32(new_cap)
}

// Room for exactly `n` slots in an object that has none yet (a function with its length and name: the 4 a growing
// object asks for would leave half of them empty in each of thousands of functions).
object_reserve_exact :: proc(rt: ^Runtime, o: ^Object, n: int) {
	if o.slot_cap != 0 || n <= 0 {return}
	o.slots = cast([^]Prop_Slot)mem_alloc(rt, n * size_of(Prop_Slot))
	o.slot_cap = u32(n)
}

// Append a property to `o` (the caller has checked it does not exist). Returns its slot.
add_property :: proc(rt: ^Runtime, o: ^Object, a: Atom, flags: Prop_Flags, kind: Prop_Kind = .data) -> ^Prop_Slot {
	if o.watch_index {
		if _, isi := atom_index(rt, a); isi {rt.std_protos_touched = true}
	}
	if kind != .data || .writable not_in flags {chain_changed(rt, o)}
	shape_ensure(o.shape)
	sh := o.shape
	if sh.is_dict {
		append(&sh.props, Shape_Prop{a, flags, kind})
		sh.version += 1
		n := len(sh.props)
		if n > SHAPE_LINEAR_MAX {
			if sh.hash == nil || n * 2 > len(sh.hash) {
				shape_build_hash(rt, sh)
			} else {
				mask := u32(len(sh.hash) - 1)
				h := atom_mix(a) & mask
				for sh.hash[h] != 0 {h = (h + 1) & mask}
				sh.hash[h] = u32(n)
			}
		}
	} else {
		o.shape = shape_transition(rt, sh, a, flags, kind)
	}
	n := len(o.shape.props)
	slots_reserve(rt, o, n)
	s := &o.slots[n - 1]
	s^ = {}
	return s
}

// The shape an object of the shared shape `sh` takes when the property `a` is appended: the transition's (made the
// first time; a dictionary shape of its own past SHAPE_SHARED_MAX properties, which no transition keeps). Inlined in
// add_property: out of line, a closure took 5 % longer to make (its four properties; docs/performance.md, round 22).
shape_transition :: #force_inline proc(rt: ^Runtime, sh: ^Shape, a: Atom, flags: Prop_Flags, kind: Prop_Kind) -> ^Shape {
	if to := shape_next(sh, a, flags, kind); to != nil {return to}
	next := shape_clone(rt, sh, len(sh.props) >= SHAPE_SHARED_MAX)
	append(&next.props, Shape_Prop{a, flags, kind})
	shape_build_hash(rt, next)
	if !next.is_dict {
		append(&sh.transitions, Transition{atom = a, flags = flags, kind = kind, to = next})
		shape_hash_transitions(rt, sh)
	}
	return next
}

// Where a transition of `sh` leads, nil when it has none: so `a` is not a key of `sh` when it has one.
shape_next :: #force_inline proc "contextless" (sh: ^Shape, a: Atom, flags: Prop_Flags, kind: Prop_Kind) -> ^Shape {
	t := shape_transition_of(sh, a, flags, kind)
	return t != nil ? t.to : nil
}

shape_transition_of :: #force_inline proc "contextless" (sh: ^Shape, a: Atom, flags: Prop_Flags, kind: Prop_Kind) -> ^Transition {
	if sh.transition_hash == nil {
		for &t in sh.transitions {
			if t.atom == a && t.flags == flags && t.kind == kind {return &t}
		}
		return nil
	}
	mask := u32(len(sh.transition_hash) - 1)
	h := atom_mix(a) & mask
	for {
		v := sh.transition_hash[h]
		if v == 0 {return nil}
		t := &sh.transitions[v - 1]
		if t.atom == a && t.flags == flags && t.kind == kind {return t}
		h = (h + 1) & mask
	}
}

// Something that can stop a set was put on `o`, or its prototype changed: what was walked through it no longer holds.
chain_changed :: #force_inline proc "contextless" (rt: ^Runtime, o: ^Object) {
	if o.flags & OBJ_ON_WALKED_CHAIN != 0 {rt.chain_generation += 1}
}

// `o` goes to the shape `to` of a transition of its own: the slot of the key that comes with it, empty.
object_take_transition :: #force_inline proc(rt: ^Runtime, o: ^Object, to: ^Shape) -> ^Prop_Slot {
	o.shape = to
	n := len(to.props)
	slots_reserve(rt, o, n)
	s := &o.slots[n - 1]
	s^ = {}
	return s
}

// A set of `a` on `o` made it a new property by the transition from `from`, having found it nowhere on the prototypes (none of them
// exotic for this key): the next one on that shape need not look. Only a key nothing holds: a property found on the way
// could go by `delete` and show what was behind it.
chain_walked :: proc(rt: ^Runtime, from: ^Shape, a: Atom) {
	t := shape_transition_of(from, a, CWE, .data)
	if t == nil {return}
	for p := from.proto; p != nil; p = p.shape.proto {p.flags |= OBJ_ON_WALKED_CHAIN}
	t.walked = rt.chain_generation
}

// After a transition was added or the sweep took some: the table made again when the list has outgrown it, else the new one entered.
shape_hash_transitions :: proc(rt: ^Runtime, sh: ^Shape, rebuild := false) {
	n := len(sh.transitions)
	if n <= TRANSITIONS_LINEAR_MAX {
		if sh.transition_hash != nil {delete(sh.transition_hash, rt_allocator(rt)); sh.transition_hash = nil}
		return
	}
	first := n - 1
	if rebuild || n * 2 > len(sh.transition_hash) {
		if sh.transition_hash != nil {delete(sh.transition_hash, rt_allocator(rt))}
		size := 16
		for size < n * 4 {size *= 2}
		sh.transition_hash = make([]u32, size, rt_allocator(rt))
		first = 0
	}
	mask := u32(len(sh.transition_hash) - 1)
	for i in first ..< n {
		h := atom_mix(sh.transitions[i].atom) & mask
		for sh.transition_hash[h] != 0 {h = (h + 1) & mask}
		sh.transition_hash[h] = u32(i + 1)
	}
}

// The property `a` appended by its transition, when `sh` is a shared shape that has one: the caller then knows `a` is new.
object_append_by_transition :: #force_inline proc(rt: ^Runtime, o: ^Object, a: Atom, flags: Prop_Flags) -> ^Prop_Slot {
	sh := o.shape
	if sh.is_dict || o.watch_index || o.class != .object || !o.extensible || sh.lazy != nil {return nil}
	to := shape_next(sh, a, flags, .data)
	if to == nil {return nil}
	o.shape = to
	n := len(to.props)
	slots_reserve(rt, o, n)
	return &o.slots[n - 1]
}

// Room for n slots in o (the JIT's code, which appends properties itself: jit.odin).
object_slots_reserve :: proc(rt: ^Runtime, o: ^Object, n: int) {
	slots_reserve(rt, o, n)
}

// Remove own property at index `idx` (keeps the order of the others).
remove_property_at :: proc(rt: ^Runtime, o: ^Object, idx: int) {
	object_make_dict(rt, o)
	sh := o.shape
	n := len(sh.props)
	ordered_remove(&sh.props, idx)
	sh.version += 1
	for i in idx ..< n - 1 {o.slots[i] = o.slots[i + 1]}
	o.slots[n - 1] = {}
	shape_build_hash(rt, sh)
}

// Change the attributes/kind of an existing own property.
set_property_flags :: proc(rt: ^Runtime, o: ^Object, idx: int, flags: Prop_Flags, kind: Prop_Kind) {
	p := o.shape.props[idx]
	if p.flags == flags && p.kind == kind {return}
	chain_changed(rt, o)
	object_make_dict(rt, o)
	o.shape.props[idx].flags = flags
	o.shape.props[idx].kind = kind
	o.shape.version += 1
}

set_object_proto :: proc(rt: ^Runtime, o: ^Object, proto: ^Object) {
	if o.shape.proto == proto {return}
	if o.watch_index {rt.std_protos_touched = true}
	chain_changed(rt, o)
	if len(o.shape.props) == 0 && !o.shape.is_dict {
		o.shape = shape_root_for(rt, proto)
		return
	}
	object_make_dict(rt, o)
	o.shape.proto = proto
	o.shape.version += 1
}

object_proto :: #force_inline proc "contextless" (o: ^Object) -> ^Object {return o.shape.proto}

// --- creation ---

// A plain object made empty has room inline for this many slots: it grows.
INLINE_SLOTS :: 4
// An object's slots follow it in its cell when they fit a block of the pool: one allocation, one block the sweep frees and
// nothing for it to do. Past that they have a block of their own.
INLINE_SLOTS_MAX :: (POOL_MAX_BYTES - size_of(Object)) / size_of(Prop_Slot)

// `tail`: bytes of the cell after its slots, for the caller (object_tail).
object_new_shape :: proc(rt: ^Runtime, sh: ^Shape, class: Class_ID, tail := 0) -> ^Object {
	n := len(sh.props)
	room := class == .object && n == 0 ? INLINE_SLOTS : n // (a shape with keys is what the object will have: an iterator's result, a prototype)
	inline := room <= INLINE_SLOTS_MAX
	o := cell_new(rt, Object, .object, (inline ? room * size_of(Prop_Slot) : 0) + tail)
	o.class = class
	o.extensible = true
	o.shape = sh
	if inline {
		if room > 0 {
			o.slots = inline_slots(o)
			o.slot_cap = u32(room)
		}
	} else {
		o.slots = cast([^]Prop_Slot)mem_alloc(rt, room * size_of(Prop_Slot))
		o.slot_cap = u32(room)
	}
	return o
}

// What object_new_shape left after the slots of `o`, while they are still those it was made with.
object_tail :: #force_inline proc "contextless" (o: ^Object) -> rawptr {
	return rawptr(uintptr(o) + size_of(Object) + uintptr(o.slot_cap) * size_of(Prop_Slot))
}

inline_slots :: #force_inline proc "contextless" (o: ^Object) -> [^]Prop_Slot {
	return cast([^]Prop_Slot)(uintptr(o) + size_of(Object))
}

// Is `p` in the cell of `c` (the tail of a function: its closure cells)?
cell_holds :: #force_inline proc "contextless" (c: ^Cell, p: rawptr) -> bool {
	return uintptr(p) - uintptr(c) < uintptr(c.size)
}

// Are o's slots the inline ones (not a separate allocation)?
slots_are_inline :: #force_inline proc "contextless" (o: ^Object) -> bool {
	return o.slots == inline_slots(o) && o.size > size_of(Object)
}

object_new_proto :: proc(ctx: ^Context, proto: ^Object, class: Class_ID = .object) -> ^Object {
	return object_new_shape(ctx.rt, shape_root_for(ctx.rt, proto), class)
}

new_plain_object :: proc(ctx: ^Context) -> ^Object {
	return object_new_shape(ctx.rt, ctx.plain_shape, .object)
}

// A fresh Array with `n` slots of capacity and length 0.
array_new :: proc(ctx: ^Context, cap := 0) -> ^Object {
	rt := ctx.rt
	o := object_new_shape(rt, ctx.array_shape, .array)
	o.fast_array = true
	o.slots[0].value = mk_int(0)
	ad := Array_Data{}
	if cap > 0 {
		ad.values = mem_array(rt, Value, cap)
		ad.cap = u32(cap)
	}
	o.data = ad
	return o
}

// An Array holding a copy of `vals`.
array_from_values :: proc(ctx: ^Context, vals: []Value) -> ^Object {
	o := array_new(ctx, len(vals))
	ad := &o.data.(Array_Data)
	for v, i in vals {ad.values[i] = v}
	ad.count = u32(len(vals))
	o.slots[0].value = mk_u32(u32(len(vals)))
	return o
}

array_data :: #force_inline proc(o: ^Object) -> ^Array_Data {
	return &o.data.(Array_Data)
}

array_reserve :: proc(rt: ^Runtime, ad: ^Array_Data, n: u32) {
	if n <= ad.cap {return}
	new_cap := max(n, ad.cap * 3 / 2 + 4)
	ad.values = cast([^]Value)mem_resize(rt, ad.values, int(ad.cap) * size_of(Value), int(new_cap) * size_of(Value))
	ad.cap = new_cap
}

// Push onto a fast array (caller guarantees fast_array and that length == count).
array_push_fast :: proc(rt: ^Runtime, o: ^Object, v: Value) {
	ad := &o.data.(Array_Data)
	array_reserve(rt, ad, ad.count + 1)
	ad.values[ad.count] = v
	ad.count += 1
	o.slots[0].value = mk_u32(ad.count)
}

// --- finalization ---

object_finalize :: proc(rt: ^Runtime, o: ^Object) {
	if o.slots != nil && !slots_are_inline(o) {mem_free(rt, o.slots, int(o.slot_cap) * size_of(Prop_Slot))}
	o.slots = nil
	switch d in o.data {
	case Array_Data:
		if d.values != nil {mem_free(rt, d.values, int(d.cap) * size_of(Value))}
	case Mapped_Args_Data:
		if d.refs != nil {mem_free(rt, d.refs, int(d.count) * size_of(^Var_Ref))}
	case Func_Data:
		if d.var_refs != nil && d.bc != nil && !cell_holds(o, d.var_refs) {mem_free(rt, d.var_refs, int(d.bc.closure_var_count) * size_of(^Var_Ref))}
	case Native_Data:
		native_data_free(rt, &o.data.(Native_Data))
	case ^Bound_Data:
		delete(d.args, rt_allocator(rt))
		mem_delete(rt, d)
	case ^Prim_Data:
		mem_free(rt, d, size_of(Prim_Data))
	case ^Date_Data:
		mem_free(rt, d, size_of(Date_Data))
	case ^RegExp_Data:
		regexp_data_free(rt, d)
	case ^Map_State:
		delete(d.entries)
		if d.index != nil {delete(d.index, rt_allocator(rt))}
		free(d, rt_allocator(rt))
	case ^Weak_Ref_Data:
		free(d, rt_allocator(rt))
	case ^Fin_Rec_Data:
		delete(d.cells)
		free(d, rt_allocator(rt))
	case ^Array_Buffer:
		buffer_release_data(rt, d)
		if d.host != nil {buffer_host_release(rt, d)}
		delete(d.views)
		free(d, rt_allocator(rt))
	case ^Typed_Array:
		free(d, rt_allocator(rt))
	case ^Proxy_Data:
		free(d, rt_allocator(rt))
	case ^Promise_Data:
		delete(d.reactions)
		mem_delete(rt, d)
	case ^Coro:
		coro_free(rt, d)
	case ^Iter_State:
		iter_state_free(rt, d) // (in the object's cell)
	case ^Module:
	case ^Disposable_Data:
		delete(d.stack)
		free(d, rt_allocator(rt))
	case ^Host_Object:
		host_object_free(rt, o, d)
	case Internal_Data:
		if d.values != nil {mem_free(rt, d.values, int(d.count) * size_of(Value))}
	}
	o.data = nil
}

// --- tracing ---

object_trace :: proc(rt: ^Runtime, o: ^Object) {
	sh := o.shape
	mark_cell(rt, sh)
	for p, i in sh.props {
		s := &o.slots[i]
		switch p.kind {
		case .data:
			mark_value(rt, s.value)
		case .accessor:
			mark_cell(rt, s.getset.getter)
			mark_cell(rt, s.getset.setter)
		case .var_ref:
			mark_cell(rt, s.var_ref)
		case .lazy_prototype:
		}
	}
	switch d in o.data {
	case Array_Data:
		if d.values != nil {mark_values(rt, d.values[:d.count])}
	case Mapped_Args_Data:
		for i in 0 ..< int(d.count) {mark_cell(rt, d.refs[i])}
	case Func_Data:
		mark_cell(rt, d.bc)
		mark_cell(rt, d.home)
		if d.var_refs != nil && d.bc != nil {
			for i in 0 ..< int(d.bc.closure_var_count) {mark_cell(rt, d.var_refs[i])}
		}
	case Native_Data:
		if d.data != nil && !native_data_is_raw(&o.data.(Native_Data)) {mark_values(rt, d.data[:native_data_len(&o.data.(Native_Data))])}
	case ^Bound_Data:
		mark_value(rt, d.target)
		mark_value(rt, d.this)
		mark_values(rt, d.args)
	case ^Prim_Data:
		mark_value(rt, d.v)
	case ^Date_Data:
	case ^RegExp_Data:
		mark_cell(rt, d.source)
	case ^Map_State:
		if !d.is_weak {
			for &e in d.entries {
				if !e.deleted {mark_value(rt, e.key); mark_value(rt, e.value)}
			}
		}
	case ^Weak_Ref_Data:
	case ^Fin_Rec_Data:
		mark_value(rt, d.callback)
		for c in d.cells {mark_value(rt, c.held)}
	case ^Array_Buffer:
	case ^Typed_Array:
		mark_cell(rt, d.buffer)
	case ^Proxy_Data:
		mark_value(rt, d.target)
		mark_value(rt, d.handler)
	case ^Promise_Data:
		mark_value(rt, d.result)
		for &r in d.reactions {
			mark_value(rt, r.handler)
			mark_value(rt, r.resolve)
			mark_value(rt, r.reject)
			mark_value(rt, r.promise)
		}
	case ^Coro:
		coro_trace(rt, d)
	case ^Iter_State:
		iter_state_trace(rt, d)
	case ^Module:
		mark_cell(rt, d)
	case ^Disposable_Data:
		mark_values(rt, d.stack[:])
	case ^Host_Object:
		host_object_trace(rt, o, d)
	case Internal_Data:
		if d.values != nil {mark_values(rt, d.values[:d.count])}
	}
}

// --- BigInt cells ---

JS_BigInt :: struct {
	using cell: Cell,
	val:        bigint.Int,
}

bigint_new :: proc(rt: ^Runtime, v: bigint.Int) -> ^JS_BigInt {
	b := cell_new(rt, JS_BigInt, .bigint)
	b.val = v
	return b
}

bigint_finalize :: proc(rt: ^Runtime, b: ^JS_BigInt) {
	context.allocator = rt_allocator(rt)
	bigint.destroy(&b.val)
}

// --- closure cells ---

Var_Ref :: struct {
	using cell: Cell,
	pvalue:     ^Value, // the live location: into a frame while open, &value once detached
	owner:      ^Object, // the coroutine object whose frame holds the open variable (or nil)
	value:      Value,
}

var_ref_is_detached :: #force_inline proc "contextless" (vr: ^Var_Ref) -> bool {return vr.pvalue == &vr.value}

var_ref_new_detached :: proc(rt: ^Runtime, v: Value) -> ^Var_Ref {
	vr := cell_new(rt, Var_Ref, .var_ref)
	vr.value = v
	vr.pvalue = &vr.value
	return vr
}

// --- misc object helpers ---

is_callable :: proc "contextless" (v: Value) -> bool {
	if v.tag != .object {return false}
	o := as_obj(v)
	#partial switch o.class {
	case .bytecode_function, .c_function, .bound_function:
		return true
	case .proxy:
		return o.data.(^Proxy_Data).is_func
	}
	return false
}

is_constructor :: proc "contextless" (v: Value) -> bool {
	if v.tag != .object {return false}
	return as_obj(v).is_constructor
}

is_array_value :: proc(ctx: ^Context, v_in: Value) -> int {
	v := v_in
	for v.tag == .object {
		o := as_obj(v)
		if o.class == .array {return 1}
		if o.class != .proxy {return 0}
		pd := o.data.(^Proxy_Data)
		if pd.revoked {throw_type_error(ctx, "revoked proxy"); return -1}
		v = pd.target
	}
	return 0
}
