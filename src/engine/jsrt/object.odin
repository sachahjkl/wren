package jsrt

// JavaScript objects.
//
// An Object is a GC cell with a Shape (its hidden class, giving the ordered property layout) and a
// flat array of property values addressed by the shape's slots. The `exotic` tagged union carries the
// internal state of exotic object kinds (Array, Function, the primitive wrappers, TypedArray, Proxy,
// ...) without a separate allocation. This is the one struct the interpreter and every builtin touch,
// so it is laid out to keep the ordinary "plain object property get/set" path tight.
//
// Property values live in `props[slot]`. An accessor slot stores a ^Accessor instead of a plain value
// (distinguished by the shape's Prop_Flag.accessor). Array elements for the dense fast path live in
// the exotic Array state, not in the shape, so pushing numbers never grows the shape.

import "wb:engine/bigint"

Object :: struct {
	using header: GC_Header,
	shape:        ^Shape,
	props:        [dynamic]Value, // indexed by Shape_Prop.slot
	extensible:   bool,
	exotic:       Exotic,
}

// The internal slots that distinguish exotic objects. `none` is an ordinary object.
Exotic :: union {
	Array_Data,
	Function_Data,
	Native_Data,
	Bound_Function_Data,
	Primitive_Wrapper,
	Array_Buffer_Data,
	Typed_Array_Data,
	Data_View_Data,
	Map_Data,
	Set_Data,
	Proxy_Data,
	Date_Data,
	RegExp_Data,
	Error_Data,
	Iterator_Data,
	Promise_Data,
	Generator_Data,
	Namespace_Data,
}

// An accessor property's getter/setter (either may be nil / undefined).
Accessor :: struct {
	using header: GC_Header,
	get:          Value,
	set:          Value,
}

// --- exotic payloads ---

// Dense/sparse Array. Small-integer-indexed storage lives in `dense`; when the array becomes sparse
// (a large gap, or a non-index numeric key) the elements migrate to ordinary shape properties and
// `sparse` is set so writes stop touching `dense`.
Array_Data :: struct {
	dense:  [dynamic]Value,
	length: u32,
	sparse: bool,
}

// An interpreted function: its bytecode plus the captured upvalues and the realm it closes over.
Function_Data :: struct {
	bc:        ^Function_Bytecode,
	var_refs:  []^Var_Ref, // closure upvalues, one per bc.closure_var
	home:      Value,       // [[HomeObject]] for super, or undefined
	realm:     ^Realm,
}

Bound_Function_Data :: struct {
	target:     Value,
	this_val:   Value,
	bound_args: []Value,
}

// A native function implemented in Odin (host builtins and the embedding API). Stored as the exotic
// payload of an ordinary callable object so it shares the prototype/property machinery.
Native_Data :: struct {
	fn:     Native_Proc,
	magic:  i32,
	ctor:   bool,
	realm:  ^Realm,
	data:   []Value, // bound captured values for native closures
}

Native_Proc :: #type proc(ctx: ^Context, this: Value, args: []Value, magic: i32, data: []Value) -> Value

Primitive_Wrapper :: struct {
	prim: Value, // the wrapped Boolean/Number/String/Symbol/BigInt primitive
}

Array_Buffer_Data :: struct {
	bytes:        []u8,
	detached:     bool,
	shared:       bool,
	max_byte_len: int, // -1 if not resizable
}

Typed_Array_Element :: enum u8 {
	u8_clamped, i8, u8, i16, u16, i32, u32, bi64, bu64, f16, f32, f64,
}

Typed_Array_Data :: struct {
	buffer:       Value, // the backing ArrayBuffer object
	kind:         Typed_Array_Element,
	byte_offset:  int,
	length:       int, // element count
	track_rab:    bool, // length-tracking view on a resizable buffer
}

Data_View_Data :: struct {
	buffer:      Value,
	byte_offset: int,
	byte_length: int,
	track_rab:   bool,
}

// Map/Set use insertion-ordered hash tables. Entries keep deletion tombstones to preserve iterator
// semantics; a periodic compaction (not every delete) reclaims them.
Map_Data :: struct {
	entries: [dynamic]Map_Entry,
	index:   map[Map_Key]int, // key -> live entry index
	is_weak: bool,
}

Map_Entry :: struct {
	key:     Value,
	val:     Value,
	deleted: bool,
}

Set_Data :: struct {
	entries: [dynamic]Value,
	index:   map[Map_Key]int,
	is_weak: bool,
}

// A hashable projection of a Value used as a Map/Set key under SameValueZero.
Map_Key :: struct {
	tag: Tag,
	bits: u64, // f64 bits, i32, bool, or a cell pointer as uintptr
}

Proxy_Data :: struct {
	target:  Value,
	handler: Value,
	revoked: bool,
}

