// shadow.odin: shadow trees for JavaScript (DOM §4.2.2, §4.8, HTML slots and declarative shadow roots,
// ElementInternals, CSSOM constructable stylesheets). Ported from native/js/runtime/shadow.c, same symbols and
// behaviour. The trees, slots and the event path are the browser's (src/dom/shadow.odin, src/page/js_shadow.odin);
// here are the members whose arguments need converting by hand (dictionaries, variadic nodes, setlike
// CustomStateSet) and, native in place of the old prelude/shadow.js: the adoptedStyleSheets ObservableArray (a Proxy
// over a real array whose every change is given to the browser), the Window's named properties object and
// element.part.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") nothing: abi.Nothing

// ---- the generated dictionaries read here (gen/bindings.h; the layout must match the C) ----

@(private = "file")
wjd_ShadowRootInit :: struct {
	clonable:                  bool,
	customElementRegistry:     wj.JSValue,
	has_customElementRegistry: bool,
	delegatesFocus:            bool,
	mode:                      wj.Str,
	has_mode:                  bool,
	serializable:              bool,
	slotAssignment:            wj.Str,
}
@(private = "file") wjd_GetRootNodeOptions :: struct { composed: bool }
@(private = "file") wjd_GetHTMLOptions :: struct { serializableShadowRoots: bool, shadowRoots: wj.JSValue }
@(private = "file") wjd_AssignedNodesOptions :: struct { flatten: bool }
@(private = "file") wjd_CSSStyleSheetInit :: struct { baseURL: wj.Str, disabled: bool, media: wj.JSValue }

#assert(size_of(wjd_ShadowRootInit) == 48 && offset_of(wjd_ShadowRootInit, mode) == 20 && offset_of(wjd_ShadowRootInit, slotAssignment) == 36)
#assert(size_of(wjd_GetHTMLOptions) == 16 && size_of(wjd_CSSStyleSheetInit) == 24 && offset_of(wjd_CSSStyleSheetInit, media) == 16)

@(default_calling_convention = "c", private = "file")
foreign {
	wjd_ShadowRootInit_from       :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_ShadowRootInit) -> bool ---
	wjd_ShadowRootInit_free       :: proc(ctx: ^wj.Context, d: ^wjd_ShadowRootInit) ---
	wjd_GetRootNodeOptions_from   :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_GetRootNodeOptions) -> bool ---
	wjd_GetRootNodeOptions_free   :: proc(ctx: ^wj.Context, d: ^wjd_GetRootNodeOptions) ---
	wjd_GetHTMLOptions_from       :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_GetHTMLOptions) -> bool ---
	wjd_GetHTMLOptions_free       :: proc(ctx: ^wj.Context, d: ^wjd_GetHTMLOptions) ---
	wjd_AssignedNodesOptions_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_AssignedNodesOptions) -> bool ---
	wjd_AssignedNodesOptions_free :: proc(ctx: ^wj.Context, d: ^wjd_AssignedNodesOptions) ---
	wjd_CSSStyleSheetInit_from    :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_CSSStyleSheetInit) -> bool ---
	wjd_CSSStyleSheetInit_free    :: proc(ctx: ^wj.Context, d: ^wjd_CSSStyleSheetInit) ---
}

// ---- attachShadow, getRootNode ----

@(export, link_name = "wjr_Element_attachShadow")
wjr_Element_attachShadow :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, t, ifc("Element"))
	if o == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Element.attachShadow", 1, argc) }
	init: wjd_ShadowRootInit
	if !wjd_ShadowRootInit_from(ctx, argv[0], &init) { return wj.EXCEPTION }
	modes := [?]cstring{"open", "closed", nil}
	assignments := [?]cstring{"named", "manual", nil}
	mode := api_decl.ShadowRootMode(wj.wj_enum_index(&init.mode, raw_data(modes[:])))
	slot := init.slotAssignment.ptr != nil ? api_decl.SlotAssignmentMode(wj.wj_enum_index(&init.slotAssignment, raw_data(assignments[:]))) : .Named
	delegates, clonable, serializable := init.delegatesFocus, init.clonable, init.serializable
	wjd_ShadowRootInit_free(ctx, &init)
	root: api_decl.Node
	st := jsb.host6(&root, api_decl.Element_attachShadowInit, wj.wr_Element_attachShadowInit, api_decl.Element(o.handle), mode, delegates, slot, clonable, serializable)
	return node_or_throw(ctx, root, st, "Element.attachShadow")
}

@(export, link_name = "wjr_Node_getRootNode")
wjr_Node_getRootNode :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, ifc("Node"))
	if o == nil { return wj.EXCEPTION }
	if o.handle == 0 { return wj.JS_DupValue(ctx, this_val) }
	opts: wjd_GetRootNodeOptions
	if !wjd_GetRootNodeOptions_from(ctx, wj.arg(argc, argv, 0), &opts) { return wj.EXCEPTION }
	composed := opts.composed
	wjd_GetRootNodeOptions_free(ctx, &opts)
	root: api_decl.Node
	jsb.host(&root, api_decl.Node_rootNodeComposed, wj.wr_Node_rootNodeComposed, api_decl.Node(o.handle), composed)
	return wj.wj_wrap_node(ctx, u64(root))
}

// ---- markup with declarative shadow roots ----

@(private = "file")
get_html :: proc(ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, iface: i32, what: cstring) -> wj.JSValue {
	o := wj.wj_this(ctx, t, iface)
	if o == nil { return wj.EXCEPTION }
	opts: wjd_GetHTMLOptions
	if !wjd_GetHTMLOptions_from(ctx, wj.arg(argc, argv, 0), &opts) { return wj.EXCEPTION }
	defer wjd_GetHTMLOptions_free(ctx, &opts)
	// shadowRoots: a sequence of ShadowRoot
	roots: [^]u64
	n: u32
	defer wj.libc_free(roots)
	if wj.is_object(opts.shadowRoots) {
		lv := wj.JS_GetPropertyStr(ctx, opts.shadowRoots, "length")
		count: u32
		ok := wj.JS_ToUint32(ctx, &count, lv) >= 0
		wj.JS_FreeValue(ctx, lv)
		if !ok { return wj.EXCEPTION }
		if count > 0 { roots = ([^]u64)(wj.libc_malloc(uint(count) * 8)) }
		for i in 0 ..< count {
			if roots == nil { break }
			v := wj.JS_GetPropertyUint32(ctx, opts.shadowRoots, i)
			h: u64
			ok = wj.wj_to_handle(ctx, v, ifc("ShadowRoot"), false, &h, "Failed to execute 'getHTML': shadowRoots must be ShadowRoot objects.")
			wj.JS_FreeValue(ctx, v)
			if !ok { return wj.EXCEPTION }
			roots[n] = h
			n += 1
		}
	}
	s: string
	st := jsb.host(&s, api_decl.Node_getHTML, wj.wr_Node_getHTML, api_decl.Node(o.handle), opts.serializableShadowRoots, roots != nil ? roots[:n] : nil)
	return dom_str(ctx, s, st, false, what)
}

@(export, link_name = "wjr_Element_getHTML")
wjr_Element_getHTML :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return get_html(ctx, t, argc, argv, ifc("Element"), "Element.getHTML")
}
@(export, link_name = "wjr_ShadowRoot_getHTML")
wjr_ShadowRoot_getHTML :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return get_html(ctx, t, argc, argv, ifc("ShadowRoot"), "ShadowRoot.getHTML")
}

@(private = "file")
set_html_unsafe :: proc(ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, iface: i32, what: cstring) -> wj.JSValue {
	o := wj.wj_this(ctx, t, iface)
	if o == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, what, 1, argc) }
	s: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &s, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	st := jsb.host(&nothing, api_decl.Node_setHTMLUnsafe, wj.wr_Node_setHTMLUnsafe, api_decl.Node(o.handle), str_view(s))
	return st != .None ? wj.wj_throw_status(ctx, i32(st), what) : wj.UNDEFINED
}

@(export, link_name = "wjr_Element_setHTMLUnsafe")
wjr_Element_setHTMLUnsafe :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return set_html_unsafe(ctx, t, argc, argv, ifc("Element"), "Element.setHTMLUnsafe")
}
@(export, link_name = "wjr_ShadowRoot_setHTMLUnsafe")
wjr_ShadowRoot_setHTMLUnsafe :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return set_html_unsafe(ctx, t, argc, argv, ifc("ShadowRoot"), "ShadowRoot.setHTMLUnsafe")
}

@(export, link_name = "wjr_Document_static_parseHTMLUnsafe")
wjr_Document_static_parseHTMLUnsafe :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if argc < 1 { return wj.wj_throw_arity(ctx, "Document.parseHTMLUnsafe", 1, argc) }
	s: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &s, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	doc: api_decl.Document
	st := jsb.host(&doc, api_decl.Document_parseHTMLUnsafeNode, wj.wr_Document_parseHTMLUnsafeNode, str_view(s))
	return node_or_throw(ctx, doc, st, "Document.parseHTMLUnsafe")
}

