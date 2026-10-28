package jsrt

// The object internal methods (ECMA-262 §10.1 ordinary objects, and the exotic objects' overrides):
// [[GetOwnProperty]], [[DefineOwnProperty]], [[HasProperty]], [[Get]], [[Set]], [[Delete]],
// [[OwnPropertyKeys]], [[GetPrototypeOf]], [[SetPrototypeOf]], [[IsExtensible]],
// [[PreventExtensions]].
//
// Return convention for fallible predicates: 1 true, 0 false, -1 an exception is pending.
// Value-returning operations return EXCEPTION on failure. Results of [[Get]] are rooted (gc.odin).

import "core:math"

Desc_Field :: enum u8 {value, writable, get, set, enumerable, configurable}
Desc_Has :: bit_set[Desc_Field;u8]

Prop_Desc :: struct {
	value:  Value,
	getter: Value,
	setter: Value,
	flags:  Prop_Flags,
	has:    Desc_Has,
}

desc_is_accessor :: #force_inline proc "contextless" (d: ^Prop_Desc) -> bool {return .get in d.has || .set in d.has}
desc_is_data :: #force_inline proc "contextless" (d: ^Prop_Desc) -> bool {return .value in d.has || .writable in d.has}

data_desc :: proc(v: Value, flags: Prop_Flags) -> Prop_Desc {
	return Prop_Desc{value = v, getter = UNDEFINED, setter = UNDEFINED, flags = flags, has = {.value, .writable, .enumerable, .configurable}}
}

accessor_desc :: proc(get, set: Value, flags: Prop_Flags) -> Prop_Desc {
	return Prop_Desc{value = UNDEFINED, getter = get, setter = set, flags = flags - {.writable}, has = {.get, .set, .enumerable, .configurable}}
}

@(private = "file")
obj_val :: #force_inline proc "contextless" (o: ^Object) -> Value {
	if o == nil {return UNDEFINED}
	return mk_obj(o)
}

@(private = "file")
val_obj :: #force_inline proc "contextless" (v: Value) -> ^Object {
	if v.tag == .object {return as_obj(v)}
	return nil
}

// --- [[GetOwnProperty]] ---

get_own_property :: proc(ctx: ^Context, o: ^Object, a: Atom, d: ^Prop_Desc) -> int {
	#partial switch o.class {
	case .proxy:
		return proxy_get_own_property(ctx, o, a, d)
	case .string:
		if pd, ok := o.data.(Prim_Data); ok && is_string(pd.v) {
			s := as_str(pd.v)
			if idx, isi := atom_array_index(a); isi && idx < s.len {
				if d != nil {d^ = data_desc(mk_str(str_from_code_unit(ctx.rt, str_char_at(ctx.rt, s, int(idx)))), {.enumerable})}
				return 1
			}
		}
	case .module_ns:
		return module_ns_get_own(ctx, o, a, d)
	case:
		if is_typed_array_class(o.class) {
			if n, isnum := atom_canonical_numeric(ctx, a); isnum {
				v, valid := typed_array_get_index(ctx, o, n)
				if !valid {return 0}
				if d != nil {d^ = data_desc(v, CWE)}
				return 1
			}
		}
	}
	if o.fast_array {
		if idx, isi := atom_array_index(a); isi {
			ad := &o.data.(Array_Data)
			if idx < ad.count {
				if d != nil {d^ = data_desc(ad.values[idx], CWE)}
				return 1
			}
		}
	}
	i := shape_find(o.shape, a)
	if i < 0 {return 0}
	if d == nil {return 1}
	p := o.shape.props[i]
	s := &o.slots[i]
	switch p.kind {
	case .data:
		d^ = data_desc(s.value, p.flags)
	case .accessor:
		d^ = accessor_desc(obj_val(s.getset.getter), obj_val(s.getset.setter), p.flags)
	case .var_ref:
		v := s.var_ref.pvalue^
		if v.tag == .uninitialized {
			throw_reference_error_uninit(ctx, a)
			return -1
		}
		d^ = data_desc(v, p.flags)
	}
	return 1
}

// Fast own-property existence (no descriptor, no exotic traps except the cheap ones).
has_own_property :: proc(ctx: ^Context, o: ^Object, a: Atom) -> int {
	return get_own_property(ctx, o, a, nil)
}

// --- [[DefineOwnProperty]] ---

throw_cannot_define :: proc(ctx: ^Context, a: Atom) -> int {
	throw_type_error(ctx, cat(ctx, "cannot redefine property: ", atom_utf8(ctx.rt, a)))
	return -1
}

@(private = "file")
fail_define :: #force_inline proc(ctx: ^Context, a: Atom, throw_flag: bool) -> int {
	if throw_flag {return throw_cannot_define(ctx, a)}
	return 0
}

