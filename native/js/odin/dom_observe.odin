// dom_observe.odin: MutationObserver and MutationRecord, TreeWalker / NodeIterator / NodeFilter, Range, and the
// document's Selection, for JavaScript (DOM Standard 4.3, 5, 6; Selection API). Ported from
// native/js/runtime/dom_observe.c; same wjr_* symbols and exports (wj_cb_mutation, wj_mo_queue). The browser side is
// src/page/js_dom_observe.odin; every call into it is a declaration of api_decl/dom.odin through jsb.host.
//
// A MutationObserver is an engine object whose impl keeps the callback; the browser's observer notifies it by slot (the
// `user` of its callback). A traversal (TreeWalker, NodeIterator) and a Range keep their state in a Dom_Impl of kind
// DOM_VALUES: the wrappers in `values`, the numbers in `rect`.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") Node :: api_decl.Node
@(private = "file") none: abi.Nothing

// ---- the browser's tree, one call each ----

@(private = "file")
tree_step :: proc($D: typeid, imp: $R, h: Node) -> (r: Node) {
	jsb.host(&r, D, imp, h)
	return
}

@(private = "file") parent_of :: proc(h: Node) -> Node { return tree_step(api_decl.Node_parentNode, wj.wr_Node_parentNode, h) }
@(private = "file") first_child :: proc(h: Node) -> Node { return tree_step(api_decl.Node_firstChild, wj.wr_Node_firstChild, h) }
@(private = "file") last_child :: proc(h: Node) -> Node { return tree_step(api_decl.Node_lastChild, wj.wr_Node_lastChild, h) }
@(private = "file") next_sibling :: proc(h: Node) -> Node { return tree_step(api_decl.Node_nextSibling, wj.wr_Node_nextSibling, h) }
@(private = "file") previous_sibling :: proc(h: Node) -> Node { return tree_step(api_decl.Node_previousSibling, wj.wr_Node_previousSibling, h) }
@(private = "file") root_of :: proc(h: Node) -> Node { return tree_step(api_decl.Node_rootNode, wj.wr_Node_rootNode, h) }

@(private = "file")
node_type :: proc(h: Node) -> (t: i32) {
	jsb.host(&t, api_decl.Node_nodeType, wj.wr_Node_nodeType, h)
	return
}

@(private = "file")
node_length :: proc(h: Node) -> (n: u32) {
	jsb.host(&n, api_decl.Node_length, wj.wr_Node_length, h)
	return
}

@(private = "file")
contains :: proc(h, other: Node) -> (yes: bool) {
	jsb.host(&yes, api_decl.Node_contains, wj.wr_Node_contains, h, other)
	return
}

// The boundary points' order: negative, 0, positive.
@(private = "file")
compare_points :: proc(a: Node, ao: u32, b: Node, bo: u32) -> (order: i32) {
	jsb.host(&order, api_decl.Range_comparePoints, wj.wr_Range_comparePoints, a, ao, b, bo)
	return
}

// A node's position among its parent's children.
@(private = "file")
index_in_parent :: proc(h: Node) -> (i: u32) {
	for p := previous_sibling(h); p != 0; p = previous_sibling(p) { i += 1 }
	return
}

@(private = "file")
handle_of :: #force_inline proc "contextless" (v: wj.JSValue) -> Node { return Node(wj.obj_handle(v)) }

// ---- MutationObserver ----

@(private = "file")
Observer :: struct {
	host:     api_decl.MutationObserver,
	callback: wj.JSValue,   // counted
	self:     wj.JSValue,   // not counted
	slot:     i32,
}

// The observers by slot (the notification's `user`; slot 0 is none), not counted.
@(private = "file") observers: [dynamic]wj.JSValue

// DOM: a node's registered observer list keeps its observers alive. The wrapper of an observed node keeps an array of
// them in a [SameObject] slot past the generated ones (marked and freed with the wrapper), so an observer lives as long
// as some node it observes can still be reached, and no longer.
@(private = "file")
observer_attach :: proc(ctx: ^wj.Context, target, observer: wj.JSValue) -> bool {
	o := wj.obj_of(target)
	if o == nil { return true }
	slot := int(wj.wj_same_object_count)
	if slot >= int(o.n_same) {
		n := slot + 1
		s := ([^]wj.JSValue)(wj.libc_realloc(o.same, uint(n) * size_of(wj.JSValue)))
		if s == nil { wj.JS_ThrowOutOfMemory(ctx); return false }
		for i in int(o.n_same) ..< n { s[i] = wj.UNDEFINED }
		o.same = s
		o.n_same = u16(n)
	}
	if !wj.is_object(o.same[slot]) {
		wj.JS_FreeValue(ctx, o.same[slot])
		o.same[slot] = wj.JS_NewArray(ctx)
	}
	arr := o.same[slot]
	n: i64
	wj.JS_GetLength(ctx, arr, &n)
	for i in 0 ..< n {
		x := wj.JS_GetPropertyUint32(ctx, arr, u32(i))
		same := wj.same_ptr(x, observer)
		wj.JS_FreeValue(ctx, x)
		if same { return true }
	}
	return wj.array_set(ctx, arr, u32(n), wj.JS_DupValue(ctx, observer)) >= 0
}

@(private = "file")
observer_free :: proc "c" (p: rawptr) {
	context = jsb.glue_context()
	m := (^Observer)(p)
	rt := wj.JS_GetRuntime(wj.realm_ctx())
	if m.slot > 0 && int(m.slot) < len(observers) { observers[m.slot] = wj.UNDEFINED }
	if m.host != 0 { jsb.host(&none, api_decl.Object_release, wj.wr_Object_release, abi.Handle(m.host)) }
	wj.JS_FreeValueRT(rt, m.callback)
	wj.libc_free(m)
}

@(private = "file")
observer_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	wj.wj_mark(rt, (^Observer)(p).callback, mark_func)
}

@(private = "file")
observer_of :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Observer {
	o := wj.wj_this(ctx, this_val, ifc("MutationObserver"))
	if o == nil { return nil }
	if o.impl == nil || o.impl_free != observer_free { wj.JS_ThrowTypeError(ctx, "Illegal invocation"); return nil }
	return (^Observer)(o.impl)
}

@(export, link_name = "wjr_MutationObserver_constructor")
wjr_MutationObserver_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor MutationObserver requires 'new'") }
	if argc < 1 { return wj.wj_throw_arity(ctx, "MutationObserver", 1, argc) }
	if !wj.JS_IsFunction(ctx, argv[0]) {
		return wj.JS_ThrowTypeError(ctx, "Failed to construct 'MutationObserver': The callback provided as parameter 1 is not a function.")
	}
	if len(observers) == 0 { append(&observers, wj.UNDEFINED) }   // slot 0: none
	slot := 1
	for slot < len(observers) && !wj.is_undefined(observers[slot]) { slot += 1 }
	if slot >= len(observers) { append(&observers, wj.UNDEFINED) }
	m := (^Observer)(wj.libc_calloc(1, size_of(Observer)))
	if m == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	m.callback = wj.JS_DupValue(ctx, argv[0])
	m.slot = i32(slot)
	jsb.host(&m.host, api_decl.MutationObserver_create, wj.wr_MutationObserver_create, wj.table_index(rawptr(wj_cb_mutation)), m.slot)
	obj := wj.wj_new_object_for(ctx, ifc("MutationObserver"), new_target, m, observer_free)
	if wj.is_exception(obj) { return obj }
	wj.obj_of(obj).impl_mark = observer_mark
	m.self = obj
	observers[slot] = obj
	return obj
}

// childList, attributes, characterData, subtree, attributeOldValue, characterDataOldValue; attributeFilter is bit 6.
@(private = "file") Observe_Option :: enum u32 { Child_List, Attributes, Character_Data, Subtree, Attribute_Old_Value, Character_Data_Old_Value, Attribute_Filter }
@(private = "file") Observe_Options :: bit_set[Observe_Option; u32]

