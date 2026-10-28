// custom_elements.odin: custom elements (HTML §4.13), native. Ported from native/js/runtime/custom_elements.c with the
// same behaviour and symbols (wjr_* the generated table references, wj_install_custom_elements at pre-initialization,
// wj_ce_process the browser calls to run the queued reactions). The registry, definitions, upgrades and reactions are
// kept as engine objects (Map / WeakMap / Set) so object identity and the Map/Set/constructor semantics match the old
// JavaScript exactly. Each definition `def` is a plain object { name, ctor, the four callbacks, observed, noShadow,
// noInternals }.
package odin_glue

import "../odin/wj"

CE_UPGRADE :: 1
CE_CONNECTED :: 2
CE_DISCONNECTED :: 3
CE_ATTRIBUTE :: 4
CE_STATE_CUSTOM :: 1
CE_STATE_FAILED :: 2

// the registry's state (counted JSValues, made at pre-initialization)
@(private = "file") ce_by_name: wj.JSValue   // Map name -> def
@(private = "file") ce_by_ctor: wj.JSValue   // Map ctor -> def
@(private = "file") ce_pending: wj.JSValue   // Map name -> { promise, resolve }
@(private = "file") ce_defs: wj.JSValue      // WeakMap element -> def
@(private = "file") ce_stack: wj.JSValue     // Array of { def, element }
@(private = "file") ce_name_re: wj.JSValue   // the PotentialCustomElementName RegExp
@(private = "file") ce_reserved: wj.JSValue  // Set of reserved names
@(private = "file") ce_running: bool
@(private = "file") ce_ready: bool

@(private = "file") registry: wj.JSValue
@(private = "file") registry_made: bool

@(private = "file") iface_registry := i32(-2)
@(private = "file") i_registry :: proc "c" () -> i32 { if iface_registry == -2 { iface_registry = wj.iface("CustomElementRegistry") }; return iface_registry }

@(private = "file")
global_prop :: proc "c" (ctx: ^wj.Context, name: cstring) -> wj.JSValue { return wj.JS_GetPropertyStr(ctx, wj.wj_the_realm.global, name) }

// ---- Map / Set / WeakMap over the engine's own objects ----

@(private = "file")
map_get :: proc "c" (ctx: ^wj.Context, m: wj.JSValue, key: wj.JSValue) -> wj.JSValue {
	f := wj.JS_GetPropertyStr(ctx, m, "get")
	k := key
	r := wj.JS_Call(ctx, f, m, 1, &k)
	wj.JS_FreeValue(ctx, f)
	return r
}
@(private = "file")
map_has :: proc "c" (ctx: ^wj.Context, m: wj.JSValue, key: wj.JSValue) -> bool {
	f := wj.JS_GetPropertyStr(ctx, m, "has")
	k := key
	r := wj.JS_Call(ctx, f, m, 1, &k)
	has := wj.JS_ToBool(ctx, r) != 0
	wj.JS_FreeValue(ctx, r); wj.JS_FreeValue(ctx, f)
	return has
}
@(private = "file")
map_set :: proc "c" (ctx: ^wj.Context, m: wj.JSValue, key: wj.JSValue, value: wj.JSValue) {
	f := wj.JS_GetPropertyStr(ctx, m, "set")
	args := [2]wj.JSValue{ key, value }
	r := wj.JS_Call(ctx, f, m, 2, &args[0])
	wj.JS_FreeValue(ctx, r); wj.JS_FreeValue(ctx, f)
}
@(private = "file")
map_delete :: proc "c" (ctx: ^wj.Context, m: wj.JSValue, key: wj.JSValue) {
	f := wj.JS_GetPropertyStr(ctx, m, "delete")
	k := key
	r := wj.JS_Call(ctx, f, m, 1, &k)
	wj.JS_FreeValue(ctx, r); wj.JS_FreeValue(ctx, f)
}
@(private = "file")
set_add :: proc "c" (ctx: ^wj.Context, s: wj.JSValue, value: wj.JSValue) {
	f := wj.JS_GetPropertyStr(ctx, s, "add")
	v := value
	r := wj.JS_Call(ctx, f, s, 1, &v)
	wj.JS_FreeValue(ctx, r); wj.JS_FreeValue(ctx, f)
}
@(private = "file")
set_has :: proc "c" (ctx: ^wj.Context, s: wj.JSValue, value: wj.JSValue) -> bool {
	f := wj.JS_GetPropertyStr(ctx, s, "has")
	v := value
	r := wj.JS_Call(ctx, f, s, 1, &v)
	has := wj.JS_ToBool(ctx, r) != 0
	wj.JS_FreeValue(ctx, r); wj.JS_FreeValue(ctx, f)
	return has
}
@(private = "file")
set_has_str :: proc "c" (ctx: ^wj.Context, s: wj.JSValue, str: cstring) -> bool {
	v := wj.JS_NewString(ctx, str)
	has := set_has(ctx, s, v)
	wj.JS_FreeValue(ctx, v)
	return has
}

// ---- the browser's half ----

@(private = "file")
rd_u64 :: proc "c" (p: [^]u8) -> u64 { v := u64(0); for i := 7; i >= 0; i -= 1 { v = v << 8 | u64(p[i]) }; return v }
@(private = "file")
rd_u32 :: proc "c" (p: [^]u8) -> u32 { return u32(p[0]) | u32(p[1]) << 8 | u32(p[2]) << 16 | u32(p[3]) << 24 }

