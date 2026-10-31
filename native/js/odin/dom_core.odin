// dom_core.odin: the DOM Standard's tree for JavaScript, the members whose IDL signature the generated glue cannot
// convert (unions, dictionaries, variadic node lists, sequences) or that make engine objects: the mutation methods with
// their exceptions, ParentNode / ChildNode, live and static node lists, Document's factories, the attributes of
// elements (NamedNodeMap, Attr), DOMTokenList, DOMStringMap. Ported from native/js/runtime/dom_core.c, same symbols and
// behaviour; the browser side is src/page/js_dom_*.odin.
//
// Every call into the browser names its declaration (native/js/odin_abi/api_decl/dom.odin) and the generated import
// that carries it; jsb lowers the arguments and raises the result. What is written here is behaviour: the Attr objects
// and their cache, the packing of variadic arguments, the choice between the page's document and a document of its
// own, the namespaces of attributes. The engine objects (lists, token lists...) and their helpers are wj.dom_*
// (wj/m1_dom.odin).
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") nothing: abi.Nothing

@(private = "file")
to_str :: #force_inline proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, s: ^wj.Str, flags: i32 = 0) -> bool {
	return wj.wj_to_str(ctx, v, s, flags, "")
}

// ---- node lists ----

// (contextless: a static list's length and items are the hot path of indexed loops; only a live one calls the browser)
@(private = "file")
list_length :: proc "contextless" (d: ^wj.Dom_Impl) -> u32 {
	if d.kind != wj.DOM_LIST_LIVE { return d.n }
	context = jsb.glue_context()
	n: u32
	jsb.host(&n, api_decl.Collection_length, wj.wr_Collection_length, api_decl.Collection(d.coll))
	return n
}

@(private = "file")
list_item :: proc "contextless" (d: ^wj.Dom_Impl, i: u32) -> u64 {
	if d.kind != wj.DOM_LIST_LIVE { return i < d.n ? d.nodes[i] : 0 }
	context = jsb.glue_context()
	h: api_decl.Node
	jsb.host(&h, api_decl.Collection_item, wj.wr_Collection_item, api_decl.Collection(d.coll), i)
	return u64(h)
}

@(private = "file")
list_of :: #force_inline proc "contextless" (obj: wj.JSValue) -> ^wj.Dom_Impl {
	return wj.dom_impl_any(obj, wj.DOM_LIST_LIVE, wj.DOM_LIST_STATIC)
}

@(export, link_name = "wjr_NodeList_length_hook")
wjr_NodeList_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 {
	d := list_of(obj)
	return d != nil ? list_length(d) : 0
}

@(export, link_name = "wjr_NodeList_index_get")
wjr_NodeList_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue {
	d := list_of(obj)
	h := d != nil ? list_item(d, index) : 0
	found^ = h != 0
	return h != 0 ? wj.wj_wrap_node(ctx, h) : wj.UNDEFINED
}

@(private = "file")
list_get_length :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32) -> wj.JSValue {
	d := wj.dom_impl_of(ctx, this_val, iface)
	return d != nil ? wj.new_uint32(ctx, list_length(d)) : wj.EXCEPTION
}

@(private = "file")
list_item_method :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, iface: i32, what: cstring) -> wj.JSValue {
	context = jsb.glue_context()
	d := wj.dom_impl_of(ctx, this_val, iface)
	if d == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, what, 1, argc) }
	i: u32
	if !wj.wj_to_uint32(ctx, argv[0], &i, 32, 0) { return wj.EXCEPTION }
	return wj.wj_wrap_node(ctx, list_item(d, i))
}

@(export, link_name = "wjr_NodeList_get_length")
wjr_NodeList_get_length :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return list_get_length(ctx, t, ifc("NodeList")) }
@(export, link_name = "wjr_NodeList_item")
wjr_NodeList_item :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return list_item_method(ctx, t, argc, argv, ifc("NodeList"), "NodeList.item") }
@(export, link_name = "wjr_HTMLCollection_length_hook")
wjr_HTMLCollection_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 { return wjr_NodeList_length_hook(ctx, obj) }
@(export, link_name = "wjr_HTMLCollection_index_get")
wjr_HTMLCollection_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue { return wjr_NodeList_index_get(ctx, obj, index, found) }
@(export, link_name = "wjr_HTMLCollection_get_length")
wjr_HTMLCollection_get_length :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return list_get_length(ctx, t, ifc("HTMLCollection")) }
@(export, link_name = "wjr_HTMLCollection_item")
wjr_HTMLCollection_item :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return list_item_method(ctx, t, argc, argv, ifc("HTMLCollection"), "HTMLCollection.item") }

// named properties: collection.name (the first element of that id or name)
@(export, link_name = "wjr_HTMLCollection_named_get")
wjr_HTMLCollection_named_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, name: [^]u8, n: uint, found: ^bool) -> wj.JSValue {
	context = jsb.glue_context()
	found^ = false
	d := wj.dom_impl_any(obj, wj.DOM_LIST_LIVE)
	if d == nil || n == 0 { return wj.UNDEFINED }
	h: api_decl.Node
	jsb.host(&h, api_decl.Collection_namedItem, wj.wr_Collection_namedItem, api_decl.Collection(d.coll), string(name[:n]))
	if h == 0 { return wj.UNDEFINED }
	found^ = true
	return wj.wj_wrap_node(ctx, u64(h))
}

@(export, link_name = "wjr_HTMLCollection_namedItem")
wjr_HTMLCollection_namedItem :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := wj.dom_impl_of(ctx, this_val, ifc("HTMLCollection"))
	if d == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "HTMLCollection.namedItem", 1, argc) }
	if d.kind != wj.DOM_LIST_LIVE { return wj.NULL }
	s: wj.Str
	if !to_str(ctx, argv[0], &s) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	h: api_decl.Node
	jsb.host(&h, api_decl.Collection_namedItem, wj.wr_Collection_namedItem, api_decl.Collection(d.coll), str_view(s))
	return wj.wj_wrap_node(ctx, u64(h))
}

// ---- Node ----

@(private = "file")
is_attr :: #force_inline proc "contextless" (v: wj.JSValue) -> bool { return wj.wj_unwrap(v, ifc("Attr")) != nil }

@(export, link_name = "wjr_Node_get_nodeType")
wjr_Node_get_nodeType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, ifc("Node"))
	if o == nil { return wj.EXCEPTION }
	// the wrapper's interface says it: no call to the browser (CDATASection before Text, which it inherits)
	kinds := [?]struct { iface, type: i32 }{
		{ifc("Element"), 1}, {ifc("Attr"), 2}, {ifc("CDATASection"), 4}, {ifc("Text"), 3},
		{ifc("ProcessingInstruction"), 7}, {ifc("Comment"), 8}, {ifc("Document"), 9},
		{ifc("DocumentType"), 10}, {ifc("DocumentFragment"), 11},
	}
	for k in kinds { if inherits(i32(o.iface), k.iface) { return wj.new_int32(k.type) } }
	t: i32
	jsb.host(&t, api_decl.Node_nodeType, wj.wr_Node_nodeType, api_decl.Node(o.handle))
	return wj.new_int32(t)
}

@(export, link_name = "wjr_Node_get_nodeName")
wjr_Node_get_nodeName :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, ifc("Node"))
	if o == nil { return wj.EXCEPTION }
	if is_attr(this_val) { return wj.new_string_len(ctx, wj.dom_name((^wj.Dom_Impl)(o.impl))) }
	s: string
	st := jsb.host(&s, api_decl.Node_nodeName, wj.wr_Node_nodeName, api_decl.Node(o.handle))
	return dom_str(ctx, s, st, false, "Node.nodeName")
}

// nodeValue and textContent: an Attr's value, else the browser's (null for the nodes that have none)
@(private = "file")
node_text_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, content: bool) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, ifc("Node"))
	if o == nil { return wj.EXCEPTION }
	if is_attr(this_val) { return attr_value(ctx, (^wj.Dom_Impl)(o.impl)) }
	s: string
	if content {
		st := jsb.host(&s, api_decl.Node_textContent, wj.wr_Node_textContent, api_decl.Node(o.handle))
		return dom_str(ctx, s, st, true, "Node.textContent")
	}
	st := jsb.host(&s, api_decl.Node_nodeValue, wj.wr_Node_nodeValue, api_decl.Node(o.handle))
	return dom_str(ctx, s, st, true, "Node.nodeValue")
}

@(private = "file")
node_text_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue, content: bool) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, ifc("Node"))
	if o == nil { return wj.EXCEPTION }
	if is_attr(this_val) { return attr_set_value(ctx, (^wj.Dom_Impl)(o.impl), v) }
	s: wj.Str
	if !to_str(ctx, v, &s, wj.STR_NULL_EMPTY) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	n := api_decl.Node(o.handle)
	if content {
		st := jsb.host(&nothing, api_decl.Node_set_textContent, wj.wr_Node_set_textContent, n, str_view(s))
		return st != .None ? wj.wj_throw_status(ctx, i32(st), "Node.textContent") : wj.UNDEFINED
	}
	st := jsb.host(&nothing, api_decl.Node_set_nodeValue, wj.wr_Node_set_nodeValue, n, str_view(s))
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "Node.nodeValue") : wj.UNDEFINED
}

@(export, link_name = "wjr_Node_get_nodeValue")
wjr_Node_get_nodeValue :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return node_text_get(ctx, t, false) }
@(export, link_name = "wjr_Node_set_nodeValue")
wjr_Node_set_nodeValue :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return node_text_set(ctx, t, v, false) }
@(export, link_name = "wjr_Node_get_textContent")
wjr_Node_get_textContent :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return node_text_get(ctx, t, true) }
@(export, link_name = "wjr_Node_set_textContent")
wjr_Node_set_textContent :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return node_text_set(ctx, t, v, true) }

