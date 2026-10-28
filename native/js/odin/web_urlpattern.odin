// web_urlpattern.odin: URLPattern (URL Pattern Standard) on the browser's pattern object (module url). Ported from
// native/js/runtime/web_urlpattern.c; wjr_* symbols and behaviour identical.
//
// The pattern parsing and matching are pure and native (src/url/pattern*.odin); this file is the thin glue that reads a
// URLPatternInput (a USVString or a URLPatternInit dictionary) and assembles the structured URLPatternResult. No logic
// lives here — it is Web IDL shape only.
package odin_glue

import "../odin/wj"

foreign import m_urlpattern "url"

@(default_calling_convention = "c")
foreign m_urlpattern {
	@(link_name = "URLPattern_createString") wr_URLPattern_createString :: proc(input: [^]u8, input_len: u32, base: [^]u8, base_len: u32, has_base: i32, ignore_case: i32, ret: ^u64) -> i32 ---
	@(link_name = "URLPattern_createInit")   wr_URLPattern_createInit   :: proc(
		protocol: [^]u8, protocol_len: u32, has_protocol: i32,
		username: [^]u8, username_len: u32, has_username: i32,
		password: [^]u8, password_len: u32, has_password: i32,
		hostname: [^]u8, hostname_len: u32, has_hostname: i32,
		port: [^]u8, port_len: u32, has_port: i32,
		pathname: [^]u8, pathname_len: u32, has_pathname: i32,
		search: [^]u8, search_len: u32, has_search: i32,
		hash: [^]u8, hash_len: u32, has_hash: i32,
		base: [^]u8, base_len: u32, has_base: i32,
		ignore_case: i32, ret: ^u64) -> i32 ---
	@(link_name = "URLPattern_component")      wr_URLPattern_component      :: proc(pattern: u64, component: i32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "URLPattern_execString")     wr_URLPattern_execString     :: proc(pattern: u64, input: [^]u8, input_len: u32, base: [^]u8, base_len: u32, has_base: i32) -> i32 ---
	@(link_name = "URLPattern_execInit")       wr_URLPattern_execInit       :: proc(
		pattern: u64,
		protocol: [^]u8, protocol_len: u32, has_protocol: i32,
		username: [^]u8, username_len: u32, has_username: i32,
		password: [^]u8, password_len: u32, has_password: i32,
		hostname: [^]u8, hostname_len: u32, has_hostname: i32,
		port: [^]u8, port_len: u32, has_port: i32,
		pathname: [^]u8, pathname_len: u32, has_pathname: i32,
		search: [^]u8, search_len: u32, has_search: i32,
		hash: [^]u8, hash_len: u32, has_hash: i32) -> i32 ---
	@(link_name = "URLPattern_componentInput") wr_URLPattern_componentInput :: proc(pattern: u64, component: i32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "URLPattern_groupCount")     wr_URLPattern_groupCount     :: proc(pattern: u64, component: i32) -> i32 ---
	@(link_name = "URLPattern_groupName")      wr_URLPattern_groupName      :: proc(pattern: u64, component: i32, index: i32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "URLPattern_groupValue")     wr_URLPattern_groupValue     :: proc(pattern: u64, component: i32, index: i32, buf: [^]u8, cap: u32) -> i32 ---
}

// the eight components in the host enum's order (wr_URLPatternComponent_*) and their result-key names
@(private = "file") PATTERN_KEYS := [8]cstring{ "protocol", "username", "password", "hostname", "port", "pathname", "search", "hash" }
@(private = "file") INIT_NAMES   := [9]cstring{ "protocol", "username", "password", "hostname", "port", "pathname", "search", "hash", "baseURL" }

@(private = "file") iface_pattern := i32(-2)
@(private = "file")
pattern_iface :: proc "c" () -> i32 {
	if iface_pattern == -2 { iface_pattern = wj.iface("URLPattern") }
	return iface_pattern
}

// The nine optional fields of a URLPatternInit, owned until pattern_init_free.
@(private = "file") Pattern_Init :: struct {
	v:   [9]wj.Str,
	has: [9]bool,
}

