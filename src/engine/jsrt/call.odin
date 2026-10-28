package jsrt

// Calls: frames, closures, [[Call]] and [[Construct]] for every callable kind.
//
// An interpreter activation owns one block of Values: arguments (max(argc, arg_count)), locals,
// the operand stack (stack_size) and the closure-cell pointers of captured locals. Ordinary calls
// take that block from segmented value stacks that never move (closure cells may point into them);
// generator and async activations allocate it on the heap so it survives suspension.

Value_Segment :: struct {
	data: []Value,
	top:  int,
}

VSEGMENT_SIZE :: 32 * 1024

Frame :: struct {
	prev:        ^Frame,
	ctx:         ^Context,
	caller_ctx:  ^Context, // the realm that made the call (QuickJS throws a few errors there)
	func:        Value,
	bc:          ^Function_Bytecode,
	this_val:    Value,
	new_target:  Value,
	args:        [^]Value,
	arg_buf_len: int,
	argc:        int,
	locals:      [^]Value,
	stack:       [^]Value,
	sp:          int,
	var_refs:    [^]^Var_Ref,
	pc:          int,
	extra_args:  []Value,
	coro:        ^Object, // the generator/async object owning this frame (heap storage), or nil
	seg_index:   int,
	seg_top:     int,
	storage:     [^]Value, // heap storage of a coroutine frame
	storage_len: int,
	pending_throw: bool, // resume by throwing the pending exception
}

@(private = "file")
frame_slots :: #force_inline proc(b: ^Function_Bytecode, arg_buf_len: int) -> (n_values: int, n_ref_values: int) {
	ref_values := (int(b.var_ref_count) * size_of(rawptr) + size_of(Value) - 1) / size_of(Value)
	return arg_buf_len + int(b.var_count) + int(b.stack_size) + ref_values, ref_values
}

// Lay out a frame's arguments, locals, stack and closure-cell array over `mem`.
@(private = "file")
frame_layout :: proc(f: ^Frame, b: ^Function_Bytecode, mem: [^]Value, args: []Value, arg_buf_len: int) {
	n := len(args)
	for i in 0 ..< n {mem[i] = args[i]}
	total, ref_values := frame_slots(b, arg_buf_len)
	for i in n ..< total - ref_values {mem[i] = UNDEFINED}
	f.args = mem
	f.arg_buf_len = arg_buf_len
	f.argc = n
	f.locals = mem[arg_buf_len:]
	f.stack = mem[arg_buf_len + int(b.var_count):]
	f.sp = 0
	f.var_refs = cast([^]^Var_Ref)&mem[total - ref_values]
	for i in 0 ..< int(b.var_ref_count) {f.var_refs[i] = nil}
	f.bc = b
}

@(private = "file")
vstack_alloc :: #force_inline proc(rt: ^Runtime, n: int) -> (mem: [^]Value, seg: int, top: int) {
	if rt.vstack_cur < len(rt.vstack) {
		s := &rt.vstack[rt.vstack_cur]
		if s.top + n <= len(s.data) {
			mem = raw_data(s.data[s.top:])
			seg = rt.vstack_cur
			top = s.top
			s.top += n
			return
		}
	}
	return vstack_alloc_slow(rt, n)
}

@(private = "file")
vstack_alloc_slow :: proc(rt: ^Runtime, n: int) -> (mem: [^]Value, seg: int, top: int) {
	for {
		if rt.vstack_cur >= len(rt.vstack) {
			size := max(VSEGMENT_SIZE, n)
			append(&rt.vstack, Value_Segment{data = make([]Value, size, rt.allocator)})
		}
		s := &rt.vstack[rt.vstack_cur]
		if s.top + n <= len(s.data) {
			mem = raw_data(s.data[s.top:])
			seg = rt.vstack_cur
			top = s.top
			s.top += n
			return
		}
		if s.top == 0 {
			// a segment too small for this frame: replace it
			delete(s.data, rt.allocator)
			s.data = make([]Value, max(VSEGMENT_SIZE, n), rt.allocator)
			continue
		}
		rt.vstack_cur += 1
		if rt.vstack_cur < len(rt.vstack) {rt.vstack[rt.vstack_cur].top = 0}
	}
}

@(private = "file")
vstack_release :: proc(rt: ^Runtime, seg, top: int) {
	rt.vstack_cur = seg
	rt.vstack[seg].top = top
}

