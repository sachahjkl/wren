/* web_credentials.c: navigator.credentials (Credential Management) and Web Authentication Level 3 (PublicKeyCredential,
 * AuthenticatorAttestationResponse, AuthenticatorAssertionResponse) on the browser's module "credentials".
 *
 * The browser does the ceremony (src/webauthn, src/page/bindings_webauthn.odin): it takes the options in their standard
 * JSON form. So create() and get() convert the dictionary as Web IDL does (the generated wjd_* converters, sequences and
 * records converted here), copy every BufferSource at once (WebAuthn: "snapshotted when the algorithm begins") into
 * base64url, and hand the JSON over with the mediation and the signal. The answer, a browser object, becomes a
 * PublicKeyCredential whose [SameObject] members are made once (ArrayBuffers, the response); the browser object is
 * released at once. parseCreationOptionsFromJSON / parseRequestOptionsFromJSON / toJSON / getClientExtensionResults
 * are the same conversions the other way. A rejection of the browser's promise becomes the DOMException its code names,
 * or the signal's reason after an abort. */
#include <stdio.h>
#include <stdlib.h>
#include "web.h"

/* ---- base64url ---- */

static const char B64URL[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

static void b64_put(web_buf *b, const uint8_t *p, size_t n)
{
    char q[4];
    size_t i = 0;
    for (; i + 3 <= n; i += 3) {
        uint32_t v = (uint32_t)p[i] << 16 | (uint32_t)p[i + 1] << 8 | p[i + 2];
        q[0] = B64URL[v >> 18 & 63]; q[1] = B64URL[v >> 12 & 63]; q[2] = B64URL[v >> 6 & 63]; q[3] = B64URL[v & 63];
        web_buf_put(b, q, 4);
    }
    if (n - i == 1) {
        uint32_t v = (uint32_t)p[i] << 16;
        q[0] = B64URL[v >> 18 & 63]; q[1] = B64URL[v >> 12 & 63];
        web_buf_put(b, q, 2);
    } else if (n - i == 2) {
        uint32_t v = (uint32_t)p[i] << 16 | (uint32_t)p[i + 1] << 8;
        q[0] = B64URL[v >> 18 & 63]; q[1] = B64URL[v >> 12 & 63]; q[2] = B64URL[v >> 6 & 63];
        web_buf_put(b, q, 3);
    }
}

static int b64_value(char c)
{
    if (c >= 'A' && c <= 'Z') { return c - 'A'; }
    if (c >= 'a' && c <= 'z') { return c - 'a' + 26; }
    if (c >= '0' && c <= '9') { return c - '0' + 52; }
    if (c == '-') { return 62; }
    if (c == '_') { return 63; }
    return -1;
}

/* An ArrayBuffer of the decoded bytes, or JS_EXCEPTION with an EncodingError pending (trailing '=' tolerated, as the
 * browser does). */
static JSValue b64_arraybuffer(JSContext *ctx, const char *s, size_t n, const char *what)
{
    while (n > 0 && s[n - 1] == '=') { n--; }
    if (n % 4 == 1) { goto bad; }
    uint8_t *out = malloc(n / 4 * 3 + 3);
    if (!out) { return JS_ThrowOutOfMemory(ctx); }
    size_t k = 0;
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < n; i++) {
        int v = b64_value(s[i]);
        if (v < 0) { free(out); goto bad; }
        acc = acc << 6 | (uint32_t)v;
        bits += 6;
        if (bits >= 8) { bits -= 8; out[k++] = (uint8_t)(acc >> bits); acc &= (1u << bits) - 1; }
    }
    JSValue ab = JS_NewArrayBufferCopy(ctx, out, k);
    free(out);
    return ab;
bad:;
    char msg[160];
    snprintf(msg, sizeof msg, "'%s' is not valid base64url", what);
    return wj_throw_dom(ctx, "EncodingError", msg);
}

static bool b64_valid(const char *s, size_t n)
{
    while (n > 0 && s[n - 1] == '=') { n--; }
    if (n % 4 == 1) { return false; }
    for (size_t i = 0; i < n; i++) { if (b64_value(s[i]) < 0) { return false; } }
    return true;
}

/* ---- a JSON writer (the options' JSON form) ---- */

typedef struct jw { web_buf b; uint64_t comma; int depth; } jw;

static void jw_sep(jw *w)
{
    uint64_t bit = 1ull << (w->depth & 63);
    if (w->comma & bit) { web_buf_put(&w->b, ",", 1); }
    w->comma |= bit;
}
static void jw_open(jw *w, char c) { web_buf_put(&w->b, &c, 1); w->depth++; w->comma &= ~(1ull << (w->depth & 63)); }
static void jw_close(jw *w, char c) { web_buf_put(&w->b, &c, 1); w->depth--; }
static void jw_key(jw *w, const char *k) { jw_sep(w); web_buf_puts(&w->b, "\""); web_buf_puts(&w->b, k); web_buf_puts(&w->b, "\":"); }
static void jw_elem(jw *w) { jw_sep(w); }
static void jw_string(jw *w, const char *p, size_t n)
{
    static const char HEX[] = "0123456789abcdef";
    web_buf_put(&w->b, "\"", 1);
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)p[i];
        if (c == '"') { web_buf_puts(&w->b, "\\\""); }
        else if (c == '\\') { web_buf_puts(&w->b, "\\\\"); }
        else if (c < 0x20) { char e[6] = {'\\', 'u', '0', '0', HEX[c >> 4], HEX[c & 15]}; web_buf_put(&w->b, e, 6); }
        else { web_buf_put(&w->b, &p[i], 1); }
    }
    web_buf_put(&w->b, "\"", 1);
}
static void jw_cstr(jw *w, const char *s) { jw_string(w, s, strlen(s)); }
static void jw_wstr(jw *w, const wj_str *s) { jw_string(w, s->ptr ? s->ptr : "", s->ptr ? s->len : 0); }
static void jw_b64(jw *w, const uint8_t *p, size_t n) { web_buf_put(&w->b, "\"", 1); b64_put(&w->b, p, n); web_buf_put(&w->b, "\"", 1); }
static void jw_int(jw *w, long long v) { char t[32]; snprintf(t, sizeof t, "%lld", v); web_buf_puts(&w->b, t); }
static void jw_bool(jw *w, bool v) { web_buf_puts(&w->b, v ? "true" : "false"); }

/* a BufferSource member, copied now */
static bool jw_buffer(JSContext *ctx, jw *w, const char *key, JSValueConst v, const char *what)
{
    uint8_t *p;
    size_t n;
    if (!wj_to_buffer_source(ctx, v, &p, &n, 0, what)) { return false; }
    if (key) { jw_key(w, key); } else { jw_elem(w); }
    jw_b64(w, p, n);
    return true;
}

/* Reads a dictionary member (undefined when the dictionary is undefined or null). */
static bool member(JSContext *ctx, JSValueConst dict, const char *name, JSValue *out)
{
    return web_dict_get(ctx, dict, name, out);
}

static bool required_missing(JSContext *ctx, const char *name, const char *dict)
{
    JS_ThrowTypeError(ctx, "Failed to read the '%s' property from '%s': Required member is undefined.", name, dict);
    return false;
}

/* sequence<DOMString> as a JSON array */
typedef struct seq_ctx { jw *w; const char *what; } seq_ctx;

static bool string_item(JSContext *ctx, JSValueConst item, void *opaque)
{
    seq_ctx *s = opaque;
    wj_str v;
    if (!wj_to_str(ctx, item, &v, 0, NULL)) { return false; }
    jw_elem(s->w);
    jw_wstr(s->w, &v);
    wj_str_free(ctx, &v);
    return true;
}