@(export, link_name = "wjr_Node_get_childNodes")
wjr_Node_get_childNodes :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if is_attr(this_val) { return wj.dom_static_list_of(ctx, nil, 0) }
	h := node_this(ctx, this_val, ifc("Node"))
	if h == 0 { return wj.EXCEPTION }
	return wj.dom_live_list(ctx, this_val, h, 0, nil, 0, ifc("NodeList"))
}

// getRootNode({composed}): shadow.c

@(private = "file")
Mutation :: enum { Append, Insert_Before, Replace, Remove }

// appendChild / insertBefore / replaceChild / removeChild: the DOM Standard's checks are the browser's.
@(private = "file")
mutate :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, m: Mutation) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, ifc("Node"))
	if o == nil { return wj.EXCEPTION }
	parent := api_decl.Node(o.handle)
	node, child: u64
	st: abi.Api_Error
	switch m {
	case .Append:
		if argc < 1 { return wj.wj_throw_arity(ctx, "Node.appendChild", 1, argc) }
		if parent == 0 { return wj.wj_throw_dom(ctx, "HierarchyRequestError", "This node type does not support this method.") }
		if !wj.dom_node_arg(ctx, argv[0], &node, false, "appendChild") { return wj.EXCEPTION }
		st = jsb.host(&nothing, api_decl.Node_preInsert, wj.wr_Node_preInsert, parent, api_decl.Node(node), api_decl.Node(0))
		if st != .None { return wj.wj_throw_status(ctx, i32(st), "Node.appendChild") }
	case .Insert_Before:
		if argc < 2 { return wj.wj_throw_arity(ctx, "Node.insertBefore", 2, argc) }
		if !wj.dom_node_arg(ctx, argv[0], &node, false, "insertBefore") { return wj.EXCEPTION }
		if !wj.dom_node_arg(ctx, argv[1], &child, true, "insertBefore") { return wj.EXCEPTION }
		st = jsb.host(&nothing, api_decl.Node_preInsert, wj.wr_Node_preInsert, parent, api_decl.Node(node), api_decl.Node(child))
		if st != .None { return wj.wj_throw_status(ctx, i32(st), "Node.insertBefore") }
	case .Replace:
		if argc < 2 { return wj.wj_throw_arity(ctx, "Node.replaceChild", 2, argc) }
		if !wj.dom_node_arg(ctx, argv[0], &node, false, "replaceChild") { return wj.EXCEPTION }
		if !wj.dom_node_arg(ctx, argv[1], &child, false, "replaceChild") { return wj.EXCEPTION }
		st = jsb.host(&nothing, api_decl.Node_replaceChildChecked, wj.wr_Node_replaceChildChecked, parent, api_decl.Node(node), api_decl.Node(child))
		if st != .None { return wj.wj_throw_status(ctx, i32(st), "Node.replaceChild") }
		return wj.JS_DupValue(ctx, argv[1])
	case .Remove:
		if argc < 1 { return wj.wj_throw_arity(ctx, "Node.removeChild", 1, argc) }
		if !wj.dom_node_arg(ctx, argv[0], &child, false, "removeChild") { return wj.EXCEPTION }
		st = jsb.host(&nothing, api_decl.Node_preRemove, wj.wr_Node_preRemove, parent, api_decl.Node(child))
		if st != .None { return wj.wj_throw_status(ctx, i32(st), "Node.removeChild") }
	}
	return wj.JS_DupValue(ctx, argv[0])
}

@(export, link_name = "wjr_Node_appendChild")
wjr_Node_appendChild :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return mutate(ctx, t, argc, argv, .Append) }
@(export, link_name = "wjr_Node_insertBefore")
wjr_Node_insertBefore :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return mutate(ctx, t, argc, argv, .Insert_Before) }
@(export, link_name = "wjr_Node_replaceChild")
wjr_Node_replaceChild :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return mutate(ctx, t, argc, argv, .Replace) }
@(export, link_name = "wjr_Node_removeChild")
wjr_Node_removeChild :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return mutate(ctx, t, argc, argv, .Remove) }

// ---- ParentNode / ChildNode: (Node or DOMString)... packed for Node_insertItems ----

@(private = "file")
insert_items :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, mode: api_decl.InsertMode, what: cstring) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, ifc("Node"))
	if o == nil { return wj.EXCEPTION }
	b: Pack
	defer pack_free(&b)
	for i in 0 ..< argc {
		if n := wj.wj_unwrap(argv[i], ifc("Node")); n != nil && n.handle != 0 {
			if !pack_u8(&b, 0) || !pack_le(&b, n.handle, 8) { return wj.JS_ThrowOutOfMemory(ctx) }
			continue
		}
		s: wj.Str
		if !to_str(ctx, argv[i], &s) { return wj.EXCEPTION }
		ok := pack_u8(&b, 1) && pack_le(&b, u64(s.len), 4) && pack_bytes(&b, wj.str_slice(s))
		wj.wj_str_free(ctx, &s)
		if !ok { return wj.JS_ThrowOutOfMemory(ctx) }
	}
	st := jsb.host(&nothing, api_decl.Node_insertItems, wj.wr_Node_insertItems, api_decl.Node(o.handle), mode, abi.Bytes(pack_slice(&b)))
	return st != .None ? wj.wj_throw_status(ctx, i32(st), what) : wj.UNDEFINED
}

@(export, link_name = "wjr_ParentNode_prepend")
wjr_ParentNode_prepend :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return insert_items(ctx, t, argc, argv, .Prepend, "prepend") }
@(export, link_name = "wjr_ParentNode_append")
wjr_ParentNode_append :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return insert_items(ctx, t, argc, argv, .Append, "append") }
@(export, link_name = "wjr_ParentNode_replaceChildren")
wjr_ParentNode_replaceChildren :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return insert_items(ctx, t, argc, argv, .Replace_Children, "replaceChildren") }
@(export, link_name = "wjr_ChildNode_before")
wjr_ChildNode_before :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return insert_items(ctx, t, argc, argv, .Before, "before") }
@(export, link_name = "wjr_ChildNode_after")
wjr_ChildNode_after :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return insert_items(ctx, t, argc, argv, .After, "after") }
@(export, link_name = "wjr_ChildNode_replaceWith")
wjr_ChildNode_replaceWith :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return insert_items(ctx, t, argc, argv, .Replace_With, "replaceWith") }

// moveBefore(node, child): as insertBefore (the browser keeps no state that a move would preserve)
@(export, link_name = "wjr_ParentNode_moveBefore")
wjr_ParentNode_moveBefore :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	r := mutate(ctx, this_val, argc, argv, .Insert_Before)
	if wj.is_exception(r) { return r }
	wj.JS_FreeValue(ctx, r)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_ParentNode_get_children")
wjr_ParentNode_get_children :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	h := node_this(ctx, this_val, ifc("Node"))
	if h == 0 { return wj.EXCEPTION }
	return wj.dom_live_list(ctx, this_val, h, 1, nil, 0, ifc("HTMLCollection"))
}

@(export, link_name = "wjr_ParentNode_querySelectorAll")
wjr_ParentNode_querySelectorAll :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := node_this(ctx, this_val, ifc("Node"))
	if h == 0 { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "querySelectorAll", 1, argc) }
	s: wj.Str
	if !to_str(ctx, argv[0], &s) { return wj.EXCEPTION }
	packed: abi.Bytes
	st := jsb.host(&packed, api_decl.ParentNode_querySelectorAllPacked, wj.wr_ParentNode_querySelectorAllPacked, api_decl.Node(h), str_view(s))
	wj.wj_str_free(ctx, &s)
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "querySelectorAll") }
	return wj.dom_static_list(ctx, raw_data(packed), u32(len(packed) / 8))
}

// getElementsByTagName / ClassName / Name: live collections over the subtree (collection kinds of
// src/page/js_dom_collections.odin)
@(private = "file")
by_string :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, kind: i32, iface: i32, what: cstring) -> wj.JSValue {
	h := node_this(ctx, this_val, ifc("Node"))
	if h == 0 { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, what, 1, argc) }
	s: wj.Str
	if !to_str(ctx, argv[0], &s) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	return wj.dom_live_list(ctx, this_val, h, kind, s.ptr, s.len, iface)
}

// getElementsByTagNameNS: the filter is "namespace\0localName"
@(private = "file")
by_ns :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h := node_this(ctx, this_val, ifc("Node"))
	if h == 0 { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "getElementsByTagNameNS", 2, argc) }
	ns, local: wj.Str
	if !to_str(ctx, argv[0], &ns, wj.STR_NULLABLE) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &ns)
	if !to_str(ctx, argv[1], &local) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &local)
	b: Pack
	defer pack_free(&b)
	if !pack_bytes(&b, wj.str_slice(ns)) || !pack_u8(&b, 0) || !pack_bytes(&b, wj.str_slice(local)) { return wj.JS_ThrowOutOfMemory(ctx) }
	return wj.dom_live_list(ctx, this_val, h, 11, b.p, uint(b.n), ifc("HTMLCollection"))
}

@(export, link_name = "wjr_Document_getElementsByTagName")
wjr_Document_getElementsByTagName :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return by_string(ctx, t, argc, argv, 2, ifc("HTMLCollection"), "getElementsByTagName") }
@(export, link_name = "wjr_Element_getElementsByTagName")
wjr_Element_getElementsByTagName :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return by_string(ctx, t, argc, argv, 2, ifc("HTMLCollection"), "getElementsByTagName") }
@(export, link_name = "wjr_Document_getElementsByClassName")
wjr_Document_getElementsByClassName :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return by_string(ctx, t, argc, argv, 3, ifc("HTMLCollection"), "getElementsByClassName") }
@(export, link_name = "wjr_Element_getElementsByClassName")
wjr_Element_getElementsByClassName :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return by_string(ctx, t, argc, argv, 3, ifc("HTMLCollection"), "getElementsByClassName") }
@(export, link_name = "wjr_Document_getElementsByTagNameNS")
wjr_Document_getElementsByTagNameNS :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return by_ns(ctx, t, argc, argv) }
@(export, link_name = "wjr_Element_getElementsByTagNameNS")
wjr_Element_getElementsByTagNameNS :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return by_ns(ctx, t, argc, argv) }
@(export, link_name = "wjr_Document_getElementsByName")
wjr_Document_getElementsByName :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return by_string(ctx, t, argc, argv, 4, ifc("NodeList"), "getElementsByName") }

