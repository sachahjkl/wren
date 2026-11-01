// test_host.odin: the global wrenTest of a page given a test host (src/tools/testhost, page.set_test_host). It carries the
// results of a test program's pages to that program as typed calls of the module testhost (api/testhost.widl), instead of lines
// of the console to parse. A realm of a browser has no such global: wj_realm_start installs it on START_TEST_HOST alone.
package odin_glue

import "../odin/wj"

// A string argument, or a TypeError: what the program is told is what the script meant, nothing is converted on the way.
@(private = "file")
Text :: struct { value: cstring, n: uint }

@(private = "file")
text_arg :: proc "c" (ctx: ^wj.Context, what: cstring, argc: i32, argv: [^]wj.JSValue, i: i32, out: ^Text) -> bool {
	if i >= argc || !wj.is_string(argv[i]) {
		wj.JS_ThrowTypeError(ctx, "wrenTest.%s: argument %d is not a string", what, i + 1)
		return false
	}
	out.value = wj.to_cstring_len(ctx, &out.n, argv[i])
	return out.value != nil
}

@(private = "file") text_ptr :: #force_inline proc "contextless" (t: Text) -> [^]u8 { return ([^]u8)(rawptr(t.value)) }

// A function of one string.
@(private = "file")
of_text :: proc "c" (ctx: ^wj.Context, what: cstring, argc: i32, argv: [^]wj.JSValue, send: proc "contextless" (p: [^]u8, n: u32)) -> wj.JSValue {
	t: Text
	if !text_arg(ctx, what, argc, argv, 0, &t) { return wj.EXCEPTION }
	send(text_ptr(t), u32(t.n))
	wj.JS_FreeCString(ctx, t.value)
	return wj.UNDEFINED
}

@(private = "file")
test_begin :: proc "c" (ctx: ^wj.Context, _: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return of_text(ctx, "testBegin", argc, argv, wj.wr_TestHost_testBegin)
}

@(private = "file")
test_end :: proc "c" (ctx: ^wj.Context, _: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return of_text(ctx, "testEnd", argc, argv, wj.wr_TestHost_testEnd)
}

@(private = "file")
note :: proc "c" (ctx: ^wj.Context, _: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return of_text(ctx, "note", argc, argv, wj.wr_TestHost_note)
}

@(private = "file")
signal :: proc "c" (ctx: ^wj.Context, _: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return of_text(ctx, "signal", argc, argv, wj.wr_TestHost_signal)
}

// check(passed: boolean, what: string)
@(private = "file")
check :: proc "c" (ctx: ^wj.Context, _: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 || !wj.is_bool(argv[0]) { return wj.JS_ThrowTypeError(ctx, "wrenTest.check: argument 1 is not a boolean") }
	t: Text
	if !text_arg(ctx, "check", argc, argv, 1, &t) { return wj.EXCEPTION }
	wj.wr_TestHost_check(wj.JS_ToBool(ctx, argv[0]) != 0 ? 1 : 0, text_ptr(t), u32(t.n))
	wj.JS_FreeCString(ctx, t.value)
	return wj.UNDEFINED
}

// measure(name: string, value: number)
@(private = "file")
measure :: proc "c" (ctx: ^wj.Context, _: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	t: Text
	if !text_arg(ctx, "measure", argc, argv, 0, &t) { return wj.EXCEPTION }
	v: f64
	if argc < 2 || !wj.is_number(argv[1]) || wj.JS_ToFloat64(ctx, &v, argv[1]) != 0 {
		wj.JS_FreeCString(ctx, t.value)
		return wj.JS_ThrowTypeError(ctx, "wrenTest.measure: argument 2 is not a number")
	}
	wj.wr_TestHost_measure(text_ptr(t), u32(t.n), v)
	wj.JS_FreeCString(ctx, t.value)
	return wj.UNDEFINED
}

// skip(reason: "webgl-adapter" | "av1-decoder", why: string)
@(private = "file")
skip :: proc "c" (ctx: ^wj.Context, _: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	r, why: Text
	if !text_arg(ctx, "skip", argc, argv, 0, &r) { return wj.EXCEPTION }
	if !text_arg(ctx, "skip", argc, argv, 1, &why) { wj.JS_FreeCString(ctx, r.value); return wj.EXCEPTION }
	defer { wj.JS_FreeCString(ctx, r.value); wj.JS_FreeCString(ctx, why.value) }
	reason: wj.wr_TestSkipReason
	switch {
	case wj.str_eq(text_ptr(r), "webgl-adapter"): reason = .WebglAdapter
	case wj.str_eq(text_ptr(r), "av1-decoder"):   reason = .Av1Decoder
	case: return wj.JS_ThrowTypeError(ctx, "wrenTest.skip: no such reason: %s", r.value)
	}
	wj.wr_TestHost_skip(i32(reason), text_ptr(why), u32(why.n))
	return wj.UNDEFINED
}

@(private = "file")
done :: proc "c" (ctx: ^wj.Context, _: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_TestHost_done()
	return wj.UNDEFINED
}

// Run time, once for a realm whose page has a test host.
wj_install_test_host :: proc "contextless" (ctx: ^wj.Context) {
	o := wj.JS_NewObject(ctx)
	add :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring, fn: wj.Native, length: i32) {
		wj.JS_DefinePropertyValueStr(ctx, o, name, wj.new_cfunction(ctx, fn, name, length), wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
	}
	add(ctx, o, "testBegin", test_begin, 1)
	add(ctx, o, "testEnd", test_end, 1)
	add(ctx, o, "check", check, 2)
	add(ctx, o, "measure", measure, 2)
	add(ctx, o, "note", note, 1)
	add(ctx, o, "signal", signal, 1)
	add(ctx, o, "skip", skip, 2)
	add(ctx, o, "done", done, 0)
	global := wj.JS_GetGlobalObject(ctx)
	wj.JS_DefinePropertyValueStr(ctx, global, "wrenTest", o, wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
	wj.JS_FreeValue(ctx, global)
}
