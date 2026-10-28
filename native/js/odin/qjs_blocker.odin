// qjs_blocker.odin: the content blocker's scriptlets that change what a JavaScript API does (set-constant,
// abort-on-property-read / write, abort-current-script, abort-on-stack-trace, no-setTimeout-if, no-setInterval-if, the
// nano boosters, no-fetch-if, no-xhr-if, addEventListener-defuser, window.open-defuser, noeval, nowebrtc, json-prune on
// JSON.parse), ported from native/js/engine/qjs_blocker.c with the same behaviour. They are installed in the realm
// before the page's first script as NATIVE hooks: accessor properties and replaced functions that are functions of the
// engine (no interpreted wrapper, no JavaScript source for the blocker to compile or run), deciding with the page's
// values (function text, current script, arguments) natively. A call of a hooked API the rule does not concern costs the
// check and the call of the original: tens of nanoseconds.
//
// The browser sends the rules once, as text (wj_hook_install): records separated by 0x1e, fields by 0x1f, the first
// field the canonical scriptlet name of uBlock Origin, then its arguments as written in the filter. Rules live as long
// as the realm (one document): their memory is never given back, as in the C.
package odin_glue

import "../odin/wj"

// ---- strings (NUL-terminated, libc heap) ----

@(private = "file")
str_dup :: proc "contextless" (p: [^]u8, n: int) -> [^]u8 {
	s := ([^]u8)(wj.libc_malloc(uint(n) + 1))
	if s == nil { return nil }
	if n > 0 { wj.memcpy(s, p, uint(n)) }
	s[n] = 0
	return s
}

@(private = "file")
cstr_len :: #force_inline proc "contextless" (p: [^]u8) -> int { return p != nil ? int(wj.strlen(cstring(p))) : 0 }

@(private = "file")
is :: #force_inline proc "contextless" (p: [^]u8, lit: string) -> bool { return wj.str_eq(p, lit) }

@(private = "file")
contains_byte :: proc "contextless" (set: string, c: u8) -> bool {
	for i in 0 ..< len(set) { if set[i] == c { return true } }
	return false
}

@(private = "file")
clear_exception :: #force_inline proc "contextless" (ctx: ^wj.Context) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)) }

// ---- patterns: `text`, `/regex/flags`, `!text` (negated); empty matches everything ----

@(private = "file") NEEDLE_ANY   :: 0
@(private = "file") NEEDLE_TEXT  :: 1
@(private = "file") NEEDLE_REGEX :: 2
@(private = "file") NEEDLE_NEVER :: 3   // a regex that does not compile

@(private = "file")
Needle :: struct {
	mode: i32,
	neg:  bool,
	text: [^]u8,
	re:   wj.JSValue,
}

@(private = "file")
needle_init :: proc "contextless" (ctx: ^wj.Context, n: ^Needle, p_in: [^]u8) {
	n^ = {}
	n.re = wj.UNDEFINED
	p := p_in
	if p == nil || p[0] == 0 { n.mode = NEEDLE_ANY; return }
	if p[0] == '!' { n.neg = true; p = p[1:] }
	plen := cstr_len(p)
	if plen >= 2 && p[0] == '/' {
		end := -1
		for i := plen - 1; i >= 0; i -= 1 { if p[i] == '/' { end = i; break } }
		if end > 0 {
			flags: [16]u8
			fi := 0
			ok := true
			for f := end + 1; f < plen; f += 1 {
				if !contains_byte("gimsuyd", p[f]) || fi + 1 >= len(flags) { ok = false; break }
				if p[f] != 'g' && p[f] != 'y' { flags[fi] = p[f]; fi += 1 }
			}
			flags[fi] = 0
			if ok {
				g := wj.JS_GetGlobalObject(ctx)
				ctor := wj.JS_GetPropertyStr(ctx, g, "RegExp")
				args := [2]wj.JSValue{wj.JS_NewStringLen(ctx, p[1:], uint(end - 1)), wj.JS_NewString(ctx, cstring(&flags[0]))}
				re := wj.JS_CallConstructor(ctx, ctor, 2, &args[0])
				wj.JS_FreeValue(ctx, args[0])
				wj.JS_FreeValue(ctx, args[1])
				wj.JS_FreeValue(ctx, ctor)
				wj.JS_FreeValue(ctx, g)
				if wj.is_exception(re) { clear_exception(ctx); n.mode = NEEDLE_NEVER } else { n.mode = NEEDLE_REGEX; n.re = re }
				return
			}
		}
	}
	n.mode = NEEDLE_TEXT
	n.text = str_dup(p, plen)
}

@(private = "file")
needle_test :: proc "contextless" (ctx: ^wj.Context, n: ^Needle, s: [^]u8) -> bool {
	if n.mode == NEEDLE_ANY { return true }
	hit := false
	if n.mode == NEEDLE_TEXT {
		tl := cstr_len(n.text)
		hit = n.text != nil && wj.index_of(s, cstr_len(s), string(n.text[:tl])) >= 0
	} else if n.mode == NEEDLE_REGEX {
		str := wj.JS_NewString(ctx, cstring(s))
		a := wj.JS_NewAtom(ctx, "test")
		r := wj.JS_Invoke(ctx, n.re, a, 1, &str)
		wj.JS_FreeAtom(ctx, a)
		wj.JS_FreeValue(ctx, str)
		if wj.is_exception(r) { clear_exception(ctx) } else { hit = wj.JS_ToBool(ctx, r) > 0 }
		wj.JS_FreeValue(ctx, r)
	}
	return hit != n.neg
}

