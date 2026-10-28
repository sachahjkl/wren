// console.odin: the console namespace (Console Standard), ported from native/js/runtime/console.c. Same symbols
// (wjr_console_*, the non-wjr wj_console_inspect_result and wj_install_console used by runtime.c and the dev tools) and
// behaviour: arguments are formatted the way browsers show them on a single line (strings as is at the top level,
// quoted inside objects; arrays, objects, errors with their stack, functions, symbols, depth- and length-limited),
// printf-style substitutions (%s %d %i %f %o %O %c) applied to the first argument, then sent to the browser's console
// with their level. Counters, timers and group indentation are kept per realm. See docs/js/odin-glue.md.
//
// (The weak hook wj_describe_node of the C version is never defined — its struct parameter is console.c's private
// type, so no external definer can match it — so the DOM-node short form it would add is dropped here: equivalent to
// the C where the symbol is null. A node still prints as "ConstructorName {}".)
package odin_glue

import "../odin/wj"

// browser console levels (wren_api.h wj.wr_ConsoleLevel).
@(private = "file") LEVEL_LOG   :: 0
@(private = "file") LEVEL_INFO  :: 1
@(private = "file") LEVEL_WARN  :: 2
@(private = "file") LEVEL_ERROR :: 3
@(private = "file") LEVEL_DEBUG :: 4

@(private = "file") INSPECT_MAX_DEPTH  :: 2
@(private = "file") INSPECT_MAX_ITEMS  :: 100
@(private = "file") INSPECT_MAX_STRING :: 10000

@(private = "file") console_indent: i32

// Byte-pointer literals (Odin cannot cast a constant cstring to a pointer at comptime; these are initialised data).
@(private = "file") LIT_EMPTY   := [1]u8{0}
@(private = "file") LIT_OBJECT  := [7]u8{'O','b','j','e','c','t',0}
@(private = "file") LIT_SUBST   := [8]u8{'s','d','i','f','o','O','c',0}
@(private = "file") LIT_DEFAULT := [8]u8{'d','e','f','a','u','l','t',0}

@(private = "file") empty_bytes :: #force_inline proc "contextless" () -> [^]u8 { return ([^]u8)(&LIT_EMPTY[0]) }
@(private = "file") default_bytes :: #force_inline proc "contextless" () -> [^]u8 { return ([^]u8)(&LIT_DEFAULT[0]) }

// ---- a growable byte builder over libc (matches console.c's sb) ----
@(private = "file")
SB :: struct { p: [^]u8, n: uint, cap: uint }

@(private = "file")
sb_put :: proc "contextless" (b: ^SB, s: [^]u8, n: uint) {
	if b.n + n + 1 > b.cap {
		c := b.cap != 0 ? b.cap : 128
		for c < b.n + n + 1 { c *= 2 }
		q := ([^]u8)(wj.libc_realloc(b.p, c))
		if q == nil { return }
		b.p = q
		b.cap = c
	}
	if n > 0 { wj.memcpy(&b.p[b.n], s, n) }
	b.n += n
	b.p[b.n] = 0
}
@(private = "file") sb_str :: #force_inline proc "contextless" (b: ^SB, s: cstring) { sb_put(b, ([^]u8)(rawptr(s)), len(s)) }
@(private = "file") sb_byte :: #force_inline proc "contextless" (b: ^SB, c: u8) { ch := c; sb_put(b, &ch, 1) }

@(private = "file")
put_js_string :: proc "c" (ctx: ^wj.Context, b: ^SB, v: wj.JSValue, quoted: bool) {
	n: uint
	s := wj.to_cstring_len(ctx, &n, v)
	if s == nil { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); sb_str(b, "?"); return }
	if n > INSPECT_MAX_STRING { n = INSPECT_MAX_STRING }
	p := ([^]u8)(rawptr(s))
	if quoted {
		sb_byte(b, '\'')
		for i: uint = 0; i < n; i += 1 {
			c := p[i]
			switch c {
			case '\'': sb_str(b, "\\'")
			case '\n': sb_str(b, "\\n")
			case '\\': sb_str(b, "\\\\")
			case:      sb_put(b, &p[i], 1)
			}
		}
		sb_byte(b, '\'')
	} else {
		sb_put(b, p, n)
	}
	wj.JS_FreeCString(ctx, s)
}