// ---- slots ----

@(private = "file")
assigned :: proc(ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, elements: bool) -> wj.JSValue {
	o := wj.wj_this(ctx, t, ifc("HTMLSlotElement"))
	if o == nil { return wj.EXCEPTION }
	opts: wjd_AssignedNodesOptions
	if !wjd_AssignedNodesOptions_from(ctx, wj.arg(argc, argv, 0), &opts) { return wj.EXCEPTION }
	flatten := opts.flatten
	wjd_AssignedNodesOptions_free(ctx, &opts)
	packed: abi.Bytes
	st := jsb.host(&packed, api_decl.HTMLSlotElement_assignedPacked, wj.wr_HTMLSlotElement_assignedPacked, api_decl.Element(o.handle), flatten, elements)
	what: cstring = elements ? "HTMLSlotElement.assignedElements" : "HTMLSlotElement.assignedNodes"
	if st != .None { return wj.wj_throw_status(ctx, i32(st), what) }
	return handles_array(ctx, ([]u8)(packed), wj.wj_wrap_node)
}

@(export, link_name = "wjr_HTMLSlotElement_assignedNodes")
wjr_HTMLSlotElement_assignedNodes :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return assigned(ctx, t, argc, argv, false)
}
@(export, link_name = "wjr_HTMLSlotElement_assignedElements")
wjr_HTMLSlotElement_assignedElements :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return assigned(ctx, t, argc, argv, true)
}

@(export, link_name = "wjr_HTMLSlotElement_assign")
wjr_HTMLSlotElement_assign :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, t, ifc("HTMLSlotElement"))
	if o == nil { return wj.EXCEPTION }
	hs: [^]u64
	if argc > 0 {
		hs = ([^]u64)(wj.libc_malloc(uint(argc) * 8))
		if hs == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	}
	defer wj.libc_free(hs)
	for i in 0 ..< argc {
		x := wj.wj_unwrap(argv[i], ifc("Element"))
		if x == nil { x = wj.wj_unwrap(argv[i], ifc("Text")) }
		if x == nil || x.handle == 0 { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'assign' on 'HTMLSlotElement': The provided value is not of type '(Element or Text)'.") }
		hs[i] = x.handle
	}
	st := jsb.host(&nothing, api_decl.HTMLSlotElement_assignNodes, wj.wr_HTMLSlotElement_assignNodes, api_decl.Element(o.handle), hs != nil ? hs[:argc] : nil)
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "HTMLSlotElement.assign") : wj.UNDEFINED
}

// ---- events ----

// composedPath() of the event being dispatched (`host`; empty otherwise)
event_composed_path :: proc(ctx: ^wj.Context, host: u64) -> wj.JSValue {
	if host == 0 { return wj.JS_NewArray(ctx) }
	ev := api_decl.Event(host)
	packed: abi.Bytes
	jsb.host(&packed, api_decl.Event_composedPathPacked, wj.wr_Event_composedPathPacked, ev)
	if len(packed) > 0 { return handles_array(ctx, ([]u8)(packed), wj_wrap_target) }
	// an event dispatched at the Window or at an EventTarget that is not a node: its path is that target
	arr := wj.JS_NewArray(ctx)
	current, target: api_decl.EventTarget
	jsb.host(&current, api_decl.Event_currentTarget, wj.wr_Event_currentTarget, ev)
	if current != 0 {
		jsb.host(&target, api_decl.Event_target, wj.wr_Event_target, ev)
		wj.array_set(ctx, arr, 0, wj_wrap_target(ctx, u64(target)))
	}
	return arr
}

// elementsFromPoint(x, y) of the document or of a shadow root: the elements hit, innermost first, retargeted against
// the root; elementFromPoint: the first of them (null when there is none)
@(private = "file")
from_point :: proc(ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, iface: i32, all: bool, what: cstring) -> wj.JSValue {
	o := wj.wj_this(ctx, t, iface)
	if o == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, what, 2, argc) }
	x, y: f64
	if !wj.wj_to_double(ctx, argv[0], &x, true) || !wj.wj_to_double(ctx, argv[1], &y, true) { return wj.EXCEPTION }
	packed: abi.Bytes
	jsb.host(&packed, api_decl.DocumentOrShadowRoot_elementsFromPointPacked, wj.wr_DocumentOrShadowRoot_elementsFromPointPacked, api_decl.Node(o.handle), x, y)
	if !all { return len(packed) >= 8 ? wj.wj_wrap_node(ctx, wj.read_u64(raw_data(packed))) : wj.NULL }
	return handles_array(ctx, ([]u8)(packed), wj.wj_wrap_node)
}

@(export, link_name = "wjr_Document_elementsFromPoint")
wjr_Document_elementsFromPoint :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return from_point(ctx, t, argc, argv, ifc("Document"), true, "Document.elementsFromPoint")
}

// shadowRoot.elementFromPoint / elementsFromPoint (Shadow DOM §4.3 extensions of DocumentOrShadowRoot, in every
// engine, not in the IDL of CSSOM View): set on ShadowRoot.prototype at the start of a Window realm
@(private = "file")
shadow_element_from_point :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return from_point(ctx, t, argc, argv, ifc("ShadowRoot"), false, "ShadowRoot.elementFromPoint")
}
@(private = "file")
shadow_elements_from_point :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return from_point(ctx, t, argc, argv, ifc("ShadowRoot"), true, "ShadowRoot.elementsFromPoint")
}

@(private = "file")
install_shadow_root_extras :: proc "contextless" (ctx: ^wj.Context) {
	ctor := global_prop(ctx, "ShadowRoot")
	defer wj.JS_FreeValue(ctx, ctor)
	proto := wj.is_object(ctor) ? wj.JS_GetPropertyStr(ctx, ctor, "prototype") : wj.UNDEFINED
	defer wj.JS_FreeValue(ctx, proto)
	if !wj.is_object(proto) { return }
	flags :: wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE
	wj.JS_DefinePropertyValueStr(ctx, proto, "elementFromPoint", wj.new_cfunction(ctx, shadow_element_from_point, "elementFromPoint", 2), flags)
	wj.JS_DefinePropertyValueStr(ctx, proto, "elementsFromPoint", wj.new_cfunction(ctx, shadow_elements_from_point, "elementsFromPoint", 2), flags)
}

// slotchange: a job of the engine (queued by the browser when a slot is first signalled: wj_slot_queue), in order with
// the promise reactions and mutation observer notifications around it, which fires slotchange at the signalled slots
@(private = "file")
slot_job :: proc "c" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	jsb.host(&nothing, api_decl.Shadow_fireSlotChanges, wj.wr_Shadow_fireSlotChanges)
	return wj.UNDEFINED
}

@(export, link_name = "wj_slot_queue")
wj_slot_queue :: proc "c" () {
	wj.JS_EnqueueJob(wj.realm_ctx(), slot_job, 0, nil)
}

// ---- ElementInternals, CustomStateSet ----

@(private = "file") Internals :: struct { states: wj.JSValue }
@(private = "file") States :: struct { internals: api_decl.ElementInternals, owner: wj.JSValue }

@(private = "file")
internals_free :: proc "c" (p: rawptr) {
	wj.JS_FreeValueRT(wj.web_rt(), (^Internals)(p).states)
	wj.libc_free(p)
}
@(private = "file")
internals_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) { wj.wj_mark(rt, (^Internals)(p).states, mark_func) }
@(private = "file")
states_free :: proc "c" (p: rawptr) {
	wj.JS_FreeValueRT(wj.web_rt(), (^States)(p).owner)
	wj.libc_free(p)
}
@(private = "file")
states_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) { wj.wj_mark(rt, (^States)(p).owner, mark_func) }

@(export, link_name = "wjr_HTMLElement_attachInternals")
wjr_HTMLElement_attachInternals :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, t, ifc("HTMLElement"))
	if o == nil { return wj.EXCEPTION }
	h: api_decl.ElementInternals
	st := jsb.host(&h, api_decl.Element_attachInternals, wj.wr_Element_attachInternals, api_decl.Element(o.handle))
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "HTMLElement.attachInternals") }
	obj := wj.wj_wrap_owned(ctx, u64(h), ifc("ElementInternals"), wj.UNDEFINED)
	if wj.is_exception(obj) { return obj }
	it := (^Internals)(wj.libc_calloc(1, size_of(Internals)))
	if it == nil { wj.JS_FreeValue(ctx, obj); return wj.JS_ThrowOutOfMemory(ctx) }
	it.states = wj.UNDEFINED
	wj.web_set_impl(obj, it, internals_free, internals_mark)
	// the element keeps its internals' wrapper alive (scripts read them back through it)
	wj.JS_DefinePropertyValueStr(ctx, t, "\x01internals", wj.JS_DupValue(ctx, obj), 0)
	return obj
}