@(private = "file")
ce_create :: proc "c" (ctx: ^wj.Context, name: [^]u8, length: uint) -> wj.JSValue {
	h := u64(0)
	st := wj.wr_CustomElements_create(name, u32(length), &h)
	if st < 0 { return wj.wj_throw_status(ctx, st, "HTMLElement") }
	return wj.wj_wrap_node(ctx, h)
}
@(private = "file")
ce_set_state :: proc "c" (ctx: ^wj.Context, el: wj.JSValue, state: i32) {
	o := wj.obj_of(el)
	if o == nil || o.kind != wj.KIND_NODE { return }
	wj.wr_Element_setCustomState(o.handle, u32(state))
}
@(private = "file")
ce_browser_define :: proc "c" (name: [^]u8, length: uint) { wj.wr_CustomElements_define(name, u32(length)) }
@(private = "file")
ce_browser_disable :: proc "c" (name: [^]u8, length: uint, shadow: bool, internals: bool) { wj.wr_CustomElements_disable(name, u32(length), shadow ? 1 : 0, internals ? 1 : 0) }

@(private = "file")
packed_elements :: proc "c" (ctx: ^wj.Context, n: i32) -> wj.JSValue {
	arr := wj.JS_NewArray(ctx)
	if n <= 0 { return arr }
	count := u32(n) / 8
	hs := ([^]u64)(wj.libc_malloc(uint(count) * size_of(u64)))
	if hs == nil { return arr }
	for i in u32(0)..<count { hs[i] = rd_u64(wj.wj_scratch.data[8 * i:]) }
	for i in u32(0)..<count { wj.array_set(ctx, arr, i, wj.wj_wrap_node(ctx, hs[i])) }
	wj.libc_free(hs)
	return arr
}
@(private = "file")
ce_by_name_elements :: proc "c" (ctx: ^wj.Context, name: [^]u8, length: uint) -> wj.JSValue {
	n := wj.wr_Document_shadowIncludingByName(name, u32(length), wj.wj_scratch.data, wj.wj_scratch.cap)
	if n > 0 && u32(n) > wj.wj_scratch.cap { if wj.wj_scratch_grow(u32(n)) { n = wj.wr_Document_shadowIncludingByName(name, u32(length), wj.wj_scratch.data, wj.wj_scratch.cap) } }
	return packed_elements(ctx, n)
}
@(private = "file")
ce_descendants :: proc "c" (ctx: ^wj.Context, root: wj.JSValue) -> wj.JSValue {
	o := wj.wj_unwrap(root, iface_node())
	if o == nil || o.handle == 0 { return wj.JS_NewArray(ctx) }
	n := wj.wr_Node_shadowIncludingElements(o.handle, wj.wj_scratch.data, wj.wj_scratch.cap)
	if n > 0 && u32(n) > wj.wj_scratch.cap { if wj.wj_scratch_grow(u32(n)) { n = wj.wr_Node_shadowIncludingElements(o.handle, wj.wj_scratch.data, wj.wj_scratch.cap) } }
	return packed_elements(ctx, n)
}

@(private = "file")
ce_take_records :: proc "c" (ctx: ^wj.Context) -> wj.JSValue {
	need := wj.wr_CustomElements_pending()
	out := wj.JS_NewArray(ctx)
	if need == 0 { return out }
	if wj.wj_scratch.cap < need && !wj.wj_scratch_grow(need) { wj.JS_FreeValue(ctx, out); return wj.JS_ThrowOutOfMemory(ctx) }
	n := wj.wr_CustomElements_take(wj.wj_scratch.data, wj.wj_scratch.cap)
	if n <= 0 || u32(n) > wj.wj_scratch.cap { return out }
	b := ([^]u8)(wj.libc_malloc(uint(n)))
	if b == nil { wj.JS_FreeValue(ctx, out); return wj.JS_ThrowOutOfMemory(ctx) }
	wj.memcpy(b, wj.wj_scratch.data, uint(n))
	handles := ([^]u64)(wj.libc_malloc((uint(n) / 9 + 1) * size_of(u64)))
	nh := u32(0); k := u32(0)
	i := uint(0)
	for handles != nil && i + 9 <= uint(n) {
		kind := b[i]
		h := rd_u64(b[i + 1:])
		i += 9
		handles[nh] = h; nh += 1
		rec := wj.JS_NewArray(ctx)
		wj.array_set(ctx, rec, 0, wj.new_int32(i32(kind)))
		wj.array_set(ctx, rec, 1, wj.wj_wrap_node(ctx, h))
		if kind == 4 {
			s: [3][^]u8
			l := [3]u32{ 0, 0, 0 }
			for f in 0..<3 {
				if i + 4 > uint(n) { break }
				length := rd_u32(b[i:])
				if uint(length) > uint(n) - i - 4 { i = uint(n); break }
				l[f] = length
				s[f] = b[i + 4:]
				i += 4 + uint(length)
			}
			flags := i < uint(n) ? b[i] : 0
			i += 1
			wj.array_set(ctx, rec, 2, wj.JS_NewStringLen(ctx, s[0] != nil ? s[0] : wj.raw_bytes(""), uint(l[0])))
			wj.array_set(ctx, rec, 3, (flags & 1) != 0 ? wj.JS_NewStringLen(ctx, s[1], uint(l[1])) : wj.NULL)
			wj.array_set(ctx, rec, 4, (flags & 2) != 0 ? wj.JS_NewStringLen(ctx, s[2], uint(l[2])) : wj.NULL)
		}
		wj.array_set(ctx, out, k, rec); k += 1
	}
	if handles != nil { wj.wr_CustomElements_release(handles, nh) }
	wj.libc_free(handles)
	wj.libc_free(b)
	return out
}
@(private = "file")
ce_take :: proc "c" (ctx: ^wj.Context) -> wj.JSValue {
	rt := wj.JS_GetRuntime(ctx)
	threshold := wj.JS_GetGCThreshold(rt)
	wj.JS_SetGCThreshold(rt, ~uint(0))
	out := ce_take_records(ctx)
	wj.JS_SetGCThreshold(rt, threshold)
	return out
}

