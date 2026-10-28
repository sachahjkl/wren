package jsrt

// Map, Set, WeakMap, WeakSet (insertion-ordered hash tables keyed by SameValueZero), WeakRef and
// FinalizationRegistry, and the Map/Set iterators.

import "core:math"

@(private = "file")
map_hash :: proc(rt: ^Runtime, v: Value) -> u32 {
	switch v.tag {
	case .int:
		return u32(v.u.i) * 0x9E3779B1
	case .float:
		d := v.u.f
		if d == math.trunc(d) && d >= -2147483648 && d <= 2147483647 {return u32(i32(d)) * 0x9E3779B1}
		if math.is_nan(d) {return 0x7ff80000}
		b := transmute(u64)d
		return u32(b ~ (b >> 32)) * 0x85EBCA6B
	case .string:
		return str_hash(rt, as_str(v))
	case .bool:
		return v.u.b ? 1 : 2
	case .undefined:
		return 3
	case .null:
		return 4
	case .bigint:
		b := as_big(v)
		h: u32 = b.val.neg ? 5 : 6
		for l in b.val.mag {h = (h ~ l) * 16777619}
		return h
	case .object, .symbol, .function_bc, .module:
		p := uintptr(v.u.ptr)
		return u32(p >> 4) * 0x9E3779B1 ~ u32(u64(p) >> 32)
	case .uninitialized, .exception, .catch_offset:
	}
	return 0
}

map_new :: proc(ctx: ^Context, proto: ^Object, class: Class_ID) -> ^Object {
	o := object_new_proto(ctx, proto, class)
	ms := new(Map_State, rt_allocator(ctx.rt))
	ms.entries = make([dynamic]Map_Entry, rt_allocator(ctx.rt))
	ms.is_weak = class == .weakmap || class == .weakset
	o.data = ms
	if ms.is_weak {append(&ctx.rt.weak_list, o)}
	return o
}

@(private = "file")
map_rehash :: proc(rt: ^Runtime, ms: ^Map_State) {
	size := 16
	for size < ms.live * 2 + 8 {size *= 2}
	if ms.index != nil {delete(ms.index, rt_allocator(rt))}
	ms.index = make([]i32, size, rt_allocator(rt))
	mask := u32(size - 1)
	for &e, i in ms.entries {
		if e.deleted {continue}
		h := map_hash(rt, e.key) & mask
		for ms.index[h] != 0 {h = (h + 1) & mask}
		ms.index[h] = i32(i + 1)
	}
}

// Index of the live entry with `key`, or -1.
map_find :: proc(rt: ^Runtime, ms: ^Map_State, key: Value) -> int {
	if ms.index == nil {
		for &e, i in ms.entries {
			if !e.deleted && map_key_eq(rt, e.key, key) {return i}
		}
		return -1
	}
	mask := u32(len(ms.index) - 1)
	h := map_hash(rt, key) & mask
	for {
		v := ms.index[h]
		if v == 0 {return -1}
		if v > 0 {
			e := &ms.entries[v - 1]
			if !e.deleted && map_key_eq(rt, e.key, key) {return int(v - 1)}
		}
		h = (h + 1) & mask
	}
}

@(private = "file")
map_key_eq :: proc(rt: ^Runtime, a, b: Value) -> bool {
	if is_number(a) && is_number(b) {
		x, y := as_f64(a), as_f64(b)
		if math.is_nan(x) {return math.is_nan(y)}
		return x == y
	}
	if a.tag != b.tag {return false}
	#partial switch a.tag {
	case .string:
		return str_eq(rt, as_str(a), as_str(b))
	case .bigint:
		bb := as_big(b)
		ab := as_big(a)
		if ab.val.neg != bb.val.neg || len(ab.val.mag) != len(bb.val.mag) {return false}
		for l, i in ab.val.mag {if l != bb.val.mag[i] {return false}}
		return true
	case .bool:
		return a.u.b == b.u.b
	case .undefined, .null:
		return true
	}
	return a.u.ptr == b.u.ptr
}

