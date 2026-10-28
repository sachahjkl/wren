// web_clipboard.odin: navigator.clipboard (Clipboard API) and ClipboardItem, native. writeText / readText are browser
// functions (module navigator: Clipboard_writeText, Clipboard_readText, bound by the generated glue); read / write and
// ClipboardItem are built here on top of them. Only text/plain goes through the system clipboard: an item with another
// type is accepted, but write() keeps text/plain and rejects when there is none (NotAllowedError, as for a type the
// browser cannot put on the clipboard), and read() gives one item with the clipboard's text.
//
// ClipboardItem keeps its data on a non-enumerable own property `_s`: a plain object { map, types, style } where `map`
// is the engine's Map (type -> a Promise). Ported from native/js/runtime/web_clipboard.c: same symbols and behaviour;
// the browser calls are declared in native/js/odin_abi/api_decl/clipboard.odin and made through jsb.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") iface_clipboard := i32(-2)
@(private = "file") iface_navigator := i32(-2)

@(private = "file")
clipboard_iface :: proc "contextless" () -> i32 {
	if iface_clipboard == -2 { iface_clipboard = wj.iface("Clipboard") }
	return iface_clipboard
}
@(private = "file")
navigator_iface :: proc "contextless" () -> i32 {
	if iface_navigator == -2 { iface_navigator = wj.iface("Navigator") }
	return iface_navigator
}

@(private = "file")
global_prop :: proc "contextless" (ctx: ^wj.Context, name: cstring) -> wj.JSValue { return wj.JS_GetPropertyStr(ctx, wj.realm_global(), name) }

// What a ClipboardItem's presentationStyle may be.
@(private = "file")
Presentation_Style :: enum { Unspecified, Inline, Attachment }
@(private = "file")
presentation_styles := [Presentation_Style]string{ .Unspecified = "unspecified", .Inline = "inline", .Attachment = "attachment" }

// The ClipboardItem constructor, kept to recognise a ClipboardItem in write() and to make one in read().
@(private = "file") clipboarditem_ctor: wj.JSValue

// ---- ClipboardItem ----

