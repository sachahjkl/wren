// Package jsb: the JavaScript side of the generic boundary, inside the engine module. It binds a member of a WebIDL
// interface to a procedure typed by the shared declarations (native/js/odin_abi/api_decl) with no per-member code:
// `this` becomes the declaration's first parameter (a handle kind), the JS arguments its other parameters (converted
// by type: strings, optional strings, booleans, numbers, handles), the result goes back to JS by type, and an
// Api_Error result throws. The arguments travel as abi.Cells and the call is abi.apply, the same two pieces the host
// side uses, so a conversion exists once per type, not once per member.
//
// What a domain still writes by hand is behaviour (category C of the glue audit: [SameObject] caches, sequences and
// records, iterators, bespoke error messages) and, per member, one line naming the declaration (the exported symbol
// the generated binding table references).
package jsb

import "base:intrinsics"
import "base:runtime"
import "../../odin_abi/abi"
import "../wj"

////////////////////////////////
// The context

// The context the glue's Odin-convention code runs in (an exported proc "c" sets it before calling into jsb's
// bridges or a host call): the freestanding default. (Caching it once was measured: no difference on a getter.)
glue_context :: #force_inline proc "contextless" () -> runtime.Context { return runtime.default_context() }

////////////////////////////////
// Interfaces and `this`

// A handle kind is an 8-byte integer type of its own (api_decl declares each as `distinct abi.Handle`); a plain i64 /
// u64 is a number. Odin cannot tell a distinct type from its base at compile time, hence that test in the whens.

// The interface index of handle kind H (api_decl.URL -> "URL": a handle kind is named after its interface), resolved
// once per kind.
iface_of :: proc "contextless" ($H: typeid) -> i32 {
	@(static) idx := i32(-2)
	if idx == -2 {
		name: [96]u8
		n := copy(name[:len(name) - 1], type_name(H))
		name[n] = 0
		idx = wj.iface(cstring(&name[0]))
	}
	return idx
}

@(private)
type_name :: proc "contextless" ($T: typeid) -> string {
	if named, ok := type_info_of(T).variant.(runtime.Type_Info_Named); ok { return named.name }
	return ""
}

// `this` of a member of interface H: its live handle, or false with a TypeError pending.
this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, $H: typeid) -> (H, bool) {
	o := wj.wj_this(ctx, this_val, iface_of(H))
	if o == nil { return 0, false }
	if o.handle == 0 { wj.wj_throw_type(ctx, "Illegal invocation"); return 0, false }
	return H(o.handle), true
}

////////////////////////////////
// Arguments: JS -> cells

// How a string argument converts: a DOMString (wj_to_str) or a USVString (lone surrogates replaced, web_to_usv).
Strings :: enum u8 { DOM, USV }

// The converted strings of one call, released after it.
Held :: struct {
	s: [abi.MAX_PARAMS]wj.Str,
	n: int,
}

release :: proc "contextless" (ctx: ^wj.Context, h: ^Held) {
	for i in 0 ..< h.n { wj.wj_str_free(ctx, &h.s[i]) }
	h.n = 0
}

// One JS value as a parameter of type T, into cell c. False with an exception pending when it does not convert.
arg :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, c: ^abi.Cell, $T: typeid, strs: Strings, h: ^Held) -> bool {
	when T == string {
		s := &h.s[h.n]
		ok := strs == .USV ? wj.web_to_usv(ctx, v, s) : wj.wj_to_str(ctx, v, s, 0, nil)
		if !ok { return false }
		h.n += 1
		c^ = {u64(uintptr(s.ptr != nil ? s.ptr : wj.empty_ptr())), u64(s.len)}
	} else when intrinsics.type_is_union(T) {
		// an optional argument: undefined is absent
		INNER :: intrinsics.type_variant_type_of(T, 0)
		when INNER == string {
			if wj.is_undefined(v) { c^ = {0, abi.ABSENT_LEN}; return true }
			return arg(ctx, v, c, INNER, strs, h)
		} else {
			if wj.is_undefined(v) { c.b = 0; return true }
			c.b = 1
			return arg(ctx, v, c, INNER, strs, h)
		}
	} else when intrinsics.type_is_boolean(T) {
		c.a = wj.JS_ToBool(ctx, v) != 0 ? 1 : 0
	} else when T == f64 {
		d: f64
		if !wj.wj_to_double(ctx, v, &d, false) { return false }
		c.a = transmute(u64)d
	} else when T == i32 {
		x: i32
		if !wj.wj_to_int32(ctx, v, &x, 32, 0) { return false }
		c.a = u64(u32(x))
	} else when T == u32 {
		x: u32
		if !wj.wj_to_uint32(ctx, v, &x, 32, 0) { return false }
		c.a = u64(x)
	} else when intrinsics.type_is_integer(T) && size_of(T) == 8 && T != u64 && T != i64 {   // a handle kind
		// a handle kind: the platform object of its interface
		handle: u64
		if !wj.wj_to_handle(ctx, v, iface_of(T), false, &handle, "The provided value is not of the expected interface.") { return false }
		c.a = handle
	} else {
		#panic("jsb.arg: a parameter type JavaScript does not convert to (an enum is a string in WebIDL: bind it by hand)")
	}
	return true
}