map_set :: proc(rt: ^Runtime, ms: ^Map_State, key: Value, val: Value) {
	k := key
	if k.tag == .float && k.u.f == 0 {k = mk_int(0)}
	i := map_find(rt, ms, k)
	if i >= 0 {
		ms.entries[i].value = val
		return
	}
	append(&ms.entries, Map_Entry{key = k, value = val})
	ms.live += 1
	if len(ms.entries) > 8 {
		if ms.index == nil || len(ms.entries) * 2 > len(ms.index) {
			map_rehash(rt, ms)
		} else {
			mask := u32(len(ms.index) - 1)
			h := map_hash(rt, k) & mask
			for ms.index[h] > 0 {h = (h + 1) & mask}
			ms.index[h] = i32(len(ms.entries))
		}
	}
}

map_delete_index :: proc(rt: ^Runtime, ms: ^Map_State, i: int) {
	e := &ms.entries[i]
	if e.deleted {return}
	if ms.index != nil {
		// tombstone the index slot (probe from the key's hash)
		mask := u32(len(ms.index) - 1)
		h := map_hash(rt, e.key) & mask
		for _ in 0 ..< len(ms.index) {
			v := ms.index[h]
			if v == 0 {break}
			if int(v) == i + 1 {ms.index[h] = -1; break}
			h = (h + 1) & mask
		}
	}
	e.deleted = true
	e.key = UNDEFINED
	e.value = UNDEFINED
	ms.live -= 1
	if ms.iterators == 0 && len(ms.entries) > 16 && ms.live < len(ms.entries) / 2 {
		map_compact(rt, ms)
	}
}

@(private = "file")
map_compact :: proc(rt: ^Runtime, ms: ^Map_State) {
	j := 0
	for i in 0 ..< len(ms.entries) {
		if !ms.entries[i].deleted {
			ms.entries[j] = ms.entries[i]
			j += 1
		}
	}
	resize(&ms.entries, j)
	if j > 8 {map_rehash(rt, ms)} else if ms.index != nil {
		delete(ms.index, rt_allocator(rt))
		ms.index = nil
	}
}

map_clear :: proc(rt: ^Runtime, ms: ^Map_State) {
	for &e in ms.entries {
		if !e.deleted {
			e.deleted = true
			e.key = UNDEFINED
			e.value = UNDEFINED
		}
	}
	ms.live = 0
	if ms.iterators == 0 {
		clear(&ms.entries)
		if ms.index != nil {delete(ms.index, rt_allocator(rt)); ms.index = nil}
	} else if ms.index != nil {
		for &v in ms.index {v = 0}
	}
}

map_iterator_release :: proc(st: ^Iter_State) {
	if st.target.tag == .object {
		if ms, ok := as_obj(st.target).data.(^Map_State); ok && ms.iterators > 0 {ms.iterators -= 1}
	}
}

// --- constructors ---

@(private = "file")
can_be_held_weakly :: proc(rt: ^Runtime, v: Value) -> bool {
	if v.tag == .object {return true}
	if v.tag == .symbol {return !as_sym(v).is_registered}
	return false
}

// Map (class map) / Set / WeakMap / WeakSet constructors; magic = class.
@(private = "file")
collection_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	class := Class_ID(magic)
	proto, ok := proto_from_ctor(ctx, nt, class)
	if !ok {return EXCEPTION}
	o := map_new(ctx, proto, class)
	iterable := arg(args, 0)
	if is_nullish(iterable) {return mk_obj(o)}
	is_map := class == .jsmap || class == .weakmap
	adder := get(ctx, mk_obj(o), is_map ? pa(.A_set) : pa(.A_add))
	if is_exception(adder) {return EXCEPTION}
	if !is_callable(adder) {return throw_type_error(ctx, "adder is not a function")}
	it := get_iterator(ctx, iterable, false)
	if is_exception(it) {return EXCEPTION}
	next := get(ctx, it, pa(.A_next))
	if is_exception(next) {return EXCEPTION}
	m := temp_mark(rt)
	for {
		temp_reset(rt, m)
		v, done, ok2 := iterator_step_value(ctx, it, next)
		if !ok2 {return EXCEPTION}
		if done {break}
		r: Value
		if is_map {
			if v.tag != .object {
				throw_type_error(ctx, "iterator value is not an entry object")
				iterator_close(ctx, it, true)
				return EXCEPTION
			}
			k := get_index(ctx, v, 0)
			if is_exception(k) {iterator_close(ctx, it, true); return EXCEPTION}
			val := get_index(ctx, v, 1)
			if is_exception(val) {iterator_close(ctx, it, true); return EXCEPTION}
			r = call(ctx, adder, mk_obj(o), {k, val})
		} else {
			r = call(ctx, adder, mk_obj(o), {v})
		}
		if is_exception(r) {iterator_close(ctx, it, true); return EXCEPTION}
	}
	return mk_obj(o)
}