static bool sequence(JSContext *ctx, JSValueConst v, const char *what, bool (*fn)(JSContext *, JSValueConst, void *), void *opaque)
{
    int it = web_is_iterable(ctx, v);
    if (it < 0) { return false; }
    if (!it) { JS_ThrowTypeError(ctx, "Failed to convert '%s': the value is not iterable.", what); return false; }
    return web_for_of(ctx, v, fn, opaque);
}

static bool jw_strings(JSContext *ctx, jw *w, const char *key, JSValueConst v)
{
    jw_key(w, key);
    jw_open(w, '[');
    seq_ctx s = { w, key };
    bool ok = sequence(ctx, v, key, string_item, &s);
    jw_close(w, ']');
    return ok;
}

/* PublicKeyCredentialParameters: alg, type (both required) */
static bool param_item(JSContext *ctx, JSValueConst item, void *opaque)
{
    jw *w = ((seq_ctx *)opaque)->w;
    if (!web_dict_check(ctx, item, "PublicKeyCredentialParameters")) { return false; }
    JSValue a, t;
    if (!member(ctx, item, "alg", &a)) { return false; }
    if (JS_IsUndefined(a)) { return required_missing(ctx, "alg", "PublicKeyCredentialParameters"); }
    int32_t alg;
    bool ok = wj_to_int32(ctx, a, &alg, 32, 0);
    JS_FreeValue(ctx, a);
    if (!ok || !member(ctx, item, "type", &t)) { return false; }
    if (JS_IsUndefined(t)) { return required_missing(ctx, "type", "PublicKeyCredentialParameters"); }
    wj_str type;
    ok = wj_to_str(ctx, t, &type, 0, NULL);
    JS_FreeValue(ctx, t);
    if (!ok) { return false; }
    jw_elem(w); jw_open(w, '{');
    jw_key(w, "type"); jw_wstr(w, &type);
    jw_key(w, "alg"); jw_int(w, alg);
    jw_close(w, '}');
    wj_str_free(ctx, &type);
    return true;
}

/* PublicKeyCredentialDescriptor: id (required BufferSource), transports, type (required) */
static bool descriptor_item(JSContext *ctx, JSValueConst item, void *opaque)
{
    jw *w = ((seq_ctx *)opaque)->w;
    if (!web_dict_check(ctx, item, "PublicKeyCredentialDescriptor")) { return false; }
    JSValue id, tr, t;
    if (!member(ctx, item, "id", &id)) { return false; }
    if (JS_IsUndefined(id)) { return required_missing(ctx, "id", "PublicKeyCredentialDescriptor"); }
    jw_elem(w); jw_open(w, '{');
    bool ok = jw_buffer(ctx, w, "id", id, "PublicKeyCredentialDescriptor.id");
    JS_FreeValue(ctx, id);
    if (!ok || !member(ctx, item, "transports", &tr)) { return false; }
    if (!JS_IsUndefined(tr)) { ok = jw_strings(ctx, w, "transports", tr); }
    JS_FreeValue(ctx, tr);
    if (!ok || !member(ctx, item, "type", &t)) { return false; }
    if (JS_IsUndefined(t)) { return required_missing(ctx, "type", "PublicKeyCredentialDescriptor"); }
    wj_str type;
    ok = wj_to_str(ctx, t, &type, 0, NULL);
    JS_FreeValue(ctx, t);
    if (!ok) { return false; }
    jw_key(w, "type"); jw_wstr(w, &type);
    wj_str_free(ctx, &type);
    jw_close(w, '}');
    return true;
}

static bool jw_descriptors(JSContext *ctx, jw *w, const char *key, JSValueConst v)
{
    jw_key(w, key);
    jw_open(w, '[');
    seq_ctx s = { w, key };
    bool ok = JS_IsUndefined(v) || sequence(ctx, v, key, descriptor_item, &s);
    jw_close(w, ']');
    return ok;
}

static bool jw_prf_values(JSContext *ctx, jw *w, const wjd_AuthenticationExtensionsPRFValues *v)
{
    jw_open(w, '{');
    if (!jw_buffer(ctx, w, "first", v->first, "prf.first")) { return false; }
    if (v->has_second && !jw_buffer(ctx, w, "second", v->second, "prf.second")) { return false; }
    jw_close(w, '}');
    return true;
}

static bool prf_record_entry(JSContext *ctx, JSValueConst key, JSValueConst value, void *opaque)
{
    jw *w = opaque;
    wj_str k;
    if (!wj_to_str(ctx, key, &k, 0, NULL)) { return false; }
    wjd_AuthenticationExtensionsPRFValues v;
    bool ok = wjd_AuthenticationExtensionsPRFValues_from(ctx, value, &v);
    if (ok) {
        jw_sep(w);
        jw_wstr(w, &k);
        web_buf_puts(&w->b, ":");
        ok = jw_prf_values(ctx, w, &v);
        wjd_AuthenticationExtensionsPRFValues_free(ctx, &v);
    }
    wj_str_free(ctx, &k);
    return ok;
}

/* Extensions this client knows (WebAuthn's from the IDL, CTAP2's read from the object), in their JSON form. */
static bool jw_extensions(JSContext *ctx, jw *w, JSValueConst raw)
{
    wjd_AuthenticationExtensionsClientInputs e;
    if (!wjd_AuthenticationExtensionsClientInputs_from(ctx, raw, &e)) { return false; }
    bool ok = true;
    jw_key(w, "extensions");
    jw_open(w, '{');
    if (e.has_appid) { jw_key(w, "appid"); jw_wstr(w, &e.appid); }
    if (e.has_appidExclude) { jw_key(w, "appidExclude"); jw_wstr(w, &e.appidExclude); }
    if (e.has_credProps) { jw_key(w, "credProps"); jw_bool(w, e.credProps); }
    if (e.has_largeBlob) {
        jw_key(w, "largeBlob"); jw_open(w, '{');
        if (e.largeBlob.has_support) { jw_key(w, "support"); jw_wstr(w, &e.largeBlob.support); }
        if (e.largeBlob.has_read) { jw_key(w, "read"); jw_bool(w, e.largeBlob.read); }
        if (e.largeBlob.has_write) { ok = jw_buffer(ctx, w, "write", e.largeBlob.write, "largeBlob.write"); }
        jw_close(w, '}');
    }
    if (ok && e.has_prf) {
        jw_key(w, "prf"); jw_open(w, '{');
        if (e.prf.has_eval) { jw_key(w, "eval"); ok = jw_prf_values(ctx, w, &e.prf.eval); }
        if (ok && e.prf.has_evalByCredential) {
            jw_key(w, "evalByCredential"); jw_open(w, '{');
            ok = web_for_record(ctx, e.prf.evalByCredential, prf_record_entry, w);
            jw_close(w, '}');
        }
        jw_close(w, '}');
    }
    wjd_AuthenticationExtensionsClientInputs_free(ctx, &e);
    /* CTAP2 extensions (credProtect, credBlob, minPinLength, hmac-secret), as Chromium exposes them */
    static const struct { const char *name; int kind; } ctap[] = {
        {"credBlob", 2}, {"credentialProtectionPolicy", 1}, {"enforceCredentialProtectionPolicy", 0}, {"getCredBlob", 0},
        {"hmacCreateSecret", 0}, {"minPinLength", 0},
    };
    for (size_t i = 0; ok && i < WEB_COUNT(ctap) && JS_IsObject(raw); i++) {
        JSValue v = JS_GetPropertyStr(ctx, raw, ctap[i].name);
        if (JS_IsException(v)) { ok = false; break; }
        if (!JS_IsUndefined(v)) {
            if (ctap[i].kind == 0) { int b = JS_ToBool(ctx, v); if (b < 0) { ok = false; } else { jw_key(w, ctap[i].name); jw_bool(w, b); } }
            else if (ctap[i].kind == 1) { wj_str s; if (!wj_to_str(ctx, v, &s, 0, NULL)) { ok = false; } else { jw_key(w, ctap[i].name); jw_wstr(w, &s); wj_str_free(ctx, &s); } }
            else { ok = jw_buffer(ctx, w, ctap[i].name, v, ctap[i].name); }
        }
        JS_FreeValue(ctx, v);
    }
    jw_close(w, '}');
    return ok;
}

