// web_devtools.odin: the description of console arguments for the developer tools, native. While the panel is open (the
// shell sets `on` on the state object kept under console[Symbol.for("wren.devtools")]), each console call first sends a
// description of its arguments, as JSON (strings, numbers, objects with their properties, Maps, Sets, DOM nodes,
// errors with their stacks, tables), through console.debug with a prefix the shell recognizes; the console call then
// goes on as it always did. `eval` runs a console expression and `complete` lists the names of an object; `store` /
// `storeNode` keep a value under a global name and `copy` sends it as JSON text. The shape of the state object and its
// methods is the contract src/page/devtools_api.odin relies on. Ported from native/js/runtime/web_devtools.c; same
// wj_devtools_install and messages.
//
// The value walk and the JSON it builds are Odin (a byte builder on the libc heap); only string escaping leans on the
// engine's JSON.stringify and a function's source on Function.prototype.toString, as before.
package odin_glue

import "../odin/wj"

@(private = "file") DT_MAXKEYS :: 100
@(private = "file") DT_MAXDEPTH :: 4

@(private = "file") Out :: [dynamic]u8

// One description being written: the state object, the JSON, the budget of nested objects it may expand, the
// objects on the path from the root (cycles), the depth.
@(private = "file")
Ser :: struct {
	ctx:    ^wj.Context,
	state:  wj.JSValue,
	out:    Out,
	budget: int,
	seen:   [dynamic]wj.JSValue,   // counted
	depth:  int,
}

@(private = "file")
ser_make :: proc(ctx: ^wj.Context, state: wj.JSValue, budget: int) -> Ser {
	return Ser{ctx = ctx, state = state, budget = budget}
}

@(private = "file")
ser_free :: proc(s: ^Ser) {
	for v in s.seen { wj.JS_FreeValue(s.ctx, v) }
	delete(s.seen)
	delete(s.out)
}

@(private = "file")
put_int :: proc(out: ^Out, v: i64) {
	digits: [24]u8
	n := len(digits)
	u := v < 0 ? u64(-v) : u64(v)
	for {
		n -= 1
		digits[n] = u8('0' + u % 10)
		u /= 10
		if u == 0 { break }
	}
	if v < 0 { n -= 1; digits[n] = '-' }
	append(out, string(digits[n:]))
}

@(private = "file") global_prop :: #force_inline proc "contextless" (ctx: ^wj.Context, name: cstring) -> wj.JSValue { return wj.global_get(ctx, name) }

// the atom of Symbol.for("wren.devtools")
@(private = "file")
dt_symbol_atom :: proc "contextless" (ctx: ^wj.Context) -> wj.Atom {
	sym := global_prop(ctx, "Symbol")
	key := wj.new_string(ctx, "wren.devtools")
	s := wj.invoke(ctx, sym, "for", ([^]wj.JSValue)(&key)[:1])
	free_values(ctx, key, sym)
	a := wj.JS_ValueToAtom(ctx, s)
	wj.JS_FreeValue(ctx, s)
	return a
}

// JSON.stringify(String(v)), cut to 1000 code units and an ellipsis, appended to `out`
@(private = "file")
dt_str :: proc(ctx: ^wj.Context, out: ^Out, sv: wj.JSValue) {
	s := wj.JS_ToString(ctx, sv)
	lenv := wj.JS_GetPropertyStr(ctx, s, "length")
	n: u32
	wj.JS_ToUint32(ctx, &n, lenv)
	wj.JS_FreeValue(ctx, lenv)
	use: wj.JSValue
	if n > 1000 {
		bounds := [2]wj.JSValue{wj.new_int32(0), wj.new_int32(1000)}
		cut := wj.invoke(ctx, s, "slice", bounds[:])
		ell := wj.new_string(ctx, "\u2026")
		use = wj.invoke(ctx, cut, "concat", ([^]wj.JSValue)(&ell)[:1])
		free_values(ctx, ell, cut)
	} else {
		use = wj.JS_DupValue(ctx, s)
	}
	wj.JS_FreeValue(ctx, s)
	j := wj.JS_JSONStringify(ctx, use, wj.UNDEFINED, wj.UNDEFINED)
	wj.JS_FreeValue(ctx, use)
	c, text := to_text(ctx, j)
	append(out, c != nil ? text : "\"\"")
	if c != nil { wj.free_cstring(ctx, c) }
	wj.JS_FreeValue(ctx, j)
}

@(private = "file")
dt_str_text :: proc(ctx: ^wj.Context, out: ^Out, text: string) {
	v := js_string(ctx, text)
	dt_str(ctx, out, v)
	wj.JS_FreeValue(ctx, v)
}

// classOf(v): v.constructor.name, else Object.prototype.toString.call(v).slice(8, -1)
@(private = "file")
dt_class_of :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^Out) {
	k := wj.JS_GetPropertyStr(ctx, v, "constructor")
	if wj.JS_IsFunction(ctx, k) {
		nm := wj.JS_GetPropertyStr(ctx, k, "name")
		c, s := to_text(ctx, nm)
		if c != nil { append(out, s); wj.free_cstring(ctx, c) }
		wj.JS_FreeValue(ctx, nm)
	}
	wj.JS_FreeValue(ctx, k)
	if len(out) > 0 { return }
	objc := global_prop(ctx, "Object")
	proto := wj.JS_GetPropertyStr(ctx, objc, "prototype")
	ts := wj.JS_GetPropertyStr(ctx, proto, "toString")
	r := wj.JS_Call(ctx, ts, v, 0, nil)
	c, s := to_text(ctx, r)
	if c != nil && len(s) > 9 { append(out, s[8:len(s) - 1]) } else { append(out, "Object") }
	if c != nil { wj.free_cstring(ctx, c) }
	free_values(ctx, r, ts, proto, objc)
}

@(private = "file")
is_space :: #force_inline proc "contextless" (c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }

// fdesc(f): the display form of a function: (class ? "class " : "") + (name || "(anonymous)") + (class ? "" : "(args)")
@(private = "file")
dt_fdesc :: proc(ctx: ^wj.Context, f: wj.JSValue, out: ^Out) {
	fp := global_prop(ctx, "Function")
	fproto := wj.JS_GetPropertyStr(ctx, fp, "prototype")
	tsfn := wj.JS_GetPropertyStr(ctx, fproto, "toString")
	src := wj.JS_Call(ctx, tsfn, f, 0, nil)
	free_values(ctx, tsfn, fproto, fp)
	sc: cstring
	s: string
	if wj.is_exception(src) { wj.drop_exception(ctx) } else { sc, s = to_text(ctx, src) }
	// class? /^\s*class\b/
	q := s
	for len(q) > 0 && is_space(q[0]) { q = q[1:] }
	is_class := len(q) >= 5 && q[:5] == "class" && (len(q) == 5 || is_space(q[5]) || q[5] == '{' || q[5] == '/')
	// args: /^[^{]*?\(([^)]*)\)/, the first (...) before any {, whitespace runs collapsed and trimmed
	args: [dynamic]u8
	defer delete(args)
	if !is_class && sc != nil {
		lp := -1
		for i in 0 ..< len(s) {
			if s[i] == '{' { break }
			if s[i] == '(' { lp = i + 1; break }
		}
		if lp >= 0 {
			rp := -1
			for i in lp ..< len(s) { if s[i] == ')' { rp = i; break } }
			if rp >= lp {
				space, started := false, false
				for c in transmute([]u8)s[lp:min(rp, lp + 255)] {
					if is_space(c) { if started { space = true }; continue }
					if space { append(&args, ' ') }
					space, started = false, true
					append(&args, c)
				}
			}
		}
	}
	namev := wj.JS_GetPropertyStr(ctx, f, "name")
	nc, name := to_text(ctx, namev)
	full: Out
	defer delete(full)
	if is_class { append(&full, "class ") }
	append(&full, nc != nil && len(name) > 0 ? name : "(anonymous)")
	if !is_class { append(&full, "("); append(&full, ..args[:]); append(&full, ")") }
	if nc != nil { wj.free_cstring(ctx, nc) }
	wj.JS_FreeValue(ctx, namev)
	if sc != nil { wj.free_cstring(ctx, sc) }
	wj.JS_FreeValue(ctx, src)
	dt_str_text(ctx, out, string(full[:]))
}