@(private = "file")
put_key :: proc "c" (ctx: ^wj.Context, b: ^SB, atom: wj.Atom) {
	k := wj.JS_AtomToValue(ctx, atom)
	if wj.is_symbol(k) { sb_byte(b, '['); put_js_string(ctx, b, k, false); sb_byte(b, ']'); wj.JS_FreeValue(ctx, k); return }
	n: uint
	s := wj.to_cstring_len(ctx, &n, k)
	wj.JS_FreeValue(ctx, k)
	if s == nil { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return }
	p := ([^]u8)(rawptr(s))
	ident := n > 0 && !(p[0] >= '0' && p[0] <= '9')
	for i: uint = 0; i < n && ident; i += 1 {
		c := p[i]
		ident = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$'
	}
	if ident { sb_put(b, p, n) } else { sb_byte(b, '\''); sb_put(b, p, n); sb_byte(b, '\'') }
	wj.JS_FreeCString(ctx, s)
}

@(private = "file")
inspect_object :: proc "c" (ctx: ^wj.Context, b: ^SB, v: wj.JSValue, depth: i32) {
	if wj.JS_IsFunction(ctx, v) {
		name := wj.JS_GetPropertyStr(ctx, v, "name")
		n: uint = 0
		s := wj.is_string(name) ? wj.to_cstring_len(ctx, &n, name) : nil
		sb_str(b, "[Function")
		if s != nil && n != 0 { sb_str(b, ": "); sb_put(b, ([^]u8)(rawptr(s)), n) } else { sb_str(b, " (anonymous)") }
		sb_str(b, "]")
		if s != nil { wj.JS_FreeCString(ctx, s) }
		wj.JS_FreeValue(ctx, name)
		return
	}
	if wj.JS_IsError(v) {
		st := wj.JS_GetPropertyStr(ctx, v, "stack")
		str := wj.JS_ToString(ctx, v)
		put_js_string(ctx, b, str, false)
		wj.JS_FreeValue(ctx, str)
		if wj.is_string(st) {
			n: uint
			s := wj.to_cstring_len(ctx, &n, st)
			if s != nil && n != 0 { sb_str(b, "\n"); sb_put(b, ([^]u8)(rawptr(s)), n); for b.n != 0 && b.p[b.n - 1] == '\n' { b.n -= 1; b.p[b.n] = 0 } }
			if s != nil { wj.JS_FreeCString(ctx, s) }
		}
		wj.JS_FreeValue(ctx, st)
		return
	}
	if wj.JS_IsDate(v) || wj.JS_IsRegExp(v) {
		s := wj.JS_ToString(ctx, v)
		put_js_string(ctx, b, s, false)
		wj.JS_FreeValue(ctx, s)
		return
	}
	array := wj.JS_IsArray(v)
	if depth > INSPECT_MAX_DEPTH { sb_str(b, wj.JS_IsPromise(v) ? "[Promise]" : (array ? "[Array]" : "[Object]")); return }
	if wj.JS_IsPromise(v) {
		st := wj.JS_PromiseState(ctx, v)
		sb_str(b, "Promise {")
		if st == .Pending { sb_str(b, " <pending>") } else {
			r := wj.JS_PromiseResult(ctx, v)
			sb_str(b, st == .Rejected ? " <rejected> " : " ")
			inspect(ctx, b, r, depth + 1, false)
			wj.JS_FreeValue(ctx, r)
		}
		sb_str(b, " }")
		return
	}
	if array {
		length: i64 = 0
		if wj.JS_GetLength(ctx, v, &length) < 0 { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)) }
		sb_str(b, "[")
		for i: i64 = 0; i < length && i < INSPECT_MAX_ITEMS; i += 1 {
			if i != 0 { sb_str(b, ", ") } else { sb_str(b, " ") }
			e := wj.JS_GetPropertyInt64(ctx, v, i)
			inspect(ctx, b, e, depth + 1, false)
			wj.JS_FreeValue(ctx, e)
		}
		if length > INSPECT_MAX_ITEMS {
			t: [64]u8
			wj.snprintf(&t[0], size_of(t), ", ... %lld more items", i64(length - INSPECT_MAX_ITEMS))
			sb_str(b, cstring(&t[0]))
		}
		sb_str(b, length != 0 ? " ]" : "]")
		return
	}
	// constructor name prefix for class instances ("Foo { a: 1 }"), none for plain objects
	ctor := wj.JS_GetPropertyStr(ctx, v, "constructor")
	if wj.JS_HasException(ctx) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)) }
	if wj.JS_IsFunction(ctx, ctor) {
		name := wj.JS_GetPropertyStr(ctx, ctor, "name")
		n: uint = 0
		s := wj.is_string(name) ? wj.to_cstring_len(ctx, &n, name) : nil
		if s != nil && n != 0 && wj.strcmp(([^]u8)(rawptr(s)), raw_data(LIT_OBJECT[:])) != 0 { sb_put(b, ([^]u8)(rawptr(s)), n); sb_str(b, " ") }
		if s != nil { wj.JS_FreeCString(ctx, s) }
		wj.JS_FreeValue(ctx, name)
	}
	wj.JS_FreeValue(ctx, ctor)
	tab: [^]wj.Property_Enum
	count: u32 = 0
	if wj.JS_GetOwnPropertyNames(ctx, &tab, &count, v, wj.GPN_STRING_MASK | wj.GPN_SYMBOL_MASK | wj.GPN_ENUM_ONLY) < 0 {
		wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))
		sb_str(b, "{}")
		return
	}
	sb_str(b, "{")
	for i: u32 = 0; i < count; i += 1 {
		if i >= INSPECT_MAX_ITEMS { sb_str(b, ", ..."); break }
		sb_str(b, i != 0 ? ", " : " ")
		put_key(ctx, b, tab[i].atom)
		sb_str(b, ": ")
		e := wj.JS_GetProperty(ctx, v, tab[i].atom)
		if wj.is_exception(e) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); sb_str(b, "[Exception]") } else { inspect(ctx, b, e, depth + 1, false) }
		wj.JS_FreeValue(ctx, e)
	}
	sb_str(b, count != 0 ? " }" : "}")
	wj.JS_FreePropertyEnum(ctx, tab, count)
}