// The JS arguments [i, n) of declaration P (P's parameter i is JS argument i - first) into cells[i ...].
@(private)
args :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, c: ^abi.Cells, $P: typeid, $i, $n, $first: int,
	strs: Strings, h: ^Held) -> bool {
	when i < n {
		if !arg(ctx, wj.arg(argc, argv, i32(i - first)), &c[i], intrinsics.type_proc_parameter_type(P, i), strs, h) { return false }
		return args(ctx, argc, argv, c, P, i + 1, n, first, strs, h)
	} else {
		return true
	}
}

// How many of P's parameters [first, n) a call must give (the trailing optional ones may be left out).
@(private)
required :: proc "contextless" ($P: typeid, $i, $n: int) -> i32 {
	when i < n {
		rest := required(P, i + 1, n)
		when intrinsics.type_is_union(intrinsics.type_proc_parameter_type(P, i)) {
			return rest > 0 ? rest + 1 : 0
		} else {
			return rest + 1
		}
	} else {
		return 0
	}
}

////////////////////////////////
// Results: value -> JS

to_js :: proc "contextless" (ctx: ^wj.Context, v: $T) -> wj.JSValue {
	when T == string {
		return wj.new_string_len(ctx, v)
	} else when intrinsics.type_is_union(T) {
		x, ok := v.?
		return ok ? to_js(ctx, x) : wj.NULL
	} else when intrinsics.type_is_specialization_of(T, abi.Owned) {
		return wj.wj_wrap_owned(ctx, u64(v.handle), iface_of(type_of(v.handle)), wj.UNDEFINED)
	} else when intrinsics.type_is_boolean(T) {
		return wj.new_bool(v)
	} else when T == f64 {
		return wj.new_float64(ctx, v)
	} else when T == u32 {
		return wj.new_uint32(ctx, v)
	} else when intrinsics.type_is_integer(T) && size_of(T) == 8 && T != u64 && T != i64 {   // a handle kind
		return wj.wj_wrap_host(ctx, u64(v), iface_of(T))
	} else when intrinsics.type_is_integer(T) {
		return wj.new_int64(ctx, i64(v))
	} else {
		#panic("jsb.to_js: a result type JavaScript does not receive")
	}
}

// The JS value of what P returned in r0 / r1: an Api_Error throws (wj_throw_status, `what` naming the member).
@(private)
result :: #force_inline proc "contextless" (ctx: ^wj.Context, $P: typeid, r0: ^$R0, r1: ^$R1, what: cstring) -> wj.JSValue {
	NR :: intrinsics.type_proc_return_count(P)
	when NR == 0 {
		return wj.UNDEFINED
	} else when NR == 1 && R0 == abi.Api_Error {
		return r0^ != .None ? wj.wj_throw_status(ctx, i32(r0^), what) : wj.UNDEFINED
	} else when NR == 1 {
		return to_js(ctx, r0^)
	} else {
		if r1^ != .None { return wj.wj_throw_status(ctx, i32(r1^), what) }
		return to_js(ctx, r0^)
	}
}