@(private = "file")
needle_test_value :: proc "contextless" (ctx: ^wj.Context, n: ^Needle, v: wj.JSValue) -> bool {
	if n.mode == NEEDLE_ANY { return true }
	s := wj.JS_ToCStringLen2(ctx, nil, v, false)
	if s == nil { clear_exception(ctx); return needle_test(ctx, n, wj.empty_ptr()) }
	r := needle_test(ctx, n, ([^]u8)(rawptr(s)))
	wj.JS_FreeCString(ctx, s)
	return r
}

// ---- rules ----

@(private = "file") R_SET_CONST :: 0
@(private = "file") R_AOPR      :: 1
@(private = "file") R_AOPW      :: 2
@(private = "file") R_ACS       :: 3
@(private = "file") R_AOST      :: 4
@(private = "file") R_TIMER     :: 5
@(private = "file") R_BOOST     :: 6
@(private = "file") R_FETCH     :: 7
@(private = "file") R_XHR       :: 8
@(private = "file") R_AELD      :: 9
@(private = "file") R_WOPEN     :: 10
@(private = "file") R_JSON      :: 11

@(private = "file") MAX_PATHS :: 16

@(private = "file")
Words :: struct { w: [^][^]u8, n: i32 }

@(private = "file")
Ftest :: struct { key: [^]u8, n: Needle }

@(private = "file")
Rule :: struct {
	kind:        i32,
	parts:       Words,
	n1, n2:      Needle,
	val:         wj.JSValue,
	delay:       [^]u8,          // timers: the delay to match ("" or nil: any)
	boost:       f64,
	tests:       [^]Ftest,
	ntests:      i32,
	body_empty:  bool,           // no-fetch-if: "emptyStr"
	replace_obj: bool,           // window.open-defuser: return an object
	aborted:     bool,           // set-constant: only when the property exists
	paths:       [MAX_PATHS]Words,
	npaths:      i32,
	req:         [MAX_PATHS]Words,
	nreq:        i32,
}

@(private = "file") rules: [^]^Rule
@(private = "file") nrules, caprules: i32

@(private = "file")
new_rule :: proc "contextless" (kind: i32) -> ^Rule {
	if nrules == caprules {
		cap := caprules != 0 ? caprules * 2 : 16
		n := ([^]^Rule)(wj.libc_realloc(rules, uint(cap) * size_of(^Rule)))
		if n == nil { return nil }
		rules = n
		caprules = cap
	}
	r := (^Rule)(wj.libc_calloc(1, size_of(Rule)))
	if r == nil { return nil }
	r.kind = kind
	r.val = wj.UNDEFINED
	r.n1.re = wj.UNDEFINED
	r.n2.re = wj.UNDEFINED
	rules[nrules] = r
	nrules += 1
	return r
}

// The words of `s` between any of the separator bytes.
@(private = "file")
split_chars :: proc "contextless" (s: [^]u8, seps: string) -> Words {
	out: Words
	n := cstr_len(s)
	p := 0
	for p < n {
		for p < n && contains_byte(seps, s[p]) { p += 1 }
		if p >= n { break }
		q := p
		for q < n && !contains_byte(seps, s[q]) { q += 1 }
		w := ([^][^]u8)(wj.libc_realloc(out.w, uint(out.n + 1) * size_of([^]u8)))
		if w == nil { break }
		out.w = w
		out.w[out.n] = str_dup(s[p:], q - p)
		out.n += 1
		p = q
	}
	return out
}

@(private = "file")
words_free :: proc "contextless" (w: Words) {
	for i in 0 ..< w.n { wj.libc_free(w.w[i]) }
	wj.libc_free(w.w)
}

// ---- small natives ----

@(private = "file")
fn_noop :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return wj.UNDEFINED }
@(private = "file")
fn_true :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return wj.TRUE }
@(private = "file")
fn_false :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return wj.FALSE }

@(private = "file") rng_state: u32 = 0x9e3779b9

@(private = "file")
next_rand :: proc "contextless" () -> u32 {
	rng_state ~= rng_state << 13
	rng_state ~= rng_state >> 17
	rng_state ~= rng_state << 5
	return rng_state
}

@(private = "file")
reference_error :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	name: [13]u8
	for i in 0 ..< 12 { name[i] = u8('a' + next_rand() % 26) }
	name[12] = 0
	return wj.JS_ThrowReferenceError(ctx, "%s is not defined", cstring(&name[0]))
}

@(private = "file")
fn_throw :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return reference_error(ctx) }

// Promise[method](arg) (no argument when undefined), `arg` taken.
@(private = "file")
promise_static :: proc "contextless" (ctx: ^wj.Context, method: cstring, arg: wj.JSValue) -> wj.JSValue {
	g := wj.JS_GetGlobalObject(ctx)
	P := wj.JS_GetPropertyStr(ctx, g, "Promise")
	a := wj.JS_NewAtom(ctx, method)
	v := arg
	r := wj.JS_Invoke(ctx, P, a, wj.is_undefined(arg) ? 0 : 1, &v)
	wj.JS_FreeAtom(ctx, a)
	wj.JS_FreeValue(ctx, P)
	wj.JS_FreeValue(ctx, g)
	wj.JS_FreeValue(ctx, arg)
	return r
}

@(private = "file")
fn_resolve_empty :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return promise_static(ctx, "resolve", wj.JS_NewObject(ctx)) }
@(private = "file")
fn_reject_undef :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return promise_static(ctx, "reject", wj.UNDEFINED) }
@(private = "file")
fn_resolve_undef :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return promise_static(ctx, "resolve", wj.UNDEFINED) }

