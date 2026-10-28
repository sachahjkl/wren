// web_crypto.odin: crypto (Web Cryptography API): getRandomValues, randomUUID and subtle.digest on the browser's
// BCrypt-backed functions (module crypto). Ported from native/js/runtime/web_crypto.c; wjr_* symbols and behaviour
// identical. Random bytes are written straight into the view's memory. Other SubtleCrypto operations reject with
// NotSupportedError. In a document that is not a secure context, crypto.subtle and crypto.randomUUID are absent.
package odin_glue

import "../odin/wj"

foreign import m_crypto "crypto"
foreign import m_crypto_document "document"

@(default_calling_convention = "c")
foreign m_crypto {
	@(link_name = "Crypto_getRandomValues") wr_Crypto_getRandomValues :: proc(destination: [^]u8, destination_cap: u32) -> i32 ---
	@(link_name = "SubtleCrypto_digest")    wr_SubtleCrypto_digest    :: proc(algorithm: [^]u8, algorithm_len: u32, data: [^]u8, data_len: u32) -> u64 ---
}

@(default_calling_convention = "c")
foreign m_crypto_document {
	@(link_name = "Window_isSecureContext") wr_Window_isSecureContext :: proc() -> i32 ---
}

ERR_QUOTA_C :: i32(-13)   // wr_Error_Quota (file-local alias)

@(private = "file") iface_crypto := i32(-2)
@(private = "file") iface_subtle := i32(-2)

@(private = "file")
crypto_iface :: proc "c" () -> i32 {
	if iface_crypto == -2 { iface_crypto = wj.iface("Crypto") }
	return iface_crypto
}
@(private = "file")
subtle_iface :: proc "c" () -> i32 {
	if iface_subtle == -2 { iface_subtle = wj.iface("SubtleCrypto") }
	return iface_subtle
}

@(private = "file") make_crypto :: proc "c" (ctx: ^wj.Context) -> wj.JSValue { return wj.wj_new_object(ctx, crypto_iface(), nil, nil) }
@(private = "file") make_subtle :: proc "c" (ctx: ^wj.Context) -> wj.JSValue { return wj.wj_new_object(ctx, subtle_iface(), nil, nil) }

@(export, link_name = "wjr_WindowOrWorkerGlobalScope_get_crypto")
wjr_WindowOrWorkerGlobalScope_get_crypto :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj.web_singleton(ctx, wj.SINGLE_CRYPTO, make_crypto)
}

@(export, link_name = "wjr_Crypto_get_subtle")
wjr_Crypto_get_subtle :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, crypto_iface()) == nil { return wj.EXCEPTION }
	return wj.web_singleton(ctx, wj.SINGLE_SUBTLE, make_subtle)
}

WEB_RANDOM_MAX :: 65536   // the Web Cryptography API's limit, before the browser's own (crypto.max_random_bytes)

@(export, link_name = "wjr_Crypto_getRandomValues")
wjr_Crypto_getRandomValues :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, crypto_iface()) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Crypto.getRandomValues", 1, argc) }
	t := wj.Typed_Array(wj.wj_typed_array_type(argv[0]))
	integer: bool
	#partial switch t {
	case .Int8, .Uint8, .Uint8C, .Int16, .Uint16, .Int32, .Uint32, .Big_Int64, .Big_Uint64:
		integer = true
	}
	if !integer {
		// a view that is not of integers (floats, DataView): TypeMismatchError; anything else is not an ArrayBufferView
		if wj.wj_is_array_buffer_view(argv[0]) {
			return wj.wj_throw_dom(ctx, "TypeMismatchError", "Failed to execute 'getRandomValues' on 'Crypto': The provided ArrayBufferView is not an integer array type.")
		}
		return wj.wj_throw_type(ctx, "Failed to execute 'getRandomValues' on 'Crypto': parameter 1 is not of type 'ArrayBufferView'.")
	}
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, argv[0], &p, &n, wj.BS_VIEW_ONLY | wj.BS_ALLOW_SHARED, "Crypto.getRandomValues") { return wj.EXCEPTION }
	if n > WEB_RANDOM_MAX { return wj.wj_throw_dom(ctx, "QuotaExceededError", "Failed to execute 'getRandomValues' on 'Crypto': The ArrayBufferView's byte length exceeds the number of bytes of entropy available via this API (65536).") }
	if n > 0 {
		st := wr_Crypto_getRandomValues(p, u32(n))
		if st < 0 {
			if st == ERR_QUOTA_C { return wj.wj_throw_dom(ctx, "QuotaExceededError", "Failed to execute 'getRandomValues' on 'Crypto': over crypto.max_random_bytes.") }
			return wj.wj_throw_status(ctx, st, "Crypto.getRandomValues")
		}
	}
	return wj.JS_DupValue(ctx, argv[0])
}

// AlgorithmIdentifier: a string, or an object with a name.
@(private = "file")
algorithm_name :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, out: ^wj.Str) -> bool {
	if wj.is_object(v) {
		n := wj.JS_GetPropertyStr(ctx, v, "name")
		if wj.is_exception(n) { return false }
		if wj.is_undefined(n) { wj.wj_throw_type(ctx, "Algorithm: name is missing"); return false }
		ok := wj.wj_to_str(ctx, n, out, 0, nil)
		wj.JS_FreeValue(ctx, n)
		return ok
	}
	return wj.wj_to_str(ctx, v, out, 0, nil)
}

