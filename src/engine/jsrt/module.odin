package jsrt

// ECMAScript modules: records read from bytecode, linking (export resolution, binding of imports to
// the exporters' closure cells), evaluation with top-level await (the spec's InnerModuleEvaluation
// as QuickJS-ng implements it), namespace objects, dynamic import() and import.meta.

Module_Status :: enum u8 {unlinked, linking, linked, evaluating, evaluating_async, evaluated}

Req_Entry :: struct {
	name:       Atom,
	module:     ^Module,
	attributes: Value,
}

Export_Entry :: struct {
	kind:        u8, // 0 local, 1 indirect
	var_idx:     int,
	req_idx:     int,
	local_name:  Atom,
	export_name: Atom,
	var_ref:     ^Var_Ref,
}

Import_Entry :: struct {
	var_idx:     int,
	import_name: Atom,
	req_idx:     int,
}

Module :: struct {
	using cell:      Cell,
	name:            Atom,
	ctx:             ^Context,
	req:             [dynamic]Req_Entry,
	exports:         [dynamic]Export_Entry,
	star_exports:    [dynamic]int,
	imports:         [dynamic]Import_Entry,
	has_tla:         bool,
	func_bc:         ^Function_Bytecode,
	func_obj:        ^Object,
	namespace:       ^Object,
	meta:            Value,
	status:          Module_Status,
	resolved:        bool,
	func_created:    bool,
	dfs_index:       int,
	dfs_ancestor:    int,
	stack_prev:      ^Module,
	cycle_root:      ^Module,
	async_parents:   [dynamic]^Module,
	pending_async:   int,
	async_evaluation: bool,
	async_ts:        i64,
	has_eval_exception: bool,
	eval_exception:  Value,
	promise:         Value,
	resolve:         Value,
	reject:          Value,
	host_data:       rawptr,
}

module_new :: proc(ctx: ^Context, name: Atom) -> ^Module {
	rt := ctx.rt
	m := cell_new(rt, Module, .module)
	m.name = name
	m.ctx = ctx
	a := rt_allocator(rt)
	m.req = make([dynamic]Req_Entry, a)
	m.exports = make([dynamic]Export_Entry, a)
	m.star_exports = make([dynamic]int, a)
	m.imports = make([dynamic]Import_Entry, a)
	m.async_parents = make([dynamic]^Module, a)
	m.meta = UNDEFINED
	m.eval_exception = UNDEFINED
	m.promise = UNDEFINED
	m.resolve = UNDEFINED
	m.reject = UNDEFINED
	return m
}

module_finalize :: proc(rt: ^Runtime, m: ^Module) {
	delete(m.req)
	delete(m.exports)
	delete(m.star_exports)
	delete(m.imports)
	delete(m.async_parents)
}

module_trace :: proc(rt: ^Runtime, m: ^Module) {
	for &r in m.req {
		mark_cell(rt, r.module)
		mark_value(rt, r.attributes)
	}
	for &e in m.exports {mark_cell(rt, e.var_ref)}
	mark_cell(rt, m.func_bc)
	mark_cell(rt, m.func_obj)
	mark_cell(rt, m.namespace)
	mark_value(rt, m.meta)
	mark_cell(rt, m.stack_prev)
	mark_cell(rt, m.cycle_root)
	for p in m.async_parents {mark_cell(rt, p)}
	mark_value(rt, m.eval_exception)
	mark_value(rt, m.promise)
	mark_value(rt, m.resolve)
	mark_value(rt, m.reject)
}

module_register :: proc(rt: ^Runtime, m: ^Module) {
	for x in rt.modules {if x == m {return}}
	append(&rt.modules, m)
}

find_module_by_name :: proc(rt: ^Runtime, name: Atom) -> ^Module {
	for m in rt.modules {if m.name == name {return m}}
	return nil
}

// HostLoadImportedModule through the embedding hook.
@(private = "file")
host_load :: proc(ctx: ^Context, referrer: Atom, spec: Atom) -> ^Module {
	rt := ctx.rt
	if rt.config.load_module == nil {
		throw_reference_error(ctx, cat(ctx, "could not load module '", atom_utf8(rt, spec), "'"))
		return nil
	}
	v := rt.config.load_module(ctx, atom_utf8(rt, referrer), atom_utf8(rt, spec), rt.config.load_user)
	if is_exception(v) {return nil}
	if v.tag != .module {
		throw_type_error(ctx, "module loader did not return a module")
		return nil
	}
	m := cast(^Module)v.u.ptr
	module_register(rt, m)
	return m
}