// ---- DOM accessors read on first use ----

@(private = "file") dom_is_connected: wj.JSValue
@(private = "file") dom_local_name: wj.JSValue
@(private = "file") dom_attributes: wj.JSValue
@(private = "file") dom_read: bool

@(private = "file")
own_getter :: proc "c" (ctx: ^wj.Context, proto: wj.JSValue, name: cstring) -> wj.JSValue {
	objc := global_prop(ctx, "Object")
	gopd := wj.JS_GetPropertyStr(ctx, objc, "getOwnPropertyDescriptor")
	args := [2]wj.JSValue{ proto, wj.JS_NewString(ctx, name) }
	desc := wj.JS_Call(ctx, gopd, objc, 2, &args[0])
	wj.JS_FreeValue(ctx, args[1]); wj.JS_FreeValue(ctx, gopd); wj.JS_FreeValue(ctx, objc)
	get := wj.JS_GetPropertyStr(ctx, desc, "get")
	wj.JS_FreeValue(ctx, desc)
	return get
}
@(private = "file")
dom_read_once :: proc "c" (ctx: ^wj.Context) {
	if dom_read { return }
	dom_read = true
	node := global_prop(ctx, "Node")
	node_proto := wj.JS_GetPropertyStr(ctx, node, "prototype")
	dom_is_connected = own_getter(ctx, node_proto, "isConnected")
	wj.JS_FreeValue(ctx, node_proto); wj.JS_FreeValue(ctx, node)
	el := global_prop(ctx, "Element")
	el_proto := wj.JS_GetPropertyStr(ctx, el, "prototype")
	dom_local_name = own_getter(ctx, el_proto, "localName")
	dom_attributes = own_getter(ctx, el_proto, "attributes")
	wj.JS_FreeValue(ctx, el_proto); wj.JS_FreeValue(ctx, el)
}
@(private = "file")
dom_is_connected_of :: proc "c" (ctx: ^wj.Context, el: wj.JSValue) -> bool {
	dom_read_once(ctx)
	r := wj.JS_Call(ctx, dom_is_connected, el, 0, nil)
	c := wj.JS_ToBool(ctx, r) != 0
	wj.JS_FreeValue(ctx, r)
	return c
}
@(private = "file")
dom_local_name_of :: proc "c" (ctx: ^wj.Context, el: wj.JSValue) -> wj.JSValue { dom_read_once(ctx); return wj.JS_Call(ctx, dom_local_name, el, 0, nil) }
@(private = "file")
dom_attributes_of :: proc "c" (ctx: ^wj.Context, el: wj.JSValue) -> wj.JSValue { dom_read_once(ctx); return wj.JS_Call(ctx, dom_attributes, el, 0, nil) }

// ---- name validity ----

@(private = "file")
valid_name_v :: proc "c" (ctx: ^wj.Context, nv: wj.JSValue) -> bool {
	test := wj.JS_GetPropertyStr(ctx, ce_name_re, "test")
	n := nv
	r := wj.JS_Call(ctx, test, ce_name_re, 1, &n)
	ok := wj.JS_ToBool(ctx, r) != 0
	wj.JS_FreeValue(ctx, r); wj.JS_FreeValue(ctx, test)
	reserved := set_has(ctx, ce_reserved, nv)
	return ok && !reserved
}
@(private = "file")
valid_name :: proc "c" (ctx: ^wj.Context, name: cstring) -> bool {
	nv := wj.JS_NewString(ctx, name)
	ok := valid_name_v(ctx, nv)
	wj.JS_FreeValue(ctx, nv)
	return ok
}

// ---- definitions, upgrades, reactions ----

@(private = "file")
read_callback :: proc "c" (ctx: ^wj.Context, proto: wj.JSValue, name: cstring, out: ^wj.JSValue) -> bool {
	f := wj.JS_GetPropertyStr(ctx, proto, name)
	if wj.is_exception(f) { return false }
	if !wj.is_undefined(f) && !wj.JS_IsFunction(ctx, f) {
		wj.JS_FreeValue(ctx, f)
		wj.wj_throw_type(ctx, "Failed to execute 'define' on 'CustomElementRegistry': The '%s' property is not a function.", name)
		return false
	}
	out^ = f
	return true
}

@(private = "file")
react :: proc "c" (ctx: ^wj.Context, def: wj.JSValue, el: wj.JSValue, name: cstring, argc: i32, argv: [^]wj.JSValue) {
	f := wj.JS_GetPropertyStr(ctx, def, name)
	if wj.is_undefined(f) { wj.JS_FreeValue(ctx, f); return }
	r := wj.JS_Call(ctx, f, el, argc, argv)
	if wj.is_exception(r) { wj.wj_report_exception(ctx, wj.JS_GetException(ctx)) }
	else { wj.JS_FreeValue(ctx, r) }
	wj.JS_FreeValue(ctx, f)
}