@(export, link_name = "wjr_MutationObserver_observe")
wjr_MutationObserver_observe :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	m := observer_of(ctx, this_val)
	if m == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "MutationObserver.observe", 1, argc) }
	target: u64
	if !wj.dom_node_arg(ctx, argv[0], &target, false, "observe") { return wj.EXCEPTION }
	opt := wj.arg(argc, argv, 1)
	flags := [?]cstring{"childList", "attributes", "characterData", "subtree", "attributeOldValue", "characterDataOldValue"}
	options: Observe_Options
	attributes_given, cdata_given: bool
	for i in 0 ..< len(flags) {
		which := Observe_Option(i)
		v := wj.dom_dict_get(ctx, opt, flags[i])
		if wj.is_exception(v) { return v }
		if which == .Attributes && !wj.is_undefined(v) { attributes_given = true }
		if which == .Character_Data && !wj.is_undefined(v) { cdata_given = true }
		if wj.JS_ToBool(ctx, v) != 0 { options += {which} }
		wj.JS_FreeValue(ctx, v)
	}
	filter := wj.dom_dict_get(ctx, opt, "attributeFilter")
	if wj.is_exception(filter) { return filter }
	defer wj.JS_FreeValue(ctx, filter)
	names: [dynamic]u8
	defer delete(names)
	if !wj.is_undefined(filter) {
		options += {.Attribute_Filter}
		n: i64
		if wj.JS_GetLength(ctx, filter, &n) < 0 { return wj.EXCEPTION }
		for i in 0 ..< n {
			s := wj.JS_GetPropertyUint32(ctx, filter, u32(i))
			c, text := to_text(ctx, s)
			wj.JS_FreeValue(ctx, s)
			if c == nil { return wj.EXCEPTION }
			if i > 0 { append(&names, 0) }
			append(&names, ..transmute([]u8)text)
			wj.JS_FreeCString(ctx, c)
		}
	}
	// DOM: attributeOldValue / attributeFilter imply attributes unless it is given false (TypeError then)
	if options & {.Attribute_Old_Value, .Attribute_Filter} != {} && attributes_given && .Attributes not_in options {
		return wj.JS_ThrowTypeError(ctx, "The options object may only set 'attributeOldValue' or 'attributeFilter' when 'attributes' is true or not present.")
	}
	if .Character_Data_Old_Value in options && cdata_given && .Character_Data not_in options {
		return wj.JS_ThrowTypeError(ctx, "The options object may only set 'characterDataOldValue' when 'characterData' is true or not present.")
	}
	if st := jsb.host(&none, api_decl.MutationObserver_observe, wj.wr_MutationObserver_observe, m.host, Node(target), transmute(u32)options, abi.Bytes(names[:])); st != .None {
		return wj.wj_throw_status(ctx, i32(st), "MutationObserver.observe")
	}
	return observer_attach(ctx, argv[0], this_val) ? wj.UNDEFINED : wj.EXCEPTION
}

@(export, link_name = "wjr_MutationObserver_disconnect")
wjr_MutationObserver_disconnect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	m := observer_of(ctx, this_val)
	if m == nil { return wj.EXCEPTION }
	jsb.host(&none, api_decl.MutationObserver_disconnect, wj.wr_MutationObserver_disconnect, m.host)
	return wj.UNDEFINED
}

// A MutationRecord's values.
@(private = "file") Record_Field :: enum { Type, Target, Added, Removed, Previous, Next, Name, Namespace, Old }
@(private = "file") RECORD_FIELDS :: len(Record_Field)

// A cursor over the browser's packed records (little endian); every read is bounds-checked, an overrun reads zeros.
@(private = "file")
Reader :: struct {
	data: []u8,
	at:   int,
	over: bool,
}

@(private = "file")
reader_take :: proc "contextless" (r: ^Reader, n: int) -> []u8 {
	if n < 0 || r.at + n > len(r.data) { r.over = true; return nil }
	s := r.data[r.at:][:n]
	r.at += n
	return s
}

@(private = "file")
reader_u32 :: proc "contextless" (r: ^Reader) -> u32 {
	b := reader_take(r, 4)
	return b != nil ? wj.read_u32(raw_data(b)) : 0
}

@(private = "file")
reader_u64 :: proc "contextless" (r: ^Reader) -> u64 {
	b := reader_take(r, 8)
	return b != nil ? wj.read_u64(raw_data(b)) : 0
}

// The records the observer has gathered, as an array of MutationRecord (an empty one when there are none). The record
// layout: kind u8, target u64, previous u64, next u64, added u32, removed u32, the handles of the added then the removed
// nodes, name length u32 and name, old-value flag u8, old-value length u32 and old value.
@(private = "file")
take_records :: proc(ctx: ^wj.Context, m: ^Observer) -> wj.JSValue {
	defer jsb.host(&none, api_decl.MutationObserver_release, wj.wr_MutationObserver_release, m.host)
	packed: abi.Bytes
	jsb.host(&packed, api_decl.MutationObserver_takeRecords, wj.wr_MutationObserver_takeRecords, m.host)
	arr := wj.JS_NewArray(ctx)
	if len(packed) == 0 { return arr }
	data := make([]u8, len(packed), wj.libc_allocator())   // the scratch buffer is reused by every host call below
	if data == nil { wj.JS_FreeValue(ctx, arr); return wj.JS_ThrowOutOfMemory(ctx) }
	defer delete(data, wj.libc_allocator())
	copy(data, ([]u8)(packed))
	TYPES := [3]cstring{"attributes", "characterData", "childList"}
	r := Reader{data = data}
	k: u32
	for r.at + 33 <= len(data) {
		kind := reader_take(&r, 1)[0]
		target, prev, next := reader_u64(&r), reader_u64(&r), reader_u64(&r)
		added, removed := int(reader_u32(&r)), int(reader_u32(&r))
		// counts from the buffer must not wrap around
		if len(data) - r.at < (added + removed) * 8 + 9 { break }
		d: ^wj.Dom_Impl
		rec := wj.dom_new(ctx, ifc("MutationRecord"), wj.DOM_VALUES, wj.UNDEFINED, 0, &d)
		if wj.is_exception(rec) { break }
		d.values = ([^]wj.JSValue)(wj.libc_calloc(RECORD_FIELDS, size_of(wj.JSValue)))
		if d.values == nil { wj.JS_FreeValue(ctx, rec); break }
		d.n_values = RECORD_FIELDS
		d.values[int(Record_Field.Type)] = wj.new_string(ctx, TYPES[kind < 3 ? kind : 2])
		d.values[int(Record_Field.Target)] = wj.wj_wrap_node(ctx, target)
		hs := ([^]u64)(wj.libc_malloc(uint(added + removed + 1) * 8))
		for i in 0 ..< added + removed { if hs != nil { hs[i] = reader_u64(&r) } else { reader_take(&r, 8) } }
		d.values[int(Record_Field.Added)] = dom_static_list_of_or_empty(ctx, hs, added, 0)
		d.values[int(Record_Field.Removed)] = dom_static_list_of_or_empty(ctx, hs, removed, added)
		wj.libc_free(hs)
		d.values[int(Record_Field.Previous)] = wj.wj_wrap_node(ctx, prev)
		d.values[int(Record_Field.Next)] = wj.wj_wrap_node(ctx, next)
		name_len := int(reader_u32(&r))
		if len(data) - r.at < name_len + 5 { wj.JS_FreeValue(ctx, rec); break }
		name := reader_take(&r, name_len)
		d.values[int(Record_Field.Name)] = kind == 0 ? wj.new_string_len(ctx, name) : wj.NULL
		d.values[int(Record_Field.Namespace)] = wj.NULL
		has_old := reader_take(&r, 1)[0] != 0
		old_len := int(reader_u32(&r))
		if len(data) - r.at < old_len { wj.JS_FreeValue(ctx, rec); break }
		old := reader_take(&r, old_len)
		d.values[int(Record_Field.Old)] = has_old ? wj.new_string_len(ctx, old) : wj.NULL
		wj.array_set(ctx, arr, k, rec)
		k += 1
	}
	return arr
}

// A static NodeList of `count` of the handles at hs[first:] (an empty one when the handles could not be read).
@(private = "file")
dom_static_list_of_or_empty :: proc "contextless" (ctx: ^wj.Context, hs: [^]u64, count, first: int) -> wj.JSValue {
	if hs == nil { return wj.dom_static_list_of(ctx, nil, 0) }
	return wj.dom_static_list_of(ctx, ([^]u64)(&hs[first]), u32(count))
}

@(export, link_name = "wjr_MutationObserver_takeRecords")
wjr_MutationObserver_takeRecords :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	m := observer_of(ctx, this_val)
	return m != nil ? take_records(ctx, m) : wj.EXCEPTION
}

// The notification microtask of an observer (DOM "notify mutation observers").
@(export, link_name = "wj_cb_mutation")
wj_cb_mutation :: proc "c" (user: i32) {
	context = m4_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	if user <= 0 || int(user) >= len(observers) || wj.is_undefined(observers[user]) { return }
	self := wj.JS_DupValue(ctx, observers[user])
	defer wj.JS_FreeValue(ctx, self)
	m := (^Observer)(wj.obj_of(self).impl)
	records := take_records(ctx, m)
	if wj.is_exception(records) { wj.wj_report_pending(ctx); return }
	defer wj.JS_FreeValue(ctx, records)
	n: i64
	wj.JS_GetLength(ctx, records, &n)
	if n > 0 {
		args := [2]wj.JSValue{records, self}
		r := wj.JS_Call(ctx, m.callback, self, 2, &args[0])
		if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
	}
}

// The browser queues the notification of an observer as a job of the engine (a microtask in the order of the promise
// reactions around it, as DOM queues it): the job delivers the records.
@(private = "file")
observer_job :: proc "c" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	user: i32
	if argc > 0 { wj.JS_ToInt32(ctx, &user, argv[0]) }
	wj_cb_mutation(user)
	return wj.UNDEFINED
}

