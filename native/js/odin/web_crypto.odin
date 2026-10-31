// web_crypto.odin: crypto (Web Cryptography API): getRandomValues, randomUUID and subtle.digest on the browser's
// functions (module crypto). Ported from native/js/runtime/web_crypto.c; wjr_* symbols and behaviour identical. Random
// bytes are written straight into the view's memory. In a document that is not a secure context, crypto.subtle,
// crypto.randomUUID, SubtleCrypto and CryptoKey are absent.
//
// The other SubtleCrypto operations are web_crypto.js over the natives here, evaluated the first time a realm calls one
// (the one other exception, with web_wasm.js, to the rule of prelude.odin): the conversions and rules of the
// specification read better there, and the computations are not there but in the browser
// (src/page/bindings_crypto_subtle.odin), which keeps the material of the keys. A CryptoKey is native and holds a state
// made by web_crypto.js; nothing else of a page reaches that state.
package odin_glue

import "../odin/wj"




ERR_QUOTA_C :: i32(-13)   // wj.wr_Error_Quota (file-local alias)

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
		st := wj.wr_Crypto_getRandomValues(p, u32(n))
		if st < 0 {
			if st == ERR_QUOTA_C { return wj.wj_throw_dom(ctx, "QuotaExceededError", "Failed to execute 'getRandomValues' on 'Crypto': over crypto.max_random_bytes.") }
			return wj.wj_throw_status(ctx, st, "Crypto.getRandomValues")
		}
		wj.JS_ArrayBufferCommit(ctx, p, n)   // (a WebAssembly memory: these bytes were a copy)
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
	h := wj.wr_SubtleCrypto_digest(([^]u8)(rawptr(canon)), u32(len(canon)), p, u32(n))
	return wj.wj_promise_from_host(ctx, h, wj.HOST_ARRAYBUFFER, nil, wj.UNDEFINED)
}

// ---- keys ----

// A realm's CryptoKey: the state of web_crypto.js (its type, its algorithm, its usages, its data).
@(private = "file")
Key_Impl :: struct { state: wj.JSValue }

@(private = "file")
key_impl_free :: proc "c" (p: rawptr) {
	wj.JS_FreeValueRT(wj.web_rt(), (^Key_Impl)(p).state)
	wj.libc_free(p)
}

@(private = "file")
key_impl_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	wj.wj_mark(rt, (^Key_Impl)(p).state, mark_func)
}

@(private = "file") iface_key := i32(-2)

@(private = "file")
key_iface :: proc "c" () -> i32 {
	if iface_key == -2 { iface_key = wj.iface("CryptoKey") }
	return iface_key
}

// The state of a CryptoKey (not counted), nil for anything else.
@(private = "file")
key_impl_of :: proc "contextless" (v: wj.JSValue) -> ^Key_Impl {
	o := wj.obj_of(v)
	if o == nil || o.impl_free != key_impl_free { return nil }
	return (^Key_Impl)(o.impl)
}

@(private = "file")
key_attribute :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, name: cstring) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, key_iface()) == nil { return wj.EXCEPTION }
	k := key_impl_of(this_val)
	if k == nil { return wj.JS_ThrowTypeError(ctx, "Illegal invocation") }
	return wj.JS_GetPropertyStr(ctx, k.state, name)
}

@(export, link_name = "wjr_CryptoKey_get_type")
wjr_CryptoKey_get_type :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return key_attribute(ctx, this_val, "type") }
@(export, link_name = "wjr_CryptoKey_get_extractable")
wjr_CryptoKey_get_extractable :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return key_attribute(ctx, this_val, "extractable") }
@(export, link_name = "wjr_CryptoKey_get_algorithm")
wjr_CryptoKey_get_algorithm :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return key_attribute(ctx, this_val, "algorithm") }
@(export, link_name = "wjr_CryptoKey_get_usages")
wjr_CryptoKey_get_usages :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return key_attribute(ctx, this_val, "usages") }

// keyNew(state): the CryptoKey of a state
@(private = "file")
native_key_new :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	k := (^Key_Impl)(wj.libc_malloc(size_of(Key_Impl)))
	if k == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	k.state = wj.JS_DupValue(ctx, wj.arg(argc, argv, 0))
	obj := wj.wj_new_object(ctx, key_iface(), k, key_impl_free)
	if wj.is_exception(obj) { return obj }
	wj.obj_of(obj).impl_mark = key_impl_mark
	return obj
}