// A live collection of kind `kind` over `this` (an element of interface `iface`, or the document).
@(private = "file")
collection_of :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32, kind: i32) -> wj.JSValue {
	h := node_this(ctx, this_val, iface)
	if h == 0 { return wj.EXCEPTION }
	return wj.dom_live_list(ctx, this_val, h, kind, nil, 0, ifc("HTMLCollection"))
}

// document.all: the live collection of all elements, [IsHTMLDDA]: typeof "undefined", falsy and == null, but not ===
// undefined (Polymer-Resin's sanitizer tells a value from document.all by `v === document.all`: with an undefined
// document.all every undefined binding was taken for it, and YouTube's icons were hidden).
@(export, link_name = "wjr_Document_get_all")
wjr_Document_get_all :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	v := collection_of(ctx, this_val, ifc("Document"), 12)
	if wj.is_object(v) { wj.JS_SetIsHTMLDDA(ctx, v) }
	return v
}

@(export, link_name = "wjr_Document_get_forms")
wjr_Document_get_forms :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return collection_of(ctx, t, ifc("Document"), 5) }
@(export, link_name = "wjr_Document_get_images")
wjr_Document_get_images :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return collection_of(ctx, t, ifc("Document"), 6) }
@(export, link_name = "wjr_Document_get_links")
wjr_Document_get_links :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return collection_of(ctx, t, ifc("Document"), 7) }
@(export, link_name = "wjr_Document_get_scripts")
wjr_Document_get_scripts :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return collection_of(ctx, t, ifc("Document"), 8) }
@(export, link_name = "wjr_Document_get_embeds")
wjr_Document_get_embeds :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return collection_of(ctx, t, ifc("Document"), 9) }
@(export, link_name = "wjr_Document_get_plugins")
wjr_Document_get_plugins :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return collection_of(ctx, t, ifc("Document"), 9) }
@(export, link_name = "wjr_Document_get_anchors")
wjr_Document_get_anchors :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return collection_of(ctx, t, ifc("Document"), 10) }
@(export, link_name = "wjr_HTMLTableElement_get_rows")
wjr_HTMLTableElement_get_rows :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return collection_of(ctx, t, ifc("HTMLTableElement"), 14) }
@(export, link_name = "wjr_HTMLTableSectionElement_get_rows")
wjr_HTMLTableSectionElement_get_rows :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return collection_of(ctx, t, ifc("HTMLTableSectionElement"), 14) }
@(export, link_name = "wjr_HTMLTableRowElement_get_cells")
wjr_HTMLTableRowElement_get_cells :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return collection_of(ctx, t, ifc("HTMLTableRowElement"), 15) }
@(export, link_name = "wjr_HTMLTableElement_get_tBodies")
wjr_HTMLTableElement_get_tBodies :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return collection_of(ctx, t, ifc("HTMLTableElement"), 16) }

// ---- Document ----

@(private = "file")
page_document :: proc() -> api_decl.Document {
	d: api_decl.Document
	jsb.host(&d, api_decl.Window_document, wj.wr_Window_document)
	return d
}

@(export, link_name = "wjr_Document_createElement")
wjr_Document_createElement :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, this_val, ifc("Document")) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Document.createElement", 1, argc) }
	name: wj.Str
	if !to_str(ctx, argv[0], &name) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &name)
	doc := api_decl.Document(node_this(ctx, this_val, ifc("Document")))
	if doc == 0 { return wj.EXCEPTION }
	el: api_decl.Element
	st: abi.Api_Error
	if doc == page_document() {
		st = jsb.host(&el, api_decl.Document_createElementChecked, wj.wr_Document_createElementChecked, str_view(name))
	} else {
		// an XML document's element keeps its name's case; Not_Found: an HTML document of its own
		st = jsb.host(&el, api_decl.Document_createXMLElement, wj.wr_Document_createXMLElement, doc, Maybe(string)(nil), str_view(name), false)
		if st == .Not_Found { st = jsb.host(&el, api_decl.Document_createElementInert, wj.wr_Document_createElementInert, str_view(name)) }
	}
	return node_or_throw(ctx, el, st, "Document.createElement")
}

// getElementById(id): the page's document by the browser's id index; a document of its own (createHTMLDocument's,
// DOMParser's, createDocument's) in its own tree
@(export, link_name = "wjr_Document_getElementById")
wjr_Document_getElementById :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	doc := api_decl.Document(node_this(ctx, this_val, ifc("Document")))
	if doc == 0 { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Document.getElementById", 1, argc) }
	id: wj.Str
	if !to_str(ctx, argv[0], &id) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &id)
	el: api_decl.Element
	if doc == page_document() {
		jsb.host(&el, api_decl.Document_getElementById, wj.wr_Document_getElementById, str_view(id))
	} else {
		jsb.host(&el, api_decl.NonElementParentNode_getElementById, wj.wr_NonElementParentNode_getElementById, api_decl.Node(doc), str_view(id))
	}
	return wj.wj_wrap_node(ctx, u64(el))
}

// A namespace argument: null and "" are no namespace.
@(private = "file")
namespace_of :: #force_inline proc "contextless" (ns: wj.Str) -> Maybe(string) {
	if ns.ptr == nil || ns.len == 0 { return nil }
	return string(ns.ptr[:ns.len])
}

@(export, link_name = "wjr_Document_createElementNS")
wjr_Document_createElementNS :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, this_val, ifc("Document")) == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "Document.createElementNS", 2, argc) }
	ns, name: wj.Str
	if !to_str(ctx, argv[0], &ns, wj.STR_NULLABLE) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &ns)
	if !to_str(ctx, argv[1], &name) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &name)
	el: api_decl.Element
	doc := api_decl.Document(node_this(ctx, this_val, ifc("Document")))
	st := abi.Api_Error.Not_Found
	if doc != 0 && doc != page_document() {
		st = jsb.host(&el, api_decl.Document_createXMLElement, wj.wr_Document_createXMLElement, doc, namespace_of(ns), str_view(name), true)
	}
	if st == .Not_Found {
		st = jsb.host(&el, api_decl.Document_createElementNSChecked, wj.wr_Document_createElementNSChecked, namespace_of(ns), str_view(name))
	}
	return node_or_throw(ctx, el, st, "Document.createElementNS")
}

@(export, link_name = "wjr_Document_importNode")
wjr_Document_importNode :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, this_val, ifc("Document")) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Document.importNode", 1, argc) }
	node: u64
	if !wj.dom_node_arg(ctx, argv[0], &node, false, "importNode") { return wj.EXCEPTION }
	// (Node node, optional (boolean or ImportNodeOptions) options): {selfOnly} or the legacy `deep`
	opt := wj.arg(argc, argv, 1)
	deep: bool
	if wj.is_object(opt) {
		s := wj.JS_GetPropertyStr(ctx, opt, "selfOnly")
		if wj.is_exception(s) { return s }
		deep = wj.JS_ToBool(ctx, s) == 0
		wj.JS_FreeValue(ctx, s)
	} else {
		deep = wj.JS_ToBool(ctx, opt) != 0
	}
	h: api_decl.Node
	st := jsb.host(&h, api_decl.Document_importNodeCopy, wj.wr_Document_importNodeCopy, api_decl.Node(node), deep)
	return node_or_throw(ctx, h, st, "Document.importNode")
}

// The parts of a document: the page's, or one of createHTMLDocument (a document node of its own)
@(private = "file")
document_part :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, which: api_decl.DocumentPart) -> wj.JSValue {
	context = jsb.glue_context()
	h := node_this(ctx, this_val, ifc("Document"))
	if h == 0 { return wj.EXCEPTION }
	return wj.wj_wrap_node(ctx, u64(part_of(api_decl.Document(h), which)))
}

@(private = "file")
part_of :: proc(doc: api_decl.Document, which: api_decl.DocumentPart) -> api_decl.Node {
	n: api_decl.Node
	jsb.host(&n, api_decl.Document_partOf, wj.wr_Document_partOf, doc, which)
	return n
}

@(export, link_name = "wjr_Document_get_documentElement")
wjr_Document_get_documentElement :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return document_part(ctx, t, .Document_Element) }
@(export, link_name = "wjr_Document_get_head")
wjr_Document_get_head :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return document_part(ctx, t, .Head) }
@(export, link_name = "wjr_Document_get_body")
wjr_Document_get_body :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return document_part(ctx, t, .Body) }
@(export, link_name = "wjr_Document_get_doctype")
wjr_Document_get_doctype :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return document_part(ctx, t, .Doctype) }