Date_Data :: struct {
	time: f64, // milliseconds since the epoch, NaN for an invalid Date
}

RegExp_Data :: struct {
	bytecode: []u8, // compiled by src/engine/regexp
	source:   ^JS_String,
	flags:    u32,
}

Error_Data :: struct {
	// Errors are ordinary objects; this slot only tags them so stack capture and host bridging can
	// recognise an Error without a prototype walk.
	kind: Error_Kind,
}

Error_Kind :: enum u8 {
	plain, eval, range, reference, syntax, type, uri, internal, aggregate, suppressed,
}

Iterator_Data :: struct {
	kind:   Iterator_Kind,
	target: Value,
	pos:    u32,
	done:   bool,
}

Iterator_Kind :: enum u8 {
	array_keys, array_values, array_entries, string_chars, map_entries, set_values, regexp,
}

Promise_Data :: struct {
	state:        Promise_State,
	result:       Value,
	fulfill_jobs: [dynamic]Promise_Reaction,
	reject_jobs:  [dynamic]Promise_Reaction,
	handled:      bool,
}

Promise_State :: enum u8 {pending, fulfilled, rejected}

Promise_Reaction :: struct {
	handler: Value, // the onFulfilled/onRejected, or undefined
	capability_resolve: Value,
	capability_reject:  Value,
}

Generator_Data :: struct {
	frame: rawptr, // ^Call_Frame captured across yields; owned by the generator
	state: Generator_State,
	is_async: bool,
}

Generator_State :: enum u8 {suspended_start, suspended_yield, executing, completed}

Namespace_Data :: struct {
	module: rawptr, // ^Module
}

// --- construction ---

// A plain object with the given prototype (nil for a null prototype). Starts at the empty shape.
object_new :: proc(rt: ^Runtime, proto: ^Object) -> ^Object {
	obj := gc_new_cell(rt, Object, .object)
	if obj == nil {return nil}
	obj.shape = shape_empty(rt, proto)
	obj.props = make([dynamic]Value, rt.allocator)
	obj.extensible = true
	return obj
}

// A plain object using an already-built shape (shares the hidden class). Adds a shape reference.
object_with_shape :: proc(rt: ^Runtime, shape: ^Shape) -> ^Object {
	obj := gc_new_cell(rt, Object, .object)
	if obj == nil {return nil}
	obj.shape = shape_ref(shape)
	obj.props = make([dynamic]Value, len(shape.props), rt.allocator)
	for i in 0 ..< len(shape.props) {obj.props[i] = UNDEFINED}
	obj.extensible = true
	return obj
}

object_ref :: proc(obj: ^Object) -> ^Object {
	obj.ref_count += 1
	return obj
}

object_unref :: proc(rt: ^Runtime, obj: ^Object) {
	obj.ref_count -= 1
	if obj.ref_count == 0 {gc_free_cell(rt, obj)}
}

object_destroy :: proc(rt: ^Runtime, obj: ^Object) {
	// Clear outgoing edges first so a cycle sweep freeing several cells does not re-enter a
	// half-freed child. We drop property values, the shape, and any exotic-held references.
	for v in obj.props {
		value_free(rt, v)
	}
	delete(obj.props)
	obj.props = nil
	exotic_destroy(rt, obj)
	if obj.shape != nil {
		shape_unref(rt, obj.shape)
		obj.shape = nil
	}
	gc_raw_free(rt, obj, size_of(Object))
}

// Free the references an exotic payload owns.
exotic_destroy :: proc(rt: ^Runtime, obj: ^Object) {
	switch &e in obj.exotic {
	case Array_Data:
		for v in e.dense {value_free(rt, v)}
		delete(e.dense)
	case Function_Data:
		for vr in e.var_refs {
			if vr != nil {var_ref_unref(rt, vr)}
		}
		if e.var_refs != nil {delete(e.var_refs, rt.allocator)}
		if e.bc != nil {function_bc_unref(rt, e.bc)}
		value_free(rt, e.home)
	case Native_Data:
		for v in e.data {value_free(rt, v)}
		if e.data != nil {delete(e.data, rt.allocator)}
	case Bound_Function_Data:
		value_free(rt, e.target)
		value_free(rt, e.this_val)
		for v in e.bound_args {value_free(rt, v)}
		if e.bound_args != nil {delete(e.bound_args, rt.allocator)}
	case Primitive_Wrapper:
		value_free(rt, e.prim)
	case Array_Buffer_Data:
		if e.bytes != nil {gc_raw_free(rt, raw_data(e.bytes), len(e.bytes))}
	case Typed_Array_Data:
		value_free(rt, e.buffer)
	case Data_View_Data:
		value_free(rt, e.buffer)
	case Map_Data:
		for en in e.entries {value_free(rt, en.key); value_free(rt, en.val)}
		delete(e.entries)
		delete(e.index)
	case Set_Data:
		for v in e.entries {value_free(rt, v)}
		delete(e.entries)
		delete(e.index)
	case Proxy_Data:
		value_free(rt, e.target)
		value_free(rt, e.handler)
	case Date_Data:
	case RegExp_Data:
		if e.bytecode != nil {gc_raw_free(rt, raw_data(e.bytecode), len(e.bytecode))}
		if e.source != nil {string_unref(rt, e.source)}
	case Error_Data:
	case Iterator_Data:
		value_free(rt, e.target)
	case Promise_Data:
		value_free(rt, e.result)
		for r in e.fulfill_jobs {promise_reaction_free(rt, r)}
		for r in e.reject_jobs {promise_reaction_free(rt, r)}
		delete(e.fulfill_jobs)
		delete(e.reject_jobs)
	case Generator_Data:
		if e.frame != nil {frame_free(rt, cast(^Call_Frame)e.frame)}
	case Namespace_Data:
	}
}