@(export, link_name = "wj_mo_queue")
wj_mo_queue :: proc "c" (user: i32) {
	ctx := wj.realm_ctx()
	arg := wj.new_int32(user)
	wj.JS_EnqueueJob(ctx, observer_job, 1, &arg)
}

@(private = "file")
record_field :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, field: Record_Field) -> wj.JSValue {
	d := wj.dom_impl_of(ctx, this_val, ifc("MutationRecord"))
	if d == nil { return wj.EXCEPTION }
	return int(field) < int(d.n_values) ? wj.JS_DupValue(ctx, d.values[int(field)]) : wj.NULL
}

@(export, link_name = "wjr_MutationRecord_get_type")              wjr_MutationRecord_get_type              :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return record_field(ctx, t, .Type) }
@(export, link_name = "wjr_MutationRecord_get_target")            wjr_MutationRecord_get_target            :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return record_field(ctx, t, .Target) }
@(export, link_name = "wjr_MutationRecord_get_addedNodes")        wjr_MutationRecord_get_addedNodes        :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return record_field(ctx, t, .Added) }
@(export, link_name = "wjr_MutationRecord_get_removedNodes")      wjr_MutationRecord_get_removedNodes      :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return record_field(ctx, t, .Removed) }
@(export, link_name = "wjr_MutationRecord_get_previousSibling")   wjr_MutationRecord_get_previousSibling   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return record_field(ctx, t, .Previous) }
@(export, link_name = "wjr_MutationRecord_get_nextSibling")       wjr_MutationRecord_get_nextSibling       :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return record_field(ctx, t, .Next) }
@(export, link_name = "wjr_MutationRecord_get_attributeName")     wjr_MutationRecord_get_attributeName     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return record_field(ctx, t, .Name) }
@(export, link_name = "wjr_MutationRecord_get_attributeNamespace") wjr_MutationRecord_get_attributeNamespace :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return record_field(ctx, t, .Namespace) }
@(export, link_name = "wjr_MutationRecord_get_oldValue")          wjr_MutationRecord_get_oldValue          :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return record_field(ctx, t, .Old) }

// ---- TreeWalker and NodeIterator (DOM 6) ----

@(private = "file") Traversal_Field :: enum { Root, Filter, Current }
@(private = "file") TRAVERSAL_FIELDS :: len(Traversal_Field)

// NodeFilter's results.
@(private = "file") Filter_Result :: enum i32 { Accept = 1, Reject = 2, Skip = 3 }

// A traversal's numbers (rect): whatToShow, the "active" flag, and the NodeIterator's pointerBeforeReference.
@(private = "file") SHOW :: 0
@(private = "file") ACTIVE :: 1
@(private = "file") BEFORE :: 2

@(private = "file")
traversal_of :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32) -> ^wj.Dom_Impl {
	return wj.dom_impl_of(ctx, this_val, iface)
}

// DOM "filter": the node's verdict; false with an exception pending.
@(private = "file")
filter_node :: proc(ctx: ^wj.Context, d: ^wj.Dom_Impl, node: Node) -> (Filter_Result, bool) {
	type := node_type(node)
	show := u32(d.rect[SHOW])
	if type <= 0 || show & (1 << u32(type - 1)) == 0 { return .Skip, true }
	f := d.values[int(Traversal_Field.Filter)]
	if wj.is_null(f) || wj.is_undefined(f) { return .Accept, true }
	if d.rect[ACTIVE] != 0 {
		wj.wj_throw_dom(ctx, "InvalidStateError", "The filter is already running.")
		return .Skip, false
	}
	d.rect[ACTIVE] = 1
	n := wj.wj_wrap_node(ctx, u64(node))
	r: wj.JSValue
	if wj.JS_IsFunction(ctx, f) {
		r = wj.JS_Call(ctx, f, wj.UNDEFINED, 1, &n)
	} else {
		m := wj.JS_GetPropertyStr(ctx, f, "acceptNode")
		if wj.is_exception(m) {
			r = m
		} else if !wj.JS_IsFunction(ctx, m) {
			wj.JS_FreeValue(ctx, m)
			r = wj.JS_ThrowTypeError(ctx, "the filter has no acceptNode method")
		} else {
			r = wj.JS_Call(ctx, m, f, 1, &n)
			wj.JS_FreeValue(ctx, m)
		}
	}
	d.rect[ACTIVE] = 0
	wj.JS_FreeValue(ctx, n)
	if wj.is_exception(r) { return .Skip, false }
	v: u32
	ok := wj.wj_to_uint32(ctx, r, &v, 16, 0)
	wj.JS_FreeValue(ctx, r)
	return Filter_Result(v), ok
}

@(private = "file")
traversal_new :: proc(ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, iface: i32, what: cstring) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, ifc("Document")) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, what, 1, argc) }
	root: u64
	if !wj.dom_node_arg(ctx, argv[0], &root, false, what) { return wj.EXCEPTION }
	show := u32(0xFFFF_FFFF)
	if argc > 1 && !wj.is_undefined(argv[1]) && !wj.wj_to_uint32(ctx, argv[1], &show, 32, 0) { return wj.EXCEPTION }
	filter := wj.arg(argc, argv, 2)
	if !wj.is_null(filter) && !wj.is_undefined(filter) && !wj.is_object(filter) {
		return wj.JS_ThrowTypeError(ctx, "The filter is not a NodeFilter.")
	}
	d: ^wj.Dom_Impl
	obj := wj.dom_new(ctx, iface, wj.DOM_VALUES, wj.UNDEFINED, root, &d)
	if wj.is_exception(obj) { return obj }
	d.values = ([^]wj.JSValue)(wj.libc_calloc(TRAVERSAL_FIELDS, size_of(wj.JSValue)))
	if d.values == nil { wj.JS_FreeValue(ctx, obj); return wj.JS_ThrowOutOfMemory(ctx) }
	d.n_values = TRAVERSAL_FIELDS
	d.values[int(Traversal_Field.Root)] = wj.JS_DupValue(ctx, argv[0])
	d.values[int(Traversal_Field.Filter)] = wj.is_object(filter) ? wj.JS_DupValue(ctx, filter) : wj.NULL
	d.values[int(Traversal_Field.Current)] = wj.JS_DupValue(ctx, argv[0])
	d.rect[SHOW] = f64(show)
	d.rect[BEFORE] = 1
	return obj
}

@(export, link_name = "wjr_Document_createTreeWalker")
wjr_Document_createTreeWalker :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	return traversal_new(ctx, this_val, argc, argv, ifc("TreeWalker"), "createTreeWalker")
}
@(export, link_name = "wjr_Document_createNodeIterator")
wjr_Document_createNodeIterator :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	return traversal_new(ctx, this_val, argc, argv, ifc("NodeIterator"), "createNodeIterator")
}

@(private = "file")
traversal_field :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, iface: i32, field: Traversal_Field) -> wj.JSValue {
	d := traversal_of(ctx, t, iface)
	return d != nil ? wj.JS_DupValue(ctx, d.values[int(field)]) : wj.EXCEPTION
}

@(private = "file")
traversal_show :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, iface: i32) -> wj.JSValue {
	d := traversal_of(ctx, t, iface)
	return d != nil ? wj.new_uint32(ctx, u32(d.rect[SHOW])) : wj.EXCEPTION
}

@(export, link_name = "wjr_TreeWalker_get_root")        wjr_TreeWalker_get_root        :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return traversal_field(ctx, t, ifc("TreeWalker"), .Root) }
@(export, link_name = "wjr_TreeWalker_get_filter")      wjr_TreeWalker_get_filter      :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return traversal_field(ctx, t, ifc("TreeWalker"), .Filter) }
@(export, link_name = "wjr_TreeWalker_get_currentNode") wjr_TreeWalker_get_currentNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return traversal_field(ctx, t, ifc("TreeWalker"), .Current) }
@(export, link_name = "wjr_TreeWalker_get_whatToShow")  wjr_TreeWalker_get_whatToShow  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return traversal_show(ctx, t, ifc("TreeWalker")) }
@(export, link_name = "wjr_NodeIterator_get_root")          wjr_NodeIterator_get_root          :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return traversal_field(ctx, t, ifc("NodeIterator"), .Root) }
@(export, link_name = "wjr_NodeIterator_get_filter")        wjr_NodeIterator_get_filter        :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return traversal_field(ctx, t, ifc("NodeIterator"), .Filter) }
@(export, link_name = "wjr_NodeIterator_get_referenceNode") wjr_NodeIterator_get_referenceNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return traversal_field(ctx, t, ifc("NodeIterator"), .Current) }
@(export, link_name = "wjr_NodeIterator_get_whatToShow")    wjr_NodeIterator_get_whatToShow    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return traversal_show(ctx, t, ifc("NodeIterator")) }