////////////////////////////////
// Members
//
// A member names its declaration D (an api_decl proc type) and the generated import `imp` (wj.wr_*) that carries D
// across: there is no per-function stub. The JS values become D's parameters (by D's types), D's parameters are
// lowered onto imp's wire parameters (lower, below), the import is called through abi.apply, and its wire result is
// raised back to D's results; then D's result goes to JS. The lowering checks at compile time that imp is the wire
// form of D, so a declaration and an import that drifted apart do not build.

// An operation of interface H whose declaration is proc(this: H, the JS arguments...) -> result. The arity check, the
// conversions, the call and the result are the declaration's; `what` names the member in errors
// ("URLSearchParams.toString").
method :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, $D: typeid, imp: $R,
	what: cstring, strs := Strings.DOM) -> wj.JSValue where intrinsics.type_is_proc(D), intrinsics.type_is_proc(R) {
	context = glue_context()
	N :: intrinsics.type_proc_parameter_count(D)
	H :: intrinsics.type_proc_parameter_type(D, 0)
	c: abi.Cells = ---
	h, ok := this(ctx, this_val, H)
	if !ok { return wj.EXCEPTION }
	if need := required(D, 1, N); argc < need { return wj.wj_throw_arity(ctx, what, need, argc) }
	c[0].a = u64(h)
	held: Held
	if !args(ctx, argc, argv, &c, D, 1, N, 1, strs, &held) { release(ctx, &held); return wj.EXCEPTION }
	return call(ctx, &c, D, imp, what, &held)
}

// A static operation or a function of the global (no `this`): all of the declaration's parameters are JS arguments.
function :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, $D: typeid, imp: $R, what: cstring,
	strs := Strings.DOM) -> wj.JSValue where intrinsics.type_is_proc(D), intrinsics.type_is_proc(R) {
	context = glue_context()
	N :: intrinsics.type_proc_parameter_count(D)
	c: abi.Cells = ---
	if need := required(D, 0, N); argc < need { return wj.wj_throw_arity(ctx, what, need, argc) }
	held: Held
	if !args(ctx, argc, argv, &c, D, 0, N, 0, strs, &held) { release(ctx, &held); return wj.EXCEPTION }
	return call(ctx, &c, D, imp, what, &held)
}

// An attribute getter of interface H whose declaration takes `this` and one fixed value selecting the attribute
// (URL_get(url, .Pathname)).
getter :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, $D: typeid, imp: $R, which: $K, what: cstring) -> wj.JSValue
	where intrinsics.type_is_proc(D), intrinsics.type_proc_parameter_count(D) == 2 {
	context = glue_context()
	H :: intrinsics.type_proc_parameter_type(D, 0)
	K1 :: intrinsics.type_proc_parameter_type(D, 1)
	c: abi.Cells = ---
	h, ok := this(ctx, this_val, H)
	if !ok { return wj.EXCEPTION }
	c[0].a = u64(h)
	abi.cell_set(&c[1], K1(which))
	held: Held
	return call(ctx, &c, D, imp, what, &held)
}

@(private)
call :: #force_inline proc(ctx: ^wj.Context, c: ^abi.Cells, $D: typeid, imp: $R, what: cstring, held: ^Held) -> wj.JSValue {
	NR :: intrinsics.type_proc_return_count(D)
	when NR >= 1 { r0: intrinsics.type_proc_return_type(D, 0) } else { r0: abi.Nothing }
	when NR >= 2 { r1: intrinsics.type_proc_return_type(D, 1) } else { r1: abi.Nothing }
	cross(c, D, imp, &r0, &r1)
	v := result(ctx, D, &r0, &r1, what)   // (converted before the argument strings are released: a result may alias them)
	release(ctx, held)
	return v
}

////////////////////////////////
// Behaviour code calling the host: the same lowering, from Odin values

// Call declaration D through import imp with the given arguments; D's value result (if any) in out (a ^abi.Nothing
// when D has none). Returns D's Api_Error, .None when D raises nothing. A string result lives in the realm's scratch
// buffer until the next host call.
host :: proc{host0, host1, host2, host3, host4}

