// m1_dom.odin: the helpers of dom_internal.h that every DOM member uses, implemented here (they were dom_core.c's) and
// exported under their C names, so the C that remains links against them and an Odin domain calls them as wj.dom_new
// and so on. An engine-made DOM object is a platform object whose impl is a Dom_Impl (dom.odin), freed and marked by
// the two procedures below; dom_impl_of recognises one by its free function.
package wj

@(private = "file")
dom_impl_free :: proc "c" (p: rawptr) {
	d := (^Dom_Impl)(p)
	rt := JS_GetRuntime(wj_the_realm.ctx)
	if d.coll != 0 { wr_Object_release(d.coll) }
	if d.nodes != nil {
		if d.n != 0 { wr_Node_unpinAll(d.nodes, d.n) }
		libc_free(d.nodes)
	}
	JS_FreeValueRT(rt, d.owner)
	JS_FreeValueRT(rt, d.extra)
	for i in 0 ..< d.n_values { JS_FreeValueRT(rt, d.values[i]) }
	libc_free(d.values)
	libc_free(d.name)
	libc_free(d)
}

@(private = "file")
dom_impl_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	d := (^Dom_Impl)(p)
	wj_mark(rt, d.owner, mark_func)
	wj_mark(rt, d.extra, mark_func)
	for i in 0 ..< d.n_values { wj_mark(rt, d.values[i], mark_func) }
}

@(export, link_name = "dom_strndup")
dom_strndup :: proc "c" (s: [^]u8, n: uint) -> [^]u8 {
	p := ([^]u8)(libc_malloc(n + 1))
	if p == nil { return nil }
	if n > 0 { memcpy(p, s, n) }
	p[n] = 0
	return p
}

// A new engine object of `iface` with a fresh Dom_Impl of `kind` (owner dup'ed).
@(export, link_name = "dom_new")
dom_new :: proc "c" (ctx: ^Context, iface: i32, kind: i32, owner: JSValue, node: u64, out: ^^Dom_Impl) -> JSValue {
	d := (^Dom_Impl)(libc_calloc(1, size_of(Dom_Impl)))
	if d == nil { return JS_ThrowOutOfMemory(ctx) }
	d.kind = kind
	d.owner = JS_DupValue(ctx, owner)
	d.node = node
	d.extra = UNDEFINED
	obj := wj_new_object(ctx, iface, d, dom_impl_free)
	if is_exception(obj) { return obj }
	obj_of(obj).impl_mark = dom_impl_mark
	if out != nil { out^ = d }
	return obj
}

// The Dom_Impl of `this` when it is an engine-made DOM object of `iface` (TypeError "Illegal invocation" otherwise).
@(export, link_name = "dom_impl_of")
dom_impl_of :: proc "c" (ctx: ^Context, this_val: JSValue, iface: i32) -> ^Dom_Impl {
	o := wj_this(ctx, this_val, iface)
	if o == nil { return nil }
	if o.impl == nil || o.impl_free != dom_impl_free { JS_ThrowTypeError(ctx, "Illegal invocation"); return nil }
	return (^Dom_Impl)(o.impl)
}

// The Dom_Impl of a platform object made by dom_new (no exception), of kind `a` or `b` (-1: any). On the hot path of
// indexed and named properties: no allocation, no context.
dom_impl_any :: #force_inline proc "contextless" (v: JSValue, a: i32 = -1, b: i32 = -1) -> ^Dom_Impl {
	o := obj_of(v)
	if o == nil || o.impl == nil || o.impl_free != dom_impl_free { return nil }
	d := (^Dom_Impl)(o.impl)
	return a < 0 || d.kind == a || d.kind == b ? d : nil
}

@(private = "file") node_iface := i32(-2)

// The browser's handle of a node argument (TypeError naming the method otherwise).
@(export, link_name = "dom_node_arg")
dom_node_arg :: proc "c" (ctx: ^Context, v: JSValue, out: ^u64, nullable: bool, what: cstring) -> bool {
	out^ = 0
	if nullable && is_nullish(v) { return true }
	if node_iface == -2 { node_iface = iface("Node") }
	o := wj_unwrap(v, node_iface)
	if o == nil || o.handle == 0 {
		JS_ThrowTypeError(ctx, "Failed to execute '%s': parameter is not of type 'Node'.", what)
		return false
	}
	out^ = o.handle
	return true
}

// A member of an undefined-or-dictionary argument: undefined when it is not an object.
@(export, link_name = "dom_dict_get")
dom_dict_get :: proc "c" (ctx: ^Context, dict: JSValue, name: cstring) -> JSValue {
	if !is_object(dict) { return UNDEFINED }
	return JS_GetPropertyStr(ctx, dict, name)
}

@(private = "file") nodelist_iface := i32(-2)

// A static NodeList of handles (pinned for the list's life).
@(export, link_name = "dom_static_list_of")
dom_static_list_of :: proc "c" (ctx: ^Context, handles: [^]u64, count: u32) -> JSValue {
	if nodelist_iface == -2 { nodelist_iface = iface("NodeList") }
	d: ^Dom_Impl
	obj := dom_new(ctx, nodelist_iface, DOM_LIST_STATIC, UNDEFINED, 0, &d)
	if is_exception(obj) { return obj }
	if count > 0 {
		d.nodes = ([^]u64)(libc_malloc(uint(count) * 8))
		if d.nodes == nil { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx) }
		memcpy(d.nodes, handles, uint(count) * 8)
		d.n = count
		wr_Node_pinAll(d.nodes, d.n)
	}
	return obj
}

// A static NodeList of handles packed 8 bytes each, little endian (copied).
@(export, link_name = "dom_static_list")
dom_static_list :: proc "c" (ctx: ^Context, packed: [^]u8, count: u32) -> JSValue {
	if count == 0 { return dom_static_list_of(ctx, nil, 0) }
	h := ([^]u64)(libc_malloc(uint(count) * 8))
	if h == nil { return JS_ThrowOutOfMemory(ctx) }
	defer libc_free(h)
	for i in 0 ..< count { h[i] = read_u64(packed[8 * i:]) }
	return dom_static_list_of(ctx, h, count)
}

// A live collection of the browser's (src/page/js_dom_collections.odin, kind = its collection kind): a NodeList or an
// HTMLCollection (`iface`), released with the object.
@(export, link_name = "dom_live_list")
dom_live_list :: proc "c" (ctx: ^Context, owner: JSValue, root: u64, kind: i32, arg: [^]u8, arg_len: uint, iface: i32) -> JSValue {
	coll: u64
	if st := wr_Collection_create(root, kind, cstr_bytes(arg), u32(arg_len), &coll); st < 0 { return wj_throw_status(ctx, st, "collection") }
	d: ^Dom_Impl
	obj := dom_new(ctx, iface, DOM_LIST_LIVE, owner, root, &d)
	if is_exception(obj) { wr_Object_release(coll); return obj }
	d.coll = coll
	return obj
}

// The name / text a Dom_Impl keeps (malloc'd by dom_strndup), as an Odin string.
dom_name :: #force_inline proc "contextless" (d: ^Dom_Impl) -> string {
	return d.name != nil ? string(d.name[:d.name_len]) : ""
}