@(private = "file")
inspect :: proc "c" (ctx: ^wj.Context, b: ^SB, v: wj.JSValue, depth: i32, top: bool) {
	if wj.is_string(v) { put_js_string(ctx, b, v, !top); return }
	if wj.is_symbol(v) {
		d := wj.JS_GetPropertyStr(ctx, v, "description")
		sb_str(b, "Symbol(")
		if wj.is_string(d) { put_js_string(ctx, b, d, false) }
		sb_str(b, ")")
		wj.JS_FreeValue(ctx, d)
		return
	}
	if wj.is_big_int(v) {
		s := wj.JS_ToString(ctx, v)
		put_js_string(ctx, b, s, false)
		sb_str(b, "n")
		wj.JS_FreeValue(ctx, s)
		return
	}
	if wj.is_object(v) { inspect_object(ctx, b, v, depth); return }
	// numbers (-0 shown as such), booleans, null, undefined
	if wj.is_number(v) {
		d: f64
		wj.JS_ToFloat64(ctx, &d, v)
		if d == 0 && (transmute(u64)d) >> 63 != 0 { sb_str(b, "-0"); return }
	}
	s := wj.JS_ToString(ctx, v)
	put_js_string(ctx, b, s, false)
	wj.JS_FreeValue(ctx, s)
}

