/* wj_shim.c: the layout contract between the engine's C structs and their Odin mirrors (native/js/odin/wj).
 *
 * The Odin glue reads and writes the engine's structs in place (wj_the_realm, wj_obj, wj_listener, wj_interface,
 * wj_buf, wj_str, dom_impl, web_extracted): each is mirrored field for field in package wj (engine.odin, dom.odin,
 * strings.odin, values.odin), and the static inlines over them (wj_obj_of, web_set_impl, web_rt, web_is_window) are
 * reimplemented there. This file holds NO code: only compile-time checks that every mirrored offset and size is the one
 * the Odin side assumes (the same numbers are asserted on the Odin side, engine.odin "layout"). A field added, removed
 * or retyped on either side breaks the build here instead of corrupting memory at run time.
 *
 * It replaces the per-field C accessors the first ports used (wj_realm_ctx, wj_shim_obj_handle, wj_g4_scratch_data...):
 * one call per field read, C written by us, and three copies of the same accessors. When a struct moves to Odin its
 * asserts go; when the last one has, this file goes. Compiled by zig cc with the engine's C (tools/build_js.ps1). */
#include <stddef.h>
#include "web.h"
#include "dom_internal.h"

#define WJ_LAYOUT(type, field, off) _Static_assert(offsetof(type, field) == (off), #type "." #field " moved: update its Odin mirror")
#define WJ_SIZE(type, size) _Static_assert(sizeof(type) == (size), #type " changed size: update its Odin mirror")

/* wj_interface (engine.odin Interface): the stride of wj_interfaces[] */
WJ_LAYOUT(wj_interface, parent, 4);
WJ_LAYOUT(wj_interface, class_kind, 10);
WJ_LAYOUT(wj_interface, ctor, 16);
WJ_LAYOUT(wj_interface, subtree_end, 26);
WJ_LAYOUT(wj_interface, legacy_alias, 52);
WJ_LAYOUT(wj_interface, factory_length, 64);
WJ_SIZE(wj_interface, 68);

/* wj_listener (engine.odin Listener) */
WJ_LAYOUT(wj_listener, callback, 8);
WJ_LAYOUT(wj_listener, type, 16);
WJ_LAYOUT(wj_listener, host_id, 24);
WJ_LAYOUT(wj_listener, capture, 32);
WJ_LAYOUT(wj_listener, handler, 35);
WJ_LAYOUT(wj_listener, owner, 36);
WJ_SIZE(wj_listener, 40);

/* wj_obj (engine.odin Obj) */
WJ_LAYOUT(wj_obj, handle, 0);
WJ_LAYOUT(wj_obj, iface, 8);
WJ_LAYOUT(wj_obj, kind, 10);
WJ_LAYOUT(wj_obj, group_slot, 12);
WJ_LAYOUT(wj_obj, group_val, 24);
WJ_LAYOUT(wj_obj, listeners, 32);
WJ_LAYOUT(wj_obj, impl, 36);
WJ_LAYOUT(wj_obj, impl_free, 40);
WJ_LAYOUT(wj_obj, impl_mark, 44);
WJ_LAYOUT(wj_obj, self, 48);
WJ_LAYOUT(wj_obj, same, 56);
WJ_LAYOUT(wj_obj, n_same, 60);
WJ_SIZE(wj_obj, 64);

/* wj_realm (engine.odin Realm) */
WJ_LAYOUT(wj_realm, kind, 4);
WJ_LAYOUT(wj_realm, scope, 8);
WJ_LAYOUT(wj_realm, global_obj, 16);
WJ_LAYOUT(wj_realm, global, 80);
WJ_LAYOUT(wj_realm, protos, 88);
WJ_LAYOUT(wj_realm, ctors, 92);
WJ_LAYOUT(wj_realm, started, 96);
WJ_LAYOUT(wj_realm, in_gc_prologue, 97);
WJ_SIZE(wj_realm, 104);

/* wj_buf, wj_str (engine.odin Buf, strings.odin Str) */
WJ_LAYOUT(wj_buf, cap, 4);
WJ_SIZE(wj_buf, 8);
WJ_LAYOUT(wj_str, len, 4);
WJ_LAYOUT(wj_str, owned, 8);
WJ_SIZE(wj_str, 12);