// ClipboardItem(items, options)
@(private = "file")
ci_ctor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Please use the 'new' operator, this object constructor cannot be called as a function.") }
	if argc < 1 { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'ClipboardItem': 1 argument required, but only 0 present.") }
	items := argv[0]
	if wj.is_null(items) || !wj.is_object(items) {
		return wj.JS_ThrowTypeError(ctx, "Failed to construct 'ClipboardItem': The provided value is not of type 'record<DOMString, ClipboardItemData>'.")
	}
	// Object.keys(items)
	objc := global_prop(ctx, "Object")
	keysfn := wj.JS_GetPropertyStr(ctx, objc, "keys")
	keys := wj.JS_Call(ctx, keysfn, objc, 1, &items)
	wj.JS_FreeValue(ctx, keysfn)
	wj.JS_FreeValue(ctx, objc)
	if wj.is_exception(keys) { return keys }
	defer wj.JS_FreeValue(ctx, keys)
	nkeys: u32
	klen := wj.JS_GetPropertyStr(ctx, keys, "length")
	wj.JS_ToUint32(ctx, &nkeys, klen)
	wj.JS_FreeValue(ctx, klen)
	if nkeys == 0 { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'ClipboardItem': At least one entry must be provided") }

	style := Presentation_Style.Unspecified
	options := wj.arg(argc, argv, 1)
	if !wj.is_nullish(options) {
		if !wj.is_object(options) { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'ClipboardItem': The provided value is not of type 'ClipboardItemOptions'.") }
		ps := wj.JS_GetPropertyStr(ctx, options, "presentationStyle")
		defer wj.JS_FreeValue(ctx, ps)
		if !wj.is_undefined(ps) {
			s := wj.to_cstring(ctx, ps)
			defer if s != nil { wj.free_cstring(ctx, s) }
			found := false
			for name, st in presentation_styles {
				if s != nil && string(s) == name { style = st; found = true; break }
			}
			if !found {
				return wj.JS_ThrowTypeError(ctx, "Failed to construct 'ClipboardItem': The provided value '%s' is not a valid enum value of type PresentationStyle.", s != nil ? s : cstring(""))
			}
		}
	}

	// map = new Map(); for (k of keys) map.set(String(k), Promise.resolve(items[k])); types: the string keys, frozen
	mapc := global_prop(ctx, "Map")
	m := wj.JS_CallConstructor(ctx, mapc, 0, nil)
	wj.JS_FreeValue(ctx, mapc)
	mapset := wj.JS_GetPropertyStr(ctx, m, "set")
	promisec := global_prop(ctx, "Promise")
	resolve := wj.JS_GetPropertyStr(ctx, promisec, "resolve")
	types := wj.JS_NewArray(ctx)
	for i in 0 ..< nkeys {
		kv := wj.JS_GetPropertyUint32(ctx, keys, i)
		ks := wj.JS_ToString(ctx, kv)
		wj.JS_FreeValue(ctx, kv)
		ka := wj.JS_ValueToAtom(ctx, ks)
		val := wj.JS_GetProperty(ctx, items, ka)
		wj.JS_FreeAtom(ctx, ka)
		p := wj.JS_Call(ctx, resolve, promisec, 1, &val)
		wj.JS_FreeValue(ctx, val)
		setargs := [2]wj.JSValue{ ks, p }
		wj.JS_FreeValue(ctx, wj.JS_Call(ctx, mapset, m, 2, &setargs[0]))
		wj.JS_FreeValue(ctx, p)
		wj.JS_SetPropertyUint32(ctx, types, i, wj.JS_DupValue(ctx, ks))
		wj.JS_FreeValue(ctx, ks)
	}
	wj.JS_FreeValue(ctx, resolve)
	wj.JS_FreeValue(ctx, promisec)
	wj.JS_FreeValue(ctx, mapset)
	wj.web_freeze(ctx, types)

	// the object from new.target's prototype
	proto := wj.JS_GetPropertyStr(ctx, new_target, "prototype")
	obj := wj.is_object(proto) ? wj.JS_NewObjectProto(ctx, proto) : wj.JS_NewObject(ctx)
	wj.JS_FreeValue(ctx, proto)
	s := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, s, "map", m)
	wj.JS_SetPropertyStr(ctx, s, "types", types)
	wj.JS_SetPropertyStr(ctx, s, "style", wj.new_string_len(ctx, presentation_styles[style]))
	wj.JS_DefinePropertyValueStr(ctx, obj, "_s", s, wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
	return obj
}

// A member of the `_s` state of a ClipboardItem; a TypeError ("Illegal invocation") on the wrong receiver.
@(private = "file")
ci_member :: proc "contextless" (ctx: ^wj.Context, item: wj.JSValue, name: cstring) -> wj.JSValue {
	s := wj.JS_GetPropertyStr(ctx, item, "_s")
	if !wj.is_object(s) { wj.JS_FreeValue(ctx, s); return wj.JS_ThrowTypeError(ctx, "Illegal invocation") }
	v := wj.JS_GetPropertyStr(ctx, s, name)
	wj.JS_FreeValue(ctx, s)
	return v
}

@(private = "file")
ci_get_presentation_style :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return ci_member(ctx, this_val, "style") }
@(private = "file")
ci_get_types :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return ci_member(ctx, this_val, "types") }

// getType(type): p.then(v => typeof v === "string" ? new Blob([v], {type}) : v). The reaction carries [type].
@(private = "file")
ci_get_type_then :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	v := wj.arg(argc, argv, 0)
	if !wj.is_string(v) { return wj.JS_DupValue(ctx, v) }
	sn, tn: uint
	sv := wj.to_cstring_len(ctx, &sn, v)
	type := wj.to_cstring_len(ctx, &tn, data[0])
	blob := web_blob_new(ctx, wj.cstr_bytes(sv), sv != nil ? sn : 0, type != nil ? type : "", type != nil ? tn : 0)
	if sv != nil { wj.free_cstring(ctx, sv) }
	if type != nil { wj.free_cstring(ctx, type) }
	return blob
}