// Reads a USVString property `name` of the init dictionary into out.v[i] (owned); sets has[i]. False with an exception.
@(private = "file")
pattern_init_field :: proc "c" (ctx: ^wj.Context, init: wj.JSValue, name: cstring, out: ^wj.Str, has: ^bool) -> bool {
	out^ = {}
	has^ = false
	v: wj.JSValue
	if !wj.web_dict_get(ctx, init, name, &v) { return false }
	if wj.is_undefined(v) { wj.JS_FreeValue(ctx, v); return true }
	ok := wj.web_to_usv(ctx, v, out)
	wj.JS_FreeValue(ctx, v)
	if ok { has^ = true }
	return ok
}

@(private = "file")
pattern_read_init :: proc "c" (ctx: ^wj.Context, init: wj.JSValue, out: ^Pattern_Init) -> bool {
	for i in 0 ..< 9 {
		if !pattern_init_field(ctx, init, INIT_NAMES[i], &out.v[i], &out.has[i]) {
			for j in 0 ..< i { wj_str_free(ctx, &out.v[j]) }
			return false
		}
	}
	return true
}

@(private = "file")
pattern_init_free :: proc "c" (ctx: ^wj.Context, p: ^Pattern_Init) {
	for i in 0 ..< 9 { wj_str_free(ctx, &p.v[i]) }
}

// The INIT_ARG macro of the C: a field's (ptr, len, has) triple (empty, not nil, when unset).
@(private = "file")
arg_ptr :: #force_inline proc "contextless" (p: ^Pattern_Init, i: int) -> [^]u8 {
	return p.v[i].ptr != nil ? p.v[i].ptr : wj.empty_ptr()
}
@(private = "file") arg_len :: #force_inline proc "contextless" (p: ^Pattern_Init, i: int) -> u32 { return u32(p.v[i].len) }
@(private = "file") arg_has :: #force_inline proc "contextless" (p: ^Pattern_Init, i: int) -> i32 { return p.has[i] ? 1 : 0 }

@(export, link_name = "wjr_URLPattern_constructor")
wjr_URLPattern_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor URLPattern requires 'new'") }
	input := wj.arg(argc, argv, 0)
	a1 := wj.arg(argc, argv, 1)
	a2 := wj.arg(argc, argv, 2)

	input_is_string := wj.is_string(input) || (!wj.is_object(input) && !wj.is_undefined(input))
	// options is a1 when input is an init object, else a2 (a1 is then the baseURL string)
	options := input_is_string ? a2 : a1
	ignore_case := false
	if wj.is_object(options) {
		ic: wj.JSValue
		if !wj.web_dict_get(ctx, options, "ignoreCase", &ic) { return wj.EXCEPTION }
		ignore_case = wj.to_bool(ctx, ic)
		wj.JS_FreeValue(ctx, ic)
	}

	h := u64(0)
	st: i32
	if input_is_string {
		in_s, base: wj.Str
		if !wj.web_to_usv(ctx, input, &in_s) { return wj.EXCEPTION }
		has_base := wj.is_string(a1)
		base = {}
		if has_base && !wj.web_to_usv(ctx, a1, &base) { wj_str_free(ctx, &in_s); return wj.EXCEPTION }
		base_ptr := base.ptr != nil ? base.ptr : wj.empty_ptr()
		st = wr_URLPattern_createString(in_s.ptr, u32(in_s.len), base_ptr, has_base ? u32(base.len) : 0, has_base ? 1 : 0, ignore_case ? 1 : 0, &h)
		wj_str_free(ctx, &in_s)
		wj_str_free(ctx, &base)
	} else {
		p: Pattern_Init
		is_obj := wj.is_object(input)
		if is_obj {
			if !pattern_read_init(ctx, input, &p) { return wj.EXCEPTION }
		}
		st = wr_URLPattern_createInit(
			arg_ptr(&p, 0), arg_len(&p, 0), arg_has(&p, 0),
			arg_ptr(&p, 1), arg_len(&p, 1), arg_has(&p, 1),
			arg_ptr(&p, 2), arg_len(&p, 2), arg_has(&p, 2),
			arg_ptr(&p, 3), arg_len(&p, 3), arg_has(&p, 3),
			arg_ptr(&p, 4), arg_len(&p, 4), arg_has(&p, 4),
			arg_ptr(&p, 5), arg_len(&p, 5), arg_has(&p, 5),
			arg_ptr(&p, 6), arg_len(&p, 6), arg_has(&p, 6),
			arg_ptr(&p, 7), arg_len(&p, 7), arg_has(&p, 7),
			arg_ptr(&p, 8), arg_len(&p, 8), arg_has(&p, 8),
			ignore_case ? 1 : 0, &h)
		if is_obj { pattern_init_free(ctx, &p) }
	}
	if st < 0 { return wj.wj_throw_status(ctx, st, "URLPattern") }
	return wj.wj_wrap_owned(ctx, h, pattern_iface(), new_target)
}