// a string property of v appended (when it is not empty, after `prefix` and before `suffix`)
@(private = "file")
put_prop :: proc(ctx: ^wj.Context, out: ^Out, v: wj.JSValue, name: cstring, prefix, suffix: string, strings_only := false) {
	pv := wj.JS_GetPropertyStr(ctx, v, name)
	defer wj.JS_FreeValue(ctx, pv)
	if strings_only && !wj.is_string(pv) { return }
	c, s := to_text(ctx, pv)
	if c == nil { return }
	if len(s) > 0 { append(out, prefix); append(out, s); append(out, suffix) }
	wj.free_cstring(ctx, c)
}

// domdesc(n): a short form of a DOM node
@(private = "file")
dt_domdesc :: proc(ctx: ^wj.Context, n: wj.JSValue, out: ^Out) {
	ntv := wj.JS_GetPropertyStr(ctx, n, "nodeType")
	nt: i32
	wj.JS_ToInt32(ctx, &nt, ntv)
	wj.JS_FreeValue(ctx, ntv)
	form: Out
	defer delete(form)
	switch nt {
	case 1:
		append(&form, "<")
		put_prop(ctx, &form, n, "localName", "", "")
		put_prop(ctx, &form, n, "id", " id=\"", "\"")
		put_prop(ctx, &form, n, "className", " class=\"", "\"", strings_only = true)
		append(&form, ">")
	case 3, 8:
		dv := wj.JS_GetPropertyStr(ctx, n, "data")
		ds := wj.JS_ToString(ctx, dv)
		bounds := [2]wj.JSValue{wj.new_int32(0), wj.new_int32(60)}
		cut := wj.invoke(ctx, ds, "slice", bounds[:])
		c, s := to_text(ctx, cut)
		if nt == 3 { append(&form, "#text \""); append(&form, s); append(&form, "\"") } else { append(&form, "<!--"); append(&form, s); append(&form, "-->") }
		if c != nil { wj.free_cstring(ctx, c) }
		free_values(ctx, cut, ds, dv)
	case 9:
		append(&form, "#document")
	case:
		nn := wj.JS_GetPropertyStr(ctx, n, "nodeName")
		c, s := to_text(ctx, nn)
		append(&form, c != nil ? s : "Node")
		if c != nil { wj.free_cstring(ctx, c) }
		wj.JS_FreeValue(ctx, nn)
	}
	dt_str_text(ctx, out, string(form[:]))
}

// v instanceof globalThis[name]
@(private = "file")
dt_instanceof :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, name: cstring) -> bool {
	ctor := global_prop(ctx, name)
	defer wj.JS_FreeValue(ctx, ctor)
	if !wj.is_object(ctor) { return false }
	return wj.JS_IsInstanceOf(ctx, v, ctor) > 0
}

// ArrayBuffer.isView(v)
@(private = "file")
dt_is_view :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> bool {
	v := v
	ab := global_prop(ctx, "ArrayBuffer")
	r := wj.invoke(ctx, ab, "isView", ([^]wj.JSValue)(&v)[:1])
	is := wj.JS_ToBool(ctx, r) > 0
	free_values(ctx, r, ab)
	return is
}

@(private = "file")
dt_seen_has :: proc(s: ^Ser, v: wj.JSValue) -> bool {
	for x in s.seen { if wj.same_ptr(x, v) { return true } }
	return false
}

// The entries of an iterator (from obj[method]()), each given to `each` until it returns false or `limit` is reached.
// Returns how many were seen.
@(private = "file")
dt_iterate :: proc(ctx: ^wj.Context, obj: wj.JSValue, method: cstring, limit: int, each: proc(s: ^Ser, item: wj.JSValue, i: int), s: ^Ser) -> int {
	it := wj.invoke(ctx, obj, method, nil)
	nextfn := wj.JS_GetPropertyStr(ctx, it, "next")
	defer free_values(ctx, nextfn, it)
	i := 0
	for {
		res := wj.JS_Call(ctx, nextfn, it, 0, nil)
		done := wj.JS_GetPropertyStr(ctx, res, "done")
		finished := wj.JS_ToBool(ctx, done) != 0   // (an exception ends the walk too)
		wj.JS_FreeValue(ctx, done)
		if finished || i >= limit { wj.JS_FreeValue(ctx, res); break }
		value := wj.JS_GetPropertyStr(ctx, res, "value")
		each(s, value, i)
		free_values(ctx, value, res)
		i += 1
	}
	return i
}

