// dom_forms.odin: members of form controls the generated glue cannot convert: setSelectionRange and the selection
// setters (a direction given as a string), form.elements and select.options (live collections). Ported from
// native/js/runtime/dom_forms.c with the same behaviour and symbols. The controls' state is the forms model's
// (src/page/bindings_forms.odin).
package odin_glue

import "../odin/wj"

@(private = "file") iface_input := i32(-2)
@(private = "file") iface_textarea := i32(-2)
@(private = "file") iface_form := i32(-2)
@(private = "file") iface_select := i32(-2)
@(private = "file") iface_datalist := i32(-2)
@(private = "file") iface_form_controls := i32(-2)
@(private = "file") iface_options_coll := i32(-2)
@(private = "file") iface_collection := i32(-2)
@(private = "file") i_input :: proc "c" () -> i32 { if iface_input == -2 { iface_input = wj.iface("HTMLInputElement") }; return iface_input }
@(private = "file") i_textarea :: proc "c" () -> i32 { if iface_textarea == -2 { iface_textarea = wj.iface("HTMLTextAreaElement") }; return iface_textarea }
@(private = "file") i_form :: proc "c" () -> i32 { if iface_form == -2 { iface_form = wj.iface("HTMLFormElement") }; return iface_form }
@(private = "file") i_select :: proc "c" () -> i32 { if iface_select == -2 { iface_select = wj.iface("HTMLSelectElement") }; return iface_select }
@(private = "file") i_datalist :: proc "c" () -> i32 { if iface_datalist == -2 { iface_datalist = wj.iface("HTMLDataListElement") }; return iface_datalist }
@(private = "file") i_form_controls :: proc "c" () -> i32 { if iface_form_controls == -2 { iface_form_controls = wj.iface("HTMLFormControlsCollection") }; return iface_form_controls }
@(private = "file") i_options :: proc "c" () -> i32 { if iface_options_coll == -2 { iface_options_coll = wj.iface("HTMLOptionsCollection") }; return iface_options_coll }
@(private = "file") i_collection :: proc "c" () -> i32 { if iface_collection == -2 { iface_collection = wj.iface("HTMLCollection") }; return iface_collection }

INT32_MAX :: i32(0x7fff_ffff)

@(private = "file")
direction_of :: proc "c" (ctx: ^wj.Context, v: wj.JSValue) -> i32 {
	if wj.is_undefined(v) { return 0 }
	s := wj.JS_ToCString(ctx, v)
	if s == nil { return -1 }
	d := wj.str_eq(s, "forward") ? i32(1) : wj.str_eq(s, "backward") ? i32(2) : i32(0)
	wj.JS_FreeCString(ctx, s)
	return d
}

@(private = "file")
is_input :: proc "c" (o: ^wj.Obj) -> bool { return i32(o.iface) == i_input() }

@(private = "file")
set_range :: proc "c" (ctx: ^wj.Context, o: ^wj.Obj, start: i32, end: i32, dir: i32) -> wj.JSValue {
	st := is_input(o) ? wj.wr_HTMLInputElement_setSelectionRange(o.handle, start, end, dir) : wj.wr_HTMLTextAreaElement_setSelectionRange(o.handle, start, end, dir)
	return st < 0 ? wj.wj_throw_status(ctx, st, "setSelectionRange") : wj.UNDEFINED
}

@(private = "file")
clamp_i32 :: proc "c" (x: u32) -> i32 { return i32(x > u32(INT32_MAX) ? u32(INT32_MAX) : x) }

@(private = "file")
selection_range :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, iface: i32) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, iface)
	if o == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "setSelectionRange", 2, argc) }
	start, end: u32
	if !wj.wj_to_uint32(ctx, argv[0], &start, 32, 0) || !wj.wj_to_uint32(ctx, argv[1], &end, 32, 0) { return wj.EXCEPTION }
	dir := direction_of(ctx, wj.arg(argc, argv, 2))
	if dir < 0 { return wj.EXCEPTION }
	return set_range(ctx, o, clamp_i32(start), clamp_i32(end), dir)
}

@(export, link_name = "wjr_HTMLInputElement_setSelectionRange")
wjr_HTMLInputElement_setSelectionRange :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return selection_range(ctx, t, argc, argv, i_input()) }
@(export, link_name = "wjr_HTMLTextAreaElement_setSelectionRange")
wjr_HTMLTextAreaElement_setSelectionRange :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return selection_range(ctx, t, argc, argv, i_textarea()) }