@(export, link_name = "wjr_Document_set_body")
wjr_Document_set_body :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := api_decl.Document(node_this(ctx, this_val, ifc("Document")))
	if h == 0 { return wj.EXCEPTION }
	body: u64
	if !wj.dom_node_arg(ctx, v, &body, true, "body") { return wj.EXCEPTION }
	st: abi.Api_Error
	if h != page_document() {
		// another document node: its body replaced (or appended) like the page's
		old, de := part_of(h, .Body), part_of(h, .Document_Element)
		if old != 0 {
			parent: api_decl.Node
			jsb.host(&parent, api_decl.Node_parentNode, wj.wr_Node_parentNode, old)
			st = jsb.host(&nothing, api_decl.Node_replaceChildChecked, wj.wr_Node_replaceChildChecked, parent, api_decl.Node(body), old)
		} else if de != 0 {
			st = jsb.host(&nothing, api_decl.Node_preInsert, wj.wr_Node_preInsert, de, api_decl.Node(body), api_decl.Node(0))
		} else {
			st = .Hierarchy
		}
	} else {
		st = jsb.host(&nothing, api_decl.Document_set_body, wj.wr_Document_set_body, api_decl.Element(body))
	}
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "Document.body") : wj.UNDEFINED
}

// ---- DOMImplementation ----

@(export, link_name = "wjr_Document_get_implementation")
wjr_Document_get_implementation :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	h := node_this(ctx, this_val, ifc("Document"))
	if h == 0 { return wj.EXCEPTION }
	return wj.dom_new(ctx, ifc("DOMImplementation"), wj.DOM_VALUES, this_val, h, nil)
}

@(export, link_name = "wjr_DOMImplementation_createHTMLDocument")
wjr_DOMImplementation_createHTMLDocument :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.dom_impl_of(ctx, this_val, ifc("DOMImplementation")) == nil { return wj.EXCEPTION }
	title: wj.Str
	if !to_str(ctx, wj.arg(argc, argv, 0), &title, wj.STR_OPTIONAL) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &title)
	h: api_decl.Document
	st := jsb.host(&h, api_decl.DOMImplementation_createHTMLDocument, wj.wr_DOMImplementation_createHTMLDocument, maybe_view(title))
	return node_or_throw(ctx, h, st, "DOMImplementation.createHTMLDocument")
}

@(export, link_name = "wjr_DOMImplementation_createDocumentType")
wjr_DOMImplementation_createDocumentType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.dom_impl_of(ctx, this_val, ifc("DOMImplementation")) == nil { return wj.EXCEPTION }
	if argc < 3 { return wj.wj_throw_arity(ctx, "DOMImplementation.createDocumentType", 3, argc) }
	s: [3]wj.Str
	defer { for &x in s { wj.wj_str_free(ctx, &x) } }
	for i in 0 ..< 3 { if !to_str(ctx, argv[i], &s[i]) { return wj.EXCEPTION } }
	h: api_decl.Node
	st := jsb.host(&h, api_decl.DOMImplementation_createDocumentType, wj.wr_DOMImplementation_createDocumentType, str_view(s[0]), str_view(s[1]), str_view(s[2]))
	return node_or_throw(ctx, h, st, "DOMImplementation.createDocumentType")
}

// createDocument(namespace, qualifiedName [LegacyNullToEmptyString], doctype): a new XMLDocument (src/page/js_xml_parse.odin)
@(export, link_name = "wjr_DOMImplementation_createDocument")
wjr_DOMImplementation_createDocument :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.dom_impl_of(ctx, this_val, ifc("DOMImplementation")) == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "DOMImplementation.createDocument", 2, argc) }
	dtv := wj.arg(argc, argv, 2)
	dt: u64
	if !wj.is_nullish(dtv) {
		o := wj.wj_unwrap(dtv, ifc("DocumentType"))
		if o == nil { return wj.wj_throw_type(ctx, "Failed to execute 'createDocument' on 'DOMImplementation': parameter 3 is not of type 'DocumentType'.") }
		dt = o.handle
	}
	ns, name: wj.Str
	if !to_str(ctx, argv[0], &ns, wj.STR_NULLABLE) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &ns)
	if !wj.is_null(argv[1]) && !to_str(ctx, argv[1], &name) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &name)
	h: api_decl.Document
	st := jsb.host(&h, api_decl.DOMImplementation_createDocument, wj.wr_DOMImplementation_createDocument, namespace_of(ns), str_view(name), api_decl.Node(dt))
	return node_or_throw(ctx, h, st, "DOMImplementation.createDocument")
}

// new Document(): an empty XML document (as DOM's "new Document" is, whose interface is the base of XMLDocument here).
@(export, link_name = "wjr_Document_constructor")
wjr_Document_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor Document requires 'new'") }
	ns, name: wj.Str
	h: api_decl.Document
	st := jsb.host(&h, api_decl.DOMImplementation_createDocument, wj.wr_DOMImplementation_createDocument, namespace_of(ns), str_view(name), api_decl.Node(0))
	return node_or_throw(ctx, h, st, "Document")
}

@(export, link_name = "wjr_DOMImplementation_hasFeature")
wjr_DOMImplementation_hasFeature :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.dom_impl_of(ctx, this_val, ifc("DOMImplementation")) != nil ? wj.TRUE : wj.EXCEPTION
}

// ---- DOMParser, XMLSerializer ----

@(export, link_name = "wjr_DOMParser_constructor")
wjr_DOMParser_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor DOMParser requires 'new'") }
	return wj.wj_new_object_for(ctx, ifc("DOMParser"), new_target, nil, nil)
}

// parseFromString(string, type): "text/html" parses a whole document into a new inert one (scripts never run in it,
// no declarative shadow roots); the XML types make an XMLDocument (src/page/js_xml_parse.odin), a <parsererror> one
// when the text is not well-formed. A type outside DOMParserSupportedType is a TypeError.
@(export, link_name = "wjr_DOMParser_parseFromString")
wjr_DOMParser_parseFromString :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, this_val, ifc("DOMParser")) == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "DOMParser.parseFromString", 2, argc) }
	s, type: wj.Str
	// (as USVString: a lone surrogate becomes U+FFFD, which the parsers accept)
	if !to_str(ctx, argv[0], &s, wj.STR_USV) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	if !to_str(ctx, argv[1], &type) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &type)
	h: api_decl.Document
	switch str_view(type) {
	case "text/html":
		st := jsb.host(&h, api_decl.DOMParser_parseHTMLNode, wj.wr_DOMParser_parseHTMLNode, str_view(s))
		return node_or_throw(ctx, h, st, "DOMParser.parseFromString")
	case "text/xml", "application/xml", "application/xhtml+xml", "image/svg+xml":
		st := jsb.host(&h, api_decl.DOMParser_parseXMLNode, wj.wr_DOMParser_parseXMLNode, str_view(s), str_view(type))
		return node_or_throw(ctx, h, st, "DOMParser.parseFromString")
	}
	return wj.JS_ThrowTypeError(ctx, "Failed to execute 'parseFromString' on 'DOMParser': The provided value '%.*s' is not a valid enum value of type DOMParserSupportedType.",
		i32(min(type.len, 64)), wj.cstr_bytes(type.ptr))
}

// document.contentType: an XML document's own type (DOMParser's), else the page's
@(export, link_name = "wjr_Document_get_contentType")
wjr_Document_get_contentType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := node_this(ctx, this_val, ifc("Document"))
	if h == 0 { return wj.EXCEPTION }
	s: string
	if jsb.host(&s, api_decl.Document_xmlContentType, wj.wr_Document_xmlContentType, api_decl.Document(h)) != .None {
		jsb.host(&s, api_decl.Document_contentType, wj.wr_Document_contentType)
	}
	return wj.new_string_len(ctx, s)
}

@(export, link_name = "wjr_XMLSerializer_constructor")
wjr_XMLSerializer_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor XMLSerializer requires 'new'") }
	return wj.wj_new_object_for(ctx, ifc("XMLSerializer"), new_target, nil, nil)
}

// serializeToString(node): the browser's XML serialization (src/page/js_xml.odin)
@(export, link_name = "wjr_XMLSerializer_serializeToString")
wjr_XMLSerializer_serializeToString :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, this_val, ifc("XMLSerializer")) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "XMLSerializer.serializeToString", 1, argc) }
	o := wj.wj_unwrap(argv[0], ifc("Node"))
	if o == nil { return wj.wj_throw_type(ctx, "Failed to execute 'serializeToString' on 'XMLSerializer': parameter 1 is not of type 'Node'.") }
	s: string
	st := jsb.host(&s, api_decl.XMLSerializer_serialize, wj.wr_XMLSerializer_serialize, api_decl.Node(o.handle))
	return dom_str(ctx, s, st, false, "XMLSerializer.serializeToString")
}

@(export, link_name = "wjr_Document_get_defaultView")
wjr_Document_get_defaultView :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, ifc("Document")) == nil { return wj.EXCEPTION }
	return wj.JS_DupValue(ctx, wj.realm_global())
}

@(export, link_name = "wjr_Document_get_location")
wjr_Document_get_location :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, ifc("Document"))
	if o == nil { return wj.EXCEPTION }
	// null for a document without a browsing context (createHTMLDocument's, DOMParser's)
	if o.handle != 0 && api_decl.Document(o.handle) != page_document() { return wj.NULL }
	return wj.JS_GetPropertyStr(ctx, wj.realm_global(), "location")
}

// new Text(data) / new Comment(data): a node of the page's document
@(private = "file")
character_data_new :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue, comment: bool) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, comment ? cstring("Constructor Comment requires 'new'") : cstring("Constructor Text requires 'new'")) }
	s: wj.Str
	if !to_str(ctx, wj.arg(argc, argv, 0), &s) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	h: api_decl.Node
	if comment {
		st := jsb.host(&h, api_decl.Document_createComment, wj.wr_Document_createComment, str_view(s))
		return node_or_throw(ctx, h, st, "Comment")
	}
	st := jsb.host(&h, api_decl.Document_createTextNode, wj.wr_Document_createTextNode, str_view(s))
	return node_or_throw(ctx, h, st, "Text")
}

@(export, link_name = "wjr_Text_constructor")
wjr_Text_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return character_data_new(ctx, nt, argc, argv, false) }
@(export, link_name = "wjr_Comment_constructor")
wjr_Comment_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return character_data_new(ctx, nt, argc, argv, true) }

