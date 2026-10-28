// web_encoding.odin: TextEncoder and TextDecoder (Encoding Standard), atob and btoa (HTML "forgiving-base64"). Ported
// from native/js/runtime/web_encoding.c; wjr_* symbols and behaviour identical.
//
// TextEncoder lives in the engine (UTF-8 of a USVString is what the engine produces once lone surrogates are replaced).
// TextDecoder is the browser's decoder (module encoding: every WHATWG label, replacement or fatal mode, BOM handling,
// streaming): the input is read where it is, the result comes back in one copy.
package odin_glue

import "../odin/wj"

foreign import m_encoding "encoding"

@(default_calling_convention = "c")
foreign m_encoding {
	@(link_name = "TextDecoder_create") wr_TextDecoder_create :: proc(label: [^]u8, label_len: u32, options: u32, ret: ^u64) -> i32 ---
	@(link_name = "TextDecoder_flags")  wr_TextDecoder_flags  :: proc(decoder: u64) -> u32 ---
	@(link_name = "TextDecoder_decode") wr_TextDecoder_decode :: proc(decoder: u64, input: [^]u8, input_len: u32, stream: i32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "TextDecoder_output") wr_TextDecoder_output :: proc(decoder: u64, buf: [^]u8, cap: u32) -> i32 ---
}

TDO_FATAL      :: u32(1 << 0)   // wr_TextDecoderOptions_Fatal
TDO_IGNORE_BOM :: u32(1 << 1)   // wr_TextDecoderOptions_Ignore_BOM
ERR_RANGE_E    :: i32(-11)      // wr_Error_Range
ERR_TYPE_E     :: i32(-10)      // wr_Error_Type

@(private = "file") iface_text_encoder := i32(-2)
@(private = "file") iface_text_decoder := i32(-2)

@(private = "file")
text_encoder_iface :: proc "c" () -> i32 {
	if iface_text_encoder == -2 { iface_text_encoder = wj.iface("TextEncoder") }
	return iface_text_encoder
}
@(private = "file")
text_decoder_iface :: proc "c" () -> i32 {
	if iface_text_decoder == -2 { iface_text_decoder = wj.iface("TextDecoder") }
	return iface_text_decoder
}

// ---- TextEncoder ----

@(export, link_name = "wjr_TextEncoder_constructor")
wjr_TextEncoder_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor TextEncoder requires 'new'") }
	return wj.wj_new_object_for(ctx, text_encoder_iface(), new_target, nil, nil)
}

@(export, link_name = "wjr_TextEncoder_get_encoding")
wjr_TextEncoder_get_encoding :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, text_encoder_iface()) == nil { return wj.EXCEPTION }
	return wj.new_cstring(ctx, "utf-8")
}

@(export, link_name = "wjr_TextEncoder_encode")
wjr_TextEncoder_encode :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, text_encoder_iface()) == nil { return wj.EXCEPTION }
	in_val := wj.arg(argc, argv, 0)
	if wj.is_undefined(in_val) { return wj.new_uint8_array(ctx, nil) }
	s: wj.Str
	if !wj.web_to_usv(ctx, in_val, &s) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	return wj.new_uint8_array(ctx, wj.str_slice(s))
}

@(private = "file")
utf8_len :: #force_inline proc "contextless" (lead: u8) -> int {
	return lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4
}

@(export, link_name = "wjr_TextEncoder_encodeInto")
wjr_TextEncoder_encodeInto :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, text_encoder_iface()) == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "TextEncoder.encodeInto", 2, argc) }
	if wj.Typed_Array(wj.wj_typed_array_type(argv[1])) != .Uint8 { return wj.wj_throw_type(ctx, "TextEncoder.encodeInto: the destination is not a Uint8Array") }
	s: wj.Str
	if !wj.web_to_usv(ctx, argv[0], &s) { return wj.EXCEPTION }
	dst: [^]u8
	cap: uint
	if !wj.wj_to_buffer_source(ctx, argv[1], &dst, &cap, wj.BS_VIEW_ONLY | wj.BS_ALLOW_SHARED, "TextEncoder.encodeInto") { wj.wj_str_free(ctx, &s); return wj.EXCEPTION }
	// whole characters only; `read` counts UTF-16 code units (a 4-byte sequence is a surrogate pair)
	src := wj.str_slice(s)
	i, read := 0, 0
	for i < len(src) {
		n := utf8_len(src[i])
		if i + n > len(src) || uint(i + n) > cap { break }
		i += n
		read += n == 4 ? 2 : 1
	}
	if i > 0 { copy(dst[:i], src[:i]) }
	wj.wj_str_free(ctx, &s)
	r := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, r, "read", wj.new_float64(ctx, f64(read)))
	wj.JS_SetPropertyStr(ctx, r, "written", wj.new_float64(ctx, f64(i)))
	return r
}

// ---- TextDecoder ----