@(private = "file")
selection_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue, iface: i32, which: i32) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, iface)
	if o == nil { return wj.EXCEPTION }
	start := is_input(o) ? wj.wr_HTMLInputElement_selectionStart(o.handle) : wj.wr_HTMLTextAreaElement_selectionStart(o.handle)
	end := is_input(o) ? wj.wr_HTMLInputElement_selectionEnd(o.handle) : wj.wr_HTMLTextAreaElement_selectionEnd(o.handle)
	if start < 0 || end < 0 { return wj.wj_throw_dom(ctx, "InvalidStateError", "The control has no selection.") }
	if which == 2 {
		dir := direction_of(ctx, v)
		if dir < 0 { return wj.EXCEPTION }
		return set_range(ctx, o, start, end, dir)
	}
	x := u32(0)
	if !wj.is_null(v) && !wj.wj_to_uint32(ctx, v, &x, 32, 0) { return wj.EXCEPTION }
	xi := clamp_i32(x)
	if which == 0 { return set_range(ctx, o, xi, end < xi ? xi : end, 0) }
	return set_range(ctx, o, start, xi, 0)
}

@(export, link_name = "wjr_HTMLInputElement_set_selectionStart")
wjr_HTMLInputElement_set_selectionStart :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return selection_set(ctx, t, v, i_input(), 0) }
@(export, link_name = "wjr_HTMLInputElement_set_selectionEnd")
wjr_HTMLInputElement_set_selectionEnd :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return selection_set(ctx, t, v, i_input(), 1) }
@(export, link_name = "wjr_HTMLInputElement_set_selectionDirection")
wjr_HTMLInputElement_set_selectionDirection :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return selection_set(ctx, t, v, i_input(), 2) }
@(export, link_name = "wjr_HTMLTextAreaElement_set_selectionStart")
wjr_HTMLTextAreaElement_set_selectionStart :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return selection_set(ctx, t, v, i_textarea(), 0) }
@(export, link_name = "wjr_HTMLTextAreaElement_set_selectionEnd")
wjr_HTMLTextAreaElement_set_selectionEnd :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return selection_set(ctx, t, v, i_textarea(), 1) }
@(export, link_name = "wjr_HTMLTextAreaElement_set_selectionDirection")
wjr_HTMLTextAreaElement_set_selectionDirection :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return selection_set(ctx, t, v, i_textarea(), 2) }

// ---- a form's indexed and named properties ----

@(export, link_name = "wjr_HTMLFormElement_length_hook")
wjr_HTMLFormElement_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 {
	o := wj.obj_of(obj)
	if o == nil || o.handle == 0 { return 0 }
	n := wj.wr_HTMLFormElement_length(o.handle)
	return n > 0 ? u32(n) : 0
}

@(export, link_name = "wjr_HTMLFormElement_index_get")
wjr_HTMLFormElement_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue {
	o := wj.obj_of(obj)
	found^ = false
	if o == nil || o.handle == 0 || index > u32(INT32_MAX) { return wj.UNDEFINED }
	h := wj.wr_HTMLFormElement_elements(o.handle, i32(index))
	if h == 0 { return wj.UNDEFINED }
	found^ = true
	return wj.wj_wrap_node(ctx, h)
}

@(export, link_name = "wjr_HTMLFormElement_named_get")
wjr_HTMLFormElement_named_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, name: [^]u8, length: uint, found: ^bool) -> wj.JSValue {
	found^ = false
	o := wj.obj_of(obj)
	if o == nil || o.handle == 0 { return wj.UNDEFINED }
	h := wj.wr_HTMLFormElement_namedControl(o.handle, name, u32(length))
	if h == 0 { return wj.UNDEFINED }
	found^ = true
	return wj.wj_wrap_node(ctx, h)
}

// ---- live collections ----

@(export, link_name = "wjr_HTMLFormElement_get_elements")
wjr_HTMLFormElement_get_elements :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, i_form())
	if o == nil { return wj.EXCEPTION }
	return wj.dom_live_list(ctx, this_val, o.handle, 17, wj.raw_bytes(""), 0, i_form_controls())
}

@(export, link_name = "wjr_HTMLSelectElement_get_options")
wjr_HTMLSelectElement_get_options :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, i_select())
	if o == nil { return wj.EXCEPTION }
	return wj.dom_live_list(ctx, this_val, o.handle, 13, wj.raw_bytes(""), 0, i_options())
}

@(export, link_name = "wjr_HTMLDataListElement_get_options")
wjr_HTMLDataListElement_get_options :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, i_datalist())
	if o == nil { return wj.EXCEPTION }
	return wj.dom_live_list(ctx, this_val, o.handle, 13, wj.raw_bytes(""), 0, i_collection())
}

@(export, link_name = "wjr_HTMLFormControlsCollection_namedItem")
wjr_HTMLFormControlsCollection_namedItem :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	r := wj.JS_GetPropertyStr(ctx, wj.wj_the_realm.protos[i_collection()], "namedItem")
	x := wj.JS_Call(ctx, r, this_val, argc, argv)
	wj.JS_FreeValue(ctx, r)
	return x
}

