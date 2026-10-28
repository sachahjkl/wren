package jsrt

// Global variable access (GetGlobalVar & co. in QuickJS): global lexical declarations live in the
// realm's `global_var_obj`, var/function declarations on the global object itself.

// Direct-mapped cache of "atom -> slot index in the global object": a hit is checked against the live shape
// (the property at that index must still be this atom), so no invalidation is needed when properties move.
Global_Cache_Entry :: struct {
	atom: Atom,
	idx:  u32,
}

GLOBAL_CACHE_SIZE :: 256

// The slot of data property `a` of the global object, or -1 (the caller falls back to the full lookup).
global_slot :: #force_inline proc "contextless" (ctx: ^Context, g: ^Object, a: Atom) -> int {
	ce := &ctx.global_cache[(a * 0x9E3779B1) >> 24]
	props := raw_data(g.shape.props)
	if ce.atom == a && int(ce.idx) < len(g.shape.props) && props[ce.idx].atom == a {
		return props[ce.idx].kind == .data ? int(ce.idx) : -1
	}
	j := shape_find(g.shape, a)
	if j < 0 {return -1}
	ce^ = {a, u32(j)}
	return props[j].kind == .data ? j : -1
}

global_get :: proc(ctx: ^Context, a: Atom, throw_ref: bool) -> Value {
	gv := ctx.global_var_obj
	i := shape_find(gv.shape, a)
	if i >= 0 {
		v := gv.slots[i].value
		if v.tag == .uninitialized {return throw_reference_error_uninit(ctx, a)}
		return v
	}
	g := ctx.global_obj
	j := global_slot(ctx, g, a)
	if j >= 0 {return g.slots[j].value}
	h := has_property(ctx, g, a)
	if h < 0 {return EXCEPTION}
	if h == 0 {
		if throw_ref {return throw_not_defined(ctx, a)}
		return UNDEFINED
	}
	return get_property(ctx, mk_obj(g), a, mk_obj(g))
}

// put_var (init=false) / put_var_init (init=true).
global_set :: proc(ctx: ^Context, a: Atom, v: Value, init: bool, strict: bool) -> int {
	gv := ctx.global_var_obj
	i := shape_find(gv.shape, a)
	if i >= 0 {
		if !init {
			if gv.slots[i].value.tag == .uninitialized {
				throw_reference_error_uninit(ctx, a)
				return -1
			}
			if .writable not_in gv.shape.props[i].flags {return throw_read_only(ctx, a)}
		}
		gv.slots[i].value = v
		return 0
	}
	g := ctx.global_obj
	j := global_slot(ctx, g, a)
	if j >= 0 && .writable in g.shape.props[j].flags {
		g.slots[j].value = v
		return 0
	}
	h := has_property(ctx, g, a)
	if h < 0 {return -1}
	if h == 0 && strict {
		throw_not_defined(ctx, a)
		return -1
	}
	r := set_property(ctx, mk_obj(g), a, v, mk_obj(g), strict)
	return r < 0 ? -1 : 0
}

global_check_define :: proc(ctx: ^Context, a: Atom, flags: int) -> int {
	g := ctx.global_obj
	i := shape_find(g.shape, a)
	if flags & DEFINE_GLOBAL_LEX_VAR != 0 {
		if i >= 0 && .configurable not_in g.shape.props[i].flags {
			throw_syntax_error(ctx, cat(ctx, "redeclaration of '", atom_utf8(ctx.rt, a), "'"))
			return -1
		}
	} else {
		if i < 0 && !g.extensible {
			throw_type_error(ctx, cat(ctx, "cannot define variable '", atom_utf8(ctx.rt, a), "'"))
			return -1
		}
		if flags & DEFINE_GLOBAL_FUNC_VAR != 0 && i >= 0 {
			p := g.shape.props[i]
			if .configurable not_in p.flags && (p.kind == .accessor || p.flags & {.writable, .enumerable} != {.writable, .enumerable}) {
				throw_type_error(ctx, cat(ctx, "cannot define variable '", atom_utf8(ctx.rt, a), "'"))
				return -1
			}
		}
	}
	if shape_find(ctx.global_var_obj.shape, a) >= 0 {
		throw_syntax_error(ctx, cat(ctx, "redeclaration of '", atom_utf8(ctx.rt, a), "'"))
		return -1
	}
	return 0
}

global_define_var :: proc(ctx: ^Context, a: Atom, def_flags: int) -> int {
	o: ^Object
	flags: Prop_Flags
	val: Value
	if def_flags & DEFINE_GLOBAL_LEX_VAR != 0 {
		o = ctx.global_var_obj
		flags = {.enumerable, .configurable}
		if def_flags & QJS_PROP_WRITABLE != 0 {flags += {.writable}}
		val = UNINITIALIZED
	} else {
		o = ctx.global_obj
		flags = {.enumerable, .writable}
		if def_flags & QJS_PROP_CONFIGURABLE != 0 {flags += {.configurable}}
		val = UNDEFINED
	}
	if shape_find(o.shape, a) >= 0 {return 0}
	if !o.extensible {return 0}
	s := add_property(ctx.rt, o, a, flags)
	s.value = val
	return 0
}

global_define_func :: proc(ctx: ^Context, a: Atom, fn: Value, def_flags: int) -> int {
	g := ctx.global_obj
	i := shape_find(g.shape, a)
	d: Prop_Desc
	if i < 0 || .configurable in g.shape.props[i].flags {
		flags: Prop_Flags = {.enumerable, .writable}
		if def_flags & QJS_PROP_CONFIGURABLE != 0 {flags += {.configurable}}
		d = data_desc(fn, flags)
	} else {
		d = Prop_Desc{value = fn, has = {.value}}
	}
	return define_own_property(ctx, g, a, d, true) < 0 ? -1 : 0
}

// make_var_ref: push (object, name) for a global reference.
global_make_ref :: proc(ctx: ^Context, a: Atom, stack: []Value, sp: int) -> int {
	gv := ctx.global_var_obj
	i := shape_find(gv.shape, a)
	if i >= 0 {
		if gv.slots[i].value.tag == .uninitialized {
			throw_reference_error_uninit(ctx, a)
			return -1
		}
		if .writable not_in gv.shape.props[i].flags {return throw_read_only(ctx, a)}
		stack[sp] = mk_obj(gv)
	} else {
		h := has_property(ctx, ctx.global_obj, a)
		if h < 0 {return -1}
		stack[sp] = h == 1 ? mk_obj(ctx.global_obj) : UNDEFINED
	}
	stack[sp + 1] = atom_to_value(ctx.rt, a)
	return 0
}

global_delete :: proc(ctx: ^Context, a: Atom) -> int {
	if shape_find(ctx.global_var_obj.shape, a) >= 0 {return 0}
	return delete_property(ctx, ctx.global_obj, a)
}