@(private = "file")
internals_this :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue) -> ^wj.Obj {
	o := wj.wj_this(ctx, t, ifc("ElementInternals"))
	if o != nil && o.impl == nil { wj.JS_ThrowTypeError(ctx, "Illegal invocation"); return nil }
	return o
}

@(export, link_name = "wjr_ElementInternals_get_shadowRoot")
wjr_ElementInternals_get_shadowRoot :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := internals_this(ctx, t)
	if o == nil { return wj.EXCEPTION }
	root: api_decl.Node
	jsb.host(&root, api_decl.ElementInternals_shadowRootOf, wj.wr_ElementInternals_shadowRootOf, api_decl.ElementInternals(o.handle))
	return wj.wj_wrap_node(ctx, u64(root))
}

@(export, link_name = "wjr_ElementInternals_get_states")
wjr_ElementInternals_get_states :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	o := internals_this(ctx, t)
	if o == nil { return wj.EXCEPTION }
	it := (^Internals)(o.impl)
	if wj.is_undefined(it.states) {
		s := (^States)(wj.libc_calloc(1, size_of(States)))
		if s == nil { return wj.JS_ThrowOutOfMemory(ctx) }
		s^ = {api_decl.ElementInternals(o.handle), wj.JS_DupValue(ctx, t)}
		obj := wj.wj_new_object(ctx, ifc("CustomStateSet"), s, states_free)
		if wj.is_exception(obj) { return obj }
		wj.obj_of(obj).impl_mark = states_mark
		// setlike: @@iterator is values() (Web IDL §3.7.11)
		proto := wj.JS_GetPrototype(ctx, obj)
		sym := global_prop(ctx, "Symbol")
		iter := wj.JS_GetPropertyStr(ctx, sym, "iterator")
		ia := wj.JS_ValueToAtom(ctx, iter)
		if wj.JS_HasProperty(ctx, proto, ia) == 0 {
			wj.JS_DefinePropertyValue(ctx, proto, ia, wj.JS_GetPropertyStr(ctx, proto, "values"), wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
		}
		wj.JS_FreeAtom(ctx, ia)
		wj.JS_FreeValue(ctx, iter)
		wj.JS_FreeValue(ctx, sym)
		wj.JS_FreeValue(ctx, proto)
		it.states = obj
	}
	return wj.JS_DupValue(ctx, it.states)
}

@(private = "file")
states_this :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue) -> ^States {
	o := wj.wj_this(ctx, t, ifc("CustomStateSet"))
	if o == nil { return nil }
	if o.impl == nil { wj.JS_ThrowTypeError(ctx, "Illegal invocation"); return nil }
	return (^States)(o.impl)
}

@(private = "file")
State_Op :: enum { Add, Delete, Has }

@(private = "file")
state_op :: proc(ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, op: State_Op, what: cstring) -> wj.JSValue {
	s := states_this(ctx, t)
	if s == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, what, 1, argc) }
	v: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &v, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &v)
	r: bool
	switch op {
	case .Add:
		jsb.host(&nothing, api_decl.CustomStates_add, wj.wr_CustomStates_add, s.internals, str_view(v))
		return wj.JS_DupValue(ctx, t)
	case .Delete:
		jsb.host(&r, api_decl.CustomStates_delete, wj.wr_CustomStates_delete, s.internals, str_view(v))
	case .Has:
		jsb.host(&r, api_decl.CustomStates_has, wj.wr_CustomStates_has, s.internals, str_view(v))
	}
	return wj.new_bool(r)
}

@(export, link_name = "wjr_CustomStateSet_add")
wjr_CustomStateSet_add :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return state_op(ctx, t, argc, argv, .Add, "CustomStateSet.add")
}
@(export, link_name = "wjr_CustomStateSet_delete")
wjr_CustomStateSet_delete :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return state_op(ctx, t, argc, argv, .Delete, "CustomStateSet.delete")
}
@(export, link_name = "wjr_CustomStateSet_has")
wjr_CustomStateSet_has :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return state_op(ctx, t, argc, argv, .Has, "CustomStateSet.has")
}

@(export, link_name = "wjr_CustomStateSet_clear")
wjr_CustomStateSet_clear :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	s := states_this(ctx, t)
	if s == nil { return wj.EXCEPTION }
	jsb.host(&nothing, api_decl.CustomStates_clear, wj.wr_CustomStates_clear, s.internals)
	return wj.UNDEFINED
}

// the states as an array of strings, and their count
@(private = "file")
states_array :: proc(ctx: ^wj.Context, s: ^States) -> (wj.JSValue, u32) {
	list: abi.Bytes
	jsb.host(&list, api_decl.CustomStates_list, wj.wr_CustomStates_list, s.internals)
	arr := wj.JS_NewArray(ctx)
	k: u32
	start := 0
	for c, i in list {
		if c != 0 { continue }
		wj.array_set(ctx, arr, k, wj.new_string_len(ctx, ([]u8)(list[start:i])))
		k += 1
		start = i + 1
	}
	return arr, k
}

@(export, link_name = "wjr_CustomStateSet_get_size")
wjr_CustomStateSet_get_size :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	s := states_this(ctx, t)
	if s == nil { return wj.EXCEPTION }
	arr, n := states_array(ctx, s)
	wj.JS_FreeValue(ctx, arr)
	return wj.new_uint32(ctx, n)
}

// values() / keys() / entries(): an iterator over a snapshot of the states
@(private = "file")
states_iter :: proc(ctx: ^wj.Context, t: wj.JSValue, entries: bool) -> wj.JSValue {
	s := states_this(ctx, t)
	if s == nil { return wj.EXCEPTION }
	arr, n := states_array(ctx, s)
	if entries {
		// a set's entries are [value, value]
		pairs := wj.JS_NewArray(ctx)
		for i in 0 ..< n {
			v := wj.JS_GetPropertyUint32(ctx, arr, i)
			pair := wj.JS_NewArray(ctx)
			wj.array_set(ctx, pair, 0, wj.JS_DupValue(ctx, v))
			wj.array_set(ctx, pair, 1, v)
			wj.array_set(ctx, pairs, i, pair)
		}
		wj.JS_FreeValue(ctx, arr)
		arr = pairs
	}
	defer wj.JS_FreeValue(ctx, arr)
	return call_method(ctx, arr, "values")
}

@(export, link_name = "wjr_CustomStateSet_values")
wjr_CustomStateSet_values :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return states_iter(ctx, t, false)
}
@(export, link_name = "wjr_CustomStateSet_keys")
wjr_CustomStateSet_keys :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return states_iter(ctx, t, false)
}
@(export, link_name = "wjr_CustomStateSet_entries")
wjr_CustomStateSet_entries :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return states_iter(ctx, t, true)
}

@(export, link_name = "wjr_CustomStateSet_forEach")
wjr_CustomStateSet_forEach :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	s := states_this(ctx, t)
	if s == nil { return wj.EXCEPTION }
	if argc < 1 || !wj.JS_IsFunction(ctx, argv[0]) { return wj.JS_ThrowTypeError(ctx, "CustomStateSet.forEach: the callback is not a function") }
	arr, n := states_array(ctx, s)
	defer wj.JS_FreeValue(ctx, arr)
	this_arg := wj.arg(argc, argv, 1)
	for i in 0 ..< n {
		v := wj.JS_GetPropertyUint32(ctx, arr, i)
		args := [3]wj.JSValue{v, v, t}
		r := wj.JS_Call(ctx, argv[0], this_arg, 3, &args[0])
		wj.JS_FreeValue(ctx, v)
		if wj.is_exception(r) { return r }
		wj.JS_FreeValue(ctx, r)
	}
	return wj.UNDEFINED
}

// ---- stylesheets: constructed ones and those of <style> / <link> elements (src/page/js_cssom.odin) ----

@(private = "file")
is_sheet :: proc(h: u64) -> bool {
	r: bool
	jsb.host(&r, api_decl.CSSStyleSheet_isSheet, wj.wr_CSSStyleSheet_isSheet, api_decl.CSSStyleSheet(h))
	return r
}

// `this` of a CSSStyleSheet member: any sheet of the page (0 with a TypeError pending otherwise)
@(private = "file")
sheet_this :: proc(ctx: ^wj.Context, t: wj.JSValue) -> api_decl.CSSStyleSheet {
	o := wj.wj_this(ctx, t, ifc("CSSStyleSheet"))
	if o == nil { return 0 }
	if o.handle == 0 || !is_sheet(o.handle) {
		wj.JS_ThrowTypeError(ctx, "Illegal invocation: not a stylesheet of this document")
		return 0
	}
	return api_decl.CSSStyleSheet(o.handle)
}