promise_reaction_free :: proc(rt: ^Runtime, r: Promise_Reaction) {
	value_free(rt, r.handler)
	value_free(rt, r.capability_resolve)
	value_free(rt, r.capability_reject)
}

// --- the cycle collector's view of a cell's outgoing references ---
//
// Called by gc.odin for every cyclic cell. It must visit exactly the heap cells this cell holds a
// strong reference to. WeakRef / WeakMap keys are intentionally NOT visited.
gc_visit_children :: proc(h: ^GC_Header, visit: proc(child: ^GC_Header)) {
	switch h.kind {
	case .object:
		obj := cast(^Object)h
		if obj.shape != nil {visit(cast(^GC_Header)obj.shape)}
		for v in obj.props {
			if is_heap(v) {visit(as_header(v))}
		}
		gc_visit_exotic(obj, visit)
	case .function_bc:
		fb := cast(^Function_Bytecode)h
		for v in fb.cpool {
			if is_heap(v) {visit(as_header(v))}
		}
	case .var_ref:
		vr := cast(^Var_Ref)h
		if is_heap(vr.value) {visit(as_header(vr.value))}
	case .string, .symbol, .bigint, .shape:
		// Shapes reference their prototype object; include it so a proto cycle is collectable.
		if h.kind == .shape {
			sh := cast(^Shape)h
			if sh.proto != nil {visit(cast(^GC_Header)sh.proto)}
		}
	}
}

@(private = "file")
gc_visit_exotic :: proc(obj: ^Object, visit: proc(child: ^GC_Header)) {
	switch &e in obj.exotic {
	case Array_Data:
		for v in e.dense {
			if is_heap(v) {visit(as_header(v))}
		}
	case Function_Data:
		if e.bc != nil {visit(cast(^GC_Header)e.bc)}
		for vr in e.var_refs {
			if vr != nil {visit(cast(^GC_Header)vr)}
		}
		if is_heap(e.home) {visit(as_header(e.home))}
	case Native_Data:
		for v in e.data {
			if is_heap(v) {visit(as_header(v))}
		}
	case Bound_Function_Data:
		if is_heap(e.target) {visit(as_header(e.target))}
		if is_heap(e.this_val) {visit(as_header(e.this_val))}
		for v in e.bound_args {
			if is_heap(v) {visit(as_header(v))}
		}
	case Primitive_Wrapper:
		if is_heap(e.prim) {visit(as_header(e.prim))}
	case Typed_Array_Data:
		if is_heap(e.buffer) {visit(as_header(e.buffer))}
	case Data_View_Data:
		if is_heap(e.buffer) {visit(as_header(e.buffer))}
	case Map_Data:
		if !e.is_weak {
			for en in e.entries {
				if is_heap(en.key) {visit(as_header(en.key))}
				if is_heap(en.val) {visit(as_header(en.val))}
			}
		}
	case Set_Data:
		if !e.is_weak {
			for v in e.entries {
				if is_heap(v) {visit(as_header(v))}
			}
		}
	case Proxy_Data:
		if is_heap(e.target) {visit(as_header(e.target))}
		if is_heap(e.handler) {visit(as_header(e.handler))}
	case Promise_Data:
		if is_heap(e.result) {visit(as_header(e.result))}
	case Iterator_Data:
		if is_heap(e.target) {visit(as_header(e.target))}
	case Array_Buffer_Data, Date_Data, RegExp_Data, Error_Data, Generator_Data, Namespace_Data:
	// No strong Value references to visit for these: ArrayBuffer owns raw bytes, RegExp/Date are
	// scalar, generator frames are reached through their own cells, namespaces through the module.
	}
}

// --- BigInt helper used across the object layer ---

// Compare two bigint cells; thin wrapper so callers do not import the bigint package directly.
bigint_cmp_cells :: proc(a, b: ^JS_BigInt) -> int {
	return bigint.cmp(a.val, b.val)
}