// --- closure cells ---

// The closure cell for local (or argument) `idx` of frame `f`, created on first capture.
get_var_ref :: proc(rt: ^Runtime, f: ^Frame, idx: int, is_arg: bool) -> ^Var_Ref {
	b := f.bc
	vd := &b.vardefs[is_arg ? idx : int(b.arg_count) + idx]
	pv := is_arg ? &f.args[idx] : &f.locals[idx]
	if vd.is_captured {
		k := int(vd.var_ref_idx)
		vr := f.var_refs[k]
		if vr != nil {return vr}
		vr = cell_new(rt, Var_Ref, .var_ref)
		vr.pvalue = pv
		vr.owner = f.coro
		f.var_refs[k] = vr
		return vr
	}
	return var_ref_new_detached(rt, pv^)
}

close_var_ref :: #force_inline proc(vr: ^Var_Ref) {
	if vr.is_detached {return}
	vr.value = vr.pvalue^
	vr.pvalue = &vr.value
	vr.is_detached = true
	vr.owner = nil
}

close_var_refs :: proc(f: ^Frame) {
	if f.bc == nil || f.var_refs == nil {return}
	for i in 0 ..< int(f.bc.var_ref_count) {
		vr := f.var_refs[i]
		if vr != nil {
			close_var_ref(vr)
			f.var_refs[i] = nil
		}
	}
}

close_lexical_var :: proc(f: ^Frame, idx: int) {
	b := f.bc
	k := int(b.vardefs[int(b.arg_count) + idx].var_ref_idx)
	vr := f.var_refs[k]
	if vr != nil {
		close_var_ref(vr)
		f.var_refs[k] = nil
	}
}

// --- function objects ---

function_proto_for_kind :: proc(ctx: ^Context, k: Func_Kind) -> ^Object {
	switch k {
	case .normal: return ctx.function_proto
	case .generator: return ctx.class_proto[.generator_function]
	case .async: return ctx.class_proto[.async_function]
	case .async_generator: return ctx.class_proto[.async_generator_function]
	}
	return ctx.function_proto
}

// Bind `b` to the closure cells it captures from the frame `f` (whose function's cells are `cur`).
closure_bind :: proc(ctx: ^Context, o: ^Object, b: ^Function_Bytecode, cur: [^]^Var_Ref, f: ^Frame) {
	rt := ctx.rt
	fd := Func_Data{bc = b}
	if b.closure_var_count > 0 {
		fd.var_refs = cast([^]^Var_Ref)mem_alloc(rt, int(b.closure_var_count) * size_of(^Var_Ref))
		for i in 0 ..< int(b.closure_var_count) {
			cv := &b.closure_vars[i]
			vr: ^Var_Ref
			#partial switch cv.closure_type {
			case .local:
				vr = get_var_ref(rt, f, int(cv.var_idx), false)
			case .arg:
				vr = get_var_ref(rt, f, int(cv.var_idx), true)
			case:
				if cur != nil {vr = cur[cv.var_idx]}
			}
			if vr == nil {vr = var_ref_new_detached(rt, UNDEFINED)}
			fd.var_refs[i] = vr
		}
	}
	o.data = fd
}

// js_closure: a function object for bytecode `b` created in frame `f`.
make_closure :: proc(ctx: ^Context, b: ^Function_Bytecode, cur: [^]^Var_Ref, f: ^Frame) -> Value {
	rt := ctx.rt
	o := object_new_proto(ctx, function_proto_for_kind(ctx, b.func_kind), .bytecode_function)
	closure_bind(ctx, o, b, cur, f)
	name := b.func_name == ATOM_NULL ? pa(.A_empty_string) : b.func_name
	define_value(ctx, o, pa(.A_length), mk_int(i32(b.defined_arg_count)), {.configurable})
	define_value(ctx, o, pa(.A_name), atom_to_value(rt, name), {.configurable})
	if b.func_kind == .generator || b.func_kind == .async_generator {
		cls: Class_ID = b.func_kind == .async_generator ? .async_generator : .generator
		proto := object_new_proto(ctx, ctx.class_proto[cls])
		define_value(ctx, o, pa(.A_prototype), mk_obj(proto), {.writable})
	} else if b.has_prototype {
		o.is_constructor = true
		proto := new_plain_object(ctx)
		define_value(ctx, proto, pa(.A_constructor), mk_obj(o), CW)
		define_value(ctx, o, pa(.A_prototype), mk_obj(proto), {.writable})
	}
	return mk_obj(o)
}