@(private = "file")
seq_item_to_set :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	set := (^wj.JSValue)(opaque)^
	s := wj.JS_ToString(ctx, item)
	if wj.is_exception(s) { return false }
	set_add(ctx, set, s)
	wj.JS_FreeValue(ctx, s)
	return true
}
@(private = "file")
to_string_sequence :: proc "c" (ctx: ^wj.Context, value: wj.JSValue, set: wj.JSValue) -> bool {
	s := set
	return wj.web_for_of(ctx, value, seq_item_to_set, &s)
}

// HTML "upgrade an element"
@(private = "file")
upgrade :: proc "c" (ctx: ^wj.Context, def: wj.JSValue, el: wj.JSValue) {
	if map_has(ctx, ce_defs, el) { return }
	map_set(ctx, ce_defs, el, def)
	ce_set_state(ctx, el, CE_STATE_FAILED)
	frame := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, frame, "def", wj.JS_DupValue(ctx, def))
	wj.JS_SetPropertyStr(ctx, frame, "element", wj.JS_DupValue(ctx, el))
	length := i64(0); wj.JS_GetLength(ctx, ce_stack, &length)
	wj.JS_SetPropertyInt64(ctx, ce_stack, length, frame)
	ctor := wj.JS_GetPropertyStr(ctx, def, "ctor")
	r := wj.JS_CallConstructor(ctx, ctor, 0, nil)
	wj.JS_FreeValue(ctx, ctor)
	failed := false
	if wj.is_exception(r) {
		wj.wj_report_exception(ctx, wj.JS_GetException(ctx))
		failed = true
	} else if !wj.same_ptr(r, el) {
		wj.JS_FreeValue(ctx, r)
		wj.wj_report_exception(ctx, wj.web_type_error(ctx, "Failed to construct a custom element: the constructor did not return the element being upgraded."))
		failed = true
	} else {
		wj.JS_FreeValue(ctx, r)
	}
	slen := i64(0); wj.JS_GetLength(ctx, ce_stack, &slen)
	if slen > 0 { popped := wj.JS_GetPropertyInt64(ctx, ce_stack, slen - 1); wj.JS_FreeValue(ctx, popped); wj.JS_SetPropertyInt64(ctx, ce_stack, slen - 1, wj.UNDEFINED); wj.JS_SetPropertyStr(ctx, ce_stack, "length", wj.JS_NewInt64(ctx, slen - 1)) }
	if failed { return }
	ce_set_state(ctx, el, CE_STATE_CUSTOM)
	acc := wj.JS_GetPropertyStr(ctx, def, "attributeChangedCallback")
	has_attr_cb := !wj.is_undefined(acc)
	wj.JS_FreeValue(ctx, acc)
	if has_attr_cb {
		observed := wj.JS_GetPropertyStr(ctx, def, "observed")
		attrs := dom_attributes_of(ctx, el)
		arrayc := global_prop(ctx, "Array")
		from := wj.JS_GetPropertyStr(ctx, arrayc, "from")
		a0 := attrs
		list := wj.JS_Call(ctx, from, arrayc, 1, &a0)
		wj.JS_FreeValue(ctx, from); wj.JS_FreeValue(ctx, arrayc); wj.JS_FreeValue(ctx, attrs)
		an := i64(0); wj.JS_GetLength(ctx, list, &an)
		for i in 0..<an {
			a := wj.JS_GetPropertyInt64(ctx, list, i)
			aname := wj.JS_GetPropertyStr(ctx, a, "name")
			if set_has(ctx, observed, aname) {
				avalue := wj.JS_GetPropertyStr(ctx, a, "value")
				ans := wj.JS_GetPropertyStr(ctx, a, "namespaceURI")
				args := [4]wj.JSValue{ aname, wj.NULL, avalue, ans }
				react(ctx, def, el, "attributeChangedCallback", 4, &args[0])
				wj.JS_FreeValue(ctx, avalue); wj.JS_FreeValue(ctx, ans)
			}
			wj.JS_FreeValue(ctx, aname); wj.JS_FreeValue(ctx, a)
		}
		wj.JS_FreeValue(ctx, list); wj.JS_FreeValue(ctx, observed)
	}
	if dom_is_connected_of(ctx, el) { react(ctx, def, el, "connectedCallback", 0, nil) }
}

@(private = "file")
try_upgrade :: proc "c" (ctx: ^wj.Context, el: wj.JSValue) {
	if map_has(ctx, ce_defs, el) { return }
	ln := dom_local_name_of(ctx, el)
	def := map_get(ctx, ce_by_name, ln)
	wj.JS_FreeValue(ctx, ln)
	if !wj.is_undefined(def) { upgrade(ctx, def, el) }
	wj.JS_FreeValue(ctx, def)
}

