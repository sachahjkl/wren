// dom_popover.odin: the Popover API for JavaScript (module popover): HTMLElement's popover, showPopover / hidePopover /
// togglePopover, the popover target attributes of buttons, and ToggleEvent. Ported from native/js/runtime/dom_popover.c
// with the same behaviour and symbols. The state and the algorithms are the browser's; here are the arguments and the
// reflection.
package odin_glue

import "../odin/wj"

@(private = "file") popover_states := [4]cstring{ nil, "auto", "manual", "hint" }

@(private = "file") iface_toggle := i32(-2)
@(private = "file") iface_toggle_event :: proc "c" () -> i32 { if iface_toggle == -2 { iface_toggle = wj.iface("ToggleEvent") }; return iface_toggle }

@(private = "file")
element_of :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> u64 {
	o := wj.wj_this(ctx, this_val, iface_html_element())
	return o != nil ? o.handle : 0
}

// options.source: an HTMLElement or nothing (TypeError for anything else)
@(private = "file")
source_of :: proc "c" (ctx: ^wj.Context, opt: wj.JSValue, out: ^u64) -> bool {
	out^ = 0
	v: wj.JSValue
	if !wj.is_object(opt) { return true }
	if !wj.web_dict_get(ctx, opt, "source", &v) { return false }
	if wj.is_undefined(v) { return true }
	o := wj.wj_unwrap(v, iface_html_element())
	wj.JS_FreeValue(ctx, v)
	if o == nil { wj.wj_throw_type(ctx, "Failed to read the 'source' property: The provided value is not of type 'HTMLElement'."); return false }
	out^ = o.handle
	return true
}

@(export, link_name = "wjr_HTMLElement_get_popover")
wjr_HTMLElement_get_popover :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	h := element_of(ctx, this_val)
	if h == 0 { return wj.EXCEPTION }
	s := wr_Popover_state(h)
	return s > 0 && s < 4 ? wj.JS_NewString(ctx, popover_states[s]) : wj.NULL
}

@(export, link_name = "wjr_HTMLElement_set_popover")
wjr_HTMLElement_set_popover :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	h := element_of(ctx, this_val)
	if h == 0 { return wj.EXCEPTION }
	if wj.is_null(v) {
		st := wr_Element_removeAttribute(h, wj.raw_bytes("popover"), 7)
		return st < 0 ? wj.wj_throw_status(ctx, st, "popover") : wj.UNDEFINED
	}
	s: wj.Str
	if !wj.wj_to_str(ctx, v, &s, 0, "") { return wj.EXCEPTION }
	st := wr_Element_setAttribute(h, wj.raw_bytes("popover"), 7, wj.cstr_bytes(s.ptr), u32(s.len))
	wj.wj_str_free(ctx, &s)
	return st < 0 ? wj.wj_throw_status(ctx, st, "popover") : wj.UNDEFINED
}

@(export, link_name = "wjr_HTMLElement_showPopover")
wjr_HTMLElement_showPopover :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h := element_of(ctx, this_val)
	if h == 0 { return wj.EXCEPTION }
	opt := wj.arg(argc, argv, 0)
	source: u64
	if !wj.web_dict_check(ctx, opt, "showPopover") || !source_of(ctx, opt, &source) { return wj.EXCEPTION }
	st := wr_Popover_show(h, source)
	return st < 0 ? wj.wj_throw_status(ctx, st, "showPopover") : wj.UNDEFINED
}

@(export, link_name = "wjr_HTMLElement_hidePopover")
wjr_HTMLElement_hidePopover :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h := element_of(ctx, this_val)
	if h == 0 { return wj.EXCEPTION }
	st := wr_Popover_hide(h)
	return st < 0 ? wj.wj_throw_status(ctx, st, "hidePopover") : wj.UNDEFINED
}

// togglePopover(options): a boolean (force), or {force, source}
@(export, link_name = "wjr_HTMLElement_togglePopover")
wjr_HTMLElement_togglePopover :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h := element_of(ctx, this_val)
	if h == 0 { return wj.EXCEPTION }
	opt := wj.arg(argc, argv, 0)
	force := i32(-1)
	source := u64(0)
	if wj.is_object(opt) {
		f: wj.JSValue
		if !wj.web_dict_get(ctx, opt, "force", &f) { return wj.EXCEPTION }
		if !wj.is_undefined(f) { force = wj.JS_ToBool(ctx, f) != 0 ? 1 : 0 }
		wj.JS_FreeValue(ctx, f)
		if !source_of(ctx, opt, &source) { return wj.EXCEPTION }
	} else if !wj.is_undefined(opt) && !wj.is_null(opt) {
		force = wj.JS_ToBool(ctx, opt) != 0 ? 1 : 0
	}
	r := u8(0)
	st := wr_Popover_toggle(h, force, source, &r)
	return st < 0 ? wj.wj_throw_status(ctx, st, "togglePopover") : wj.new_bool(r != 0)
}