// A top-level script/eval function: no captured cells.
make_toplevel_function :: proc(ctx: ^Context, b: ^Function_Bytecode) -> Value {
	o := object_new_proto(ctx, function_proto_for_kind(ctx, b.func_kind), .bytecode_function)
	o.data = Func_Data{bc = b}
	if b.closure_var_count > 0 {
		// global references of top-level code resolve through the global object at run time
		fd := &o.data.(Func_Data)
		fd.var_refs = cast([^]^Var_Ref)mem_alloc(ctx.rt, int(b.closure_var_count) * size_of(^Var_Ref))
		for i in 0 ..< int(b.closure_var_count) {fd.var_refs[i] = var_ref_new_detached(ctx.rt, UNDEFINED)}
	}
	return mk_obj(o)
}

set_home_object :: proc(func: Value, home: Value) {
	if func.tag != .object {return}
	o := as_obj(func)
	if fd, ok := &o.data.(Func_Data); ok && fd.bc != nil && fd.bc.need_home_object {
		fd.home = home.tag == .object ? as_obj(home) : nil
	}
}

// A native function object.
new_native_function :: proc(ctx: ^Context, fn: Native_Proc, name: string, length: int, magic: i32 = 0, kind: Native_Kind = .function, proto: ^Object = nil) -> ^Object {
	rt := ctx.rt
	o := object_new_proto(ctx, proto != nil ? proto : ctx.function_proto, .c_function)
	o.data = Native_Data{fn = fn, realm = ctx, magic = magic, kind = kind}
	o.is_constructor = kind != .function
	define_value(ctx, o, pa(.A_length), mk_int(i32(length)), {.configurable})
	define_value(ctx, o, pa(.A_name), mk_str(str_from_utf8(rt, name)), {.configurable})
	return o
}

// A native closure carrying `data` values (read back with native_data()).
new_native_closure :: proc(ctx: ^Context, fn: Native_Proc, name: string, length: int, data: []Value, magic: i32 = 0) -> ^Object {
	o := new_native_function(ctx, fn, name, length, magic)
	nd := &o.data.(Native_Data)
	if len(data) > 0 {
		nd.data = mem_array(ctx.rt, Value, len(data))
		for v, i in data {nd.data[i] = v}
		nd.data_len = u32(len(data))
	}
	return o
}

// Unnamed native closure (name ""): resolving functions, etc.
new_native_anon :: proc(ctx: ^Context, fn: Native_Proc, length: int, data: []Value, magic: i32 = 0) -> ^Object {
	return new_native_closure(ctx, fn, "", length, data, magic)
}

// The data of the native function currently executing.
native_data :: proc(ctx: ^Context) -> []Value {
	f := ctx.rt.native_self
	if f == nil {return nil}
	nd := &f.data.(Native_Data)
	return nd.data[:nd.data_len]
}

arg :: #force_inline proc "contextless" (args: []Value, i: int) -> Value {
	if i < len(args) {return args[i]}
	return UNDEFINED
}

// --- [[Call]] / [[Construct]] ---

call :: proc(ctx: ^Context, f: Value, this: Value, args: []Value) -> Value {
	r := call_internal(ctx, f, this, UNDEFINED, args, false)
	root(ctx.rt, r)
	return r
}

// Construct(F, args, newTarget).
construct :: proc(ctx: ^Context, f: Value, args: []Value, new_target: Value) -> Value {
	if !is_constructor(f) {return throw_type_error(ctx, "not a constructor")}
	r := call_internal(ctx, f, UNDEFINED, new_target, args, true)
	root(ctx.rt, r)
	return r
}

stack_overflow :: proc(ctx: ^Context) -> Value {
	return throw_range_error(ctx, "Maximum call stack size exceeded")
}