@(private = "file")
ce_define :: proc "c" (ctx: ^wj.Context, namev: wj.JSValue, ctor: wj.JSValue, options: wj.JSValue) -> wj.JSValue {
	name_str := wj.JS_ToString(ctx, namev)
	if wj.is_exception(name_str) { return wj.EXCEPTION }
	name_len := uint(0)
	name := wj.JS_ToCStringLen(ctx, &name_len, name_str)
	namebuf := wj.cstr(wj.web_strndup(wj.cstr_bytes(name), name != nil ? name_len : 0))
	if name != nil { wj.JS_FreeCString(ctx, name) }

	if !wj.JS_IsConstructor(ctx, ctor) { wj.JS_FreeValue(ctx, name_str); wj.libc_free(rawptr(namebuf)); return wj.wj_throw_type(ctx, "Failed to execute 'define' on 'CustomElementRegistry': The provided value is not of type 'CustomElementConstructor'.") }
	msg: [128]u8
	if !valid_name_v(ctx, name_str) {
		wj.snprintf(&msg[0], len(msg), "Failed to execute 'define' on 'CustomElementRegistry': \"%s\" is not a valid custom element name", namebuf)
		wj.JS_FreeValue(ctx, name_str); wj.libc_free(rawptr(namebuf))
		return wj.JS_Throw(ctx, wj.web_dom_exception(ctx, "SyntaxError", wj.cstr(&msg[0])))
	}
	name_key := name_str   // the exact string value: keys byName / byCtor / pending without NUL truncation
	if map_has(ctx, ce_by_name, name_key) {
		wj.snprintf(&msg[0], len(msg), "Failed to execute 'define' on 'CustomElementRegistry': the name \"%s\" has already been used with this registry", namebuf)
		wj.JS_FreeValue(ctx, name_key); wj.libc_free(rawptr(namebuf))
		return wj.JS_Throw(ctx, wj.web_dom_exception(ctx, "NotSupportedError", wj.cstr(&msg[0])))
	}
	if map_has(ctx, ce_by_ctor, ctor) { wj.JS_FreeValue(ctx, name_key); wj.libc_free(rawptr(namebuf)); return wj.JS_Throw(ctx, wj.web_dom_exception(ctx, "NotSupportedError", "Failed to execute 'define' on 'CustomElementRegistry': this constructor has already been used with this registry")) }
	if !wj.is_undefined(options) && !wj.is_null(options) {
		ext := wj.JS_GetPropertyStr(ctx, options, "extends")
		if !wj.is_undefined(ext) {
			es := wj.JS_ToCString(ctx, ext)
			ext_valid := es != nil && valid_name(ctx, es)
			if es != nil { wj.JS_FreeCString(ctx, es) }
			wj.JS_FreeValue(ctx, ext); wj.JS_FreeValue(ctx, name_key); wj.libc_free(rawptr(namebuf))
			if ext_valid { return wj.JS_Throw(ctx, wj.web_dom_exception(ctx, "NotSupportedError", "Failed to execute 'define' on 'CustomElementRegistry': 'extends' names a custom element")) }
			return wj.JS_Throw(ctx, wj.web_dom_exception(ctx, "NotSupportedError", "Failed to execute 'define' on 'CustomElementRegistry': customized built-in elements ('extends') are not supported"))
		}
		wj.JS_FreeValue(ctx, ext)
	}
	if ce_running { wj.JS_FreeValue(ctx, name_key); wj.libc_free(rawptr(namebuf)); return wj.JS_Throw(ctx, wj.web_dom_exception(ctx, "NotSupportedError", "Failed to execute 'define' on 'CustomElementRegistry': a definition is running")) }

	ce_running = true
	def := wj.UNDEFINED
	ok := true
	proto := wj.JS_GetPropertyStr(ctx, ctor, "prototype")
	if wj.is_exception(proto) {
		ok = false
	} else if !wj.is_object(proto) && !wj.JS_IsFunction(ctx, proto) {
		wj.wj_throw_type(ctx, "Failed to execute 'define' on 'CustomElementRegistry': The 'prototype' property of the constructor is not an object.")
		ok = false
	}
	if ok {
		def = wj.JS_NewObject(ctx)
		wj.JS_SetPropertyStr(ctx, def, "name", wj.JS_NewString(ctx, namebuf))
		wj.JS_SetPropertyStr(ctx, def, "ctor", wj.JS_DupValue(ctx, ctor))
		cb: wj.JSValue
		names := [4]cstring{ "connectedCallback", "disconnectedCallback", "adoptedCallback", "attributeChangedCallback" }
		for i in 0..<4 {
			if !ok { break }
			if !read_callback(ctx, proto, names[i], &cb) { ok = false; break }
			wj.JS_SetPropertyStr(ctx, def, names[i], cb)
		}
		if ok {
			setc := global_prop(ctx, "Set")
			observed := wj.JS_CallConstructor(ctx, setc, 0, nil)
			wj.JS_FreeValue(ctx, setc)
			acc := wj.JS_GetPropertyStr(ctx, def, "attributeChangedCallback")
			if !wj.is_undefined(acc) {
				list := wj.JS_GetPropertyStr(ctx, ctor, "observedAttributes")
				if wj.is_exception(list) { wj.JS_FreeValue(ctx, observed); ok = false }
				else {
					if !wj.is_undefined(list) && !to_string_sequence(ctx, list, observed) { ok = false }
					wj.JS_FreeValue(ctx, list)
					if !ok { wj.JS_FreeValue(ctx, observed) }
				}
			}
			wj.JS_FreeValue(ctx, acc)
			if ok {
				wj.JS_SetPropertyStr(ctx, def, "observed", observed)
				noShadow := false; noInternals := false
				disabled := wj.JS_GetPropertyStr(ctx, ctor, "disabledFeatures")
				if wj.is_exception(disabled) { ok = false }
				else if !wj.is_undefined(disabled) {
					setc2 := global_prop(ctx, "Set")
					features := wj.JS_CallConstructor(ctx, setc2, 0, nil)
					wj.JS_FreeValue(ctx, setc2)
					if !to_string_sequence(ctx, disabled, features) { ok = false }
					else { noShadow = set_has_str(ctx, features, "shadow"); noInternals = set_has_str(ctx, features, "internals") }
					wj.JS_FreeValue(ctx, features)
				}
				if !wj.is_exception(disabled) { wj.JS_FreeValue(ctx, disabled) }
				if ok {
					wj.JS_SetPropertyStr(ctx, def, "noShadow", wj.new_bool(noShadow))
					wj.JS_SetPropertyStr(ctx, def, "noInternals", wj.new_bool(noInternals))
					fa := wj.JS_GetPropertyStr(ctx, ctor, "formAssociated")
					if wj.is_exception(fa) { ok = false }
					else { wj.JS_FreeValue(ctx, fa) }
				}
			}
		}
	}
	wj.JS_FreeValue(ctx, proto)
	ce_running = false
	if !ok { wj.JS_FreeValue(ctx, def); wj.JS_FreeValue(ctx, name_key); wj.libc_free(rawptr(namebuf)); return wj.EXCEPTION }

	map_set(ctx, ce_by_name, name_key, def)
	map_set(ctx, ce_by_ctor, ctor, def)
	nsv := wj.JS_GetPropertyStr(ctx, def, "noShadow")
	niv := wj.JS_GetPropertyStr(ctx, def, "noInternals")
	noShadow := wj.JS_ToBool(ctx, nsv) != 0
	noInternals := wj.JS_ToBool(ctx, niv) != 0
	wj.JS_FreeValue(ctx, nsv); wj.JS_FreeValue(ctx, niv)
	nblen := wj.strlen(namebuf)
	if noShadow || noInternals { ce_browser_disable(wj.cstr_bytes(namebuf), nblen, noShadow, noInternals) }
	ce_browser_define(wj.cstr_bytes(namebuf), nblen)
	list := ce_by_name_elements(ctx, wj.cstr_bytes(namebuf), nblen)
	ln := i64(0); wj.JS_GetLength(ctx, list, &ln)
	for i in 0..<ln { el := wj.JS_GetPropertyInt64(ctx, list, i); try_upgrade(ctx, el); wj.JS_FreeValue(ctx, el) }
	wj.JS_FreeValue(ctx, list)
	p := map_get(ctx, ce_pending, name_key)
	if !wj.is_undefined(p) {
		map_delete(ctx, ce_pending, name_key)
		resolve := wj.JS_GetPropertyStr(ctx, p, "resolve")
		c := ctor
		r := wj.JS_Call(ctx, resolve, wj.UNDEFINED, 1, &c)
		wj.JS_FreeValue(ctx, r); wj.JS_FreeValue(ctx, resolve)
	}
	wj.JS_FreeValue(ctx, p)
	wj.JS_FreeValue(ctx, name_key)
	wj.libc_free(rawptr(namebuf))
	return wj.UNDEFINED
}