// obj(v): a non-null object value
@(private = "file")
dt_obj :: proc(s: ^Ser, v: wj.JSValue) {
	ctx := s.ctx
	out := &s.out
	s.budget -= 1
	cls: Out
	defer delete(cls)
	if wj.JS_IsArray(v) { append(&cls, "Array") } else { dt_class_of(ctx, v, &cls) }
	// Error / Node / Date / RegExp
	if dt_instanceof(ctx, v, "Error") {
		append(out, "{\"t\":\"x\",\"c\":"); dt_str_text(ctx, out, string(cls[:]))
		sv := wj.JS_ToString(ctx, v); append(out, ",\"d\":"); dt_str(ctx, out, sv); wj.JS_FreeValue(ctx, sv)
		st := wj.JS_GetPropertyStr(ctx, v, "stack")
		sts := wj.JS_ToString(ctx, st)
		append(out, ",\"st\":"); dt_str(ctx, out, sts)
		free_values(ctx, sts, st)
		append(out, "}")
		return
	}
	if dt_instanceof(ctx, v, "Node") { append(out, "{\"t\":\"d\",\"d\":"); dt_domdesc(ctx, v, out); append(out, "}"); return }
	if dt_instanceof(ctx, v, "Date") {
		append(out, "{\"t\":\"o\",\"c\":\"Date\",\"d\":")
		tv := wj.invoke(ctx, v, "getTime", nil)
		t: f64
		wj.JS_ToFloat64(ctx, &t, tv)
		wj.JS_FreeValue(ctx, tv)
		iso := t != t ? wj.new_string(ctx, "Invalid Date") : wj.invoke(ctx, v, "toISOString", nil)
		dt_str(ctx, out, iso)
		wj.JS_FreeValue(ctx, iso)
		append(out, "}")
		return
	}
	if dt_instanceof(ctx, v, "RegExp") {
		append(out, "{\"t\":\"o\",\"c\":\"RegExp\",\"d\":")
		sv := wj.JS_ToString(ctx, v); dt_str(ctx, out, sv); wj.JS_FreeValue(ctx, sv)
		append(out, "}")
		return
	}

	open := s.depth < DT_MAXDEPTH && s.budget > 0
	append(out, "{\"t\":\"o\",\"c\":"); dt_str_text(ctx, out, string(cls[:]))
	append(&s.seen, wj.JS_DupValue(ctx, v))
	defer { wj.JS_FreeValue(ctx, pop(&s.seen)) }
	size_of_prop :: proc(ctx: ^wj.Context, v: wj.JSValue, name: cstring) -> i64 {
		x := wj.JS_GetPropertyStr(ctx, v, name)
		n: i64
		wj.JS_ToInt64(ctx, &n, x)
		wj.JS_FreeValue(ctx, x)
		return n
	}
	switch {
	case dt_instanceof(ctx, v, "Map"):
		size := size_of_prop(ctx, v, "size")
		append(out, ",\"m\":"); put_int(out, size)
		if !open { break }
		append(out, ",\"p\":[")
		pair :: proc(s: ^Ser, item: wj.JSValue, i: int) {
			key := wj.JS_GetPropertyInt64(s.ctx, item, 0)
			val := wj.JS_GetPropertyInt64(s.ctx, item, 1)
			if i > 0 { append(&s.out, ",") }
			append(&s.out, "["); s.depth += 1; dt_node(s, key); append(&s.out, ","); dt_node(s, val); s.depth -= 1; append(&s.out, "]")
			free_values(s.ctx, key, val)
		}
		if dt_iterate(ctx, v, "entries", DT_MAXKEYS, pair, s) >= DT_MAXKEYS && size > DT_MAXKEYS {
			append(out, "],\"x\":"); put_int(out, size - DT_MAXKEYS); append(out, ",\"p2\":[")
		}
		append(out, "]")
	case dt_instanceof(ctx, v, "Set"):
		size := size_of_prop(ctx, v, "size")
		append(out, ",\"m\":"); put_int(out, size)
		if !open { break }
		append(out, ",\"p\":[")
		member :: proc(s: ^Ser, item: wj.JSValue, i: int) {
			if i > 0 { append(&s.out, ",") }
			append(&s.out, "[{\"t\":\"s\",\"v\":\"\"},"); s.depth += 1; dt_node(s, item); s.depth -= 1; append(&s.out, "]")
		}
		dt_iterate(ctx, v, "values", DT_MAXKEYS, member, s)
		append(out, "]")
		if size > DT_MAXKEYS { append(out, ",\"x\":"); put_int(out, size - DT_MAXKEYS) }
	case wj.JS_IsArray(v) || dt_is_view(ctx, v):
		n := size_of_prop(ctx, v, "length")
		append(out, ",\"m\":"); put_int(out, n)
		if !open { break }
		append(out, ",\"p\":[")
		for i in 0 ..< min(n, DT_MAXKEYS) {
			if i > 0 { append(out, ",") }
			idx: Out
			put_int(&idx, i)
			append(out, "["); dt_str_text(ctx, out, string(idx[:])); append(out, ",")
			delete(idx)
			el := wj.JS_GetPropertyInt64(ctx, v, i)
			s.depth += 1; dt_node(s, el); s.depth -= 1
			wj.JS_FreeValue(ctx, el)
			append(out, "]")
		}
		append(out, "]")
		if n > DT_MAXKEYS { append(out, ",\"x\":"); put_int(out, n - DT_MAXKEYS) }
	case:
		objc := global_prop(ctx, "Object")
		vv := v
		keys := wj.invoke(ctx, objc, "keys", ([^]wj.JSValue)(&vv)[:1])
		defer free_values(ctx, keys, objc)
		nk := wj.length_of(ctx, keys)
		append(out, ",\"m\":"); put_int(out, nk)
		if !open { break }
		append(out, ",\"p\":[")
		for i in 0 ..< min(nk, DT_MAXKEYS) {
			kv := wj.JS_GetPropertyInt64(ctx, keys, i)
			if i > 0 { append(out, ",") }
			append(out, "["); dt_str(ctx, out, kv); append(out, ",")
			// d = getOwnPropertyDescriptor(v, k); d && "value" in d ? d.value : (an accessor)
			da := [2]wj.JSValue{v, kv}
			d := wj.invoke(ctx, objc, "getOwnPropertyDescriptor", da[:])
			has_value := false
			if wj.is_object(d) {
				va := wj.JS_NewAtom(ctx, "value")
				has_value = wj.JS_HasProperty(ctx, d, va) > 0
				wj.JS_FreeAtom(ctx, va)
			}
			if has_value {
				val := wj.JS_GetPropertyStr(ctx, d, "value")
				s.depth += 1; dt_node(s, val); s.depth -= 1
				wj.JS_FreeValue(ctx, val)
			} else {
				append(out, "{\"t\":\"a\"}")
			}
			free_values(ctx, d, kv)
			append(out, "]")
		}
		append(out, "]")
		if nk > DT_MAXKEYS { append(out, ",\"x\":"); put_int(out, nk - DT_MAXKEYS) }
	}
	append(out, "}")
}

// node(v): any value
@(private = "file")
dt_node :: proc(s: ^Ser, v: wj.JSValue) {
	ctx := s.ctx
	out := &s.out
	switch {
	case wj.is_string(v):
		append(out, "{\"t\":\"s\",\"v\":"); dt_str(ctx, out, v); append(out, "}")
	case wj.is_number(v):
		d: f64
		wj.JS_ToFloat64(ctx, &d, v)
		append(out, "{\"t\":\"n\",\"v\":\"")
		if d == 0 && transmute(u64)d >> 63 != 0 {
			append(out, "-0")
		} else {
			sv := wj.JS_ToString(ctx, v)
			c, t := to_text(ctx, sv)
			if c != nil { append(out, t); wj.free_cstring(ctx, c) }
			wj.JS_FreeValue(ctx, sv)
		}
		append(out, "\"}")
	case wj.is_bool(v):
		append(out, wj.int_of(v) != 0 ? "{\"t\":\"b\",\"v\":true}" : "{\"t\":\"b\",\"v\":false}")
	case wj.is_undefined(v):
		append(out, "{\"t\":\"u\"}")
	case wj.is_big_int(v):
		sv := wj.JS_ToString(ctx, v)
		c, t := to_text(ctx, sv)
		append(out, "{\"t\":\"i\",\"v\":\""); append(out, c != nil ? t : "0"); append(out, "n\"}")
		if c != nil { wj.free_cstring(ctx, c) }
		wj.JS_FreeValue(ctx, sv)
	case wj.is_symbol(v):
		sv := wj.JS_ToString(ctx, v)
		append(out, "{\"t\":\"y\",\"v\":"); dt_str(ctx, out, sv); append(out, "}")
		wj.JS_FreeValue(ctx, sv)
	case wj.JS_IsFunction(ctx, v):
		append(out, "{\"t\":\"f\",\"d\":"); dt_fdesc(ctx, v, out); append(out, "}")
	case wj.is_null(v):
		append(out, "{\"t\":\"z\"}")
	case dt_seen_has(s, v):
		append(out, "{\"t\":\"c\"}")
	case:
		dt_obj(s, v)
	}
}