@(export, link_name = "wjr_DocumentFragment_constructor")
wjr_DocumentFragment_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor DocumentFragment requires 'new'") }
	h: api_decl.Node
	st := jsb.host(&h, api_decl.Document_createDocumentFragment, wj.wr_Document_createDocumentFragment)
	return node_or_throw(ctx, h, st, "DocumentFragment")
}

// ---- Element ----

@(export, link_name = "wjr_Element_get_tagName")
wjr_Element_get_tagName :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := node_this(ctx, this_val, ifc("Element"))
	if h == 0 { return wj.EXCEPTION }
	s: string
	st := jsb.host(&s, api_decl.Element_qualifiedTagName, wj.wr_Element_qualifiedTagName, api_decl.Element(h))
	return dom_str(ctx, s, st, false, "Element.tagName")
}

@(export, link_name = "wjr_Element_getAttributeNames")
wjr_Element_getAttributeNames :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := node_this(ctx, this_val, ifc("Element"))
	if h == 0 { return wj.EXCEPTION }
	names: abi.Bytes
	jsb.host(&names, api_decl.Element_attributeNames, wj.wr_Element_attributeNames, api_decl.Element(h))
	arr := wj.JS_NewArray(ctx)
	nul_list_into(ctx, arr, ([]u8)(names))
	return arr
}

@(export, link_name = "wjr_Element_setAttribute")
wjr_Element_setAttribute :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := node_this(ctx, this_val, ifc("Element"))
	if h == 0 { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "Element.setAttribute", 2, argc) }
	name, value: wj.Str
	if !to_str(ctx, argv[0], &name) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &name)
	if !to_str(ctx, argv[1], &value) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &value)
	st := jsb.host(&nothing, api_decl.Element_setAttributeChecked, wj.wr_Element_setAttributeChecked, api_decl.Element(h), str_view(name), str_view(value))
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "Element.setAttribute") : wj.UNDEFINED
}

// an optional boolean `force`: -1 when not given
@(private = "file")
force_of :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, i: i32) -> i32 {
	v := wj.arg(argc, argv, i)
	return wj.is_undefined(v) ? -1 : (wj.JS_ToBool(ctx, v) != 0 ? 1 : 0)
}

@(export, link_name = "wjr_Element_toggleAttribute")
wjr_Element_toggleAttribute :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := node_this(ctx, this_val, ifc("Element"))
	if h == 0 { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Element.toggleAttribute", 1, argc) }
	name: wj.Str
	if !to_str(ctx, argv[0], &name) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &name)
	r: bool
	st := jsb.host(&r, api_decl.Element_toggleAttributeChecked, wj.wr_Element_toggleAttributeChecked, api_decl.Element(h), str_view(name), force_of(ctx, argc, argv, 1))
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "Element.toggleAttribute") : wj.new_bool(r)
}

// ---- DOMTokenList (classList, relList...) ----

@(private = "file")
token_list :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32, attr: string) -> wj.JSValue {
	h := node_this(ctx, this_val, iface)
	if h == 0 { return wj.EXCEPTION }
	d: ^wj.Dom_Impl
	obj := wj.dom_new(ctx, ifc("DOMTokenList"), wj.DOM_TOKENS, this_val, h, &d)
	if wj.is_exception(obj) { return obj }
	d.name = wj.dom_strndup(raw_data(attr), uint(len(attr)))
	d.name_len = uint(len(attr))
	return obj
}

@(export, link_name = "wjr_Element_get_classList")
wjr_Element_get_classList :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return token_list(ctx, t, ifc("Element"), "class") }
// element.part (prelude/shadow.js keeps one per element)
@(export, link_name = "wj_token_list_of")
wj_token_list_of :: proc "c" (ctx: ^wj.Context, element: wj.JSValue, attr: cstring) -> wj.JSValue { return token_list(ctx, element, ifc("Element"), string(attr)) }
@(export, link_name = "wjr_HTMLAnchorElement_get_relList")
wjr_HTMLAnchorElement_get_relList :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return token_list(ctx, t, ifc("HTMLAnchorElement"), "rel") }
@(export, link_name = "wjr_HTMLAreaElement_get_relList")
wjr_HTMLAreaElement_get_relList :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return token_list(ctx, t, ifc("HTMLAreaElement"), "rel") }
@(export, link_name = "wjr_HTMLLinkElement_get_relList")
wjr_HTMLLinkElement_get_relList :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return token_list(ctx, t, ifc("HTMLLinkElement"), "rel") }
@(export, link_name = "wjr_HTMLFormElement_get_relList")
wjr_HTMLFormElement_get_relList :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return token_list(ctx, t, ifc("HTMLFormElement"), "rel") }
@(export, link_name = "wjr_HTMLLinkElement_get_sizes")
wjr_HTMLLinkElement_get_sizes :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return token_list(ctx, t, ifc("HTMLLinkElement"), "sizes") }
@(export, link_name = "wjr_HTMLIFrameElement_get_sandbox")
wjr_HTMLIFrameElement_get_sandbox :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return token_list(ctx, t, ifc("HTMLIFrameElement"), "sandbox") }
@(export, link_name = "wjr_HTMLOutputElement_get_htmlFor")
wjr_HTMLOutputElement_get_htmlFor :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return token_list(ctx, t, ifc("HTMLOutputElement"), "for") }

// The element and the attribute a token list is over.
@(private = "file")
Tokens :: struct { el: api_decl.Element, attr: string }

@(private = "file")
tokens_of :: proc "contextless" (d: ^wj.Dom_Impl) -> Tokens { return {api_decl.Element(d.node), wj.dom_name(d)} }

@(private = "file")
tokens_length :: proc(t: Tokens) -> u32 {
	n: u32
	jsb.host(&n, api_decl.TokenList_length, wj.wr_TokenList_length, t.el, t.attr)
	return n
}

@(export, link_name = "wjr_DOMTokenList_length_hook")
wjr_DOMTokenList_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 {
	context = jsb.glue_context()
	d := wj.dom_impl_any(obj, wj.DOM_TOKENS)
	return d != nil ? tokens_length(tokens_of(d)) : 0
}

@(export, link_name = "wjr_DOMTokenList_index_get")
wjr_DOMTokenList_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue {
	context = jsb.glue_context()
	found^ = false
	d := wj.dom_impl_any(obj, wj.DOM_TOKENS)
	if d == nil { return wj.UNDEFINED }
	t := tokens_of(d)
	s: string
	if jsb.host(&s, api_decl.TokenList_item, wj.wr_TokenList_item, t.el, t.attr, index) != .None { return wj.UNDEFINED }
	found^ = true
	return wj.new_string_len(ctx, s)
}

@(private = "file")
tokens_this :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^wj.Dom_Impl { return wj.dom_impl_of(ctx, this_val, ifc("DOMTokenList")) }

@(export, link_name = "wjr_DOMTokenList_get_length")
wjr_DOMTokenList_get_length :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := tokens_this(ctx, this_val)
	return d != nil ? wj.new_uint32(ctx, tokens_length(tokens_of(d))) : wj.EXCEPTION
}

@(export, link_name = "wjr_DOMTokenList_item")
wjr_DOMTokenList_item :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := tokens_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "DOMTokenList.item", 1, argc) }
	i: u32
	if !wj.wj_to_uint32(ctx, argv[0], &i, 32, 0) { return wj.EXCEPTION }
	t := tokens_of(d)
	s: string
	st := jsb.host(&s, api_decl.TokenList_item, wj.wr_TokenList_item, t.el, t.attr, i)
	return dom_str(ctx, s, st, true, "DOMTokenList.item")
}

// The member's string arguments, converted (released by tokens_args_free).
@(private = "file")
Token_Args :: struct { s: [2]wj.Str, n: int }

@(private = "file")
tokens_args :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, a: ^Token_Args, n: int, what: cstring) -> bool {
	if argc < i32(n) { wj.wj_throw_arity(ctx, what, i32(n), argc); return false }
	for i in 0 ..< n {
		if !to_str(ctx, argv[i], &a.s[i]) { return false }
		a.n += 1
	}
	return true
}

@(private = "file")
tokens_args_free :: proc "contextless" (ctx: ^wj.Context, a: ^Token_Args) { for i in 0 ..< a.n { wj.wj_str_free(ctx, &a.s[i]) } }

@(export, link_name = "wjr_DOMTokenList_contains")
wjr_DOMTokenList_contains :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := tokens_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	a: Token_Args
	defer tokens_args_free(ctx, &a)
	if !tokens_args(ctx, argc, argv, &a, 1, "DOMTokenList.contains") { return wj.EXCEPTION }
	t := tokens_of(d)
	r: bool
	jsb.host(&r, api_decl.TokenList_contains, wj.wr_TokenList_contains, t.el, t.attr, str_view(a.s[0]))
	return wj.new_bool(r)
}

// add / remove: the tokens NUL-separated
@(private = "file")
tokens_change :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, add: bool) -> wj.JSValue {
	context = jsb.glue_context()
	d := tokens_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	if argc == 0 { return wj.UNDEFINED }
	b: Pack
	defer pack_free(&b)
	for i in 0 ..< argc {
		s: wj.Str
		if !to_str(ctx, argv[i], &s) { return wj.EXCEPTION }
		ok := (i == 0 || pack_u8(&b, 0)) && pack_bytes(&b, wj.str_slice(s))
		wj.wj_str_free(ctx, &s)
		if !ok { return wj.JS_ThrowOutOfMemory(ctx) }
	}
	t := tokens_of(d)
	tokens := abi.Bytes(pack_slice(&b))
	st: abi.Api_Error
	if add {
		st = jsb.host(&nothing, api_decl.TokenList_add, wj.wr_TokenList_add, t.el, t.attr, tokens)
	} else {
		st = jsb.host(&nothing, api_decl.TokenList_remove, wj.wr_TokenList_remove, t.el, t.attr, tokens)
	}
	return st != .None ? wj.wj_throw_status(ctx, i32(st), add ? cstring("DOMTokenList.add") : cstring("DOMTokenList.remove")) : wj.UNDEFINED
}