@(export, link_name = "wjr_CSSStyleSheet_constructor")
wjr_CSSStyleSheet_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor CSSStyleSheet requires 'new'") }
	init: wjd_CSSStyleSheetInit
	if !wjd_CSSStyleSheetInit_from(ctx, wj.arg(argc, argv, 0), &init) { return wj.EXCEPTION }
	defer wjd_CSSStyleSheetInit_free(ctx, &init)
	media: wj.Str
	defer wj.wj_str_free(ctx, &media)
	ok := true
	if wj.is_string(init.media) {
		ok = wj.wj_to_str(ctx, init.media, &media, 0, "")
	} else if wj.is_object(init.media) {
		// a MediaList: its mediaText
		mt := wj.JS_GetPropertyStr(ctx, init.media, "mediaText")
		ok = !wj.is_exception(mt) && wj.wj_to_str(ctx, mt, &media, 0, "")
		wj.JS_FreeValue(ctx, mt)
	}
	if !ok { return wj.EXCEPTION }
	h: api_decl.CSSStyleSheet
	jsb.host(&h, api_decl.CSSStyleSheet_create, wj.wr_CSSStyleSheet_create, str_view(media), init.disabled, str_view(init.baseURL))
	if h == 0 { return wj.wj_throw_dom(ctx, "NotSupportedError", "Stylesheets are not available here.") }
	return wj.wj_wrap_owned(ctx, u64(h), ifc("CSSStyleSheet"), new_target)
}

// replaceText of the converted text: .None, the browser's error, or false with an exception pending
@(private = "file")
sheet_replace :: proc(ctx: ^wj.Context, h: api_decl.CSSStyleSheet, text: wj.JSValue) -> (abi.Api_Error, bool) {
	s: wj.Str
	if !wj.wj_to_str(ctx, text, &s, 0, "") { return .None, false }
	defer wj.wj_str_free(ctx, &s)
	return jsb.host(&nothing, api_decl.CSSStyleSheet_replaceText, wj.wr_CSSStyleSheet_replaceText, h, str_view(s)), true
}

@(export, link_name = "wjr_CSSStyleSheet_replaceSync")
wjr_CSSStyleSheet_replaceSync :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := sheet_this(ctx, t)
	if h == 0 { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "CSSStyleSheet.replaceSync", 1, argc) }
	st, ok := sheet_replace(ctx, h, argv[0])
	if !ok { return wj.EXCEPTION }
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "CSSStyleSheet.replaceSync") : wj.UNDEFINED
}

// replace(text): the rules are parsed at once (no @import to wait for: they are dropped); a promise of the sheet
@(export, link_name = "wjr_CSSStyleSheet_replace")
wjr_CSSStyleSheet_replace :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := sheet_this(ctx, t)
	if h == 0 { return wj.web_promise_reject_pending(ctx) }
	st, ok := sheet_replace(ctx, h, wj.arg(argc, argv, 0))
	if !ok { return wj.web_promise_reject_pending(ctx) }
	if st != .None { wj.wj_throw_status(ctx, i32(st), "CSSStyleSheet.replace"); return wj.web_promise_reject_pending(ctx) }
	return wj.web_promise_resolved(ctx, t)
}

@(export, link_name = "wjr_CSSStyleSheet_insertRule")
wjr_CSSStyleSheet_insertRule :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := sheet_this(ctx, t)
	if h == 0 { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "CSSStyleSheet.insertRule", 1, argc) }
	index: u32
	if argc > 1 && !wj.is_undefined(argv[1]) && wj.JS_ToUint32(ctx, &index, argv[1]) < 0 { return wj.EXCEPTION }
	s: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &s, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	r: u32
	st := jsb.host(&r, api_decl.CSSStyleSheet_insertRuleAt, wj.wr_CSSStyleSheet_insertRuleAt, h, str_view(s), index)
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "CSSStyleSheet.insertRule") : wj.new_uint32(ctx, r)
}

@(export, link_name = "wjr_CSSStyleSheet_deleteRule")
wjr_CSSStyleSheet_deleteRule :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := sheet_this(ctx, t)
	if h == 0 { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "CSSStyleSheet.deleteRule", 1, argc) }
	index: u32
	if wj.JS_ToUint32(ctx, &index, argv[0]) < 0 { return wj.EXCEPTION }
	st := jsb.host(&nothing, api_decl.CSSStyleSheet_deleteRuleAt, wj.wr_CSSStyleSheet_deleteRuleAt, h, index)
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "CSSStyleSheet.deleteRule") : wj.UNDEFINED
}

// cssRules ([SameObject]): a CSSRuleList whose length is the browser's; its items (objects with cssText, selectorText
// for a style rule, parentStyleSheet: CSSRule is not otherwise modelled) are made when one is read, again only after
// the sheet's rules changed (CSSStyleSheet_rulesVersion). insertRule(rule, sheet.cssRules.length) in a loop, as
// CSS-in-JS libraries do, makes no rule object at all.
@(private = "file")
Rules :: struct {
	sheet:   wj.JSValue,   // the CSSStyleSheet (counted)
	items:   wj.JSValue,   // an array of the rule objects (counted), undefined until read
	by_id:   wj.JSValue,   // the same objects by rule identity (CSSStyleSheet_ruleId; counted): kept across changes
	version: u32,
}

@(private = "file")
rules_free :: proc "c" (p: rawptr) {
	r := (^Rules)(p)
	rt := wj.web_rt()
	wj.JS_FreeValueRT(rt, r.sheet)
	wj.JS_FreeValueRT(rt, r.items)
	wj.JS_FreeValueRT(rt, r.by_id)
	wj.libc_free(r)
}

@(private = "file")
rules_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	r := (^Rules)(p)
	wj.wj_mark(rt, r.sheet, mark_func)
	wj.wj_mark(rt, r.items, mark_func)
	wj.wj_mark(rt, r.by_id, mark_func)
}

@(private = "file")
rules_of :: proc "contextless" (obj: wj.JSValue) -> ^Rules {
	o := wj.wj_unwrap(obj, ifc("CSSRuleList"))
	return o != nil && o.impl_free == rules_free ? (^Rules)(o.impl) : nil
}

@(private = "file")
rules_sheet :: proc(r: ^Rules) -> api_decl.CSSStyleSheet {
	o := r != nil ? wj.wj_unwrap(r.sheet, ifc("CSSStyleSheet")) : nil
	return o != nil && o.handle != 0 && is_sheet(o.handle) ? api_decl.CSSStyleSheet(o.handle) : 0
}

@(private = "file")
rule_count :: proc(h: api_decl.CSSStyleSheet) -> u32 {
	n: u32
	if h != 0 { jsb.host(&n, api_decl.CSSStyleSheet_ruleCount, wj.wr_CSSStyleSheet_ruleCount, h) }
	return n
}

// A rule object: cssText, a style rule's selectorText (what comes before its block), parentStyleSheet.
@(private = "file")
rule_object :: proc "contextless" (ctx: ^wj.Context, text: string, sheet: wj.JSValue) -> wj.JSValue {
	rule := wj.JS_NewObject(ctx)
	wj.JS_DefinePropertyValueStr(ctx, rule, "cssText", wj.new_string_len(ctx, text), wj.PROP_ENUMERABLE)
	if len(text) > 0 && text[0] != '@' {
		for c, b in transmute([]u8)text {
			if c != '{' { continue }
			sl := b
			for sl > 0 && (text[sl - 1] == ' ' || text[sl - 1] == '\n' || text[sl - 1] == '\t') { sl -= 1 }
			wj.JS_DefinePropertyValueStr(ctx, rule, "selectorText", wj.new_string_len(ctx, text[:sl]), wj.PROP_ENUMERABLE)
			break
		}
	}
	wj.JS_DefinePropertyValueStr(ctx, rule, "parentStyleSheet", wj.JS_DupValue(ctx, sheet), 0)
	return rule
}

// the rule objects (not counted), made again when the sheet's rules changed since
@(private = "file")
rules_items :: proc(ctx: ^wj.Context, r: ^Rules) -> wj.JSValue {
	h := rules_sheet(r)
	v: u32
	if h != 0 { jsb.host(&v, api_decl.CSSStyleSheet_rulesVersion, wj.wr_CSSStyleSheet_rulesVersion, h) }
	if wj.JS_IsArray(r.items) && r.version == v { return r.items }
	arr := wj.JS_NewArray(ctx)
	if wj.is_exception(arr) { return arr }
	by_id := wj.JS_NewObject(ctx)
	if wj.is_exception(by_id) { wj.JS_FreeValue(ctx, arr); return by_id }
	n := rule_count(h)
	for i in 0 ..< n {
		id: u32
		jsb.host(&id, api_decl.CSSStyleSheet_ruleId, wj.wr_CSSStyleSheet_ruleId, h, i)
		kept := wj.is_object(r.by_id) && id != 0 ? wj.JS_GetPropertyUint32(ctx, r.by_id, id) : wj.UNDEFINED
		if wj.is_object(kept) {
			wj.JS_SetPropertyUint32(ctx, by_id, id, wj.JS_DupValue(ctx, kept))
			wj.array_set(ctx, arr, i, kept)
			continue
		}
		wj.JS_FreeValue(ctx, kept)
		text: string
		if jsb.host(&text, api_decl.CSSStyleSheet_ruleText, wj.wr_CSSStyleSheet_ruleText, h, i) != .None { break }
		rule := rule_object(ctx, text, r.sheet)
		if id != 0 { wj.JS_SetPropertyUint32(ctx, by_id, id, wj.JS_DupValue(ctx, rule)) }
		wj.array_set(ctx, arr, i, rule)
	}
	wj.JS_FreeValue(ctx, r.items)
	wj.JS_FreeValue(ctx, r.by_id)
	r.items = arr
	r.by_id = by_id
	r.version = v
	return arr
}