static bool jw_hints(JSContext *ctx, jw *w, JSValueConst v) { return JS_IsUndefined(v) ? (jw_key(w, "hints"), web_buf_puts(&w->b, "[]"), true) : jw_strings(ctx, w, "hints", v); }

/* PublicKeyCredentialCreationOptions -> PublicKeyCredentialCreationOptionsJSON */
static bool creation_json(JSContext *ctx, JSValueConst pk_raw, const wjd_PublicKeyCredentialCreationOptions *o, jw *w)
{
    jw_open(w, '{');
    jw_key(w, "rp"); jw_open(w, '{');
    jw_key(w, "name"); jw_wstr(w, &o->rp.base.name);
    if (o->rp.has_id) { jw_key(w, "id"); jw_wstr(w, &o->rp.id); }
    jw_close(w, '}');
    jw_key(w, "user"); jw_open(w, '{');
    if (!jw_buffer(ctx, w, "id", o->user.id, "user.id")) { return false; }
    jw_key(w, "name"); jw_wstr(w, &o->user.base.name);
    jw_key(w, "displayName"); jw_wstr(w, &o->user.displayName);
    jw_close(w, '}');
    if (!jw_buffer(ctx, w, "challenge", o->challenge, "challenge")) { return false; }
    jw_key(w, "pubKeyCredParams"); jw_open(w, '[');
    seq_ctx s = { w, "pubKeyCredParams" };
    if (!sequence(ctx, o->pubKeyCredParams, "pubKeyCredParams", param_item, &s)) { return false; }
    jw_close(w, ']');
    if (o->has_timeout) { jw_key(w, "timeout"); jw_int(w, o->timeout); }
    if (!jw_descriptors(ctx, w, "excludeCredentials", o->excludeCredentials)) { return false; }
    if (o->has_authenticatorSelection) {
        const wjd_AuthenticatorSelectionCriteria *a = &o->authenticatorSelection;
        jw_key(w, "authenticatorSelection"); jw_open(w, '{');
        if (a->has_authenticatorAttachment) { jw_key(w, "authenticatorAttachment"); jw_wstr(w, &a->authenticatorAttachment); }
        if (a->has_residentKey) { jw_key(w, "residentKey"); jw_wstr(w, &a->residentKey); }
        jw_key(w, "requireResidentKey"); jw_bool(w, a->requireResidentKey);
        jw_key(w, "userVerification"); jw_wstr(w, &a->userVerification);
        jw_close(w, '}');
    }
    if (!jw_hints(ctx, w, o->hints)) { return false; }
    jw_key(w, "attestation"); jw_wstr(w, &o->attestation);
    if (!JS_IsUndefined(o->attestationFormats) && !jw_strings(ctx, w, "attestationFormats", o->attestationFormats)) { return false; }
    if (o->has_extensions) {
        JSValue raw;
        if (!member(ctx, pk_raw, "extensions", &raw)) { return false; }
        bool ok = jw_extensions(ctx, w, raw);
        JS_FreeValue(ctx, raw);
        if (!ok) { return false; }
    }
    jw_close(w, '}');
    return true;
}

/* PublicKeyCredentialRequestOptions -> PublicKeyCredentialRequestOptionsJSON */
static bool request_json(JSContext *ctx, JSValueConst pk_raw, const wjd_PublicKeyCredentialRequestOptions *o, jw *w)
{
    jw_open(w, '{');
    if (!jw_buffer(ctx, w, "challenge", o->challenge, "challenge")) { return false; }
    if (o->has_timeout) { jw_key(w, "timeout"); jw_int(w, o->timeout); }
    if (o->has_rpId) { jw_key(w, "rpId"); jw_wstr(w, &o->rpId); }
    if (!jw_descriptors(ctx, w, "allowCredentials", o->allowCredentials)) { return false; }
    jw_key(w, "userVerification"); jw_wstr(w, &o->userVerification);
    if (!jw_hints(ctx, w, o->hints)) { return false; }
    if (o->has_extensions) {
        JSValue raw;
        if (!member(ctx, pk_raw, "extensions", &raw)) { return false; }
        bool ok = jw_extensions(ctx, w, raw);
        JS_FreeValue(ctx, raw);
        if (!ok) { return false; }
    }
    jw_close(w, '}');
    return true;
}

/* ---- credentials ---- */

typedef struct cred_impl { JSValue raw_id, response, id, attachment, ext_json, json; } cred_impl;
typedef struct resp_impl { JSValue client_data, attestation_object, authenticator_data, signature, user_handle, public_key, transports; int32_t alg; bool assertion; } resp_impl;

static void cred_free(void *p)
{
    cred_impl *c = p;
    JSRuntime *rt = web_rt();
    JS_FreeValueRT(rt, c->raw_id); JS_FreeValueRT(rt, c->response); JS_FreeValueRT(rt, c->id);
    JS_FreeValueRT(rt, c->attachment); JS_FreeValueRT(rt, c->ext_json); JS_FreeValueRT(rt, c->json);
    free(c);
}
static void cred_mark(void *rt, void *p, void *mf)
{
    cred_impl *c = p;
    wj_mark(rt, c->raw_id, mf); wj_mark(rt, c->response, mf); wj_mark(rt, c->id, mf);
    wj_mark(rt, c->attachment, mf); wj_mark(rt, c->ext_json, mf); wj_mark(rt, c->json, mf);
}
static void resp_free(void *p)
{
    resp_impl *r = p;
    JSRuntime *rt = web_rt();
    JS_FreeValueRT(rt, r->client_data); JS_FreeValueRT(rt, r->attestation_object); JS_FreeValueRT(rt, r->authenticator_data);
    JS_FreeValueRT(rt, r->signature); JS_FreeValueRT(rt, r->user_handle); JS_FreeValueRT(rt, r->public_key); JS_FreeValueRT(rt, r->transports);
    free(r);
}
static void resp_mark(void *rt, void *p, void *mf)
{
    resp_impl *r = p;
    wj_mark(rt, r->client_data, mf); wj_mark(rt, r->attestation_object, mf); wj_mark(rt, r->authenticator_data, mf);
    wj_mark(rt, r->signature, mf); wj_mark(rt, r->user_handle, mf); wj_mark(rt, r->public_key, mf); wj_mark(rt, r->transports, mf);
}

/* a binary member of the browser's credential: an ArrayBuffer, or null when it has none */
static JSValue host_bytes(JSContext *ctx, uint64_t h, int which)
{
    uint64_t buf = 0;
    if (wr_PublicKeyCredential_bytes(h, which, &buf) < 0 || !buf) { return JS_NULL; }
    JSValue ab = wj_arraybuffer_from_host(ctx, buf);
    wr_Object_release(buf);
    return ab;
}

#define HOST_STRING(call) ({ int32_t _len; WJ_FETCH_STRING(_len, call); _len >= 0 ? JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)_len) : JS_NULL; })