@(private = "file")
this_map :: proc(ctx: ^Context, this: Value, class: Class_ID) -> ^Map_State {
	if this.tag == .object {
		o := as_obj(this)
		if o.class == class {
			if ms, ok := o.data.(^Map_State); ok {return ms}
		}
	}
	names := [Class_ID]string{}
	_ = names
	throw_type_error(ctx, "incompatible receiver")
	return nil
}

// methods: magic encodes (class << 4) | op
MAP_GET :: 0
MAP_SET :: 1
MAP_HAS :: 2
MAP_DELETE :: 3
MAP_CLEAR :: 4
MAP_SIZE :: 5
MAP_ADD :: 6
MAP_GET_OR_INSERT :: 7
MAP_GET_OR_INSERT_COMPUTED :: 8

@(private = "file")
collection_method :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	class := Class_ID(magic >> 4)
	op := magic & 15
	ms := this_map(ctx, this, class)
	if ms == nil {return EXCEPTION}
	key := arg(args, 0)
	weak := ms.is_weak
	switch op {
	case MAP_GET:
		if weak && !can_be_held_weakly(rt, key) {return UNDEFINED}
		i := map_find(rt, ms, key)
		return i < 0 ? UNDEFINED : ms.entries[i].value
	case MAP_SET:
		if weak && !can_be_held_weakly(rt, key) {return throw_type_error(ctx, "invalid value used as weak map key")}
		map_set(rt, ms, key, arg(args, 1))
		return this
	case MAP_ADD:
		if weak && !can_be_held_weakly(rt, key) {return throw_type_error(ctx, "invalid value used in weak set")}
		if map_find(rt, ms, key) < 0 {map_set(rt, ms, key, UNDEFINED)}
		return this
	case MAP_HAS:
		if weak && !can_be_held_weakly(rt, key) {return FALSE}
		return mk_bool(map_find(rt, ms, key) >= 0)
	case MAP_DELETE:
		if weak && !can_be_held_weakly(rt, key) {return FALSE}
		i := map_find(rt, ms, key)
		if i < 0 {return FALSE}
		map_delete_index(rt, ms, i)
		return TRUE
	case MAP_CLEAR:
		map_clear(rt, ms)
		return UNDEFINED
	case MAP_SIZE:
		return mk_int(i32(ms.live))
	case MAP_GET_OR_INSERT, MAP_GET_OR_INSERT_COMPUTED:
		if weak && !can_be_held_weakly(rt, key) {return throw_type_error(ctx, "invalid value used as weak map key")}
		k := key
		if k.tag == .float && k.u.f == 0 {k = mk_int(0)}
		i := map_find(rt, ms, k)
		if i >= 0 {return ms.entries[i].value}
		v := arg(args, 1)
		if op == MAP_GET_OR_INSERT_COMPUTED {
			if !is_callable(v) {return throw_type_error(ctx, "callback is not a function")}
			v = call(ctx, v, UNDEFINED, {k})
			if is_exception(v) {return EXCEPTION}
		}
		map_set(rt, ms, k, v)
		return v
	}
	return UNDEFINED
}