@(export, link_name = "wjr_NodeIterator_get_pointerBeforeReferenceNode")
wjr_NodeIterator_get_pointerBeforeReferenceNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	d := traversal_of(ctx, t, ifc("NodeIterator"))
	return d != nil ? wj.new_bool(d.rect[BEFORE] != 0) : wj.EXCEPTION
}

@(export, link_name = "wjr_NodeIterator_detach")
wjr_NodeIterator_detach :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return traversal_of(ctx, t, ifc("NodeIterator")) != nil ? wj.UNDEFINED : wj.EXCEPTION
}

@(export, link_name = "wjr_TreeWalker_set_currentNode")
wjr_TreeWalker_set_currentNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	d := traversal_of(ctx, t, ifc("TreeWalker"))
	if d == nil { return wj.EXCEPTION }
	h: u64
	if !wj.dom_node_arg(ctx, v, &h, false, "currentNode") { return wj.EXCEPTION }
	wj.JS_FreeValue(ctx, d.values[int(Traversal_Field.Current)])
	d.values[int(Traversal_Field.Current)] = wj.JS_DupValue(ctx, v)
	return wj.UNDEFINED
}

// Makes `h` the current node and returns its wrapper.
@(private = "file")
set_current :: proc "contextless" (ctx: ^wj.Context, d: ^wj.Dom_Impl, h: Node) -> wj.JSValue {
	n := wj.wj_wrap_node(ctx, u64(h))
	if wj.is_exception(n) { return n }
	wj.JS_FreeValue(ctx, d.values[int(Traversal_Field.Current)])
	d.values[int(Traversal_Field.Current)] = wj.JS_DupValue(ctx, n)
	return n
}

@(private = "file") root_of_walk :: #force_inline proc "contextless" (d: ^wj.Dom_Impl) -> Node { return handle_of(d.values[int(Traversal_Field.Root)]) }
@(private = "file") current_of_walk :: #force_inline proc "contextless" (d: ^wj.Dom_Impl) -> Node { return handle_of(d.values[int(Traversal_Field.Current)]) }

@(export, link_name = "wjr_TreeWalker_parentNode")
wjr_TreeWalker_parentNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := traversal_of(ctx, t, ifc("TreeWalker"))
	if d == nil { return wj.EXCEPTION }
	root := root_of_walk(d)
	for node := current_of_walk(d); node != 0 && node != root; {
		node = parent_of(node)
		if node == 0 { break }
		r, ok := filter_node(ctx, d, node)
		if !ok { return wj.EXCEPTION }
		if r == .Accept { return set_current(ctx, d, node) }
	}
	return wj.NULL
}

// DOM "traverse children": the first or the last child.
@(private = "file")
walk_children :: proc(ctx: ^wj.Context, d: ^wj.Dom_Impl, first: bool) -> wj.JSValue {
	root := root_of_walk(d)
	parent := current_of_walk(d)
	node := first ? first_child(parent) : last_child(parent)
	for node != 0 {
		r, ok := filter_node(ctx, d, node)
		if !ok { return wj.EXCEPTION }
		if r == .Accept { return set_current(ctx, d, node) }
		if r == .Skip {
			if c := first ? first_child(node) : last_child(node); c != 0 { node = c; continue }
		}
		for node != 0 {
			if s := first ? next_sibling(node) : previous_sibling(node); s != 0 { node = s; break }
			p := parent_of(node)
			if p == 0 || p == root || p == parent { return wj.NULL }
			node = p
		}
	}
	return wj.NULL
}

// DOM "traverse siblings": the next or the previous.
@(private = "file")
walk_siblings :: proc(ctx: ^wj.Context, d: ^wj.Dom_Impl, next: bool) -> wj.JSValue {
	root := root_of_walk(d)
	node := current_of_walk(d)
	if node == root { return wj.NULL }
	for {
		s := next ? next_sibling(node) : previous_sibling(node)
		for s != 0 {
			node = s
			r, ok := filter_node(ctx, d, node)
			if !ok { return wj.EXCEPTION }
			if r == .Accept { return set_current(ctx, d, node) }
			s = next ? first_child(node) : last_child(node)
			if r == .Reject || s == 0 { s = next ? next_sibling(node) : previous_sibling(node) }
		}
		node = parent_of(node)
		if node == 0 || node == root { return wj.NULL }
		r, ok := filter_node(ctx, d, node)
		if !ok { return wj.EXCEPTION }
		if r == .Accept { return wj.NULL }
	}
}

@(private = "file")
walker_call :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, step: $F) -> wj.JSValue {
	context = jsb.glue_context()
	d := traversal_of(ctx, t, ifc("TreeWalker"))
	return d != nil ? step(ctx, d) : wj.EXCEPTION
}

@(export, link_name = "wjr_TreeWalker_firstChild")
wjr_TreeWalker_firstChild :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return walker_call(ctx, t, proc(ctx: ^wj.Context, d: ^wj.Dom_Impl) -> wj.JSValue { return walk_children(ctx, d, true) })
}
@(export, link_name = "wjr_TreeWalker_lastChild")
wjr_TreeWalker_lastChild :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return walker_call(ctx, t, proc(ctx: ^wj.Context, d: ^wj.Dom_Impl) -> wj.JSValue { return walk_children(ctx, d, false) })
}
@(export, link_name = "wjr_TreeWalker_nextSibling")
wjr_TreeWalker_nextSibling :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return walker_call(ctx, t, proc(ctx: ^wj.Context, d: ^wj.Dom_Impl) -> wj.JSValue { return walk_siblings(ctx, d, true) })
}
@(export, link_name = "wjr_TreeWalker_previousSibling")
wjr_TreeWalker_previousSibling :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return walker_call(ctx, t, proc(ctx: ^wj.Context, d: ^wj.Dom_Impl) -> wj.JSValue { return walk_siblings(ctx, d, false) })
}

@(export, link_name = "wjr_TreeWalker_previousNode")
wjr_TreeWalker_previousNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := traversal_of(ctx, t, ifc("TreeWalker"))
	if d == nil { return wj.EXCEPTION }
	root := root_of_walk(d)
	node := current_of_walk(d)
	for node != root {
		sib := previous_sibling(node)
		for sib != 0 {
			node = sib
			r, ok := filter_node(ctx, d, node)
			if !ok { return wj.EXCEPTION }
			for r != .Reject {
				lc := last_child(node)
				if lc == 0 { break }
				node = lc
				if r, ok = filter_node(ctx, d, node); !ok { return wj.EXCEPTION }
			}
			if r == .Accept { return set_current(ctx, d, node) }
			sib = previous_sibling(node)
		}
		p := parent_of(node)
		if node == root || p == 0 { return wj.NULL }
		node = p
		r, ok := filter_node(ctx, d, node)
		if !ok { return wj.EXCEPTION }
		if r == .Accept { return set_current(ctx, d, node) }
	}
	return wj.NULL
}

@(export, link_name = "wjr_TreeWalker_nextNode")
wjr_TreeWalker_nextNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := traversal_of(ctx, t, ifc("TreeWalker"))
	if d == nil { return wj.EXCEPTION }
	root := root_of_walk(d)
	node := current_of_walk(d)
	r := Filter_Result.Accept
	for {
		for r != .Reject {
			c := first_child(node)
			if c == 0 { break }
			node = c
			ok: bool
			if r, ok = filter_node(ctx, d, node); !ok { return wj.EXCEPTION }
			if r == .Accept { return set_current(ctx, d, node) }
		}
		sib: Node
		for tmp := node; tmp != 0; {
			if tmp == root { return wj.NULL }
			sib = next_sibling(tmp)
			if sib != 0 { node = sib; break }
			tmp = parent_of(tmp)
		}
		if sib == 0 { return wj.NULL }
		ok: bool
		if r, ok = filter_node(ctx, d, node); !ok { return wj.EXCEPTION }
		if r == .Accept { return set_current(ctx, d, node) }
	}
}

// The node after `h` in tree order inside `root`.
@(private = "file")
following :: proc(h, root: Node) -> Node {
	if c := first_child(h); c != 0 { return c }
	for n := h; n != 0 && n != root; n = parent_of(n) {
		if s := next_sibling(n); s != 0 { return s }
	}
	return 0
}

// The node before `h` in tree order inside `root`.
@(private = "file")
preceding :: proc(h, root: Node) -> Node {
	if h == root { return 0 }
	p := previous_sibling(h)
	if p == 0 { return parent_of(h) }
	for lc := last_child(p); lc != 0; lc = last_child(p) { p = lc }
	return p
}

// DOM "traverse" of a NodeIterator.
@(private = "file")
iterator_traverse :: proc(ctx: ^wj.Context, t: wj.JSValue, next: bool) -> wj.JSValue {
	d := traversal_of(ctx, t, ifc("NodeIterator"))
	if d == nil { return wj.EXCEPTION }
	root := root_of_walk(d)
	node := current_of_walk(d)
	before := d.rect[BEFORE] != 0
	for {
		if next {
			if !before { node = following(node, root); if node == 0 { return wj.NULL } } else { before = false }
		} else {
			if before { node = preceding(node, root); if node == 0 { return wj.NULL } } else { before = true }
		}
		r, ok := filter_node(ctx, d, node)
		if !ok { return wj.EXCEPTION }
		if r == .Accept { break }
	}
	d.rect[BEFORE] = before ? 1 : 0
	return set_current(ctx, d, node)
}