@(export, link_name = "wjr_DOMTokenList_add")
wjr_DOMTokenList_add :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return tokens_change(ctx, t, argc, argv, true) }
@(export, link_name = "wjr_DOMTokenList_remove")
wjr_DOMTokenList_remove :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return tokens_change(ctx, t, argc, argv, false) }

@(export, link_name = "wjr_DOMTokenList_toggle")
wjr_DOMTokenList_toggle :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := tokens_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	a: Token_Args
	defer tokens_args_free(ctx, &a)
	if !tokens_args(ctx, argc, argv, &a, 1, "DOMTokenList.toggle") { return wj.EXCEPTION }
	t := tokens_of(d)
	r: bool
	st := jsb.host(&r, api_decl.TokenList_toggle, wj.wr_TokenList_toggle, t.el, t.attr, str_view(a.s[0]), force_of(ctx, argc, argv, 1))
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "DOMTokenList.toggle") : wj.new_bool(r)
}

@(export, link_name = "wjr_DOMTokenList_replace")
wjr_DOMTokenList_replace :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := tokens_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	a: Token_Args
	defer tokens_args_free(ctx, &a)
	if !tokens_args(ctx, argc, argv, &a, 2, "DOMTokenList.replace") { return wj.EXCEPTION }
	t := tokens_of(d)
	r: bool
	st := jsb.host(&r, api_decl.TokenList_replace, wj.wr_TokenList_replace, t.el, t.attr, str_view(a.s[0]), str_view(a.s[1]))
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "DOMTokenList.replace") : wj.new_bool(r)
}

@(export, link_name = "wjr_DOMTokenList_supports")
wjr_DOMTokenList_supports :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := tokens_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	a: Token_Args
	defer tokens_args_free(ctx, &a)
	if !tokens_args(ctx, argc, argv, &a, 1, "DOMTokenList.supports") { return wj.EXCEPTION }
	t := tokens_of(d)
	r: bool
	st := jsb.host(&r, api_decl.TokenList_supports, wj.wr_TokenList_supports, t.el, t.attr, str_view(a.s[0]))
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "DOMTokenList.supports") : wj.new_bool(r)
}

@(export, link_name = "wjr_DOMTokenList_get_value")
wjr_DOMTokenList_get_value :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := tokens_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	t := tokens_of(d)
	s: string
	jsb.host(&s, api_decl.Element_getAttribute, wj.wr_Element_getAttribute, t.el, t.attr)   // absent: ""
	return wj.new_string_len(ctx, s)
}

@(export, link_name = "wjr_DOMTokenList_set_value")
wjr_DOMTokenList_set_value :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	d := tokens_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	s: wj.Str
	if !to_str(ctx, v, &s) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	t := tokens_of(d)
	st := jsb.host(&nothing, api_decl.Element_setAttribute, wj.wr_Element_setAttribute, t.el, t.attr, str_view(s))
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "DOMTokenList.value") : wj.UNDEFINED
}

// ---- DOMStringMap (dataset) ----

@(export, link_name = "wjr_HTMLOrSVGOrMathMLElement_get_dataset")
wjr_HTMLOrSVGOrMathMLElement_get_dataset :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	h := node_this(ctx, this_val, ifc("Element"))
	if h == 0 { return wj.EXCEPTION }
	return wj.dom_new(ctx, ifc("DOMStringMap"), wj.DOM_DATASET, this_val, h, nil)
}

@(export, link_name = "wjr_DOMStringMap_named_get")
wjr_DOMStringMap_named_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, name: [^]u8, n: uint, found: ^bool) -> wj.JSValue {
	context = jsb.glue_context()
	found^ = false
	d := wj.dom_impl_any(obj, wj.DOM_DATASET)
	if d == nil { return wj.UNDEFINED }
	s: string
	if jsb.host(&s, api_decl.Dataset_get, wj.wr_Dataset_get, api_decl.Element(d.node), string(name[:n])) != .None { return wj.UNDEFINED }
	found^ = true
	return wj.new_string_len(ctx, s)
}

@(export, link_name = "wjr_DOMStringMap_named_set")
wjr_DOMStringMap_named_set :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, name: [^]u8, n: uint, value: wj.JSValue) -> i32 {
	context = jsb.glue_context()
	d := wj.dom_impl_any(obj, wj.DOM_DATASET)
	if d == nil { return 0 }
	s: wj.Str
	if !to_str(ctx, value, &s) { return -1 }
	defer wj.wj_str_free(ctx, &s)
	if st := jsb.host(&nothing, api_decl.Dataset_set, wj.wr_Dataset_set, api_decl.Element(d.node), string(name[:n]), str_view(s)); st != .None {
		wj.wj_throw_status(ctx, i32(st), "DOMStringMap")
		return -1
	}
	return 1
}

@(export, link_name = "wjr_DOMStringMap_named_delete")
wjr_DOMStringMap_named_delete :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, name: [^]u8, n: uint) -> i32 {
	context = jsb.glue_context()
	d := wj.dom_impl_any(obj, wj.DOM_DATASET)
	if d == nil { return 0 }
	jsb.host(&nothing, api_decl.Dataset_delete, wj.wr_Dataset_delete, api_decl.Element(d.node), string(name[:n]))
	return 1
}

@(export, link_name = "wjr_DOMStringMap_named_keys")
wjr_DOMStringMap_named_keys :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, array: wj.JSValue) -> i32 {
	context = jsb.glue_context()
	d := wj.dom_impl_any(obj, wj.DOM_DATASET)
	if d == nil { return 0 }
	names: abi.Bytes
	jsb.host(&names, api_decl.Dataset_names, wj.wr_Dataset_names, api_decl.Element(d.node))
	nul_list_into(ctx, array, ([]u8)(names))
	return 0
}

// ---- Attr and NamedNodeMap ----
//
// An Attr is a Dom_Impl of kind DOM_ATTR: `name` its qualified name, `node` its element (0: detached, its value in
// `extra`), `owner` the element's wrapper. A NamedNodeMap (DOM_ATTRS) keeps one Attr per attribute in `extra`, a
// null-prototype object keyed by the lower-case name.

@(private = "file")
attr_new :: proc "c" (ctx: ^wj.Context, owner: wj.JSValue, el: u64, name: string) -> wj.JSValue {
	d: ^wj.Dom_Impl
	obj := wj.dom_new(ctx, ifc("Attr"), wj.DOM_ATTR, owner, el, &d)
	if wj.is_exception(obj) { return obj }
	d.name = wj.dom_strndup(raw_data(name), uint(len(name)))
	d.name_len = uint(len(name))
	d.extra = wj.new_string(ctx, "")
	return obj
}

@(private = "file")
attr_value :: proc(ctx: ^wj.Context, a: ^wj.Dom_Impl) -> wj.JSValue {
	if a.node != 0 {
		s: string
		if jsb.host(&s, api_decl.Element_getAttribute, wj.wr_Element_getAttribute, api_decl.Element(a.node), wj.dom_name(a)) == .None {
			return wj.new_string_len(ctx, s)
		}
	}
	return wj.JS_DupValue(ctx, a.extra)
}

@(private = "file")
attr_set_value :: proc(ctx: ^wj.Context, a: ^wj.Dom_Impl, v: wj.JSValue) -> wj.JSValue {
	s: wj.Str
	if !to_str(ctx, v, &s, wj.STR_NULL_EMPTY) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	str := wj.new_string_len(ctx, str_view(s))
	wj.JS_FreeValue(ctx, a.extra)
	a.extra = str
	if a.node == 0 { return wj.UNDEFINED }
	st := jsb.host(&nothing, api_decl.Element_setAttribute, wj.wr_Element_setAttribute, api_decl.Element(a.node), wj.dom_name(a), str_view(s))
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "Attr.value") : wj.UNDEFINED
}

@(private = "file")
attr_this :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^wj.Dom_Impl { return wj.dom_impl_of(ctx, this_val, ifc("Attr")) }

// The qualified name's prefix and local name (split at the first colon).
@(private = "file")
attr_split :: proc "contextless" (a: ^wj.Dom_Impl) -> (prefix: string, local: string, has_prefix: bool) {
	name := wj.dom_name(a)
	for i in 0 ..< len(name) { if name[i] == ':' { return name[:i], name[i + 1:], true } }
	return "", name, false
}

@(export, link_name = "wjr_Attr_get_name")
wjr_Attr_get_name :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	a := attr_this(ctx, t)
	return a != nil ? wj.new_string_len(ctx, wj.dom_name(a)) : wj.EXCEPTION
}

@(export, link_name = "wjr_Attr_get_localName")
wjr_Attr_get_localName :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	a := attr_this(ctx, t)
	if a == nil { return wj.EXCEPTION }
	_, local, _ := attr_split(a)
	return wj.new_string_len(ctx, local)
}

@(export, link_name = "wjr_Attr_get_prefix")
wjr_Attr_get_prefix :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	a := attr_this(ctx, t)
	if a == nil { return wj.EXCEPTION }
	prefix, _, ok := attr_split(a)
	return ok ? wj.new_string_len(ctx, prefix) : wj.NULL
}

