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
