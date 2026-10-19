/* web_crypto.c: crypto (Web Cryptography API): getRandomValues, randomUUID and subtle.digest on the browser's
 * BCrypt-backed functions (module crypto). The random bytes are written straight into the view's memory. Other
 * SubtleCrypto operations reject with NotSupportedError. In a document that is not a secure context, crypto.subtle and
 * crypto.randomUUID are absent ([SecureContext]). */
#include <stdio.h>
#include <stdlib.h>
#include "web.h"

static JSValue make_crypto(JSContext *ctx) { return wj_new_object(ctx, WJ_IFACE_Crypto, NULL, NULL); }
static JSValue make_subtle(JSContext *ctx) { return wj_new_object(ctx, WJ_IFACE_SubtleCrypto, NULL, NULL); }

JSValue wjr_WindowOrWorkerGlobalScope_get_crypto(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return web_singleton(ctx, WEB_SINGLE_CRYPTO, make_crypto); }

JSValue wjr_Crypto_get_subtle(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Crypto)) { return JS_EXCEPTION; }
    return web_singleton(ctx, WEB_SINGLE_SUBTLE, make_subtle);
}

/* the Web Cryptography API's limit, before the browser's own (crypto.max_random_bytes) */
#define WEB_RANDOM_MAX 65536

JSValue wjr_Crypto_getRandomValues(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Crypto)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Crypto.getRandomValues", 1, argc); }
    int t = wj_typed_array_type(argv[0]);
    bool integer = t == JS_TYPED_ARRAY_INT8 || t == JS_TYPED_ARRAY_UINT8 || t == JS_TYPED_ARRAY_UINT8C || t == JS_TYPED_ARRAY_INT16 ||
                   t == JS_TYPED_ARRAY_UINT16 || t == JS_TYPED_ARRAY_INT32 || t == JS_TYPED_ARRAY_UINT32 ||
                   t == JS_TYPED_ARRAY_BIG_INT64 || t == JS_TYPED_ARRAY_BIG_UINT64;
    if (!integer) {
        if (t >= 0 || wj_is_buffer_source(argv[0])) { return wj_throw_dom(ctx, "TypeMismatchError", "Failed to execute 'getRandomValues' on 'Crypto': The provided ArrayBufferView is not an integer array type."); }
        return JS_ThrowTypeError(ctx, "Failed to execute 'getRandomValues' on 'Crypto': parameter 1 is not of type 'ArrayBufferView'.");
    }
    uint8_t *p;
    size_t n;
    if (!wj_to_buffer_source(ctx, argv[0], &p, &n, WJ_BS_VIEW_ONLY | WJ_BS_ALLOW_SHARED, "Crypto.getRandomValues")) { return JS_EXCEPTION; }
    if (n > WEB_RANDOM_MAX) { return wj_throw_dom(ctx, "QuotaExceededError", "Failed to execute 'getRandomValues' on 'Crypto': The ArrayBufferView's byte length exceeds the number of bytes of entropy available via this API (65536)."); }
    if (n > 0) {
        int32_t st = wr_Crypto_getRandomValues(p, (uint32_t)n);
        if (st < 0) {
            if (st == wr_Error_Quota) { return wj_throw_dom(ctx, "QuotaExceededError", "Failed to execute 'getRandomValues' on 'Crypto': over crypto.max_random_bytes."); }
            return wj_throw_status(ctx, st, "Crypto.getRandomValues");
        }
    }
    return JS_DupValue(ctx, argv[0]);
}

/* AlgorithmIdentifier: a string, or an object with a name */
static bool algorithm_name(JSContext *ctx, JSValueConst v, wj_str *out)
{
    if (JS_IsObject(v)) {
        JSValue n = JS_GetPropertyStr(ctx, v, "name");
        if (JS_IsException(n)) { return false; }
        if (JS_IsUndefined(n)) { JS_ThrowTypeError(ctx, "Algorithm: name is missing"); return false; }
        bool ok = wj_to_str(ctx, n, out, 0, NULL);
        JS_FreeValue(ctx, n);
        return ok;
    }
    return wj_to_str(ctx, v, out, 0, NULL);
}