define_own_property :: proc(ctx: ^Context, o: ^Object, a: Atom, d: Prop_Desc, throw_flag: bool) -> int {
	desc := d
	#partial switch o.class {
	case .proxy:
		return proxy_define_own_property(ctx, o, a, &desc, throw_flag)
	case .array:
		if a == pa(.A_length) {return array_define_length(ctx, o, &desc, throw_flag)}
		if idx, isi := atom_array_index(a); isi {
			len := array_length_u32(o)
			lw := .writable in o.shape.props[0].flags
			if idx >= len && !lw {return fail_define(ctx, a, throw_flag)}
			if o.fast_array {
				r, handled := fast_array_define(ctx, o, idx, &desc)
				if handled {
					if r == 1 && idx >= len {o.slots[0].value = mk_u32(idx + 1)}
					return r
				}
			}
			r := ordinary_define(ctx, o, a, &desc, throw_flag)
			if r == 1 && idx >= len {o.slots[0].value = mk_u32(idx + 1)}
			return r
		}
	case .arguments:
		if idx, isi := atom_array_index(a); isi && o.fast_array {
			r, handled := fast_array_define(ctx, o, idx, &desc)
			if handled {return r}
		}
	case .mapped_arguments:
		return mapped_args_define(ctx, o, a, &desc, throw_flag)
	case .string:
		if pd, ok := o.data.(Prim_Data); ok && is_string(pd.v) {
			s := as_str(pd.v)
			if idx, isi := atom_array_index(a); isi && idx < s.len {
				cur := data_desc(mk_str(str_from_code_unit(ctx.rt, str_char_at(ctx.rt, s, int(idx)))), {.enumerable})
				if !desc_compatible(ctx, &cur, &desc) {return fail_define(ctx, a, throw_flag)}
				return 1
			}
		}
	case .module_ns:
		return module_ns_define(ctx, o, a, &desc, throw_flag)
	case:
		if is_typed_array_class(o.class) {
			if n, isnum := atom_canonical_numeric(ctx, a); isnum {
				return typed_array_define(ctx, o, a, n, &desc, throw_flag)
			}
		}
	}
	return ordinary_define(ctx, o, a, &desc, throw_flag)
}

// Can `d` be applied to an existing non-configurable, non-writable data property `cur` without
// changing it?
@(private = "file")
desc_compatible :: proc(ctx: ^Context, cur: ^Prop_Desc, d: ^Prop_Desc) -> bool {
	if .configurable in d.has && .configurable in d.flags {return false}
	if .enumerable in d.has && (.enumerable in d.flags) != (.enumerable in cur.flags) {return false}
	if desc_is_accessor(d) {return false}
	if .writable in d.has && .writable in d.flags {return false}
	if .value in d.has && !same_value(ctx, d.value, cur.value) {return false}
	return true
}

// Fast-array element definition. handled=false means "convert to a slow array and use the
// ordinary algorithm".
@(private = "file")
fast_array_define :: proc(ctx: ^Context, o: ^Object, idx: u32, d: ^Prop_Desc) -> (int, bool) {
	ad := &o.data.(Array_Data)
	if desc_is_accessor(d) {
		convert_to_slow_array(ctx, o)
		return 0, false
	}
	if idx < ad.count {
		// the element is a CWE data property; the result stays CWE unless the descriptor clears a flag
		if (.writable in d.has && .writable not_in d.flags) || (.enumerable in d.has && .enumerable not_in d.flags) || (.configurable in d.has && .configurable not_in d.flags) {
			convert_to_slow_array(ctx, o)
			return 0, false
		}
		if .value in d.has {ad.values[idx] = d.value}
		return 1, true
	}
	if idx == ad.count && o.extensible && .writable in d.flags && .enumerable in d.flags && .configurable in d.flags &&
	   d.has >= {.writable, .enumerable, .configurable} {
		array_reserve(ctx.rt, ad, ad.count + 1)
		ad.values[ad.count] = .value in d.has ? d.value : UNDEFINED
		ad.count += 1
		return 1, true
	}
	convert_to_slow_array(ctx, o)
	return 0, false
}

convert_to_slow_array :: proc(ctx: ^Context, o: ^Object) {
	if !o.fast_array {return}
	rt := ctx.rt
	ad := o.data.(Array_Data)
	o.fast_array = false
	object_make_dict(rt, o)
	// index keys must come before the string keys added so far; enumeration sorts index keys, so
	// appending is enough.
	for i in 0 ..< ad.count {
		s := add_property(rt, o, atom_from_u32(i), CWE)
		s.value = ad.values[i]
	}
	if ad.values != nil {mem_free(rt, ad.values, int(ad.cap) * size_of(Value))}
	o.data = Array_Data{}
}

ordinary_define :: proc(ctx: ^Context, o: ^Object, a: Atom, d: ^Prop_Desc, throw_flag: bool) -> int {
	rt := ctx.rt
	i := shape_find(o.shape, a)
	if i < 0 {
		if !o.extensible {
			if throw_flag {
				throw_type_error(ctx, cat(ctx, "cannot define property '", atom_utf8(rt, a), "': object is not extensible"))
				return -1
			}
			return 0
		}
		flags: Prop_Flags
		if .configurable in d.has && .configurable in d.flags {flags += {.configurable}}
		if .enumerable in d.has && .enumerable in d.flags {flags += {.enumerable}}
		if desc_is_accessor(d) {
			s := add_property(rt, o, a, flags, .accessor)
			s.getset = Getset{val_obj(d.getter), val_obj(d.setter)}
		} else {
			if .writable in d.has && .writable in d.flags {flags += {.writable}}
			s := add_property(rt, o, a, flags, .data)
			s.value = .value in d.has ? d.value : UNDEFINED
		}
		return 1
	}
	p := o.shape.props[i]
	s := &o.slots[i]
	cur_is_accessor := p.kind == .accessor
	// validation (ValidateAndApplyPropertyDescriptor)
	if .configurable not_in p.flags {
		if .configurable in d.has && .configurable in d.flags {return fail_define(ctx, a, throw_flag)}
		if .enumerable in d.has && (.enumerable in d.flags) != (.enumerable in p.flags) {return fail_define(ctx, a, throw_flag)}
		if desc_is_accessor(d) || desc_is_data(d) {
			if cur_is_accessor != desc_is_accessor(d) {return fail_define(ctx, a, throw_flag)}
			if cur_is_accessor {
				if .get in d.has && val_obj(d.getter) != s.getset.getter {return fail_define(ctx, a, throw_flag)}
				if .set in d.has && val_obj(d.setter) != s.getset.setter {return fail_define(ctx, a, throw_flag)}
			} else if .writable not_in p.flags {
				if .writable in d.has && .writable in d.flags {return fail_define(ctx, a, throw_flag)}
				if .value in d.has {
					cv := p.kind == .var_ref ? s.var_ref.pvalue^ : s.value
					if !same_value(ctx, d.value, cv) {return fail_define(ctx, a, throw_flag)}
				}
			}
		}
	}
	// apply
	flags := p.flags
	if .configurable in d.has {if .configurable in d.flags {flags += {.configurable}} else {flags -= {.configurable}}}
	if .enumerable in d.has {if .enumerable in d.flags {flags += {.enumerable}} else {flags -= {.enumerable}}}
	if desc_is_accessor(d) {
		if !cur_is_accessor {
			flags -= {.writable}
			set_property_flags(rt, o, i, flags, .accessor)
			s = &o.slots[i]
			s.getset = Getset{}
		} else {
			set_property_flags(rt, o, i, flags, .accessor)
			s = &o.slots[i]
		}
		if .get in d.has {s.getset.getter = val_obj(d.getter)}
		if .set in d.has {s.getset.setter = val_obj(d.setter)}
		return 1
	}
	if desc_is_data(d) && cur_is_accessor {
		flags -= {.writable}
		if .writable in d.has && .writable in d.flags {flags += {.writable}}
		set_property_flags(rt, o, i, flags, .data)
		s = &o.slots[i]
		s.value = .value in d.has ? d.value : UNDEFINED
		return 1
	}
	if .writable in d.has {if .writable in d.flags {flags += {.writable}} else {flags -= {.writable}}}
	if p.kind == .var_ref {
		if .value in d.has {s.var_ref.pvalue^ = d.value}
		set_property_flags(rt, o, i, flags, .var_ref)
		return 1
	}
	if .value in d.has {s.value = d.value}
	set_property_flags(rt, o, i, flags, p.kind)
	return 1
}