// keyState(value): its state when it is a CryptoKey, else undefined
@(private = "file")
native_key_state :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	k := key_impl_of(wj.arg(argc, argv, 0))
	return k != nil ? wj.JS_DupValue(ctx, k.state) : wj.UNDEFINED
}

// A key's material in the browser, for web_crypto.js: an object with nothing to see, which releases it when collected.
@(private = "file") data_class: wj.Class_ID

@(private = "file")
data_finalizer :: proc "c" (rt: ^wj.Runtime, val: wj.JSValue) {
	h := (^u64)(wj.JS_GetOpaque(val, data_class))
	if h == nil { return }
	wj.wr_Object_release(h^)
	wj.libc_free(h)
}

@(private = "file")
data_of :: proc "contextless" (v: wj.JSValue) -> u64 {
	h := (^u64)(wj.JS_GetOpaque(v, data_class))
	return h != nil ? h^ : 0
}

// `key` as a data object (takes it); null for 0, what a browser function gives for invalid values.
@(private = "file")
data_new :: proc "contextless" (ctx: ^wj.Context, key: u64) -> wj.JSValue {
	if key == 0 { return wj.NULL }
	h := (^u64)(wj.libc_malloc(size_of(u64)))
	if h == nil { wj.wr_Object_release(key); return wj.JS_ThrowOutOfMemory(ctx) }
	h^ = key
	obj := wj.JS_NewObjectClass(ctx, data_class)
	if wj.is_exception(obj) { wj.wr_Object_release(key); wj.libc_free(h); return obj }
	wj.JS_SetOpaque(obj, h)
	return obj
}

// A BufferSource's bytes as an argument of a browser function (it reads them before it returns).
@(private = "file")
Bytes :: struct { p: [^]u8, n: u32 }

@(private = "file")
bytes_arg :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, out: ^Bytes) -> bool {
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, v, &p, &n, 0, "SubtleCrypto") { return false }
	out^ = Bytes{n > 0 ? p : wj.empty_ptr(), u32(n)}
	return true
}

@(private = "file")
key_arg :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> (u64, bool) {
	h := data_of(v)
	if h == 0 { wj.JS_ThrowTypeError(ctx, "not the data of a key"); return 0, false }
	return h, true
}

@(private = "file")
buffer_promise :: proc "contextless" (ctx: ^wj.Context, h: u64) -> wj.JSValue { return wj.wj_promise_from_host(ctx, h, wj.HOST_ARRAYBUFFER, nil, wj.UNDEFINED) }

// copy(source): a new ArrayBuffer of a BufferSource's bytes
@(private = "file")
native_copy :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, wj.arg(argc, argv, 0), &p, &n, 0, "SubtleCrypto") { return wj.EXCEPTION }
	return wj.JS_NewArrayBufferCopy(ctx, n > 0 ? p : wj.empty_ptr(), n)
}

@(private = "file")
native_is_buffer :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.wj_is_buffer_source(wj.arg(argc, argv, 0)) ? wj.TRUE : wj.FALSE
}

// dom(name, message): a new DOMException
@(private = "file")
native_dom :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	name, message: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 0), &name, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &name)
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 1), &message, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &message)
	return wj.web_dom_exception(ctx, wj.cstr(name.ptr), wj.cstr(message.ptr))
}

// utf8(bytes): a string
@(private = "file")
native_utf8 :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b: Bytes
	if !bytes_arg(ctx, wj.arg(argc, argv, 0), &b) { return wj.EXCEPTION }
	return wj.JS_NewStringLen(ctx, b.p, uint(b.n))
}

// importRaw(kind, value, publicValue, isPrivate, extractable): the data, null when it is not valid
@(private = "file")
native_import_raw :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	kind: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 0), &kind, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &kind)
	a, b: Bytes
	if !bytes_arg(ctx, wj.arg(argc, argv, 1), &a) || !bytes_arg(ctx, wj.arg(argc, argv, 2), &b) { return wj.EXCEPTION }
	is_private, extractable := wj.to_bool(ctx, wj.arg(argc, argv, 3)), wj.to_bool(ctx, wj.arg(argc, argv, 4))
	return data_new(ctx, wj.wr_CryptoKey_importRaw(kind.ptr, u32(kind.len), a.p, a.n, b.p, b.n, is_private ? 1 : 0, extractable ? 1 : 0))
}