// Formats arguments like console.log: substitutions in a string first argument, then the rest separated by spaces.
@(private = "file")
format_args :: proc "c" (ctx: ^wj.Context, b: ^SB, argc: i32, argv: [^]wj.JSValue) {
	for i: i32 = 0; i < console_indent; i += 1 { sb_str(b, "  ") }
	next: i32 = 0
	if argc > 0 && wj.is_string(argv[0]) {
		n: uint
		f := wj.to_cstring_len(ctx, &n, argv[0])
		next = 1
		if f != nil {
			fp := ([^]u8)(rawptr(f))
			for i: uint = 0; i < n; i += 1 {
				if fp[i] != '%' || i + 1 >= n { sb_put(b, &fp[i], 1); continue }
				c := fp[i + 1]
				if c == '%' { sb_byte(b, '%'); i += 1; continue }
				if wj.strchr(raw_data(LIT_SUBST[:]), i32(c)) == nil { sb_put(b, &fp[i], 1); continue }
				i += 1
				if next >= argc { sb_put(b, &fp[i - 1], 2); continue }
				a := argv[next]; next += 1
				switch c {
				case 's': inspect(ctx, b, a, 1, true)
				case 'd', 'i':
					d: f64
					if wj.is_symbol(a) || wj.JS_ToFloat64(ctx, &d, a) < 0 { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); sb_str(b, "NaN"); break }
					t: [64]u8
					if d != d { wj.snprintf(&t[0], size_of(t), "NaN") } else { wj.snprintf(&t[0], size_of(t), "%.0f", wj.trunc(d)) }
					sb_str(b, cstring(&t[0]))
				case 'f':
					d: f64
					if wj.is_symbol(a) || wj.JS_ToFloat64(ctx, &d, a) < 0 { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); sb_str(b, "NaN"); break }
					s := wj.new_float64(ctx, d)
					inspect(ctx, b, s, 1, true)
				case 'c': // CSS styling: ignored by a text console
				case: inspect(ctx, b, a, 0, false)
				}
			}
			wj.JS_FreeCString(ctx, f)
		}
	}
	for i := next; i < argc; i += 1 {
		if b.n > 0 && i > 0 { sb_str(b, " ") }
		inspect(ctx, b, argv[i], 0, true)
	}
}

@(private = "file")
console_emit :: proc "c" (ctx: ^wj.Context, level: i32, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b: SB
	format_args(ctx, &b, argc, argv)
	wj.wj_console_text(level, b.p != nil ? b.p : empty_bytes(), b.n)
	wj.libc_free(b.p)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_console_log")   wjr_console_log   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return console_emit(ctx, LEVEL_LOG, argc, argv) }
@(export, link_name = "wjr_console_info")  wjr_console_info  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return console_emit(ctx, LEVEL_INFO, argc, argv) }
@(export, link_name = "wjr_console_warn")  wjr_console_warn  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return console_emit(ctx, LEVEL_WARN, argc, argv) }
@(export, link_name = "wjr_console_error") wjr_console_error :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return console_emit(ctx, LEVEL_ERROR, argc, argv) }
@(export, link_name = "wjr_console_debug") wjr_console_debug :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return console_emit(ctx, LEVEL_DEBUG, argc, argv) }

@(export, link_name = "wjr_console_trace")
wjr_console_trace :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b: SB
	sb_str(&b, "Trace")
	if argc != 0 { sb_str(&b, ": "); format_args(ctx, &b, argc, argv) }
	err := wj.JS_NewError(ctx)
	st := wj.JS_GetPropertyStr(ctx, err, "stack")
	if wj.is_string(st) { sb_str(&b, "\n"); put_js_string(ctx, &b, st, false) }
	wj.JS_FreeValue(ctx, st)
	wj.JS_FreeValue(ctx, err)
	wj.wj_console_text(LEVEL_LOG, b.p != nil ? b.p : empty_bytes(), b.n)
	wj.libc_free(b.p)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_console_assert")
wjr_console_assert :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc > 0 && wj.JS_ToBool(ctx, argv[0]) != 0 { return wj.UNDEFINED }
	b: SB
	sb_str(&b, "Assertion failed")
	if argc > 1 { sb_str(&b, ": "); format_args(ctx, &b, argc - 1, argv[1:]) }
	wj.wj_console_text(LEVEL_ERROR, b.p != nil ? b.p : empty_bytes(), b.n)
	wj.libc_free(b.p)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_console_group")