// Load every requested module, transitively.
module_resolve :: proc(ctx: ^Context, m: ^Module) -> bool {
	if m.resolved {return true}
	m.resolved = true
	for &r in m.req {
		m1 := host_load(ctx, m.name, r.name)
		if m1 == nil {
			m.resolved = false
			return false
		}
		r.module = m1
		if !module_resolve(ctx, m1) {return false}
	}
	return true
}

@(private = "file")
find_export :: proc(m: ^Module, name: Atom) -> ^Export_Entry {
	for &e in m.exports {if e.export_name == name {return &e}}
	return nil
}

Resolve_Result :: enum u8 {found, not_found, circular, ambiguous}

@(private = "file")
Resolve_Set :: [dynamic]struct {
	m:    ^Module,
	name: Atom,
}

@(private = "file")
resolve_export1 :: proc(m: ^Module, name: Atom, s: ^Resolve_Set) -> (Resolve_Result, ^Module, ^Export_Entry) {
	for e in s {if e.m == m && e.name == name {return .circular, nil, nil}}
	append(s, struct {m: ^Module, name: Atom}{m, name})
	if me := find_export(m, name); me != nil {
		if me.kind == 0 {return .found, m, me}
		if me.local_name == pa(.A__star_) {return .found, m, me}
		return resolve_export1(m.req[me.req_idx].module, me.local_name, s)
	}
	if name == pa(.A_default) {return .not_found, nil, nil}
	res_m: ^Module
	res_e: ^Export_Entry
	for k in m.star_exports {
		r, rm, re := resolve_export1(m.req[k].module, name, s)
		if r == .ambiguous {return .ambiguous, nil, nil}
		if r == .found {
			if res_e != nil {
				if res_m != rm || re.local_name != res_e.local_name || (re.kind == 0 && res_e.kind == 0 && re.var_idx != res_e.var_idx) {
					return .ambiguous, nil, nil
				}
			} else {
				res_m, res_e = rm, re
			}
		}
	}
	if res_e != nil {return .found, res_m, res_e}
	return .not_found, nil, nil
}

resolve_export :: proc(ctx: ^Context, m: ^Module, name: Atom) -> (Resolve_Result, ^Module, ^Export_Entry) {
	s := make(Resolve_Set, 0, 8, tmp(ctx.rt))
	return resolve_export1(m, name, &s)
}

@(private = "file")
throw_resolve_error :: proc(ctx: ^Context, res: Resolve_Result, m: ^Module, name: Atom) {
	rt := ctx.rt
	n := atom_utf8(rt, name)
	mn := atom_utf8(rt, m.name)
	#partial switch res {
	case .circular:
		throw_syntax_error(ctx, cat(ctx, "circular reference when looking for export '", n, "' in module '", mn, "'"))
	case .ambiguous:
		throw_syntax_error(ctx, cat(ctx, "export '", n, "' in module '", mn, "' is ambiguous"))
	case:
		throw_syntax_error(ctx, cat(ctx, "Could not find export '", n, "' in module '", mn, "'"))
	}
}

// The closure cell of a local export (following import aliases of re-exported imports).
@(private = "file")
local_export_ref :: proc(ctx: ^Context, m: ^Module, me: ^Export_Entry, depth := 0) -> ^Var_Ref {
	if me.var_ref != nil {return me.var_ref}
	if m.func_obj != nil {
		fd := m.func_obj.data.(Func_Data)
		if fd.var_refs != nil && fd.var_refs[me.var_idx] != nil {return fd.var_refs[me.var_idx]}
	}
	if depth > 100 {return nil}
	for &mi in m.imports {
		if mi.var_idx != me.var_idx {continue}
		m1 := m.req[mi.req_idx].module
		r, rm, re := resolve_export(ctx, m1, mi.import_name)
		if r == .found && re.local_name != pa(.A__star_) {return local_export_ref(ctx, rm, re, depth + 1)}
		break
	}
	return nil
}