// options.add / remove / length on the select the collection belongs to
@(private = "file")
options_of :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^wj.Dom_Impl { return wj.dom_impl_of(ctx, this_val, i_options()) }

@(export, link_name = "wjr_HTMLOptionsCollection_get_length")
wjr_HTMLOptionsCollection_get_length :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	d := options_of(ctx, this_val)
	return d != nil ? wj.new_uint32(ctx, wj.wr_Collection_length(d.coll)) : wj.EXCEPTION
}

@(export, link_name = "wjr_HTMLOptionsCollection_set_length")
wjr_HTMLOptionsCollection_set_length :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	d := options_of(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	n: u32
	if !wj.wj_to_uint32(ctx, v, &n, 32, 0) { return wj.EXCEPTION }
	if n > 100000 { return wj.UNDEFINED }   // HTML: larger lengths are ignored
	for cur := wj.wr_Collection_length(d.coll); cur > n; cur -= 1 { wj.wr_ChildNode_remove(wj.wr_Collection_item(d.coll, cur - 1)) }
	for cur := wj.wr_Collection_length(d.coll); cur < n; cur += 1 {
		opt := u64(0)
		if wj.wr_Document_createElementChecked(wj.raw_bytes("option"), 6, &opt) < 0 { break }
		wj.wr_Node_preInsert(d.node, opt, 0)
	}
	return wj.UNDEFINED
}

@(export, link_name = "wjr_HTMLOptionsCollection_add")
wjr_HTMLOptionsCollection_add :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := options_of(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "HTMLOptionsCollection.add", 1, argc) }
	el: u64
	if !wj.dom_node_arg(ctx, argv[0], &el, false, "add") { return wj.EXCEPTION }
	before := u64(0)
	b := wj.arg(argc, argv, 1)
	if wj.is_number(b) {
		i := i32(0)
		wj.JS_ToInt32(ctx, &i, b)
		before = i >= 0 ? wj.wr_Collection_item(d.coll, u32(i)) : 0
	} else if !wj.dom_node_arg(ctx, b, &before, true, "add") {
		return wj.EXCEPTION
	}
	parent := before != 0 ? wj.wr_Node_parentNode(before) : d.node
	st := wj.wr_Node_preInsert(parent, el, before)
	return st < 0 ? wj.wj_throw_status(ctx, st, "HTMLOptionsCollection.add") : wj.UNDEFINED
}

@(export, link_name = "wjr_HTMLOptionsCollection_remove")
wjr_HTMLOptionsCollection_remove :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := options_of(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	i := i32(0)
	if argc > 0 && wj.JS_ToInt32(ctx, &i, argv[0]) < 0 { return wj.EXCEPTION }
	opt := i >= 0 ? wj.wr_Collection_item(d.coll, u32(i)) : 0
	if opt != 0 { wj.wr_ChildNode_remove(opt) }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_HTMLSelectElement_remove")
wjr_HTMLSelectElement_remove :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, i_select())
	if o == nil { return wj.EXCEPTION }
	if argc == 0 { wj.wr_ChildNode_remove(o.handle); return wj.UNDEFINED }
	opts := wj.JS_GetPropertyStr(ctx, this_val, "options")
	if wj.is_exception(opts) { return opts }
	r := wjr_HTMLOptionsCollection_remove(ctx, opts, argc, argv)
	wj.JS_FreeValue(ctx, opts)
	return r
}

@(export, link_name = "wjr_HTMLSelectElement_add")
wjr_HTMLSelectElement_add :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, i_select()) == nil { return wj.EXCEPTION }
	opts := wj.JS_GetPropertyStr(ctx, this_val, "options")
	if wj.is_exception(opts) { return opts }
	r := wjr_HTMLOptionsCollection_add(ctx, opts, argc, argv)
	wj.JS_FreeValue(ctx, opts)
	return r
}

@(export, link_name = "wjr_HTMLOptionsCollection_get_selectedIndex")
wjr_HTMLOptionsCollection_get_selectedIndex :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	d := options_of(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	sel := wj.wj_wrap_node(ctx, d.node)
	r := wj.JS_GetPropertyStr(ctx, sel, "selectedIndex")
	wj.JS_FreeValue(ctx, sel)
	return r
}

@(export, link_name = "wjr_HTMLOptionsCollection_set_selectedIndex")
wjr_HTMLOptionsCollection_set_selectedIndex :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	d := options_of(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	sel := wj.wj_wrap_node(ctx, d.node)
	r := wj.JS_SetPropertyStr(ctx, sel, "selectedIndex", wj.JS_DupValue(ctx, v))
	wj.JS_FreeValue(ctx, sel)
	return r < 0 ? wj.EXCEPTION : wj.UNDEFINED
}
