package jsrt

// Objects and shapes (hidden classes).
//
// An Object is a cell with a Shape (its prototype plus the ordered list of own property keys and
// attributes) and a flat array of property slots addressed by the shape's indices. Objects that grow
// the same way share shapes through a transition cache; an object that deletes properties or changes
// attributes gets a private "dictionary" shape it mutates in place. The class-specific internal
// slots ([[ArrayData]], [[BoundTargetFunction]], [[MapData]], ...) live in `data`, an Odin tagged
// union, so each exotic kind is checked by the compiler instead of being a cast from an opaque pointer.

import "wb:engine/bigint"

Prop_Flag :: enum u8 {configurable, writable, enumerable}
Prop_Flags :: bit_set[Prop_Flag;u8]

CWE :: Prop_Flags{.configurable, .writable, .enumerable}
CW :: Prop_Flags{.configurable, .writable}

Prop_Kind :: enum u8 {
	data,
	accessor, // slot.getset
	var_ref,  // slot.var_ref (mapped arguments, module namespaces): the value lives in a closure cell
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
}

Shape :: struct {
	using cell:  Cell,
	proto:       ^Object,
	props:       [dynamic]Shape_Prop,
	hash:        []u32, // index+1 into props, built when len(props) > SHAPE_LINEAR_MAX
	transitions: [dynamic]Transition,
	is_dict:     bool,
}

SHAPE_LINEAR_MAX :: 8
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