// The value a scriptlet names (set-constant's second argument).
@(private = "file")
to_value :: proc "contextless" (ctx: ^wj.Context, v: [^]u8) -> wj.JSValue {
	switch {
	case is(v, "undefined"): return wj.UNDEFINED
	case is(v, "false"): return wj.FALSE
	case is(v, "true"): return wj.TRUE
	case is(v, "null"): return wj.NULL
	case is(v, "emptyObj"): return wj.JS_NewObject(ctx)
	case is(v, "emptyArr"): return wj.JS_NewArray(ctx)
	case is(v, "noopFunc"): return wj.new_cfunction(ctx, fn_noop, "", 0)
	case is(v, "trueFunc"): return wj.new_cfunction(ctx, fn_true, "", 0)
	case is(v, "falseFunc"): return wj.new_cfunction(ctx, fn_false, "", 0)
	case is(v, "throwFunc"): return wj.new_cfunction(ctx, fn_throw, "", 0)
	case is(v, "noopPromiseResolve"): return wj.new_cfunction(ctx, fn_resolve_empty, "", 0)
	case is(v, "noopPromiseReject"): return wj.new_cfunction(ctx, fn_reject_undef, "", 0)
	case is(v, "NaN"): return wj.new_float64(ctx, wj.NAN_F64)
	case is(v, "Infinity"): return wj.new_float64(ctx, wj.INF_F64)
	case is(v, "-Infinity"): return wj.new_float64(ctx, -wj.INF_F64)
	}
	end: [^]u8
	d := wj.strtod(v, &end)
	if v[0] != 0 && end[0] == 0 && d >= -32767 && d <= 32767 { return wj.new_float64(ctx, d) }
	return wj.JS_NewString(ctx, cstring(v))
}

// ---- the current script, the call stack ----

@(private = "file")
current_script_matches :: proc "contextless" (ctx: ^wj.Context, n: ^Needle) -> bool {
	g := wj.JS_GetGlobalObject(ctx)
	doc := wj.JS_GetPropertyStr(ctx, g, "document")
	cs := wj.is_object(doc) ? wj.JS_GetPropertyStr(ctx, doc, "currentScript") : wj.UNDEFINED
	r: bool
	if !wj.is_object(cs) {
		r = n.mode == NEEDLE_ANY
	} else if n.mode == NEEDLE_ANY {
		r = true
	} else {
		text := wj.JS_GetPropertyStr(ctx, cs, "textContent")
		src := wj.JS_GetPropertyStr(ctx, cs, "src")
		r = needle_test_value(ctx, n, text) || needle_test_value(ctx, n, src)
		wj.JS_FreeValue(ctx, text)
		wj.JS_FreeValue(ctx, src)
	}
	wj.JS_FreeValue(ctx, cs)
	wj.JS_FreeValue(ctx, doc)
	wj.JS_FreeValue(ctx, g)
	return r
}

@(private = "file")
stack_matches :: proc "contextless" (ctx: ^wj.Context, n: ^Needle) -> bool {
	if n.mode == NEEDLE_ANY { return true }
	e := wj.JS_NewError(ctx)
	s := wj.JS_GetPropertyStr(ctx, e, "stack")
	r := needle_test_value(ctx, n, s)
	wj.JS_FreeValue(ctx, s)
	wj.JS_FreeValue(ctx, e)
	return r
}

// ---- property paths: set-constant, abort-on-property-read / write, abort-current-script, abort-on-stack-trace ----

// The accessors at the end of a path. data[0] the rule index, data[1] the holder object (property v). magic: bit 0
// setter.
@(private = "file")
leaf_accessor :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, d: [^]wj.JSValue) -> wj.JSValue {
	r := rules[wj.int_of(d[0])]
	setter := magic & 1 != 0
	switch r.kind {
	case R_SET_CONST:
		return setter ? wj.UNDEFINED : wj.JS_DupValue(ctx, r.val)
	case R_AOPR:
		return setter ? wj.UNDEFINED : reference_error(ctx)
	case R_AOPW:
		if setter { return reference_error(ctx) }
		return wj.JS_GetPropertyStr(ctx, d[1], "v")
	case R_ACS:
		if current_script_matches(ctx, &r.n1) { return reference_error(ctx) }
	case R_AOST:
		if stack_matches(ctx, &r.n1) { return reference_error(ctx) }
	}
	if setter {
		wj.JS_SetPropertyStr(ctx, d[1], "v", wj.JS_DupValue(ctx, argc > 0 ? argv[0] : wj.UNDEFINED))
		return wj.UNDEFINED
	}
	return wj.JS_GetPropertyStr(ctx, d[1], "v")
}

@(private = "file")
leaf_install :: proc "contextless" (ctx: ^wj.Context, owner: wj.JSValue, prop: [^]u8, ri: i32) {
	r := rules[ri]
	atom := wj.JS_NewAtom(ctx, cstring(prop))
	if r.kind == R_SET_CONST && r.aborted && wj.JS_HasProperty(ctx, owner, atom) <= 0 {
		wj.JS_FreeAtom(ctx, atom)
		if wj.JS_HasException(ctx) { clear_exception(ctx) }
		return
	}
	holder := wj.JS_NewObject(ctx)
	cur := wj.UNDEFINED
	if r.kind == R_AOPW || r.kind == R_ACS || r.kind == R_AOST {
		cur = wj.JS_GetProperty(ctx, owner, atom)
		if wj.is_exception(cur) { clear_exception(ctx); cur = wj.UNDEFINED }
	}
	wj.JS_SetPropertyStr(ctx, holder, "v", cur)
	data := [2]wj.JSValue{wj.new_int32(ri), holder}
	get := wj.JS_NewCFunctionData(ctx, leaf_accessor, 0, 0, 2, &data[0])
	set := wj.JS_NewCFunctionData(ctx, leaf_accessor, 1, 1, 2, &data[0])
	wj.JS_FreeValue(ctx, holder)
	// a property set to undefined is a property that is not there: not listed by Object.keys / for-in / JSON.stringify
	flags: i32 = wj.PROP_CONFIGURABLE | ((r.kind == R_SET_CONST && wj.is_undefined(r.val)) ? 0 : wj.PROP_ENUMERABLE)
	if wj.JS_DefinePropertyGetSet(ctx, owner, atom, get, set, flags) < 0 { clear_exception(ctx) }
	wj.JS_FreeAtom(ctx, atom)
}