host0 :: proc(out: ^$O, $D: typeid, imp: $R) -> abi.Api_Error {
	c: abi.Cells = ---
	return host_call(&c, out, D, imp)
}
host1 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a)
	return host_call(&c, out, D, imp)
}
host2 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b)
	return host_call(&c, out, D, imp)
}
host3 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x)
	return host_call(&c, out, D, imp)
}
host4 :: proc(out: ^$O, $D: typeid, imp: $R, a: $A, b: $B, x: $X, y: $Y) -> abi.Api_Error {
	c: abi.Cells = ---
	abi.cell_set(&c[0], a); abi.cell_set(&c[1], b); abi.cell_set(&c[2], x); abi.cell_set(&c[3], y)
	return host_call(&c, out, D, imp)
}

@(private)
host_call :: #force_inline proc(c: ^abi.Cells, out: ^$O, $D: typeid, imp: $R) -> abi.Api_Error {
	NR :: intrinsics.type_proc_return_count(D)
	when NR >= 1 { r0: intrinsics.type_proc_return_type(D, 0) } else { r0: abi.Nothing }
	when NR >= 2 { r1: intrinsics.type_proc_return_type(D, 1) } else { r1: abi.Nothing }
	cross(c, D, imp, &r0, &r1)
	when NR == 0 {
		return .None
	} else when NR == 1 && intrinsics.type_proc_return_type(D, 0) == abi.Api_Error {
		return r0
	} else when NR == 1 {
		out^ = r0
		return .None
	} else {
		out^ = r0
		return r1
	}
}

////////////////////////////////
// Lowering a declaration onto its generated import (today's wr_* wire, src/tools/bindgen)
//
//   a handle, an integer, an enum, a bool, a float    one wire parameter of the same size
//   string / bytes / []T                              (pointer, length)
//   Maybe(string)                                     (pointer, length), the length WR_ABSENT when absent
// and the result:
//   string / bytes, (string, Api_Error)               two more wire parameters (buffer, capacity); the import returns
//                                                     the full length or a negative Error (grown once and retried)
//   (value, Api_Error)                                one more wire parameter: where the import stores the value;
//                                                     it returns the status
//   Api_Error / a scalar / nothing                    the import's own result

// Cross from D's parameters in cells to the import imp, and from its wire result to D's results r0 / r1.
@(private)
cross :: #force_inline proc(c: ^abi.Cells, $D: typeid, imp: $R, r0: ^$R0, r1: ^$R1) {
	ND :: intrinsics.type_proc_parameter_count(D)
	NR :: intrinsics.type_proc_return_count(D)
	w: abi.Cells = ---
	k := lower(c, &w, D, R, 0, ND, 0)
	_ = k   // (only a result that needs wire parameters of its own uses it)
	when R0 == string || R0 == abi.Bytes || R0 == []u8 {
		// a string result into the realm's scratch buffer
		n: i32
		w[k] = {u64(uintptr(wj.wj_scratch.data)), 0}; w[k + 1] = {u64(wj.wj_scratch.cap), 0}
		abi.apply(&w, R, imp, &n, &none)
		if n > 0 && u32(n) > wj.wj_scratch.cap {
			if !wj.wj_scratch_grow(u32(n)) { n = i32(abi.Api_Error.Quota) }
			else {
				w[k] = {u64(uintptr(wj.wj_scratch.data)), 0}; w[k + 1] = {u64(wj.wj_scratch.cap), 0}
				abi.apply(&w, R, imp, &n, &none)
			}
		}
		S :: intrinsics.type_proc_return_type(D, 0)
		if n >= 0 { r0^ = S(wj.wj_scratch.data[:n]) }
		when NR == 2 { r1^ = n < 0 ? abi.Api_Error(n) : .None }
	} else when NR == 2 {
		// (value, Api_Error): the value through the address in the last wire parameter
		V :: intrinsics.type_proc_return_type(D, 0)
		slot: u64
		w[k] = {u64(uintptr(&slot)), 0}
		st: i32
		abi.apply(&w, R, imp, &st, &none)
		vc := abi.Cell{slot, 0}
		r0^ = abi.cell_get(&vc, V)
		r1^ = st < 0 ? abi.Api_Error(st) : .None
	} else when NR == 1 {
		// the import's own result, as D's
		RR :: intrinsics.type_proc_return_type(R, 0)
		raw: RR
		abi.apply(&w, R, imp, &raw, &none)
		when R0 == abi.Api_Error { r0^ = raw < 0 ? abi.Api_Error(raw) : .None }
		else when intrinsics.type_is_boolean(R0) { r0^ = raw != 0 }
		else { r0^ = R0(raw) }
	} else {
		when intrinsics.type_proc_return_count(R) == 0 { abi.apply(&w, R, imp, &none, &none) }
		else { ignored: intrinsics.type_proc_return_type(R, 0); abi.apply(&w, R, imp, &ignored, &none) }
	}
}