@(private = "file")
collection_for_each :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	ms := this_map(ctx, this, Class_ID(magic))
	if ms == nil {return EXCEPTION}
	cb := arg(args, 0)
	if !is_callable(cb) {return throw_type_error(ctx, "callback is not a function")}
	this_arg := arg(args, 1)
	ms.iterators += 1
	defer ms.iterators -= 1
	m := temp_mark(rt)
	for i := 0; i < len(ms.entries); i += 1 {
		temp_reset(rt, m)
		e := ms.entries[i]
		if e.deleted {continue}
		root(rt, e.key)
		root(rt, e.value)
		r: Value
		if Class_ID(magic) == .set {
			r = call(ctx, cb, this_arg, {e.key, e.key, this})
		} else {
			r = call(ctx, cb, this_arg, {e.value, e.key, this})
		}
		if is_exception(r) {return EXCEPTION}
	}
	return UNDEFINED
}

// keys / values / entries: magic = (class << 4) | kind (0 keys, 1 values, 2 entries)
@(private = "file")
collection_iter :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	class := Class_ID(magic >> 4)
	ms := this_map(ctx, this, class)
	if ms == nil {return EXCEPTION}
	kind: Iter_Kind
	if class == .jsmap {
		kinds := [3]Iter_Kind{.map_keys, .map_values, .map_entries}
		kind = kinds[magic & 15]
	} else {
		kind = (magic & 15) == 2 ? .set_entries : .set_values
	}
	pcls: Class_ID = class == .jsmap ? .map_iterator : .set_iterator
	it := iter_state_new(ctx, ctx.class_proto[pcls], pcls, kind, this)
	ms.iterators += 1
	return mk_obj(it)
}

@(private = "file")
collection_iter_next :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	cls := Class_ID(magic)
	if this.tag != .object || as_obj(this).class != cls {return throw_type_error(ctx, "incompatible iterator")}
	st := as_obj(this).data.(^Iter_State)
	if st.done {return iter_result(ctx, UNDEFINED, true)}
	ms := as_obj(st.target).data.(^Map_State)
	for st.index < i64(len(ms.entries)) {
		e := ms.entries[st.index]
		st.index += 1
		if e.deleted {continue}
		v: Value
		#partial switch st.kind {
		case .map_keys, .set_values:
			v = e.key
		case .map_values:
			v = e.value
		case .map_entries:
			v = mk_obj(array_from_values(ctx, {e.key, e.value}))
		case .set_entries:
			v = mk_obj(array_from_values(ctx, {e.key, e.key}))
		}
		return iter_result(ctx, v, false)
	}
	st.done = true
	if ms.iterators > 0 {ms.iterators -= 1}
	st.target = UNDEFINED
	_ = rt
	return iter_result(ctx, UNDEFINED, true)
}

// --- Set methods (union, intersection, ...) ---

// GetSetRecord(obj): size, has, keys
@(private = "file")
Set_Record :: struct {
	obj:  Value,
	size: f64,
	has:  Value,
	keys: Value,
}

@(private = "file")
get_set_record :: proc(ctx: ^Context, v: Value) -> (Set_Record, bool) {
	if v.tag != .object {
		throw_type_error(ctx, "argument is not an object")
		return {}, false
	}
	rs := get(ctx, v, pa(.A_size))
	if is_exception(rs) {return {}, false}
	n, ok := to_number(ctx, rs)
	if !ok {return {}, false}
	if n != n {
		throw_type_error(ctx, "size is NaN")
		return {}, false
	}
	isz, _ := to_integer(ctx, mk_number(n))
	if isz < 0 {
		throw_range_error(ctx, "invalid size")
		return {}, false
	}
	has := get(ctx, v, pa(.A_has))
	if is_exception(has) {return {}, false}
	if !is_callable(has) {
		throw_type_error(ctx, "has is not a function")
		return {}, false
	}
	keys := get(ctx, v, pa(.A_keys))
	if is_exception(keys) {return {}, false}
	if !is_callable(keys) {
		throw_type_error(ctx, "keys is not a function")
		return {}, false
	}
	return Set_Record{v, isz, has, keys}, true
}

@(private = "file")
set_copy :: proc(ctx: ^Context, ms: ^Map_State) -> ^Object {
	o := map_new(ctx, ctx.class_proto[.set], .set)
	ns := o.data.(^Map_State)
	for &e in ms.entries {if !e.deleted {map_set(ctx.rt, ns, e.key, UNDEFINED)}}
	return o
}