// `this` as a URLPattern with a live handle, else TypeError.
@(private = "file")
pattern_handle :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> (u64, bool) {
	o := wj.wj_this(ctx, this_val, pattern_iface())
	if o == nil { return 0, false }
	h := wj.handle_of(o)
	if h == 0 { wj.wj_throw_type(ctx, "Illegal invocation"); return 0, false }
	return h, true
}

@(private = "file") Comp_P_Op :: struct { handle: u64, component: i32 }
@(private = "file")
fill_component :: proc "contextless" (user: rawptr, buf: [^]u8, cap: u32) -> i32 {
	op := (^Comp_P_Op)(user); return wr_URLPattern_component(op.handle, op.component, buf, cap)
}

@(private = "file")
pattern_component :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, component: i32) -> wj.JSValue {
	h, ok := pattern_handle(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	op := Comp_P_Op{ h, component }
	n := wj.fetch_string(fill_component, &op)
	if n < 0 { return wj.wj_throw_status(ctx, n, "URLPattern") }
	return wj.new_string_len(ctx, wj.scratch_bytes(n))
}

@(export, link_name = "wjr_URLPattern_get_protocol") wjr_URLPattern_get_protocol :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return pattern_component(ctx, t, 0) }
@(export, link_name = "wjr_URLPattern_get_username") wjr_URLPattern_get_username :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return pattern_component(ctx, t, 1) }
@(export, link_name = "wjr_URLPattern_get_password") wjr_URLPattern_get_password :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return pattern_component(ctx, t, 2) }
@(export, link_name = "wjr_URLPattern_get_hostname") wjr_URLPattern_get_hostname :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return pattern_component(ctx, t, 3) }
@(export, link_name = "wjr_URLPattern_get_port")     wjr_URLPattern_get_port     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return pattern_component(ctx, t, 4) }
@(export, link_name = "wjr_URLPattern_get_pathname") wjr_URLPattern_get_pathname :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return pattern_component(ctx, t, 5) }
@(export, link_name = "wjr_URLPattern_get_search")   wjr_URLPattern_get_search   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return pattern_component(ctx, t, 6) }
@(export, link_name = "wjr_URLPattern_get_hash")     wjr_URLPattern_get_hash     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return pattern_component(ctx, t, 7) }

// Runs a match (exec/test). 1 matched, 0 no match, -1 with an exception pending.
@(private = "file")
pattern_run :: proc "c" (ctx: ^wj.Context, h: u64, argc: i32, argv: [^]wj.JSValue) -> i32 {
	input := wj.arg(argc, argv, 0)
	a1 := wj.arg(argc, argv, 1)
	input_is_string := wj.is_string(input) || (!wj.is_object(input) && !wj.is_undefined(input))
	if input_is_string || wj.is_undefined(input) {
		in_s, base: wj.Str
		in_s = {}
		if !wj.is_undefined(input) && !wj.web_to_usv(ctx, input, &in_s) { return -1 }
		has_base := wj.is_string(a1)
		base = {}
		if has_base && !wj.web_to_usv(ctx, a1, &base) { wj_str_free(ctx, &in_s); return -1 }
		in_ptr := in_s.ptr != nil ? in_s.ptr : wj.empty_ptr()
		base_ptr := base.ptr != nil ? base.ptr : wj.empty_ptr()
		r := wr_URLPattern_execString(h, in_ptr, u32(in_s.len), base_ptr, has_base ? u32(base.len) : 0, has_base ? 1 : 0)
		wj_str_free(ctx, &in_s)
		wj_str_free(ctx, &base)
		return r > 0 ? 1 : 0
	}
	p: Pattern_Init
	if !pattern_read_init(ctx, input, &p) { return -1 }
	r := wr_URLPattern_execInit(h,
		arg_ptr(&p, 0), arg_len(&p, 0), arg_has(&p, 0),
		arg_ptr(&p, 1), arg_len(&p, 1), arg_has(&p, 1),
		arg_ptr(&p, 2), arg_len(&p, 2), arg_has(&p, 2),
		arg_ptr(&p, 3), arg_len(&p, 3), arg_has(&p, 3),
		arg_ptr(&p, 4), arg_len(&p, 4), arg_has(&p, 4),
		arg_ptr(&p, 5), arg_len(&p, 5), arg_has(&p, 5),
		arg_ptr(&p, 6), arg_len(&p, 6), arg_has(&p, 6),
		arg_ptr(&p, 7), arg_len(&p, 7), arg_has(&p, 7))
	pattern_init_free(ctx, &p)
	return r > 0 ? 1 : 0
}