// --- arrays ---

array_length_u32 :: #force_inline proc(o: ^Object) -> u32 {
	v := o.slots[0].value
	if v.tag == .int {return u32(v.u.i)}
	return u32(v.u.f)
}

// ArraySetLength (ECMA-262 §10.4.2.4).
@(private = "file")
array_define_length :: proc(ctx: ^Context, o: ^Object, d: ^Prop_Desc, throw_flag: bool) -> int {
	if .value not_in d.has {
		return ordinary_define(ctx, o, pa(.A_length), d, throw_flag)
	}
	new_len, ok := to_uint32(ctx, d.value)
	if !ok {return -1}
	num, ok2 := to_number(ctx, d.value)
	if !ok2 {return -1}
	if f64(new_len) != num {
		throw_range_error(ctx, "invalid array length")
		return -1
	}
	nd := d^
	nd.value = mk_u32(new_len)
	old_len := array_length_u32(o)
	if new_len >= old_len {
		return ordinary_define(ctx, o, pa(.A_length), &nd, throw_flag)
	}
	if .writable not_in o.shape.props[0].flags {return fail_define(ctx, pa(.A_length), throw_flag)}
	new_writable := !(.writable in nd.has && .writable not_in nd.flags)
	nd.has += {.writable}
	nd.flags += {.writable}
	// validate the rest of the descriptor (configurable/enumerable) before deleting anything
	{
		probe := nd
		probe.has -= {.value}
		if ordinary_define(ctx, o, pa(.A_length), &probe, false) == 0 {return fail_define(ctx, pa(.A_length), throw_flag)}
	}
	final_len, deleted_ok := array_truncate(ctx, o, old_len, new_len)
	o.slots[0].value = mk_u32(final_len)
	if !new_writable {
		set_property_flags(ctx.rt, o, 0, o.shape.props[0].flags - {.writable}, .data)
	}
	if !deleted_ok {return fail_define(ctx, pa(.A_length), throw_flag)}
	return 1
}

// Delete elements in [new_len, old_len) from the top; stops at a non-configurable element.
@(private = "file")
array_truncate :: proc(ctx: ^Context, o: ^Object, old_len, new_len: u32) -> (u32, bool) {
	if o.fast_array {
		ad := &o.data.(Array_Data)
		if ad.count > new_len {ad.count = new_len}
		return new_len, true
	}
	// slow array: collect index keys >= new_len, delete from the highest
	keys := make([dynamic]u32, 0, 16, tmp(ctx.rt))
	for p in o.shape.props {
		if idx, isi := atom_array_index(p.atom); isi && idx >= new_len {append(&keys, idx)}
	}
	sort_u32_desc(keys[:])
	for k in keys {
		i := shape_find(o.shape, atom_from_u32(k))
		if i < 0 {continue}
		if .configurable not_in o.shape.props[i].flags {
			return k + 1, false
		}
		remove_property_at(ctx.rt, o, i)
	}
	return new_len, true
}

sort_u32_desc :: proc(a: []u32) {
	// insertion sort for small inputs, otherwise a simple heap sort (no allocation)
	n := len(a)
	if n < 32 {
		for i in 1 ..< n {
			x := a[i]
			j := i
			for j > 0 && a[j - 1] < x {a[j] = a[j - 1]; j -= 1}
			a[j] = x
		}
		return
	}
	sort_u32_asc(a)
	for i in 0 ..< n / 2 {a[i], a[n - 1 - i] = a[n - 1 - i], a[i]}
}

sort_u32_asc :: proc(a: []u32) {
	n := len(a)
	sift :: proc(a: []u32, start, end: int) {
		root := start
		for {
			child := 2 * root + 1
			if child > end {return}
			sw := root
			if a[sw] < a[child] {sw = child}
			if child + 1 <= end && a[sw] < a[child + 1] {sw = child + 1}
			if sw == root {return}
			a[root], a[sw] = a[sw], a[root]
			root = sw
		}
	}
	for start := (n - 2) / 2; start >= 0; start -= 1 {sift(a, start, n - 1)}
	for end := n - 1; end > 0; end -= 1 {
		a[0], a[end] = a[end], a[0]
		sift(a, 0, end - 1)
	}
}