// An intermediate object that does not exist yet: remember what is assigned and walk into it. data[0] rule, data[1]
// depth, data[2] holder.
@(private = "file")
mid_accessor :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, d: [^]wj.JSValue) -> wj.JSValue {
	if magic & 1 == 0 { return wj.JS_GetPropertyStr(ctx, d[2], "v") }
	v := argc > 0 ? argv[0] : wj.UNDEFINED
	wj.JS_SetPropertyStr(ctx, d[2], "v", wj.JS_DupValue(ctx, v))
	if wj.is_object(v) { trap_walk(ctx, v, wj.int_of(d[0]), wj.int_of(d[1]) + 1) }
	return wj.UNDEFINED
}

@(private = "file")
trap_walk :: proc "contextless" (ctx: ^wj.Context, owner: wj.JSValue, ri: i32, i: i32) {
	r := rules[ri]
	prop := r.parts.w[i]
	if i == r.parts.n - 1 { leaf_install(ctx, owner, prop, ri); return }
	atom := wj.JS_NewAtom(ctx, cstring(prop))
	cur := wj.JS_GetProperty(ctx, owner, atom)
	if wj.is_exception(cur) { clear_exception(ctx); wj.JS_FreeAtom(ctx, atom); return }
	if wj.is_object(cur) { trap_walk(ctx, cur, ri, i + 1); wj.JS_FreeValue(ctx, cur); wj.JS_FreeAtom(ctx, atom); return }
	desc: wj.Property_Descriptor
	if wj.JS_GetOwnProperty(ctx, &desc, owner, atom) > 0 {
		fixed := desc.flags & wj.PROP_CONFIGURABLE == 0
		wj.JS_FreeValue(ctx, desc.value); wj.JS_FreeValue(ctx, desc.getter); wj.JS_FreeValue(ctx, desc.setter)
		if fixed { wj.JS_FreeValue(ctx, cur); wj.JS_FreeAtom(ctx, atom); return }
	}
	holder := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, holder, "v", cur)
	data := [3]wj.JSValue{wj.new_int32(ri), wj.new_int32(i), holder}
	get := wj.JS_NewCFunctionData(ctx, mid_accessor, 0, 0, 3, &data[0])
	set := wj.JS_NewCFunctionData(ctx, mid_accessor, 1, 1, 3, &data[0])
	wj.JS_FreeValue(ctx, holder)
	if wj.JS_DefinePropertyGetSet(ctx, owner, atom, get, set, wj.PROP_CONFIGURABLE | wj.PROP_ENUMERABLE) < 0 { clear_exception(ctx) }
	wj.JS_FreeAtom(ctx, atom)
}

// ---- timers ----

@(private = "file")
delay_matches :: proc "contextless" (ctx: ^wj.Context, want: [^]u8, d: wj.JSValue) -> bool {
	if want == nil || want[0] == 0 { return true }
	s := wj.JS_ToCStringLen2(ctx, nil, d, false)
	if s == nil { clear_exception(ctx); return false }
	sp := ([^]u8)(rawptr(s))
	r := want[0] == '!' ? wj.strcmp(sp, want[1:]) != 0 : wj.strcmp(sp, want) == 0
	wj.JS_FreeCString(ctx, s)
	return r
}

// data[0] the original, data[1] the rule index; magic 0: no-setTimeout/Interval-if, 1: the nano booster
@(private = "file")
timer_hook :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, d: [^]wj.JSValue) -> wj.JSValue {
	r := rules[wj.int_of(d[1])]
	cb := argc > 0 ? argv[0] : wj.UNDEFINED
	dl := argc > 1 ? argv[1] : wj.UNDEFINED
	if needle_test_value(ctx, &r.n1, cb) {
		if magic == 0 {
			if delay_matches(ctx, r.delay, dl) { return wj.new_int32(0) }
		} else {
			x: f64 = 0
			any_delay := r.delay == nil || r.delay[0] == 0 || is(r.delay, "*")
			if wj.JS_ToFloat64(ctx, &x, dl) < 0 { clear_exception(ctx); x = wj.NAN_F64 }
			if any_delay || x == wj.strtod(r.delay, nil) {
				args: [16]wj.JSValue
				n := min(argc, 16)
				for i in 0 ..< n { args[i] = wj.JS_DupValue(ctx, argv[i]) }
				if n > 1 {
					wj.JS_FreeValue(ctx, args[1])
					nd := wj.floor(x * r.boost)
					args[1] = wj.new_float64(ctx, nd > 0 ? nd : 0)
				}
				res := wj.JS_Call(ctx, d[0], this_val, n, &args[0])
				for i in 0 ..< n { wj.JS_FreeValue(ctx, args[i]) }
				return res
			}
		}
	}
	return wj.JS_Call(ctx, d[0], this_val, argc, argv)
}