@(export, link_name = "wjr_URLPattern_test")
wjr_URLPattern_test :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h, ok := pattern_handle(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	r := pattern_run(ctx, h, argc, argv)
	if r < 0 { return wj.EXCEPTION }
	return wj.new_bool(r == 1)
}

@(private = "file") Grp_Op :: struct { handle: u64, component: i32, index: i32, which: i32 }
@(private = "file")
fill_component_input :: proc "contextless" (user: rawptr, buf: [^]u8, cap: u32) -> i32 {
	op := (^Grp_Op)(user); return wr_URLPattern_componentInput(op.handle, op.component, buf, cap)
}
@(private = "file")
fill_group_name :: proc "contextless" (user: rawptr, buf: [^]u8, cap: u32) -> i32 {
	op := (^Grp_Op)(user); return wr_URLPattern_groupName(op.handle, op.component, op.index, buf, cap)
}
@(private = "file")
fill_group_value :: proc "contextless" (user: rawptr, buf: [^]u8, cap: u32) -> i32 {
	op := (^Grp_Op)(user); return wr_URLPattern_groupValue(op.handle, op.component, op.index, buf, cap)
}

// Builds a URLPatternComponentResult { input, groups } for component `c` from the stored match.
@(private = "file")
pattern_component_result :: proc "c" (ctx: ^wj.Context, h: u64, c: i32) -> wj.JSValue {
	result := wj.JS_NewObject(ctx)
	op := Grp_Op{ h, c, 0, 0 }
	n := wj.fetch_string(fill_component_input, &op)
	wj.JS_DefinePropertyValueStr(ctx, result, "input", wj.new_string_len(ctx, wj.scratch_bytes(n)), wj.PROP_C_W_E)
	groups := wj.JS_NewObject(ctx)
	count := wr_URLPattern_groupCount(h, c)
	for i in 0 ..< count {
		op.index = i
		nn := wj.fetch_string(fill_group_name, &op)
		if nn < 0 { continue }
		name := wj.temp_cstr(wj.scratch_bytes(nn))
		vn := wj.fetch_string(fill_group_value, &op)
		value := vn == ERR_NOT_FOUND_P ? wj.UNDEFINED : wj.new_string_len(ctx, wj.scratch_bytes(vn))
		if name != nil {
			wj.JS_DefinePropertyValueStr(ctx, groups, name, value, wj.PROP_C_W_E)
			wj.temp_cstr_free(name)
		} else {
			wj.JS_FreeValue(ctx, value)
		}
	}
	wj.JS_DefinePropertyValueStr(ctx, result, "groups", groups, wj.PROP_C_W_E)
	return result
}

ERR_NOT_FOUND_P :: i32(-3)   // wr_Error_Not_Found

@(export, link_name = "wjr_URLPattern_exec")
wjr_URLPattern_exec :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h, ok := pattern_handle(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	r := pattern_run(ctx, h, argc, argv)
	if r < 0 { return wj.EXCEPTION }
	if r == 0 { return wj.NULL }

	result := wj.JS_NewObject(ctx)
	// inputs: the input(s) echoed back. A string or a URLPatternInit as the first input, plus the baseURL string when
	// one was given as the second argument.
	inputs := wj.JS_NewArray(ctx)
	input := wj.arg(argc, argv, 0)
	a1 := wj.arg(argc, argv, 1)
	ii := u32(0)
	wj.array_set(ctx, inputs, ii, wj.is_undefined(input) ? wj.JS_NewObject(ctx) : wj.JS_DupValue(ctx, input))
	ii += 1
	if wj.is_string(a1) { wj.array_set(ctx, inputs, ii, wj.JS_DupValue(ctx, a1)); ii += 1 }
	wj.JS_DefinePropertyValueStr(ctx, result, "inputs", inputs, wj.PROP_C_W_E)
	for c in 0 ..< i32(8) {
		wj.JS_DefinePropertyValueStr(ctx, result, PATTERN_KEYS[c], pattern_component_result(ctx, h, c), wj.PROP_C_W_E)
	}
	return result
}