// [HTMLConstructor]
@(private = "file")
ce_construct :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue) -> wj.JSValue {
	def := map_get(ctx, ce_by_ctor, new_target)
	if wj.is_undefined(def) { wj.JS_FreeValue(ctx, def); return wj.wj_throw_type(ctx, "Illegal constructor") }
	proto := wj.JS_GetPropertyStr(ctx, new_target, "prototype")
	slen := i64(0); wj.JS_GetLength(ctx, ce_stack, &slen)
	from_stack := false
	if slen > 0 {
		top := wj.JS_GetPropertyInt64(ctx, ce_stack, slen - 1)
		topdef := wj.JS_GetPropertyStr(ctx, top, "def")
		from_stack = wj.same_ptr(topdef, def)
		wj.JS_FreeValue(ctx, topdef); wj.JS_FreeValue(ctx, top)
	}
	if !from_stack {
		namev := wj.JS_GetPropertyStr(ctx, def, "name")
		name := wj.JS_ToCString(ctx, namev)
		el := ce_create(ctx, name != nil ? wj.cstr_bytes(name) : wj.raw_bytes(""), name != nil ? wj.strlen(name) : 0)
		if name != nil { wj.JS_FreeCString(ctx, name) }
		wj.JS_FreeValue(ctx, namev)
		if wj.is_exception(el) { wj.JS_FreeValue(ctx, proto); wj.JS_FreeValue(ctx, def); return el }
		target_proto: wj.JSValue
		if wj.is_object(proto) && !wj.is_null(proto) { target_proto = wj.JS_DupValue(ctx, proto) }
		else { hec := global_prop(ctx, "HTMLElement"); target_proto = wj.JS_GetPropertyStr(ctx, hec, "prototype"); wj.JS_FreeValue(ctx, hec) }
		wj.JS_SetPrototype(ctx, el, target_proto)
		wj.JS_FreeValue(ctx, target_proto)
		map_set(ctx, ce_defs, el, def)
		wj.JS_FreeValue(ctx, proto); wj.JS_FreeValue(ctx, def)
		return el
	}
	top := wj.JS_GetPropertyInt64(ctx, ce_stack, slen - 1)
	el := wj.JS_GetPropertyStr(ctx, top, "element")
	if wj.is_null(el) {
		wj.JS_FreeValue(ctx, el); wj.JS_FreeValue(ctx, top); wj.JS_FreeValue(ctx, proto); wj.JS_FreeValue(ctx, def)
		return wj.JS_Throw(ctx, wj.web_dom_exception(ctx, "InvalidStateError", "Failed to construct 'HTMLElement': the element is already constructed"))
	}
	wj.JS_SetPrototype(ctx, el, proto)
	wj.JS_SetPropertyStr(ctx, top, "element", wj.NULL)
	wj.JS_FreeValue(ctx, top); wj.JS_FreeValue(ctx, proto); wj.JS_FreeValue(ctx, def)
	return el
}