// importDer(kind, pkcs8, der, extractable)
@(private = "file")
native_import_der :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	kind: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 0), &kind, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &kind)
	der: Bytes
	if !bytes_arg(ctx, wj.arg(argc, argv, 2), &der) { return wj.EXCEPTION }
	pkcs8, extractable := wj.to_bool(ctx, wj.arg(argc, argv, 1)), wj.to_bool(ctx, wj.arg(argc, argv, 3))
	return data_new(ctx, wj.wr_CryptoKey_importDer(kind.ptr, u32(kind.len), pkcs8 ? 1 : 0, der.p, der.n, extractable ? 1 : 0))
}

// importRsa(n, e, d, p, q, dp, dq, qi, extractable)
@(private = "file")
native_import_rsa :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	v: [8]Bytes
	for i in 0 ..< 8 {
		if !bytes_arg(ctx, wj.arg(argc, argv, i32(i)), &v[i]) { return wj.EXCEPTION }
	}
	extractable := wj.to_bool(ctx, wj.arg(argc, argv, 8))
	return data_new(ctx, wj.wr_CryptoKey_importRsa(v[0].p, v[0].n, v[1].p, v[1].n, v[2].p, v[2].n, v[3].p, v[3].n, v[4].p, v[4].n, v[5].p, v[5].n, v[6].p, v[6].n, v[7].p, v[7].n, extractable ? 1 : 0))
}

// The promise of a new key settles with its data.
@(private = "file")
generate_settle :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	if reject^ { return wj.web_dom_exception(ctx, "OperationError", "The key could not be generated.") }
	return data_new(ctx, u64(value))
}

// generate(kind, bits, extractable): a promise of the data
@(private = "file")
native_generate :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	kind: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 0), &kind, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &kind)
	bits: i32
	wj.JS_ToInt32(ctx, &bits, wj.arg(argc, argv, 1))
	return wj.wj_promise_from_host(ctx, wj.wr_CryptoKey_generate(kind.ptr, u32(kind.len), bits, wj.to_bool(ctx, wj.arg(argc, argv, 2)) ? 1 : 0), 0, generate_settle, wj.UNDEFINED)
}

@(private = "file")
native_public_of :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h, ok := key_arg(ctx, wj.arg(argc, argv, 0))
	if !ok { return wj.EXCEPTION }
	return data_new(ctx, wj.wr_CryptoKey_publicOf(h))
}

@(private = "file")
native_modulus_bits :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h, ok := key_arg(ctx, wj.arg(argc, argv, 0))
	if !ok { return wj.EXCEPTION }
	return wj.new_int32(wj.wr_CryptoKey_modulusBits(h))
}

// exportPart(data, part): an ArrayBuffer. (The bytes are wiped from wj_scratch: they may be a key's.)
@(private = "file")
native_export_part :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h, ok := key_arg(ctx, wj.arg(argc, argv, 0))
	if !ok { return wj.EXCEPTION }
	part: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 1), &part, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &part)
	n := wj.wr_CryptoKey_export(h, part.ptr, u32(part.len), wj.wj_scratch.data, wj.wj_scratch.cap)
	if n > 0 && u32(n) > wj.wj_scratch.cap {
		if !wj.wj_scratch_grow(u32(n)) { return wj.JS_ThrowOutOfMemory(ctx) }
		n = wj.wr_CryptoKey_export(h, part.ptr, u32(part.len), wj.wj_scratch.data, wj.wj_scratch.cap)
	}
	if n < 0 { return wj.wj_throw_status(ctx, n, "SubtleCrypto.exportKey") }
	ab := wj.JS_NewArrayBufferCopy(ctx, n > 0 ? wj.wj_scratch.data : wj.empty_ptr(), uint(n))
	if n > 0 { wj.memset(wj.wj_scratch.data, 0, uint(n)) }
	return ab
}

