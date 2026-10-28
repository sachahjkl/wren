package jscapi

// The C-visible side. With -define:JSCAPI_EXPORT=true every JS_* / js_* procedure of this package is exported
// under its QuickJS name, so C code that still calls the QuickJS API (the generated binding table, native/js/gen)
// links against this engine instead of quickjs.c. The throwers take printf arguments: a C caller passes them as
// wasm32 varargs (a pointer to the argument area, last parameter), which the exported versions below read.

import "base:runtime"
import js "wb:engine/jsrt"

JSCAPI_EXPORT :: #config(JSCAPI_EXPORT, false)

// A wasm32 C varargs area: the arguments in order, each at its natural alignment (i32 and pointers 4, i64 and
// double 8).
@(private)
Va :: struct {
	p: uintptr,
}

@(private)
va_align :: #force_inline proc "contextless" (v: ^Va, n: uintptr) {
	v.p = (v.p + n - 1) & ~(n - 1)
}

@(private)
va_i32 :: proc "contextless" (v: ^Va) -> i32 {
	va_align(v, 4)
	x := (^i32)(v.p)^
	v.p += 4
	return x
}

@(private)
va_i64 :: proc "contextless" (v: ^Va) -> i64 {
	va_align(v, 8)
	x := (^i64)(v.p)^
	v.p += 8
	return x
}

@(private)
va_f64 :: proc "contextless" (v: ^Va) -> f64 {
	va_align(v, 8)
	x := (^f64)(v.p)^
	v.p += 8
	return x
}

@(private)
format_va :: proc(f: cstring, area: rawptr, alloc: runtime.Allocator) -> string {
	out := make([dynamic]u8, 0, 64, alloc)
	va := Va{uintptr(area)}
	fs := string(f)
	i := 0
	for i < len(fs) {
		ch := fs[i]
		i += 1
		if ch != '%' {
			append(&out, ch)
			continue
		}
		prec := -1
		longs := 0
		for i < len(fs) && (fs[i] == 'l' || fs[i] == 'z' || fs[i] == 'j' || fs[i] == 't' || fs[i] == 'h') {
			if fs[i] == 'l' {longs += 1}
			i += 1
		}
		if i + 1 < len(fs) && fs[i] == '.' && fs[i + 1] == '*' {
			prec = int(va_i32(&va))
			i += 2
		}
		if i >= len(fs) {break}
		spec := fs[i]
		i += 1
		switch spec {
		case '%': append(&out, '%')
		case 's':
			p := cast(cstring)rawptr(uintptr(va_i32(&va)))
			s := p == nil ? "(null)" : string(p)
			if prec >= 0 && prec < len(s) {s = s[:prec]}
			append(&out, ..transmute([]u8)s)
		case 'd', 'i':
			put_int(&out, longs >= 2 ? va_i64(&va) : i64(va_i32(&va)), false)
		case 'u':
			put_int(&out, longs >= 2 ? va_i64(&va) : i64(u32(va_i32(&va))), true)
		case 'c': append(&out, u8(va_i32(&va)))
		case 'x', 'X':
			v := longs >= 2 ? u64(va_i64(&va)) : u64(u32(va_i32(&va)))
			digits := spec == 'X' ? "0123456789ABCDEF" : "0123456789abcdef"
			tmp: [16]u8
			n := 0
			for {
				tmp[n] = digits[v & 15]
				n += 1
				v >>= 4
				if v == 0 {break}
			}
			for k := n - 1; k >= 0; k -= 1 {append(&out, tmp[k])}
		case 'f', 'g', 'e':
			_ = va_f64(&va) // numbers are not formatted
			append(&out, '?')
		case: append(&out, '%', spec)
		}
	}
	return string(out[:])
}

@(private)
throw_va :: proc(c: ^Context, kind: js.Error_Kind, f: cstring, area: rawptr) -> JSValue {
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	msg := format_va(f, area, js.tmp(ctx.rt))
	return enc(js.throw_error(ctx, kind, msg))
}

@(export = JSCAPI_EXPORT, link_name = "JS_ThrowTypeError")
c_throw_type_error :: proc "c" (c: ^Context, fmt: cstring, va: rawptr) -> JSValue {
	context = api_ctx()
	return throw_va(c, .type, fmt, va)
}

@(export = JSCAPI_EXPORT, link_name = "JS_ThrowRangeError")
c_throw_range_error :: proc "c" (c: ^Context, fmt: cstring, va: rawptr) -> JSValue {
	context = api_ctx()
	return throw_va(c, .range, fmt, va)
}

@(export = JSCAPI_EXPORT, link_name = "JS_ThrowReferenceError")
c_throw_reference_error :: proc "c" (c: ^Context, fmt: cstring, va: rawptr) -> JSValue {
	context = api_ctx()
	return throw_va(c, .reference, fmt, va)
}

@(export = JSCAPI_EXPORT, link_name = "JS_ThrowSyntaxError")
c_throw_syntax_error :: proc "c" (c: ^Context, fmt: cstring, va: rawptr) -> JSValue {
	context = api_ctx()
	return throw_va(c, .syntax, fmt, va)
}

@(export = JSCAPI_EXPORT, link_name = "JS_ThrowInternalError")
c_throw_internal_error :: proc "c" (c: ^Context, fmt: cstring, va: rawptr) -> JSValue {
	context = api_ctx()
	return throw_va(c, .internal, fmt, va)
}