@(export, link_name = "wjr_CSSStyleSheet_get_cssRules")
wjr_CSSStyleSheet_get_cssRules :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if sheet_this(ctx, t) == 0 { return wj.EXCEPTION }
	r := (^Rules)(wj.libc_calloc(1, size_of(Rules)))
	if r == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	r^ = {sheet = wj.JS_DupValue(ctx, t), items = wj.UNDEFINED, by_id = wj.UNDEFINED}
	obj := wj.wj_new_object(ctx, ifc("CSSRuleList"), r, rules_free)
	if wj.is_exception(obj) { return obj }
	wj.obj_of(obj).impl_mark = rules_mark
	return obj
}

@(export, link_name = "wjr_CSSStyleSheet_get_rules")
wjr_CSSStyleSheet_get_rules :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return wj.JS_GetPropertyStr(ctx, t, "cssRules") }

@(export, link_name = "wjr_CSSRuleList_length_hook")
wjr_CSSRuleList_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 {
	context = jsb.glue_context()
	return rule_count(rules_sheet(rules_of(obj)))
}

@(export, link_name = "wjr_CSSRuleList_index_get")
wjr_CSSRuleList_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue {
	context = jsb.glue_context()
	found^ = false
	r := rules_of(obj)
	if r == nil { return wj.UNDEFINED }
	arr := rules_items(ctx, r)
	if wj.is_exception(arr) { return arr }
	v := wj.JS_GetPropertyUint32(ctx, arr, index)
	found^ = !wj.is_undefined(v)
	return v
}

@(export, link_name = "wjr_CSSRuleList_get_length")
wjr_CSSRuleList_get_length :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("CSSRuleList")) == nil { return wj.EXCEPTION }
	return wj.new_uint32(ctx, wjr_CSSRuleList_length_hook(ctx, t))
}

@(export, link_name = "wjr_CSSRuleList_item")
wjr_CSSRuleList_item :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("CSSRuleList")) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "CSSRuleList.item", 1, argc) }
	i: u32
	if !wj.wj_to_uint32(ctx, argv[0], &i, 32, 0) { return wj.EXCEPTION }
	found: bool
	v := wjr_CSSRuleList_index_get(ctx, t, i, &found)
	return wj.is_exception(v) || found ? v : wj.NULL
}

@(export, link_name = "wjr_StyleSheet_get_disabled")
wjr_StyleSheet_get_disabled :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := sheet_this(ctx, t)
	if h == 0 { return wj.EXCEPTION }
	r: bool
	jsb.host(&r, api_decl.CSSStyleSheet_isDisabled, wj.wr_CSSStyleSheet_isDisabled, h)
	return wj.new_bool(r)
}

@(export, link_name = "wjr_StyleSheet_set_disabled")
wjr_StyleSheet_set_disabled :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := sheet_this(ctx, t)
	if h == 0 { return wj.EXCEPTION }
	jsb.host(&nothing, api_decl.CSSStyleSheet_setDisabled, wj.wr_CSSStyleSheet_setDisabled, h, wj.JS_ToBool(ctx, v) != 0)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_StyleSheet_get_type")
wjr_StyleSheet_get_type :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return sheet_this(ctx, t) != 0 ? wj.new_string(ctx, "text/css") : wj.EXCEPTION
}

// a string of the browser's, null when empty
@(private = "file")
string_or_null :: proc "contextless" (ctx: ^wj.Context, s: string, st: abi.Api_Error) -> wj.JSValue {
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "StyleSheet") }
	return len(s) == 0 ? wj.NULL : wj.new_string_len(ctx, s)
}

@(export, link_name = "wjr_StyleSheet_get_href")
wjr_StyleSheet_get_href :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := sheet_this(ctx, t)
	if h == 0 { return wj.EXCEPTION }
	s: string
	st := jsb.host(&s, api_decl.CSSStyleSheet_hrefOf, wj.wr_CSSStyleSheet_hrefOf, h)
	return string_or_null(ctx, s, st)
}

@(export, link_name = "wjr_StyleSheet_get_title")
wjr_StyleSheet_get_title :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := sheet_this(ctx, t)
	if h == 0 { return wj.EXCEPTION }
	s: string
	st := jsb.host(&s, api_decl.CSSStyleSheet_titleOf, wj.wr_CSSStyleSheet_titleOf, h)
	return string_or_null(ctx, s, st)
}

@(export, link_name = "wjr_StyleSheet_get_ownerNode")
wjr_StyleSheet_get_ownerNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := sheet_this(ctx, t)
	if h == 0 { return wj.EXCEPTION }
	n: api_decl.Node
	jsb.host(&n, api_decl.CSSStyleSheet_ownerNodeOf, wj.wr_CSSStyleSheet_ownerNodeOf, h)
	return wj.wj_wrap_node(ctx, u64(n))
}

@(export, link_name = "wjr_StyleSheet_get_parentStyleSheet")
wjr_StyleSheet_get_parentStyleSheet :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return sheet_this(ctx, t) != 0 ? wj.NULL : wj.EXCEPTION
}
@(export, link_name = "wjr_CSSStyleSheet_get_ownerRule")
wjr_CSSStyleSheet_get_ownerRule :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return sheet_this(ctx, t) != 0 ? wj.NULL : wj.EXCEPTION
}

// element.sheet (LinkStyle: <style>, <link>, SVG <style>)
@(export, link_name = "wjr_LinkStyle_get_sheet")
wjr_LinkStyle_get_sheet :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, t, ifc("Node"))
	if o == nil { return wj.EXCEPTION }
	h: api_decl.CSSStyleSheet
	jsb.host(&h, api_decl.LinkStyle_sheetOf, wj.wr_LinkStyle_sheetOf, api_decl.Node(o.handle))
	return wj.wj_wrap_host(ctx, u64(h), ifc("CSSStyleSheet"))
}

// document.styleSheets / shadowRoot.styleSheets ([SameObject]): a live StyleSheetList of the tree's sheets
@(private = "file")
Sheets :: struct {
	root:   wj.JSValue,   // the document or shadow root (counted)
	handle: api_decl.Node,
}

@(private = "file")
sheets_free :: proc "c" (p: rawptr) {
	wj.JS_FreeValueRT(wj.web_rt(), (^Sheets)(p).root)
	wj.libc_free(p)
}

@(private = "file")
sheets_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) { wj.wj_mark(rt, (^Sheets)(p).root, mark_func) }

@(private = "file")
sheets_of :: proc "contextless" (obj: wj.JSValue) -> ^Sheets {
	o := wj.wj_unwrap(obj, ifc("StyleSheetList"))
	return o != nil && o.impl_free == sheets_free ? (^Sheets)(o.impl) : nil
}

@(export, link_name = "wjr_DocumentOrShadowRoot_get_styleSheets")
wjr_DocumentOrShadowRoot_get_styleSheets :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	o := wj.wj_this(ctx, t, ifc("Node"))
	if o == nil { return wj.EXCEPTION }
	s := (^Sheets)(wj.libc_calloc(1, size_of(Sheets)))
	if s == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	s^ = {wj.JS_DupValue(ctx, t), api_decl.Node(o.handle)}
	obj := wj.wj_new_object(ctx, ifc("StyleSheetList"), s, sheets_free)
	if wj.is_exception(obj) { return obj }
	wj.obj_of(obj).impl_mark = sheets_mark
	return obj
}

@(export, link_name = "wjr_StyleSheetList_length_hook")
wjr_StyleSheetList_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 {
	context = jsb.glue_context()
	s := sheets_of(obj)
	if s == nil { return 0 }
	n: u32
	jsb.host(&n, api_decl.DocumentOrShadowRoot_sheetCount, wj.wr_DocumentOrShadowRoot_sheetCount, s.handle)
	return n
}