@(private = "file")
wrap_global_function :: proc "contextless" (ctx: ^wj.Context, owner: wj.JSValue, prop: cstring, fn: wj.Native_Data, ri: i32, magic: i32, length: i32) -> wj.JSValue {
	orig := wj.JS_GetPropertyStr(ctx, owner, prop)
	if !wj.JS_IsFunction(ctx, orig) { wj.JS_FreeValue(ctx, orig); return wj.UNDEFINED }
	data := [2]wj.JSValue{orig, wj.new_int32(ri)}
	w := wj.JS_NewCFunctionData2(ctx, fn, prop, length, magic, 2, &data[0])
	wj.JS_FreeValue(ctx, orig)
	return w
}

@(private = "file")
replace_property :: proc "contextless" (ctx: ^wj.Context, owner: wj.JSValue, prop: cstring, w: wj.JSValue) {
	if wj.is_undefined(w) { return }
	a := wj.JS_NewAtom(ctx, prop)
	if wj.JS_DefinePropertyValue(ctx, owner, a, w, wj.PROP_CONFIGURABLE | wj.PROP_WRITABLE) < 0 { clear_exception(ctx) }
	wj.JS_FreeAtom(ctx, a)
}

// ---- fetch and XMLHttpRequest ----

@(private = "file")
tests_init :: proc "contextless" (ctx: ^wj.Context, r: ^Rule, needle_arg: [^]u8) {
	parts := split_chars(needle_arg, " \t")
	r.tests = ([^]Ftest)(wj.libc_calloc(uint(max(parts.n, 1)), size_of(Ftest)))
	if r.tests == nil { words_free(parts); return }
	for i in 0 ..< parts.n {
		p := parts.w[i]
		pl := cstr_len(p)
		colon := wj.index_byte(p, pl, ':')
		key := colon > 0
		if key { for c in 0 ..< colon { if p[c] < 'a' || p[c] > 'z' { key = false } } }
		r.tests[i].n.re = wj.UNDEFINED
		if key {
			r.tests[i].key = str_dup(p, colon)
			needle_init(ctx, &r.tests[i].n, p[colon + 1:])
		} else {
			r.tests[i].key = str_dup(raw_data(string("url")), 3)
			needle_init(ctx, &r.tests[i].n, p)
		}
	}
	words_free(parts)
	r.ntests = parts.n
}

@(private = "file")
prop_of :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring) -> wj.JSValue {
	if !wj.is_object(o) { return wj.UNDEFINED }
	v := wj.JS_GetPropertyStr(ctx, o, name)
	if wj.is_exception(v) { clear_exception(ctx); return wj.UNDEFINED }
	return v
}

@(private = "file")
test_value_str :: proc "contextless" (ctx: ^wj.Context, n: ^Needle, v: wj.JSValue, dflt: cstring) -> bool {
	if wj.is_nullish(v) { return needle_test(ctx, n, ([^]u8)(rawptr(dflt))) }
	return needle_test_value(ctx, n, v)
}

@(private = "file")
fetch_hook :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, d: [^]wj.JSValue) -> wj.JSValue {
	r := rules[wj.int_of(d[1])]
	input := argc > 0 ? argv[0] : wj.UNDEFINED
	init := argc > 1 ? argv[1] : wj.UNDEFINED
	all := true
	for i: i32 = 0; i < r.ntests && all; i += 1 {
		t := &r.tests[i]
		v: wj.JSValue
		ok: bool
		if is(t.key, "url") {
			v = wj.is_string(input) ? wj.JS_DupValue(ctx, input) : prop_of(ctx, input, "url")
			ok = test_value_str(ctx, &t.n, v, "")
		} else if is(t.key, "method") {
			v = prop_of(ctx, init, "method")
			if wj.is_undefined(v) { wj.JS_FreeValue(ctx, v); v = prop_of(ctx, input, "method") }
			ok = test_value_str(ctx, &t.n, v, "GET")
		} else {
			v = prop_of(ctx, init, cstring(t.key))
			ok = test_value_str(ctx, &t.n, v, "")
		}
		wj.JS_FreeValue(ctx, v)
		all = ok
	}
	if !all { return wj.JS_Call(ctx, d[0], this_val, argc, argv) }
	g := wj.JS_GetGlobalObject(ctx)
	R := wj.JS_GetPropertyStr(ctx, g, "Response")
	resp := wj.UNDEFINED
	if wj.JS_IsFunction(ctx, R) {
		args := [2]wj.JSValue{wj.JS_NewString(ctx, r.body_empty ? "" : "{}"), wj.JS_NewObject(ctx)}
		wj.JS_SetPropertyStr(ctx, args[1], "status", wj.new_int32(200))
		wj.JS_SetPropertyStr(ctx, args[1], "statusText", wj.JS_NewString(ctx, "OK"))
		resp = wj.JS_CallConstructor(ctx, R, 2, &args[0])
		wj.JS_FreeValue(ctx, args[0])
		wj.JS_FreeValue(ctx, args[1])
		if wj.is_exception(resp) { clear_exception(ctx); resp = wj.UNDEFINED }
	}
	if wj.is_undefined(resp) { resp = wj.JS_NewObject(ctx) }
	wj.JS_FreeValue(ctx, R)
	wj.JS_FreeValue(ctx, g)
	return promise_static(ctx, "resolve", resp)
}

// XMLHttpRequest: open records the method and URL, send is answered when they match.
@(private = "file")
xhr_open_hook :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, d: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_object(this_val) {
		wj.JS_DefinePropertyValueStr(ctx, this_val, "__wbm", argc > 0 ? wj.JS_DupValue(ctx, argv[0]) : wj.UNDEFINED, wj.PROP_CONFIGURABLE | wj.PROP_WRITABLE)
		wj.JS_DefinePropertyValueStr(ctx, this_val, "__wbu", argc > 1 ? wj.JS_DupValue(ctx, argv[1]) : wj.UNDEFINED, wj.PROP_CONFIGURABLE | wj.PROP_WRITABLE)
	}
	return wj.JS_Call(ctx, d[0], this_val, argc, argv)
}