// ---- PopoverTargetAttributes (button, input) ----

@(private = "file")
invoker_of :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> u64 {
	o := wj.wj_this(ctx, this_val, iface_element())
	return o != nil ? o.handle : 0
}

@(export, link_name = "wjr_PopoverTargetAttributes_get_popoverTargetElement")
wjr_PopoverTargetAttributes_get_popoverTargetElement :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	h := invoker_of(ctx, this_val)
	if h == 0 { return wj.EXCEPTION }
	set := wj.web_extra_get(ctx, this_val, "popoverTargetElement")
	if wj.is_object(set) {
		// an element set explicitly stays the target while it is in the same document
		t := wj.wj_unwrap(set, iface_element())
		if t != nil && wr_Node_isConnected(t.handle) != 0 { return set }
		wj.JS_FreeValue(ctx, set)
		return wj.NULL
	}
	wj.JS_FreeValue(ctx, set)
	return wj.wj_wrap_node(ctx, wr_Popover_targetOf(h))
}

@(export, link_name = "wjr_PopoverTargetAttributes_set_popoverTargetElement")
wjr_PopoverTargetAttributes_set_popoverTargetElement :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	h := invoker_of(ctx, this_val)
	if h == 0 { return wj.EXCEPTION }
	if !wj.is_null(v) && !wj.is_undefined(v) && wj.wj_unwrap(v, iface_element()) == nil {
		return wj.wj_throw_type(ctx, "Failed to set the 'popoverTargetElement' property: The provided value is not of type 'Element'.")
	}
	if wj.is_null(v) || wj.is_undefined(v) {
		wj.web_extra_set(ctx, this_val, "popoverTargetElement", wj.UNDEFINED)
		wr_Element_removeAttribute(h, wj.raw_bytes("popovertarget"), 13)
		return wj.UNDEFINED
	}
	// reflected through the target's id when it has one (the browser activates the button through the attribute)
	t := wj.wj_unwrap(v, iface_element())
	n := wr_Element_getAttribute(t.handle, wj.raw_bytes("id"), 2, wj.wj_scratch.data, wj.wj_scratch.cap)
	if n > 0 && u32(n) > wj.wj_scratch.cap { if wj.wj_scratch_grow(u32(n)) { n = wr_Element_getAttribute(t.handle, wj.raw_bytes("id"), 2, wj.wj_scratch.data, wj.wj_scratch.cap) } }
	if n > 0 {
		id := wj.web_strndup(wj.cstr(wj.wj_scratch.data), uint(n))
		if id != nil { wr_Element_setAttribute(h, wj.raw_bytes("popovertarget"), 13, wj.cstr_bytes(id), u32(n)); wj.libc_free(rawptr(id)) }
	} else {
		wr_Element_setAttribute(h, wj.raw_bytes("popovertarget"), 13, wj.raw_bytes(""), 0)
	}
	wj.web_extra_set(ctx, this_val, "popoverTargetElement", wj.JS_DupValue(ctx, v))
	return wj.UNDEFINED
}

@(export, link_name = "wjr_PopoverTargetAttributes_get_popoverTargetAction")
wjr_PopoverTargetAttributes_get_popoverTargetAction :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	h := invoker_of(ctx, this_val)
	if h == 0 { return wj.EXCEPTION }
	n := wr_Element_getAttribute(h, wj.raw_bytes("popovertargetaction"), 19, wj.wj_scratch.data, wj.wj_scratch.cap)
	if n > 0 && u32(n) > wj.wj_scratch.cap { if wj.wj_scratch_grow(u32(n)) { n = wr_Element_getAttribute(h, wj.raw_bytes("popovertargetaction"), 19, wj.wj_scratch.data, wj.wj_scratch.cap) } }
	s := wj.cstr(wj.wj_scratch.data)
	if n == 4 && wj.web_ascii_ieq(s, 4, "show") { return wj.JS_NewString(ctx, "show") }
	if n == 4 && wj.web_ascii_ieq(s, 4, "hide") { return wj.JS_NewString(ctx, "hide") }
	return wj.JS_NewString(ctx, "toggle")   // missing and invalid value default
}