@(private = "file")
ci_get_type :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := wj.JS_GetPropertyStr(ctx, this_val, "_s")
	if !wj.is_object(s) { wj.JS_FreeValue(ctx, s); return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "Illegal invocation")) }
	type := wj.JS_ToString(ctx, wj.arg(argc, argv, 0))
	m := wj.JS_GetPropertyStr(ctx, s, "map")
	get := wj.JS_GetPropertyStr(ctx, m, "get")
	p := wj.JS_Call(ctx, get, m, 1, &type)
	wj.JS_FreeValue(ctx, get)
	wj.JS_FreeValue(ctx, m)
	wj.JS_FreeValue(ctx, s)
	if wj.is_undefined(p) {
		wj.JS_FreeValue(ctx, type)
		return wj.web_promise_rejected(ctx, wj.web_dom_exception(ctx, "NotFoundError", "Failed to execute 'getType' on 'ClipboardItem': The type was not found"))
	}
	r := wj.web_then(ctx, p, rawptr(ci_get_type_then), nil, 1, &type)
	wj.JS_FreeValue(ctx, p)
	wj.JS_FreeValue(ctx, type)
	return r
}

// ClipboardItem.supports(type): text/plain only (ASCII case-insensitive)
@(private = "file")
ci_supports :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	n: uint
	s := wj.to_cstring_len(ctx, &n, wj.arg(argc, argv, 0))
	ok := s != nil && wj.web_ascii_ieq(wj.cstr_bytes(s), uint(len(string(s))), "text/plain")
	if s != nil { wj.free_cstring(ctx, s) }
	return wj.new_bool(ok)
}

// A ClipboardItem of this realm: our prototype, with an `_s`.
@(private = "file")
is_clipboard_item :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> bool {
	if !wj.is_object(v) { return false }
	proto := wj.JS_GetPropertyStr(ctx, clipboarditem_ctor, "prototype")
	vproto := wj.JS_GetPrototype(ctx, v)
	same := wj.same_ptr(proto, vproto)
	wj.JS_FreeValue(ctx, proto)
	wj.JS_FreeValue(ctx, vproto)
	if !same { return false }
	s := wj.JS_GetPropertyStr(ctx, v, "_s")
	ok := wj.is_object(s)
	wj.JS_FreeValue(ctx, s)
	return ok
}

// ---- navigator.clipboard ----

@(private = "file")
make_clipboard :: proc "c" (ctx: ^wj.Context) -> wj.JSValue { return wj.wj_new_object(ctx, clipboard_iface(), nil, nil) }

@(export, link_name = "wjr_Navigator_get_clipboard")
wjr_Navigator_get_clipboard :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, navigator_iface()) == nil { return wj.EXCEPTION }
	return wj.web_singleton(ctx, wj.SINGLE_CLIPBOARD, make_clipboard)
}

// read(): readText().then(text => text === "" ? [] : [new ClipboardItem({"text/plain": new Blob([text], {type})})])
@(private = "file")
read_then :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	text := wj.to_cstring(ctx, wj.arg(argc, argv, 0))
	tlen := text != nil ? len(string(text)) : 0
	arr := wj.JS_NewArray(ctx)
	if tlen > 0 {
		blob := web_blob_new(ctx, wj.cstr_bytes(text), uint(tlen), "text/plain", 10)
		items := wj.JS_NewObject(ctx)
		wj.JS_SetPropertyStr(ctx, items, "text/plain", blob)
		item := ci_ctor(ctx, clipboarditem_ctor, 1, &items)
		wj.JS_FreeValue(ctx, items)
		wj.JS_SetPropertyUint32(ctx, arr, 0, item)
	}
	if text != nil { wj.free_cstring(ctx, text) }
	return arr
}

@(export, link_name = "wjr_Clipboard_read")
wjr_Clipboard_read :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, this_val, clipboard_iface()) == nil { return wj.web_promise_reject_pending(ctx) }
	h: abi.Handle
	jsb.host(&h, api_decl.Clipboard_readText, wj.wr_Clipboard_readText)
	p := wj.wj_promise_from_host(ctx, u64(h), wj.HOST_TEXT, nil, wj.UNDEFINED)
	r := wj.web_then(ctx, p, rawptr(read_then), nil, 0, nil)
	wj.JS_FreeValue(ctx, p)
	return r
}

// write(): the second stage, text in hand -> writeText(text).
@(private = "file")
write_text_then :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	text := wj.to_cstring(ctx, wj.arg(argc, argv, 0))
	h: abi.Handle
	jsb.host(&h, api_decl.Clipboard_writeText, wj.wr_Clipboard_writeText, text != nil ? string(text) : "")
	if text != nil { wj.free_cstring(ctx, text) }
	return wj.wj_promise_from_host(ctx, u64(h), wj.HOST_UNDEFINED, nil, wj.UNDEFINED)
}