@(private = "file") xhr_event_names := [3]cstring{"readystatechange", "load", "loadend"}

@(private = "file")
xhr_events :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, d: [^]wj.JSValue) -> wj.JSValue {
	xhr := d[0]
	g := wj.JS_GetGlobalObject(ctx)
	E := wj.JS_GetPropertyStr(ctx, g, "Event")
	h := wj.JS_GetPropertyStr(ctx, xhr, "onreadystatechange")
	if wj.JS_IsFunction(ctx, h) {
		r := wj.JS_Call(ctx, h, xhr, 0, nil)
		if wj.is_exception(r) { clear_exception(ctx) }
		wj.JS_FreeValue(ctx, r)
	}
	wj.JS_FreeValue(ctx, h)
	for i := 0; i < 3 && wj.JS_IsFunction(ctx, E); i += 1 {
		name := wj.JS_NewString(ctx, xhr_event_names[i])
		ev := wj.JS_CallConstructor(ctx, E, 1, &name)
		wj.JS_FreeValue(ctx, name)
		if wj.is_exception(ev) { clear_exception(ctx); continue }
		a := wj.JS_NewAtom(ctx, "dispatchEvent")
		r := wj.JS_Invoke(ctx, xhr, a, 1, &ev)
		wj.JS_FreeAtom(ctx, a)
		if wj.is_exception(r) { clear_exception(ctx) }
		wj.JS_FreeValue(ctx, r)
		wj.JS_FreeValue(ctx, ev)
	}
	wj.JS_FreeValue(ctx, E)
	wj.JS_FreeValue(ctx, g)
	return wj.UNDEFINED
}

@(private = "file") xhr_props := [4]cstring{"readyState", "status", "responseText", "response"}

@(private = "file")
xhr_send_hook :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, d: [^]wj.JSValue) -> wj.JSValue {
	r := rules[wj.int_of(d[1])]
	all := wj.is_object(this_val)
	for i: i32 = 0; i < r.ntests && all; i += 1 {
		v := wj.JS_GetPropertyStr(ctx, this_val, is(r.tests[i].key, "method") ? "__wbm" : "__wbu")
		all = test_value_str(ctx, &r.tests[i].n, v, "")
		wj.JS_FreeValue(ctx, v)
	}
	if !all { return wj.JS_Call(ctx, d[0], this_val, argc, argv) }
	for i in 0 ..< 4 {
		v := i == 0 ? wj.new_int32(4) : (i == 1 ? wj.new_int32(200) : wj.JS_NewString(ctx, ""))
		wj.JS_DefinePropertyValueStr(ctx, this_val, xhr_props[i], v, wj.PROP_CONFIGURABLE)
	}
	g := wj.JS_GetGlobalObject(ctx)
	st := wj.JS_GetPropertyStr(ctx, g, "setTimeout")
	if wj.JS_IsFunction(ctx, st) {
		data := [1]wj.JSValue{wj.JS_DupValue(ctx, this_val)}
		cb := wj.JS_NewCFunctionData(ctx, xhr_events, 0, 0, 1, &data[0])
		wj.JS_FreeValue(ctx, data[0])
		args := [2]wj.JSValue{cb, wj.new_int32(1)}
		t := wj.JS_Call(ctx, st, g, 2, &args[0])
		wj.JS_FreeValue(ctx, t)
		wj.JS_FreeValue(ctx, cb)
	}
	wj.JS_FreeValue(ctx, st)
	wj.JS_FreeValue(ctx, g)
	return wj.UNDEFINED
}

// ---- addEventListener, window.open ----

@(private = "file")
aeld_hook :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, d: [^]wj.JSValue) -> wj.JSValue {
	r := rules[wj.int_of(d[1])]
	if argc >= 2 && needle_test_value(ctx, &r.n1, argv[0]) {
		src := wj.UNDEFINED
		if wj.JS_IsFunction(ctx, argv[1]) {
			src = wj.JS_DupValue(ctx, argv[1])
		} else if wj.is_object(argv[1]) {
			src = wj.JS_GetPropertyStr(ctx, argv[1], "handleEvent")
		}
		is_fn := wj.JS_IsFunction(ctx, src)
		hit := r.n2.mode == NEEDLE_ANY || (is_fn && needle_test_value(ctx, &r.n2, src)) || (!is_fn && needle_test(ctx, &r.n2, wj.empty_ptr()))
		wj.JS_FreeValue(ctx, src)
		if hit { return wj.UNDEFINED }
	}
	return wj.JS_Call(ctx, d[0], this_val, argc, argv)
}

@(private = "file") wopen_noops := [5]cstring{"close", "focus", "blur", "postMessage", "open"}

@(private = "file")
wopen_hook :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, d: [^]wj.JSValue) -> wj.JSValue {
	r := rules[wj.int_of(d[1])]
	hit := argc > 0 ? needle_test_value(ctx, &r.n1, argv[0]) : needle_test(ctx, &r.n1, wj.empty_ptr())
	if !hit { return wj.JS_Call(ctx, d[0], this_val, argc, argv) }
	if !r.replace_obj { return wj.NULL }
	o := wj.JS_NewObject(ctx)
	for name in wopen_noops { wj.JS_SetPropertyStr(ctx, o, name, wj.new_cfunction(ctx, fn_noop, name, 0)) }
	return o
}

// ---- noeval, nowebrtc ----

@(private = "file") webrtc_noops := [3]cstring{"close", "addEventListener", "removeEventListener"}
@(private = "file") webrtc_proms := [4]cstring{"createOffer", "createAnswer", "setLocalDescription", "setRemoteDescription"}
@(private = "file") webrtc_names := [3]cstring{"RTCPeerConnection", "webkitRTCPeerConnection", "mozRTCPeerConnection"}