@(export, link_name = "wjr_NodeIterator_nextNode")
wjr_NodeIterator_nextNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return iterator_traverse(ctx, t, true)
}
@(export, link_name = "wjr_NodeIterator_previousNode")
wjr_NodeIterator_previousNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return iterator_traverse(ctx, t, false)
}

// ---- Range (DOM 5): boundary points kept as wrappers and offsets (not updated by later mutations) ----

@(private = "file") RG_START :: 0
@(private = "file") RG_END :: 1
@(private = "file") RANGE_VALUES :: 2

// A range of the boundary points (sc, so) and (ec, eo); takes sc and ec.
@(private = "file")
range_make :: proc "contextless" (ctx: ^wj.Context, new_target: wj.JSValue, sc: wj.JSValue, so: u32, ec: wj.JSValue, eo: u32, iface: i32) -> wj.JSValue {
	d: ^wj.Dom_Impl
	obj := wj.dom_new(ctx, iface, wj.DOM_VALUES, wj.UNDEFINED, 0, &d)
	if wj.is_exception(obj) { wj.free_values(ctx, sc, ec); return obj }
	d.values = ([^]wj.JSValue)(wj.libc_calloc(RANGE_VALUES, size_of(wj.JSValue)))
	if d.values == nil { wj.free_values(ctx, sc, ec, obj); return wj.JS_ThrowOutOfMemory(ctx) }
	d.n_values = RANGE_VALUES
	d.values[RG_START] = sc
	d.values[RG_END] = ec
	d.rect[RG_START] = f64(so)
	d.rect[RG_END] = f64(eo)
	// subclasses (new.target) get their prototype
	if wj.is_object(new_target) {
		proto := wj.JS_GetPropertyStr(ctx, new_target, "prototype")
		if wj.is_object(proto) { wj.JS_SetPrototype(ctx, obj, proto) }
		wj.JS_FreeValue(ctx, proto)
	}
	return obj
}

@(export, link_name = "wjr_Range_constructor")
wjr_Range_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor Range requires 'new'") }
	doc := global_prop(ctx, "document")
	return range_make(ctx, new_target, doc, 0, wj.JS_DupValue(ctx, doc), 0, ifc("Range"))
}

@(export, link_name = "wjr_Document_createRange")
wjr_Document_createRange :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, ifc("Document")) == nil { return wj.EXCEPTION }
	return range_make(ctx, wj.UNDEFINED, wj.JS_DupValue(ctx, this_val), 0, wj.JS_DupValue(ctx, this_val), 0, ifc("Range"))
}

@(private = "file")
range_of :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^wj.Dom_Impl {
	return wj.dom_impl_of(ctx, this_val, ifc("AbstractRange"))
}

// The boundary points of a range: the start and end containers and offsets.
@(private = "file") rs :: #force_inline proc "contextless" (d: ^wj.Dom_Impl) -> Node { return handle_of(d.values[RG_START]) }
@(private = "file") re :: #force_inline proc "contextless" (d: ^wj.Dom_Impl) -> Node { return handle_of(d.values[RG_END]) }
@(private = "file") rso :: #force_inline proc "contextless" (d: ^wj.Dom_Impl) -> u32 { return u32(d.rect[RG_START]) }
@(private = "file") reo :: #force_inline proc "contextless" (d: ^wj.Dom_Impl) -> u32 { return u32(d.rect[RG_END]) }

@(export, link_name = "wjr_AbstractRange_get_startContainer")
wjr_AbstractRange_get_startContainer :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	d := range_of(ctx, t)
	return d != nil ? wj.JS_DupValue(ctx, d.values[RG_START]) : wj.EXCEPTION
}
@(export, link_name = "wjr_AbstractRange_get_endContainer")
wjr_AbstractRange_get_endContainer :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	d := range_of(ctx, t)
	return d != nil ? wj.JS_DupValue(ctx, d.values[RG_END]) : wj.EXCEPTION
}
@(export, link_name = "wjr_AbstractRange_get_startOffset")
wjr_AbstractRange_get_startOffset :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	d := range_of(ctx, t)
	return d != nil ? wj.new_uint32(ctx, rso(d)) : wj.EXCEPTION
}
@(export, link_name = "wjr_AbstractRange_get_endOffset")
wjr_AbstractRange_get_endOffset :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	d := range_of(ctx, t)
	return d != nil ? wj.new_uint32(ctx, reo(d)) : wj.EXCEPTION
}
@(export, link_name = "wjr_AbstractRange_get_collapsed")
wjr_AbstractRange_get_collapsed :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	d := range_of(ctx, t)
	return d != nil ? wj.new_bool(rs(d) == re(d) && rso(d) == reo(d)) : wj.EXCEPTION
}

// Moves one boundary point (which: RG_START / RG_END) to `node` at `off`.
@(private = "file")
range_set :: proc "contextless" (ctx: ^wj.Context, d: ^wj.Dom_Impl, which: int, node: wj.JSValue, off: u32) {
	wj.JS_FreeValue(ctx, d.values[which])
	d.values[which] = wj.JS_DupValue(ctx, node)
	d.rect[which] = f64(off)
}

// DOM "set the start or end": the checks, and the other end follows when the range would be inverted.
@(private = "file")
range_set_bp :: proc(ctx: ^wj.Context, d: ^wj.Dom_Impl, node_v: wj.JSValue, off: u32, start: bool) -> wj.JSValue {
	node: u64
	if !wj.dom_node_arg(ctx, node_v, &node, false, start ? "setStart" : "setEnd") { return wj.EXCEPTION }
	n := Node(node)
	if node_type(n) == 10 { return wj.wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided is of type 'DocumentType'.") }
	if off > node_length(n) { return wj.wj_throw_dom(ctx, "IndexSizeError", "The offset is larger than the node's length.") }
	if start {
		other_root := root_of(n) != root_of(re(d))
		if other_root || compare_points(n, off, re(d), reo(d)) > 0 { range_set(ctx, d, RG_END, node_v, off) }
		range_set(ctx, d, RG_START, node_v, off)
	} else {
		other_root := root_of(n) != root_of(rs(d))
		if other_root || compare_points(n, off, rs(d), rso(d)) < 0 { range_set(ctx, d, RG_START, node_v, off) }
		range_set(ctx, d, RG_END, node_v, off)
	}
	return wj.UNDEFINED
}

@(private = "file")
range_bp_call :: proc(ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, start: bool) -> wj.JSValue {
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, start ? "Range.setStart" : "Range.setEnd", 2, argc) }
	off: u32
	if !wj.wj_to_uint32(ctx, argv[1], &off, 32, 0) { return wj.EXCEPTION }
	return range_set_bp(ctx, d, argv[0], off, start)
}

@(export, link_name = "wjr_Range_setStart")
wjr_Range_setStart :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return range_bp_call(ctx, t, argc, argv, true)
}
@(export, link_name = "wjr_Range_setEnd")
wjr_Range_setEnd :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return range_bp_call(ctx, t, argc, argv, false)
}

// setStartBefore / After, setEndBefore / After: around a node in its parent.
@(private = "file")
range_around :: proc(ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, start, after: bool) -> wj.JSValue {
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Range", 1, argc) }
	node: u64
	if !wj.dom_node_arg(ctx, argv[0], &node, false, "Range") { return wj.EXCEPTION }
	p := parent_of(Node(node))
	if p == 0 { return wj.wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided has no parent.") }
	pv := wj.wj_wrap_node(ctx, u64(p))
	r := range_set_bp(ctx, d, pv, index_in_parent(Node(node)) + (after ? 1 : 0), start)
	wj.JS_FreeValue(ctx, pv)
	return r
}

@(export, link_name = "wjr_Range_setStartBefore")
wjr_Range_setStartBefore :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return range_around(ctx, t, argc, argv, true, false)
}
@(export, link_name = "wjr_Range_setStartAfter")
wjr_Range_setStartAfter :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return range_around(ctx, t, argc, argv, true, true)
}
@(export, link_name = "wjr_Range_setEndBefore")
wjr_Range_setEndBefore :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return range_around(ctx, t, argc, argv, false, false)
}
@(export, link_name = "wjr_Range_setEndAfter")
wjr_Range_setEndAfter :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return range_around(ctx, t, argc, argv, false, true)
}