@(private) none: abi.Nothing

// D's parameters [i, nd) onto the wire parameters of R from w[j]: one specialised step per parameter, each checking
// at compile time that the wire parameters it fills have the expected shape. Returns the next wire index.
@(private)
lower :: #force_inline proc "contextless" (c, w: ^abi.Cells, $D, $R: typeid, $i, $nd, $j: int) -> int {
	when i < nd {
		T :: intrinsics.type_proc_parameter_type(D, i)
		when T == string || T == abi.Bytes || T == []u8 || intrinsics.type_is_slice(T) {
			#assert(intrinsics.type_is_multi_pointer(intrinsics.type_proc_parameter_type(R, j)), "jsb: a span lowers to (pointer, length)")
			#assert(size_of(intrinsics.type_proc_parameter_type(R, j + 1)) == 4, "jsb: a span lowers to (pointer, length)")
			w[j] = {c[i].a, 0}; w[j + 1] = {c[i].b, 0}
			return lower(c, w, D, R, i + 1, nd, j + 2)
		} else when intrinsics.type_is_union(T) {
			V :: intrinsics.type_variant_type_of(T, 0)
			#assert(V == string || V == abi.Bytes || V == []u8, "jsb: only Maybe(string) / Maybe(bytes) lower onto today's wire")
			#assert(intrinsics.type_is_multi_pointer(intrinsics.type_proc_parameter_type(R, j)), "jsb: an optional string lowers to (pointer, length)")
			absent := c[i].b == abi.ABSENT_LEN
			w[j] = {absent ? 0 : c[i].a, 0}; w[j + 1] = {absent ? u64(wj.WR_ABSENT) : c[i].b, 0}
			return lower(c, w, D, R, i + 1, nd, j + 2)
		} else {
			#assert(size_of(intrinsics.type_proc_parameter_type(R, j)) == size_of(T) || (intrinsics.type_is_boolean(T) && size_of(intrinsics.type_proc_parameter_type(R, j)) == 4),
				"jsb: a scalar lowers to one wire parameter of its size")
			w[j] = c[i]
			return lower(c, w, D, R, i + 1, nd, j + 1)
		}
	} else {
		// what follows the arguments: the result's wire parameters, and nothing else
		NW :: intrinsics.type_proc_parameter_count(R)
		NR :: intrinsics.type_proc_return_count(D)
		when NR >= 1 { R0 :: intrinsics.type_proc_return_type(D, 0) } else { R0 :: abi.Nothing }
		when R0 == string || R0 == abi.Bytes || R0 == []u8 {
			#assert(NW == j + 2, "jsb: a string result lowers to (buffer, capacity) after the arguments")
			#assert(intrinsics.type_is_multi_pointer(intrinsics.type_proc_parameter_type(R, j)) && size_of(intrinsics.type_proc_parameter_type(R, j + 1)) == 4,
				"jsb: a string result lowers to (buffer, capacity) after the arguments")
			#assert(intrinsics.type_proc_return_count(R) == 1, "jsb: the import of a string result returns the length")
		} else when NR == 2 {
			#assert(NW == j + 1, "jsb: a (value, error) result lowers to one result address after the arguments")
			#assert(intrinsics.type_is_pointer(intrinsics.type_proc_parameter_type(R, j)), "jsb: a (value, error) result lowers to one result address")
			#assert(intrinsics.type_proc_return_count(R) == 1, "jsb: the import of a (value, error) result returns the status")
		} else {
			#assert(NW == j, "jsb: the import takes exactly the declaration's arguments")
			#assert(NR == 0 || intrinsics.type_proc_return_count(R) == 1, "jsb: the import returns the declaration's result")
		}
		return j
	}
}
