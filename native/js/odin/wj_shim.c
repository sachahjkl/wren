/* wj_shim.c: the few engine things the Odin glue layer (native/js/odin/wj) cannot name directly.
 *
 * Odin resolves an engine symbol through wasm-ld, so a function with a real symbol needs no shim. What needs one is
 * anything that is a `static inline`, a macro, or a *field of a global struct* in the C headers, because those have no
 * symbol to link against. Today that is only the realm's global object (wj_the_realm.global, a field). Keeping this as
 * one tiny C accessor avoids mirroring wj_realm's layout in Odin (fragile) until wj_the_realm itself is ported.
 *
 * This file is compiled by zig cc with the engine's other C (tools/build_js.ps1) and shrinks as more of the glue moves
 * to Odin. It deliberately does NOT grow into logic: it exposes state, nothing more. */
#include "wj.h"

/* The realm's global object (not counted). */
wj_val wj_realm_global(void) { return wj_the_realm.global; }

/* The realm's context. A field of wj_the_realm, so no symbol; the Odin glue needs it for the browser->guest entry
 * points it owns (wj_shared_connect, wj_port_message...) that start from the realm rather than from a JSContext arg. */
wj_ctx *wj_realm_ctx(void) { return wj_the_realm.ctx; }

/* The realm's kind: WJ_EXPOSE_WINDOW or WJ_EXPOSE_WORKER (web_is_window() == kind != WORKER). */
int wj_realm_kind(void) { return wj_the_realm.kind; }

/* The prototype object of interface `iface` (wj_the_realm.protos[iface]); undefined when the realm has none. */
wj_val wj_realm_proto(int iface) { return wj_the_realm.protos[iface]; }

/* The scratch buffer (wj_scratch) used by WJ_FETCH_STRING: its data pointer and capacity. A browser function fills it
 * up to `cap`; the Odin glue grows it with wj_scratch_grow (a real symbol) and reads the bytes back. */
uint8_t *wj_scratch_data(void) { return wj_scratch.data; }
uint32_t wj_scratch_cap(void) { return wj_scratch.cap; }

/* The engine-owned data of a platform object (wj_obj.impl), for the glue that has a wj_obj* from wj_unwrap (where no
 * web_this_impl shortcut applies). A field accessor, like the ones above: it mirrors no layout in Odin. */
void *wj_obj_impl(wj_obj *o) { return o ? o->impl : 0; }
