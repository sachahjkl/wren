// m6_c_hooks.odin: the functions of the C runtime that is not ported yet which the engine's core (qjs_realm.odin,
// runtime.odin, prelude.odin, web_core.odin, load*.odin) calls, declared once. When one of these files is ported to
// Odin (package odin_glue), its line here goes: the new definition takes the same name, and the compiler reports the
// redeclaration until it does.
package odin_glue

import "../odin/wj"

@(default_calling_convention = "c")
foreign {
	// the parts of the web APIs (runtime/web*.c): what each sets up at pre-initialization and when a realm starts
	web_blob_preinit      :: proc(ctx: ^wj.Context) -> i32 ---
	web_perf_preinit      :: proc(ctx: ^wj.Context) -> i32 ---


	// realm start (clone.c)

	// events (events.c)
}