// Set an array's length from a script value ([[Set]] on "length").
array_set_length :: proc(ctx: ^Context, o: ^Object, v: Value, throw_flag: bool) -> int {
	d := Prop_Desc{value = v, has = {.value}}
	return array_define_length(ctx, o, &d, throw_flag)
}

// --- mapped arguments (§10.4.4) ---

@(private = "file")
mapped_args_define :: proc(ctx: ^Context, o: ^Object, a: Atom, d: ^Prop_Desc, throw_flag: bool) -> int {
	i := shape_find(o.shape, a)
	if i < 0 || o.shape.props[i].kind != .var_ref {
		return ordinary_define(ctx, o, a, d, throw_flag)
	}
	vr := o.slots[i].var_ref
	nd := d^
	if desc_is_data(d) && .value not_in d.has && .writable in d.has && .writable not_in d.flags {
		nd.value = vr.pvalue^
		nd.has += {.value}
	}
	// apply the ordinary algorithm on a plain data view of the property, then re-establish or drop
	// the mapping
	cur := vr.pvalue^
	flags := o.shape.props[i].flags
	set_property_flags(ctx.rt, o, i, flags, .data)
	o.slots[i].value = cur
	r := ordinary_define(ctx, o, a, &nd, throw_flag)
	if r != 1 {
		// restore the mapping
		i2 := shape_find(o.shape, a)
		if i2 >= 0 && o.shape.props[i2].kind == .data {
			set_property_flags(ctx.rt, o, i2, o.shape.props[i2].flags, .var_ref)
			o.slots[i2].var_ref = vr
		}
		return r
	}
	i2 := shape_find(o.shape, a)
	keep_mapped := !desc_is_accessor(d) && !(.writable in d.has && .writable not_in d.flags)
	if .value in d.has && !desc_is_accessor(d) {vr.pvalue^ = d.value}
	if keep_mapped && i2 >= 0 && o.shape.props[i2].kind == .data {
		set_property_flags(ctx.rt, o, i2, o.shape.props[i2].flags, .var_ref)
		o.slots[i2].var_ref = vr
	}
	return 1
}

// --- [[HasProperty]] ---

has_property :: proc(ctx: ^Context, o_in: ^Object, a: Atom) -> int {
	o := o_in
	for o != nil {
		if o.class == .proxy {return proxy_has(ctx, o, a)}
		if is_typed_array_class(o.class) {
			if n, isnum := atom_canonical_numeric(ctx, a); isnum {
				_, valid := typed_array_get_index(ctx, o, n)
				return valid ? 1 : 0
			}
		}
		r := get_own_property(ctx, o, a, nil)
		if r != 0 {return r}
		o = o.shape.proto
	}
	return 0
}

// --- [[Get]] ---

get_property :: proc(ctx: ^Context, obj: Value, a: Atom, receiver: Value) -> Value {
	rt := ctx.rt
	o: ^Object
	#partial switch obj.tag {
	case .object:
		o = as_obj(obj)
	case .string:
		s := as_str(obj)
		if idx, isi := atom_array_index(a); isi {
			if idx < s.len {return mk_str(str_from_code_unit(rt, str_char_at(rt, s, int(idx))))}
		} else if a == pa(.A_length) {
			return mk_u32(s.len)
		}
		o = ctx.class_proto[.string]
	case .int, .float:
		o = ctx.class_proto[.number]
	case .bool:
		o = ctx.class_proto[.boolean]
	case .symbol:
		o = ctx.class_proto[.symbol]
	case .bigint:
		o = ctx.class_proto[.bigint]
	case .undefined, .null:
		return throw_type_error(ctx, cat(ctx, "cannot read property '", atom_utf8(rt, a), "' of ", is_null(obj) ? "null" : "undefined"))
	case:
		return UNDEFINED
	}
	for o != nil {
		i := shape_find(o.shape, a)
		if i >= 0 {
			p := o.shape.props[i]
			s := &o.slots[i]
			switch p.kind {
			case .data:
				v := s.value
				root(rt, v)
				return v
			case .accessor:
				g := s.getset.getter
				if g == nil {return UNDEFINED}
				return call(ctx, mk_obj(g), receiver, {})
			case .var_ref:
				v := s.var_ref.pvalue^
				if v.tag == .uninitialized {
					throw_reference_error_uninit(ctx, a)
					return EXCEPTION
				}
				root(rt, v)
				return v
			}
		}
		if o.fast_array {
			if idx, isi := atom_array_index(a); isi {
				ad := &o.data.(Array_Data)
				if idx < ad.count {
					v := ad.values[idx]
					root(rt, v)
					return v
				}
			}
		} else {
			#partial switch o.class {
			case .proxy:
				return proxy_get(ctx, o, a, receiver)
			case .string:
				if pd, ok := o.data.(Prim_Data); ok && is_string(pd.v) {
					s := as_str(pd.v)
					if idx, isi := atom_array_index(a); isi && idx < s.len {
						return mk_str(str_from_code_unit(rt, str_char_at(rt, s, int(idx))))
					}
				}
			case .module_ns:
				d: Prop_Desc
				r := module_ns_get_own(ctx, o, a, &d)
				if r < 0 {return EXCEPTION}
				if r == 1 {return d.value}
				return UNDEFINED
			case:
				if is_typed_array_class(o.class) {
					if n, isnum := atom_canonical_numeric(ctx, a); isnum {
						v, valid := typed_array_get_index(ctx, o, n)
						if !valid {return UNDEFINED}
						return v
					}
				}
			}
		}
		o = o.shape.proto
	}
	return UNDEFINED
}

get :: #force_inline proc(ctx: ^Context, obj: Value, a: Atom) -> Value {
	return get_property(ctx, obj, a, obj)
}

get_str :: proc(ctx: ^Context, obj: Value, name: string) -> Value {
	return get_property(ctx, obj, atom_from_utf8(ctx.rt, name), obj)
}