@(private = "file")
webrtc_stub :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	o := wj.JS_NewObject(ctx)
	for name in webrtc_noops { wj.JS_SetPropertyStr(ctx, o, name, wj.new_cfunction(ctx, fn_noop, name, 0)) }
	for name in webrtc_proms { wj.JS_SetPropertyStr(ctx, o, name, wj.new_cfunction(ctx, fn_resolve_undef, name, 0)) }
	wj.JS_SetPropertyStr(ctx, o, "createDataChannel", wj.new_cfunction(ctx, fn_noop, "createDataChannel", 0))
	return o
}

// ---- json-prune on JSON.parse ----

@(private = "file")
path_rec :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, parts: Words, i: i32, del: bool, depth: int) -> bool {
	if !wj.is_object(o) || depth > 12 { return false }
	key := parts.w[i]
	wild := is(key, "*") || is(key, "[]") || is(key, "[-]")
	last := i == parts.n - 1
	hit := false
	if wild {
		tab: [^]wj.Property_Enum
		n: u32
		if wj.JS_GetOwnPropertyNames(ctx, &tab, &n, o, wj.GPN_STRING_MASK | wj.GPN_ENUM_ONLY) < 0 { clear_exception(ctx); return false }
		for k: u32 = 0; k < n; k += 1 {
			if last {
				hit = true
				if del { wj.JS_DeleteProperty(ctx, o, tab[k].atom, 0) }
			} else {
				child := wj.JS_GetProperty(ctx, o, tab[k].atom)
				if path_rec(ctx, child, parts, i + 1, del, depth + 1) { hit = true }
				wj.JS_FreeValue(ctx, child)
			}
		}
		wj.JS_FreePropertyEnum(ctx, tab, n)
		return hit
	}
	a := wj.JS_NewAtom(ctx, cstring(key))
	has := wj.JS_HasProperty(ctx, o, a)
	if has > 0 {
		if last {
			hit = true
			if del { wj.JS_DeleteProperty(ctx, o, a, 0) }
		} else {
			child := wj.JS_GetProperty(ctx, o, a)
			hit = path_rec(ctx, child, parts, i + 1, del, depth + 1)
			wj.JS_FreeValue(ctx, child)
		}
	} else if has < 0 {
		clear_exception(ctx)
	}
	wj.JS_FreeAtom(ctx, a)
	return hit
}

@(private = "file")
json_hook :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, d: [^]wj.JSValue) -> wj.JSValue {
	r := rules[wj.int_of(d[1])]
	res := wj.JS_Call(ctx, d[0], this_val, argc, argv)
	if wj.is_exception(res) || !wj.is_object(res) { return res }
	if r.n1.mode != NEEDLE_ANY && !stack_matches(ctx, &r.n1) { return res }
	for i in 0 ..< r.nreq { if !path_rec(ctx, res, r.req[i], 0, false, 0) { return res } }
	for i in 0 ..< r.npaths { path_rec(ctx, res, r.paths[i], 0, true, 0) }
	return res
}

// ---- installation ----

@(private = "file")
paths_init :: proc "contextless" (dst: ^[MAX_PATHS]Words, count: ^i32, spec: [^]u8) {
	words := split_chars(spec, " \t\r\n")
	for i := i32(0); i < words.n && count^ < MAX_PATHS; i += 1 {
		parts := split_chars(words.w[i], ".")
		if parts.n > 0 { dst[count^] = parts; count^ += 1 } else { words_free(parts) }
	}
	words_free(words)
}

// argument `i` of a rule ("" when absent)
@(private = "file")
argn :: #force_inline proc "contextless" (a: [^][^]u8, n: int, i: int) -> [^]u8 { return i < n ? a[i] : wj.empty_ptr() }