Object :: struct {
	using cell:     Cell,
	class:          Class_ID,
	extensible:     bool,
	is_constructor: bool,
	fast_array:     bool, // Array/Arguments: integer keys live in data.(Array_Data)
	is_htmldda:     bool,
	is_class_ctor:  bool,
	watch_index:    bool, // Array.prototype / Object.prototype: an index key or a new [[Prototype]] disables array fast paths
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
	Prim_Data,
	Date_Data,
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

Native_Data :: struct {
	fn:       Native_Proc,
	realm:    ^Context,
	magic:    i32,
	kind:     Native_Kind,
	data:     [^]Value,
	data_len: u32,
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
	views:        [dynamic]^Object, // typed arrays/data views over this buffer (weak-ish: views keep buffer alive)
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

// --- shapes ---

shape_new :: proc(rt: ^Runtime, proto: ^Object) -> ^Shape {
	sh := cell_new(rt, Shape, .shape)
	sh.proto = proto
	sh.props = make([dynamic]Shape_Prop, rt_allocator(rt))
	sh.transitions = make([dynamic]Transition, rt_allocator(rt))
	return sh
}

shape_finalize :: proc(rt: ^Runtime, sh: ^Shape) {
	delete(sh.props)
	delete(sh.transitions)
	if sh.hash != nil {delete(sh.hash, rt_allocator(rt))}
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

shape_find :: #force_inline proc "contextless" (sh: ^Shape, a: Atom) -> int {
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
	o.slots = cast([^]Prop_Slot)mem_resize(rt, o.slots, int(o.slot_cap) * size_of(Prop_Slot), new_cap * size_of(Prop_Slot))
	for i in int(o.slot_cap) ..< new_cap {o.slots[i] = {}}
	o.slot_cap = u32(new_cap)
}

// Append a property to `o` (the caller has checked it does not exist). Returns its slot.
add_property :: proc(rt: ^Runtime, o: ^Object, a: Atom, flags: Prop_Flags, kind: Prop_Kind = .data) -> ^Prop_Slot {
	if o.watch_index {
		if _, isi := atom_index(rt, a); isi {rt.std_protos_touched = true}
	}
	sh := o.shape
	if sh.is_dict {
		append(&sh.props, Shape_Prop{a, flags, kind})
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
		next: ^Shape
		for t in sh.transitions {
			if t.atom == a && t.flags == flags && t.kind == kind {next = t.to; break}
		}
		if next == nil {
			if len(sh.props) >= SHAPE_SHARED_MAX {
				next = shape_clone(rt, sh, true)
			} else {
				next = shape_clone(rt, sh, false)
			}
			append(&next.props, Shape_Prop{a, flags, kind})
			shape_build_hash(rt, next)
			if !next.is_dict {
				append(&sh.transitions, Transition{a, flags, kind, next})
			}
		}
		o.shape = next
	}
	n := len(o.shape.props)
	slots_reserve(rt, o, n)
	s := &o.slots[n - 1]
	s^ = {}
	return s
}

// Remove own property at index `idx` (keeps the order of the others).
remove_property_at :: proc(rt: ^Runtime, o: ^Object, idx: int) {
	object_make_dict(rt, o)
	sh := o.shape
	n := len(sh.props)
	ordered_remove(&sh.props, idx)
	for i in idx ..< n - 1 {o.slots[i] = o.slots[i + 1]}
	o.slots[n - 1] = {}
	shape_build_hash(rt, sh)
}

// Change the attributes/kind of an existing own property.
set_property_flags :: proc(rt: ^Runtime, o: ^Object, idx: int, flags: Prop_Flags, kind: Prop_Kind) {
	p := o.shape.props[idx]
	if p.flags == flags && p.kind == kind {return}
	object_make_dict(rt, o)
	o.shape.props[idx].flags = flags
	o.shape.props[idx].kind = kind
}

set_object_proto :: proc(rt: ^Runtime, o: ^Object, proto: ^Object) {
	if o.shape.proto == proto {return}
	if o.watch_index {rt.std_protos_touched = true}
	if len(o.shape.props) == 0 && !o.shape.is_dict {
		o.shape = shape_root_for(rt, proto)
		return
	}
	object_make_dict(rt, o)
	o.shape.proto = proto
}

object_proto :: #force_inline proc "contextless" (o: ^Object) -> ^Object {return o.shape.proto}

// --- creation ---

object_new_shape :: proc(rt: ^Runtime, sh: ^Shape, class: Class_ID) -> ^Object {
	o := cell_new(rt, Object, .object)
	o.class = class
	o.extensible = true
	o.shape = sh
	n := len(sh.props)
	if n > 0 {
		o.slots = cast([^]Prop_Slot)mem_alloc(rt, n * size_of(Prop_Slot))
		o.slot_cap = u32(n)
	}
	return o
}

object_new_proto :: proc(ctx: ^Context, proto: ^Object, class: Class_ID = .object) -> ^Object {
	return object_new_shape(ctx.rt, shape_root_for(ctx.rt, proto), class)
}

new_plain_object :: proc(ctx: ^Context) -> ^Object {
	return object_new_proto(ctx, ctx.class_proto[.object])
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
	if o.slots != nil {mem_free(rt, o.slots, int(o.slot_cap) * size_of(Prop_Slot))}
	o.slots = nil
	switch d in o.data {
	case Array_Data:
		if d.values != nil {mem_free(rt, d.values, int(d.cap) * size_of(Value))}
	case Mapped_Args_Data:
		if d.refs != nil {mem_free(rt, d.refs, int(d.count) * size_of(^Var_Ref))}
	case Func_Data:
		if d.var_refs != nil && d.bc != nil {mem_free(rt, d.var_refs, int(d.bc.closure_var_count) * size_of(^Var_Ref))}
	case Native_Data:
		if d.data != nil {mem_free(rt, d.data, int(d.data_len) * size_of(Value))}
	case ^Bound_Data:
		delete(d.args, rt_allocator(rt))
		free(d, rt_allocator(rt))
	case Prim_Data, Date_Data:
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
		if d.data != nil && !d.shared {mem_free(rt, d.data, d.alloc_len)}
		delete(d.views)
		free(d, rt_allocator(rt))
	case ^Typed_Array:
		free(d, rt_allocator(rt))
	case ^Proxy_Data:
		free(d, rt_allocator(rt))
	case ^Promise_Data:
		delete(d.reactions)
		free(d, rt_allocator(rt))
	case ^Coro:
		coro_free(rt, d)
	case ^Iter_State:
		iter_state_free(rt, d)
	case ^Module:
	case ^Disposable_Data:
		delete(d.stack)
		free(d, rt_allocator(rt))
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
		if d.data != nil {mark_values(rt, d.data[:d.data_len])}
	case ^Bound_Data:
		mark_value(rt, d.target)
		mark_value(rt, d.this)
		mark_values(rt, d.args)
	case Prim_Data:
		mark_value(rt, d.v)
	case Date_Data:
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
	using cell:  Cell,
	pvalue:      ^Value, // the live location: into a frame while open, &value once detached
	value:       Value,
	is_detached: bool,
	owner:       ^Object, // the coroutine object whose frame holds the open variable (or nil)
}

var_ref_new_detached :: proc(rt: ^Runtime, v: Value) -> ^Var_Ref {
	vr := cell_new(rt, Var_Ref, .var_ref)
	vr.is_detached = true
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

is_array_value :: proc(ctx: ^Context, v: Value) -> int {
	if v.tag != .object {return 0}
	o := as_obj(v)
	if o.class == .array {return 1}
	if o.class == .proxy {
		pd := o.data.(^Proxy_Data)
		if pd.revoked {throw_type_error(ctx, "revoked proxy"); return -1}
		return is_array_value(ctx, pd.target)
	}
	return 0
}