// ---- where(): the first stack frame outside this module ----

// best effort: new Error().stack, the first line with a source location that is not a native frame of this file
@(private = "file")
dt_where :: proc(ctx: ^wj.Context, out: ^Out) {
	errc := global_prop(ctx, "Error")
	err := wj.JS_CallConstructor(ctx, errc, 0, nil)
	wj.JS_FreeValue(ctx, errc)
	st := wj.JS_GetPropertyStr(ctx, err, "stack")
	wj.JS_FreeValue(ctx, err)
	defer wj.JS_FreeValue(ctx, st)
	c, text := to_text(ctx, st)
	best := ""
	defer if c != nil { wj.free_cstring(ctx, c) }
	rest := text
	for len(rest) > 0 {
		line := rest
		for ch, i in transmute([]u8)rest { if ch == '\n' { line = rest[:i]; break } }
		rest = len(line) < len(rest) ? rest[len(line) + 1:] : ""
		if len(line) == 0 || len(line) >= 512 || contains(line, "web_devtools") { continue }
		// trim leading whitespace and "at ", then what is inside the last "(...)"
		b := line
		for len(b) > 0 && (b[0] == ' ' || b[0] == '\t') { b = b[1:] }
		if len(b) >= 3 && b[:3] == "at " { b = b[3:] }
		for i := len(b) - 1; i >= 0; i -= 1 { if b[i] == '(' { b = b[i + 1:]; break } }
		for len(b) > 0 && (b[len(b) - 1] == ')' || b[len(b) - 1] == ' ' || b[len(b) - 1] == '\r') { b = b[:len(b) - 1] }
		// a source location: ':' followed by a digit somewhere
		loc := false
		for i in 0 ..< max(len(b) - 1, 0) { if b[i] == ':' && b[i + 1] >= '0' && b[i + 1] <= '9' { loc = true } }
		if loc && len(b) > 0 { best = b; break }
	}
	dt_str_text(ctx, out, best)
}

@(private = "file")
contains :: proc "contextless" (s, sub: string) -> bool {
	for i in 0 ..= len(s) - len(sub) { if s[i:i + len(sub)] == sub { return true } }
	return false
}

// ---- the state object and its accessors ----

@(private = "file")
dt_on :: proc "contextless" (ctx: ^wj.Context, state: wj.JSValue) -> bool {
	v := wj.JS_GetPropertyStr(ctx, state, "on")
	on := wj.JS_ToBool(ctx, v) > 0
	wj.JS_FreeValue(ctx, v)
	return on
}

@(private = "file")
dt_int :: proc "contextless" (ctx: ^wj.Context, state: wj.JSValue, name: cstring) -> i64 {
	v := wj.JS_GetPropertyStr(ctx, state, name)
	n: i64
	wj.JS_ToInt64(ctx, &n, v)
	wj.JS_FreeValue(ctx, v)
	return n
}

// state._orig[name]: the console method before wrapping
@(private = "file")
dt_orig :: proc "contextless" (ctx: ^wj.Context, state: wj.JSValue, name: cstring) -> wj.JSValue {
	orig := wj.JS_GetPropertyStr(ctx, state, "_orig")
	f := wj.JS_GetPropertyStr(ctx, orig, name)
	wj.JS_FreeValue(ctx, orig)
	return f
}

// orig.debug.call(console, text): the shell reads the prefixed messages
@(private = "file")
dt_debug :: proc "contextless" (ctx: ^wj.Context, state: wj.JSValue, text: []u8) {
	console := global_prop(ctx, "console")
	debug := dt_orig(ctx, state, "debug")
	arg := wj.new_string_len(ctx, text)
	r := wj.JS_Call(ctx, debug, console, 1, &arg)
	free_values(ctx, arg, r, debug, console)
}

// send(tag, json): "\u0001tag:" + json, when it is not longer than state.max
@(private = "file")
dt_send :: proc(ctx: ^wj.Context, state: wj.JSValue, tag: string, json: []u8) {
	if i64(len(json)) > dt_int(ctx, state, "max") { return }
	msg: Out
	defer delete(msg)
	append(&msg, "\x01"); append(&msg, tag); append(&msg, ":"); append(&msg, ..json)
	dt_debug(ctx, state, msg[:])
}

// keep(args): ++rid, refs.set(rid, args), the oldest evicted past 300; the id
@(private = "file")
dt_keep :: proc "contextless" (ctx: ^wj.Context, state: wj.JSValue, args: wj.JSValue) -> i64 {
	rid := dt_int(ctx, state, "rid") + 1
	wj.JS_SetPropertyStr(ctx, state, "rid", wj.new_int64(ctx, rid))
	refs := wj.JS_GetPropertyStr(ctx, state, "refs")
	defer wj.JS_FreeValue(ctx, refs)
	sa := [2]wj.JSValue{wj.new_int64(ctx, rid), args}
	r := wj.invoke(ctx, refs, "set", sa[:])
	free_values(ctx, sa[0], r)
	if dt_int(ctx, refs, "size") > 300 {
		it := wj.invoke(ctx, refs, "keys", nil)
		res := wj.invoke(ctx, it, "next", nil)
		first := wj.JS_GetPropertyStr(ctx, res, "value")
		dr := wj.invoke(ctx, refs, "delete", ([^]wj.JSValue)(&first)[:1])
		free_values(ctx, dr, first, res, it)
	}
	return rid
}

// ---- the wrapped console methods ----

// data: [state, the level string, the original method]; magic 1 for assert
@(private = "file")
dt_console_wrapper :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	state := data[0]
	console := global_prop(ctx, "console")
	defer wj.JS_FreeValue(ctx, console)
	recv := wj.is_undefined(this_val) ? console : this_val
	if dt_on(ctx, state) {
		lc, level := to_text(ctx, data[1])
		defer if lc != nil { wj.free_cstring(ctx, lc) }
		args := wj.JS_NewArray(ctx)
		for i in 0 ..< argc { wj.JS_SetPropertyUint32(ctx, args, u32(i), wj.JS_DupValue(ctx, argv[i])) }
		id := dt_keep(ctx, state, args)
		wj.JS_FreeValue(ctx, args)
		w: Out
		defer delete(w)
		dt_where(ctx, &w)
		s := ser_make(ctx, state, magic != 0 ? 200 : 400)   // (assert's budget is 200)
		defer ser_free(&s)
		append(&s.out, "{\"l\":\""); append(&s.out, lc != nil ? level : "log")
		append(&s.out, "\",\"r\":"); put_int(&s.out, id); append(&s.out, ",\"w\":")
		if len(w) > 0 { append(&s.out, ..w[:]) } else { append(&s.out, "\"\"") }
		append(&s.out, ",\"a\":[")
		if magic != 0 {
			// assert: ["Assertion failed"].concat(args)
			af := wj.new_string(ctx, "Assertion failed")
			dt_node(&s, af)
			wj.JS_FreeValue(ctx, af)
			for i in 0 ..< argc { append(&s.out, ","); dt_node(&s, argv[i]) }
		} else {
			for i in 0 ..< argc { if i > 0 { append(&s.out, ",") }; dt_node(&s, argv[i]) }
		}
		append(&s.out, "]}")
		dt_send(ctx, state, "dt", s.out[:])
	}
	return wj.JS_Call(ctx, data[2], recv, argc, argv)
}