@(export, link_name = "wjr_Range_collapse")
wjr_Range_collapse :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	if argc > 0 && wj.JS_ToBool(ctx, argv[0]) != 0 {
		range_set(ctx, d, RG_END, d.values[RG_START], rso(d))
	} else {
		range_set(ctx, d, RG_START, d.values[RG_END], reo(d))
	}
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Range_selectNode")
wjr_Range_selectNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Range.selectNode", 1, argc) }
	node: u64
	if !wj.dom_node_arg(ctx, argv[0], &node, false, "selectNode") { return wj.EXCEPTION }
	p := parent_of(Node(node))
	if p == 0 { return wj.wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided has no parent.") }
	i := index_in_parent(Node(node))
	pv := wj.wj_wrap_node(ctx, u64(p))
	range_set(ctx, d, RG_START, pv, i)
	range_set(ctx, d, RG_END, pv, i + 1)
	wj.JS_FreeValue(ctx, pv)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Range_selectNodeContents")
wjr_Range_selectNodeContents :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Range.selectNodeContents", 1, argc) }
	node: u64
	if !wj.dom_node_arg(ctx, argv[0], &node, false, "selectNodeContents") { return wj.EXCEPTION }
	if node_type(Node(node)) == 10 { return wj.wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided is of type 'DocumentType'.") }
	range_set(ctx, d, RG_START, argv[0], 0)
	range_set(ctx, d, RG_END, argv[0], node_length(Node(node)))
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Range_get_commonAncestorContainer")
wjr_Range_get_commonAncestorContainer :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	ca, e := rs(d), re(d)
	for ca != 0 && !contains(ca, e) { ca = parent_of(ca) }
	return wj.wj_wrap_node(ctx, u64(ca))
}

@(export, link_name = "wjr_Range_cloneRange")
wjr_Range_cloneRange :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	return range_make(ctx, wj.UNDEFINED, wj.JS_DupValue(ctx, d.values[RG_START]), rso(d), wj.JS_DupValue(ctx, d.values[RG_END]), reo(d), ifc("Range"))
}

@(export, link_name = "wjr_Range_detach")
wjr_Range_detach :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return range_of(ctx, t) != nil ? wj.UNDEFINED : wj.EXCEPTION
}

@(export, link_name = "wjr_Range_compareBoundaryPoints")
wjr_Range_compareBoundaryPoints :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "Range.compareBoundaryPoints", 2, argc) }
	how: u32
	if !wj.wj_to_uint32(ctx, argv[0], &how, 16, 0) { return wj.EXCEPTION }
	if how > 3 {
		return wj.wj_throw_dom(ctx, "NotSupportedError", "The comparison method provided must be one of 'START_TO_START', 'START_TO_END', 'END_TO_END', or 'END_TO_START'.")
	}
	so := wj.wj_unwrap(argv[1], ifc("Range"))
	if so == nil || so.impl == nil { return wj.JS_ThrowTypeError(ctx, "parameter 2 is not of type 'Range'.") }
	s := (^wj.Dom_Impl)(so.impl)
	if root_of(rs(d)) != root_of(rs(s)) { return wj.wj_throw_dom(ctx, "WrongDocumentError", "The two Ranges are not in the same tree.") }
	a, b: Node
	ao, bo: u32
	switch how {
	case 0: a, ao, b, bo = rs(d), rso(d), rs(s), rso(s)   // START_TO_START
	case 1: a, ao, b, bo = re(d), reo(d), rs(s), rso(s)   // START_TO_END
	case 2: a, ao, b, bo = re(d), reo(d), re(s), reo(s)   // END_TO_END
	case: a, ao, b, bo = rs(d), rso(d), re(s), reo(s)     // END_TO_START
	}
	return wj.new_int32(compare_points(a, ao, b, bo))
}

// The checks the point methods share: the node and the offset, then the document the point is in.
@(private = "file")
point_args :: proc(ctx: ^wj.Context, argv: [^]wj.JSValue, what: cstring) -> (node: Node, off: u32, ok: bool) {
	h: u64
	if !wj.dom_node_arg(ctx, argv[0], &h, false, what) || !wj.wj_to_uint32(ctx, argv[1], &off, 32, 0) { return 0, 0, false }
	return Node(h), off, true
}

@(export, link_name = "wjr_Range_comparePoint")
wjr_Range_comparePoint :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "Range.comparePoint", 2, argc) }
	node, off, ok := point_args(ctx, argv, "comparePoint")
	if !ok { return wj.EXCEPTION }
	if root_of(node) != root_of(rs(d)) { return wj.wj_throw_dom(ctx, "WrongDocumentError", "The node provided and the Range are not in the same tree.") }
	if node_type(node) == 10 { return wj.wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided is of type 'DocumentType'.") }
	if off > node_length(node) { return wj.wj_throw_dom(ctx, "IndexSizeError", "The offset is larger than the node's length.") }
	if compare_points(node, off, rs(d), rso(d)) < 0 { return wj.new_int32(-1) }
	if compare_points(node, off, re(d), reo(d)) > 0 { return wj.new_int32(1) }
	return wj.new_int32(0)
}

@(export, link_name = "wjr_Range_isPointInRange")
wjr_Range_isPointInRange :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "Range.isPointInRange", 2, argc) }
	node, off, ok := point_args(ctx, argv, "isPointInRange")
	if !ok { return wj.EXCEPTION }
	if root_of(node) != root_of(rs(d)) { return wj.FALSE }
	if node_type(node) == 10 { return wj.wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided is of type 'DocumentType'.") }
	if off > node_length(node) { return wj.wj_throw_dom(ctx, "IndexSizeError", "The offset is larger than the node's length.") }
	return wj.new_bool(compare_points(node, off, rs(d), rso(d)) >= 0 && compare_points(node, off, re(d), reo(d)) <= 0)
}

@(export, link_name = "wjr_Range_intersectsNode")
wjr_Range_intersectsNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Range.intersectsNode", 1, argc) }
	h: u64
	if !wj.dom_node_arg(ctx, argv[0], &h, false, "intersectsNode") { return wj.EXCEPTION }
	node := Node(h)
	if root_of(node) != root_of(rs(d)) { return wj.FALSE }
	p := parent_of(node)
	if p == 0 { return wj.TRUE }
	i := index_in_parent(node)
	return wj.new_bool(compare_points(p, i, re(d), reo(d)) < 0 && compare_points(p, i + 1, rs(d), rso(d)) > 0)
}

@(export, link_name = "wjr_Range_toString")
wjr_Range_toString :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	text: string
	jsb.host(&text, api_decl.Range_text, wj.wr_Range_text, rs(d), rso(d), re(d), reo(d))
	return wj.new_string_len(ctx, text)
}

// The boundary point the range collapses to after its contents go (DOM "extract" steps 11-12).
@(private = "file")
collapse_point :: proc(sc: Node, so: u32, ec: Node) -> (node: Node, off: u32) {
	if contains(sc, ec) { return sc, so }
	ref := sc
	for parent_of(ref) != 0 && !contains(parent_of(ref), ec) { ref = parent_of(ref) }
	return parent_of(ref), index_in_parent(ref) + 1
}

// What range_contents does: clone the contents, extract them, or delete them.
@(private = "file") Contents_Mode :: enum i32 { Clone, Extract, Delete }

@(private = "file")
range_contents :: proc(ctx: ^wj.Context, t: wj.JSValue, mode: Contents_Mode) -> wj.JSValue {
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	cn: Node
	co: u32
	if mode != .Clone { cn, co = collapse_point(rs(d), rso(d), re(d)) }
	frag: Node
	if st := jsb.host(&frag, api_decl.Range_contents, wj.wr_Range_contents, rs(d), rso(d), re(d), reo(d), i32(mode)); st != .None {
		return wj.wj_throw_status(ctx, i32(st), "Range")
	}
	if mode != .Clone && cn != 0 {
		nv := wj.wj_wrap_node(ctx, u64(cn))
		range_set(ctx, d, RG_START, nv, co)
		range_set(ctx, d, RG_END, nv, co)
		wj.JS_FreeValue(ctx, nv)
	}
	if mode == .Delete { return wj.UNDEFINED }
	return wj.wj_wrap_node(ctx, u64(frag))
}

@(export, link_name = "wjr_Range_cloneContents")
wjr_Range_cloneContents :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return range_contents(ctx, t, .Clone)
}
@(export, link_name = "wjr_Range_extractContents")
wjr_Range_extractContents :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return range_contents(ctx, t, .Extract)
}
@(export, link_name = "wjr_Range_deleteContents")
wjr_Range_deleteContents :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return range_contents(ctx, t, .Delete)
}