// magic: 0 union, 1 intersection, 2 difference, 3 symmetricDifference, 4 isSubsetOf, 5 isSupersetOf, 6 isDisjointFrom
@(private = "file")
set_algebra :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	ms := this_map(ctx, this, .set)
	if ms == nil {return EXCEPTION}
	rec, ok := get_set_record(ctx, arg(args, 0))
	if !ok {return EXCEPTION}
	iterate_keys :: proc(ctx: ^Context, rec: Set_Record, fn: proc(ctx: ^Context, k: Value, data: rawptr) -> int, data: rawptr) -> int {
		it := call(ctx, rec.keys, rec.obj, {})
		if is_exception(it) {return -1}
		if it.tag != .object {throw_type_error(ctx, "keys() result is not an object"); return -1}
		next := get(ctx, it, pa(.A_next))
		if is_exception(next) {return -1}
		for {
			v, done, ok := iterator_step_value(ctx, it, next)
			if !ok {return -1}
			if done {return 0}
			r := fn(ctx, v, data)
			if r != 0 {
				if r > 0 {
					if iterator_close(ctx, it, false) < 0 {return -1}
				}
				return r
			}
		}
	}
	call_has :: proc(ctx: ^Context, rec: Set_Record, k: Value) -> int {
		r := call(ctx, rec.has, rec.obj, {k})
		if is_exception(r) {return -1}
		return to_boolean(r) ? 1 : 0
	}
	switch magic {
	case 0, 3:
		res := set_copy(ctx, ms)
		D :: struct {
			res: ^Map_State,
			src: ^Map_State,
			sym: bool,
		}
		d := D{res.data.(^Map_State), ms, magic == 3}
		r := iterate_keys(ctx, rec, proc(ctx: ^Context, k: Value, data: rawptr) -> int {
				d := cast(^D)data
				key := k
				if key.tag == .float && key.u.f == 0 {key = mk_int(0)}
				if d.sym {
					if map_find(ctx.rt, d.src, key) >= 0 {
						i := map_find(ctx.rt, d.res, key)
						if i >= 0 {map_delete_index(ctx.rt, d.res, i)}
					} else {
						map_set(ctx.rt, d.res, key, UNDEFINED)
					}
				} else {
					map_set(ctx.rt, d.res, key, UNDEFINED)
				}
				return 0
			}, &d)
		if r < 0 {return EXCEPTION}
		return mk_obj(res)
	case 1:
		res := map_new(ctx, ctx.class_proto[.set], .set)
		rs := res.data.(^Map_State)
		if f64(ms.live) <= rec.size {
			ms.iterators += 1
			defer ms.iterators -= 1
			for i := 0; i < len(ms.entries); i += 1 {
				e := ms.entries[i]
				if e.deleted {continue}
				h := call_has(ctx, rec, e.key)
				if h < 0 {return EXCEPTION}
				if h == 1 {map_set(rt, rs, e.key, UNDEFINED)}
			}
		} else {
			D :: struct {
				res: ^Map_State,
				src: ^Map_State,
			}
			d := D{rs, ms}
			r := iterate_keys(ctx, rec, proc(ctx: ^Context, k: Value, data: rawptr) -> int {
					d := cast(^D)data
					key := k
					if key.tag == .float && key.u.f == 0 {key = mk_int(0)}
					if map_find(ctx.rt, d.src, key) >= 0 {map_set(ctx.rt, d.res, key, UNDEFINED)}
					return 0
				}, &d)
			if r < 0 {return EXCEPTION}
		}
		return mk_obj(res)
	case 2:
		res := set_copy(ctx, ms)
		rs := res.data.(^Map_State)
		if f64(ms.live) <= rec.size {
			for i := 0; i < len(ms.entries); i += 1 {
				e := ms.entries[i]
				if e.deleted {continue}
				h := call_has(ctx, rec, e.key)
				if h < 0 {return EXCEPTION}
				if h == 1 {
					j := map_find(rt, rs, e.key)
					if j >= 0 {map_delete_index(rt, rs, j)}
				}
			}
		} else {
			r := iterate_keys(ctx, rec, proc(ctx: ^Context, k: Value, data: rawptr) -> int {
					rs := cast(^Map_State)data
					j := map_find(ctx.rt, rs, k)
					if j >= 0 {map_delete_index(ctx.rt, rs, j)}
					return 0
				}, rs)
			if r < 0 {return EXCEPTION}
		}
		return mk_obj(res)
	case 4:
		if f64(ms.live) > rec.size {return FALSE}
		ms.iterators += 1
		defer ms.iterators -= 1
		for i := 0; i < len(ms.entries); i += 1 {
			e := ms.entries[i]
			if e.deleted {continue}
			h := call_has(ctx, rec, e.key)
			if h < 0 {return EXCEPTION}
			if h == 0 {return FALSE}
		}
		return TRUE
	case 5:
		if f64(ms.live) < rec.size {return FALSE}
		r := iterate_keys(ctx, rec, proc(ctx: ^Context, k: Value, data: rawptr) -> int {
				ms := cast(^Map_State)data
				return map_find(ctx.rt, ms, k) < 0 ? 1 : 0
			}, ms)
		if r < 0 {return EXCEPTION}
		return mk_bool(r == 0)
	case 6:
		if f64(ms.live) <= rec.size {
			ms.iterators += 1
			defer ms.iterators -= 1
			for i := 0; i < len(ms.entries); i += 1 {
				e := ms.entries[i]
				if e.deleted {continue}
				h := call_has(ctx, rec, e.key)
				if h < 0 {return EXCEPTION}
				if h == 1 {return FALSE}
			}
			return TRUE
		}
		r := iterate_keys(ctx, rec, proc(ctx: ^Context, k: Value, data: rawptr) -> int {
				ms := cast(^Map_State)data
				return map_find(ctx.rt, ms, k) >= 0 ? 1 : 0
			}, ms)
		if r < 0 {return EXCEPTION}
		return mk_bool(r == 0)
	}
	return UNDEFINED
}