// obj[key] for an arbitrary key value.
get_by_value :: proc(ctx: ^Context, obj: Value, key: Value) -> Value {
	if obj.tag == .object && key.tag == .int && key.u.i >= 0 {
		o := as_obj(obj)
		if o.fast_array {
			ad := &o.data.(Array_Data)
			if u32(key.u.i) < ad.count {return ad.values[key.u.i]}
		}
		if is_typed_array_class(o.class) {
			v, valid := typed_array_get_index(ctx, o, f64(key.u.i))
			if valid {return v}
			return UNDEFINED
		}
		return get_property(ctx, obj, atom_from_u32(u32(key.u.i)), obj)
	}
	if is_nullish(obj) {
		ks := "symbol"
		if key.tag != .symbol {
			ksv := to_str(ctx, key)
			if ksv == nil {return EXCEPTION}
			ks = str_to_utf8(ctx.rt, ksv, tmp(ctx.rt))
		}
		return throw_type_error(ctx, cat(ctx, "cannot read property '", ks, "' of ", is_null(obj) ? "null" : "undefined"))
	}
	a, ok := to_property_key(ctx, key)
	if !ok {return EXCEPTION}
	return get_property(ctx, obj, a, obj)
}

get_index :: proc(ctx: ^Context, obj: Value, idx: i64) -> Value {
	if idx >= 0 && idx <= i64(ATOM_MAX_INT) {
		if obj.tag == .object {
			o := as_obj(obj)
			if o.fast_array {
				ad := &o.data.(Array_Data)
				if u32(idx) < ad.count {
					v := ad.values[idx]
					root(ctx.rt, v)
					return v
				}
			}
		}
		return get_property(ctx, obj, atom_from_u32(u32(idx)), obj)
	}
	return get_property(ctx, obj, number_to_atom(ctx, f64(idx)), obj)
}

// --- [[Set]] ---

throw_read_only :: proc(ctx: ^Context, a: Atom) -> int {
	throw_type_error(ctx, cat(ctx, "'", atom_utf8(ctx.rt, a), "' is read-only"))
	return -1
}

@(private = "file")
fail_set :: #force_inline proc(ctx: ^Context, a: Atom, throw_flag: bool) -> int {
	if throw_flag {return throw_read_only(ctx, a)}
	return 0
}

set_property :: proc(ctx: ^Context, obj: Value, a: Atom, val: Value, receiver: Value, throw_flag: bool) -> int {
	rt := ctx.rt
	p: ^Object
	#partial switch obj.tag {
	case .object:
		p = as_obj(obj)
	case .undefined, .null:
		throw_type_error(ctx, cat(ctx, "cannot set property '", atom_utf8(rt, a), "' of ", is_null(obj) ? "null" : "undefined"))
		return -1
	case .string:
		s := as_str(obj)
		if idx, isi := atom_array_index(a); isi && idx < s.len {return fail_set(ctx, a, throw_flag)}
		if a == pa(.A_length) {return fail_set(ctx, a, throw_flag)}
		p = ctx.class_proto[.string]
	case .int, .float:
		p = ctx.class_proto[.number]
	case .bool:
		p = ctx.class_proto[.boolean]
	case .symbol:
		p = ctx.class_proto[.symbol]
	case .bigint:
		p = ctx.class_proto[.bigint]
	case:
		return 0
	}
	recv_obj: ^Object = receiver.tag == .object ? as_obj(receiver) : nil
	for p != nil {
		i := shape_find(p.shape, a)
		if i >= 0 {
			prop := p.shape.props[i]
			s := &p.slots[i]
			if prop.kind == .accessor {
				st := s.getset.setter
				if st == nil {return fail_set(ctx, a, throw_flag)}
				r := call(ctx, mk_obj(st), receiver, {val})
				if is_exception(r) {return -1}
				return 1
			}
			if .writable not_in prop.flags {return fail_set(ctx, a, throw_flag)}
			if p == recv_obj {
				if prop.kind == .var_ref {
					if s.var_ref.pvalue^.tag == .uninitialized {
						throw_reference_error_uninit(ctx, a)
						return -1
					}
					s.var_ref.pvalue^ = val
					return 1
				}
				if p.class == .array && a == pa(.A_length) {return array_set_length(ctx, p, val, throw_flag)}
				s.value = val
				return 1
			}
			break
		}
		// exotic own properties not stored in the shape
		if p.fast_array {
			if idx, isi := atom_array_index(a); isi {
				ad := &p.data.(Array_Data)
				if idx < ad.count {
					if p == recv_obj {ad.values[idx] = val; return 1}
					break
				}
			}
		} else {
			#partial switch p.class {
			case .proxy:
				return proxy_set(ctx, p, a, val, receiver, throw_flag)
			case .string:
				if pd, ok := p.data.(Prim_Data); ok && is_string(pd.v) {
					if idx, isi := atom_array_index(a); isi && idx < as_str(pd.v).len {return fail_set(ctx, a, throw_flag)}
				}
			case .module_ns:
				return fail_set(ctx, a, throw_flag)
			case:
				if is_typed_array_class(p.class) {
					if n, isnum := atom_canonical_numeric(ctx, a); isnum {
						if p == recv_obj {
							if !typed_array_set_index(ctx, p, n, val) {return -1}
							return 1
						}
						if _, valid := typed_array_get_index(ctx, p, n); !valid {return 1}
						break
					}
				}
			}
		}
		p = p.shape.proto
	}
	// define on the receiver
	if recv_obj == nil {return fail_set(ctx, a, throw_flag)}
	r := recv_obj
	if r.class == .proxy || is_typed_array_class(r.class) || r.class == .module_ns || r.class == .string || r.class == .mapped_arguments || r.class == .array || r.class == .arguments {
		ed: Prop_Desc
		res := get_own_property(ctx, r, a, &ed)
		if res < 0 {return -1}
		if res == 1 {
			if desc_is_accessor(&ed) || .writable not_in ed.flags {return fail_set(ctx, a, throw_flag)}
			nd := Prop_Desc{value = val, has = {.value}}
			return define_own_property(ctx, r, a, nd, throw_flag)
		}
		return define_own_property(ctx, r, a, data_desc(val, CWE), throw_flag)
	}
	i := shape_find(r.shape, a)
	if i >= 0 {
		prop := r.shape.props[i]
		if prop.kind == .accessor || .writable not_in prop.flags {return fail_set(ctx, a, throw_flag)}
		if prop.kind == .var_ref {r.slots[i].var_ref.pvalue^ = val} else {r.slots[i].value = val}
		return 1
	}
	if !r.extensible {
		if throw_flag {
			throw_type_error(ctx, cat(ctx, "cannot add property '", atom_utf8(rt, a), "': object is not extensible"))
			return -1
		}
		return 0
	}
	s := add_property(rt, r, a, CWE)
	s.value = val
	return 1
}