@(private = "file")
range_insert :: proc(ctx: ^wj.Context, d: ^wj.Dom_Impl, node_v: wj.JSValue) -> wj.JSValue {
	h: u64
	if !wj.dom_node_arg(ctx, node_v, &h, false, "insertNode") { return wj.EXCEPTION }
	node := Node(h)
	sc := rs(d)
	st_type := node_type(sc)
	if st_type == 7 || st_type == 8 || (st_type == 3 && parent_of(sc) == 0) || sc == node {
		return wj.wj_throw_dom(ctx, "HierarchyRequestError", "The range's start cannot hold the node.")
	}
	ref := st_type == 3 ? sc : first_child(sc)
	if st_type != 3 {
		for i: u32 = 0; ref != 0 && i < rso(d); i += 1 { ref = next_sibling(ref) }
	}
	parent := ref != 0 ? parent_of(ref) : sc
	if st_type == 3 {
		tail: Node
		if s := jsb.host(&tail, api_decl.Text_splitText, wj.wr_Text_splitText, sc, rso(d)); s != .None {
			return wj.wj_throw_status(ctx, i32(s), "Range.insertNode")
		}
		ref = tail
	}
	if node == ref { ref = next_sibling(ref) }
	collapsed := rs(d) == re(d) && rso(d) == reo(d)
	add := node_type(node) == 11 ? node_length(node) : 1
	if parent_of(node) != 0 { jsb.host(&none, api_decl.ChildNode_remove, wj.wr_ChildNode_remove, node) }
	new_off := ref != 0 ? index_in_parent(ref) : node_length(parent)
	if st := jsb.host(&none, api_decl.Node_preInsert, wj.wr_Node_preInsert, parent, node, ref); st != .None {
		return wj.wj_throw_status(ctx, i32(st), "Range.insertNode")
	}
	if collapsed {
		pv := wj.wj_wrap_node(ctx, u64(parent))
		range_set(ctx, d, RG_END, pv, new_off + add)
		wj.JS_FreeValue(ctx, pv)
	}
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Range_insertNode")
wjr_Range_insertNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Range.insertNode", 1, argc) }
	return range_insert(ctx, d, argv[0])
}

@(export, link_name = "wjr_Range_surroundContents")
wjr_Range_surroundContents :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Range.surroundContents", 1, argc) }
	np: u64
	if !wj.dom_node_arg(ctx, argv[0], &np, false, "surroundContents") { return wj.EXCEPTION }
	if ty := node_type(Node(np)); ty == 9 || ty == 10 || ty == 11 {
		return wj.wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided cannot surround contents.")
	}
	frag := range_contents(ctx, t, .Extract)
	if wj.is_exception(frag) { return frag }
	jsb.host(&none, api_decl.Node_set_textContent, wj.wr_Node_set_textContent, Node(np), "")
	st := jsb.host(&none, api_decl.Node_preInsert, wj.wr_Node_preInsert, Node(np), handle_of(frag), Node(0))
	wj.JS_FreeValue(ctx, frag)
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "Range.surroundContents") }
	if r := range_insert(ctx, d, argv[0]); wj.is_exception(r) { return r }
	node_arg := [1]wj.JSValue{argv[0]}
	return wjr_Range_selectNode(ctx, t, 1, &node_arg[0])
}

@(export, link_name = "wjr_Range_getBoundingClientRect")
wjr_Range_getBoundingClientRect :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	r: wj.wr_DomRect
	wj.wr_Range_boundingRect(u64(rs(d)), rso(d), u64(re(d)), reo(d), &r)
	return dom_rect_new(ctx, r.x, r.y, r.width, r.height, false)
}

@(export, link_name = "wjr_Range_getClientRects")
wjr_Range_getClientRects :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	rects: abi.Bytes
	jsb.host(&rects, api_decl.Range_clientRectsPacked, wj.wr_Range_clientRectsPacked, rs(d), rso(d), re(d), reo(d))
	return dom_rect_list(ctx, raw_data(rects), u32(len(rects) / 32))
}

// createContextualFragment(markup): the browser parses it in the context of the start node's element (a <body>
// otherwise) and leaves its scripts runnable once inserted.
@(export, link_name = "wjr_Range_createContextualFragment")
wjr_Range_createContextualFragment :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := range_of(ctx, t)
	if d == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Range.createContextualFragment", 1, argc) }
	s: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &s, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	frag: Node
	if st := jsb.host(&frag, api_decl.Range_createContextualFragment, wj.wr_Range_createContextualFragment, rs(d), str_view(s)); st != .None {
		return wj.wj_throw_status(ctx, i32(st), "Range.createContextualFragment")
	}
	return wj.wj_wrap_node(ctx, u64(frag))
}

// StaticRange(init)
@(export, link_name = "wjr_StaticRange_constructor")
wjr_StaticRange_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor StaticRange requires 'new'") }
	init := wj.arg(argc, argv, 0)
	names := [4]cstring{"startContainer", "startOffset", "endContainer", "endOffset"}
	v: [4]wj.JSValue
	for i in 0 ..< 4 {
		v[i] = wj.dom_dict_get(ctx, init, names[i])
		if wj.is_exception(v[i]) {
			for k in 0 ..< i { wj.JS_FreeValue(ctx, v[k]) }
			return wj.EXCEPTION
		}
	}
	a, b: u64
	ao, bo: u32
	ok := wj.dom_node_arg(ctx, v[0], &a, false, "StaticRange") && wj.dom_node_arg(ctx, v[2], &b, false, "StaticRange") &&
		wj.wj_to_uint32(ctx, v[1], &ao, 32, 0) && wj.wj_to_uint32(ctx, v[3], &bo, 32, 0)
	if ok {
		ta, tb := node_type(Node(a)), node_type(Node(b))
		if ta == 10 || ta == 2 || tb == 10 || tb == 2 {
			wj.wj_throw_dom(ctx, "InvalidNodeTypeError", "A StaticRange cannot start or end in a doctype or an attribute.")
			ok = false
		}
	}
	wj.free_values(ctx, v[1], v[3])
	if !ok { wj.free_values(ctx, v[0], v[2]); return wj.EXCEPTION }
	return range_make(ctx, new_target, v[0], ao, v[2], bo, ifc("StaticRange"))
}

// ---- Selection (one per realm: the document's) ----

@(private = "file") the_selection := wj.UNDEFINED

@(private = "file")
selection_object :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	if wj.is_undefined(the_selection) {
		the_selection = wj.dom_new(ctx, ifc("Selection"), wj.DOM_VALUES, wj.UNDEFINED, 0, nil)
		if wj.is_exception(the_selection) {
			e := the_selection
			the_selection = wj.UNDEFINED
			return e
		}
	}
	return wj.JS_DupValue(ctx, the_selection)
}

@(export, link_name = "wjr_Window_getSelection")
wjr_Window_getSelection :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return selection_object(ctx) }
@(export, link_name = "wjr_Document_getSelection")
wjr_Document_getSelection :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.wj_this(ctx, t, ifc("Document")) != nil ? selection_object(ctx) : wj.EXCEPTION
}

// The browser's selection state (kind 0 none, 1 caret, 2 range), for `this` a Selection.
@(private = "file")
selection_state :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue) -> (s: wj.wr_SelectionState, ok: bool) {
	if wj.wj_this(ctx, t, ifc("Selection")) == nil { return {}, false }
	wj.wr_Selection_state(&s)
	return s, true
}

@(export, link_name = "wjr_Selection_get_anchorNode")
wjr_Selection_get_anchorNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	s, ok := selection_state(ctx, t)
	return ok ? wj.wj_wrap_node(ctx, s.anchor) : wj.EXCEPTION
}
@(export, link_name = "wjr_Selection_get_anchorOffset")
wjr_Selection_get_anchorOffset :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	s, ok := selection_state(ctx, t)
	return ok ? wj.new_uint32(ctx, s.anchor_offset) : wj.EXCEPTION
}
@(export, link_name = "wjr_Selection_get_focusNode")
wjr_Selection_get_focusNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	s, ok := selection_state(ctx, t)
	return ok ? wj.wj_wrap_node(ctx, s.focus) : wj.EXCEPTION
}
@(export, link_name = "wjr_Selection_get_focusOffset")
wjr_Selection_get_focusOffset :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	s, ok := selection_state(ctx, t)
	return ok ? wj.new_uint32(ctx, s.focus_offset) : wj.EXCEPTION
}
@(export, link_name = "wjr_Selection_get_isCollapsed")
wjr_Selection_get_isCollapsed :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	s, ok := selection_state(ctx, t)
	return ok ? wj.new_bool(s.kind != 2) : wj.EXCEPTION
}
@(export, link_name = "wjr_Selection_get_rangeCount")
wjr_Selection_get_rangeCount :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	s, ok := selection_state(ctx, t)
	return ok ? wj.new_int32(s.kind != 0 ? 1 : 0) : wj.EXCEPTION
}
@(export, link_name = "wjr_Selection_get_type")
wjr_Selection_get_type :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	s, ok := selection_state(ctx, t)
	if !ok { return wj.EXCEPTION }
	return wj.new_string(ctx, s.kind == 0 ? "None" : s.kind == 1 ? "Caret" : "Range")
}

// Is the selection's anchor before (or at) its focus?
@(private = "file")
is_forward :: proc(s: wj.wr_SelectionState) -> bool {
	return compare_points(Node(s.anchor), s.anchor_offset, Node(s.focus), s.focus_offset) <= 0
}