@(export, link_name = "wjr_StyleSheetList_index_get")
wjr_StyleSheetList_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue {
	context = jsb.glue_context()
	h: api_decl.CSSStyleSheet
	if s := sheets_of(obj); s != nil { jsb.host(&h, api_decl.DocumentOrShadowRoot_sheetAt, wj.wr_DocumentOrShadowRoot_sheetAt, s.handle, index) }
	found^ = h != 0
	return h != 0 ? wj.wj_wrap_host(ctx, u64(h), ifc("CSSStyleSheet")) : wj.UNDEFINED
}

@(export, link_name = "wjr_StyleSheetList_get_length")
wjr_StyleSheetList_get_length :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("StyleSheetList")) == nil { return wj.EXCEPTION }
	return wj.new_uint32(ctx, wjr_StyleSheetList_length_hook(ctx, t))
}

@(export, link_name = "wjr_StyleSheetList_item")
wjr_StyleSheetList_item :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("StyleSheetList")) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "StyleSheetList.item", 1, argc) }
	i: u32
	if !wj.wj_to_uint32(ctx, argv[0], &i, 32, 0) { return wj.EXCEPTION }
	found: bool
	v := wjr_StyleSheetList_index_get(ctx, t, i, &found)
	return found ? v : wj.NULL
}

// ---- adoptedStyleSheets: an ObservableArray<CSSStyleSheet> per root, native (in place of prelude/shadow.js) ----
// A Proxy over a real backing array: reads and the Array.prototype methods go straight to the backing array,
// Array.isArray() is true (the target is a genuine array), and only set / define / delete are trapped — each checks
// (constructed stylesheets only), mutates the array and gives the sheets to the browser (DocumentOrShadowRoot_adopt).
// A Proxy is required here: an exotic class could neither satisfy Array.isArray nor re-run the WebIDL descriptor
// conversion for defineProperty. The traps are native functions (no prelude JavaScript). The proxies are kept by root
// handle, not by wrapper, and closed roots are dropped from time to time.

@(private = "file") obs_by_root := wj.UNDEFINED           // Map root handle -> the ObservableArray Proxy (counted)
@(private = "file") obs_backing_by_root := wj.UNDEFINED   // Map root handle -> backing array (counted)
@(private = "file") shadow_ready: bool
@(private = "file") obs_made: u32

// the browser's handle of a constructed stylesheet wrapper (0: not one)
@(private = "file")
constructed_sheet :: proc(v: wj.JSValue) -> u64 {
	o := wj.wj_unwrap(v, ifc("CSSStyleSheet"))
	if o == nil || o.handle == 0 { return 0 }
	r: bool
	jsb.host(&r, api_decl.CSSStyleSheet_isConstructed, wj.wr_CSSStyleSheet_isConstructed, api_decl.CSSStyleSheet(o.handle))
	return r ? o.handle : 0
}

// A constructed stylesheet; throws for anything else.
@(private = "file")
obs_check :: proc(ctx: ^wj.Context, v: wj.JSValue) -> bool {
	if wj.wj_unwrap(v, ifc("CSSStyleSheet")) == nil {
		wj.JS_ThrowTypeError(ctx, "Failed to set the 'adoptedStyleSheets' property: Failed to convert value to 'CSSStyleSheet'.")
		return false
	}
	if constructed_sheet(v) == 0 {
		wj.JS_Throw(ctx, wj.web_dom_exception(ctx, "NotAllowedError", "Failed to set the 'adoptedStyleSheets' property: Can't adopt non-constructed stylesheets."))
		return false
	}
	return true
}

// commit(): give a backing array's sheets to the browser
@(private = "file")
obs_commit :: proc(ctx: ^wj.Context, root: u64, array: wj.JSValue) -> bool {
	n: i64
	wj.JS_GetLength(ctx, array, &n)
	hs: [^]u64
	if n > 0 {
		hs = ([^]u64)(wj.libc_malloc(uint(n) * 8))
		if hs == nil { wj.JS_ThrowOutOfMemory(ctx); return false }
	}
	defer wj.libc_free(hs)
	for i in 0 ..< n {
		v := wj.JS_GetPropertyInt64(ctx, array, i)
		hs[i] = constructed_sheet(v)
		wj.JS_FreeValue(ctx, v)
	}
	st := jsb.host(&nothing, api_decl.DocumentOrShadowRoot_adopt, wj.wr_DocumentOrShadowRoot_adopt, api_decl.Node(root), hs != nil ? hs[:n] : nil)
	if st != .None { wj.wj_throw_status(ctx, i32(st), "adoptedStyleSheets"); return false }
	return true
}

// A trap's property key when it is a canonical array index: its value, true.
@(private = "file")
index_key :: proc "contextless" (ctx: ^wj.Context, prop: wj.JSValue) -> (index: i64, is_index: bool, ok: bool) {
	if !wj.is_string(prop) { return 0, false, true }
	n: uint
	p := wj.to_cstring_len(ctx, &n, prop)
	if p == nil { return 0, false, false }
	is_index = is_index_string(string(([^]u8)(rawptr(p))[:n]))
	wj.JS_FreeCString(ctx, p)
	if is_index {
		d: f64
		wj.JS_ToFloat64(ctx, &d, prop)
		index = i64(d)
	}
	return index, is_index, true
}

// Reflect[name](args...)
@(private = "file")
reflect :: proc "contextless" (ctx: ^wj.Context, name: cstring, args: ..wj.JSValue) -> wj.JSValue {
	r := global_prop(ctx, "Reflect")
	defer wj.JS_FreeValue(ctx, r)
	return call_method(ctx, r, name, ..args)
}

@(private = "file")
target_length :: proc "contextless" (ctx: ^wj.Context, target: wj.JSValue) -> i64 {
	n: i64
	wj.JS_GetLength(ctx, target, &n)
	return n
}

// set(target, prop, value, receiver): an index or length is checked and committed; anything else goes to the array
// (Reflect.set, so a deeper accessor and the array's own [[Set]] behave normally).
@(private = "file")
obs_set_trap :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	root := data_handle(data)
	target, prop, value := wj.arg(argc, argv, 0), wj.arg(argc, argv, 1), wj.arg(argc, argv, 2)
	index, is_index, ok := index_key(ctx, prop)
	if !ok { return wj.EXCEPTION }
	if is_index {
		if index > target_length(ctx, target) { return wj.JS_ThrowRangeError(ctx, "adoptedStyleSheets: index past the end") }
		if !obs_check(ctx, value) { return wj.EXCEPTION }
		wj.JS_SetPropertyInt64(ctx, target, index, wj.JS_DupValue(ctx, value))
		return obs_commit(ctx, root, target) ? wj.TRUE : wj.EXCEPTION
	}
	if str_value_is(ctx, prop, "length") {
		dn: f64
		if wj.JS_ToFloat64(ctx, &dn, value) < 0 { return wj.EXCEPTION }
		if dn != f64(i64(dn)) || dn < 0 || i64(dn) > target_length(ctx, target) { return wj.JS_ThrowRangeError(ctx, "adoptedStyleSheets: invalid length") }
		wj.JS_SetPropertyStr(ctx, target, "length", wj.new_int64(ctx, i64(dn)))
		return obs_commit(ctx, root, target) ? wj.TRUE : wj.EXCEPTION
	}
	return reflect(ctx, "set", target, prop, value, argc > 3 ? argv[3] : target)
}

// defineProperty(target, prop, descriptor): an index with a value is checked and committed; else
// Reflect.defineProperty (which re-runs the WebIDL descriptor conversion, so a reentrant mutation during conversion is
// observed).
@(private = "file")
obs_define_trap :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	root := data_handle(data)
	target, prop, desc := wj.arg(argc, argv, 0), wj.arg(argc, argv, 1), wj.arg(argc, argv, 2)
	index, is_index, ok := index_key(ctx, prop)
	if !ok { return wj.EXCEPTION }
	if !is_index { return reflect(ctx, "defineProperty", target, prop, desc) }
	// "value" in desc (an accessor descriptor is refused)
	va := wj.JS_NewAtom(ctx, "value")
	has := wj.JS_HasProperty(ctx, desc, va)
	if has <= 0 { wj.JS_FreeAtom(ctx, va); return has < 0 ? wj.EXCEPTION : wj.FALSE }
	val := wj.JS_GetProperty(ctx, desc, va)
	wj.JS_FreeAtom(ctx, va)
	if wj.is_exception(val) { return wj.EXCEPTION }
	if index > target_length(ctx, target) { wj.JS_FreeValue(ctx, val); return wj.FALSE }
	if !obs_check(ctx, val) { wj.JS_FreeValue(ctx, val); return wj.EXCEPTION }
	wj.JS_SetPropertyInt64(ctx, target, index, val)
	return obs_commit(ctx, root, target) ? wj.TRUE : wj.EXCEPTION
}

