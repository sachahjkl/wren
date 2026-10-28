// m4_common.odin: what the M4 domains (messaging, workers, cloning, navigation, service workers, performance, locks,
// scheduler, navigator, devtools, compat) share: lazily resolved interface indices, the Odin context they run in, and
// small value helpers over the wj layer.
package odin_glue

import "base:runtime"
import "../odin/wj"

// The context of an Odin-convention procedure of these domains: the libc heap as allocator (dynamic arrays, maps and
// builders made here are plain libc blocks).
m4_context :: #force_inline proc "contextless" () -> runtime.Context { return wj.heap_context() }

// An interface index resolved by name once (slot starts at -2: not looked up yet).
iface_lazy :: #force_inline proc "contextless" (slot: ^i32, name: cstring) -> i32 {
	if slot^ == -2 { slot^ = wj.iface(name) }
	return slot^
}

// Is `v` a platform object of the interface `slot` names (or of a descendant)?
is_a :: #force_inline proc "contextless" (v: wj.JSValue, slot: ^i32, name: cstring) -> bool {
	return wj.wj_unwrap(v, iface_lazy(slot, name)) != nil
}

// Odin bytes of a NUL-free cstring / of a converted string, for comparisons and host calls.
cstr_string :: #force_inline proc "contextless" (s: cstring) -> string { return s != nil ? string(s) : "" }
str_view    :: #force_inline proc "contextless" (s: wj.Str) -> string { return s.ptr != nil ? string(s.ptr[:s.len]) : "" }

// A JS string of Odin bytes.
js_string :: #force_inline proc "contextless" (ctx: ^wj.Context, s: string) -> wj.JSValue { return wj.new_string_len(ctx, s) }

// Free several values at once.
free_values :: proc "contextless" (ctx: ^wj.Context, vs: ..wj.JSValue) {
	for v in vs { wj.JS_FreeValue(ctx, v) }
}

// The text of a JS value converted with ToString, as Odin bytes owned by the engine until free_cstring (nil on a
// throw: an exception is pending).
to_text :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> (cstring, string) {
	n: uint
	c := wj.JS_ToCStringLen2(ctx, &n, v, false)
	if c == nil { return nil, "" }
	return c, string(([^]u8)(rawptr(c))[:n])
}

// Object.freeze(v) with the realm's Object (the result dropped).
freeze :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) {
	object := wj.global_get(ctx, "Object")
	args := [1]wj.JSValue{v}
	r := wj.invoke(ctx, object, "freeze", args[:])
	wj.JS_FreeValue(ctx, r)
	wj.JS_FreeValue(ctx, object)
}

// target.addEventListener(type, listener) through the object's own method (a target without one is left as is).
add_listener :: proc "contextless" (ctx: ^wj.Context, target: wj.JSValue, type: cstring, listener: wj.JSValue) {
	add := wj.JS_GetPropertyStr(ctx, target, "addEventListener")
	defer wj.JS_FreeValue(ctx, add)
	if !wj.JS_IsFunction(ctx, add) { return }
	args := [2]wj.JSValue{wj.new_string(ctx, type), listener}
	r := wj.JS_Call(ctx, add, target, 2, &args[0])
	free_values(ctx, r, args[0])
}

// The realm's origin (globalThis.origin) as a JS value (counted), or "" when it is not a string.
realm_origin :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	o := wj.global_get(ctx, "origin")
	if wj.is_string(o) { return o }
	wj.JS_FreeValue(ctx, o)
	return wj.new_string(ctx, "")
}