@(private = "file")
ce_process :: proc "c" (ctx: ^wj.Context) {
	for {
		list := ce_take(ctx)
		if wj.is_exception(list) { wj.wj_report_pending(ctx); return }
		n := i64(0); wj.JS_GetLength(ctx, list, &n)
		if n == 0 { wj.JS_FreeValue(ctx, list); return }
		for i in 0..<n {
			r := wj.JS_GetPropertyInt64(ctx, list, i)
			el := wj.JS_GetPropertyInt64(ctx, r, 1)
			if wj.is_null(el) { wj.JS_FreeValue(ctx, el); wj.JS_FreeValue(ctx, r); continue }
			kindv := wj.JS_GetPropertyInt64(ctx, r, 0)
			kind := i32(0); wj.JS_ToInt32(ctx, &kind, kindv); wj.JS_FreeValue(ctx, kindv)
			if kind == CE_UPGRADE { try_upgrade(ctx, el) }
			else if kind == CE_CONNECTED { d := map_get(ctx, ce_defs, el); if !wj.is_undefined(d) { react(ctx, d, el, "connectedCallback", 0, nil) }; wj.JS_FreeValue(ctx, d) }
			else if kind == CE_DISCONNECTED { d := map_get(ctx, ce_defs, el); if !wj.is_undefined(d) { react(ctx, d, el, "disconnectedCallback", 0, nil) }; wj.JS_FreeValue(ctx, d) }
			else if kind == CE_ATTRIBUTE {
				d := map_get(ctx, ce_defs, el)
				if !wj.is_undefined(d) {
					aname := wj.JS_GetPropertyInt64(ctx, r, 2)
					observed := wj.JS_GetPropertyStr(ctx, d, "observed")
					if set_has(ctx, observed, aname) {
						oldv := wj.JS_GetPropertyInt64(ctx, r, 3)
						newv := wj.JS_GetPropertyInt64(ctx, r, 4)
						args := [4]wj.JSValue{ aname, oldv, newv, wj.NULL }
						react(ctx, d, el, "attributeChangedCallback", 4, &args[0])
						wj.JS_FreeValue(ctx, oldv); wj.JS_FreeValue(ctx, newv)
					}
					wj.JS_FreeValue(ctx, observed); wj.JS_FreeValue(ctx, aname)
				}
				wj.JS_FreeValue(ctx, d)
			}
			wj.JS_FreeValue(ctx, el); wj.JS_FreeValue(ctx, r)
		}
		wj.JS_FreeValue(ctx, list)
	}
}

// ---- install the state at pre-initialization ----

@(private = "file") CE_RESERVED := [?]cstring{ "annotation-xml", "color-profile", "font-face", "font-face-src", "font-face-uri", "font-face-format", "font-face-name", "missing-glyph" }
@(private = "file") PCEN : cstring : "^[a-z][\\-.0-9_a-z\\u00B7\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u203F-\\u2040\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\u{10000}-\\u{EFFFF}]*-[\\-.0-9_a-z\\u00B7\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u203F-\\u2040\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\u{10000}-\\u{EFFFF}]*$"

@(export, link_name = "wj_install_custom_elements")
wj_install_custom_elements :: proc "c" (ctx: ^wj.Context) {
	mapc := global_prop(ctx, "Map")
	ce_by_name = wj.JS_CallConstructor(ctx, mapc, 0, nil)
	ce_by_ctor = wj.JS_CallConstructor(ctx, mapc, 0, nil)
	ce_pending = wj.JS_CallConstructor(ctx, mapc, 0, nil)
	wj.JS_FreeValue(ctx, mapc)
	wmc := global_prop(ctx, "WeakMap")
	ce_defs = wj.JS_CallConstructor(ctx, wmc, 0, nil)
	wj.JS_FreeValue(ctx, wmc)
	ce_stack = wj.JS_NewArray(ctx)
	setc := global_prop(ctx, "Set")
	ce_reserved = wj.JS_CallConstructor(ctx, setc, 0, nil)
	wj.JS_FreeValue(ctx, setc)
	for p in CE_RESERVED { set_add(ctx, ce_reserved, wj.JS_NewString(ctx, p)) }
	rec := global_prop(ctx, "RegExp")
	reargs := [2]wj.JSValue{ wj.JS_NewString(ctx, PCEN), wj.JS_NewString(ctx, "u") }
	ce_name_re = wj.JS_CallConstructor(ctx, rec, 2, &reargs[0])
	wj.JS_FreeValue(ctx, reargs[0]); wj.JS_FreeValue(ctx, reargs[1]); wj.JS_FreeValue(ctx, rec)
	ce_ready = true
}

// ---- the Web IDL members ----

@(export, link_name = "wjr_Window_get_customElements")
wjr_Window_get_customElements :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if !registry_made {
		r := wj.wj_new_object(ctx, i_registry(), nil, nil)
		if wj.is_exception(r) { return r }
		registry = r
		registry_made = true
	}
	return wj.JS_DupValue(ctx, registry)
}

@(private = "file")
registry_this :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> bool { return wj.wj_this(ctx, this_val, i_registry()) != nil }

