// m6_load.odin: the two helpers of script loading other parts of the engine call (ported from native/js/runtime/load.c,
// same symbols; the rest of load.c is native/js/odin/load.odin): the name of code without a script of its own, and
// HostEnsureCanCompileStrings.
package wj

// The URL naming code without a script of its own (handlers, timer strings): the document's. NUL-terminated in `out`.
@(export, link_name = "wj_script_base_name")
wj_script_base_name :: proc "c" (out: [^]u8, cap: uint) -> uint {
	n := fetch_string(wr_Script_baseName)
	size := n > 0 ? uint(n) : 0
	if size >= cap { size = cap - 1 }
	if size > 0 { memcpy(out, wj_scratch.data, size) }
	out[size] = 0
	return size
}

// HostEnsureCanCompileStrings: false with an EvalError pending when the page's policy refuses (reported by the browser).
@(export, link_name = "wj_can_compile_string")
wj_can_compile_string :: proc "c" (ctx: ^Context, source: JSValue) -> bool {
	n: uint
	s := JS_ToCStringLen2(ctx, &n, source, false)
	if s == nil { return false }
	ok := wr_Script_allowEval(([^]u8)(rawptr(s)), u32(n)) != 0
	JS_FreeCString(ctx, s)
	if ok { return true }
	ctor := JS_GetPropertyStr(ctx, wj_the_realm.global, "EvalError")
	msg := JS_NewString(ctx, "Refused to evaluate a string as JavaScript because 'unsafe-eval' is not an allowed source of script in the Content Security Policy of this document.")
	err := JS_CallConstructor(ctx, ctor, 1, &msg)
	JS_FreeValue(ctx, msg)
	JS_FreeValue(ctx, ctor)
	if !is_exception(err) { JS_Throw(ctx, err) }
	return false
}