JSValue wjr_SubtleCrypto_digest(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_SubtleCrypto)) { return web_promise_reject_pending(ctx); }
    if (argc < 2) { wj_throw_arity(ctx, "SubtleCrypto.digest", 2, argc); return web_promise_reject_pending(ctx); }
    wj_str alg;
    if (!algorithm_name(ctx, argv[0], &alg)) { return web_promise_reject_pending(ctx); }
    /* the registered names, matched ASCII case-insensitively */
    static const char *names[] = { "SHA-1", "SHA-256", "SHA-384", "SHA-512" };
    const char *canon = NULL;
    for (size_t i = 0; i < WEB_COUNT(names); i++) { if (web_ascii_ieq(alg.ptr, alg.len, names[i])) { canon = names[i]; } }
    wj_str_free(ctx, &alg);
    if (!canon) { return web_promise_rejected(ctx, web_dom_exception(ctx, "NotSupportedError", "Failed to execute 'digest' on 'SubtleCrypto': Algorithm: Unrecognized name")); }
    uint8_t *p;
    size_t n;
    if (!wj_to_buffer_source(ctx, argv[1], &p, &n, 0, "SubtleCrypto.digest")) { return web_promise_reject_pending(ctx); }
    if (n > 0xFFFFFFFFu) { return web_promise_rejected(ctx, web_dom_exception(ctx, "QuotaExceededError", "the data is too large")); }
    /* the browser copies the bytes before this returns: later changes of the buffer do not matter */
    uint64_t h = wr_SubtleCrypto_digest((const uint8_t *)canon, (uint32_t)strlen(canon), p, (uint32_t)n);
    return wj_promise_from_host(ctx, h, WJ_HOST_ARRAYBUFFER, NULL, JS_UNDEFINED);
}

static JSValue subtle_unsupported(JSContext *ctx, JSValueConst this_val, const char *what)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_SubtleCrypto)) { return web_promise_reject_pending(ctx); }
    char msg[160];
    snprintf(msg, sizeof msg, "SubtleCrypto.%s is not supported by this browser", what);
    return web_promise_rejected(ctx, web_dom_exception(ctx, "NotSupportedError", msg));
}

#define SUBTLE_UNSUPPORTED(op) \
    JSValue wjr_SubtleCrypto_##op(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return subtle_unsupported(ctx, this_val, #op); }
SUBTLE_UNSUPPORTED(encrypt)
SUBTLE_UNSUPPORTED(decrypt)
SUBTLE_UNSUPPORTED(sign)
SUBTLE_UNSUPPORTED(verify)
SUBTLE_UNSUPPORTED(generateKey)
SUBTLE_UNSUPPORTED(deriveKey)
SUBTLE_UNSUPPORTED(deriveBits)
SUBTLE_UNSUPPORTED(importKey)
SUBTLE_UNSUPPORTED(exportKey)
SUBTLE_UNSUPPORTED(wrapKey)
SUBTLE_UNSUPPORTED(unwrapKey)
/* the macro hides them from the generator (it finds hand-written members by name at the start of a line) */
JSValue wjr_SubtleCrypto_encrypt(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
JSValue wjr_SubtleCrypto_decrypt(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
JSValue wjr_SubtleCrypto_sign(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
JSValue wjr_SubtleCrypto_verify(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
JSValue wjr_SubtleCrypto_generateKey(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
JSValue wjr_SubtleCrypto_deriveKey(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
JSValue wjr_SubtleCrypto_deriveBits(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
JSValue wjr_SubtleCrypto_importKey(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
JSValue wjr_SubtleCrypto_exportKey(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
JSValue wjr_SubtleCrypto_wrapKey(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
JSValue wjr_SubtleCrypto_unwrapKey(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);

/* [SecureContext] members are absent from documents that are not secure contexts */
int web_crypto_start(JSContext *ctx, int kind)
{
    WJ_UNUSED(kind);
    if (wr_Window_isSecureContext()) { return 0; }
    JSValue proto = wj_the_realm.protos[WJ_IFACE_Crypto];
    if (!JS_IsObject(proto)) { return 0; }
    static const char *names[] = { "subtle", "randomUUID" };
    for (int i = 0; i < 2; i++) {
        JSAtom a = JS_NewAtom(ctx, names[i]);
        JS_DeleteProperty(ctx, proto, a, 0);
        JS_FreeAtom(ctx, a);
    }
    return 0;
}