// table(data, cols) as the "tbl" JSON in s.out (nothing when data is not an object)
@(private = "file")
Row :: struct { index: wj.JSValue, cells: wj.JSValue, value: wj.JSValue, has_value: bool }   // counted

@(private = "file")
Table :: struct { s: ^Ser, rows: [dynamic]Row, keys: [dynamic]wj.JSValue, has_values: bool }

@(private = "file")
table_add :: proc(t: ^Table, index: wj.JSValue, row: wj.JSValue) {
	ctx := t.s.ctx
	r := Row{index = index, cells = wj.JS_NewObject(ctx), value = wj.UNDEFINED}
	if wj.is_object(row) {
		objc := global_prop(ctx, "Object")
		rv := row
		rk := wj.invoke(ctx, objc, "keys", ([^]wj.JSValue)(&rv)[:1])
		wj.JS_FreeValue(ctx, objc)
		for ki in 0 ..< wj.length_of(ctx, rk) {
			k := wj.JS_GetPropertyInt64(ctx, rk, ki)
			kc, ks := to_text(ctx, k)
			found := false
			for e in t.keys {
				ec, es := to_text(ctx, e)
				if ec != nil { found = kc != nil && es == ks; wj.free_cstring(ctx, ec) }
				if found { break }
			}
			if kc != nil { wj.free_cstring(ctx, kc) }
			if !found { append(&t.keys, wj.JS_DupValue(ctx, k)) }
			ka := wj.JS_ValueToAtom(ctx, k)
			wj.JS_SetProperty(ctx, r.cells, ka, wj.JS_GetProperty(ctx, row, ka))
			wj.JS_FreeAtom(ctx, ka)
			wj.JS_FreeValue(ctx, k)
		}
		wj.JS_FreeValue(ctx, rk)
	} else {
		r.value = wj.JS_DupValue(ctx, row)
		r.has_value = true
		t.has_values = true
	}
	append(&t.rows, r)
}

@(private = "file")
index_string :: proc(ctx: ^wj.Context, i: int) -> wj.JSValue {
	b: Out
	defer delete(b)
	put_int(&b, i64(i))
	return wj.new_string_len(ctx, b[:])
}

// a nested description with a budget of its own
@(private = "file")
dt_cell :: proc(ctx: ^wj.Context, state: wj.JSValue, out: ^Out, v: wj.JSValue) {
	sub := ser_make(ctx, state, 50)
	defer ser_free(&sub)
	dt_node(&sub, v)
	append(out, ..sub.out[:])
}

@(private = "file")
dt_table_build :: proc(s: ^Ser, data: wj.JSValue, cols: wj.JSValue) {
	ctx := s.ctx
	if !wj.is_object(data) { return }
	t := Table{s = s}
	defer {
		for r in t.rows { free_values(ctx, r.index, r.cells, r.value) }
		for k in t.keys { wj.JS_FreeValue(ctx, k) }
		delete(t.rows)
		delete(t.keys)
	}
	if dt_instanceof(ctx, data, "Map") {
		entry :: proc(s: ^Ser, item: wj.JSValue, i: int) {
			t := (^Table)(context.user_ptr)
			val := wj.JS_GetPropertyInt64(s.ctx, item, 1)
			table_add(t, index_string(s.ctx, i), val)
			wj.JS_FreeValue(s.ctx, val)
		}
		context.user_ptr = &t
		dt_iterate(ctx, data, "entries", max(int), entry, s)
	} else if dt_instanceof(ctx, data, "Set") {
		member :: proc(s: ^Ser, item: wj.JSValue, i: int) { table_add((^Table)(context.user_ptr), index_string(s.ctx, i), item) }
		context.user_ptr = &t
		dt_iterate(ctx, data, "values", max(int), member, s)
	} else {
		objc := global_prop(ctx, "Object")
		dv := data
		dk := wj.invoke(ctx, objc, "keys", ([^]wj.JSValue)(&dv)[:1])
		wj.JS_FreeValue(ctx, objc)
		for i in 0 ..< min(wj.length_of(ctx, dk), 200) {
			k := wj.JS_GetPropertyInt64(ctx, dk, i)
			ka := wj.JS_ValueToAtom(ctx, k)
			val := wj.JS_GetProperty(ctx, data, ka)
			wj.JS_FreeAtom(ctx, ka)
			table_add(&t, wj.JS_ToString(ctx, k), val)
			free_values(ctx, val, k)
		}
		wj.JS_FreeValue(ctx, dk)
	}
	// the columns: Array.isArray(cols) ? cols.map(String) : the first 40 keys
	use: [dynamic]wj.JSValue
	defer { for u in use { wj.JS_FreeValue(ctx, u) }; delete(use) }
	if wj.JS_IsArray(cols) {
		for i in 0 ..< wj.length_of(ctx, cols) {
			c := wj.JS_GetPropertyInt64(ctx, cols, i)
			append(&use, wj.JS_ToString(ctx, c))
			wj.JS_FreeValue(ctx, c)
		}
	} else {
		for k in t.keys[:min(len(t.keys), 40)] { append(&use, wj.JS_DupValue(ctx, k)) }
	}
	out := &s.out
	append(out, "{\"cols\":[")
	for c, i in use { if i > 0 { append(out, ",") }; dt_str(ctx, out, c) }
	append(out, "],\"values\":"); append(out, t.has_values ? "true" : "false"); append(out, ",\"rows\":[")
	for r, ri in t.rows {
		if ri > 0 { append(out, ",") }
		append(out, "{\"i\":"); dt_str(ctx, out, r.index)
		append(out, ",\"v\":")
		if r.has_value { dt_cell(ctx, s.state, out, r.value) } else { append(out, "null") }
		append(out, ",\"c\":[")
		for k, ci in use {
			if ci > 0 { append(out, ",") }
			ka := wj.JS_ValueToAtom(ctx, k)
			if wj.JS_HasProperty(ctx, r.cells, ka) > 0 {
				cv := wj.JS_GetProperty(ctx, r.cells, ka)
				dt_cell(ctx, s.state, out, cv)
				wj.JS_FreeValue(ctx, cv)
			} else {
				append(out, "null")
			}
			wj.JS_FreeAtom(ctx, ka)
		}
		append(out, "]}")
	}
	append(out, "]}")
}