wjr_console_group :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc != 0 { console_emit(ctx, LEVEL_LOG, argc, argv) }
	console_indent += 1
	return wj.UNDEFINED
}
@(export, link_name = "wjr_console_groupEnd")
wjr_console_groupEnd :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if console_indent > 0 { console_indent -= 1 }
	return wj.UNDEFINED
}

// labels for count / time: a small list, one per realm
@(private = "file")
Label :: struct { next: ^Label, name: [^]u8, value: f64 }
@(private = "file") counts: ^Label
@(private = "file") timers_labels: ^Label

@(private = "file")
find_label :: proc "contextless" (list: ^^Label, name: [^]u8, create: bool) -> ^Label {
	for l := list^; l != nil; l = l.next { if wj.strcmp(l.name, name) == 0 { return l } }
	if !create { return nil }
	l := (^Label)(wj.libc_calloc(1, size_of(Label)))
	if l == nil { return nil }
	l.name = wj.libc_strdup(name)
	l.next = list^
	list^ = l
	return l
}

@(private = "file")
drop_label :: proc "contextless" (list: ^^Label, x: ^Label) {
	p := list
	for p^ != nil {
		if p^ == x { p^ = x.next; wj.libc_free(x.name); wj.libc_free(x); return }
		p = &p^.next
	}
}

@(private = "file")
label_arg :: proc "c" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue) -> cstring {
	if argc == 0 || wj.is_undefined(argv[0]) { return nil }
	return wj.to_cstring_len(ctx, nil, argv[0])
}

@(export, link_name = "wjr_console_count")
wjr_console_count :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := label_arg(ctx, argc, argv)
	if argc != 0 && s == nil && !wj.is_undefined(argv[0]) { return wj.EXCEPTION }
	name := s != nil ? ([^]u8)(rawptr(s)) : default_bytes()
	l := find_label(&counts, name, true)
	value := l != nil ? (l.value + 1) : 0
	if l != nil { l.value = value }
	tbuf: [600]u8
	m := wj.snprintf(&tbuf[0], size_of(tbuf), "%s: %.0f", name, value)
	wj.wj_console_text(LEVEL_INFO, &tbuf[0], m > 0 ? uint(m) : 0)
	if s != nil { wj.JS_FreeCString(ctx, s) }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_console_countReset")
wjr_console_countReset :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := label_arg(ctx, argc, argv)
	name := s != nil ? ([^]u8)(rawptr(s)) : default_bytes()
	l := find_label(&counts, name, false)
	if l != nil { l.value = 0 }
	if s != nil { wj.JS_FreeCString(ctx, s) }
	return wj.UNDEFINED
}

@(private = "file") console_now :: proc "contextless" () -> f64 { return wj.wr_Performance_now() }

@(export, link_name = "wjr_console_time")
wjr_console_time :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := label_arg(ctx, argc, argv)
	name := s != nil ? ([^]u8)(rawptr(s)) : default_bytes()
	if find_label(&timers_labels, name, false) != nil {
		tbuf: [600]u8
		m := wj.snprintf(&tbuf[0], size_of(tbuf), "Timer '%s' already exists", name)
		wj.wj_console_text(LEVEL_WARN, &tbuf[0], m > 0 ? uint(m) : 0)
	} else {
		l := find_label(&timers_labels, name, true)
		if l != nil { l.value = console_now() }
	}
	if s != nil { wj.JS_FreeCString(ctx, s) }
	return wj.UNDEFINED
}

