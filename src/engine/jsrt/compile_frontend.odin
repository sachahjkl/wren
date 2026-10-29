package jsrt

// The engine's own compiler: the Odin front-end (src/engine/frontend) turns source text into
// QuickJS-ng 0.17 bytecode, serialized with JS_WriteObject's layout, which read_object loads. This is
// the default Host_Config.compile; the front-end works in a scratch arena released after each call.

import "core:mem"
import fe "wb:engine/frontend"

frontend_compile :: proc(ctx: ^Context, req: ^Compile_Request) -> Value {
	rt := ctx.rt
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, rt.allocator, rt.allocator, 256 * 1024, 64 * 1024, 16)
	defer mem.dynamic_arena_destroy(&arena)
	counter: Compile_Alloc
	compile_alloc_init(&counter, &arena, rt.allocator)
	defer compile_alloc_release(&counter)
	defer {
		rt.compile_count += 1
		rt.compile_peak_bytes = max(rt.compile_peak_bytes, counter.peak)
		rt.compile_peak_blocks = max(rt.compile_peak_blocks, arena_blocks(&arena))
	}
	a := compile_alloc(&counter)

	opts := fe.Compile_Options {
		filename           = req.filename,
		strict             = req.strict,
		encode_import_type = true,
		stack_budget       = rt.config.compile_stack_budget,
		keep_source        = !rt.config.strip_source,
	}
	kind: fe.Program_Kind
	switch req.kind {
	case .script, .function_ctor: kind = .script
	case .module: kind = .module
	case .eval_indirect: kind = .indirect_eval
	case .eval_direct:
		kind = .direct_eval
		if req.parent == nil {kind = .indirect_eval}
	}
	parent: fe.Eval_Parent
	if kind == .direct_eval {
		b := req.parent
		n := int(b.arg_count) + int(b.var_count)
		vds := make([]fe.Eval_Parent_Var, n, a)
		for i in 0 ..< min(n, len(b.vardefs)) {
			vd := b.vardefs[i]
			vds[i] = {
				name        = atom_utf8_alloc(rt, vd.name, a),
				scope_level = int(vd.scope_level),
				scope_next  = int(vd.scope_next),
				var_kind    = fe.Var_Kind(vd.var_kind),
				is_const    = vd.is_const,
				is_lexical  = vd.is_lexical,
			}
		}
		cvs := make([]fe.Eval_Parent_Closure, int(b.closure_var_count), a)
		for i in 0 ..< min(len(cvs), len(b.closure_vars)) {
			cv := b.closure_vars[i]
			cvs[i] = {
				name         = atom_utf8_alloc(rt, cv.name, a),
				var_idx      = int(cv.var_idx),
				closure_type = fe.Closure_Type(cv.closure_type),
				var_kind     = fe.Var_Kind(cv.var_kind),
				is_const     = cv.is_const,
				is_lexical   = cv.is_lexical,
			}
		}
		parent = {
			arg_count          = int(b.arg_count),
			vardefs            = vds,
			closure_vars       = cvs,
			scope_idx          = req.scope_idx,
			is_strict          = b.is_strict_mode,
			new_target_allowed = b.new_target_allowed,
			super_call_allowed = b.super_call_allowed,
			super_allowed      = b.super_allowed,
			arguments_allowed  = b.arguments_allowed,
		}
		opts.parent = &parent
	}
	res := fe.compile_program(req.source, kind, a, opts)
	if fe.is_err(res.err) {
		if fe.error_kind(res.err) == .range {
			return throw_error(ctx, .range, "Maximum call stack size exceeded")
		}
		return throw_error(ctx, .syntax, res.err.message)
	}
	// The serialized form is built on the host heap (it grows by realloc, and its buffers are freed as soon as
	// they are done with) and the arena goes before the bytecode is read, so the compiler's transient memory is
	// returned for the runtime's heap to reuse instead of adding to it.
	wa := req.keep_image ? rt_allocator(rt) : rt.allocator
	bytes := fe.write_object_of(res, wa)
	compile_alloc_release(&counter)
	mem.dynamic_arena_destroy(&arena)
	v := read_object(ctx, bytes)
	if req.keep_image && v.tag == .function_bc {
		b := cast(^Function_Bytecode)v.u.ptr
		b.image = bytes
	} else {
		delete(bytes, wa)
	}
	return v
}

// An atom's UTF-8 text copied into `a` (the front-end's scratch arena).
@(private = "file")
atom_utf8_alloc :: proc(rt: ^Runtime, at: Atom, a: mem.Allocator) -> string {
	s := atom_utf8(rt, at)
	b := make([]u8, len(s), a)
	copy(b, s)
	return string(b)
}