@(export, link_name = "wjr_TextDecoder_constructor")
wjr_TextDecoder_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor TextDecoder requires 'new'") }
	label: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 0), &label, 0, "utf-8") { return wj.EXCEPTION }
	opt := wj.arg(argc, argv, 1)
	flags := u32(0)
	if !wj.web_dict_check(ctx, opt, "TextDecoder") { wj.wj_str_free(ctx, &label); return wj.EXCEPTION }
	fatal, bom: wj.JSValue
	if !wj.web_dict_get(ctx, opt, "fatal", &fatal) { wj.wj_str_free(ctx, &label); return wj.EXCEPTION }
	if wj.to_bool(ctx, fatal) { flags |= TDO_FATAL }
	wj.JS_FreeValue(ctx, fatal)
	if !wj.web_dict_get(ctx, opt, "ignoreBOM", &bom) { wj.wj_str_free(ctx, &label); return wj.EXCEPTION }
	if wj.to_bool(ctx, bom) { flags |= TDO_IGNORE_BOM }
	wj.JS_FreeValue(ctx, bom)
	// the browser takes "" for utf-8; an empty label is not one (RangeError)
	if label.len == 0 { wj.wj_str_free(ctx, &label); return wj.JS_ThrowRangeError(ctx, "The encoding label provided ('') is invalid.") }
	h := u64(0)
	st := wr_TextDecoder_create(label.ptr, u32(label.len), flags, &h)
	if st < 0 {
		e: wj.JSValue
		if st == ERR_RANGE_E {
			e = wj.JS_ThrowRangeError(ctx, "The encoding label provided ('%.*s') is invalid.", i32(min(label.len, 64)), label.ptr)
		} else {
			e = wj.wj_throw_status(ctx, st, "TextDecoder")
		}
		wj.wj_str_free(ctx, &label)
		return e
	}
	wj.wj_str_free(ctx, &label)
	return wj.wj_wrap_owned(ctx, h, text_decoder_iface(), new_target)
}

// `this` as a TextDecoder with a live browser handle, else TypeError.
@(private = "file")
decoder_handle :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> (u64, bool) {
	o := wj.wj_this(ctx, this_val, text_decoder_iface())
	if o == nil { return 0, false }
	h := wj.handle_of(o)
	if h == 0 { wj.wj_throw_type(ctx, "Illegal invocation"); return 0, false }
	return h, true
}

@(export, link_name = "wjr_TextDecoder_get_fatal")
wjr_TextDecoder_get_fatal :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	h, ok := decoder_handle(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	return wj.new_bool((wr_TextDecoder_flags(h) & TDO_FATAL) != 0)
}

@(export, link_name = "wjr_TextDecoder_get_ignoreBOM")
wjr_TextDecoder_get_ignoreBOM :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	h, ok := decoder_handle(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	return wj.new_bool((wr_TextDecoder_flags(h) & TDO_IGNORE_BOM) != 0)
}

@(export, link_name = "wjr_TextDecoder_decode")
wjr_TextDecoder_decode :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h, ok := decoder_handle(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	in_val := wj.arg(argc, argv, 0)
	opt := wj.arg(argc, argv, 1)
	if !wj.web_dict_check(ctx, opt, "TextDecoder.decode") { return wj.EXCEPTION }
	sv: wj.JSValue
	if !wj.web_dict_get(ctx, opt, "stream", &sv) { return wj.EXCEPTION }
	stream := wj.to_bool(ctx, sv)
	wj.JS_FreeValue(ctx, sv)
	p: [^]u8
	n: uint
	if !wj.is_undefined(in_val) && !wj.wj_to_buffer_source(ctx, in_val, &p, &n, wj.BS_ALLOW_SHARED, "TextDecoder.decode") { return wj.EXCEPTION }
	if n > 0xFFFF_FFFF { return wj.JS_ThrowRangeError(ctx, "TextDecoder.decode: the input is too large") }
	// decoding changes the decoder's state: when the result does not fit, it is read again (TextDecoder_output)
	if wj.wj_scratch.data == nil && !wj.wj_scratch_grow(256) { return wj.JS_ThrowOutOfMemory(ctx) }
	r := wr_TextDecoder_decode(h, p, u32(n), stream ? 1 : 0, wj.wj_scratch.data, wj.wj_scratch.cap)
	if r < 0 {
		if r == ERR_TYPE_E { return wj.wj_throw_type(ctx, "The encoded data was not valid.") }
		return wj.wj_throw_status(ctx, r, "TextDecoder.decode")
	}
	if u32(r) > wj.wj_scratch.cap {
		if !wj.wj_scratch_grow(u32(r)) { return wj.JS_ThrowOutOfMemory(ctx) }
		r = wr_TextDecoder_output(h, wj.wj_scratch.data, wj.wj_scratch.cap)
		if r < 0 { r = 0 }
	}
	return wj.new_string_len(ctx, wj.scratch_bytes(r))
}

// ---- atob / btoa ----

@(private = "file") B64 := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

// the bytes of a "binary string" (each code unit one byte): false when one is past U+00FF
@(private = "file")
binary_bytes :: proc "contextless" (s: []u8, out: [^]u8) -> (n: int, ok: bool) {
	w := 0
	i := 0
	for i < len(s) {
		c := s[i]
		if c < 0x80 { out[w] = c; w += 1; i += 1; continue }
		if (c == 0xC2 || c == 0xC3) && i + 1 < len(s) {
			out[w] = u8(((c & 0x1F) << 6) | (s[i + 1] & 0x3F)); w += 1; i += 2; continue
		}
		return 0, false
	}
	return w, true
}