@(export, link_name = "wjr_CustomElementRegistry_define")
wjr_CustomElementRegistry_define :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !registry_this(ctx, this_val) { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "CustomElementRegistry.define", 2, argc) }
	if !ce_ready { return wj.wj_throw_type(ctx, "custom elements are not available") }
	return ce_define(ctx, argv[0], argv[1], wj.arg(argc, argv, 2))
}

@(export, link_name = "wjr_CustomElementRegistry_get")
wjr_CustomElementRegistry_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !registry_this(ctx, this_val) { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "CustomElementRegistry.get", 1, argc) }
	if !ce_ready { return wj.UNDEFINED }
	name := wj.JS_ToString(ctx, argv[0])
	def := map_get(ctx, ce_by_name, name)
	wj.JS_FreeValue(ctx, name)
	if wj.is_undefined(def) { return def }
	ctor := wj.JS_GetPropertyStr(ctx, def, "ctor")
	wj.JS_FreeValue(ctx, def)
	return ctor
}

@(export, link_name = "wjr_CustomElementRegistry_getName")
wjr_CustomElementRegistry_getName :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !registry_this(ctx, this_val) { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "CustomElementRegistry.getName", 1, argc) }
	if !ce_ready { return wj.NULL }
	def := map_get(ctx, ce_by_ctor, argv[0])
	if wj.is_undefined(def) { wj.JS_FreeValue(ctx, def); return wj.NULL }
	name := wj.JS_GetPropertyStr(ctx, def, "name")
	wj.JS_FreeValue(ctx, def)
	return name
}

@(export, link_name = "wjr_CustomElementRegistry_whenDefined")
wjr_CustomElementRegistry_whenDefined :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !registry_this(ctx, this_val) { return wj.web_promise_reject_pending(ctx) }
	if argc < 1 { wj.wj_throw_arity(ctx, "CustomElementRegistry.whenDefined", 1, argc); return wj.web_promise_reject_pending(ctx) }
	if !ce_ready { return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "custom elements are not available")) }
	// the exact string value (as define keys it): a C string would stop at an embedded NUL ("a-\0" is not "a-")
	name_key := wj.JS_ToString(ctx, argv[0])
	if wj.is_exception(name_key) { return wj.web_promise_reject_pending(ctx) }
	if !valid_name_v(ctx, name_key) {
		wj.JS_FreeValue(ctx, name_key)
		return wj.web_promise_rejected(ctx, wj.web_dom_exception(ctx, "SyntaxError", "is not a valid custom element name"))
	}
	def := map_get(ctx, ce_by_name, name_key)
	if !wj.is_undefined(def) {
		ctor := wj.JS_GetPropertyStr(ctx, def, "ctor")
		wj.JS_FreeValue(ctx, def)
		r := wj.web_promise_resolved(ctx, ctor)
		wj.JS_FreeValue(ctx, ctor); wj.JS_FreeValue(ctx, name_key)
		return r
	}
	wj.JS_FreeValue(ctx, def)
	entry := map_get(ctx, ce_pending, name_key)
	if wj.is_undefined(entry) {
		wj.JS_FreeValue(ctx, entry)
		funcs: [2]wj.JSValue
		promise := wj.web_promise_new(ctx, raw_data(funcs[:]))
		entry = wj.JS_NewObject(ctx)
		wj.JS_SetPropertyStr(ctx, entry, "promise", wj.JS_DupValue(ctx, promise))
		wj.JS_SetPropertyStr(ctx, entry, "resolve", funcs[0])
		wj.JS_FreeValue(ctx, funcs[1])
		map_set(ctx, ce_pending, name_key, entry)
		wj.JS_FreeValue(ctx, name_key)
		return promise
	}
	wj.JS_FreeValue(ctx, name_key)
	promise := wj.JS_GetPropertyStr(ctx, entry, "promise")
	wj.JS_FreeValue(ctx, entry)
	return promise
}

@(export, link_name = "wjr_CustomElementRegistry_upgrade")
wjr_CustomElementRegistry_upgrade :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !registry_this(ctx, this_val) { return wj.EXCEPTION }
	if argc < 1 || wj.obj_of(argv[0]) == nil || wj.obj_of(argv[0]).kind != wj.KIND_NODE { return wj.wj_throw_type(ctx, "Failed to execute 'upgrade' on 'CustomElementRegistry': parameter 1 is not of type 'Node'.") }
	if !ce_ready { return wj.UNDEFINED }
	list := ce_descendants(ctx, argv[0])
	n := i64(0); wj.JS_GetLength(ctx, list, &n)
	for i in 0..<n { el := wj.JS_GetPropertyInt64(ctx, list, i); try_upgrade(ctx, el); wj.JS_FreeValue(ctx, el) }
	wj.JS_FreeValue(ctx, list)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_HTMLElement_constructor")
wjr_HTMLElement_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Failed to construct 'HTMLElement': Please use the 'new' operator, this DOM object constructor cannot be called as a function.") }
	if !ce_ready { return wj.wj_throw_type(ctx, "Illegal constructor") }
	return ce_construct(ctx, new_target)
}

// The browser runs the queued reactions (js_custom_elements.odin: custom_elements_flush)
@(export, link_name = "wj_ce_process")
wj_ce_process :: proc "c" () {
	ctx := wj.wj_the_realm.ctx
	if ctx == nil || !ce_ready { return }
	wj.wj_stack_enter(ctx)
	ce_process(ctx)
}