@(private = "file")
create_module_function :: proc(ctx: ^Context, m: ^Module) {
	if m.func_created {return}
	m.func_created = true
	rt := ctx.rt
	b := m.func_bc
	fo := object_new_proto(ctx, ctx.function_proto, .bytecode_function)
	fd := Func_Data{bc = b}
	if b.closure_var_count > 0 {
		fd.var_refs = cast([^]^Var_Ref)mem_alloc(rt, int(b.closure_var_count) * size_of(^Var_Ref))
		for i in 0 ..< int(b.closure_var_count) {
			cv := &b.closure_vars[i]
			if cv.closure_type == .module_decl {
				fd.var_refs[i] = var_ref_new_detached(rt, cv.is_lexical ? UNINITIALIZED : UNDEFINED)
			}
		}
	}
	fo.data = fd
	m.func_obj = fo
	for &r in m.req {create_module_function(ctx, r.module)}
}

@(private = "file")
inner_link :: proc(ctx: ^Context, m: ^Module, stack_top: ^^Module, index: int) -> int {
	rt := ctx.rt
	idx := index
	if rt.stack_depth > rt.config.max_stack_depth {
		stack_overflow(ctx)
		return -1
	}
	if m.status != .unlinked {return idx}
	m.status = .linking
	m.dfs_index = idx
	m.dfs_ancestor = idx
	idx += 1
	m.stack_prev = stack_top^
	stack_top^ = m
	for &r in m.req {
		m1 := r.module
		idx = inner_link(ctx, m1, stack_top, idx)
		if idx < 0 {return -1}
		if m1.status == .linking {m.dfs_ancestor = min(m.dfs_ancestor, m1.dfs_ancestor)}
	}
	for &me in m.exports {
		if me.kind == 1 && me.local_name != pa(.A__star_) {
			m1 := m.req[me.req_idx].module
			r, _, _ := resolve_export(ctx, m1, me.local_name)
			if r != .found {
				throw_resolve_error(ctx, r, m1, me.local_name)
				return -1
			}
		}
	}
	fd := &m.func_obj.data.(Func_Data)
	for &mi in m.imports {
		m1 := m.req[mi.req_idx].module
		if mi.import_name == pa(.A__star_) {
			ns := module_namespace(ctx, m1)
			if is_exception(ns) {return -1}
			fd.var_refs[mi.var_idx] = var_ref_new_detached(rt, ns)
			continue
		}
		r, rm, re := resolve_export(ctx, m1, mi.import_name)
		if r != .found {
			throw_resolve_error(ctx, r, m1, mi.import_name)
			return -1
		}
		if re.local_name == pa(.A__star_) {
			ns := module_namespace(ctx, rm.req[re.req_idx].module)
			if is_exception(ns) {return -1}
			fd.var_refs[mi.var_idx] = var_ref_new_detached(rt, ns)
		} else {
			vr := local_export_ref(ctx, rm, re)
			if vr == nil {
				throw_syntax_error(ctx, cat(ctx, "circular import: binding '", atom_utf8(rt, mi.import_name), "' is not resolvable in module '", atom_utf8(rt, rm.name), "'"))
				return -1
			}
			fd.var_refs[mi.var_idx] = vr
		}
	}
	for &me in m.exports {
		if me.kind == 0 {me.var_ref = fd.var_refs[me.var_idx]}
	}
	// instantiate the hoisted function declarations
	r := call_internal(ctx, mk_obj(m.func_obj), TRUE, UNDEFINED, {}, false)
	if is_exception(r) {return -1}
	if m.dfs_index == m.dfs_ancestor {
		for {
			m1 := stack_top^
			stack_top^ = m1.stack_prev
			m1.status = .linked
			if m1 == m {break}
		}
	}
	return idx
}

module_link :: proc(ctx: ^Context, m: ^Module) -> bool {
	if !module_resolve(ctx, m) {return false}
	create_module_function(ctx, m)
	stack_top: ^Module
	if inner_link(ctx, m, &stack_top, 0) < 0 {
		for stack_top != nil {
			m1 := stack_top
			m1.status = .unlinked
			stack_top = m1.stack_prev
		}
		return false
	}
	return true
}