init_mapset_builtins :: proc(ctx: ^Context) {
	rt := ctx.rt
	mp := ctx.class_proto[.jsmap]
	mc := def_ctor(ctx, "Map", collection_ctor, 0, mp, .constructor_only, i32(Class_ID.jsmap))
	def_method(ctx, mc, "groupBy", group_by, 2, 1)
	install_species(ctx, mc)
	mm :: proc(c: Class_ID, op: i32) -> i32 {return i32(c) << 4 | op}
	def_method(ctx, mp, "get", collection_method, 1, mm(.jsmap, MAP_GET))
	def_method(ctx, mp, "set", collection_method, 2, mm(.jsmap, MAP_SET))
	def_method(ctx, mp, "has", collection_method, 1, mm(.jsmap, MAP_HAS))
	def_method(ctx, mp, "delete", collection_method, 1, mm(.jsmap, MAP_DELETE))
	def_method(ctx, mp, "clear", collection_method, 0, mm(.jsmap, MAP_CLEAR))
	def_method(ctx, mp, "getOrInsert", collection_method, 2, mm(.jsmap, MAP_GET_OR_INSERT))
	def_method(ctx, mp, "getOrInsertComputed", collection_method, 2, mm(.jsmap, MAP_GET_OR_INSERT_COMPUTED))
	def_getter(ctx, mp, pa(.A_size), collection_method, nil, mm(.jsmap, MAP_SIZE))
	def_method(ctx, mp, "forEach", collection_for_each, 1, i32(Class_ID.jsmap))
	def_method(ctx, mp, "keys", collection_iter, 0, mm(.jsmap, 0))
	def_method(ctx, mp, "values", collection_iter, 0, mm(.jsmap, 1))
	me := def_method(ctx, mp, "entries", collection_iter, 0, mm(.jsmap, 2))
	define_value(ctx, mp, well_known_atom(.iterator), mk_obj(me), CW)
	def_tag(ctx, mp, "Map")
	mip := ctx.class_proto[.map_iterator]
	def_method(ctx, mip, "next", collection_iter_next, 0, i32(Class_ID.map_iterator))
	def_tag(ctx, mip, "Map Iterator")

	sp := ctx.class_proto[.set]
	sc := def_ctor(ctx, "Set", collection_ctor, 0, sp, .constructor_only, i32(Class_ID.set))
	install_species(ctx, sc)
	def_method(ctx, sp, "add", collection_method, 1, mm(.set, MAP_ADD))
	def_method(ctx, sp, "has", collection_method, 1, mm(.set, MAP_HAS))
	def_method(ctx, sp, "delete", collection_method, 1, mm(.set, MAP_DELETE))
	def_method(ctx, sp, "clear", collection_method, 0, mm(.set, MAP_CLEAR))
	def_getter(ctx, sp, pa(.A_size), collection_method, nil, mm(.set, MAP_SIZE))
	def_method(ctx, sp, "forEach", collection_for_each, 1, i32(Class_ID.set))
	def_method(ctx, sp, "entries", collection_iter, 0, mm(.set, 2))
	sv := def_method(ctx, sp, "values", collection_iter, 0, mm(.set, 1))
	define_value(ctx, sp, pa(.A_keys), mk_obj(sv), CW)
	define_value(ctx, sp, well_known_atom(.iterator), mk_obj(sv), CW)
	def_method(ctx, sp, "union", set_algebra, 1, 0)
	def_method(ctx, sp, "intersection", set_algebra, 1, 1)
	def_method(ctx, sp, "difference", set_algebra, 1, 2)
	def_method(ctx, sp, "symmetricDifference", set_algebra, 1, 3)
	def_method(ctx, sp, "isSubsetOf", set_algebra, 1, 4)
	def_method(ctx, sp, "isSupersetOf", set_algebra, 1, 5)
	def_method(ctx, sp, "isDisjointFrom", set_algebra, 1, 6)
	def_tag(ctx, sp, "Set")
	sip := ctx.class_proto[.set_iterator]
	def_method(ctx, sip, "next", collection_iter_next, 0, i32(Class_ID.set_iterator))
	def_tag(ctx, sip, "Set Iterator")

	wmp := ctx.class_proto[.weakmap]
	def_ctor(ctx, "WeakMap", collection_ctor, 0, wmp, .constructor_only, i32(Class_ID.weakmap))
	def_method(ctx, wmp, "get", collection_method, 1, mm(.weakmap, MAP_GET))
	def_method(ctx, wmp, "set", collection_method, 2, mm(.weakmap, MAP_SET))
	def_method(ctx, wmp, "has", collection_method, 1, mm(.weakmap, MAP_HAS))
	def_method(ctx, wmp, "delete", collection_method, 1, mm(.weakmap, MAP_DELETE))
	def_method(ctx, wmp, "getOrInsert", collection_method, 2, mm(.weakmap, MAP_GET_OR_INSERT))
	def_method(ctx, wmp, "getOrInsertComputed", collection_method, 2, mm(.weakmap, MAP_GET_OR_INSERT_COMPUTED))
	def_tag(ctx, wmp, "WeakMap")
	wsp := ctx.class_proto[.weakset]
	def_ctor(ctx, "WeakSet", collection_ctor, 0, wsp, .constructor_only, i32(Class_ID.weakset))
	def_method(ctx, wsp, "add", collection_method, 1, mm(.weakset, MAP_ADD))
	def_method(ctx, wsp, "has", collection_method, 1, mm(.weakset, MAP_HAS))
	def_method(ctx, wsp, "delete", collection_method, 1, mm(.weakset, MAP_DELETE))
	def_tag(ctx, wsp, "WeakSet")
	_ = rt
}