// deleteProperty(target, prop): an ObservableArray deletes only its last element (then commits)
@(private = "file")
obs_delete_trap :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	root := data_handle(data)
	target, prop := wj.arg(argc, argv, 0), wj.arg(argc, argv, 1)
	index, is_index, ok := index_key(ctx, prop)
	if !ok { return wj.EXCEPTION }
	if !is_index { return reflect(ctx, "deleteProperty", target, prop) }
	tl := target_length(ctx, target)
	if index != tl - 1 { return wj.FALSE }   // only the last element
	wj.JS_SetPropertyStr(ctx, target, "length", wj.new_int64(ctx, tl - 1))
	return obs_commit(ctx, root, target) ? wj.TRUE : wj.EXCEPTION
}

// delete the entries of a root-keyed Map whose root is a node no longer live
@(private = "file")
obs_prune_map :: proc(ctx: ^wj.Context, m: wj.JSValue) {
	if wj.is_undefined(m) { return }
	it := call_method(ctx, m, "keys")
	array := global_prop(ctx, "Array")
	keys := call_method(ctx, array, "from", it)
	wj.JS_FreeValue(ctx, array)
	wj.JS_FreeValue(ctx, it)
	defer wj.JS_FreeValue(ctx, keys)
	n: i64
	wj.JS_GetLength(ctx, keys, &n)
	for i in 0 ..< n {
		k := wj.JS_GetPropertyInt64(ctx, keys, i)
		d: f64
		wj.JS_ToFloat64(ctx, &d, k)
		live: bool
		jsb.host(&live, api_decl.Node_isLive, wj.wr_Node_isLive, api_decl.Node(u64(d)))
		if !live { wj.JS_FreeValue(ctx, call_method(ctx, m, "delete", k)) }
		wj.JS_FreeValue(ctx, k)
	}
}

// lookup over a root-keyed Map (UNINITIALIZED when absent)
@(private = "file")
obs_map_get :: proc "contextless" (ctx: ^wj.Context, m: wj.JSValue, handle: u64) -> wj.JSValue {
	if wj.is_undefined(m) { return wj.UNINITIALIZED }
	key := wj.new_float64(ctx, f64(handle))
	e := call_method(ctx, m, "get", key)
	wj.JS_FreeValue(ctx, key)
	if wj.is_undefined(e) { return wj.UNINITIALIZED }
	return e
}

@(private = "file")
obs_map_set :: proc "contextless" (ctx: ^wj.Context, m: ^wj.JSValue, handle: u64, value: wj.JSValue) {
	if wj.is_undefined(m^) { m^ = construct_global(ctx, "Map") }
	key := wj.new_float64(ctx, f64(handle))
	wj.JS_FreeValue(ctx, call_method(ctx, m^, "set", key, value))
	wj.JS_FreeValue(ctx, key)
}

// the ObservableArray Proxy of a root, made (empty) the first time; the same object each time
@(private = "file")
obs_entry :: proc(ctx: ^wj.Context, handle: u64) -> wj.JSValue {
	if e := obs_map_get(ctx, obs_by_root, handle); !wj.is_uninitialized(e) { return e }
	backing := wj.JS_NewArray(ctx)
	defer wj.JS_FreeValue(ctx, backing)
	data := handle_data(handle)
	handler := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, handler, "set", wj.JS_NewCFunctionData(ctx, obs_set_trap, 4, 0, 2, &data[0]))
	wj.JS_SetPropertyStr(ctx, handler, "defineProperty", wj.JS_NewCFunctionData(ctx, obs_define_trap, 3, 0, 2, &data[0]))
	wj.JS_SetPropertyStr(ctx, handler, "deleteProperty", wj.JS_NewCFunctionData(ctx, obs_delete_trap, 2, 0, 2, &data[0]))
	proxy := construct_global(ctx, "Proxy", backing, handler)
	wj.JS_FreeValue(ctx, handler)
	if wj.is_exception(proxy) { return proxy }
	obs_map_set(ctx, &obs_backing_by_root, handle, backing)
	obs_map_set(ctx, &obs_by_root, handle, proxy)
	obs_made += 1
	if obs_made % 64 == 0 {
		// drop the arrays of roots that are gone
		obs_prune_map(ctx, obs_by_root)
		obs_prune_map(ctx, obs_backing_by_root)
	}
	return proxy
}

@(private = "file")
adopted_get :: proc(ctx: ^wj.Context, t: wj.JSValue, iface: i32) -> wj.JSValue {
	o := wj.wj_this(ctx, t, iface)
	if o == nil { return wj.EXCEPTION }
	if !shadow_ready { return wj.JS_ThrowTypeError(ctx, "adoptedStyleSheets: not available") }
	return obs_entry(ctx, o.handle)
}

// set adoptedStyleSheets = value: the sequence replaces the array, then commit
@(private = "file")
adopted_set :: proc(ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue, iface: i32) -> wj.JSValue {
	o := wj.wj_this(ctx, t, iface)
	if o == nil { return wj.EXCEPTION }
	if !shadow_ready { return wj.JS_ThrowTypeError(ctx, "adoptedStyleSheets: not available") }
	iterable := wj.is_object(v) ? wj.web_is_iterable(ctx, v) : 0
	if iterable < 0 { return wj.EXCEPTION }
	if iterable == 0 { return wj.JS_ThrowTypeError(ctx, "Failed to set the 'adoptedStyleSheets' property: The provided value cannot be converted to a sequence.") }
	// Array.from(value): materialise and check every element first
	array := global_prop(ctx, "Array")
	mat := call_method(ctx, array, "from", v)
	wj.JS_FreeValue(ctx, array)
	if wj.is_exception(mat) { return mat }
	defer wj.JS_FreeValue(ctx, mat)
	n: i64
	wj.JS_GetLength(ctx, mat, &n)
	for i in 0 ..< n {
		el := wj.JS_GetPropertyInt64(ctx, mat, i)
		ok := obs_check(ctx, el)
		wj.JS_FreeValue(ctx, el)
		if !ok { return wj.EXCEPTION }
	}
	proxy := obs_entry(ctx, o.handle)   // ensures the Proxy and its backing array exist
	if wj.is_exception(proxy) { return proxy }
	wj.JS_FreeValue(ctx, proxy)
	backing := obs_map_get(ctx, obs_backing_by_root, o.handle)
	if wj.is_uninitialized(backing) { return wj.JS_ThrowTypeError(ctx, "adoptedStyleSheets: not available") }
	defer wj.JS_FreeValue(ctx, backing)
	// a full replacement of the backing array, then one commit
	wj.JS_SetPropertyStr(ctx, backing, "length", wj.new_int32(0))
	for i in 0 ..< n { wj.JS_SetPropertyInt64(ctx, backing, i, wj.JS_GetPropertyInt64(ctx, mat, i)) }
	return obs_commit(ctx, o.handle, backing) ? wj.UNDEFINED : wj.EXCEPTION
}

@(export, link_name = "wjr_Document_get_adoptedStyleSheets")
wjr_Document_get_adoptedStyleSheets :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return adopted_get(ctx, t, ifc("Document"))
}
@(export, link_name = "wjr_Document_set_adoptedStyleSheets")
wjr_Document_set_adoptedStyleSheets :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return adopted_set(ctx, t, v, ifc("Document"))
}
@(export, link_name = "wjr_ShadowRoot_get_adoptedStyleSheets")
wjr_ShadowRoot_get_adoptedStyleSheets :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return adopted_get(ctx, t, ifc("ShadowRoot"))
}
@(export, link_name = "wjr_ShadowRoot_set_adoptedStyleSheets")
wjr_ShadowRoot_set_adoptedStyleSheets :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return adopted_set(ctx, t, v, ifc("ShadowRoot"))
}

// ---- the Window's named properties object (HTML §7.2.2.3) ----
// Elements with an id, and embed/form/img/object elements with a name, reachable as properties of the global. A null-
// backed exotic object inserted between Window.prototype and EventTarget.prototype whose get/has/getOwnPropertyDescriptor
// fall back to a document lookup when Window.prototype / the global do not already define the name.

@(private = "file") named_class: wj.Class_ID
@(private = "file") named_exotic: wj.Class_Exotic_Methods
@(private = "file") named_def: wj.Class_Def