// --- namespaces ---

module_namespace :: proc(ctx: ^Context, m: ^Module) -> Value {
	if m.namespace != nil {return mk_obj(m.namespace)}
	rt := ctx.rt
	ns := object_new_proto(ctx, nil, .module_ns)
	ns.data = m
	m.namespace = ns
	// exported names (star exports skip "default"; duplicates resolved later)
	names := make([dynamic]Atom, 0, 16, tmp(rt))
	visited := make([dynamic]^Module, 0, 8, tmp(rt))
	collect :: proc(m: ^Module, from_star: bool, names: ^[dynamic]Atom, visited: ^[dynamic]^Module) {
		for v in visited {if v == m {return}}
		append(visited, m)
		for &e in m.exports {
			if from_star && e.export_name == pa(.A_default) {continue}
			found := false
			for n in names {if n == e.export_name {found = true; break}}
			if !found {append(names, e.export_name)}
		}
		for k in m.star_exports {collect(m.req[k].module, true, names, visited)}
	}
	collect(m, false, &names, &visited)
	Entry :: struct {
		name: Atom,
		ref:  ^Var_Ref,
		ns:   ^Module,
	}
	entries := make([dynamic]Entry, 0, len(names), tmp(rt))
	for n in names {
		r, rm, re := resolve_export(ctx, m, n)
		if r == .ambiguous {continue}
		if r != .found {
			me := find_export(m, n)
			if me != nil && me.kind == 1 && me.local_name != pa(.A__star_) {
				throw_resolve_error(ctx, r, m.req[me.req_idx].module, me.local_name)
			} else {
				throw_resolve_error(ctx, r, m, n)
			}
			m.namespace = nil
			return EXCEPTION
		}
		if re.local_name == pa(.A__star_) {
			append(&entries, Entry{name = n, ns = rm.req[re.req_idx].module})
		} else {
			vr := local_export_ref(ctx, rm, re)
			if vr == nil {
				throw_resolve_error(ctx, .circular, m, n)
				m.namespace = nil
				return EXCEPTION
			}
			append(&entries, Entry{name = n, ref = vr})
		}
	}
	// sort by code units
	for i in 1 ..< len(entries) {
		x := entries[i]
		j := i
		for j > 0 && str_cmp(rt, atom_to_string(rt, entries[j - 1].name), atom_to_string(rt, x.name)) > 0 {
			entries[j] = entries[j - 1]
			j -= 1
		}
		entries[j] = x
	}
	for e in entries {
		vr := e.ref
		if e.ns != nil {
			nsv := module_namespace(ctx, e.ns)
			if is_exception(nsv) {return EXCEPTION}
			vr = var_ref_new_detached(rt, nsv)
		}
		s := add_property(rt, ns, e.name, {.enumerable, .writable}, .var_ref)
		s.var_ref = vr
	}
	s := add_property(rt, ns, well_known_atom(.to_string_tag), {})
	s.value = atom_to_value(rt, pa(.A_Module))
	ns.extensible = false
	return mk_obj(ns)
}

module_ns_get_own :: proc(ctx: ^Context, o: ^Object, a: Atom, d: ^Prop_Desc) -> int {
	i := shape_find(o.shape, a)
	if i < 0 {return 0}
	p := o.shape.props[i]
	if p.kind == .var_ref {
		v := o.slots[i].var_ref.pvalue^
		if v.tag == .uninitialized {
			throw_reference_error_uninit(ctx, a)
			return -1
		}
		if d != nil {d^ = data_desc(v, {.enumerable, .writable})}
		return 1
	}
	if d != nil {d^ = data_desc(o.slots[i].value, p.flags)}
	return 1
}

module_ns_define :: proc(ctx: ^Context, o: ^Object, a: Atom, d: ^Prop_Desc, throw_flag: bool) -> int {
	if atom_is_symbol(ctx.rt, a) {return ordinary_define(ctx, o, a, d, throw_flag)}
	cur: Prop_Desc
	r := module_ns_get_own(ctx, o, a, &cur)
	if r < 0 {return -1}
	ok := r == 1
	if ok {
		if .configurable in d.has && .configurable in d.flags {ok = false}
		if .enumerable in d.has && .enumerable not_in d.flags {ok = false}
		if desc_is_accessor(d) {ok = false}
		if .writable in d.has && .writable not_in d.flags {ok = false}
		if .value in d.has && !same_value(ctx, d.value, cur.value) {ok = false}
	}
	if !ok {
		if throw_flag {return throw_cannot_define(ctx, a)}
		return 0
	}
	return 1
}