static JSValue make_credential(JSContext *ctx, uint64_t h)
{
    bool assertion = wr_PublicKeyCredential_isAssertion(h) != 0;
    resp_impl *r = calloc(1, sizeof *r);
    cred_impl *c = calloc(1, sizeof *c);
    if (!r || !c) { free(r); free(c); return JS_ThrowOutOfMemory(ctx); }
    r->assertion = assertion;
    r->client_data = host_bytes(ctx, h, wr_CredentialBytes_Client_Data_JSON);
    r->authenticator_data = host_bytes(ctx, h, wr_CredentialBytes_Authenticator_Data);
    r->attestation_object = assertion ? JS_NULL : host_bytes(ctx, h, wr_CredentialBytes_Attestation_Object);
    r->signature = assertion ? host_bytes(ctx, h, wr_CredentialBytes_Signature) : JS_NULL;
    r->user_handle = assertion ? host_bytes(ctx, h, wr_CredentialBytes_User_Handle) : JS_NULL;
    r->public_key = assertion ? JS_NULL : host_bytes(ctx, h, wr_CredentialBytes_Public_Key);
    r->transports = assertion ? JS_NULL : HOST_STRING(wr_PublicKeyCredential_transports(h, wj_scratch.data, wj_scratch.cap));
    r->alg = assertion ? 0 : wr_PublicKeyCredential_publicKeyAlgorithm(h);
    JSValue resp = wj_new_object(ctx, assertion ? WJ_IFACE_AuthenticatorAssertionResponse : WJ_IFACE_AuthenticatorAttestationResponse, NULL, NULL);
    if (JS_IsException(resp)) { resp_free(r); free(c); return resp; }
    web_set_impl(resp, r, resp_free, resp_mark);

    c->response = resp;
    c->raw_id = host_bytes(ctx, h, wr_CredentialBytes_Raw_Id);
    c->id = HOST_STRING(wr_PublicKeyCredential_id(h, wj_scratch.data, wj_scratch.cap));
    c->attachment = HOST_STRING(wr_PublicKeyCredential_authenticatorAttachment(h, wj_scratch.data, wj_scratch.cap));
    c->ext_json = HOST_STRING(wr_PublicKeyCredential_clientExtensionResults(h, wj_scratch.data, wj_scratch.cap));
    c->json = HOST_STRING(wr_PublicKeyCredential_toJSON(h, wj_scratch.data, wj_scratch.cap));
    JSValue obj = wj_new_object(ctx, WJ_IFACE_PublicKeyCredential, NULL, NULL);
    if (JS_IsException(obj)) { cred_free(c); return obj; }
    web_set_impl(obj, c, cred_free, cred_mark);
    return obj;
}

/* The browser's promise of a credential: a PublicKeyCredential (or null); a rejection is the signal's reason after an
 * abort, else the exception the code names. `data` is the signal (or undefined). */
static JSValue cred_settle(JSContext *ctx, int state, uint64_t host, int64_t value, JSValueConst data, bool *reject)
{
    if (state != 1) {
        *reject = true;
        if (web_signal_aborted(data)) { return web_signal_reason(ctx, data); }
        int32_t n;
        WJ_FETCH_STRING(n, wr_Promise_text(host, wj_scratch.data, wj_scratch.cap));
        return web_error_value(ctx, (int32_t)value, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
    }
    if (value == 0) { return JS_NULL; }
    JSValue c = make_credential(ctx, (uint64_t)value);
    wr_Object_release((uint64_t)value);
    return c;
}

static int mediation_of(const wj_str *m)
{
    if (!m->ptr) { return wr_CredentialMediation_Optional; }
    if (m->len == 6 && memcmp(m->ptr, "silent", 6) == 0) { return wr_CredentialMediation_Silent; }
    if (m->len == 8 && memcmp(m->ptr, "required", 8) == 0) { return wr_CredentialMediation_Required; }
    if (m->len == 11 && memcmp(m->ptr, "conditional", 11) == 0) { return wr_CredentialMediation_Conditional; }
    return wr_CredentialMediation_Optional;
}

static JSValue make_container(JSContext *ctx) { return wj_new_object(ctx, WJ_IFACE_CredentialsContainer, NULL, NULL); }

JSValue wjr_Navigator_get_credentials(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Navigator)) { return JS_EXCEPTION; }
    return web_singleton(ctx, WEB_SINGLE_CREDENTIALS, make_container);
}

static JSValue start(JSContext *ctx, bool create, const uint8_t *json, size_t len, int mediation, JSValueConst signal)
{
    web_usv_fix((char *)json, len);   /* DOMStrings with lone surrogates: the browser takes UTF-8 */
    uint64_t h = create ? wr_CredentialsContainer_create(json, (uint32_t)len, mediation, web_signal_handle(signal))
                        : wr_CredentialsContainer_get(json, (uint32_t)len, mediation, web_signal_handle(signal));
    return wj_promise_from_host(ctx, h, WJ_HOST_UNDEFINED, cred_settle, signal);
}

JSValue wjr_CredentialsContainer_create(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_CredentialsContainer)) { return web_promise_reject_pending(ctx); }
    JSValueConst arg = argc > 0 ? argv[0] : JS_UNDEFINED;
    wjd_CredentialCreationOptions o;
    if (!wjd_CredentialCreationOptions_from(ctx, arg, &o)) { return web_promise_reject_pending(ctx); }
    JSValue result;
    int kinds = (o.has_publicKey ? 1 : 0) + (o.has_password ? 1 : 0) + (o.has_federated ? 1 : 0);
    if (kinds != 1 || !o.has_publicKey) {
        result = web_promise_rejected(ctx, web_dom_exception(ctx, "NotSupportedError", kinds == 0 ? "Failed to execute 'create' on 'CredentialsContainer': no credential type was given." : (kinds > 1 ? "Failed to execute 'create' on 'CredentialsContainer': only one credential type may be created at a time." : "Failed to execute 'create' on 'CredentialsContainer': only public key credentials are supported.")));
        wjd_CredentialCreationOptions_free(ctx, &o);
        return result;
    }
    if (o.has_signal && web_signal_aborted(o.signal)) {
        result = web_promise_rejected(ctx, web_signal_reason(ctx, o.signal));
        wjd_CredentialCreationOptions_free(ctx, &o);
        return result;
    }
    jw w = {0};
    JSValue pk_raw;
    bool ok = member(ctx, arg, "publicKey", &pk_raw);
    if (ok) { ok = creation_json(ctx, pk_raw, &o.publicKey, &w); JS_FreeValue(ctx, pk_raw); }
    if (ok && w.b.failed) { JS_ThrowOutOfMemory(ctx); ok = false; }
    result = ok ? start(ctx, true, w.b.p, w.b.len, mediation_of(&o.mediation), o.has_signal ? o.signal : JS_UNDEFINED) : web_promise_reject_pending(ctx);
    web_buf_free(&w.b);
    wjd_CredentialCreationOptions_free(ctx, &o);
    return result;
}

JSValue wjr_CredentialsContainer_get(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_CredentialsContainer)) { return web_promise_reject_pending(ctx); }
    JSValueConst arg = argc > 0 ? argv[0] : JS_UNDEFINED;
    wjd_CredentialRequestOptions o;
    if (!wjd_CredentialRequestOptions_from(ctx, arg, &o)) { return web_promise_reject_pending(ctx); }
    JSValue result;
    if (o.has_signal && web_signal_aborted(o.signal)) {
        result = web_promise_rejected(ctx, web_signal_reason(ctx, o.signal));
        wjd_CredentialRequestOptions_free(ctx, &o);
        return result;
    }
    int kinds = (o.has_publicKey ? 1 : 0) + (o.password ? 1 : 0) + (o.has_federated ? 1 : 0);
    if (kinds == 0 || !o.has_publicKey || kinds > 1) {
        /* Credential Management §2.5.1: no interface, or public-key mixed with another type (its "types allowed in the
         * same get() request" is empty); password and federated credentials are not implemented */
        result = web_promise_rejected(ctx, web_dom_exception(ctx, "NotSupportedError", kinds == 0 ? "Failed to execute 'get' on 'CredentialsContainer': no credential type was requested." : "Failed to execute 'get' on 'CredentialsContainer': only public key credentials are supported, and alone."));
        wjd_CredentialRequestOptions_free(ctx, &o);
        return result;
    }
    if (o.has_uiMode && o.uiMode.len == 9 && memcmp(o.uiMode.ptr, "immediate", 9) == 0) {
        result = web_promise_rejected(ctx, web_type_error(ctx, "Failed to execute 'get' on 'CredentialsContainer': uiMode 'immediate' is not supported."));
        wjd_CredentialRequestOptions_free(ctx, &o);
        return result;
    }
    jw w = {0};
    JSValue pk_raw;
    bool ok = member(ctx, arg, "publicKey", &pk_raw);
    if (ok) { ok = request_json(ctx, pk_raw, &o.publicKey, &w); JS_FreeValue(ctx, pk_raw); }
    if (ok && w.b.failed) { JS_ThrowOutOfMemory(ctx); ok = false; }
    result = ok ? start(ctx, false, w.b.p, w.b.len, mediation_of(&o.mediation), o.has_signal ? o.signal : JS_UNDEFINED) : web_promise_reject_pending(ctx);
    web_buf_free(&w.b);
    wjd_CredentialRequestOptions_free(ctx, &o);
    return result;
}

