/* web_encoding.c: TextEncoder and TextDecoder (Encoding Standard), atob and btoa (HTML "forgiving-base64").
 *
 * TextEncoder lives in the engine (UTF-8 of a USVString is what the engine produces once lone surrogates are
 * replaced). TextDecoder is the browser's decoder (module encoding: every WHATWG label, replacement or fatal mode, BOM
 * handling, streaming): the input is read where it is, the result comes back in one copy. */
#include <stdlib.h>
#include "web.h"

/* ---- TextEncoder ---- */

JSValue wjr_TextEncoder_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor TextEncoder requires 'new'"); }
    return wj_new_object_for(ctx, WJ_IFACE_TextEncoder, new_target, NULL, NULL);
}

JSValue wjr_TextEncoder_get_encoding(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_TextEncoder)) { return JS_EXCEPTION; }
    return JS_NewString(ctx, "utf-8");
}

JSValue wjr_TextEncoder_encode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_TextEncoder)) { return JS_EXCEPTION; }
    JSValueConst in = wj_arg(argc, (JSValue *)argv, 0);
    if (JS_IsUndefined(in)) { return JS_NewUint8ArrayCopy(ctx, (const uint8_t *)"", 0); }
    wj_str s;
    if (!web_to_usv(ctx, in, &s)) { return JS_EXCEPTION; }
    JSValue r = JS_NewUint8ArrayCopy(ctx, (const uint8_t *)s.ptr, s.len);
    wj_str_free(ctx, &s);
    return r;
}

static int utf8_len(uint8_t lead) { return lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4; }

JSValue wjr_TextEncoder_encodeInto(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_TextEncoder)) { return JS_EXCEPTION; }
    if (argc < 2) { return wj_throw_arity(ctx, "TextEncoder.encodeInto", 2, argc); }
    if (wj_typed_array_type(argv[1]) != JS_TYPED_ARRAY_UINT8) { return JS_ThrowTypeError(ctx, "TextEncoder.encodeInto: the destination is not a Uint8Array"); }
    wj_str s;
    if (!web_to_usv(ctx, argv[0], &s)) { return JS_EXCEPTION; }
    uint8_t *dst;
    size_t cap;
    if (!wj_to_buffer_source(ctx, argv[1], &dst, &cap, WJ_BS_VIEW_ONLY | WJ_BS_ALLOW_SHARED, "TextEncoder.encodeInto")) { wj_str_free(ctx, &s); return JS_EXCEPTION; }
    /* whole characters only; `read` counts UTF-16 code units (a 4-byte sequence is a surrogate pair) */
    size_t i = 0, read = 0;
    while (i < s.len) {
        int n = utf8_len((uint8_t)s.ptr[i]);
        if (i + (size_t)n > s.len || i + (size_t)n > cap) { break; }
        i += (size_t)n;
        read += n == 4 ? 2 : 1;
    }
    memcpy(dst, s.ptr, i);
    wj_str_free(ctx, &s);
    JSValue r = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, r, "read", JS_NewFloat64(ctx, (double)read));
    JS_SetPropertyStr(ctx, r, "written", JS_NewFloat64(ctx, (double)i));
    return r;
}

/* ---- TextDecoder ---- */

JSValue wjr_TextDecoder_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor TextDecoder requires 'new'"); }
    wj_str label;
    if (!wj_to_str(ctx, wj_arg(argc, (JSValue *)argv, 0), &label, 0, "utf-8")) { return JS_EXCEPTION; }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 1);
    uint32_t flags = 0;
    if (!web_dict_check(ctx, opt, "TextDecoder")) { wj_str_free(ctx, &label); return JS_EXCEPTION; }
    JSValue fatal, bom;
    if (!web_dict_get(ctx, opt, "fatal", &fatal)) { wj_str_free(ctx, &label); return JS_EXCEPTION; }
    if (JS_ToBool(ctx, fatal)) { flags |= wr_TextDecoderOptions_Fatal; }
    JS_FreeValue(ctx, fatal);
    if (!web_dict_get(ctx, opt, "ignoreBOM", &bom)) { wj_str_free(ctx, &label); return JS_EXCEPTION; }
    if (JS_ToBool(ctx, bom)) { flags |= wr_TextDecoderOptions_Ignore_BOM; }
    JS_FreeValue(ctx, bom);
    /* the browser takes "" for utf-8; an empty label is not one (RangeError) */
    if (label.len == 0) { wj_str_free(ctx, &label); return JS_ThrowRangeError(ctx, "The encoding label provided ('') is invalid."); }
    uint64_t h = 0;
    int32_t st = wr_TextDecoder_create((const uint8_t *)label.ptr, (uint32_t)label.len, flags, &h);
    if (st < 0) {
        JSValue e = st == wr_Error_Range ? JS_ThrowRangeError(ctx, "The encoding label provided ('%.*s') is invalid.", (int)(label.len > 64 ? 64 : label.len), label.ptr)
                                         : wj_throw_status(ctx, st, "TextDecoder");
        wj_str_free(ctx, &label);
        return e;
    }
    wj_str_free(ctx, &label);
    return wj_wrap_owned(ctx, h, WJ_IFACE_TextDecoder, new_target);
}