// The selection's boundary points in tree order: start, start offset, end, end offset.
@(private = "file")
ordered :: proc(s: wj.wr_SelectionState) -> (a: u64, ao: u32, b: u64, bo: u32) {
	if is_forward(s) { return s.anchor, s.anchor_offset, s.focus, s.focus_offset }
	return s.focus, s.focus_offset, s.anchor, s.anchor_offset
}

@(export, link_name = "wjr_Selection_get_direction")
wjr_Selection_get_direction :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	s, ok := selection_state(ctx, t)
	if !ok { return wj.EXCEPTION }
	if s.kind != 2 { return wj.new_string(ctx, "none") }
	return wj.new_string(ctx, is_forward(s) ? "forward" : "backward")
}

// A Range of the selection (kind not 0).
@(private = "file")
selection_range :: proc(ctx: ^wj.Context, s: wj.wr_SelectionState) -> wj.JSValue {
	a, ao, b, bo := ordered(s)
	return range_make(ctx, wj.UNDEFINED, wj.wj_wrap_node(ctx, a), ao, wj.wj_wrap_node(ctx, b), bo, ifc("Range"))
}

@(export, link_name = "wjr_Selection_getRangeAt")
wjr_Selection_getRangeAt :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	s, ok := selection_state(ctx, t)
	if !ok { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Selection.getRangeAt", 1, argc) }
	i: u32
	if !wj.wj_to_uint32(ctx, argv[0], &i, 32, 0) { return wj.EXCEPTION }
	if s.kind == 0 || i != 0 { return wj.wj_throw_dom(ctx, "IndexSizeError", "The index is not in the allowed range.") }
	return selection_range(ctx, s)
}

@(private = "file")
selection_set :: proc(ctx: ^wj.Context, a: u64, ao: u32, f: u64, fo: u32) -> wj.JSValue {
	if st := jsb.host(&none, api_decl.Selection_setRange, wj.wr_Selection_setRange, Node(a), ao, Node(f), fo); st != .None {
		return wj.wj_throw_status(ctx, i32(st), "Selection")
	}
	return wj.UNDEFINED
}

@(private = "file")
selection_clear :: proc() { jsb.host(&none, api_decl.Selection_clear, wj.wr_Selection_clear) }

@(export, link_name = "wjr_Selection_addRange")
wjr_Selection_addRange :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	s, ok := selection_state(ctx, t)
	if !ok { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Selection.addRange", 1, argc) }
	ro := wj.wj_unwrap(argv[0], ifc("Range"))
	if ro == nil || ro.impl == nil { return wj.JS_ThrowTypeError(ctx, "parameter 1 is not of type 'Range'.") }
	if s.kind != 0 { return wj.UNDEFINED }
	d := (^wj.Dom_Impl)(ro.impl)
	return selection_set(ctx, u64(rs(d)), rso(d), u64(re(d)), reo(d))
}

@(export, link_name = "wjr_Selection_removeRange")
wjr_Selection_removeRange :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, t, ifc("Selection")) == nil { return wj.EXCEPTION }
	selection_clear()
	return wj.UNDEFINED
}
@(export, link_name = "wjr_Selection_removeAllRanges")
wjr_Selection_removeAllRanges :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return wjr_Selection_removeRange(ctx, t, argc, argv) }
@(export, link_name = "wjr_Selection_empty")
wjr_Selection_empty :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return wjr_Selection_removeRange(ctx, t, argc, argv) }

@(export, link_name = "wjr_Selection_collapse")
wjr_Selection_collapse :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, t, ifc("Selection")) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Selection.collapse", 1, argc) }
	if wj.is_null(argv[0]) { selection_clear(); return wj.UNDEFINED }
	n: u64
	off: u32
	if !wj.dom_node_arg(ctx, argv[0], &n, false, "collapse") { return wj.EXCEPTION }
	if argc > 1 && !wj.wj_to_uint32(ctx, argv[1], &off, 32, 0) { return wj.EXCEPTION }
	if node_type(Node(n)) == 10 { return wj.wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided is of type 'DocumentType'.") }
	return selection_set(ctx, n, off, n, off)
}
@(export, link_name = "wjr_Selection_setPosition")
wjr_Selection_setPosition :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return wjr_Selection_collapse(ctx, t, argc, argv) }

// collapseToStart / collapseToEnd.
@(private = "file")
selection_collapse_to :: proc(ctx: ^wj.Context, t: wj.JSValue, to_end: bool) -> wj.JSValue {
	s, ok := selection_state(ctx, t)
	if !ok { return wj.EXCEPTION }
	if s.kind == 0 { return wj.wj_throw_dom(ctx, "InvalidStateError", "There is no selection to collapse.") }
	a, ao, b, bo := ordered(s)
	return to_end ? selection_set(ctx, b, bo, b, bo) : selection_set(ctx, a, ao, a, ao)
}

@(export, link_name = "wjr_Selection_collapseToStart")
wjr_Selection_collapseToStart :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return selection_collapse_to(ctx, t, false)
}
@(export, link_name = "wjr_Selection_collapseToEnd")
wjr_Selection_collapseToEnd :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return selection_collapse_to(ctx, t, true)
}

@(export, link_name = "wjr_Selection_extend")
wjr_Selection_extend :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	s, ok := selection_state(ctx, t)
	if !ok { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Selection.extend", 1, argc) }
	if s.kind == 0 { return wj.wj_throw_dom(ctx, "InvalidStateError", "There is no selection to extend.") }
	n: u64
	off: u32
	if !wj.dom_node_arg(ctx, argv[0], &n, false, "extend") { return wj.EXCEPTION }
	if argc > 1 && !wj.wj_to_uint32(ctx, argv[1], &off, 32, 0) { return wj.EXCEPTION }
	return selection_set(ctx, s.anchor, s.anchor_offset, n, off)
}

@(export, link_name = "wjr_Selection_setBaseAndExtent")
wjr_Selection_setBaseAndExtent :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, t, ifc("Selection")) == nil { return wj.EXCEPTION }
	if argc < 4 { return wj.wj_throw_arity(ctx, "Selection.setBaseAndExtent", 4, argc) }
	a, f: u64
	ao, fo: u32
	if !wj.dom_node_arg(ctx, argv[0], &a, false, "setBaseAndExtent") || !wj.wj_to_uint32(ctx, argv[1], &ao, 32, 0) ||
		!wj.dom_node_arg(ctx, argv[2], &f, false, "setBaseAndExtent") || !wj.wj_to_uint32(ctx, argv[3], &fo, 32, 0) {
		return wj.EXCEPTION
	}
	return selection_set(ctx, a, ao, f, fo)
}

@(export, link_name = "wjr_Selection_selectAllChildren")
wjr_Selection_selectAllChildren :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, t, ifc("Selection")) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Selection.selectAllChildren", 1, argc) }
	n: u64
	if !wj.dom_node_arg(ctx, argv[0], &n, false, "selectAllChildren") { return wj.EXCEPTION }
	if node_type(Node(n)) == 10 { return wj.wj_throw_dom(ctx, "InvalidNodeTypeError", "The node provided is of type 'DocumentType'.") }
	return selection_set(ctx, n, 0, n, u32(node_length(Node(n))))
}

@(export, link_name = "wjr_Selection_deleteFromDocument")
wjr_Selection_deleteFromDocument :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	s, ok := selection_state(ctx, t)
	if !ok { return wj.EXCEPTION }
	if s.kind != 2 { return wj.UNDEFINED }
	r := selection_range(ctx, s)
	if wj.is_exception(r) { return r }
	defer wj.JS_FreeValue(ctx, r)
	return range_contents(ctx, r, .Delete)
}

@(export, link_name = "wjr_Selection_containsNode")
wjr_Selection_containsNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	s, ok := selection_state(ctx, t)
	if !ok { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Selection.containsNode", 1, argc) }
	h: u64
	if !wj.dom_node_arg(ctx, argv[0], &h, false, "containsNode") { return wj.EXCEPTION }
	if s.kind == 0 { return wj.FALSE }
	partial := argc > 1 && wj.JS_ToBool(ctx, argv[1]) != 0
	a, ao, b, bo := ordered(s)
	n := Node(h)
	p := parent_of(n)
	if p == 0 { return wj.FALSE }
	i := index_in_parent(n)
	if partial {
		return wj.new_bool(compare_points(p, i, Node(b), bo) < 0 && compare_points(p, i + 1, Node(a), ao) > 0)
	}
	return wj.new_bool(compare_points(p, i, Node(a), ao) >= 0 && compare_points(p, i + 1, Node(b), bo) <= 0)
}

@(export, link_name = "wjr_Selection_toString")
wjr_Selection_toString :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, t, ifc("Selection")) == nil { return wj.EXCEPTION }
	text: string
	jsb.host(&text, api_decl.Selection_text, wj.wr_Selection_text)
	return wj.new_string_len(ctx, text)
}

@(export, link_name = "wjr_Selection_modify")
wjr_Selection_modify :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.wj_this(ctx, t, ifc("Selection")) != nil ? wj.UNDEFINED : wj.EXCEPTION
}