JSValue wjr_CredentialsContainer_store(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_CredentialsContainer)) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { wj_throw_arity(ctx, "CredentialsContainer.store", 1, argc); return web_promise_reject_pending(ctx); }
    if (!wj_unwrap(argv[0], WJ_IFACE_Credential)) {
        return web_promise_rejected(ctx, web_type_error(ctx, "Failed to execute 'store' on 'CredentialsContainer': parameter 1 is not of type 'Credential'."));
    }
    /* PublicKeyCredential's [[Store]]: NotSupportedError (WebAuthn §5.1.5) */
    return web_promise_rejected(ctx, web_dom_exception(ctx, "NotSupportedError", "Failed to execute 'store' on 'CredentialsContainer': public key credentials cannot be stored."));
}

JSValue wjr_CredentialsContainer_preventSilentAccess(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!wj_this(ctx, this_val, WJ_IFACE_CredentialsContainer)) { return web_promise_reject_pending(ctx); }
    return wj_promise_from_host(ctx, wr_CredentialsContainer_preventSilentAccess(), WJ_HOST_UNDEFINED, NULL, JS_UNDEFINED);
}

/* ---- Credential, PublicKeyCredential ---- */

static cred_impl *cred_this(JSContext *ctx, JSValueConst this_val) { return web_this_impl(ctx, this_val, WJ_IFACE_PublicKeyCredential); }

JSValue wjr_Credential_get_id(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Credential)) { return JS_EXCEPTION; }
    cred_impl *c = cred_this(ctx, this_val);
    return c ? JS_DupValue(ctx, c->id) : JS_EXCEPTION;
}

JSValue wjr_Credential_get_type(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Credential)) { return JS_EXCEPTION; }
    return wj_unwrap(this_val, WJ_IFACE_PublicKeyCredential) ? JS_NewString(ctx, "public-key") : JS_NewString(ctx, "");
}

/* Credential's default: no conditional mediation */
JSValue wjr_Credential_static_isConditionalMediationAvailable(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    return web_promise_resolved(ctx, JS_FALSE);
}

JSValue wjr_PublicKeyCredential_get_rawId(JSContext *ctx, JSValueConst this_val) { cred_impl *c = cred_this(ctx, this_val); return c ? JS_DupValue(ctx, c->raw_id) : JS_EXCEPTION; }
JSValue wjr_PublicKeyCredential_get_response(JSContext *ctx, JSValueConst this_val) { cred_impl *c = cred_this(ctx, this_val); return c ? JS_DupValue(ctx, c->response) : JS_EXCEPTION; }
JSValue wjr_PublicKeyCredential_get_authenticatorAttachment(JSContext *ctx, JSValueConst this_val) { cred_impl *c = cred_this(ctx, this_val); return c ? JS_DupValue(ctx, c->attachment) : JS_EXCEPTION; }

static JSValue parse_json_value(JSContext *ctx, JSValueConst text)
{
    size_t n;
    const char *s = JS_ToCStringLen(ctx, &n, text);
    if (!s) { return JS_EXCEPTION; }
    JSValue v = JS_ParseJSON(ctx, s, n, "<credential>");
    JS_FreeCString(ctx, s);
    return v;
}

/* obj[key] (a base64url string) becomes an ArrayBuffer, when present */
static bool ab_member(JSContext *ctx, JSValueConst obj, const char *key)
{
    if (!JS_IsObject(obj)) { return true; }
    JSValue v = JS_GetPropertyStr(ctx, obj, key);
    if (JS_IsException(v)) { return false; }
    bool ok = true;
    if (JS_IsString(v)) {
        size_t n;
        const char *s = JS_ToCStringLen(ctx, &n, v);
        JSValue ab = s ? b64_arraybuffer(ctx, s, n, key) : JS_EXCEPTION;
        if (s) { JS_FreeCString(ctx, s); }
        ok = !JS_IsException(ab) && JS_SetPropertyStr(ctx, obj, key, ab) >= 0;
    }
    JS_FreeValue(ctx, v);
    return ok;
}

static JSValue sub(JSContext *ctx, JSValueConst obj, const char *key) { return JS_IsObject(obj) ? JS_GetPropertyStr(ctx, obj, key) : JS_UNDEFINED; }

/* AuthenticationExtensionsClientOutputs from its JSON form: the binary members as ArrayBuffers */
static JSValue extension_outputs(JSContext *ctx, JSValueConst json)
{
    JSValue o = parse_json_value(ctx, json);
    if (JS_IsException(o)) { return o; }
    JSValue prf = sub(ctx, o, "prf"), results = sub(ctx, prf, "results"), lb = sub(ctx, o, "largeBlob");
    bool ok = ab_member(ctx, results, "first") && ab_member(ctx, results, "second") && ab_member(ctx, lb, "blob") && ab_member(ctx, o, "getCredBlob");
    JS_FreeValue(ctx, prf); JS_FreeValue(ctx, results); JS_FreeValue(ctx, lb);
    if (!ok) { JS_FreeValue(ctx, o); return JS_EXCEPTION; }
    return o;
}

JSValue wjr_PublicKeyCredential_getClientExtensionResults(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    cred_impl *c = cred_this(ctx, this_val);
    return c ? extension_outputs(ctx, c->ext_json) : JS_EXCEPTION;
}

JSValue wjr_PublicKeyCredential_toJSON(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    cred_impl *c = cred_this(ctx, this_val);
    return c ? parse_json_value(ctx, c->json) : JS_EXCEPTION;
}

JSValue wjr_PublicKeyCredential_static_isConditionalMediationAvailable(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    return wj_promise_from_host(ctx, wr_PublicKeyCredential_isConditionalMediationAvailable(), WJ_HOST_BOOL, NULL, JS_UNDEFINED);
}

JSValue wjr_PublicKeyCredential_static_isUserVerifyingPlatformAuthenticatorAvailable(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    return wj_promise_from_host(ctx, wr_PublicKeyCredential_isUserVerifyingPlatformAuthenticatorAvailable(), WJ_HOST_BOOL, NULL, JS_UNDEFINED);
}

static JSValue capabilities_settle(JSContext *ctx, int state, uint64_t host, int64_t value, JSValueConst data, bool *reject)
{
    WJ_UNUSED(data);
    JSValue text = wj_host_promise_text(ctx, host);
    if (state != 1) {
        *reject = true;
        size_t n;
        const char *s = JS_ToCStringLen(ctx, &n, text);
        JSValue e = web_error_value(ctx, (int32_t)value, s ? s : "", s ? n : 0);
        if (s) { JS_FreeCString(ctx, s); }
        JS_FreeValue(ctx, text);
        return e;
    }
    JSValue v = parse_json_value(ctx, text);
    JS_FreeValue(ctx, text);
    return v;
}