@(export, link_name = "wjr_Attr_get_namespaceURI")
wjr_Attr_get_namespaceURI :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	a := attr_this(ctx, t)
	if a == nil { return wj.EXCEPTION }
	name := wj.dom_name(a)
	has :: proc "contextless" (s, p: string) -> bool { return len(s) > len(p) && s[:len(p)] == p }
	if has(name, "xlink:") { return wj.new_string(ctx, "http://www.w3.org/1999/xlink") }
	if has(name, "xml:") { return wj.new_string(ctx, "http://www.w3.org/XML/1998/namespace") }
	if name == "xmlns" || has(name, "xmlns:") { return wj.new_string(ctx, "http://www.w3.org/2000/xmlns/") }
	return wj.NULL
}

@(export, link_name = "wjr_Attr_get_value")
wjr_Attr_get_value :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	a := attr_this(ctx, t)
	return a != nil ? attr_value(ctx, a) : wj.EXCEPTION
}

@(export, link_name = "wjr_Attr_set_value")
wjr_Attr_set_value :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	a := attr_this(ctx, t)
	return a != nil ? attr_set_value(ctx, a, v) : wj.EXCEPTION
}

@(export, link_name = "wjr_Attr_get_ownerElement")
wjr_Attr_get_ownerElement :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	a := attr_this(ctx, t)
	if a == nil { return wj.EXCEPTION }
	return a.node != 0 ? wj.JS_DupValue(ctx, a.owner) : wj.NULL
}

@(export, link_name = "wjr_Attr_get_specified")
wjr_Attr_get_specified :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return attr_this(ctx, t) != nil ? wj.TRUE : wj.EXCEPTION }

// The Attr of `name` on the element of a NamedNodeMap (one object per attribute: cached), or null when absent.
@(private = "file")
map_attr :: proc(ctx: ^wj.Context, m: ^wj.Dom_Impl, name: string) -> wj.JSValue {
	has: bool
	jsb.host(&has, api_decl.Element_hasAttribute, wj.wr_Element_hasAttribute, api_decl.Element(m.node), name)
	if !has { return wj.NULL }
	// the stored name (lower case) is the cache key
	key: [256]u8
	kl := min(len(name), len(key) - 1)
	for i in 0 ..< kl { key[i] = lower_ascii(name[i]) }
	key[kl] = 0
	ckey := cstring(&key[0])
	if !wj.is_object(m.extra) { m.extra = wj.JS_NewObjectProto(ctx, wj.NULL) }
	a := wj.JS_GetPropertyStr(ctx, m.extra, ckey)
	if wj.is_object(a) {
		if ad := (^wj.Dom_Impl)(wj.obj_impl(a)); ad != nil && ad.node == m.node { return a }   // still this element's
	}
	wj.JS_FreeValue(ctx, a)
	a = attr_new(ctx, m.owner, m.node, string(key[:kl]))
	if wj.is_exception(a) { return a }
	wj.JS_SetPropertyStr(ctx, m.extra, ckey, wj.JS_DupValue(ctx, a))
	return a
}

@(export, link_name = "wjr_Element_get_attributes")
wjr_Element_get_attributes :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	h := node_this(ctx, this_val, ifc("Element"))
	if h == 0 { return wj.EXCEPTION }
	return wj.dom_new(ctx, ifc("NamedNodeMap"), wj.DOM_ATTRS, this_val, h, nil)
}

@(private = "file")
attribute_count :: proc(el: u64) -> u32 {
	n: u32
	jsb.host(&n, api_decl.Element_attributeCount, wj.wr_Element_attributeCount, api_decl.Element(el))
	return n
}

@(export, link_name = "wjr_NamedNodeMap_length_hook")
wjr_NamedNodeMap_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 {
	context = jsb.glue_context()
	m := wj.dom_impl_any(obj, wj.DOM_ATTRS)
	return m != nil ? attribute_count(m.node) : 0
}

@(private = "file")
map_item :: proc(ctx: ^wj.Context, m: ^wj.Dom_Impl, i: u32) -> wj.JSValue {
	s: string
	if jsb.host(&s, api_decl.Element_attributeNameAt, wj.wr_Element_attributeNameAt, api_decl.Element(m.node), i) != .None { return wj.NULL }
	// (the name is in the scratch buffer, which map_attr's host calls reuse: copied first)
	name := wj.dom_strndup(raw_data(s), uint(len(s)))
	if name == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	defer wj.libc_free(name)
	return map_attr(ctx, m, string(name[:len(s)]))
}

@(export, link_name = "wjr_NamedNodeMap_index_get")
wjr_NamedNodeMap_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue {
	context = jsb.glue_context()
	found^ = false
	m := wj.dom_impl_any(obj, wj.DOM_ATTRS)
	if m == nil { return wj.UNDEFINED }
	a := map_item(ctx, m, index)
	if wj.is_null(a) { return wj.UNDEFINED }
	found^ = !wj.is_exception(a)
	return a
}

// named properties: map.name is the Attr of that qualified name (jQuery 1's support test reads
// div.attributes["onsubmit"].expando)
@(export, link_name = "wjr_NamedNodeMap_named_get")
wjr_NamedNodeMap_named_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, name: [^]u8, n: uint, found: ^bool) -> wj.JSValue {
	context = jsb.glue_context()
	found^ = false
	m := wj.dom_impl_any(obj, wj.DOM_ATTRS)
	if m == nil || n == 0 { return wj.UNDEFINED }
	a := map_attr(ctx, m, string(name[:n]))
	if wj.is_null(a) { return wj.UNDEFINED }
	found^ = !wj.is_exception(a)
	return a
}

// the supported property names: the attributes' qualified names in order (an HTML element's without the ones with
// upper case letters: a lookup lower-cases the name and could not find them)
@(export, link_name = "wjr_NamedNodeMap_named_keys")
wjr_NamedNodeMap_named_keys :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, array: wj.JSValue) -> i32 {
	context = jsb.glue_context()
	m := wj.dom_impl_any(obj, wj.DOM_ATTRS)
	if m == nil { return 0 }
	el := api_decl.Element(m.node)
	ns: string
	jsb.host(&ns, api_decl.Element_namespaceURI, wj.wr_Element_namespaceURI, el)
	html := ns == "http://www.w3.org/1999/xhtml"
	k: u32
	for i in 0 ..< attribute_count(m.node) {
		s: string
		if jsb.host(&s, api_decl.Element_attributeNameAt, wj.wr_Element_attributeNameAt, el, i) != .None { continue }
		if html {
			upper := false
			for c in transmute([]u8)s { if c >= 'A' && c <= 'Z' { upper = true; break } }
			if upper { continue }
		}
		wj.array_set(ctx, array, k, wj.new_string_len(ctx, s))
		k += 1
	}
	return 0
}

@(private = "file")
map_this :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^wj.Dom_Impl { return wj.dom_impl_of(ctx, this_val, ifc("NamedNodeMap")) }

@(export, link_name = "wjr_NamedNodeMap_get_length")
wjr_NamedNodeMap_get_length :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	m := map_this(ctx, this_val)
	return m != nil ? wj.new_uint32(ctx, attribute_count(m.node)) : wj.EXCEPTION
}

@(export, link_name = "wjr_NamedNodeMap_item")
wjr_NamedNodeMap_item :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	m := map_this(ctx, this_val)
	if m == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "NamedNodeMap.item", 1, argc) }
	i: u32
	if !wj.wj_to_uint32(ctx, argv[0], &i, 32, 0) { return wj.EXCEPTION }
	return map_item(ctx, m, i)
}

@(export, link_name = "wjr_NamedNodeMap_getNamedItem")
wjr_NamedNodeMap_getNamedItem :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	m := map_this(ctx, this_val)
	if m == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "NamedNodeMap.getNamedItem", 1, argc) }
	s: wj.Str
	if !to_str(ctx, argv[0], &s) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	return map_attr(ctx, m, str_view(s))
}

@(export, link_name = "wjr_NamedNodeMap_getNamedItemNS")
wjr_NamedNodeMap_getNamedItemNS :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	m := map_this(ctx, this_val)
	if m == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "NamedNodeMap.getNamedItemNS", 2, argc) }
	// the attributes keep their qualified names: the local name with the namespace's usual prefix
	ns, local: wj.Str
	if !to_str(ctx, argv[0], &ns, wj.STR_NULLABLE) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &ns)
	if !to_str(ctx, argv[1], &local) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &local)
	prefix := ""
	switch str_view(ns) {
	case "http://www.w3.org/1999/xlink":         prefix = "xlink:"
	case "http://www.w3.org/XML/1998/namespace": prefix = "xml:"
	}
	name: [300]u8
	n := copy(name[:len(name) - 1], prefix)
	n += copy(name[n:len(name) - 1], wj.str_slice(local))
	return map_attr(ctx, m, string(name[:n]))
}

// setNamedItem(attr) / setAttributeNode: the attribute takes the Attr's value; the Attr belongs to the element now.
// InUseAttributeError when it belongs to another element. Returns the Attr it replaces (null when none).
@(private = "file")
set_attr_node :: proc(ctx: ^wj.Context, element: wj.JSValue, el: u64, attr: wj.JSValue) -> wj.JSValue {
	ao := wj.wj_unwrap(attr, ifc("Attr"))
	if ao == nil || ao.impl == nil { return wj.wj_throw_type(ctx, "parameter 1 is not of type 'Attr'.") }
	a := (^wj.Dom_Impl)(ao.impl)
	if a.node != 0 && a.node != el {
		return wj.wj_throw_dom(ctx, "InUseAttributeError", "The node provided is an attribute node that is already an attribute of another Element; attribute nodes must be explicitly cloned.")
	}
	if a.node == el { return wj.JS_DupValue(ctx, attr) }
	mapv := wj.JS_GetPropertyStr(ctx, element, "attributes")
	if wj.is_exception(mapv) { return mapv }
	defer wj.JS_FreeValue(ctx, mapv)
	m := wj.dom_impl_any(mapv, wj.DOM_ATTRS)
	old := m != nil ? map_attr(ctx, m, wj.dom_name(a)) : wj.NULL
	if wj.is_object(old) {
		// the replaced Attr keeps its value, detached
		od := (^wj.Dom_Impl)(wj.obj_impl(old))
		v := attr_value(ctx, od)
		wj.JS_FreeValue(ctx, od.extra)
		od.extra = v
		od.node = 0
	}
	v := wj.JS_DupValue(ctx, a.extra)
	a.node = el
	wj.JS_FreeValue(ctx, a.owner)
	a.owner = wj.JS_DupValue(ctx, element)
	r := attr_set_value(ctx, a, v)
	wj.JS_FreeValue(ctx, v)
	if m != nil && wj.is_object(m.extra) { wj.JS_SetPropertyStr(ctx, m.extra, wj.cstr(a.name), wj.JS_DupValue(ctx, attr)) }
	if wj.is_exception(r) { wj.JS_FreeValue(ctx, old); return r }
	return old
}