@(private = "file") digest_names := [4]cstring{ "SHA-1", "SHA-256", "SHA-384", "SHA-512" }

@(export, link_name = "wjr_SubtleCrypto_digest")
wjr_SubtleCrypto_digest :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, subtle_iface()) == nil { return wj.web_promise_reject_pending(ctx) }
	if argc < 2 { wj.wj_throw_arity(ctx, "SubtleCrypto.digest", 2, argc); return wj.web_promise_reject_pending(ctx) }
	alg: wj.Str
	if !algorithm_name(ctx, argv[0], &alg) { return wj.web_promise_reject_pending(ctx) }
	canon: cstring = nil
	for name in digest_names {
		if wj.web_ascii_ieq(alg.ptr, alg.len, name) { canon = name }
	}
	wj.wj_str_free(ctx, &alg)
	if canon == nil { return wj.web_promise_rejected(ctx, wj.web_dom_exception(ctx, "NotSupportedError", "Failed to execute 'digest' on 'SubtleCrypto': Algorithm: Unrecognized name")) }
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, argv[1], &p, &n, 0, "SubtleCrypto.digest") { return wj.web_promise_reject_pending(ctx) }
	if n > 0xFFFF_FFFF { return wj.web_promise_rejected(ctx, wj.web_dom_exception(ctx, "QuotaExceededError", "the data is too large")) }
	// the browser copies the bytes before this returns: later changes of the buffer do not matter
	h := wr_SubtleCrypto_digest(([^]u8)(rawptr(canon)), u32(len(canon)), p, u32(n))
	return wj.wj_promise_from_host(ctx, h, wj.HOST_ARRAYBUFFER, nil, wj.UNDEFINED)
}

// The message the C built with snprintf ("SubtleCrypto.<op> is not supported by this browser") is passed whole per op,
// which avoids a formatter in the glue while keeping the observable string identical.
@(private = "file")
subtle_unsupported :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, msg: cstring) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, subtle_iface()) == nil { return wj.web_promise_reject_pending(ctx) }
	return wj.web_promise_rejected(ctx, wj.web_dom_exception(ctx, "NotSupportedError", msg))
}

// The eleven unimplemented SubtleCrypto operations. The C hid these behind a macro so the binding generator would not
// see them; the exports here have the same names the table resolves to.
@(export, link_name = "wjr_SubtleCrypto_encrypt")
wjr_SubtleCrypto_encrypt :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_unsupported(ctx, t, "SubtleCrypto.encrypt is not supported by this browser") }
@(export, link_name = "wjr_SubtleCrypto_decrypt")
wjr_SubtleCrypto_decrypt :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_unsupported(ctx, t, "SubtleCrypto.decrypt is not supported by this browser") }
@(export, link_name = "wjr_SubtleCrypto_sign")
wjr_SubtleCrypto_sign :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_unsupported(ctx, t, "SubtleCrypto.sign is not supported by this browser") }
@(export, link_name = "wjr_SubtleCrypto_verify")
wjr_SubtleCrypto_verify :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_unsupported(ctx, t, "SubtleCrypto.verify is not supported by this browser") }
@(export, link_name = "wjr_SubtleCrypto_generateKey")
wjr_SubtleCrypto_generateKey :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_unsupported(ctx, t, "SubtleCrypto.generateKey is not supported by this browser") }
@(export, link_name = "wjr_SubtleCrypto_deriveKey")
wjr_SubtleCrypto_deriveKey :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_unsupported(ctx, t, "SubtleCrypto.deriveKey is not supported by this browser") }
@(export, link_name = "wjr_SubtleCrypto_deriveBits")
wjr_SubtleCrypto_deriveBits :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_unsupported(ctx, t, "SubtleCrypto.deriveBits is not supported by this browser") }
@(export, link_name = "wjr_SubtleCrypto_importKey")
wjr_SubtleCrypto_importKey :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_unsupported(ctx, t, "SubtleCrypto.importKey is not supported by this browser") }
@(export, link_name = "wjr_SubtleCrypto_exportKey")
wjr_SubtleCrypto_exportKey :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_unsupported(ctx, t, "SubtleCrypto.exportKey is not supported by this browser") }
@(export, link_name = "wjr_SubtleCrypto_wrapKey")
wjr_SubtleCrypto_wrapKey :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_unsupported(ctx, t, "SubtleCrypto.wrapKey is not supported by this browser") }
@(export, link_name = "wjr_SubtleCrypto_unwrapKey")
wjr_SubtleCrypto_unwrapKey :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_unsupported(ctx, t, "SubtleCrypto.unwrapKey is not supported by this browser") }

// [SecureContext] members are absent from documents that are not secure contexts.
@(export, link_name = "web_crypto_start")
web_crypto_start :: proc "c" (ctx: ^wj.Context, kind: i32) -> i32 {
	if wr_Window_isSecureContext() != 0 { return 0 }
	proto := wj.proto_of(crypto_iface())
	if !wj.is_object(proto) { return 0 }
	names := [2]cstring{ "subtle", "randomUUID" }
	for name in names {
		a := wj.JS_NewAtom(ctx, name)
		wj.JS_DeleteProperty(ctx, proto, a, 0)
		wj.JS_FreeAtom(ctx, a)
	}
	return 0
}
