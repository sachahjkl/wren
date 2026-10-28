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
	web_stream_preinit    :: proc(ctx: ^wj.Context) -> i32 ---
	web_navigator_preinit :: proc(ctx: ^wj.Context) -> i32 ---
	web_perf_preinit      :: proc(ctx: ^wj.Context) -> i32 ---
	web_clipboard_preinit :: proc(ctx: ^wj.Context) -> i32 ---
	web_compat_preinit    :: proc(ctx: ^wj.Context) -> i32 ---
	web_fs_preinit        :: proc(ctx: ^wj.Context) -> i32 ---
	web_credentials_start :: proc(ctx: ^wj.Context, kind: i32) -> i32 ---
	web_clipboard_start   :: proc(ctx: ^wj.Context, kind: i32) -> i32 ---
	web_compat_start      :: proc(ctx: ^wj.Context, kind: i32) -> i32 ---
	web_idb_start         :: proc(ctx: ^wj.Context, kind: i32) -> i32 ---

	// native interfaces built into the image (intl.c, shadow.c, frames.c, web_idb.c)
	wj_install_intl             :: proc(ctx: ^wj.Context) ---
	wj_install_shadow           :: proc(ctx: ^wj.Context) ---
	wj_named_properties_install :: proc(ctx: ^wj.Context) -> i32 ---
	wj_install_frames           :: proc(ctx: ^wj.Context) ---
	wj_idb_define_lazy          :: proc(ctx: ^wj.Context) ---

	// realm start (clone.c)
	wj_clone_start :: proc(ctx: ^wj.Context) ---

	// events (events.c)
	wj_listeners_forget   :: proc(ctx: ^wj.Context, o: ^wj.Obj) ---
	wj_event_extra        :: proc(obj: wj.JSValue) -> ^wj.JSValue ---
	wj_dispatch_own_event :: proc(ctx: ^wj.Context, target: wj.JSValue, event: wj.JSValue) -> i32 ---
	wj_global_handle      :: proc() -> u64 ---
}