module_ns_delete :: proc(ctx: ^Context, o: ^Object, a: Atom) -> int {
	i := shape_find(o.shape, a)
	if i < 0 {return 1}
	if atom_is_symbol(ctx.rt, a) && .configurable in o.shape.props[i].flags {
		remove_property_at(ctx.rt, o, i)
		return 1
	}
	return 0
}

module_ns_own_keys :: proc(ctx: ^Context, o: ^Object, out: ^[dynamic]Atom, filter: Keys_Filters) -> bool {
	rt := ctx.rt
	for p in o.shape.props {
		sym := atom_is_symbol(rt, p.atom)
		if (sym && .symbols in filter) || (!sym && .strings in filter) {append(out, p.atom)}
	}
	return true
}

// --- evaluation ---

@(private = "file")
set_module_evaluated :: proc(ctx: ^Context, m: ^Module) {
	m.status = .evaluated
	if !is_undefined(m.promise) {
		call(ctx, m.resolve, UNDEFINED, {UNDEFINED})
	}
}

@(private = "file")
execute_sync_module :: proc(ctx: ^Context, m: ^Module) -> (Value, bool) {
	p := async_function_call(ctx, m.func_obj, UNDEFINED, {})
	if is_exception(p) {return take_exception(ctx), false}
	pd := promise_data(p)
	switch pd.state {
	case .fulfilled:
		return UNDEFINED, true
	case .rejected:
		pd.is_handled = true
		return pd.result, false
	case .pending:
	}
	throw_type_error(ctx, "promise is pending")
	return take_exception(ctx), false
}

@(private = "file")
async_module_rejected :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	m := cast(^Module)native_data(ctx)[0].u.ptr
	module_rejected(ctx, m, arg(args, 0))
	return UNDEFINED
}

@(private = "file")
module_rejected :: proc(ctx: ^Context, m: ^Module, err: Value) {
	if m.status == .evaluated {return}
	m.has_eval_exception = true
	m.eval_exception = err
	m.status = .evaluated
	for p in m.async_parents {module_rejected(ctx, p, err)}
	if !is_undefined(m.promise) {call(ctx, m.reject, UNDEFINED, {err})}
}

@(private = "file")
async_module_fulfilled :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	m := cast(^Module)native_data(ctx)[0].u.ptr
	if m.status == .evaluated {return UNDEFINED}
	m.async_evaluation = false
	set_module_evaluated(ctx, m)
	list := make([dynamic]^Module, 0, 8, tmp(ctx.rt))
	gather_ancestors(m, &list)
	// by increasing async evaluation order
	for i in 1 ..< len(list) {
		x := list[i]
		j := i
		for j > 0 && list[j - 1].async_ts > x.async_ts {list[j] = list[j - 1]; j -= 1}
		list[j] = x
	}
	for m1 in list {
		if m1.status == .evaluated {continue}
		if m1.has_tla {
			execute_async_module(ctx, m1)
		} else {
			err, ok := execute_sync_module(ctx, m1)
			if !ok {
				module_rejected(ctx, m1, err)
			} else {
				set_module_evaluated(ctx, m1)
			}
		}
	}
	return UNDEFINED
}

@(private = "file")
gather_ancestors :: proc(m: ^Module, list: ^[dynamic]^Module) {
	for p in m.async_parents {
		in_list := false
		for x in list {if x == p {in_list = true; break}}
		if in_list || p.cycle_root.has_eval_exception {continue}
		p.pending_async -= 1
		if p.pending_async == 0 {
			append(list, p)
			if !p.has_tla {gather_ancestors(p, list)}
		}
	}
}

