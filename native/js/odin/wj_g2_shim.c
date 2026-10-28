/* wj_g2_shim.c: the few engine things the G2 Odin glue (native/js/odin/web_*.odin ported by agent g2) cannot name
 * directly, in the same spirit as wj_shim.c: fields of global structs and `static inline` helpers have no symbol for
 * wasm-ld to resolve, so a one-line C accessor exposes them. This file holds no logic; it shrinks as the engine's
 * structs (wj_obj, wj_realm) themselves move to Odin.
 *
 * Compiled by zig cc with the engine's other C (tools/build_js.ps1, alongside wj_shim.c). */
#include "web.h"

/* wj_obj_of is a `static inline` (qjs_internal.h): expose the two fields the glue reads off a platform object. */
uint64_t wj_g2_obj_handle(JSValueConst v) { wj_obj *o = wj_obj_of(v); return o ? o->handle : 0; }
void    *wj_g2_obj_impl(JSValueConst v)   { wj_obj *o = wj_obj_of(v); return o ? o->impl : NULL; }

/* handle off a wj_obj* (wj_this / wj_unwrap return one; `handle` is the first field but reading it from Odin would
 * mirror wj_obj's layout, which the spike note warns against). */
uint64_t wj_g2_handle(const void *obj) { return obj ? ((const wj_obj *)obj)->handle : 0; }
void    *wj_g2_impl(const void *obj)   { return obj ? ((const wj_obj *)obj)->impl : NULL; }

/* The prototype object of an interface (wj_the_realm.protos[iface], a field): web_crypto deletes [SecureContext]
 * members off it when the document is not a secure context. */
JSValue wj_g2_proto(int iface) { return wj_the_realm.protos[iface]; }