static wj_obj *decoder_this(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_TextDecoder);
    if (o && !o->handle) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o;
}

JSValue wjr_TextDecoder_get_fatal(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = decoder_this(ctx, this_val);
    return o ? JS_NewBool(ctx, (wr_TextDecoder_flags(o->handle) & wr_TextDecoderOptions_Fatal) != 0) : JS_EXCEPTION;
}

JSValue wjr_TextDecoder_get_ignoreBOM(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = decoder_this(ctx, this_val);
    return o ? JS_NewBool(ctx, (wr_TextDecoder_flags(o->handle) & wr_TextDecoderOptions_Ignore_BOM) != 0) : JS_EXCEPTION;
}

JSValue wjr_TextDecoder_decode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = decoder_this(ctx, this_val);
    if (!o) { return JS_EXCEPTION; }
    JSValueConst in = wj_arg(argc, (JSValue *)argv, 0), opt = wj_arg(argc, (JSValue *)argv, 1);
    if (!web_dict_check(ctx, opt, "TextDecoder.decode")) { return JS_EXCEPTION; }
    JSValue sv;
    if (!web_dict_get(ctx, opt, "stream", &sv)) { return JS_EXCEPTION; }
    bool stream = JS_ToBool(ctx, sv);
    JS_FreeValue(ctx, sv);
    uint8_t *p = (uint8_t *)"";
    size_t n = 0;
    if (!JS_IsUndefined(in) && !wj_to_buffer_source(ctx, in, &p, &n, WJ_BS_ALLOW_SHARED, "TextDecoder.decode")) { return JS_EXCEPTION; }
    if (n > 0xFFFFFFFFu) { return JS_ThrowRangeError(ctx, "TextDecoder.decode: the input is too large"); }
    /* decoding changes the decoder's state: when the result does not fit, it is read again (TextDecoder_output) */
    if (!wj_scratch.data && !wj_scratch_grow(256)) { return JS_ThrowOutOfMemory(ctx); }
    int32_t r = wr_TextDecoder_decode(o->handle, p, (uint32_t)n, stream ? 1 : 0, wj_scratch.data, wj_scratch.cap);
    if (r < 0) {
        if (r == wr_Error_Type) { return JS_ThrowTypeError(ctx, "The encoded data was not valid."); }
        return wj_throw_status(ctx, r, "TextDecoder.decode");
    }
    if ((uint32_t)r > wj_scratch.cap) {
        if (!wj_scratch_grow((uint32_t)r)) { return JS_ThrowOutOfMemory(ctx); }
        r = wr_TextDecoder_output(o->handle, wj_scratch.data, wj_scratch.cap);
        if (r < 0) { r = 0; }
    }
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)r);
}

/* ---- atob / btoa ---- */

static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* the bytes of a "binary string" (each code unit one byte): false when one is past U+00FF */
static bool binary_bytes(const char *s, size_t n, uint8_t *out, size_t *m)
{
    size_t w = 0;
    for (size_t i = 0; i < n; i++) {
        uint8_t c = (uint8_t)s[i];
        if (c < 0x80) { out[w++] = c; continue; }
        if ((c == 0xC2 || c == 0xC3) && i + 1 < n) { out[w++] = (uint8_t)(((c & 0x1F) << 6) | ((uint8_t)s[i + 1] & 0x3F)); i++; continue; }
        return false;
    }
    *m = w;
    return true;
}