JSValue wjr_PublicKeyCredential_static_getClientCapabilities(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    return wj_promise_from_host(ctx, wr_PublicKeyCredential_getClientCapabilities(), WJ_HOST_UNDEFINED, capabilities_settle, JS_UNDEFINED);
}

/* ---- parseCreationOptionsFromJSON / parseRequestOptionsFromJSON ---- */

static bool set(JSContext *ctx, JSValueConst obj, const char *key, JSValue v)
{
    if (JS_IsException(v)) { return false; }
    return JS_DefinePropertyValueStr(ctx, obj, key, v, JS_PROP_C_W_E) >= 0;
}
static JSValue str_value(JSContext *ctx, const wj_str *s) { return JS_NewStringLen(ctx, s->ptr ? s->ptr : "", s->ptr ? s->len : 0); }
static JSValue b64_member(JSContext *ctx, const wj_str *s, const char *what) { return b64_arraybuffer(ctx, s->ptr ? s->ptr : "", s->ptr ? s->len : 0, what); }

typedef struct arr_ctx { JSValue arr; uint32_t n; } arr_ctx;

static bool string_to_array(JSContext *ctx, JSValueConst item, void *opaque)
{
    arr_ctx *a = opaque;
    wj_str s;
    if (!wj_to_str(ctx, item, &s, 0, NULL)) { return false; }
    wj_array_set(ctx, a->arr, a->n++, str_value(ctx, &s));
    wj_str_free(ctx, &s);
    return true;
}

static JSValue strings_array(JSContext *ctx, JSValueConst seq, const char *what)
{
    arr_ctx a = { JS_NewArray(ctx), 0 };
    if (JS_IsUndefined(seq)) { return a.arr; }
    if (!sequence(ctx, seq, what, string_to_array, &a)) { JS_FreeValue(ctx, a.arr); return JS_EXCEPTION; }
    return a.arr;
}

static bool param_to_array(JSContext *ctx, JSValueConst item, void *opaque)
{
    arr_ctx *a = opaque;
    if (!web_dict_check(ctx, item, "PublicKeyCredentialParameters")) { return false; }
    JSValue av, tv;
    if (!member(ctx, item, "alg", &av)) { return false; }
    if (JS_IsUndefined(av)) { return required_missing(ctx, "alg", "PublicKeyCredentialParameters"); }
    int32_t alg;
    bool ok = wj_to_int32(ctx, av, &alg, 32, 0);
    JS_FreeValue(ctx, av);
    if (!ok || !member(ctx, item, "type", &tv)) { return false; }
    if (JS_IsUndefined(tv)) { return required_missing(ctx, "type", "PublicKeyCredentialParameters"); }
    wj_str t;
    ok = wj_to_str(ctx, tv, &t, 0, NULL);
    JS_FreeValue(ctx, tv);
    if (!ok) { return false; }
    JSValue o = JS_NewObject(ctx);
    ok = set(ctx, o, "type", str_value(ctx, &t)) && set(ctx, o, "alg", JS_NewInt32(ctx, alg));
    wj_str_free(ctx, &t);
    wj_array_set(ctx, a->arr, a->n++, o);
    return ok;
}

/* PublicKeyCredentialDescriptorJSON -> PublicKeyCredentialDescriptor */
static bool descriptor_to_array(JSContext *ctx, JSValueConst item, void *opaque)
{
    arr_ctx *a = opaque;
    if (!web_dict_check(ctx, item, "PublicKeyCredentialDescriptorJSON")) { return false; }
    JSValue idv, trv, tv;
    if (!member(ctx, item, "id", &idv)) { return false; }
    if (JS_IsUndefined(idv)) { return required_missing(ctx, "id", "PublicKeyCredentialDescriptorJSON"); }
    wj_str id;
    bool ok = wj_to_str(ctx, idv, &id, 0, NULL);
    JS_FreeValue(ctx, idv);
    if (!ok) { return false; }
    JSValue o = JS_NewObject(ctx);
    wj_array_set(ctx, a->arr, a->n++, o);
    ok = set(ctx, o, "id", b64_member(ctx, &id, "id"));
    wj_str_free(ctx, &id);
    if (!ok || !member(ctx, item, "transports", &trv)) { return false; }
    if (!JS_IsUndefined(trv)) { ok = set(ctx, o, "transports", strings_array(ctx, trv, "transports")); }
    JS_FreeValue(ctx, trv);
    if (!ok || !member(ctx, item, "type", &tv)) { return false; }
    if (JS_IsUndefined(tv)) { return required_missing(ctx, "type", "PublicKeyCredentialDescriptorJSON"); }
    wj_str t;
    ok = wj_to_str(ctx, tv, &t, 0, NULL);
    JS_FreeValue(ctx, tv);
    if (!ok) { return false; }
    ok = set(ctx, o, "type", str_value(ctx, &t));
    wj_str_free(ctx, &t);
    return ok;
}

static JSValue convert_array(JSContext *ctx, JSValueConst seq, const char *what, bool (*fn)(JSContext *, JSValueConst, void *))
{
    arr_ctx a = { JS_NewArray(ctx), 0 };
    if (JS_IsUndefined(seq)) { return a.arr; }
    if (!sequence(ctx, seq, what, fn, &a)) { JS_FreeValue(ctx, a.arr); return JS_EXCEPTION; }
    return a.arr;
}

static JSValue prf_values_object(JSContext *ctx, const wjd_AuthenticationExtensionsPRFValuesJSON *v)
{
    JSValue o = JS_NewObject(ctx);
    bool ok = set(ctx, o, "first", b64_member(ctx, &v->first, "prf.first"));
    if (ok && v->has_second) { ok = set(ctx, o, "second", b64_member(ctx, &v->second, "prf.second")); }
    if (!ok) { JS_FreeValue(ctx, o); return JS_EXCEPTION; }
    return o;
}

static bool prf_json_entry(JSContext *ctx, JSValueConst key, JSValueConst value, void *opaque)
{
    JSValue out = *(JSValue *)opaque;
    wjd_AuthenticationExtensionsPRFValuesJSON v;
    if (!wjd_AuthenticationExtensionsPRFValuesJSON_from(ctx, value, &v)) { return false; }
    JSValue o = prf_values_object(ctx, &v);
    wjd_AuthenticationExtensionsPRFValuesJSON_free(ctx, &v);
    if (JS_IsException(o)) { return false; }
    JSAtom a = JS_ValueToAtom(ctx, key);
    bool ok = JS_DefinePropertyValue(ctx, out, a, o, JS_PROP_C_W_E) >= 0;
    JS_FreeAtom(ctx, a);
    return ok;
}