@(private = "file")
execute_async_module :: proc(ctx: ^Context, m: ^Module) {
	p := async_function_call(ctx, m.func_obj, UNDEFINED, {})
	if is_exception(p) {
		module_rejected(ctx, m, take_exception(ctx))
		return
	}
	mv := mk_ptr(.module, m)
	ful := new_native_anon(ctx, async_module_fulfilled, 0, {mv})
	rej := new_native_anon(ctx, async_module_rejected, 0, {mv})
	perform_promise_then(ctx, as_obj(p), mk_obj(ful), mk_obj(rej), UNDEFINED, UNDEFINED)
}

@(private = "file")
inner_evaluate :: proc(ctx: ^Context, m: ^Module, index: int, stack_top: ^^Module) -> (int, Value) {
	rt := ctx.rt
	idx := index
	if m.status == .evaluating_async || m.status == .evaluated {
		if m.has_eval_exception {return -1, m.eval_exception}
		return idx, UNDEFINED
	}
	if m.status == .evaluating {return idx, UNDEFINED}
	m.status = .evaluating
	m.dfs_index = idx
	m.dfs_ancestor = idx
	m.pending_async = 0
	idx += 1
	m.stack_prev = stack_top^
	stack_top^ = m
	for &r in m.req {
		m1 := r.module
		err: Value
		idx, err = inner_evaluate(ctx, m1, idx, stack_top)
		if idx < 0 {return -1, err}
		if m1.status == .evaluating {
			m.dfs_ancestor = min(m.dfs_ancestor, m1.dfs_ancestor)
		} else {
			m1 = m1.cycle_root
			if m1.has_eval_exception {return -1, m1.eval_exception}
		}
		if m1.async_evaluation {
			m.pending_async += 1
			append(&m1.async_parents, m)
		}
	}
	if m.pending_async > 0 {
		m.async_evaluation = true
		m.async_ts = i64(rt.gc_count) << 32 | i64(len(rt.modules)) // monotonic enough within a runtime
		module_async_counter += 1
		m.async_ts = module_async_counter
	} else if m.has_tla {
		m.async_evaluation = true
		module_async_counter += 1
		m.async_ts = module_async_counter
		execute_async_module(ctx, m)
	} else {
		err, ok := execute_sync_module(ctx, m)
		if !ok {return -1, err}
	}
	if m.dfs_index == m.dfs_ancestor {
		for {
			m1 := stack_top^
			stack_top^ = m1.stack_prev
			m1.status = m1.async_evaluation ? .evaluating_async : .evaluated
			m1.cycle_root = m
			if m1 == m {break}
		}
	}
	return idx, UNDEFINED
}

@(private = "file")
module_async_counter: i64

// Evaluate(): returns the module's evaluation promise.
module_evaluate :: proc(ctx: ^Context, m_in: ^Module) -> Value {
	m := m_in
	if m.status == .evaluating_async || m.status == .evaluated {m = m.cycle_root}
	if !is_undefined(m.promise) {return m.promise}
	cap, ok := new_promise_capability(ctx, mk_obj(ctx.promise_ctor))
	if !ok {return EXCEPTION}
	m.promise = cap.promise
	m.resolve = cap.resolve
	m.reject = cap.reject
	stack_top: ^Module
	idx, err := inner_evaluate(ctx, m, 0, &stack_top)
	if idx < 0 {
		for stack_top != nil {
			m1 := stack_top
			m1.status = .evaluated
			m1.has_eval_exception = true
			m1.eval_exception = err
			m1.cycle_root = m
			stack_top = m1.stack_prev
		}
		call(ctx, m.reject, UNDEFINED, {m.eval_exception})
	} else if !m.async_evaluation {
		call(ctx, m.resolve, UNDEFINED, {UNDEFINED})
	}
	return m.promise
}

// Link and evaluate a module record (embedding entry point). Returns the evaluation promise.
module_run :: proc(ctx: ^Context, m: ^Module) -> Value {
	module_register(ctx.rt, m)
	if !module_link(ctx, m) {return EXCEPTION}
	return module_evaluate(ctx, m)
}

// --- import.meta and import() ---

import_meta_for :: proc(ctx: ^Context, f: ^Frame) -> Value {
	rt := ctx.rt
	m: ^Module
	if f.bc != nil && f.bc.filename != ATOM_NULL {m = find_module_by_name(rt, f.bc.filename)}
	if m == nil {return throw_type_error(ctx, "import.meta not supported in this context")}
	if is_undefined(m.meta) {
		mo := object_new_proto(ctx, nil)
		m.meta = mk_obj(mo)
		if rt.config.import_meta != nil {rt.config.import_meta(ctx, atom_utf8(rt, m.name), m.meta, rt.config.meta_user)}
	}
	return m.meta
}

