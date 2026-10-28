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

/* wj_member (m4_engine.odin Member): the stride of an interface's members[] */
WJ_LAYOUT(wj_member, kind, 4);
WJ_LAYOUT(wj_member, flags, 6);
WJ_LAYOUT(wj_member, length, 8);
WJ_LAYOUT(wj_member, fn, 12);
WJ_LAYOUT(wj_member, get, 16);
WJ_LAYOUT(wj_member, set, 20);
WJ_LAYOUT(wj_member, value, 24);
WJ_SIZE(wj_member, 32);

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

/* web_extracted (values.odin Extracted) */
WJ_LAYOUT(web_extracted, len, 4);
WJ_LAYOUT(web_extracted, type, 8);
WJ_LAYOUT(web_extracted, stream, 16);
WJ_SIZE(web_extracted, 24);
