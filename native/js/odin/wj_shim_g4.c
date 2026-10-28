/* wj_shim_g4.c: tiny C accessors the G4 Odin glue needs for state that has no symbol of its own — the realm's scratch
 * buffer, the prototype table and the handle at the head of a wj_obj. Like wj_shim.c, this holds no logic: each
 * accessor is one field read, so the Odin glue does not have to mirror the (changing) C struct layouts. They shrink as
 * more of the engine moves to Odin. See docs/js/odin-glue.md ("Three kinds of symbol"). */
#include "../engine/wj.h"

uint8_t *wj_g4_scratch_data(void) { return wj_scratch.data; }
uint32_t wj_g4_scratch_cap(void) { return wj_scratch.cap; }

/* wj_obj.handle is the first field (offset 0); the accessor keeps the glue independent of the rest of the layout. */
uint64_t wj_g4_obj_handle(void *o) { return o ? ((wj_obj *)o)->handle : 0; }

/* wj_the_realm.protos[iface]: the prototype object of an interface (not counted). */
JSValue wj_g4_realm_proto(int iface) { return wj_the_realm.protos[iface]; }

/* wj_the_realm.ctx: the realm's JSContext (a browser callback that enters from nothing needs it). */
JSContext *wj_g4_realm_ctx(void) { return wj_the_realm.ctx; }