call_internal :: proc(ctx: ^Context, f: Value, this: Value, new_target: Value, args: []Value, is_construct: bool) -> Value {
	rt := ctx.rt
	if f.tag != .object {return throw_not_a_function(ctx)}
	o := as_obj(f)
	if rt.stack_depth >= rt.config.max_stack_depth || stack_exhausted(rt) {return stack_overflow(ctx)}
	#partial switch o.class {
	case .bytecode_function:
		fd := &o.data.(Func_Data)
		b := fd.bc
		switch b.func_kind {
		case .normal:
			if !is_construct {return interp_call(ctx, o, this, UNDEFINED, args)}
			if b.is_derived_class_ctor {
				return interp_call(ctx, o, UNDEFINED, new_target, args)
			}
			obj := create_from_ctor(ctx, new_target, .object)
			if is_exception(obj) {return EXCEPTION}
			root(rt, obj)
			r := interp_call(ctx, o, obj, new_target, args)
			if is_exception(r) {return EXCEPTION}
			if r.tag == .object {return r}
			return obj
		case .generator:
			if is_construct {return throw_type_error(ctx, "not a constructor")}
			return generator_function_call(ctx, o, this, args)
		case .async:
			if is_construct {return throw_type_error(ctx, "not a constructor")}
			return async_function_call(ctx, o, this, args)
		case .async_generator:
			if is_construct {return throw_type_error(ctx, "not a constructor")}
			return async_generator_function_call(ctx, o, this, args)
		}
	case .c_function:
		nd := &o.data.(Native_Data)
		t := this
		switch nd.kind {
		case .function:
			if is_construct {return throw_type_error(ctx, "not a constructor")}
		case .constructor:
			t = is_construct ? new_target : UNDEFINED
		case .constructor_only:
			if !is_construct {return throw_type_error(ctx, "constructor requires 'new'")}
			t = new_target
		}
		return call_native(ctx, o, nd, t, args)
	case .bound_function:
		bd := o.data.(^Bound_Data)
		full := make([]Value, len(bd.args) + len(args), tmp(rt))
		copy(full, bd.args)
		copy(full[len(bd.args):], args)
		if is_construct {
			nt := new_target
			if nt.tag == .object && as_obj(nt) == o {nt = bd.target}
			return call_internal(ctx, bd.target, UNDEFINED, nt, full, true)
		}
		rt.stack_depth += 1
		defer rt.stack_depth -= 1
		return call_internal(ctx, bd.target, bd.this, UNDEFINED, full, false)
	case .proxy:
		pd := o.data.(^Proxy_Data)
		if !pd.is_func {return throw_not_a_function(ctx)}
		if is_construct {return proxy_construct(ctx, o, args, new_target)}
		return proxy_call(ctx, o, this, args)
	}
	return throw_not_a_function(ctx)
}

call_native :: proc(ctx: ^Context, o: ^Object, nd: ^Native_Data, this: Value, args: []Value) -> Value {
	rt := ctx.rt
	realm := nd.realm != nil ? nd.realm : ctx
	m := temp_mark(rt)
	if !gc_safepoint(ctx) {return EXCEPTION}
	saved := rt.native_self
	rt.native_self = o
	when JSRT_TRACE_LAST_OP {trace_native = nd.fn; trace_native_obj = o; trace_native_args = args}
	rt.stack_depth += 1
	r := nd.fn(realm, this, args, nd.magic)
	rt.stack_depth -= 1
	rt.native_self = saved
	temp_reset(rt, m)
	return r
}

// OrdinaryCreateFromConstructor / js_create_from_ctor: an object whose prototype is
// newTarget.prototype (falling back to the realm's intrinsic for `class`).
create_from_ctor :: proc(ctx: ^Context, new_target: Value, class: Class_ID) -> Value {
	proto, ok := proto_from_ctor(ctx, new_target, class)
	if !ok {return EXCEPTION}
	return mk_obj(object_new_proto(ctx, proto, class))
}

proto_from_ctor :: proc(ctx: ^Context, new_target: Value, class: Class_ID) -> (^Object, bool) {
	if is_undefined(new_target) {return ctx.class_proto[class], true}
	p := get(ctx, new_target, pa(.A_prototype))
	if is_exception(p) {return nil, false}
	if p.tag == .object {return as_obj(p), true}
	realm := function_realm(ctx, new_target)
	if realm == nil {return nil, false}
	return realm.class_proto[class], true
}