/* AuthenticationExtensionsClientInputsJSON -> AuthenticationExtensionsClientInputs */
static JSValue extensions_from_json(JSContext *ctx, JSValueConst raw)
{
    wjd_AuthenticationExtensionsClientInputsJSON e;
    if (!wjd_AuthenticationExtensionsClientInputsJSON_from(ctx, raw, &e)) { return JS_EXCEPTION; }
    JSValue o = JS_NewObject(ctx);
    bool ok = true;
    if (e.has_appid) { ok = ok && set(ctx, o, "appid", str_value(ctx, &e.appid)); }
    if (e.has_appidExclude) { ok = ok && set(ctx, o, "appidExclude", str_value(ctx, &e.appidExclude)); }
    if (e.has_credProps) { ok = ok && set(ctx, o, "credProps", JS_NewBool(ctx, e.credProps)); }
    if (ok && e.has_largeBlob) {
        JSValue lb = JS_NewObject(ctx);
        ok = set(ctx, o, "largeBlob", lb);
        if (ok && e.largeBlob.has_support) { ok = set(ctx, lb, "support", str_value(ctx, &e.largeBlob.support)); }
        if (ok && e.largeBlob.has_read) { ok = set(ctx, lb, "read", JS_NewBool(ctx, e.largeBlob.read)); }
        if (ok && e.largeBlob.has_write) { ok = set(ctx, lb, "write", b64_member(ctx, &e.largeBlob.write, "largeBlob.write")); }
    }
    if (ok && e.has_prf) {
        JSValue prf = JS_NewObject(ctx);
        ok = set(ctx, o, "prf", prf);
        if (ok && e.prf.has_eval) { ok = set(ctx, prf, "eval", prf_values_object(ctx, &e.prf.eval)); }
        if (ok && e.prf.has_evalByCredential) {
            JSValue by = JS_NewObject(ctx);
            ok = set(ctx, prf, "evalByCredential", by) && web_for_record(ctx, e.prf.evalByCredential, prf_json_entry, &by);
        }
    }
    if (ok && e.has_remoteClientDataJSON) { ok = set(ctx, o, "remoteClientDataJSON", str_value(ctx, &e.remoteClientDataJSON)); }
    wjd_AuthenticationExtensionsClientInputsJSON_free(ctx, &e);
    /* CTAP2 extensions: copied, credBlob decoded */
    static const char *const plain[] = { "credentialProtectionPolicy", "enforceCredentialProtectionPolicy", "getCredBlob", "hmacCreateSecret", "minPinLength" };
    for (size_t i = 0; ok && JS_IsObject(raw) && i < WEB_COUNT(plain); i++) {
        JSValue v = JS_GetPropertyStr(ctx, raw, plain[i]);
        if (JS_IsException(v)) { ok = false; break; }
        if (JS_IsUndefined(v)) { JS_FreeValue(ctx, v); continue; }
        ok = set(ctx, o, plain[i], v);
    }
    if (ok && JS_IsObject(raw)) {
        JSValue v = JS_GetPropertyStr(ctx, raw, "credBlob");
        if (JS_IsException(v)) { ok = false; }
        else if (!JS_IsUndefined(v)) {
            wj_str s;
            ok = wj_to_str(ctx, v, &s, 0, NULL) && set(ctx, o, "credBlob", b64_member(ctx, &s, "credBlob"));
            if (s.ptr) { wj_str_free(ctx, &s); }
        }
        JS_FreeValue(ctx, v);
    }
    if (!ok) { JS_FreeValue(ctx, o); return JS_EXCEPTION; }
    return o;
}

JSValue wjr_PublicKeyCredential_static_parseCreationOptionsFromJSON(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "PublicKeyCredential.parseCreationOptionsFromJSON", 1, argc); }
    wjd_PublicKeyCredentialCreationOptionsJSON d;
    if (!wjd_PublicKeyCredentialCreationOptionsJSON_from(ctx, argv[0], &d)) { return JS_EXCEPTION; }
    JSValue o = JS_NewObject(ctx);
    JSValue rp = JS_NewObject(ctx), user = JS_NewObject(ctx);
    bool ok = set(ctx, o, "rp", rp) && set(ctx, rp, "name", str_value(ctx, &d.rp.base.name));
    if (ok && d.rp.has_id) { ok = set(ctx, rp, "id", str_value(ctx, &d.rp.id)); }
    ok = ok && set(ctx, o, "user", user) && set(ctx, user, "id", b64_member(ctx, &d.user.id, "user.id"))
        && set(ctx, user, "name", str_value(ctx, &d.user.name)) && set(ctx, user, "displayName", str_value(ctx, &d.user.displayName));
    if (!ok) { JS_FreeValue(ctx, user); }
    ok = ok && set(ctx, o, "challenge", b64_member(ctx, &d.challenge, "challenge"));
    ok = ok && set(ctx, o, "pubKeyCredParams", convert_array(ctx, d.pubKeyCredParams, "pubKeyCredParams", param_to_array));
    if (ok && d.has_timeout) { ok = set(ctx, o, "timeout", JS_NewUint32(ctx, d.timeout)); }
    ok = ok && set(ctx, o, "excludeCredentials", convert_array(ctx, d.excludeCredentials, "excludeCredentials", descriptor_to_array));
    if (ok && d.has_authenticatorSelection) {
        const wjd_AuthenticatorSelectionCriteria *a = &d.authenticatorSelection;
        JSValue s = JS_NewObject(ctx);
        ok = set(ctx, o, "authenticatorSelection", s);
        if (ok && a->has_authenticatorAttachment) { ok = set(ctx, s, "authenticatorAttachment", str_value(ctx, &a->authenticatorAttachment)); }
        if (ok && a->has_residentKey) { ok = set(ctx, s, "residentKey", str_value(ctx, &a->residentKey)); }
        ok = ok && set(ctx, s, "requireResidentKey", JS_NewBool(ctx, a->requireResidentKey)) && set(ctx, s, "userVerification", str_value(ctx, &a->userVerification));
    }
    ok = ok && set(ctx, o, "hints", strings_array(ctx, d.hints, "hints"));
    ok = ok && set(ctx, o, "attestation", str_value(ctx, &d.attestation));
    ok = ok && set(ctx, o, "attestationFormats", strings_array(ctx, d.attestationFormats, "attestationFormats"));
    if (ok && d.has_extensions) {
        JSValue raw;
        ok = member(ctx, argv[0], "extensions", &raw);
        if (ok) { ok = set(ctx, o, "extensions", extensions_from_json(ctx, raw)); JS_FreeValue(ctx, raw); }
    }
    wjd_PublicKeyCredentialCreationOptionsJSON_free(ctx, &d);
    if (!ok) { JS_FreeValue(ctx, o); return JS_EXCEPTION; }
    return o;
}

JSValue wjr_PublicKeyCredential_static_parseRequestOptionsFromJSON(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc < 1) { return wj_throw_arity(ctx, "PublicKeyCredential.parseRequestOptionsFromJSON", 1, argc); }
    wjd_PublicKeyCredentialRequestOptionsJSON d;
    if (!wjd_PublicKeyCredentialRequestOptionsJSON_from(ctx, argv[0], &d)) { return JS_EXCEPTION; }
    JSValue o = JS_NewObject(ctx);
    bool ok = set(ctx, o, "challenge", b64_member(ctx, &d.challenge, "challenge"));
    if (ok && d.has_timeout) { ok = set(ctx, o, "timeout", JS_NewUint32(ctx, d.timeout)); }
    if (ok && d.has_rpId) { ok = set(ctx, o, "rpId", str_value(ctx, &d.rpId)); }
    ok = ok && set(ctx, o, "allowCredentials", convert_array(ctx, d.allowCredentials, "allowCredentials", descriptor_to_array));
    ok = ok && set(ctx, o, "userVerification", str_value(ctx, &d.userVerification));
    ok = ok && set(ctx, o, "hints", strings_array(ctx, d.hints, "hints"));
    if (ok && d.has_extensions) {
        JSValue raw;
        ok = member(ctx, argv[0], "extensions", &raw);
        if (ok) { ok = set(ctx, o, "extensions", extensions_from_json(ctx, raw)); JS_FreeValue(ctx, raw); }
    }
    wjd_PublicKeyCredentialRequestOptionsJSON_free(ctx, &d);
    if (!ok) { JS_FreeValue(ctx, o); return JS_EXCEPTION; }
    return o;
}

/* ---- signal methods (§5.1.10): checked, then nothing to tell (no authenticator of this platform takes signals) ---- */