/* dom_impl (dom.odin Dom_Impl) */
WJ_LAYOUT(dom_impl, owner, 8);
WJ_LAYOUT(dom_impl, node, 16);
WJ_LAYOUT(dom_impl, coll, 24);
WJ_LAYOUT(dom_impl, nodes, 32);
WJ_LAYOUT(dom_impl, n, 36);
WJ_LAYOUT(dom_impl, name, 40);
WJ_LAYOUT(dom_impl, name_len, 44);
WJ_LAYOUT(dom_impl, extra, 48);
WJ_LAYOUT(dom_impl, rect, 56);
WJ_LAYOUT(dom_impl, values, 88);
WJ_LAYOUT(dom_impl, n_values, 92);
WJ_SIZE(dom_impl, 96);

/* wj_member (qjs_platform.odin Member): the generated member tables */
WJ_LAYOUT(wj_member, kind, 4);
WJ_LAYOUT(wj_member, flags, 6);
WJ_LAYOUT(wj_member, length, 8);
WJ_LAYOUT(wj_member, fn, 12);
WJ_LAYOUT(wj_member, set, 20);
WJ_LAYOUT(wj_member, value, 24);
WJ_SIZE(wj_member, 32);

/* web_buf (web_core.odin Web_Buf) */
WJ_LAYOUT(web_buf, len, 4);
WJ_LAYOUT(web_buf, failed, 12);
WJ_SIZE(web_buf, 16);

/* the QuickJS-ng structs the engine layer passes by pointer (m6_quickjs.odin, quickjs.odin) */
WJ_LAYOUT(JSClassDef, finalizer, 4);
WJ_LAYOUT(JSClassDef, exotic, 16);
WJ_SIZE(JSClassDef, 20);
WJ_LAYOUT(JSClassExoticMethods, delete_property, 8);
WJ_LAYOUT(JSClassExoticMethods, define_own_property, 12);
WJ_SIZE(JSClassExoticMethods, 28);
WJ_LAYOUT(JSMemoryUsage, malloc_size, 0);
WJ_SIZE(JSMemoryUsage, 208);
WJ_LAYOUT(JSEvalOptions, filename, 8);
WJ_SIZE(JSEvalOptions, 16);
WJ_LAYOUT(JSPropertyDescriptor, value, 8);
WJ_SIZE(JSPropertyDescriptor, 32);
WJ_LAYOUT(JSPropertyEnum, atom, 4);
WJ_SIZE(JSPropertyEnum, 8);
WJ_SIZE(JSMallocFunctions, 20);
/* the flags m6_quickjs.odin spells out (asserted with the same numbers there) */
#define WJ_VALUE(name, v) _Static_assert((name) == (v), #name " changed: update its Odin copy")
WJ_VALUE(JS_PROP_THROW, 1 << 14);
WJ_VALUE(JS_PROP_THROW_STRICT, 1 << 15);
WJ_VALUE(JS_PROP_NO_EXOTIC, 1 << 17);
WJ_VALUE(JS_CFUNC_generic_magic, 1);
WJ_VALUE(JS_CFUNC_constructor, 2);
WJ_VALUE(JS_CFUNC_constructor_or_func, 4);
WJ_VALUE(JS_CFUNC_getter, 8);
WJ_VALUE(JS_CFUNC_setter, 9);
WJ_VALUE(JS_EVAL_TYPE_MODULE, 1);
WJ_VALUE(JS_EVAL_FLAG_STRICT, 1 << 3);
WJ_VALUE(JS_EVAL_FLAG_COMPILE_ONLY, 1 << 5);
WJ_VALUE(JS_EVAL_FLAG_WREN_NO_RESOLVE, 1 << 9);
WJ_VALUE(JS_WRITE_OBJ_BYTECODE, 1);
WJ_VALUE(JS_WRITE_OBJ_STRIP_SOURCE, 1 << 4);
WJ_VALUE(JS_READ_OBJ_BYTECODE, 1);
WJ_VALUE(JS_PROMISE_PENDING, 0);
WJ_VALUE(JS_PROMISE_REJECTED, 2);

/* web_extracted (values.odin Extracted) */
WJ_LAYOUT(web_extracted, len, 4);
WJ_LAYOUT(web_extracted, type, 8);
WJ_LAYOUT(web_extracted, stream, 16);
WJ_SIZE(web_extracted, 24);