// write(): the first stage, a text/plain promise's value -> its text (typeof v === "string" ? v : v.text()).
@(private = "file")
write_value_then :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	v := wj.arg(argc, argv, 0)
	if wj.is_string(v) { return wj.JS_DupValue(ctx, v) }
	textfn := wj.JS_GetPropertyStr(ctx, v, "text")
	r := wj.JS_Call(ctx, textfn, v, 0, nil)
	wj.JS_FreeValue(ctx, textfn)
	return r
}

// The items of write()'s iterable, each a ClipboardItem.
@(private = "file")
Write_Collect :: struct { list: wj.JSValue, n: u32 }

@(private = "file")
write_collect_one :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	w := (^Write_Collect)(opaque)
	if !is_clipboard_item(ctx, item) {
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'write' on 'Clipboard': Failed to read the 'ClipboardItem' sequence: Failed to convert element to 'ClipboardItem'.")
		return false
	}
	wj.JS_SetPropertyUint32(ctx, w.list, w.n, wj.JS_DupValue(ctx, item))
	w.n += 1
	return true
}

@(export, link_name = "wjr_Clipboard_write")
wjr_Clipboard_write :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, clipboard_iface()) == nil { return wj.web_promise_reject_pending(ctx) }
	if argc < 1 {
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'write' on 'Clipboard': 1 argument required, but only 0 present.")
		return wj.web_promise_reject_pending(ctx)
	}
	items := argv[0]
	it := wj.is_object(items) ? wj.web_is_iterable(ctx, items) : 0
	if it < 0 { return wj.web_promise_reject_pending(ctx) }
	if it == 0 { return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "Failed to execute 'write' on 'Clipboard': The provided value cannot be converted to a sequence.")) }
	w := Write_Collect{ wj.JS_NewArray(ctx), 0 }
	if !wj.web_for_of(ctx, items, write_collect_one, &w) {
		wj.JS_FreeValue(ctx, w.list)
		return wj.web_promise_reject_pending(ctx)
	}
	if w.n != 1 {
		msg: cstring = w.n == 0 ? "Failed to execute 'write' on 'Clipboard': There is no item to write." : "Failed to execute 'write' on 'Clipboard': Support for multiple ClipboardItems is not implemented."
		e := wj.web_dom_exception(ctx, "NotAllowedError", msg)
		wj.JS_FreeValue(ctx, w.list)
		return wj.web_promise_rejected(ctx, e)
	}
	item0 := wj.JS_GetPropertyUint32(ctx, w.list, 0)
	wj.JS_FreeValue(ctx, w.list)
	s := wj.JS_GetPropertyStr(ctx, item0, "_s")
	m := wj.JS_GetPropertyStr(ctx, s, "map")
	get := wj.JS_GetPropertyStr(ctx, m, "get")
	plainkey := wj.new_string(ctx, "text/plain")
	plain := wj.JS_Call(ctx, get, m, 1, &plainkey)
	wj.JS_FreeValue(ctx, plainkey)
	wj.JS_FreeValue(ctx, get)
	if wj.is_undefined(plain) {
		// the error names the first type: Array.from(st.map.keys())[0]
		keysfn := wj.JS_GetPropertyStr(ctx, m, "keys")
		keysit := wj.JS_Call(ctx, keysfn, m, 0, nil)
		wj.JS_FreeValue(ctx, keysfn)
		arrayc := global_prop(ctx, "Array")
		from := wj.JS_GetPropertyStr(ctx, arrayc, "from")
		keysarr := wj.JS_Call(ctx, from, arrayc, 1, &keysit)
		wj.JS_FreeValue(ctx, from)
		wj.JS_FreeValue(ctx, arrayc)
		wj.JS_FreeValue(ctx, keysit)
		first := wj.JS_GetPropertyUint32(ctx, keysarr, 0)
		t := wj.to_cstring(ctx, first)
		msg: [160]u8
		wj.snprintf(&msg[0], len(msg), "Failed to execute 'write' on 'Clipboard': Type %s does not match the blob's type or is not supported.", t != nil ? t : cstring(""))
		if t != nil { wj.free_cstring(ctx, t) }
		wj.JS_FreeValue(ctx, first)
		wj.JS_FreeValue(ctx, keysarr)
		wj.JS_FreeValue(ctx, m)
		wj.JS_FreeValue(ctx, s)
		wj.JS_FreeValue(ctx, item0)
		return wj.web_promise_rejected(ctx, wj.web_dom_exception(ctx, "NotAllowedError", cstring(&msg[0])))
	}
	wj.JS_FreeValue(ctx, m)
	wj.JS_FreeValue(ctx, s)
	wj.JS_FreeValue(ctx, item0)
	stage1 := wj.web_then(ctx, plain, rawptr(write_value_then), nil, 0, nil)
	wj.JS_FreeValue(ctx, plain)
	if wj.is_exception(stage1) { return wj.web_promise_reject_pending(ctx) }
	r := wj.web_then(ctx, stage1, rawptr(write_text_then), nil, 0, nil)
	wj.JS_FreeValue(ctx, stage1)
	return r
}