JSValue wjr_WindowOrWorkerGlobalScope_btoa(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "btoa", 1, argc); }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, NULL)) { return JS_EXCEPTION; }
    uint8_t *bytes = malloc(s.len + 1);
    size_t n = 0;
    if (!bytes) { wj_str_free(ctx, &s); return JS_ThrowOutOfMemory(ctx); }
    if (!binary_bytes(s.ptr, s.len, bytes, &n)) {
        free(bytes);
        wj_str_free(ctx, &s);
        return wj_throw_dom(ctx, "InvalidCharacterError", "Failed to execute 'btoa': The string to be encoded contains characters outside of the Latin1 range.");
    }
    wj_str_free(ctx, &s);
    size_t out_n = (n + 2) / 3 * 4;
    char *out = malloc(out_n + 1);
    if (!out) { free(bytes); return JS_ThrowOutOfMemory(ctx); }
    size_t w = 0, i = 0;
    for (; i + 2 < n; i += 3) {
        uint32_t v = (uint32_t)bytes[i] << 16 | (uint32_t)bytes[i + 1] << 8 | bytes[i + 2];
        out[w++] = b64[v >> 18]; out[w++] = b64[(v >> 12) & 63]; out[w++] = b64[(v >> 6) & 63]; out[w++] = b64[v & 63];
    }
    if (n - i == 1) {
        uint32_t v = (uint32_t)bytes[i] << 16;
        out[w++] = b64[v >> 18]; out[w++] = b64[(v >> 12) & 63]; out[w++] = '='; out[w++] = '=';
    } else if (n - i == 2) {
        uint32_t v = (uint32_t)bytes[i] << 16 | (uint32_t)bytes[i + 1] << 8;
        out[w++] = b64[v >> 18]; out[w++] = b64[(v >> 12) & 63]; out[w++] = b64[(v >> 6) & 63]; out[w++] = '=';
    }
    free(bytes);
    JSValue r = JS_NewStringLen(ctx, out, w);
    free(out);
    return r;
}

static int b64_value(uint8_t c)
{
    if (c >= 'A' && c <= 'Z') { return c - 'A'; }
    if (c >= 'a' && c <= 'z') { return c - 'a' + 26; }
    if (c >= '0' && c <= '9') { return c - '0' + 52; }
    if (c == '+') { return 62; }
    if (c == '/') { return 63; }
    return -1;
}

JSValue wjr_WindowOrWorkerGlobalScope_atob(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "atob", 1, argc); }
    wj_str s;
    if (!wj_to_str(ctx, argv[0], &s, 0, NULL)) { return JS_EXCEPTION; }
    /* forgiving-base64 decode: ASCII whitespace removed, padding checked, then 6 bits per character */
    char *clean = malloc(s.len + 1);
    if (!clean) { wj_str_free(ctx, &s); return JS_ThrowOutOfMemory(ctx); }
    size_t n = 0;
    for (size_t i = 0; i < s.len; i++) {
        char c = s.ptr[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\f' || c == '\r') { continue; }
        clean[n++] = c;
    }
    wj_str_free(ctx, &s);
    bool bad = false;
    if (n % 4 == 0 && n >= 1 && clean[n - 1] == '=') { n--; if (n >= 1 && clean[n - 1] == '=') { n--; } }
    if (n % 4 == 1) { bad = true; }
    for (size_t i = 0; i < n && !bad; i++) { if (b64_value((uint8_t)clean[i]) < 0) { bad = true; } }
    if (bad) {
        free(clean);
        return wj_throw_dom(ctx, "InvalidCharacterError", "Failed to execute 'atob': The string to be decoded is not correctly encoded.");
    }
    /* the result is a binary string: bytes past 0x7F are 2 bytes of UTF-8 */
    uint8_t *out = malloc(n / 4 * 3 * 2 + 8);
    if (!out) { free(clean); return JS_ThrowOutOfMemory(ctx); }
    size_t w = 0;
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < n; i++) {
        acc = (acc << 6) | (uint32_t)b64_value((uint8_t)clean[i]);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            uint8_t b = (uint8_t)(acc >> bits);
            if (b < 0x80) { out[w++] = b; } else { out[w++] = (uint8_t)(0xC0 | (b >> 6)); out[w++] = (uint8_t)(0x80 | (b & 0x3F)); }
        }
    }
    free(clean);
    JSValue r = JS_NewStringLen(ctx, (const char *)out, w);
    free(out);
    return r;
}