// data: [state, the original table]
@(private = "file")
dt_console_table :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	state := data[0]
	console := global_prop(ctx, "console")
	defer wj.JS_FreeValue(ctx, console)
	recv := wj.is_undefined(this_val) ? console : this_val
	if dt_on(ctx, state) {
		table := wj.arg(argc, argv, 0)
		if wj.is_object(table) {
			s := ser_make(ctx, state, 400)
			defer ser_free(&s)
			dt_table_build(&s, table, wj.arg(argc, argv, 1))
			if len(s.out) > 0 {
				holder := wj.JS_NewArray(ctx)
				wj.JS_SetPropertyUint32(ctx, holder, 0, wj.JS_DupValue(ctx, table))
				id := dt_keep(ctx, state, holder)
				wj.JS_FreeValue(ctx, holder)
				w, msg: Out
				defer { delete(w); delete(msg) }
				dt_where(ctx, &w)
				append(&msg, "{\"l\":\"log\",\"r\":"); put_int(&msg, id); append(&msg, ",\"w\":")
				if len(w) > 0 { append(&msg, ..w[:]) } else { append(&msg, "\"\"") }
				append(&msg, ",\"tbl\":"); append(&msg, ..s.out[:]); append(&msg, "}")
				dt_send(ctx, state, "dt", msg[:])
			}
		}
	}
	return wj.JS_Call(ctx, data[1], recv, argc, argv)
}

// show(val, err): its description for the tree (when on), then its text through orig.error / orig.info
@(private = "file")
dt_show :: proc(ctx: ^wj.Context, state: wj.JSValue, val: wj.JSValue, err: bool) {
	if dt_on(ctx, state) {
		holder := wj.JS_NewArray(ctx)
		wj.JS_SetPropertyUint32(ctx, holder, 0, wj.JS_DupValue(ctx, val))
		id := dt_keep(ctx, state, holder)
		wj.JS_FreeValue(ctx, holder)
		s := ser_make(ctx, state, 600)
		defer ser_free(&s)
		append(&s.out, "{\"l\":\""); append(&s.out, err ? "error" : "result")
		append(&s.out, "\",\"r\":"); put_int(&s.out, id); append(&s.out, ",\"a\":[")
		dt_node(&s, val)
		append(&s.out, "]}")
		dt_send(ctx, state, "dt", s.out[:])
	}
	text: wj.JSValue
	switch {
	case err:
		stack := wj.is_object(val) ? wj.JS_GetPropertyStr(ctx, val, "stack") : wj.UNDEFINED
		text = !wj.is_nullish(stack) ? wj.JS_ToString(ctx, stack) : wj.JS_ToString(ctx, val)
		wj.JS_FreeValue(ctx, stack)
	case wj.is_string(val):
		text = wj.JS_JSONStringify(ctx, val, wj.UNDEFINED, wj.UNDEFINED)
	case wj.JS_IsFunction(ctx, val):
		// the description's JSON string, read back as the plain text
		fb: Out
		defer delete(fb)
		dt_fdesc(ctx, val, &fb)
		if len(fb) == 0 { append(&fb, "\"\"") }
		append(&fb, 0)   // (JS_ParseJSON reads a NUL-terminated buffer)
		text = wj.JS_ParseJSON(ctx, raw_data(fb), uint(len(fb) - 1), "<dt>")
		if wj.is_exception(text) { wj.drop_exception(ctx); text = wj.JS_ToString(ctx, val) }
	case:
		text = wj.JS_ToString(ctx, val)
	}
	console := global_prop(ctx, "console")
	f := dt_orig(ctx, state, err ? "error" : "info")
	r := wj.JS_Call(ctx, f, console, 1, &text)
	free_values(ctx, r, f, console, text)
}

// store(v): v kept under temp1, temp2..., "> tempN" logged, then show(v)
@(private = "file")
dt_store :: proc(ctx: ^wj.Context, state: wj.JSValue, v: wj.JSValue) {
	temps := dt_int(ctx, state, "temps") + 1
	wj.JS_SetPropertyStr(ctx, state, "temps", wj.new_int64(ctx, temps))
	name: Out
	defer delete(name)
	append(&name, "temp"); put_int(&name, temps); append(&name, 0)
	if wj.JS_DefinePropertyValueStr(ctx, wj.realm_global(), cstring(raw_data(name)), wj.JS_DupValue(ctx, v), wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE) < 0 {
		wj.drop_exception(ctx)
		return
	}
	line: Out
	defer delete(line)
	append(&line, "> "); append(&line, ..name[:len(name) - 1])
	console := global_prop(ctx, "console")
	logf := dt_orig(ctx, state, "log")
	la := wj.new_string_len(ctx, line[:])
	r := wj.JS_Call(ctx, logf, console, 1, &la)
	free_values(ctx, la, r, logf, console)
	dt_show(ctx, state, v, false)
}

// pick(id): refs.get(id); its first object or function, else its first value
@(private = "file")
dt_pick :: proc "contextless" (ctx: ^wj.Context, state: wj.JSValue, id: i64) -> (wj.JSValue, bool) {
	refs := wj.JS_GetPropertyStr(ctx, state, "refs")
	idv := wj.new_int64(ctx, id)
	a := wj.invoke(ctx, refs, "get", ([^]wj.JSValue)(&idv)[:1])
	free_values(ctx, idv, refs)
	defer wj.JS_FreeValue(ctx, a)
	if !wj.is_object(a) { return wj.UNDEFINED, false }
	n := wj.length_of(ctx, a)
	if n == 0 { return wj.UNDEFINED, false }
	for i in 0 ..< n {
		x := wj.JS_GetPropertyInt64(ctx, a, i)
		if !wj.is_null(x) && (wj.is_object(x) || wj.JS_IsFunction(ctx, x)) { return x, true }
		wj.JS_FreeValue(ctx, x)
	}
	return wj.JS_GetPropertyInt64(ctx, a, 0), true
}

@(private = "file")
arg_int :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue) -> i64 {
	n: i64
	wj.JS_ToInt64(ctx, &n, wj.arg(argc, argv, 0))
	return n
}

// state.store(id)
@(private = "file")
dt_m_store :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	if v, ok := dt_pick(ctx, data[0], arg_int(ctx, argc, argv)); ok { dt_store(ctx, data[0], v); wj.JS_FreeValue(ctx, v) }
	return wj.UNDEFINED
}

// state.storeNode(path): document.childNodes walked by indices, the node stored
@(private = "file")
dt_m_store_node :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	path := wj.arg(argc, argv, 0)
	n := global_prop(ctx, "document")
	for i in 0 ..< wj.length_of(ctx, path) {
		if !wj.is_object(n) { break }
		iv := wj.JS_GetPropertyInt64(ctx, path, i)
		idx: i64
		wj.JS_ToInt64(ctx, &idx, iv)
		wj.JS_FreeValue(ctx, iv)
		cn := wj.JS_GetPropertyStr(ctx, n, "childNodes")
		next := wj.JS_GetPropertyInt64(ctx, cn, idx)
		free_values(ctx, cn, n)
		n = next
	}
	if wj.is_object(n) { dt_store(ctx, data[0], n) }
	wj.JS_FreeValue(ctx, n)
	return wj.UNDEFINED
}