// aes(mode, encrypt, data, iv, aad, n, input)
@(private = "file")
native_aes :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	mode: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 0), &mode, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &mode)
	h, ok := key_arg(ctx, wj.arg(argc, argv, 2))
	if !ok { return wj.EXCEPTION }
	iv, aad, input: Bytes
	if !bytes_arg(ctx, wj.arg(argc, argv, 3), &iv) || !bytes_arg(ctx, wj.arg(argc, argv, 4), &aad) || !bytes_arg(ctx, wj.arg(argc, argv, 6), &input) { return wj.EXCEPTION }
	n: i32
	wj.JS_ToInt32(ctx, &n, wj.arg(argc, argv, 5))
	return buffer_promise(ctx, wj.wr_SubtleCrypto_aes(mode.ptr, u32(mode.len), wj.to_bool(ctx, wj.arg(argc, argv, 1)) ? 1 : 0, h, iv.p, iv.n, aad.p, aad.n, n, input.p, input.n))
}

// aesKw(wrap, data, input)
@(private = "file")
native_aes_kw :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h, ok := key_arg(ctx, wj.arg(argc, argv, 1))
	if !ok { return wj.EXCEPTION }
	input: Bytes
	if !bytes_arg(ctx, wj.arg(argc, argv, 2), &input) { return wj.EXCEPTION }
	return buffer_promise(ctx, wj.wr_SubtleCrypto_aesKw(wj.to_bool(ctx, wj.arg(argc, argv, 0)) ? 1 : 0, h, input.p, input.n))
}

// oaep(encrypt, data, hash, label, input)
@(private = "file")
native_oaep :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h, ok := key_arg(ctx, wj.arg(argc, argv, 1))
	if !ok { return wj.EXCEPTION }
	alg: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 2), &alg, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &alg)
	label, input: Bytes
	if !bytes_arg(ctx, wj.arg(argc, argv, 3), &label) || !bytes_arg(ctx, wj.arg(argc, argv, 4), &input) { return wj.EXCEPTION }
	return buffer_promise(ctx, wj.wr_SubtleCrypto_rsaOaep(wj.to_bool(ctx, wj.arg(argc, argv, 0)) ? 1 : 0, h, alg.ptr, u32(alg.len), label.p, label.n, input.p, input.n))
}

// sign(scheme, data, hash, salt, input)
@(private = "file")
native_sign :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h, ok := key_arg(ctx, wj.arg(argc, argv, 1))
	if !ok { return wj.EXCEPTION }
	scheme, alg: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 0), &scheme, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &scheme)
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 2), &alg, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &alg)
	salt: i32
	wj.JS_ToInt32(ctx, &salt, wj.arg(argc, argv, 3))
	input: Bytes
	if !bytes_arg(ctx, wj.arg(argc, argv, 4), &input) { return wj.EXCEPTION }
	return buffer_promise(ctx, wj.wr_SubtleCrypto_sign(scheme.ptr, u32(scheme.len), h, alg.ptr, u32(alg.len), salt, input.p, input.n))
}

// verify(scheme, data, hash, salt, signature, input)
@(private = "file")
native_verify :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h, ok := key_arg(ctx, wj.arg(argc, argv, 1))
	if !ok { return wj.EXCEPTION }
	scheme, alg: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 0), &scheme, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &scheme)
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 2), &alg, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &alg)
	salt: i32
	wj.JS_ToInt32(ctx, &salt, wj.arg(argc, argv, 3))
	signature, input: Bytes
	if !bytes_arg(ctx, wj.arg(argc, argv, 4), &signature) || !bytes_arg(ctx, wj.arg(argc, argv, 5), &input) { return wj.EXCEPTION }
	return wj.wj_promise_from_host(ctx, wj.wr_SubtleCrypto_verify(scheme.ptr, u32(scheme.len), h, alg.ptr, u32(alg.len), salt, signature.p, signature.n, input.p, input.n), wj.HOST_BOOL, nil, wj.UNDEFINED)
}

// agree(data, peerData)
@(private = "file")
native_agree :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h, ok := key_arg(ctx, wj.arg(argc, argv, 0))
	if !ok { return wj.EXCEPTION }
	peer, ok2 := key_arg(ctx, wj.arg(argc, argv, 1))
	if !ok2 { return wj.EXCEPTION }
	return buffer_promise(ctx, wj.wr_SubtleCrypto_agree(h, peer))
}