set :: #force_inline proc(ctx: ^Context, obj: Value, a: Atom, val: Value, throw_flag := true) -> int {
	return set_property(ctx, obj, a, val, obj, throw_flag)
}

set_by_value :: proc(ctx: ^Context, obj: Value, key: Value, val: Value, throw_flag: bool) -> int {
	if obj.tag == .object && key.tag == .int && key.u.i >= 0 {
		o := as_obj(obj)
		if o.fast_array && o.class == .array {
			ad := &o.data.(Array_Data)
			idx := u32(key.u.i)
			if idx < ad.count {ad.values[idx] = val; return 1}
		}
		if is_typed_array_class(o.class) {
			if !typed_array_set_index(ctx, o, f64(key.u.i), val) {return -1}
			return 1
		}
		return set_property(ctx, obj, atom_from_u32(u32(key.u.i)), val, obj, throw_flag)
	}
	if is_nullish(obj) {
		throw_type_error(ctx, cat(ctx, "cannot set property of ", is_null(obj) ? "null" : "undefined"))
		return -1
	}
	a, ok := to_property_key(ctx, key)
	if !ok {return -1}
	return set_property(ctx, obj, a, val, obj, throw_flag)
}

set_index :: proc(ctx: ^Context, obj: Value, idx: i64, val: Value, throw_flag := true) -> int {
	a := idx >= 0 && idx <= i64(ATOM_MAX_INT) ? atom_from_u32(u32(idx)) : number_to_atom(ctx, f64(idx))
	return set_property(ctx, obj, a, val, obj, throw_flag)
}

// CreateDataProperty / CreateDataPropertyOrThrow.
create_data_property :: proc(ctx: ^Context, o: ^Object, a: Atom, val: Value, throw_flag := true) -> int {
	if o.fast_array && o.class == .array && o.extensible {
		if idx, isi := atom_array_index(a); isi {
			ad := &o.data.(Array_Data)
			if idx < ad.count {ad.values[idx] = val; return 1}
			if idx == ad.count && idx == array_length_u32(o) && .writable in o.shape.props[0].flags {
				array_push_fast(ctx.rt, o, val)
				return 1
			}
		}
	}
	return define_own_property(ctx, o, a, data_desc(val, CWE), throw_flag)
}

create_data_index :: proc(ctx: ^Context, o: ^Object, idx: i64, val: Value, throw_flag := true) -> int {
	a := idx >= 0 && idx <= i64(ATOM_MAX_INT) ? atom_from_u32(u32(idx)) : number_to_atom(ctx, f64(idx))
	return create_data_property(ctx, o, a, val, throw_flag)
}

// Define a property on a fresh object known not to have it (builtins setup, literals).
define_value :: proc(ctx: ^Context, o: ^Object, a: Atom, val: Value, flags: Prop_Flags = CW) -> int {
	return define_own_property(ctx, o, a, data_desc(val, flags), true)
}

// --- [[Delete]] ---

delete_property :: proc(ctx: ^Context, o: ^Object, a: Atom) -> int {
	#partial switch o.class {
	case .proxy:
		return proxy_delete(ctx, o, a)
	case .string:
		if pd, ok := o.data.(Prim_Data); ok && is_string(pd.v) {
			if idx, isi := atom_array_index(a); isi && idx < as_str(pd.v).len {return 0}
		}
	case .module_ns:
		return module_ns_delete(ctx, o, a)
	case:
		if is_typed_array_class(o.class) {
			if n, isnum := atom_canonical_numeric(ctx, a); isnum {
				_, valid := typed_array_get_index(ctx, o, n)
				return valid ? 0 : 1
			}
		}
	}
	if o.fast_array {
		if idx, isi := atom_array_index(a); isi {
			ad := &o.data.(Array_Data)
			if idx >= ad.count {return 1}
			if idx == ad.count - 1 {
				ad.count -= 1
				return 1
			}
			convert_to_slow_array(ctx, o)
		}
	}
	i := shape_find(o.shape, a)
	if i < 0 {return 1}
	if .configurable not_in o.shape.props[i].flags {return 0}
	remove_property_at(ctx.rt, o, i)
	return 1
}

// delete obj[key] with strict-mode failure reporting.
delete_property_value :: proc(ctx: ^Context, obj: Value, key: Value, strict: bool) -> int {
	ov := to_object(ctx, obj)
	if is_exception(ov) {return -1}
	a, ok := to_property_key(ctx, key)
	if !ok {return -1}
	r := delete_property(ctx, as_obj(ov), a)
	if r == 0 && strict {
		throw_type_error(ctx, cat(ctx, "cannot delete property '", atom_utf8(ctx.rt, a), "'"))
		return -1
	}
	return r
}

// --- [[OwnPropertyKeys]] ---