// Function.prototype.toString.call(f), or String(f)
@(private = "file")
function_source :: proc "contextless" (ctx: ^wj.Context, f: wj.JSValue) -> wj.JSValue {
	fp := global_prop(ctx, "Function")
	fproto := wj.JS_GetPropertyStr(ctx, fp, "prototype")
	tsfn := wj.JS_GetPropertyStr(ctx, fproto, "toString")
	text := wj.JS_Call(ctx, tsfn, f, 0, nil)
	free_values(ctx, tsfn, fproto, fp)
	if wj.is_exception(text) { wj.drop_exception(ctx); text = wj.JS_ToString(ctx, f) }
	return text
}

// state.copy(id): the value as JSON text (cycles, Maps, Sets, errors, nodes), sent as "\u0001dtx:"
@(private = "file")
dt_m_copy :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	v, ok := dt_pick(ctx, data[0], arg_int(ctx, argc, argv))
	if !ok { return wj.UNDEFINED }
	defer wj.JS_FreeValue(ctx, v)
	text: wj.JSValue
	switch {
	case wj.is_string(v):           text = wj.JS_DupValue(ctx, v)
	case wj.is_undefined(v):        text = wj.new_string(ctx, "undefined")
	case wj.JS_IsFunction(ctx, v):  text = function_source(ctx, v)
	case:
		// JSON.stringify(v, replacer, 2) with the replacer kept on the state (_copyReplacer)
		replacer := wj.JS_GetPropertyStr(ctx, data[0], "_copyReplacer")
		json := global_prop(ctx, "JSON")
		sa := [3]wj.JSValue{v, replacer, wj.new_int32(2)}
		text = wj.invoke(ctx, json, "stringify", sa[:])
		free_values(ctx, json, replacer)
		if wj.is_exception(text) { wj.drop_exception(ctx); text = wj.JS_ToString(ctx, v) }
	}
	defer wj.JS_FreeValue(ctx, text)
	c, s := to_text(ctx, text)
	msg: Out
	defer delete(msg)
	append(&msg, "\x01dtx:"); append(&msg, s)
	if c != nil { wj.free_cstring(ctx, c) }
	dt_debug(ctx, data[0], msg[:])
	return wj.UNDEFINED
}

// state.eval(src): (0, eval)(src), an async retry for a top-level await, then show
@(private = "file")
dt_m_eval :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	srcv := wj.JS_ToString(ctx, wj.arg(argc, argv, 0))
	c, src := to_text(ctx, srcv)
	source: Out
	defer delete(source)
	append(&source, src); append(&source, 0)
	r := wj.JS_Eval(ctx, raw_data(source), uint(len(src)), "<console>", wj.EVAL_TYPE_GLOBAL)
	thrown := false
	if wj.is_exception(r) {
		e := wj.JS_GetException(ctx)
		// a SyntaxError with `await`: wrapped as an async IIFE
		if dt_instanceof(ctx, e, "SyntaxError") && contains(src, "await") {
			w: Out
			defer delete(w)
			append(&w, "(async () => ("); append(&w, src); append(&w, "\n))()"); append(&w, 0)
			r = wj.JS_Eval(ctx, raw_data(w), uint(len(w) - 1), "<console>", wj.EVAL_TYPE_GLOBAL)
			if wj.is_exception(r) { wj.drop_exception(ctx); r = e; thrown = true } else { wj.JS_FreeValue(ctx, e) }
		} else {
			r = e
			thrown = true
		}
	}
	if c != nil { wj.free_cstring(ctx, c) }
	wj.JS_FreeValue(ctx, srcv)
	defer wj.JS_FreeValue(ctx, r)
	// a thenable (not a function): shown, then its settled value or error shown
	if !thrown && wj.is_object(r) && !wj.JS_IsFunction(ctx, r) {
		then := wj.JS_GetPropertyStr(ctx, r, "then")
		defer wj.JS_FreeValue(ctx, then)
		if wj.JS_IsFunction(ctx, then) {
			dt_show(ctx, data[0], r, false)
			d := wj.web_then(ctx, r, rawptr(dt_then_ok), rawptr(dt_then_err), 1, data)
			wj.JS_FreeValue(ctx, d)
			return wj.UNDEFINED
		}
	}
	dt_show(ctx, data[0], r, thrown)
	return wj.UNDEFINED
}

@(private = "file")
dt_then_ok :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	dt_show(ctx, data[0], wj.arg(argc, argv, 0), false)
	return wj.UNDEFINED
}

@(private = "file")
dt_then_err :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	dt_show(ctx, data[0], wj.arg(argc, argv, 0), true)
	return wj.UNDEFINED
}

// state.complete(path): the names an expression offers (own and inherited, the nearest first, at most 400), sent as
// "\u0001dtc:"
@(private = "file")
dt_m_complete :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	pathv := wj.JS_ToString(ctx, wj.arg(argc, argv, 0))
	c, path := to_text(ctx, pathv)
	o: wj.JSValue
	if c == nil || len(path) == 0 {
		o = wj.JS_DupValue(ctx, wj.realm_global())
	} else {
		o = wj.JS_Eval(ctx, ([^]u8)(rawptr(c)), uint(len(path)), "<console>", wj.EVAL_TYPE_GLOBAL)
	}
	if c != nil { wj.free_cstring(ctx, c) }
	wj.JS_FreeValue(ctx, pathv)
	if wj.is_exception(o) { wj.drop_exception(ctx); return wj.UNDEFINED }
	defer wj.JS_FreeValue(ctx, o)
	if wj.is_nullish(o) { return wj.UNDEFINED }
	objc := global_prop(ctx, "Object")
	defer wj.JS_FreeValue(ctx, objc)
	p := wj.is_object(o) ? wj.JS_DupValue(ctx, o) : wj.JS_ToObject(ctx, o)
	// the names seen (a JS Set: names compare as the engine compares them), the list in order
	setc := global_prop(ctx, "Set")
	seen := wj.JS_CallConstructor(ctx, setc, 0, nil)
	wj.JS_FreeValue(ctx, setc)
	defer wj.JS_FreeValue(ctx, seen)
	list := wj.JS_NewArray(ctx)
	defer wj.JS_FreeValue(ctx, list)
	n_list: u32
	for depth := 0; wj.is_object(p) && depth < 8; depth += 1 {
		names := wj.invoke(ctx, objc, "getOwnPropertyNames", ([^]wj.JSValue)(&p)[:1])
		for i in 0 ..< wj.length_of(ctx, names) {
			if n_list >= 400 { break }
			k := wj.JS_GetPropertyInt64(ctx, names, i)
			has := wj.invoke(ctx, seen, "has", ([^]wj.JSValue)(&k)[:1])
			if wj.JS_ToBool(ctx, has) <= 0 {
				added := wj.invoke(ctx, seen, "add", ([^]wj.JSValue)(&k)[:1])
				wj.JS_FreeValue(ctx, added)
				wj.JS_SetPropertyUint32(ctx, list, n_list, wj.JS_DupValue(ctx, k))
				n_list += 1
			}
			free_values(ctx, has, k)
		}
		wj.JS_FreeValue(ctx, names)
		next := wj.invoke(ctx, objc, "getPrototypeOf", ([^]wj.JSValue)(&p)[:1])
		wj.JS_FreeValue(ctx, p)
		p = next
	}
	wj.JS_FreeValue(ctx, p)
	json := wj.JS_JSONStringify(ctx, list, wj.UNDEFINED, wj.UNDEFINED)
	defer wj.JS_FreeValue(ctx, json)
	jc, js := to_text(ctx, json)
	msg: Out
	defer delete(msg)
	append(&msg, "\x01dtc:"); append(&msg, jc != nil ? js : "[]")
	if jc != nil { wj.free_cstring(ctx, jc) }
	dt_debug(ctx, data[0], msg[:])
	return wj.UNDEFINED
}