// derive(data, hash, salt, info, iterations, size)
@(private = "file")
native_derive :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h, ok := key_arg(ctx, wj.arg(argc, argv, 0))
	if !ok { return wj.EXCEPTION }
	alg: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 1), &alg, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &alg)
	salt, info: Bytes
	if !bytes_arg(ctx, wj.arg(argc, argv, 2), &salt) || !bytes_arg(ctx, wj.arg(argc, argv, 3), &info) { return wj.EXCEPTION }
	iterations: f64
	size: i32
	wj.JS_ToFloat64(ctx, &iterations, wj.arg(argc, argv, 4))
	wj.JS_ToInt32(ctx, &size, wj.arg(argc, argv, 5))
	return buffer_promise(ctx, wj.wr_SubtleCrypto_derive(h, alg.ptr, u32(alg.len), salt.p, salt.n, info.p, info.n, i64(iterations), size))
}

// The operations of web_crypto.js, made on first use: a page that never asks for one pays nothing.
@(private = "file") crypto_ops: wj.JSValue
@(private = "file") crypto_ops_ready: bool

@(private = "file")
crypto_ops_get :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	if crypto_ops_ready { return crypto_ops }
	if data_class == 0 {
		rt := wj.JS_GetRuntime(ctx)
		wj.JS_NewClassID(rt, &data_class)
		def := wj.Class_Def{class_name = "CryptoKeyData", finalizer = data_finalizer}
		if wj.JS_NewClass(rt, data_class, &def) < 0 { data_class = 0; return wj.JS_ThrowOutOfMemory(ctx) }
	}
	fn := eval_prelude(ctx, "web_crypto.js", #load("web_crypto.js"))
	if wj.is_exception(fn) { return fn }
	defer wj.JS_FreeValue(ctx, fn)
	native := wj.JS_NewObject(ctx)
	defer wj.JS_FreeValue(ctx, native)
	Entry :: struct { name: cstring, fn: wj.Native, length: i32 }
	entries := [?]Entry{
		{"copy", native_copy, 1},
		{"isBuffer", native_is_buffer, 1},
		{"dom", native_dom, 2},
		{"utf8", native_utf8, 1},
		{"keyNew", native_key_new, 1},
		{"keyState", native_key_state, 1},
		{"importRaw", native_import_raw, 5},
		{"importDer", native_import_der, 4},
		{"importRsa", native_import_rsa, 9},
		{"generate", native_generate, 3},
		{"publicOf", native_public_of, 1},
		{"modulusBits", native_modulus_bits, 1},
		{"exportPart", native_export_part, 2},
		{"aes", native_aes, 7},
		{"aesKw", native_aes_kw, 3},
		{"oaep", native_oaep, 5},
		{"sign", native_sign, 5},
		{"verify", native_verify, 6},
		{"agree", native_agree, 2},
		{"derive", native_derive, 6},
	}
	for &e in entries {
		wj.JS_DefinePropertyValueStr(ctx, native, e.name, wj.new_cfunction(ctx, e.fn, e.name, e.length), wj.PROP_C_W_E)
	}
	ops := wj.JS_Call(ctx, fn, wj.UNDEFINED, 1, &native)
	if wj.is_exception(ops) { return ops }
	crypto_ops, crypto_ops_ready = ops, true
	return ops
}

// A call of an operation of web_crypto.js: its promise. (They are async functions: all they throw is in the promise.)
@(private = "file")
subtle_call :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, name: cstring, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, subtle_iface()) == nil { return wj.web_promise_reject_pending(ctx) }
	ops := crypto_ops_get(ctx)
	if wj.is_exception(ops) { return wj.web_promise_reject_pending(ctx) }
	fn := wj.JS_GetPropertyStr(ctx, ops, name)
	defer wj.JS_FreeValue(ctx, fn)
	r := wj.JS_Call(ctx, fn, wj.UNDEFINED, argc, argv)
	if wj.is_exception(r) { return wj.web_promise_reject_pending(ctx) }
	return r
}