// ---- the native class, installed at pre-initialization ----

@(export, link_name = "web_clipboard_preinit")
web_clipboard_preinit :: proc "c" (ctx: ^wj.Context) -> i32 {
	proto := wj.JS_NewObject(ctx)
	define_getter :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, name: cstring, getter_name: cstring, fn: wj.Getter) {
		a := wj.JS_NewAtom(ctx, name)
		g := wj.JS_NewCFunction2(ctx, wj.Native(rawptr(fn)), getter_name, 0, wj.CFUNC_getter, 0)
		wj.JS_DefinePropertyGetSet(ctx, obj, a, g, wj.UNDEFINED, wj.PROP_CONFIGURABLE)
		wj.JS_FreeAtom(ctx, a)
	}
	define_getter(ctx, proto, "presentationStyle", "get presentationStyle", ci_get_presentation_style)
	define_getter(ctx, proto, "types", "get types", ci_get_types)
	wj.JS_DefinePropertyValueStr(ctx, proto, "getType", wj.new_cfunction(ctx, ci_get_type, "getType", 1), wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
	// Symbol.toStringTag = "ClipboardItem"
	sym := global_prop(ctx, "Symbol")
	tts := wj.JS_GetPropertyStr(ctx, sym, "toStringTag")
	ta := wj.JS_ValueToAtom(ctx, tts)
	wj.JS_DefinePropertyValue(ctx, proto, ta, wj.new_string(ctx, "ClipboardItem"), wj.PROP_CONFIGURABLE)
	wj.JS_FreeAtom(ctx, ta)
	wj.JS_FreeValue(ctx, tts)
	wj.JS_FreeValue(ctx, sym)

	ctor := wj.JS_NewCFunction2(ctx, ci_ctor, "ClipboardItem", 1, wj.CFUNC_constructor, 0)
	wj.JS_SetConstructor(ctx, ctor, proto)
	wj.JS_DefinePropertyValueStr(ctx, ctor, "prototype", wj.JS_DupValue(ctx, proto), 0)
	wj.JS_DefinePropertyValueStr(ctx, ctor, "supports", wj.new_cfunction(ctx, ci_supports, "supports", 1), wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
	wj.JS_FreeValue(ctx, proto)

	clipboarditem_ctor = wj.JS_DupValue(ctx, ctor)
	wj.JS_DefinePropertyValueStr(ctx, wj.realm_global(), "ClipboardItem", ctor, wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
	return 0
}

// ClipboardItem is made at pre-initialization (the shared image): a worker's realm, or a document that is not a secure
// context (SecureContext, Exposed=Window), does not have it.
@(export, link_name = "web_clipboard_start")
web_clipboard_start :: proc "c" (ctx: ^wj.Context, kind: i32) -> i32 {
	context = jsb.glue_context()
	secure: bool
	if wj.is_window() { jsb.host(&secure, api_decl.Window_isSecureContext, wj.wr_Window_isSecureContext) }
	if secure { return 0 }
	a := wj.JS_NewAtom(ctx, "ClipboardItem")
	wj.JS_DeleteProperty(ctx, wj.realm_global(), a, 0)
	wj.JS_FreeAtom(ctx, a)
	return 0
}