Keys_Filter :: enum u8 {strings, symbols, private_}
Keys_Filters :: bit_set[Keys_Filter;u8]

// Collect the own keys of `o` in spec order: integer indices ascending, then strings, then symbols,
// each in creation order. The caller owns `out` (allocated in `allocator`).
own_property_keys :: proc(ctx: ^Context, o: ^Object, out: ^[dynamic]Atom, filter: Keys_Filters = {.strings, .symbols}) -> bool {
	if o.class == .proxy {return proxy_own_keys(ctx, o, out, filter)}
	rt := ctx.rt
	if .strings in filter {
		n: u32 = 0
		if o.fast_array {
			n = o.data.(Array_Data).count
		} else if o.class == .string {
			if pd, ok := o.data.(Prim_Data); ok && is_string(pd.v) {n = as_str(pd.v).len}
		} else if is_typed_array_class(o.class) {
			n = u32(typed_array_length(ctx, o))
		} else if o.class == .module_ns {
			return module_ns_own_keys(ctx, o, out, filter)
		}
		for i in 0 ..< n {append(out, atom_from_u32(i))}
		// integer keys stored in the shape (slow arrays, ordinary objects), sorted
		start := len(out)
		for p in o.shape.props {
			if atom_is_int(p.atom) {append(out, p.atom)}
		}
		if len(out) - start > 1 {
			sort_u32_asc(out[start:])
		}
		for p in o.shape.props {
			if !atom_is_int(p.atom) && !atom_is_symbol(rt, p.atom) {append(out, p.atom)}
		}
	}
	if .symbols in filter || .private_ in filter {
		for p in o.shape.props {
			if atom_is_int(p.atom) {continue}
			k := rt.atoms[p.atom].kind
			if k == .private {
				if .private_ in filter {append(out, p.atom)}
			} else if k != .string && .symbols in filter {
				append(out, p.atom)
			}
		}
	}
	return true
}

// Is own property `a` enumerable? (-1 exception, 0 not found / not enumerable, 1 yes)
own_enumerable :: proc(ctx: ^Context, o: ^Object, a: Atom) -> int {
	d: Prop_Desc
	r := get_own_property(ctx, o, a, &d)
	if r <= 0 {return r}
	return .enumerable in d.flags ? 1 : 0
}

// --- prototype and extensibility ---

// [[GetPrototypeOf]]: an object, NULL or EXCEPTION.
get_prototype_of :: proc(ctx: ^Context, o: ^Object) -> Value {
	if o.class == .proxy {return proxy_get_prototype_of(ctx, o)}
	return obj_or_null(o.shape.proto)
}

// [[SetPrototypeOf]].
set_prototype_of :: proc(ctx: ^Context, o: ^Object, proto: ^Object, throw_flag: bool) -> int {
	if o.class == .proxy {return proxy_set_prototype_of(ctx, o, proto, throw_flag)}
	cur := o.shape.proto
	if cur == proto {return 1}
	if o == ctx.class_proto[.object] || (o.class == .object && is_immutable_proto(ctx, o)) {
		if throw_flag {throw_type_error(ctx, "immutable prototype"); return -1}
		return 0
	}
	if !o.extensible {
		if throw_flag {throw_type_error(ctx, "object is not extensible"); return -1}
		return 0
	}
	for p := proto; p != nil; p = p.shape.proto {
		if p == o {
			if throw_flag {throw_type_error(ctx, "circular prototype chain"); return -1}
			return 0
		}
		if p.class == .proxy {break}
	}
	set_object_proto(ctx.rt, o, proto)
	return 1
}

@(private = "file")
is_immutable_proto :: proc(ctx: ^Context, o: ^Object) -> bool {
	for c in ctx.rt.contexts {
		if c.class_proto[.object] == o {return true}
	}
	return false
}

is_extensible :: proc(ctx: ^Context, o: ^Object) -> int {
	if o.class == .proxy {return proxy_is_extensible(ctx, o)}
	return o.extensible ? 1 : 0
}

prevent_extensions :: proc(ctx: ^Context, o: ^Object) -> int {
	if o.class == .proxy {return proxy_prevent_extensions(ctx, o)}
	if is_typed_array_class(o.class) && !typed_array_is_fixed_length(o) {return 0}
	o.extensible = false
	return 1
}

// --- descriptors <-> objects ---

// ToPropertyDescriptor.
to_property_descriptor :: proc(ctx: ^Context, v: Value, d: ^Prop_Desc) -> bool {
	if v.tag != .object {
		throw_type_error(ctx, "property descriptor must be an object")
		return false
	}
	o := as_obj(v)
	d^ = Prop_Desc{value = UNDEFINED, getter = UNDEFINED, setter = UNDEFINED}
	fields := [6]struct {
		a: Atom,
		f: Desc_Field,
	}{
		{pa(.A_enumerable), .enumerable},
		{pa(.A_configurable), .configurable},
		{pa(.A_value), .value},
		{pa(.A_writable), .writable},
		{pa(.A_get), .get},
		{pa(.A_set), .set},
	}
	for f in fields {
		h := has_property(ctx, o, f.a)
		if h < 0 {return false}
		if h == 0 {continue}
		x := get(ctx, v, f.a)
		if is_exception(x) {return false}
		d.has += {f.f}
		switch f.f {
		case .enumerable:
			if to_boolean(x) {d.flags += {.enumerable}}
		case .configurable:
			if to_boolean(x) {d.flags += {.configurable}}
		case .writable:
			if to_boolean(x) {d.flags += {.writable}}
		case .value:
			d.value = x
		case .get:
			if !is_undefined(x) && !is_callable(x) {
				throw_type_error(ctx, "getter must be a function")
				return false
			}
			d.getter = x
		case .set:
			if !is_undefined(x) && !is_callable(x) {
				throw_type_error(ctx, "setter must be a function")
				return false
			}
			d.setter = x
		}
	}
	if desc_is_accessor(d) && desc_is_data(d) {
		throw_type_error(ctx, "cannot have both a value and an accessor")
		return false
	}
	return true
}