// removeNamedItem / removeAttributeNode: the attribute goes, its Attr keeps the value, detached.
@(private = "file")
remove_attr_node :: proc(ctx: ^wj.Context, el: u64, a: ^wj.Dom_Impl, attr: wj.JSValue) -> wj.JSValue {
	if a.node != el { return wj.wj_throw_dom(ctx, "NotFoundError", "The attribute is not owned by this element.") }
	v := attr_value(ctx, a)
	wj.JS_FreeValue(ctx, a.extra)
	a.extra = v
	jsb.host(&nothing, api_decl.Element_removeAttribute, wj.wr_Element_removeAttribute, api_decl.Element(el), wj.dom_name(a))
	a.node = 0
	return wj.JS_DupValue(ctx, attr)
}

@(export, link_name = "wjr_NamedNodeMap_setNamedItem")
wjr_NamedNodeMap_setNamedItem :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	m := map_this(ctx, this_val)
	if m == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "NamedNodeMap.setNamedItem", 1, argc) }
	return set_attr_node(ctx, m.owner, m.node, argv[0])
}

@(export, link_name = "wjr_NamedNodeMap_setNamedItemNS")
wjr_NamedNodeMap_setNamedItemNS :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return wjr_NamedNodeMap_setNamedItem(ctx, t, argc, argv) }

// removeNamedItem / removeNamedItemNS: the Attr found by `find`, removed
@(private = "file")
map_remove :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, find: wj.Native, check_arity: bool) -> wj.JSValue {
	context = jsb.glue_context()
	m := map_this(ctx, this_val)
	if m == nil { return wj.EXCEPTION }
	if check_arity && argc < 1 { return wj.wj_throw_arity(ctx, "NamedNodeMap.removeNamedItem", 1, argc) }
	a := find(ctx, this_val, argc, argv)
	if wj.is_exception(a) { return a }
	if !wj.is_object(a) { return wj.wj_throw_dom(ctx, "NotFoundError", "No item with that name was found.") }
	defer wj.JS_FreeValue(ctx, a)
	return remove_attr_node(ctx, m.node, (^wj.Dom_Impl)(wj.obj_impl(a)), a)
}

@(export, link_name = "wjr_NamedNodeMap_removeNamedItem")
wjr_NamedNodeMap_removeNamedItem :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return map_remove(ctx, t, argc, argv, wjr_NamedNodeMap_getNamedItem, true) }
@(export, link_name = "wjr_NamedNodeMap_removeNamedItemNS")
wjr_NamedNodeMap_removeNamedItemNS :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return map_remove(ctx, t, argc, argv, wjr_NamedNodeMap_getNamedItemNS, false) }

// Element's Attr members: the same as its NamedNodeMap's
@(private = "file")
element_map_call :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, fn: wj.Native) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, ifc("Element")) == nil { return wj.EXCEPTION }
	m := wj.JS_GetPropertyStr(ctx, this_val, "attributes")
	if wj.is_exception(m) { return m }
	defer wj.JS_FreeValue(ctx, m)
	return fn(ctx, m, argc, argv)
}

@(export, link_name = "wjr_Element_getAttributeNode")
wjr_Element_getAttributeNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return element_map_call(ctx, t, argc, argv, wjr_NamedNodeMap_getNamedItem) }
@(export, link_name = "wjr_Element_getAttributeNodeNS")
wjr_Element_getAttributeNodeNS :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return element_map_call(ctx, t, argc, argv, wjr_NamedNodeMap_getNamedItemNS) }
@(export, link_name = "wjr_Element_setAttributeNode")
wjr_Element_setAttributeNode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return element_map_call(ctx, t, argc, argv, wjr_NamedNodeMap_setNamedItem) }
@(export, link_name = "wjr_Element_setAttributeNodeNS")
wjr_Element_setAttributeNodeNS :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return element_map_call(ctx, t, argc, argv, wjr_NamedNodeMap_setNamedItem) }

@(export, link_name = "wjr_Element_removeAttributeNode")
wjr_Element_removeAttributeNode :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := node_this(ctx, this_val, ifc("Element"))
	if h == 0 { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Element.removeAttributeNode", 1, argc) }
	ao := wj.wj_unwrap(argv[0], ifc("Attr"))
	if ao == nil || ao.impl == nil { return wj.wj_throw_type(ctx, "parameter 1 is not of type 'Attr'.") }
	return remove_attr_node(ctx, h, (^wj.Dom_Impl)(ao.impl), argv[0])
}

@(export, link_name = "wjr_Document_createAttribute")
wjr_Document_createAttribute :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, ifc("Document")) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Document.createAttribute", 1, argc) }
	s: wj.Str
	if !to_str(ctx, argv[0], &s) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	name := wj.dom_strndup(wj.cstr_bytes(s.ptr), s.len)
	if name == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	defer wj.libc_free(name)
	ok := s.len > 0
	for i in 0 ..< s.len {
		switch name[i] {
		case ' ', '\t', '\n', '\r', '\f', '/', '>', '=', 0: ok = false
		}
		name[i] = lower_ascii(name[i])
	}
	if !ok { return wj.wj_throw_dom(ctx, "InvalidCharacterError", "The localName provided is not a valid name.") }
	return attr_new(ctx, wj.UNDEFINED, 0, string(name[:s.len]))
}

@(export, link_name = "wjr_Document_createAttributeNS")
wjr_Document_createAttributeNS :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 2 { return wj.wj_throw_arity(ctx, "Document.createAttributeNS", 2, argc) }
	return wjr_Document_createAttribute(ctx, this_val, 1, argv[1:])
}

// ---- innerHTML / outerHTML setters: (TrustedHTML or [LegacyNullToEmptyString] DOMString) ----

@(private = "file")
set_markup :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue, outer: bool) -> wj.JSValue {
	context = jsb.glue_context()
	h := api_decl.Element(node_this(ctx, this_val, ifc("Element")))
	if h == 0 { return wj.EXCEPTION }
	s: wj.Str
	if !to_str(ctx, v, &s, wj.STR_NULL_EMPTY) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	if outer {
		st := jsb.host(&nothing, api_decl.Element_set_outerHTML, wj.wr_Element_set_outerHTML, h, str_view(s))
		return st != .None ? wj.wj_throw_status(ctx, i32(st), "Element.outerHTML") : wj.UNDEFINED
	}
	st := jsb.host(&nothing, api_decl.Element_set_innerHTML, wj.wr_Element_set_innerHTML, h, str_view(s))
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "Element.innerHTML") : wj.UNDEFINED
}

@(export, link_name = "wjr_Element_set_innerHTML")
wjr_Element_set_innerHTML :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return set_markup(ctx, t, v, false) }
@(export, link_name = "wjr_Element_set_outerHTML")
wjr_Element_set_outerHTML :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return set_markup(ctx, t, v, true) }

// ---- HTMLElement.hidden: (boolean or unrestricted double or DOMString)? ----

@(export, link_name = "wjr_HTMLElement_get_hidden")
wjr_HTMLElement_get_hidden :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := node_this(ctx, this_val, ifc("HTMLElement"))
	if h == 0 { return wj.EXCEPTION }
	s: api_decl.HiddenState
	jsb.host(&s, api_decl.HTMLElement_hiddenState, wj.wr_HTMLElement_hiddenState, api_decl.Element(h))
	return s == .Until_Found ? wj.new_string(ctx, "until-found") : wj.new_bool(s != .Shown)
}

@(export, link_name = "wjr_HTMLElement_set_hidden")
wjr_HTMLElement_set_hidden :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := api_decl.Element(node_this(ctx, this_val, ifc("HTMLElement")))
	if h == 0 { return wj.EXCEPTION }
	value: Maybe(string)   // nil: removed
	if wj.is_string(v) && js_str_is(ctx, v, "until-found") {
		value = "until-found"
	} else if wj.is_string(v) && js_str_is(ctx, v, "") {
		value = nil
	} else if wj.JS_ToBool(ctx, v) != 0 {
		value = ""
	}
	if s, ok := value.?; ok {
		jsb.host(&nothing, api_decl.Element_setAttribute, wj.wr_Element_setAttribute, h, "hidden", s)
	} else {
		jsb.host(&nothing, api_decl.Element_removeAttribute, wj.wr_Element_removeAttribute, h, "hidden")
	}
	return wj.UNDEFINED
}

// focus(options): the element takes the focus (forms.HTMLElement_focus; options.preventScroll has nothing to do)
@(export, link_name = "wjr_HTMLOrSVGOrMathMLElement_focus")
wjr_HTMLOrSVGOrMathMLElement_focus :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	h := node_this(ctx, this_val, ifc("Element"))
	if h == 0 { return wj.EXCEPTION }
	jsb.host(&nothing, api_decl.HTMLElement_focus, wj.wr_HTMLElement_focus, api_decl.Element(h))
	return wj.UNDEFINED
}