// Like proto_from_ctor but for a native-error / constructor whose intrinsic is not a class_proto.
proto_from_ctor_intrinsic :: proc(ctx: ^Context, new_target: Value, pick: proc(c: ^Context) -> ^Object) -> (^Object, bool) {
	if is_undefined(new_target) {return pick(ctx), true}
	p := get(ctx, new_target, pa(.A_prototype))
	if is_exception(p) {return nil, false}
	if p.tag == .object {return as_obj(p), true}
	realm := function_realm(ctx, new_target)
	if realm == nil {return nil, false}
	return pick(realm), true
}

// GetFunctionRealm.
function_realm :: proc(ctx: ^Context, f: Value) -> ^Context {
	if f.tag != .object {return ctx}
	o := as_obj(f)
	#partial switch o.class {
	case .c_function:
		return o.data.(Native_Data).realm
	case .bytecode_function:
		b := o.data.(Func_Data).bc
		if b != nil && b.realm != nil {return b.realm}
	case .proxy:
		pd := o.data.(^Proxy_Data)
		if pd.revoked {
			throw_type_error(ctx, "revoked proxy")
			return nil
		}
		return function_realm(ctx, pd.target)
	case .bound_function:
		return function_realm(ctx, o.data.(^Bound_Data).target)
	}
	return ctx
}

// --- interpreter activation ---

interp_call :: proc(ctx: ^Context, fo: ^Object, this: Value, new_target: Value, args: []Value) -> Value {
	rt := ctx.rt
	fd := &fo.data.(Func_Data)
	b := fd.bc
	realm := b.realm != nil ? b.realm : ctx
	arg_buf_len := max(len(args), int(b.arg_count))
	total, _ := frame_slots(b, arg_buf_len)
	mem, seg, top := vstack_alloc(rt, total)
	// every field is set below: no zeroing of the 200-byte frame
	f: Frame = ---
	f.ctx = realm
	f.caller_ctx = ctx
	f.func = mk_obj(fo)
	f.this_val = this
	f.new_target = new_target
	f.pc = 0
	f.extra_args = nil
	f.coro = nil
	f.seg_index = seg
	f.seg_top = top
	f.storage = nil
	f.storage_len = 0
	f.pending_throw = false
	frame_layout(&f, b, mem, args, arg_buf_len)
	f.prev = rt.cur_frame
	rt.cur_frame = &f
	rt.stack_depth += 1
	r, _ := interp_run(realm, &f, fd.var_refs)
	rt.stack_depth -= 1
	rt.cur_frame = f.prev
	if b.var_ref_count > 0 {close_var_refs(&f)}
	vstack_release(rt, seg, top)
	return r
}

// A heap frame for a coroutine (generator / async function), initialised but not started.
coro_frame_new :: proc(ctx: ^Context, fo: ^Object, this: Value, args: []Value) -> ^Frame {
	rt := ctx.rt
	fd := &fo.data.(Func_Data)
	b := fd.bc
	realm := b.realm != nil ? b.realm : ctx
	arg_buf_len := max(len(args), int(b.arg_count))
	total, _ := frame_slots(b, arg_buf_len)
	f := new(Frame, rt_allocator(rt))
	mem := mem_array(rt, Value, max(total, 1))
	f.storage = mem
	f.storage_len = max(total, 1)
	f.ctx = realm
	f.caller_ctx = ctx
	f.func = mk_obj(fo)
	f.this_val = this
	f.new_target = UNDEFINED
	f.seg_index = -1
	frame_layout(f, b, mem, args, arg_buf_len)
	return f
}

coro_frame_free :: proc(rt: ^Runtime, f: ^Frame) {
	if f == nil {return}
	close_var_refs(f)
	if f.storage != nil {mem_free(rt, f.storage, f.storage_len * size_of(Value))}
	free(f, rt_allocator(rt))
}

// Resume a suspended coroutine frame until it yields, awaits, returns or throws.
coro_resume :: proc(ctx: ^Context, f: ^Frame) -> (Value, Exit_Kind) {
	rt := ctx.rt
	if rt.stack_depth >= rt.config.max_stack_depth || stack_exhausted(rt) {
		stack_overflow(ctx)
		return EXCEPTION, .exception
	}
	fd := &as_obj(f.func).data.(Func_Data)
	f.prev = rt.cur_frame
	rt.cur_frame = f
	rt.stack_depth += 1
	r, k := interp_run(f.ctx, f, fd.var_refs)
	rt.stack_depth -= 1
	rt.cur_frame = f.prev
	f.prev = nil
	return r, k
}