// --- WeakRef / FinalizationRegistry ---

@(private = "file")
weakref_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	t := arg(args, 0)
	if !can_be_held_weakly(ctx.rt, t) {return throw_type_error(ctx, "WeakRef: invalid target")}
	proto, ok := proto_from_ctor(ctx, nt, .weakref)
	if !ok {return EXCEPTION}
	o := object_new_proto(ctx, proto, .weakref)
	d := new(Weak_Ref_Data, rt_allocator(ctx.rt))
	d.target = t
	o.data = d
	append(&ctx.rt.weak_list, o)
	return mk_obj(o)
}

@(private = "file")
weakref_deref :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := this_class(ctx, this, .weakref, "WeakRef")
	if o == nil {return EXCEPTION}
	return o.data.(^Weak_Ref_Data).target
}

@(private = "file")
finrec_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	cb := arg(args, 0)
	if !is_callable(cb) {return throw_type_error(ctx, "cleanup callback is not a function")}
	proto, ok := proto_from_ctor(ctx, nt, .finrec)
	if !ok {return EXCEPTION}
	o := object_new_proto(ctx, proto, .finrec)
	d := new(Fin_Rec_Data, rt_allocator(ctx.rt))
	d.callback = cb
	d.realm = ctx
	d.cells = make([dynamic]Fin_Rec_Cell, rt_allocator(ctx.rt))
	o.data = d
	append(&ctx.rt.weak_list, o)
	return mk_obj(o)
}

