// runtime.odin: the hand-written parts of the realm that are not members of one interface: what pre-initialization
// adds after the generated interfaces, and what each realm sets up when it starts (ported from
// native/js/runtime/runtime.c). wj/qjs_platform.odin calls both once the interface objects exist.
package odin_glue

import "../odin/wj"

// Engine-only globals the bindings do not describe.
@(export, link_name = "wj_runtime_preinit")
wj_runtime_preinit :: proc "c" (ctx: ^wj.Context) -> i32 {
	if wj.wj_interface_find("console") < 0 { wj_install_console(ctx, wj.wj_the_realm.global) }
	// Intl (ECMA-402): a native namespace built into the image, in place of the old prelude/intl.js
	wj_install_intl(ctx)
	wj_tracks_install()
	// what the DOM bindings set up once the interfaces exist (dom_style.odin: CSS property attributes)
	if wj_dom_preinit(ctx) < 0 { return -1 }
	if wj_run_preludes(ctx) != 0 { return -1 }
	return wj_web_preinit(ctx)
}

@(export, link_name = "wj_runtime_start")
wj_runtime_start :: proc "c" (ctx: ^wj.Context, kind: i32) -> i32 {
	r := &wj.wj_the_realm
	// window / self / globalThis name the global object itself in every realm
	self := wj.JS_NewAtom(ctx, "self")
	cur := wj.JS_GetProperty(ctx, r.global, self)
	if wj.is_undefined(cur) {
		wj.JS_DefinePropertyValue(ctx, r.global, self, wj.JS_DupValue(ctx, r.global), wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE | wj.PROP_ENUMERABLE)
	}
	wj.JS_FreeValue(ctx, cur)
	wj.JS_FreeAtom(ctx, self)
	// HTML §3.1: "for historical reasons" window.HTMLDocument is the Document interface object (writable, configurable,
	// not enumerable)
	if kind == wj.EXPOSE_WINDOW {
		doc := wj.JS_GetPropertyStr(ctx, r.global, "Document")
		if wj.is_object(doc) {
			wj.JS_DefinePropertyValueStr(ctx, r.global, "HTMLDocument", doc, wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
		} else {
			wj.JS_FreeValue(ctx, doc)
		}
		// the Window's named properties (elements by id as globals: runtime/shadow.c)
		wj_named_properties_install(ctx)
	}
	return wj_web_start(ctx, kind)
}