@(export, link_name = "wjr_SubtleCrypto_encrypt")
wjr_SubtleCrypto_encrypt :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_call(ctx, t, "encrypt", argc, argv) }
@(export, link_name = "wjr_SubtleCrypto_decrypt")
wjr_SubtleCrypto_decrypt :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_call(ctx, t, "decrypt", argc, argv) }
@(export, link_name = "wjr_SubtleCrypto_sign")
wjr_SubtleCrypto_sign :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_call(ctx, t, "sign", argc, argv) }
@(export, link_name = "wjr_SubtleCrypto_verify")
wjr_SubtleCrypto_verify :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_call(ctx, t, "verify", argc, argv) }
@(export, link_name = "wjr_SubtleCrypto_generateKey")
wjr_SubtleCrypto_generateKey :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_call(ctx, t, "generateKey", argc, argv) }
@(export, link_name = "wjr_SubtleCrypto_deriveKey")
wjr_SubtleCrypto_deriveKey :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_call(ctx, t, "deriveKey", argc, argv) }
@(export, link_name = "wjr_SubtleCrypto_deriveBits")
wjr_SubtleCrypto_deriveBits :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_call(ctx, t, "deriveBits", argc, argv) }
@(export, link_name = "wjr_SubtleCrypto_importKey")
wjr_SubtleCrypto_importKey :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_call(ctx, t, "importKey", argc, argv) }
@(export, link_name = "wjr_SubtleCrypto_exportKey")
wjr_SubtleCrypto_exportKey :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_call(ctx, t, "exportKey", argc, argv) }
@(export, link_name = "wjr_SubtleCrypto_wrapKey")
wjr_SubtleCrypto_wrapKey :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_call(ctx, t, "wrapKey", argc, argv) }
@(export, link_name = "wjr_SubtleCrypto_unwrapKey")
wjr_SubtleCrypto_unwrapKey :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return subtle_call(ctx, t, "unwrapKey", argc, argv) }

// ---- structured serialization (clone.odin) ----

// A key's state (not counted) when `v` is a CryptoKey.
crypto_key_state :: proc "contextless" (v: wj.JSValue) -> (state: wj.JSValue, is_key: bool) {
	k := key_impl_of(v)
	if k == nil { return wj.UNDEFINED, false }
	return k.state, true
}

// The browser's form of the material of a state's key: in wj_scratch until the next host call. The size, -1 on failure.
crypto_key_serialize :: proc "contextless" (ctx: ^wj.Context, state: wj.JSValue) -> i32 {
	dv := wj.JS_GetPropertyStr(ctx, state, "data")
	defer wj.JS_FreeValue(ctx, dv)
	h := data_of(dv)
	if h == 0 { return -1 }
	n := wj.wr_CryptoKey_serialize(h, wj.wj_scratch.data, wj.wj_scratch.cap)
	if n > 0 && u32(n) > wj.wj_scratch.cap {
		if !wj.wj_scratch_grow(u32(n)) { return -1 }
		n = wj.wr_CryptoKey_serialize(h, wj.wj_scratch.data, wj.wj_scratch.cap)
	}
	return n
}

// The key of serialized bytes in this realm. alg and list: its internal algorithm and usages.
crypto_key_adopt :: proc "contextless" (ctx: ^wj.Context, material: []u8, type, extractable, alg, list: wj.JSValue) -> wj.JSValue {
	ops := crypto_ops_get(ctx)
	if wj.is_exception(ops) { return ops }
	d := data_new(ctx, wj.wr_CryptoKey_deserialize(len(material) > 0 ? raw_data(material) : wj.empty_ptr(), u32(len(material))))
	if wj.is_exception(d) { return d }
	defer wj.JS_FreeValue(ctx, d)
	if wj.is_null(d) { return wj.wj_throw_dom(ctx, "DataCloneError", "The key could not be read.") }
	fn := wj.JS_GetPropertyStr(ctx, ops, "keyAdopt")
	defer wj.JS_FreeValue(ctx, fn)
	args := [5]wj.JSValue{d, type, extractable, alg, list}
	return wj.JS_Call(ctx, fn, wj.UNDEFINED, 5, &args[0])
}

// [SecureContext] members and interfaces are absent from documents that are not secure contexts.
@(export, link_name = "web_crypto_start")
web_crypto_start :: proc "c" (ctx: ^wj.Context, kind: i32) -> i32 {
	if wj.wr_Window_isSecureContext() != 0 { return 0 }
	proto := wj.realm_proto(crypto_iface())
	if !wj.is_object(proto) { return 0 }
	names := [2]cstring{ "subtle", "randomUUID" }
	for name in names {
		a := wj.JS_NewAtom(ctx, name)
		wj.JS_DeleteProperty(ctx, proto, a, 0)
		wj.JS_FreeAtom(ctx, a)
	}
	globals := [2]cstring{ "SubtleCrypto", "CryptoKey" }
	for name in globals {
		a := wj.JS_NewAtom(ctx, name)
		wj.JS_DeleteProperty(ctx, wj.wj_the_realm.global, a, 0)
		wj.JS_FreeAtom(ctx, a)
	}
	return 0
}