@(private = "file")
console_time_report :: proc "c" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, end: bool) -> wj.JSValue {
	s := label_arg(ctx, argc, argv)
	name := s != nil ? ([^]u8)(rawptr(s)) : default_bytes()
	l := find_label(&timers_labels, name, false)
	tbuf: [700]u8
	if l == nil {
		m := wj.snprintf(&tbuf[0], size_of(tbuf), "Timer '%s' does not exist", name)
		wj.wj_console_text(LEVEL_WARN, &tbuf[0], m > 0 ? uint(m) : 0)
	} else {
		b: SB
		m := wj.snprintf(&tbuf[0], size_of(tbuf), "%s: %.3f ms", name, console_now() - l.value)
		sb_put(&b, &tbuf[0], m > 0 ? uint(m) : 0)
		if !end && argc > 1 { sb_str(&b, " "); format_args(ctx, &b, argc - 1, argv[1:]) }
		wj.wj_console_text(LEVEL_INFO, b.p != nil ? b.p : empty_bytes(), b.n)
		wj.libc_free(b.p)
		if end { drop_label(&timers_labels, l) }
	}
	if s != nil { wj.JS_FreeCString(ctx, s) }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_console_timeLog") wjr_console_timeLog :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return console_time_report(ctx, argc, argv, false) }
@(export, link_name = "wjr_console_timeEnd") wjr_console_timeEnd :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return console_time_report(ctx, argc, argv, true) }

@(export, link_name = "wjr_console_dir")
wjr_console_dir :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b: SB
	if argc != 0 { inspect(ctx, &b, argv[0], 0, false) }
	wj.wj_console_text(LEVEL_LOG, b.p != nil ? b.p : empty_bytes(), b.n)
	wj.libc_free(b.p)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_console_groupCollapsed") wjr_console_groupCollapsed :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return wjr_console_group(ctx, t, argc, argv) }
@(export, link_name = "wjr_console_dirxml") wjr_console_dirxml :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return wjr_console_dir(ctx, t, argc, argv) }
@(export, link_name = "wjr_console_table") wjr_console_table :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return wjr_console_log(ctx, t, argc, argv) }

@(export, link_name = "wjr_console_clear")
wjr_console_clear :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	console_indent = 0
	return wj.UNDEFINED
}

// The completion value of a script run from the browser's console ("run JavaScript").
@(export, link_name = "wj_console_inspect_result")
wj_console_inspect_result :: proc "c" (ctx: ^wj.Context, v: wj.JSValue) {
	b: SB
	inspect(ctx, &b, v, 0, false)
	wj.wj_console_text(LEVEL_INFO, b.p != nil ? b.p : empty_bytes(), b.n)
	wj.libc_free(b.p)
}

// Fallback before the bindings exist (or when they do not expose console): a console object with these members, each a
// native function defined on it (no JSCFunctionListEntry: same result).
@(export, link_name = "wj_install_console")
wj_install_console :: proc "c" (ctx: ^wj.Context, global: wj.JSValue) {
	c := wj.JS_NewObject(ctx)
	def :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, name: cstring, fn: wj.Native) {
		wj.JS_DefinePropertyValueStr(ctx, obj, name, wj.new_cfunction(ctx, fn, name, 0), wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
	}
	def(ctx, c, "log", wjr_console_log);     def(ctx, c, "info", wjr_console_info)
	def(ctx, c, "warn", wjr_console_warn);   def(ctx, c, "error", wjr_console_error)
	def(ctx, c, "debug", wjr_console_debug); def(ctx, c, "trace", wjr_console_trace)
	def(ctx, c, "assert", wjr_console_assert); def(ctx, c, "group", wjr_console_group)
	def(ctx, c, "groupCollapsed", wjr_console_groupCollapsed); def(ctx, c, "groupEnd", wjr_console_groupEnd)
	def(ctx, c, "count", wjr_console_count); def(ctx, c, "countReset", wjr_console_countReset)
	def(ctx, c, "time", wjr_console_time);   def(ctx, c, "timeLog", wjr_console_timeLog)
	def(ctx, c, "timeEnd", wjr_console_timeEnd); def(ctx, c, "dir", wjr_console_dir)
	def(ctx, c, "dirxml", wjr_console_dirxml); def(ctx, c, "table", wjr_console_table)
	def(ctx, c, "clear", wjr_console_clear)
	wj.JS_DefinePropertyValueStr(ctx, global, "console", c, wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
}