// the JavaScript replacer of copy(): compiled once and kept on the state as _copyReplacer
@(private = "file")
DT_COPY_REPLACER :: "(function(){ const stack=[]; return function(k,x){" +
	"while(stack.length && stack[stack.length-1]!==this) stack.pop();" +
	"if(typeof x===\"bigint\") return x+\"n\";" +
	"if(typeof x===\"function\") return undefined;" +
	"if(typeof x===\"symbol\") return String(x);" +
	"if(x!==null && typeof x===\"object\"){" +
	"if(typeof Node!==\"undefined\" && x instanceof Node) return x.nodeType===1?x.outerHTML:String(x.nodeValue!==null?x.nodeValue:x.nodeName);" +
	"if(x instanceof Error) return {name:x.name,message:x.message,stack:x.stack};" +
	"if(stack.indexOf(x)>=0) return \"[Circular]\";" +
	"stack.push(x);" +
	"if(x instanceof Map) return Array.from(x.entries());" +
	"if(x instanceof Set) return Array.from(x.values());" +
	"} return x; }; })()"

// ---- install ----

// console.<name> = a wrapper (named after the method) with `data`
@(private = "file")
dt_wrap :: proc "contextless" (ctx: ^wj.Context, console: wj.JSValue, name: cstring, fn: wj.Native_Data, magic: i32, data: []wj.JSValue) {
	wrapper := wj.JS_NewCFunctionData(ctx, fn, 0, magic, i32(len(data)), raw_data(data))
	wj.JS_DefinePropertyValueStr(ctx, wrapper, "name", wj.new_string(ctx, name), wj.PROP_CONFIGURABLE)
	wj.JS_DefinePropertyValueStr(ctx, console, name, wrapper, wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE | wj.PROP_ENUMERABLE)
}

@(export, link_name = "wj_devtools_install")
wj_devtools_install :: proc "c" (ctx: ^wj.Context) {
	console := global_prop(ctx, "console")
	defer wj.JS_FreeValue(ctx, console)
	if !wj.is_object(console) { return }
	logfn := wj.JS_GetPropertyStr(ctx, console, "log")
	is_fn := wj.JS_IsFunction(ctx, logfn)
	wj.JS_FreeValue(ctx, logfn)
	if !is_fn { return }

	// state = { on: false, max: 262144, refs: new Map(), rid: 0, temps: 0, _orig: {...}, _copyReplacer }
	state := wj.JS_NewObject(ctx)
	defer wj.JS_FreeValue(ctx, state)
	wj.JS_SetPropertyStr(ctx, state, "on", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, state, "max", wj.new_int32(262144))
	mapc := global_prop(ctx, "Map")
	wj.JS_SetPropertyStr(ctx, state, "refs", wj.JS_CallConstructor(ctx, mapc, 0, nil))
	wj.JS_FreeValue(ctx, mapc)
	wj.JS_SetPropertyStr(ctx, state, "rid", wj.new_int32(0))
	wj.JS_SetPropertyStr(ctx, state, "temps", wj.new_int32(0))
	// _orig: the original methods, before wrapping
	orig := wj.JS_NewObject(ctx)
	NAMES :: [10]cstring{"log", "info", "warn", "error", "debug", "dir", "dirxml", "table", "assert", "trace"}
	names := NAMES
	for name in names { wj.JS_SetPropertyStr(ctx, orig, name, wj.JS_GetPropertyStr(ctx, console, name)) }
	wj.JS_SetPropertyStr(ctx, state, "_orig", wj.JS_DupValue(ctx, orig))
	defer wj.JS_FreeValue(ctx, orig)
	replacer_src: cstring = DT_COPY_REPLACER   // (NUL-terminated, as JS_Eval wants)
	replacer := wj.JS_Eval(ctx, ([^]u8)(rawptr(replacer_src)), uint(len(DT_COPY_REPLACER)), "<devtools>", wj.EVAL_TYPE_GLOBAL)
	if wj.is_exception(replacer) { wj.drop_exception(ctx); replacer = wj.UNDEFINED }
	wj.JS_SetPropertyStr(ctx, state, "_copyReplacer", replacer)

	// console[Symbol.for("wren.devtools")] = state (hidden)
	sa := dt_symbol_atom(ctx)
	wj.JS_DefinePropertyValue(ctx, console, sa, wj.JS_DupValue(ctx, state), wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
	wj.JS_FreeAtom(ctx, sa)

	// log / info / warn / error / debug / dir / dirxml wrapped (dir and dirxml at the log level), table, assert
	WRAPPED :: [7]cstring{"log", "info", "warn", "error", "debug", "dir", "dirxml"}
	wrapped := WRAPPED
	for m in wrapped {
		level: cstring = string(m) == "dir" || string(m) == "dirxml" ? "log" : m
		data := [3]wj.JSValue{state, wj.new_string(ctx, level), wj.JS_GetPropertyStr(ctx, orig, m)}
		dt_wrap(ctx, console, m, dt_console_wrapper, 0, data[:])
		free_values(ctx, data[1], data[2])
	}
	{
		data := [2]wj.JSValue{state, wj.JS_GetPropertyStr(ctx, orig, "table")}
		dt_wrap(ctx, console, "table", dt_console_table, 0, data[:])
		wj.JS_FreeValue(ctx, data[1])
	}
	{
		data := [3]wj.JSValue{state, wj.new_string(ctx, "error"), wj.JS_GetPropertyStr(ctx, orig, "assert")}
		dt_wrap(ctx, console, "assert", dt_console_wrapper, 1, data[:])
		free_values(ctx, data[1], data[2])
	}

	// the state's methods: eval, store, storeNode, copy, complete
	d1 := [1]wj.JSValue{state}
	wj.JS_SetPropertyStr(ctx, state, "eval", wj.JS_NewCFunctionData(ctx, dt_m_eval, 1, 0, 1, &d1[0]))
	wj.JS_SetPropertyStr(ctx, state, "store", wj.JS_NewCFunctionData(ctx, dt_m_store, 1, 0, 1, &d1[0]))
	wj.JS_SetPropertyStr(ctx, state, "storeNode", wj.JS_NewCFunctionData(ctx, dt_m_store_node, 1, 0, 1, &d1[0]))
	wj.JS_SetPropertyStr(ctx, state, "copy", wj.JS_NewCFunctionData(ctx, dt_m_copy, 1, 0, 1, &d1[0]))
	wj.JS_SetPropertyStr(ctx, state, "complete", wj.JS_NewCFunctionData(ctx, dt_m_complete, 1, 0, 1, &d1[0]))
}