@(export, link_name = "wjr_PopoverTargetAttributes_set_popoverTargetAction")
wjr_PopoverTargetAttributes_set_popoverTargetAction :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	h := invoker_of(ctx, this_val)
	if h == 0 { return wj.EXCEPTION }
	s: wj.Str
	if !wj.wj_to_str(ctx, v, &s, 0, "") { return wj.EXCEPTION }
	st := wr_Element_setAttribute(h, wj.raw_bytes("popovertargetaction"), 19, wj.cstr_bytes(s.ptr), u32(s.len))
	wj.wj_str_free(ctx, &s)
	return st < 0 ? wj.wj_throw_status(ctx, st, "popoverTargetAction") : wj.UNDEFINED
}

// ---- ToggleEvent ----

@(private = "file")
toggle_state :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, name: cstring, old: bool) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface_toggle_event()) == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, name)
	if !wj.is_undefined(v) { return v }
	h := wj.web_event_host(this_val)
	if h == 0 { return wj.JS_NewString(ctx, "") }
	n: i32
	if old {
		n = wr_Event_text(h, wj.wj_scratch.data, wj.wj_scratch.cap)
		if n > 0 && u32(n) > wj.wj_scratch.cap { if wj.wj_scratch_grow(u32(n)) { n = wr_Event_text(h, wj.wj_scratch.data, wj.wj_scratch.cap) } }
	} else {
		n = wr_Event_data(h, wj.wj_scratch.data, wj.wj_scratch.cap)
		if n > 0 && u32(n) > wj.wj_scratch.cap { if wj.wj_scratch_grow(u32(n)) { n = wr_Event_data(h, wj.wj_scratch.data, wj.wj_scratch.cap) } }
	}
	return n > 0 ? wj.JS_NewStringLen(ctx, wj.wj_scratch.data, uint(n)) : wj.JS_NewString(ctx, "")
}

@(export, link_name = "wjr_ToggleEvent_get_oldState")
wjr_ToggleEvent_get_oldState :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return toggle_state(ctx, this_val, "oldState", true) }
@(export, link_name = "wjr_ToggleEvent_get_newState")
wjr_ToggleEvent_get_newState :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return toggle_state(ctx, this_val, "newState", false) }

@(export, link_name = "wjr_ToggleEvent_get_source")
wjr_ToggleEvent_get_source :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface_toggle_event()) == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, "source")
	if !wj.is_undefined(v) { return v }
	h := wj.web_event_host(this_val)
	return h != 0 ? wj.wj_wrap_node(ctx, wr_Event_object(h)) : wj.NULL
}

@(export, link_name = "wjr_ToggleEvent_constructor")
wjr_ToggleEvent_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	ev := wj.wj_event_construct(ctx, new_target, argc, argv, iface_toggle_event(), "ToggleEvent")
	if wj.is_exception(ev) { return ev }
	init := wj.arg(argc, argv, 1)
	names := [2]cstring{ "oldState", "newState" }
	for i in 0..<2 {
		v: wj.JSValue
		if !wj.web_dict_get(ctx, init, names[i], &v) { wj.JS_FreeValue(ctx, ev); return wj.EXCEPTION }
		s := wj.is_undefined(v) ? wj.JS_NewString(ctx, "") : wj.JS_ToString(ctx, v)
		wj.JS_FreeValue(ctx, v)
		if wj.is_exception(s) { wj.JS_FreeValue(ctx, ev); return s }
		wj.web_extra_set(ctx, ev, names[i], s)
	}
	src: wj.JSValue
	if !wj.web_dict_get(ctx, init, "source", &src) { wj.JS_FreeValue(ctx, ev); return wj.EXCEPTION }
	if !wj.is_undefined(src) && !wj.is_null(src) && wj.wj_unwrap(src, iface_element()) == nil {
		wj.JS_FreeValue(ctx, src)
		wj.JS_FreeValue(ctx, ev)
		return wj.wj_throw_type(ctx, "Failed to construct 'ToggleEvent': source is not of type 'Element'.")
	}
	wj.web_extra_set(ctx, ev, "source", wj.is_undefined(src) ? wj.NULL : src)
	return ev
}