// FromPropertyDescriptor.
from_property_descriptor :: proc(ctx: ^Context, d: ^Prop_Desc) -> Value {
	o := new_plain_object(ctx)
	if .value in d.has {define_value(ctx, o, pa(.A_value), d.value, CWE)}
	if .writable in d.has {define_value(ctx, o, pa(.A_writable), mk_bool(.writable in d.flags), CWE)}
	if .get in d.has {define_value(ctx, o, pa(.A_get), d.getter, CWE)}
	if .set in d.has {define_value(ctx, o, pa(.A_set), d.setter, CWE)}
	if .enumerable in d.has {define_value(ctx, o, pa(.A_enumerable), mk_bool(.enumerable in d.flags), CWE)}
	if .configurable in d.has {define_value(ctx, o, pa(.A_configurable), mk_bool(.configurable in d.flags), CWE)}
	return mk_obj(o)
}

// CompletePropertyDescriptor.
complete_property_descriptor :: proc(d: ^Prop_Desc) {
	if !desc_is_accessor(d) {
		if .value not_in d.has {d.value = UNDEFINED}
		d.has += {.value, .writable}
	} else {
		if .get not_in d.has {d.getter = UNDEFINED}
		if .set not_in d.has {d.setter = UNDEFINED}
		d.has += {.get, .set}
	}
	d.has += {.enumerable, .configurable}
}

// IsCompatiblePropertyDescriptor (used by Proxy invariants).
is_compatible_descriptor :: proc(ctx: ^Context, extensible: bool, d: ^Prop_Desc, cur: ^Prop_Desc, has_cur: bool) -> bool {
	if !has_cur {return extensible}
	if .configurable not_in cur.flags {
		if .configurable in d.has && .configurable in d.flags {return false}
		if .enumerable in d.has && (.enumerable in d.flags) != (.enumerable in cur.flags) {return false}
		if desc_is_accessor(d) || desc_is_data(d) {
			if desc_is_accessor(cur) != desc_is_accessor(d) {return false}
			if desc_is_accessor(cur) {
				if .get in d.has && !same_value(ctx, d.getter, cur.getter) {return false}
				if .set in d.has && !same_value(ctx, d.setter, cur.setter) {return false}
			} else if .writable not_in cur.flags {
				if .writable in d.has && .writable in d.flags {return false}
				if .value in d.has && !same_value(ctx, d.value, cur.value) {return false}
			}
		}
	}
	return true
}

// SetIntegrityLevel / TestIntegrityLevel.
set_integrity_level :: proc(ctx: ^Context, o: ^Object, frozen: bool) -> int {
	r := prevent_extensions(ctx, o)
	if r <= 0 {return r}
	keys := make([dynamic]Atom, 0, 16, tmp(ctx.rt))
	if !own_property_keys(ctx, o, &keys) {return -1}
	if o.fast_array && !frozen {
		// sealing keeps elements writable: convert so attributes can differ from CWE
		convert_to_slow_array(ctx, o)
	} else if o.fast_array {
		convert_to_slow_array(ctx, o)
	}
	for k in keys {
		if !frozen {
			d := Prop_Desc{has = {.configurable}}
			if define_own_property(ctx, o, k, d, true) < 0 {return -1}
		} else {
			cur: Prop_Desc
			g := get_own_property(ctx, o, k, &cur)
			if g < 0 {return -1}
			if g == 0 {continue}
			d: Prop_Desc
			if desc_is_accessor(&cur) {
				d = Prop_Desc{has = {.configurable}}
			} else {
				d = Prop_Desc{has = {.configurable, .writable}}
			}
			if define_own_property(ctx, o, k, d, true) < 0 {return -1}
		}
	}
	return 1
}

test_integrity_level :: proc(ctx: ^Context, o: ^Object, frozen: bool) -> int {
	e := is_extensible(ctx, o)
	if e < 0 {return -1}
	if e == 1 {return 0}
	keys := make([dynamic]Atom, 0, 16, tmp(ctx.rt))
	if !own_property_keys(ctx, o, &keys) {return -1}
	for k in keys {
		d: Prop_Desc
		r := get_own_property(ctx, o, k, &d)
		if r < 0 {return -1}
		if r == 0 {continue}
		if .configurable in d.flags {return 0}
		if frozen && desc_is_data(&d) && .writable in d.flags {return 0}
	}
	return 1
}

// --- misc ---

// The length of an array-like object (LengthOfArrayLike).
length_of_array_like :: proc(ctx: ^Context, obj: Value) -> (i64, bool) {
	if obj.tag == .object {
		o := as_obj(obj)
		if o.class == .array {return i64(array_length_u32(o)), true}
	}
	v := get(ctx, obj, pa(.A_length))
	if is_exception(v) {return 0, false}
	return to_length(ctx, v)
}

// GetMethod: undefined for nullish, TypeError when not callable.
get_method :: proc(ctx: ^Context, v: Value, a: Atom) -> Value {
	f := get(ctx, v, a)
	if is_exception(f) {return EXCEPTION}
	if is_nullish(f) {return UNDEFINED}
	if !is_callable(f) {return throw_type_error(ctx, cat(ctx, "'", atom_utf8(ctx.rt, a), "' is not a function"))}
	return f
}

// Invoke(V, P, args).
invoke :: proc(ctx: ^Context, v: Value, a: Atom, args: []Value) -> Value {
	f := get(ctx, v, a)
	if is_exception(f) {return EXCEPTION}
	return call(ctx, f, v, args)
}

f64_is_integer :: proc(d: f64) -> bool {
	return !math.is_nan(d) && !math.is_inf(d) && math.trunc(d) == d
}