@(private = "file")
install_rule :: proc "contextless" (ctx: ^wj.Context, name: [^]u8, a: [^][^]u8, n: int) {
	g := wj.JS_GetGlobalObject(ctx)
	defer wj.JS_FreeValue(ctx, g)
	if is(name, "set-constant") || is(name, "abort-on-property-read") || is(name, "abort-on-property-write") ||
	   is(name, "abort-current-script") || is(name, "abort-on-stack-trace") {
		kind: i32 = is(name, "set-constant") ? R_SET_CONST : is(name, "abort-on-property-read") ? R_AOPR :
		            is(name, "abort-on-property-write") ? R_AOPW : is(name, "abort-current-script") ? R_ACS : R_AOST
		if argn(a, n, 0)[0] == 0 { return }
		r := new_rule(kind)
		if r == nil { return }
		r.parts = split_chars(argn(a, n, 0), ".")
		if r.parts.n == 0 { return }
		if kind == R_SET_CONST {
			r.val = to_value(ctx, n > 1 ? a[1] : raw_data(string("undefined\x00")))
			r.aborted = is(argn(a, n, 2), "aborted")
		} else if kind == R_ACS || kind == R_AOST {
			needle_init(ctx, &r.n1, argn(a, n, 1))
		}
		trap_walk(ctx, g, nrules - 1, 0)
	} else if is(name, "no-setTimeout-if") || is(name, "no-setInterval-if") {
		r := new_rule(R_TIMER)
		if r == nil { return }
		needle_init(ctx, &r.n1, argn(a, n, 0))
		r.delay = str_dup(argn(a, n, 1), cstr_len(argn(a, n, 1)))
		prop: cstring = is(name, "no-setTimeout-if") ? "setTimeout" : "setInterval"
		replace_property(ctx, g, prop, wrap_global_function(ctx, g, prop, timer_hook, nrules - 1, 0, 2))
	} else if is(name, "nano-setTimeout-booster") || is(name, "nano-setInterval-booster") {
		r := new_rule(R_BOOST)
		if r == nil { return }
		needle_init(ctx, &r.n1, argn(a, n, 0))
		r.delay = str_dup(argn(a, n, 1), cstr_len(argn(a, n, 1)))
		b := argn(a, n, 2)[0] != 0 ? wj.strtod(a[2], nil) : 0.05
		r.boost = (b >= 0.001 && b <= 50) ? b : 0.05
		prop: cstring = is(name, "nano-setTimeout-booster") ? "setTimeout" : "setInterval"
		replace_property(ctx, g, prop, wrap_global_function(ctx, g, prop, timer_hook, nrules - 1, 1, 2))
	} else if is(name, "no-fetch-if") {
		r := new_rule(R_FETCH)
		if r == nil { return }
		tests_init(ctx, r, argn(a, n, 0))
		r.body_empty = is(argn(a, n, 1), "emptyStr")
		replace_property(ctx, g, "fetch", wrap_global_function(ctx, g, "fetch", fetch_hook, nrules - 1, 0, 1))
	} else if is(name, "no-xhr-if") {
		r := new_rule(R_XHR)
		if r == nil { return }
		tests_init(ctx, r, argn(a, n, 0))
		X := wj.JS_GetPropertyStr(ctx, g, "XMLHttpRequest")
		proto := wj.is_object(X) ? wj.JS_GetPropertyStr(ctx, X, "prototype") : wj.UNDEFINED
		if wj.is_object(proto) {
			replace_property(ctx, proto, "open", wrap_global_function(ctx, proto, "open", xhr_open_hook, nrules - 1, 0, 2))
			replace_property(ctx, proto, "send", wrap_global_function(ctx, proto, "send", xhr_send_hook, nrules - 1, 0, 0))
		}
		wj.JS_FreeValue(ctx, proto)
		wj.JS_FreeValue(ctx, X)
	} else if is(name, "addEventListener-defuser") {
		r := new_rule(R_AELD)
		if r == nil { return }
		needle_init(ctx, &r.n1, argn(a, n, 0))
		needle_init(ctx, &r.n2, argn(a, n, 1))
		T := wj.JS_GetPropertyStr(ctx, g, "EventTarget")
		proto := wj.is_object(T) ? wj.JS_GetPropertyStr(ctx, T, "prototype") : wj.UNDEFINED
		if wj.is_object(proto) {
			replace_property(ctx, proto, "addEventListener", wrap_global_function(ctx, proto, "addEventListener", aeld_hook, nrules - 1, 0, 2))
		}
		wj.JS_FreeValue(ctx, proto)
		wj.JS_FreeValue(ctx, T)
	} else if is(name, "window.open-defuser") {
		r := new_rule(R_WOPEN)
		if r == nil { return }
		needle_init(ctx, &r.n1, argn(a, n, 0))
		r.replace_obj = is(argn(a, n, 2), "obj")
		replace_property(ctx, g, "open", wrap_global_function(ctx, g, "open", wopen_hook, nrules - 1, 0, 0))
	} else if is(name, "noeval") {
		replace_property(ctx, g, "eval", wj.new_cfunction(ctx, fn_noop, "eval", 1))
	} else if is(name, "nowebrtc") {
		for rtc in webrtc_names {
			o := wj.JS_GetPropertyStr(ctx, g, rtc)
			if wj.JS_IsFunction(ctx, o) { replace_property(ctx, g, rtc, wj.JS_NewCFunction2(ctx, webrtc_stub, rtc, 0, wj.CFUNC_constructor, 0)) }
			wj.JS_FreeValue(ctx, o)
		}
	} else if is(name, "json-prune") {
		r := new_rule(R_JSON)
		if r == nil { return }
		paths_init(&r.paths, &r.npaths, argn(a, n, 0))
		paths_init(&r.req, &r.nreq, argn(a, n, 1))
		needle_init(ctx, &r.n1, argn(a, n, 2))
		J := wj.JS_GetPropertyStr(ctx, g, "JSON")
		if wj.is_object(J) && r.npaths > 0 { replace_property(ctx, J, "parse", wrap_global_function(ctx, J, "parse", json_hook, nrules - 1, 0, 2)) }
		wj.JS_FreeValue(ctx, J)
	}
}

// Installs the rules of a document. `spec` (len bytes, in this memory): records of fields, see the top of the file.
// Returns how many rules were read. Meant to run once, before the page's first script.
@(export, link_name = "wj_hook_install")
wj_hook_install :: proc "c" (spec: u32, n: u32) -> i32 {
	ctx := wj.wj_the_realm.ctx
	text := ([^]u8)(uintptr(spec))
	count: i32 = 0
	i := 0
	for i < int(n) {
		j := i
		for j < int(n) && text[j] != 0x1e { j += 1 }
		// one record text[i ..< j), its fields NUL-terminated in a copy (a field ends at 0x1f, or at a NUL of the text)
		fields: [16][^]u8
		record := str_dup(text[i:], j - i)
		if record != nil {
			nf := 0
			p := 0
			for nf < 16 {
				fields[nf] = record[p:]
				nf += 1
				q := p
				for record[q] != 0 && record[q] != 0x1f { q += 1 }
				if record[q] == 0 { break }
				record[q] = 0
				p = q + 1
			}
			if nf > 0 && fields[0][0] != 0 {
				install_rule(ctx, fields[0], &fields[1], nf - 1)
				count += 1
			}
			wj.libc_free(record)
		}
		i = j + 1
	}
	return count
}