@(private = "file")
finrec_register :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	o := this_class(ctx, this, .finrec, "FinalizationRegistry")
	if o == nil {return EXCEPTION}
	d := o.data.(^Fin_Rec_Data)
	t := arg(args, 0)
	held := arg(args, 1)
	token := arg(args, 2)
	if !can_be_held_weakly(rt, t) {return throw_type_error(ctx, "register: invalid target")}
	if same_value(ctx, t, held) {return throw_type_error(ctx, "register: target and held value must differ")}
	if !is_undefined(token) && !can_be_held_weakly(rt, token) {return throw_type_error(ctx, "register: invalid unregister token")}
	append(&d.cells, Fin_Rec_Cell{target = t, held = held, token = token})
	return UNDEFINED
}

@(private = "file")
finrec_unregister :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := this_class(ctx, this, .finrec, "FinalizationRegistry")
	if o == nil {return EXCEPTION}
	d := o.data.(^Fin_Rec_Data)
	token := arg(args, 0)
	if !can_be_held_weakly(ctx.rt, token) {return throw_type_error(ctx, "unregister: invalid token")}
	removed := false
	for i := 0; i < len(d.cells); {
		if same_value(ctx, d.cells[i].token, token) {
			ordered_remove(&d.cells, i)
			removed = true
		} else {
			i += 1
		}
	}
	return mk_bool(removed)
}

@(private = "file")
finrec_cleanup_some :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := this_class(ctx, this, .finrec, "FinalizationRegistry")
	if o == nil {return EXCEPTION}
	cb := arg(args, 0)
	if !is_undefined(cb) && !is_callable(cb) {return throw_type_error(ctx, "callback is not a function")}
	return UNDEFINED
}

// Run the cleanup callbacks queued by the collector (called by the host after a turn).
run_finalization_callbacks :: proc(rt: ^Runtime) {
	for len(rt.finrec_cleanup) >= 2 {
		reg := rt.finrec_cleanup[0]
		held := rt.finrec_cleanup[1]
		remove_range(&rt.finrec_cleanup, 0, 2)
		d := as_obj(reg).data.(^Fin_Rec_Data)
		m := temp_mark(rt)
		root(rt, reg)
		root(rt, held)
		call(d.realm, d.callback, UNDEFINED, {held})
		if has_exception(d.realm) {take_exception(d.realm)}
		temp_reset(rt, m)
	}
}

init_weak_builtins :: proc(ctx: ^Context) {
	wp := ctx.class_proto[.weakref]
	def_ctor(ctx, "WeakRef", weakref_ctor, 1, wp, .constructor_only)
	def_method(ctx, wp, "deref", weakref_deref, 0)
	def_tag(ctx, wp, "WeakRef")
	fp := ctx.class_proto[.finrec]
	def_ctor(ctx, "FinalizationRegistry", finrec_ctor, 1, fp, .constructor_only)
	def_method(ctx, fp, "register", finrec_register, 2)
	def_method(ctx, fp, "unregister", finrec_unregister, 1)
	def_method(ctx, fp, "cleanupSome", finrec_cleanup_some, 0)
	def_tag(ctx, fp, "FinalizationRegistry")
}