@(private = "file")
named_lookup :: proc(ctx: ^wj.Context, prop: wj.Atom) -> wj.JSValue {
	if !wj.wj_start_frames { return wj.UNDEFINED }   // no browser behind the realm (the engine run alone): no document
	namev := wj.JS_AtomToValue(ctx, prop)
	defer wj.JS_FreeValue(ctx, namev)
	if !wj.is_string(namev) { return wj.UNDEFINED }
	n: uint
	name := wj.to_cstring_len(ctx, &n, namev)
	if name == nil { return wj.UNDEFINED }
	wj.JS_FreeCString(ctx, name)
	if n == 0 { return wj.UNDEFINED }
	// lone surrogates: name.isWellFormed() === false
	if iwf := wj.JS_GetPropertyStr(ctx, namev, "isWellFormed"); wj.JS_IsFunction(ctx, iwf) {
		r := wj.JS_Call(ctx, iwf, namev, 0, nil)
		well_formed := wj.JS_ToBool(ctx, r) != 0
		wj.JS_FreeValue(ctx, r)
		wj.JS_FreeValue(ctx, iwf)
		if !well_formed { return wj.UNDEFINED }
	} else {
		wj.JS_FreeValue(ctx, iwf)
	}
	// a child frame's window first (frames.odin)
	if w := frames_lookup(ctx, namev); !wj.is_nullish(w) { return w }
	document := global_prop(ctx, "document")
	defer wj.JS_FreeValue(ctx, document)
	if !wj.is_object(document) { return wj.UNDEFINED }
	result := wj.UNDEFINED
	// the first element of that name among embed / form / img / object, else the element of that id
	list := call_method(ctx, document, "getElementsByName", namev)
	if wj.is_exception(list) {
		wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))
	} else if wj.is_object(list) {
		count: i64
		wj.JS_GetLength(ctx, list, &count)
		for i in 0 ..< count {
			el := wj.JS_GetPropertyInt64(ctx, list, i)
			ln := wj.JS_GetPropertyStr(ctx, el, "localName")
			named := str_value_is(ctx, ln, "embed") || str_value_is(ctx, ln, "form") || str_value_is(ctx, ln, "img") || str_value_is(ctx, ln, "object")
			wj.JS_FreeValue(ctx, ln)
			if named { result = el; break }
			wj.JS_FreeValue(ctx, el)
		}
	}
	wj.JS_FreeValue(ctx, list)
	if wj.is_undefined(result) {
		el := call_method(ctx, document, "getElementById", namev)
		switch {
		case wj.is_exception(el): wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))
		case !wj.is_null(el):     result = el
		case:                     wj.JS_FreeValue(ctx, el)
		}
	}
	return result
}

// The exotic object has no own data properties of its own: a looked-up name is reported as an own data property here,
// so the engine's ordinary [[Get]] / [[Has]] (which walk the chain and call get_own_property at each step with the
// right receiver) see it. Names Window.prototype or the global already define are found before the chain reaches this
// object, so they win. define / delete refuse, as the spec's named-properties object does.
@(private = "file")
named_get_own :: proc "c" (ctx: ^wj.Context, desc: ^wj.Property_Descriptor, obj: wj.JSValue, prop: wj.Atom) -> i32 {
	context = jsb.glue_context()
	pv := wj.JS_AtomToValue(ctx, prop)
	is_str := wj.is_string(pv)
	wj.JS_FreeValue(ctx, pv)
	if !is_str { return 0 }
	// a name the object's own prototype chain (EventTarget.prototype...) already has is not shadowed
	proto := wj.JS_GetPrototype(ctx, obj)
	on_proto := wj.is_object(proto) ? wj.JS_HasProperty(ctx, proto, prop) : 0
	wj.JS_FreeValue(ctx, proto)
	if on_proto > 0 { return 0 }
	v := named_lookup(ctx, prop)
	if wj.is_undefined(v) { return 0 }
	if desc != nil {
		desc^ = {flags = wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE, value = v, getter = wj.UNDEFINED, setter = wj.UNDEFINED}
	} else {
		wj.JS_FreeValue(ctx, v)
	}
	return 1
}

@(private = "file")
named_define :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, prop: wj.Atom, val, getter, setter: wj.JSValue, flags: i32) -> i32 { return 0 }
@(private = "file")
named_delete :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, prop: wj.Atom) -> i32 { return 0 }

// The named-properties object is an "immutable prototype exotic object" (Web IDL §3.7.4.3): its [[Prototype]] can be
// set only to its current value. JSClassExoticMethods has no prototype hooks, and only a Proxy can override those
// internal methods; so the object the realm inserts is a Proxy over the exotic class object (which keeps serving the
// named-property get/has/getOwnPropertyDescriptor/define/delete/ownKeys through the default forwarding traps), with
// just these two prototype traps added.
@(private = "file")
named_get_proto_trap :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	return wj.JS_GetPrototype(ctx, wj.arg(argc, argv, 0))
}
@(private = "file")
named_set_proto_trap :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	proto := wj.arg(argc, argv, 1)
	current := wj.JS_GetPrototype(ctx, wj.arg(argc, argv, 0))
	same := wj.same_ptr(current, proto) || (wj.is_null(current) && wj.is_null(proto))
	wj.JS_FreeValue(ctx, current)
	return wj.new_bool(same)   // only the current [[Prototype]] value is accepted
}

// new Proxy(target, { getPrototypeOf, setPrototypeOf })
@(private = "file")
named_make_proxy :: proc "contextless" (ctx: ^wj.Context, target: wj.JSValue) -> wj.JSValue {
	handler := wj.JS_NewObject(ctx)
	defer wj.JS_FreeValue(ctx, handler)
	wj.JS_SetPropertyStr(ctx, handler, "getPrototypeOf", wj.JS_NewCFunctionData(ctx, named_get_proto_trap, 1, 0, 0, nil))
	wj.JS_SetPropertyStr(ctx, handler, "setPrototypeOf", wj.JS_NewCFunctionData(ctx, named_set_proto_trap, 2, 0, 0, nil))
	return construct_global(ctx, "Proxy", target, handler)
}

// ---- element.part (CSS Shadow Parts §5): the DOMTokenList of the part attribute, the same object every time ----

@(private = "file") part_lists := wj.UNDEFINED   // WeakMap element -> DOMTokenList (counted)

@(private = "file")
part_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(part_lists) { part_lists = construct_global(ctx, "WeakMap") }
	l := call_method(ctx, part_lists, "get", this_val)
	if !wj.is_undefined(l) { return l }
	l = wj_token_list_of(ctx, this_val, "part")
	if wj.is_exception(l) { return l }
	wj.JS_FreeValue(ctx, call_method(ctx, part_lists, "set", this_val, l))
	return l
}

@(private = "file")
part_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	l := part_get(ctx, this_val)
	if wj.is_exception(l) { return l }
	wj.JS_SetPropertyStr(ctx, l, "value", wj.JS_DupValue(ctx, v))
	wj.JS_FreeValue(ctx, l)
	return wj.UNDEFINED
}

// Registers the classes at pre-initialization (called from wj_run_preludes).
@(export, link_name = "wj_install_shadow")
wj_install_shadow :: proc "c" (ctx: ^wj.Context) {
	rt := wj.JS_GetRuntime(ctx)
	wj.JS_NewClassID(rt, &named_class)
	named_exotic = {get_own_property = named_get_own, delete_property = named_delete, define_own_property = named_define}
	named_def = {class_name = "WindowProperties", exotic = &named_exotic}
	if wj.JS_NewClass(rt, named_class, &named_def) < 0 { return }
	obs_by_root = wj.UNDEFINED
	obs_backing_by_root = wj.UNDEFINED
	part_lists = wj.UNDEFINED
	shadow_ready = true
}

// At the start of a Window realm: the named properties object of the Window, element.part, the members of ShadowRoot
// that the IDL lacks.
@(export, link_name = "wj_named_properties_install")
wj_named_properties_install :: proc "c" (ctx: ^wj.Context) -> i32 {
	install_shadow_root_extras(ctx)
	if !shadow_ready { return 0 }
	// the named properties object between Window.prototype and its prototype (EventTarget.prototype)
	window_proto := wj.JS_GetPrototype(ctx, wj.realm_global())
	if wj.is_object(window_proto) {
		parent := wj.JS_GetPrototype(ctx, window_proto)
		named := wj.JS_NewObjectClass(ctx, named_class)
		if wj.is_object(named) {
			wj.JS_SetPrototype(ctx, named, parent)
			// wrapped in the immutable-prototype Proxy
			proxy := named_make_proxy(ctx, named)
			if wj.is_object(proxy) {
				wj.JS_SetPrototype(ctx, window_proto, proxy)
				wj.JS_FreeValue(ctx, proxy)
			} else {
				wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))
				wj.JS_SetPrototype(ctx, window_proto, named)
			}
		}
		wj.JS_FreeValue(ctx, named)
		wj.JS_FreeValue(ctx, parent)
	}
	wj.JS_FreeValue(ctx, window_proto)
	// element.part
	element := global_prop(ctx, "Element")
	defer wj.JS_FreeValue(ctx, element)
	if wj.JS_IsFunction(ctx, element) {
		proto := wj.JS_GetPropertyStr(ctx, element, "prototype")
		a := wj.JS_NewAtom(ctx, "part")
		wj.JS_DefinePropertyGetSet(ctx, proto, a, wj.new_getter_fn(ctx, part_get, "get part"), wj.new_setter_fn(ctx, part_set, "set part"), wj.PROP_CONFIGURABLE | wj.PROP_ENUMERABLE)
		wj.JS_FreeAtom(ctx, a)
		wj.JS_FreeValue(ctx, proto)
	}
	return 0
}