static JSValue signal_done(JSContext *ctx, const wj_str *rp_id)
{
    if (wr_PublicKeyCredential_checkRpId((const uint8_t *)(rp_id->ptr ? rp_id->ptr : ""), (uint32_t)(rp_id->ptr ? rp_id->len : 0)) < 0) {
        return web_promise_rejected(ctx, web_dom_exception(ctx, "SecurityError", "The relying party ID is not a registrable domain suffix of, nor equal to, the current domain."));
    }
    return web_promise_resolved(ctx, JS_UNDEFINED);
}

static JSValue b64_type_error(JSContext *ctx, const char *what)
{
    char msg[128];
    snprintf(msg, sizeof msg, "%s is not valid base64url", what);
    return web_promise_rejected(ctx, web_type_error(ctx, msg));
}

JSValue wjr_PublicKeyCredential_static_signalUnknownCredential(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    wjd_UnknownCredentialOptions d;
    if (!wjd_UnknownCredentialOptions_from(ctx, argc > 0 ? argv[0] : JS_UNDEFINED, &d)) { return web_promise_reject_pending(ctx); }
    JSValue r = b64_valid(d.credentialId.ptr, d.credentialId.len) ? signal_done(ctx, &d.rpId) : b64_type_error(ctx, "credentialId");
    wjd_UnknownCredentialOptions_free(ctx, &d);
    return r;
}

static bool b64_item(JSContext *ctx, JSValueConst item, void *opaque)
{
    wj_str s;
    if (!wj_to_str(ctx, item, &s, 0, NULL)) { return false; }
    if (!b64_valid(s.ptr, s.len)) { *(bool *)opaque = false; }
    wj_str_free(ctx, &s);
    return true;
}

JSValue wjr_PublicKeyCredential_static_signalAllAcceptedCredentials(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    wjd_AllAcceptedCredentialsOptions d;
    if (!wjd_AllAcceptedCredentialsOptions_from(ctx, argc > 0 ? argv[0] : JS_UNDEFINED, &d)) { return web_promise_reject_pending(ctx); }
    bool ids_ok = true;
    JSValue r;
    if (!sequence(ctx, d.allAcceptedCredentialIds, "allAcceptedCredentialIds", b64_item, &ids_ok)) { r = web_promise_reject_pending(ctx); }
    else if (!b64_valid(d.userId.ptr, d.userId.len)) { r = b64_type_error(ctx, "userId"); }
    else if (!ids_ok) { r = b64_type_error(ctx, "allAcceptedCredentialIds"); }
    else { r = signal_done(ctx, &d.rpId); }
    wjd_AllAcceptedCredentialsOptions_free(ctx, &d);
    return r;
}

JSValue wjr_PublicKeyCredential_static_signalCurrentUserDetails(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    wjd_CurrentUserDetailsOptions d;
    if (!wjd_CurrentUserDetailsOptions_from(ctx, argc > 0 ? argv[0] : JS_UNDEFINED, &d)) { return web_promise_reject_pending(ctx); }
    JSValue r = b64_valid(d.userId.ptr, d.userId.len) ? signal_done(ctx, &d.rpId) : b64_type_error(ctx, "userId");
    wjd_CurrentUserDetailsOptions_free(ctx, &d);
    return r;
}

/* ---- responses ---- */

static resp_impl *resp_this(JSContext *ctx, JSValueConst this_val, int iface) { return web_this_impl(ctx, this_val, iface); }

static JSValue ab_copy(JSContext *ctx, JSValueConst ab)
{
    if (!JS_IsObject(ab)) { return JS_NULL; }
    size_t n;
    uint8_t *p = JS_GetArrayBuffer(ctx, &n, ab);
    if (!p && n) { return JS_EXCEPTION; }
    return JS_NewArrayBufferCopy(ctx, p, n);
}

JSValue wjr_AuthenticatorResponse_get_clientDataJSON(JSContext *ctx, JSValueConst this_val) { resp_impl *r = resp_this(ctx, this_val, WJ_IFACE_AuthenticatorResponse); return r ? JS_DupValue(ctx, r->client_data) : JS_EXCEPTION; }

JSValue wjr_AuthenticatorAttestationResponse_get_attestationObject(JSContext *ctx, JSValueConst this_val) { resp_impl *r = resp_this(ctx, this_val, WJ_IFACE_AuthenticatorAttestationResponse); return r ? JS_DupValue(ctx, r->attestation_object) : JS_EXCEPTION; }

JSValue wjr_AuthenticatorAttestationResponse_getTransports(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    resp_impl *r = resp_this(ctx, this_val, WJ_IFACE_AuthenticatorAttestationResponse);
    if (!r) { return JS_EXCEPTION; }
    JSValue arr = JS_NewArray(ctx);
    size_t n;
    const char *s = JS_IsString(r->transports) ? JS_ToCStringLen(ctx, &n, r->transports) : NULL;
    uint32_t k = 0;
    for (const char *t = s; t && *t;) {
        const char *e = strchr(t, ',');
        size_t l = e ? (size_t)(e - t) : strlen(t);
        if (l) { wj_array_set(ctx, arr, k++, JS_NewStringLen(ctx, t, l)); }
        t += l + (e ? 1 : 0);
    }
    if (s) { JS_FreeCString(ctx, s); }
    return arr;
}

JSValue wjr_AuthenticatorAttestationResponse_getAuthenticatorData(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    resp_impl *r = resp_this(ctx, this_val, WJ_IFACE_AuthenticatorAttestationResponse);
    return r ? ab_copy(ctx, r->authenticator_data) : JS_EXCEPTION;
}

JSValue wjr_AuthenticatorAttestationResponse_getPublicKey(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    resp_impl *r = resp_this(ctx, this_val, WJ_IFACE_AuthenticatorAttestationResponse);
    return r ? ab_copy(ctx, r->public_key) : JS_EXCEPTION;
}

JSValue wjr_AuthenticatorAttestationResponse_getPublicKeyAlgorithm(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    resp_impl *r = resp_this(ctx, this_val, WJ_IFACE_AuthenticatorAttestationResponse);
    return r ? JS_NewInt32(ctx, r->alg) : JS_EXCEPTION;
}

JSValue wjr_AuthenticatorAssertionResponse_get_authenticatorData(JSContext *ctx, JSValueConst this_val) { resp_impl *r = resp_this(ctx, this_val, WJ_IFACE_AuthenticatorAssertionResponse); return r ? JS_DupValue(ctx, r->authenticator_data) : JS_EXCEPTION; }
JSValue wjr_AuthenticatorAssertionResponse_get_signature(JSContext *ctx, JSValueConst this_val) { resp_impl *r = resp_this(ctx, this_val, WJ_IFACE_AuthenticatorAssertionResponse); return r ? JS_DupValue(ctx, r->signature) : JS_EXCEPTION; }
JSValue wjr_AuthenticatorAssertionResponse_get_userHandle(JSContext *ctx, JSValueConst this_val) { resp_impl *r = resp_this(ctx, this_val, WJ_IFACE_AuthenticatorAssertionResponse); return r ? JS_DupValue(ctx, r->user_handle) : JS_EXCEPTION; }

/* ---- realm start: with security.webauthn.enabled off, Web Authentication is absent (feature detection says so) ---- */

int web_credentials_start(JSContext *ctx, int kind)
{
    WJ_UNUSED(kind);
    if (!web_is_window() || wr_PublicKeyCredential_enabled()) { return 0; }
    static const char *const names[] = { "PublicKeyCredential", "AuthenticatorResponse", "AuthenticatorAttestationResponse", "AuthenticatorAssertionResponse" };
    for (size_t i = 0; i < WEB_COUNT(names); i++) {
        JSAtom a = JS_NewAtom(ctx, names[i]);
        JS_DeleteProperty(ctx, wj_the_realm.global, a, 0);
        JS_FreeAtom(ctx, a);
    }
    return 0;
}