@(private = "file")
import_fulfilled :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	d := native_data(ctx)
	m := cast(^Module)d[2].u.ptr
	ns := module_namespace(ctx, m)
	if is_exception(ns) {
		e := take_exception(ctx)
		call(ctx, d[1], UNDEFINED, {e})
		return UNDEFINED
	}
	call(ctx, d[0], UNDEFINED, {ns})
	return UNDEFINED
}

@(private = "file")
import_rejected :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	d := native_data(ctx)
	call(ctx, d[1], UNDEFINED, {arg(args, 0)})
	return UNDEFINED
}

// The job that performs a dynamic import. args: [resolve, reject, referrer, specifier]
@(private = "file")
dynamic_import_job :: proc(ctx: ^Context, args: []Value) -> Value {
	rt := ctx.rt
	resolve, reject := args[0], args[1]
	referrer := args[2]
	spec := as_str(args[3])
	ref_atom := referrer.tag == .string ? atom_from_string(rt, as_str(referrer)) : ATOM_NULL
	m := host_load(ctx, ref_atom, atom_from_string(rt, spec))
	ok := m != nil && module_link(ctx, m)
	if !ok {
		if rt.uncatchable {return EXCEPTION}
		e := take_exception(ctx)
		call(ctx, reject, UNDEFINED, {e})
		return UNDEFINED
	}
	p := module_evaluate(ctx, m)
	if is_exception(p) {
		e := take_exception(ctx)
		call(ctx, reject, UNDEFINED, {e})
		return UNDEFINED
	}
	mv := mk_ptr(.module, m)
	ful := new_native_anon(ctx, import_fulfilled, 0, {resolve, reject, mv})
	rej := new_native_anon(ctx, import_rejected, 0, {resolve, reject, mv})
	perform_promise_then(ctx, as_obj(p), mk_obj(ful), mk_obj(rej), UNDEFINED, UNDEFINED)
	return UNDEFINED
}

dynamic_import :: proc(ctx: ^Context, f: ^Frame, specifier: Value, options: Value) -> Value {
	rt := ctx.rt
	cap, ok := new_promise_capability(ctx, mk_obj(ctx.promise_ctor))
	if !ok {return EXCEPTION}
	fail :: proc(ctx: ^Context, cap: Capability) -> Value {
		if ctx.rt.uncatchable {return EXCEPTION}
		e := take_exception(ctx)
		call(ctx, cap.reject, UNDEFINED, {e})
		return cap.promise
	}
	referrer := NULL
	for fr := f; fr != nil; fr = fr.prev {
		if fr.bc != nil && fr.bc.filename != ATOM_NULL {
			referrer = atom_to_value(rt, fr.bc.filename)
			break
		}
	}
	s := to_string(ctx, specifier)
	if is_exception(s) {return fail(ctx, cap)}
	if !is_undefined(options) {
		if options.tag != .object {
			throw_type_error(ctx, "options must be an object")
			return fail(ctx, cap)
		}
		w := get(ctx, options, pa(.A_with))
		if is_exception(w) {return fail(ctx, cap)}
		if !is_undefined(w) {
			if w.tag != .object {
				throw_type_error(ctx, "options.with must be an object")
				return fail(ctx, cap)
			}
			keys := make([dynamic]Atom, 0, 4, tmp(rt))
			if !own_property_keys(ctx, as_obj(w), &keys, {.strings}) {return fail(ctx, cap)}
			for k in keys {
				e := own_enumerable(ctx, as_obj(w), k)
				if e < 0 {return fail(ctx, cap)}
				if e == 0 {continue}
				v := get(ctx, w, k)
				if is_exception(v) {return fail(ctx, cap)}
				if v.tag != .string {
					throw_type_error(ctx, "module attribute values must be strings")
					return fail(ctx, cap)
				}
			}
		}
	}
	enqueue_job(ctx, dynamic_import_job, {cap.resolve, cap.reject, referrer, s})
	return cap.promise
}
