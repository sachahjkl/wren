/* wj_shim.c: the few engine things the Odin glue layer (native/js/odin/wj) cannot name directly.
 *
 * Odin resolves an engine symbol through wasm-ld, so a function with a real symbol (JS_EXTERN in quickjs.h, the wj_ and
 * web_ functions of native/js/engine and native/js/runtime) needs no shim; the wj package declares it `foreign` and the
 * link resolves it. What needs a shim is anything that is a `static inline`, a macro, or a FIELD OF A GLOBAL STRUCT in
 * the headers, because those have no symbol to link against.
 *
 * There is ONE shim (this file), shared by the whole glue, not a per-agent wj_gN_shim.c. It exposes state, never logic:
 * each function is a one-line field read. It shrinks as the global C structs (wj_the_realm, wj_obj) move to Odin;
 * nothing here should ever grow into behaviour.
 *
 * Why each of these cannot be in Odin:
 *   - wj_realm_ accessors: wj_the_realm is a C global struct (engine/qjs_internal.h). Reading its fields from Odin
 *     would mean mirroring its exact layout (fragile, and it changes as the engine evolves). Until wj_the_realm itself
 *     is ported, a field accessor is the robust choice.
 *   - wj_shim_obj accessors: wj_obj_of() is a `static inline` (qjs_internal.h, the JSValue to wj_obj decode) with no
 *     symbol, and wj_obj's fields (handle, impl) sit behind the inline. Odin reads them through these accessors rather
 *     than mirroring the struct.
 *
 * Compiled by zig cc with the engine's other C (tools/build_js.ps1), alongside the ported-to-Odin domains' C being
 * dropped from the source list. */
#include "web.h"

/* ---- wj_the_realm fields (engine/qjs_internal.h via web.h) ---- */

/* The realm's global object (not counted). */
wj_val wj_realm_global(void) { return wj_the_realm.global; }

/* The realm's context. A field of wj_the_realm, so no symbol; the Odin glue needs it for the browser->guest entry
 * points it owns (wj_shared_connect, wj_port_message...) that start from the realm rather than from a JSContext arg. */
wj_ctx *wj_realm_ctx(void) { return wj_the_realm.ctx; }

/* The realm's kind: WJ_EXPOSE_WINDOW or WJ_EXPOSE_WORKER (web_is_window() == kind != WORKER). */
int wj_realm_kind(void) { return wj_the_realm.kind; }

/* The prototype object of interface `iface` (wj_the_realm.protos[iface]); undefined when the realm has none. */
wj_val wj_realm_proto(int iface) { return wj_the_realm.protos[iface]; }

/* ---- wj_obj fields (behind the `static inline` wj_obj_of) ---- */

/* The browser handle and engine-owned data of a platform object `v`. wj_obj_of is a `static inline` (qjs_internal.h):
 * expose the two fields the glue reads off a platform object. */
uint64_t wj_shim_obj_handle(JSValueConst v) { wj_obj *o = wj_obj_of(v); return o ? o->handle : 0; }
void    *wj_shim_obj_impl(JSValueConst v)   { wj_obj *o = wj_obj_of(v); return o ? o->impl : NULL; }

/* The handle and impl off a wj_obj* (wj_this / wj_unwrap return one; reading handle/impl from Odin would mirror
 * wj_obj's layout, which these accessors avoid). */
uint64_t wj_shim_handle(const void *obj) { return obj ? ((const wj_obj *)obj)->handle : 0; }
void    *wj_shim_impl(const void *obj)   { return obj ? ((const wj_obj *)obj)->impl : NULL; }

/* The impl of a wj_obj*, named as the ported C read it (wj_obj_impl). Same as wj_shim_impl; kept because a ported
 * domain (web_broadcast) calls wj_obj_impl by that name. */
void *wj_obj_impl(wj_obj *o) { return o ? o->impl : NULL; }