@(export, link_name = "wjr_WindowOrWorkerGlobalScope_btoa")
wjr_WindowOrWorkerGlobalScope_btoa :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "btoa", 1, argc) }
	s: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &s, 0, nil) { return wj.EXCEPTION }
	src := wj.str_slice(s)
	bytes := ([^]u8)(wj.malloc(s.len + 1))
	if bytes == nil { wj.wj_str_free(ctx, &s); return wj.JS_ThrowOutOfMemory(ctx) }
	n, ok := binary_bytes(src, bytes)
	if !ok {
		wj.free(bytes); wj.wj_str_free(ctx, &s)
		return wj.wj_throw_dom(ctx, "InvalidCharacterError", "Failed to execute 'btoa': The string to be encoded contains characters outside of the Latin1 range.")
	}
	wj.wj_str_free(ctx, &s)
	out_n := (n + 2) / 3 * 4
	out := ([^]u8)(wj.malloc(uint(out_n) + 1))
	if out == nil { wj.free(bytes); return wj.JS_ThrowOutOfMemory(ctx) }
	w, i := 0, 0
	for ; i + 2 < n; i += 3 {
		v := u32(bytes[i]) << 16 | u32(bytes[i + 1]) << 8 | u32(bytes[i + 2])
		out[w] = B64[v >> 18];        w += 1
		out[w] = B64[(v >> 12) & 63]; w += 1
		out[w] = B64[(v >> 6) & 63];  w += 1
		out[w] = B64[v & 63];         w += 1
	}
	if n - i == 1 {
		v := u32(bytes[i]) << 16
		out[w] = B64[v >> 18];        w += 1
		out[w] = B64[(v >> 12) & 63]; w += 1
		out[w] = '=';                 w += 1
		out[w] = '=';                 w += 1
	} else if n - i == 2 {
		v := u32(bytes[i]) << 16 | u32(bytes[i + 1]) << 8
		out[w] = B64[v >> 18];        w += 1
		out[w] = B64[(v >> 12) & 63]; w += 1
		out[w] = B64[(v >> 6) & 63];  w += 1
		out[w] = '=';                 w += 1
	}
	wj.free(bytes)
	r := wj.new_string_len(ctx, out[:w])
	wj.free(out)
	return r
}

@(private = "file")
b64_value :: proc "contextless" (c: u8) -> int {
	switch {
	case c >= 'A' && c <= 'Z': return int(c - 'A')
	case c >= 'a' && c <= 'z': return int(c - 'a') + 26
	case c >= '0' && c <= '9': return int(c - '0') + 52
	case c == '+': return 62
	case c == '/': return 63
	}
	return -1
}

@(export, link_name = "wjr_WindowOrWorkerGlobalScope_atob")
wjr_WindowOrWorkerGlobalScope_atob :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "atob", 1, argc) }
	s: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &s, 0, nil) { return wj.EXCEPTION }
	src := wj.str_slice(s)
	// forgiving-base64 decode: ASCII whitespace removed, padding checked, then 6 bits per character
	clean := ([^]u8)(wj.malloc(s.len + 1))
	if clean == nil { wj.wj_str_free(ctx, &s); return wj.JS_ThrowOutOfMemory(ctx) }
	n := 0
	for c in src {
		if c == ' ' || c == '\t' || c == '\n' || c == '\f' || c == '\r' { continue }
		clean[n] = c; n += 1
	}
	wj.wj_str_free(ctx, &s)
	bad := false
	if n % 4 == 0 && n >= 1 && clean[n - 1] == '=' { n -= 1; if n >= 1 && clean[n - 1] == '=' { n -= 1 } }
	if n % 4 == 1 { bad = true }
	for i := 0; i < n && !bad; i += 1 { if b64_value(clean[i]) < 0 { bad = true } }
	if bad {
		wj.free(clean)
		return wj.wj_throw_dom(ctx, "InvalidCharacterError", "Failed to execute 'atob': The string to be decoded is not correctly encoded.")
	}
	// the result is a binary string: bytes past 0x7F are 2 bytes of UTF-8
	out := ([^]u8)(wj.malloc(uint(n / 4 * 3 * 2 + 8)))
	if out == nil { wj.free(clean); return wj.JS_ThrowOutOfMemory(ctx) }
	w := 0
	acc := u32(0)
	bits := 0
	for i in 0 ..< n {
		acc = (acc << 6) | u32(b64_value(clean[i]))
		bits += 6
		if bits >= 8 {
			bits -= 8
			b := u8(acc >> uint(bits))
			if b < 0x80 { out[w] = b; w += 1 } else { out[w] = 0xC0 | (b >> 6); w += 1; out[w] = 0x80 | (b & 0x3F); w += 1 }
		}
	}
	wj.free(clean)
	r := wj.new_string_len(ctx, out[:w])
	wj.free(out)
	return r
}
