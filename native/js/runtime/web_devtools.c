/* web_devtools.c: the description of console arguments for the developer tools, native (in place of the console part of
 * the old prelude/compat.js). While the panel is open (the shell sets `on` on the state object kept under
 * Symbol.for("wren.devtools")), each console call first sends a description of its arguments, as JSON (strings, numbers,
 * objects with their properties, Maps, Sets, DOM nodes, errors with their stacks, tables), through console.debug with a
 * prefix the shell recognizes; the console call then goes on as it always did. `eval` runs a console expression and
 * `complete` lists the names of an object; `store` / `storeNode` keep a value under a global name and `copy` sends it
 * as JSON text. The shape of the state object and its methods is the contract src/page/devtools_api.odin relies on.
 *
 * The recursive value walk and the JSON it builds are native (web_buf); only string escaping leans on the engine's
 * JSON.stringify and a function's source on Function.prototype.toString, exactly as the JavaScript did. */
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "web.h"

#define DT_MAXKEYS 100
#define DT_MAXDEPTH 4

/* the budget of nested nodes a single description may expand (b.n in the old code) */
typedef struct { JSContext *ctx; JSValue state; web_buf out; int budget; JSValue seen; int depth; } dt_ser;

static bool set_has_value(JSContext *ctx, JSValueConst set, JSValueConst v);
static void set_add_value(JSContext *ctx, JSValueConst set, JSValueConst v);
static JSValue dt_then_ok(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data);
static JSValue dt_then_err(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data);

static JSValue global_prop(JSContext *ctx, const char *name) { return JS_GetPropertyStr(ctx, wj_the_realm.global, name); }

/* console[Symbol.for("wren.devtools")] atom */
static JSAtom dt_symbol_atom(JSContext *ctx)
{
    JSValue sym = global_prop(ctx, "Symbol");
    JSValue forf = JS_GetPropertyStr(ctx, sym, "for");
    JSValueConst key = JS_NewString(ctx, "wren.devtools");
    JSValue s = JS_Call(ctx, forf, sym, 1, &key);
    JS_FreeValue(ctx, (JSValue)key); JS_FreeValue(ctx, forf); JS_FreeValue(ctx, sym);
    JSAtom a = JS_ValueToAtom(ctx, s);
    JS_FreeValue(ctx, s);
    return a;
}

/* JSON.stringify(s), with s truncated to 1000 code units + an ellipsis as the old str() did; appended to `out` */
static void dt_str(JSContext *ctx, web_buf *out, JSValueConst sv)
{
    JSValue s = JS_ToString(ctx, sv);
    /* s.length > 1000 ? s.slice(0,1000)+"\u2026" : s */
    JSValue lenv = JS_GetPropertyStr(ctx, s, "length");
    uint32_t len = 0; JS_ToUint32(ctx, &len, lenv); JS_FreeValue(ctx, lenv);
    JSValue use;
    if (len > 1000) {
        JSValue slicefn = JS_GetPropertyStr(ctx, s, "slice");
        JSValueConst sa[2] = { JS_NewInt32(ctx, 0), JS_NewInt32(ctx, 1000) };
        JSValue cut = JS_Call(ctx, slicefn, s, 2, sa);
        JS_FreeValue(ctx, slicefn);
        JSValue plus = JS_GetPropertyStr(ctx, cut, "concat");
        JSValueConst ell = JS_NewString(ctx, "\u2026");
        use = JS_Call(ctx, plus, cut, 1, &ell);
        JS_FreeValue(ctx, (JSValue)ell); JS_FreeValue(ctx, plus); JS_FreeValue(ctx, cut);
    } else {
        use = JS_DupValue(ctx, s);
    }
    JS_FreeValue(ctx, s);
    JSValue j = JS_JSONStringify(ctx, use, JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeValue(ctx, use);
    const char *c = JS_ToCString(ctx, j);
    web_buf_puts(out, c ? c : "\"\"");
    if (c) { JS_FreeCString(ctx, c); }
    JS_FreeValue(ctx, j);
}
/* JSON.stringify of a C string */
static void dt_str_c(JSContext *ctx, web_buf *out, const char *s)
{
    JSValue v = JS_NewString(ctx, s ? s : "");
    dt_str(ctx, out, v);
    JS_FreeValue(ctx, v);
}

/* classOf(v): v.constructor.name, else Object.prototype.toString.call(v).slice(8,-1) */
static void dt_class_of(JSContext *ctx, JSValueConst v, char *out, size_t cap)
{
    out[0] = 0;
    JSValue k = JS_GetPropertyStr(ctx, v, "constructor");
    if (JS_IsFunction(ctx, k)) {
        JSValue nm = JS_GetPropertyStr(ctx, k, "name");
        const char *s = JS_ToCString(ctx, nm);
        if (s && s[0]) { snprintf(out, cap, "%s", s); }
        if (s) { JS_FreeCString(ctx, s); }
        JS_FreeValue(ctx, nm);
    }
    JS_FreeValue(ctx, k);
    if (out[0]) { return; }
    /* Object.prototype.toString.call(v).slice(8,-1) */
    JSValue objc = global_prop(ctx, "Object");
    JSValue proto = JS_GetPropertyStr(ctx, objc, "prototype");
    JSValue ts = JS_GetPropertyStr(ctx, proto, "toString");
    JSValue r = JS_Call(ctx, ts, v, 0, NULL);
    const char *s = JS_ToCString(ctx, r);
    if (s) { size_t n = strlen(s); if (n > 9) { snprintf(out, cap, "%.*s", (int)(n - 9), s + 8); } else { snprintf(out, cap, "Object"); } JS_FreeCString(ctx, s); }
    else { snprintf(out, cap, "Object"); }
    JS_FreeValue(ctx, r); JS_FreeValue(ctx, ts); JS_FreeValue(ctx, proto); JS_FreeValue(ctx, objc);
}

/* fdesc(f): the display form of a function. (cls ? "class " : "") + (name||"(anonymous)") + (cls?"":"(args)") */
static void dt_fdesc(JSContext *ctx, JSValueConst f, web_buf *out)
{
    JSValue fp = global_prop(ctx, "Function");
    JSValue fproto = JS_GetPropertyStr(ctx, fp, "prototype");
    JSValue tsfn = JS_GetPropertyStr(ctx, fproto, "toString");
    JSValue src = JS_Call(ctx, tsfn, f, 0, NULL);
    JS_FreeValue(ctx, tsfn); JS_FreeValue(ctx, fproto); JS_FreeValue(ctx, fp);
    const char *s = JS_IsException(src) ? NULL : JS_ToCString(ctx, src);
    if (JS_IsException(src)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
    char buf[256]; buf[0] = 0;
    /* class? /^\s*class\b/ */
    const char *p = s ? s : "";
    const char *q = p; while (*q == ' ' || *q == '\t' || *q == '\n' || *q == '\r') { q++; }
    bool is_class = strncmp(q, "class", 5) == 0 && (q[5] == 0 || q[5] == ' ' || q[5] == '{' || q[5] == '\t' || q[5] == '\n' || q[5] == '\r' || q[5] == '/');
    /* args: /^[^{]*?\(([^)]*)\)/ — the first (...) before any { */
    if (!is_class && s) {
        const char *lp = NULL, *rp = NULL;
        for (const char *c = s; *c && *c != '{'; c++) { if (*c == '(') { lp = c + 1; for (const char *d = lp; *d; d++) { if (*d == ')') { rp = d; break; } } break; } }
        if (lp && rp && rp >= lp) {
            size_t n = (size_t)(rp - lp);
            if (n > sizeof buf - 1) { n = sizeof buf - 1; }
            /* replace(/\s+/g," ").trim() */
            size_t oi = 0; bool sp = false, started = false;
            for (size_t i = 0; i < n && oi < sizeof buf - 1; i++) {
                char c = lp[i];
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r') { if (started) { sp = true; } }
                else { if (sp) { buf[oi++] = ' '; } sp = false; started = true; buf[oi++] = c; }
            }
            buf[oi] = 0;
        }
    }
    JSValue namev = JS_GetPropertyStr(ctx, f, "name");
    const char *name = JS_ToCString(ctx, namev);
    web_buf full = {0};
    if (is_class) { web_buf_puts(&full, "class "); }
    web_buf_puts(&full, (name && name[0]) ? name : "(anonymous)");
    if (!is_class) { web_buf_puts(&full, "("); web_buf_puts(&full, buf); web_buf_puts(&full, ")"); }
    if (name) { JS_FreeCString(ctx, name); }
    JS_FreeValue(ctx, namev);
    if (s) { JS_FreeCString(ctx, s); }
    JS_FreeValue(ctx, src);
    JSValue jv = JS_NewStringLen(ctx, (const char *)(full.p ? full.p : (uint8_t *)""), full.len);
    dt_str(ctx, out, jv);
    JS_FreeValue(ctx, jv);
    web_buf_free(&full);
}

/* domdesc(n): a short form of a DOM node */
static void dt_domdesc(JSContext *ctx, JSValueConst n, web_buf *out)
{
    JSValue ntv = JS_GetPropertyStr(ctx, n, "nodeType");
    int32_t nt = 0; JS_ToInt32(ctx, &nt, ntv); JS_FreeValue(ctx, ntv);
    web_buf form = {0};
    if (nt == 1) {
        JSValue lnv = JS_GetPropertyStr(ctx, n, "localName");
        const char *ln = JS_ToCString(ctx, lnv);
        web_buf_puts(&form, "<"); web_buf_puts(&form, ln ? ln : "");
        if (ln) { JS_FreeCString(ctx, ln); }
        JS_FreeValue(ctx, lnv);
        JSValue idv = JS_GetPropertyStr(ctx, n, "id");
        const char *id = JS_ToCString(ctx, idv);
        if (id && id[0]) { web_buf_puts(&form, " id=\""); web_buf_puts(&form, id); web_buf_puts(&form, "\""); }
        if (id) { JS_FreeCString(ctx, id); }
        JS_FreeValue(ctx, idv);
        JSValue cnv = JS_GetPropertyStr(ctx, n, "className");
        if (JS_IsString(cnv)) { const char *cn = JS_ToCString(ctx, cnv); if (cn && cn[0]) { web_buf_puts(&form, " class=\""); web_buf_puts(&form, cn); web_buf_puts(&form, "\""); } if (cn) { JS_FreeCString(ctx, cn); } }
        JS_FreeValue(ctx, cnv);
        web_buf_puts(&form, ">");
    } else if (nt == 3 || nt == 8) {
        JSValue dv = JS_GetPropertyStr(ctx, n, "data");
        JSValue ds = JS_ToString(ctx, dv);
        JSValue slicefn = JS_GetPropertyStr(ctx, ds, "slice");
        JSValueConst sa[2] = { JS_NewInt32(ctx, 0), JS_NewInt32(ctx, 60) };
        JSValue cut = JS_Call(ctx, slicefn, ds, 2, sa);
        const char *c = JS_ToCString(ctx, cut);
        if (nt == 3) { web_buf_puts(&form, "#text \""); web_buf_puts(&form, c ? c : ""); web_buf_puts(&form, "\""); }
        else { web_buf_puts(&form, "<!--"); web_buf_puts(&form, c ? c : ""); web_buf_puts(&form, "-->"); }
        if (c) { JS_FreeCString(ctx, c); }
        JS_FreeValue(ctx, cut); JS_FreeValue(ctx, slicefn); JS_FreeValue(ctx, ds); JS_FreeValue(ctx, dv);
    } else if (nt == 9) {
        web_buf_puts(&form, "#document");
    } else {
        JSValue nn = JS_GetPropertyStr(ctx, n, "nodeName");
        const char *s = JS_ToCString(ctx, nn);
        web_buf_puts(&form, s ? s : "Node");
        if (s) { JS_FreeCString(ctx, s); }
        JS_FreeValue(ctx, nn);
    }
    JSValue jv = JS_NewStringLen(ctx, (const char *)(form.p ? form.p : (uint8_t *)""), form.len);
    dt_str(ctx, out, jv);
    JS_FreeValue(ctx, jv);
    web_buf_free(&form);
}

static void dt_node(dt_ser *s, JSValueConst v);

/* is v an instance of globalThis[name]? */
static bool dt_instanceof(JSContext *ctx, JSValueConst v, const char *name)
{
    JSValue ctor = global_prop(ctx, name);
    if (!JS_IsObject(ctor)) { JS_FreeValue(ctx, ctor); return false; }
    int r = JS_IsInstanceOf(ctx, v, ctor);
    JS_FreeValue(ctx, ctor);
    return r > 0;
}
static bool dt_array_is(JSContext *ctx, JSValueConst v)
{
    WJ_UNUSED(ctx);
    return JS_IsArray(v) > 0;
}
static bool dt_is_view(JSContext *ctx, JSValueConst v)
{
    JSValue ab = global_prop(ctx, "ArrayBuffer");
    JSValue isview = JS_GetPropertyStr(ctx, ab, "isView");
    JSValue r = JS_Call(ctx, isview, ab, 1, &v);
    bool is = JS_ToBool(ctx, r);
    JS_FreeValue(ctx, r); JS_FreeValue(ctx, isview); JS_FreeValue(ctx, ab);
    return is;
}

/* seen.indexOf(v) >= 0 */
static bool dt_seen_has(dt_ser *s, JSValueConst v)
{
    int64_t n = 0; JS_GetLength(s->ctx, s->seen, &n);
    for (int64_t i = 0; i < n; i++) {
        JSValue e = JS_GetPropertyInt64(s->ctx, s->seen, i);
        bool same = JS_VALUE_GET_PTR(e) == JS_VALUE_GET_PTR(v);
        JS_FreeValue(s->ctx, e);
        if (same) { return true; }
    }
    return false;
}
static void dt_seen_push(dt_ser *s, JSValueConst v)
{
    int64_t n = 0; JS_GetLength(s->ctx, s->seen, &n);
    JS_SetPropertyInt64(s->ctx, s->seen, n, JS_DupValue(s->ctx, v));
}
static void dt_seen_pop(dt_ser *s)
{
    int64_t n = 0; JS_GetLength(s->ctx, s->seen, &n);
    if (n > 0) { JSValue e = JS_GetPropertyInt64(s->ctx, s->seen, n - 1); JS_FreeValue(s->ctx, e); JS_SetPropertyStr(s->ctx, s->seen, "length", JS_NewInt64(s->ctx, n - 1)); }
}

/* obj(v, depth, seen, b): a non-null object value */
static void dt_obj(dt_ser *s, JSValueConst v)
{
    JSContext *ctx = s->ctx;
    web_buf *out = &s->out;
    s->budget -= 1;
    char cls[128] = "Object";
    if (dt_array_is(ctx, v)) { snprintf(cls, sizeof cls, "Array"); } else { dt_class_of(ctx, v, cls, sizeof cls); }
    /* Error / Node / Date / RegExp */
    if (dt_instanceof(ctx, v, "Error")) {
        web_buf_puts(out, "{\"t\":\"x\",\"c\":"); dt_str_c(ctx, out, cls);
        JSValue sv = JS_ToString(ctx, v); web_buf_puts(out, ",\"d\":"); dt_str(ctx, out, sv); JS_FreeValue(ctx, sv);
        JSValue st = JS_GetPropertyStr(ctx, v, "stack"); JSValue sts = JS_ToString(ctx, st); web_buf_puts(out, ",\"st\":"); dt_str(ctx, out, sts); JS_FreeValue(ctx, sts); JS_FreeValue(ctx, st);
        web_buf_puts(out, "}");
        return;
    }
    if (dt_instanceof(ctx, v, "Node")) { web_buf_puts(out, "{\"t\":\"d\",\"d\":"); dt_domdesc(ctx, v, out); web_buf_puts(out, "}"); return; }
    if (dt_instanceof(ctx, v, "Date")) {
        web_buf_puts(out, "{\"t\":\"o\",\"c\":\"Date\",\"d\":");
        JSValue iso;
        JSValue gt = JS_GetPropertyStr(ctx, v, "getTime"); JSValue tv = JS_Call(ctx, gt, v, 0, NULL); double t; JS_ToFloat64(ctx, &t, tv); JS_FreeValue(ctx, tv); JS_FreeValue(ctx, gt);
        if (t != t) { iso = JS_NewString(ctx, "Invalid Date"); }
        else { JSValue isofn = JS_GetPropertyStr(ctx, v, "toISOString"); iso = JS_Call(ctx, isofn, v, 0, NULL); JS_FreeValue(ctx, isofn); }
        dt_str(ctx, out, iso); JS_FreeValue(ctx, iso);
        web_buf_puts(out, "}");
        return;
    }
    if (dt_instanceof(ctx, v, "RegExp")) { web_buf_puts(out, "{\"t\":\"o\",\"c\":\"RegExp\",\"d\":"); JSValue sv = JS_ToString(ctx, v); dt_str(ctx, out, sv); JS_FreeValue(ctx, sv); web_buf_puts(out, "}"); return; }

    bool open = s->depth < DT_MAXDEPTH && s->budget > 0;
    web_buf_puts(out, "{\"t\":\"o\",\"c\":"); dt_str_c(ctx, out, cls);
    dt_seen_push(s, v);
    char num[32];
    if (dt_instanceof(ctx, v, "Map")) {
        JSValue sz = JS_GetPropertyStr(ctx, v, "size"); int64_t size = 0; JS_ToInt64(ctx, &size, sz); JS_FreeValue(ctx, sz);
        snprintf(num, sizeof num, ",\"m\":%lld", (long long)size); web_buf_puts(out, num);
        if (open) {
            web_buf_puts(out, ",\"p\":[");
            JSValue entries = JS_GetPropertyStr(ctx, v, "entries"); JSValue it = JS_Call(ctx, entries, v, 0, NULL); JS_FreeValue(ctx, entries);
            JSValue nextfn = JS_GetPropertyStr(ctx, it, "next");
            int64_t i = 0; bool broke = false;
            for (;;) {
                JSValue res = JS_Call(ctx, nextfn, it, 0, NULL);
                JSValue done = JS_GetPropertyStr(ctx, res, "done");
                if (JS_ToBool(ctx, done)) { JS_FreeValue(ctx, done); JS_FreeValue(ctx, res); break; }
                JS_FreeValue(ctx, done);
                if (i >= DT_MAXKEYS) { snprintf(num, sizeof num, "],\"x\":%lld,\"p2\":[", (long long)(size - DT_MAXKEYS)); web_buf_puts(out, num); broke = true; JS_FreeValue(ctx, res); break; }
                JSValue pair = JS_GetPropertyStr(ctx, res, "value");
                JSValue key = JS_GetPropertyInt64(ctx, pair, 0); JSValue val = JS_GetPropertyInt64(ctx, pair, 1);
                if (i) { web_buf_puts(out, ","); }
                web_buf_puts(out, "["); s->depth++; dt_node(s, key); web_buf_puts(out, ","); dt_node(s, val); s->depth--; web_buf_puts(out, "]");
                JS_FreeValue(ctx, key); JS_FreeValue(ctx, val); JS_FreeValue(ctx, pair); JS_FreeValue(ctx, res);
                i++;
            }
            JS_FreeValue(ctx, nextfn); JS_FreeValue(ctx, it);
            web_buf_puts(out, "]");
            (void)broke;
        }
    } else if (dt_instanceof(ctx, v, "Set")) {
        JSValue sz = JS_GetPropertyStr(ctx, v, "size"); int64_t size = 0; JS_ToInt64(ctx, &size, sz); JS_FreeValue(ctx, sz);
        snprintf(num, sizeof num, ",\"m\":%lld", (long long)size); web_buf_puts(out, num);
        if (open) {
            web_buf_puts(out, ",\"p\":[");
            JSValue valuesfn = JS_GetPropertyStr(ctx, v, "values"); JSValue it = JS_Call(ctx, valuesfn, v, 0, NULL); JS_FreeValue(ctx, valuesfn);
            JSValue nextfn = JS_GetPropertyStr(ctx, it, "next");
            int64_t i = 0;
            for (;;) {
                JSValue res = JS_Call(ctx, nextfn, it, 0, NULL);
                JSValue done = JS_GetPropertyStr(ctx, res, "done");
                if (JS_ToBool(ctx, done)) { JS_FreeValue(ctx, done); JS_FreeValue(ctx, res); break; }
                JS_FreeValue(ctx, done);
                if (i >= DT_MAXKEYS) { JS_FreeValue(ctx, res); break; }
                JSValue val = JS_GetPropertyStr(ctx, res, "value");
                if (i) { web_buf_puts(out, ","); }
                web_buf_puts(out, "[{\"t\":\"s\",\"v\":\"\"},"); s->depth++; dt_node(s, val); s->depth--; web_buf_puts(out, "]");
                JS_FreeValue(ctx, val); JS_FreeValue(ctx, res);
                i++;
            }
            JS_FreeValue(ctx, nextfn); JS_FreeValue(ctx, it);
            web_buf_puts(out, "]");
            if (size > DT_MAXKEYS) { snprintf(num, sizeof num, ",\"x\":%lld", (long long)(size - DT_MAXKEYS)); web_buf_puts(out, num); }
        }
    } else if (dt_array_is(ctx, v) || dt_is_view(ctx, v)) {
        JSValue lv = JS_GetPropertyStr(ctx, v, "length"); int64_t n = 0; JS_ToInt64(ctx, &n, lv); JS_FreeValue(ctx, lv);
        snprintf(num, sizeof num, ",\"m\":%lld", (long long)n); web_buf_puts(out, num);
        if (open) {
            web_buf_puts(out, ",\"p\":[");
            for (int64_t i = 0; i < n && i < DT_MAXKEYS; i++) {
                if (i) { web_buf_puts(out, ","); }
                char idx[24]; snprintf(idx, sizeof idx, "%lld", (long long)i);
                web_buf_puts(out, "["); dt_str_c(ctx, out, idx); web_buf_puts(out, ",");
                JSValue el = JS_GetPropertyInt64(ctx, v, i); s->depth++; dt_node(s, el); s->depth--; JS_FreeValue(ctx, el);
                web_buf_puts(out, "]");
            }
            web_buf_puts(out, "]");
            if (n > DT_MAXKEYS) { snprintf(num, sizeof num, ",\"x\":%lld", (long long)(n - DT_MAXKEYS)); web_buf_puts(out, num); }
        }
    } else {
        JSValue objc = global_prop(ctx, "Object");
        JSValue keysfn = JS_GetPropertyStr(ctx, objc, "keys");
        JSValue keys = JS_Call(ctx, keysfn, objc, 1, &v);
        JS_FreeValue(ctx, keysfn); JS_FreeValue(ctx, objc);
        int64_t nk = 0; JS_GetLength(ctx, keys, &nk);
        snprintf(num, sizeof num, ",\"m\":%lld", (long long)nk); web_buf_puts(out, num);
        if (open) {
            web_buf_puts(out, ",\"p\":[");
            JSValue opc = global_prop(ctx, "Object");
            JSValue gopd = JS_GetPropertyStr(ctx, opc, "getOwnPropertyDescriptor");
            for (int64_t i = 0; i < nk && i < DT_MAXKEYS; i++) {
                JSValue kv = JS_GetPropertyInt64(ctx, keys, i);
                if (i) { web_buf_puts(out, ","); }
                web_buf_puts(out, "["); dt_str(ctx, out, kv); web_buf_puts(out, ",");
                /* d = getOwnPropertyDescriptor(v, k); val = d && "value" in d ? d.value : "(...)" */
                JSValueConst da[2] = { v, kv };
                JSValue d = JS_Call(ctx, gopd, opc, 2, da);
                /* d && "value" in d ? d.value : "(...)" */
                bool has_value = false;
                if (JS_IsObject(d)) { JSAtom va = JS_NewAtom(ctx, "value"); has_value = JS_HasProperty(ctx, d, va) > 0; JS_FreeAtom(ctx, va); }
                if (has_value) { JSValue val = JS_GetPropertyStr(ctx, d, "value"); s->depth++; dt_node(s, val); s->depth--; JS_FreeValue(ctx, val); }
                else { web_buf_puts(out, "{\"t\":\"a\"}"); }
                JS_FreeValue(ctx, d); JS_FreeValue(ctx, kv);
                web_buf_puts(out, "]");
            }
            JS_FreeValue(ctx, gopd); JS_FreeValue(ctx, opc);
            web_buf_puts(out, "]");
            if (nk > DT_MAXKEYS) { snprintf(num, sizeof num, ",\"x\":%lld", (long long)(nk - DT_MAXKEYS)); web_buf_puts(out, num); }
        }
        JS_FreeValue(ctx, keys);
    }
    dt_seen_pop(s);
    web_buf_puts(out, "}");
}

/* node(v, depth, seen, b) */
static void dt_node(dt_ser *s, JSValueConst v)
{
    JSContext *ctx = s->ctx;
    web_buf *out = &s->out;
    int tag = JS_VALUE_GET_TAG(v);
    if (JS_IsString(v)) { web_buf_puts(out, "{\"t\":\"s\",\"v\":"); dt_str(ctx, out, v); web_buf_puts(out, "}"); return; }
    if (JS_IsNumber(v)) {
        double d; JS_ToFloat64(ctx, &d, v);
        web_buf_puts(out, "{\"t\":\"n\",\"v\":\"");
        if (d == 0 && signbit(d)) { web_buf_puts(out, "-0"); }
        else { JSValue sv = JS_ToString(ctx, v); const char *c = JS_ToCString(ctx, sv); web_buf_puts(out, c ? c : ""); if (c) { JS_FreeCString(ctx, c); } JS_FreeValue(ctx, sv); }
        web_buf_puts(out, "\"}");
        return;
    }
    if (JS_IsBool(v)) { web_buf_puts(out, JS_ToBool(ctx, v) ? "{\"t\":\"b\",\"v\":true}" : "{\"t\":\"b\",\"v\":false}"); return; }
    if (JS_IsUndefined(v)) { web_buf_puts(out, "{\"t\":\"u\"}"); return; }
    if (JS_IsBigInt(v)) { JSValue sv = JS_ToString(ctx, v); const char *c = JS_ToCString(ctx, sv); web_buf_puts(out, "{\"t\":\"i\",\"v\":\""); web_buf_puts(out, c ? c : "0"); web_buf_puts(out, "n\"}"); if (c) { JS_FreeCString(ctx, c); } JS_FreeValue(ctx, sv); return; }
    if (tag == JS_TAG_SYMBOL) { JSValue sv = JS_ToString(ctx, v); web_buf_puts(out, "{\"t\":\"y\",\"v\":"); dt_str(ctx, out, sv); JS_FreeValue(ctx, sv); web_buf_puts(out, "}"); return; }
    if (JS_IsFunction(ctx, v)) { web_buf_puts(out, "{\"t\":\"f\",\"d\":"); dt_fdesc(ctx, v, out); web_buf_puts(out, "}"); return; }
    if (JS_IsNull(v)) { web_buf_puts(out, "{\"t\":\"z\"}"); return; }
    if (dt_seen_has(s, v)) { web_buf_puts(out, "{\"t\":\"c\"}"); return; }
    dt_obj(s, v);
}

/* ---- where(): the first stack frame outside this module ---- */

static void dt_where(JSContext *ctx, web_buf *out)
{
    /* best effort: new Error().stack, first line with a source location that is not this native frame */
    JSValue errc = global_prop(ctx, "Error");
    JSValue err = JS_CallConstructor(ctx, errc, 0, NULL);
    JS_FreeValue(ctx, errc);
    JSValue st = JS_GetPropertyStr(ctx, err, "stack");
    JS_FreeValue(ctx, err);
    const char *s = JS_ToCString(ctx, st);
    char best[512]; best[0] = 0;
    if (s) {
        const char *line = s;
        while (*line) {
            const char *nl = strchr(line, '\n');
            size_t len = nl ? (size_t)(nl - line) : strlen(line);
            /* skip native frames and this file */
            if (len > 0 && len < sizeof best && !strstr(line, "web_devtools")) {
                /* trim leading whitespace / "at " and "...(" ... ")" */
                const char *b = line; while (*b == ' ' || *b == '\t') { b++; }
                if (strncmp(b, "at ", 3) == 0) { b += 3; }
                const char *lp = strrchr(b, '(');
                const char *frame = lp ? lp + 1 : b;
                size_t fl = nl ? (size_t)(nl - frame) : strlen(frame);
                char tmp[512]; if (fl >= sizeof tmp) { fl = sizeof tmp - 1; }
                memcpy(tmp, frame, fl); tmp[fl] = 0;
                size_t tl = strlen(tmp); while (tl && (tmp[tl-1] == ')' || tmp[tl-1] == ' ' || tmp[tl-1] == '\r')) { tmp[--tl] = 0; }
                /* must look like a source location: has ':<digits>' near the end */
                bool loc = false; for (const char *c = tmp; *c; c++) { if (*c == ':' && c[1] >= '0' && c[1] <= '9') { loc = true; } }
                if (loc && tmp[0]) { snprintf(best, sizeof best, "%s", tmp); break; }
            }
            if (!nl) { break; }
            line = nl + 1;
        }
        JS_FreeCString(ctx, s);
    }
    JS_FreeValue(ctx, st);
    dt_str_c(ctx, out, best);
}

/* ---- the state object and its accessors ---- */

static JSValue dt_state(JSContext *ctx)
{
    JSValue console = global_prop(ctx, "console");
    JSAtom a = dt_symbol_atom(ctx);
    JSValue s = JS_GetProperty(ctx, console, a);
    JS_FreeAtom(ctx, a);
    JS_FreeValue(ctx, console);
    return s;
}
static bool dt_on(JSContext *ctx, JSValueConst state)
{
    JSValue v = JS_GetPropertyStr(ctx, state, "on");
    bool on = JS_ToBool(ctx, v);
    JS_FreeValue(ctx, v);
    return on;
}
static int64_t dt_max(JSContext *ctx, JSValueConst state)
{
    JSValue v = JS_GetPropertyStr(ctx, state, "max");
    int64_t m = 0; JS_ToInt64(ctx, &m, v); JS_FreeValue(ctx, v);
    return m;
}
/* orig: state._orig.<name> */
static JSValue dt_orig(JSContext *ctx, JSValueConst state, const char *name)
{
    JSValue orig = JS_GetPropertyStr(ctx, state, "_orig");
    JSValue f = JS_GetPropertyStr(ctx, orig, name);
    JS_FreeValue(ctx, orig);
    return f;
}
/* send(tag, json): orig.debug.call(console, "\u0001tag:" + json) if json.length <= state.max */
static bool dt_send(JSContext *ctx, JSValueConst state, const char *tag, const char *json, size_t jlen)
{
    if ((int64_t)jlen > dt_max(ctx, state)) { return false; }
    JSValue console = global_prop(ctx, "console");
    JSValue debug = dt_orig(ctx, state, "debug");
    web_buf msg = {0};
    web_buf_puts(&msg, "\x01"); web_buf_puts(&msg, tag); web_buf_puts(&msg, ":"); web_buf_put(&msg, json, jlen);
    JSValueConst arg = JS_NewStringLen(ctx, (const char *)(msg.p ? msg.p : (uint8_t *)""), msg.len);
    JSValue r = JS_Call(ctx, debug, console, 1, &arg);
    JS_FreeValue(ctx, (JSValue)arg); JS_FreeValue(ctx, r); JS_FreeValue(ctx, debug); JS_FreeValue(ctx, console);
    web_buf_free(&msg);
    return true;
}
/* keep(args): ++rid, refs.set(rid, args), evict past 300; returns the id */
static int64_t dt_keep(JSContext *ctx, JSValueConst state, JSValueConst args)
{
    JSValue ridv = JS_GetPropertyStr(ctx, state, "rid");
    int64_t rid = 0; JS_ToInt64(ctx, &rid, ridv); JS_FreeValue(ctx, ridv);
    rid += 1;
    JS_SetPropertyStr(ctx, state, "rid", JS_NewInt64(ctx, rid));
    JSValue refs = JS_GetPropertyStr(ctx, state, "refs");
    JSValue setfn = JS_GetPropertyStr(ctx, refs, "set");
    JSValueConst sa[2] = { JS_NewInt64(ctx, rid), args };
    JSValue r = JS_Call(ctx, setfn, refs, 2, sa);
    JS_FreeValue(ctx, (JSValue)sa[0]); JS_FreeValue(ctx, r); JS_FreeValue(ctx, setfn);
    /* refs.size > 300 ? refs.delete(refs.keys().next().value) */
    JSValue sz = JS_GetPropertyStr(ctx, refs, "size"); int64_t size = 0; JS_ToInt64(ctx, &size, sz); JS_FreeValue(ctx, sz);
    if (size > 300) {
        JSValue keysfn = JS_GetPropertyStr(ctx, refs, "keys"); JSValue it = JS_Call(ctx, keysfn, refs, 0, NULL); JS_FreeValue(ctx, keysfn);
        JSValue nextfn = JS_GetPropertyStr(ctx, it, "next"); JSValue res = JS_Call(ctx, nextfn, it, 0, NULL); JS_FreeValue(ctx, nextfn); JS_FreeValue(ctx, it);
        JSValue first = JS_GetPropertyStr(ctx, res, "value"); JS_FreeValue(ctx, res);
        JSValue delfn = JS_GetPropertyStr(ctx, refs, "delete"); JSValue dr = JS_Call(ctx, delfn, refs, 1, (JSValueConst *)&first); JS_FreeValue(ctx, dr); JS_FreeValue(ctx, delfn); JS_FreeValue(ctx, first);
    }
    JS_FreeValue(ctx, refs);
    return rid;
}

/* a serializer over `state` with a fresh seen list and budget */
static void dt_ser_init(dt_ser *s, JSContext *ctx, JSValueConst state, int budget)
{
    s->ctx = ctx; s->state = state; s->out = (web_buf){0}; s->budget = budget; s->seen = JS_NewArray(ctx); s->depth = 0;
}
static void dt_ser_free(dt_ser *s)
{
    JS_FreeValue(s->ctx, s->seen);
    web_buf_free(&s->out);
}

/* ---- the wrapped console methods ---- */

/* data[0] = state, data[1] = the level string, data[2] = the original method, data[3] = is-assert flag (int via magic) */
static JSValue dt_console_wrapper(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    JSValue state = data[0];
    JSValue console = global_prop(ctx, "console");
    JSValueConst recv = JS_IsUndefined(this_val) ? console : this_val;
    if (dt_on(ctx, state)) {
        const char *level = JS_ToCString(ctx, data[1]);
        /* args as a plain array */
        JSValue args = JS_NewArray(ctx);
        for (int i = 0; i < argc; i++) { JS_SetPropertyUint32(ctx, args, (uint32_t)i, JS_DupValue(ctx, argv[i])); }
        int64_t id = dt_keep(ctx, state, args);
        web_buf w = {0}; dt_where(ctx, &w);
        dt_ser ser; dt_ser_init(&ser, ctx, state, magic ? 200 : 400);   /* assert budget 200 in the old code */
        web_buf_puts(&ser.out, "{\"l\":\"");
        web_buf_puts(&ser.out, level ? level : "log");
        char idbuf[48]; snprintf(idbuf, sizeof idbuf, "\",\"r\":%lld,\"w\":", (long long)id); web_buf_puts(&ser.out, idbuf);
        web_buf_put(&ser.out, (const char *)(w.p ? w.p : (uint8_t *)"\"\""), w.len ? w.len : 2);
        web_buf_puts(&ser.out, ",\"a\":[");
        if (magic) {
            /* assert: ["Assertion failed"].concat(args) */
            JSValue af = JS_NewString(ctx, "Assertion failed");
            dt_node(&ser, af); JS_FreeValue(ctx, af);
            for (int i = 0; i < argc; i++) { web_buf_puts(&ser.out, ","); dt_node(&ser, argv[i]); }
        } else {
            for (int i = 0; i < argc; i++) { if (i) { web_buf_puts(&ser.out, ","); } dt_node(&ser, argv[i]); }
        }
        web_buf_puts(&ser.out, "]}");
        dt_send(ctx, state, "dt", (const char *)(ser.out.p ? ser.out.p : (uint8_t *)""), ser.out.len);
        dt_ser_free(&ser);
        web_buf_free(&w);
        JS_FreeValue(ctx, args);
        if (level) { JS_FreeCString(ctx, level); }
    }
    JSValue r = JS_Call(ctx, data[2], recv, argc, argv);
    JS_FreeValue(ctx, console);
    return r;
}

/* table wrapper (data[0]=state, data[1]=original) */
static void dt_table_build(dt_ser *s, JSValueConst data, JSValueConst cols);
static JSValue dt_console_table(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(magic);
    JSValue state = data[0];
    JSValue console = global_prop(ctx, "console");
    JSValueConst recv = JS_IsUndefined(this_val) ? console : this_val;
    if (dt_on(ctx, state)) {
        JSValueConst dataArg = wj_arg(argc, (JSValue *)argv, 0);
        JSValueConst cols = wj_arg(argc, (JSValue *)argv, 1);
        if (JS_IsObject(dataArg)) {
            dt_ser ser; dt_ser_init(&ser, ctx, state, 400);
            dt_table_build(&ser, dataArg, cols);
            if (ser.out.len > 0) {
                JSValue holder = JS_NewArray(ctx); JS_SetPropertyUint32(ctx, holder, 0, JS_DupValue(ctx, dataArg));
                int64_t id = dt_keep(ctx, state, holder);
                web_buf w = {0}; dt_where(ctx, &w);
                web_buf msg = {0};
                char head[64]; snprintf(head, sizeof head, "{\"l\":\"log\",\"r\":%lld,\"w\":", (long long)id); web_buf_puts(&msg, head);
                web_buf_put(&msg, (const char *)(w.p ? w.p : (uint8_t *)"\"\""), w.len ? w.len : 2);
                web_buf_puts(&msg, ",\"tbl\":"); web_buf_put(&msg, (const char *)ser.out.p, ser.out.len); web_buf_puts(&msg, "}");
                dt_send(ctx, state, "dt", (const char *)(msg.p ? msg.p : (uint8_t *)""), msg.len);
                web_buf_free(&msg); web_buf_free(&w);
                JS_FreeValue(ctx, holder);
            }
            dt_ser_free(&ser);
        }
    }
    JSValue r = JS_Call(ctx, data[1], recv, argc, argv);
    JS_FreeValue(ctx, console);
    return r;
}

/* table(data, cols): build the "tbl" JSON into s->out (empty when data is not an object). Mirrors the old table(). */
static void dt_table_build(dt_ser *s, JSValueConst data, JSValueConst cols)
{
    JSContext *ctx = s->ctx;
    if (!JS_IsObject(data)) { return; }
    /* rows: [{ i, cells:{}, value? }], keys: the union of row keys, hasValues */
    JSValue rows = JS_NewArray(ctx), keys = JS_NewArray(ctx);
    bool hasValues = false;
    uint32_t nrows = 0, nkeys = 0;
    /* add(idx, row) */
    #define DT_ADD(idxv, rowv) do { \
        JSValue r = JS_NewObject(ctx); JS_SetPropertyStr(ctx, r, "i", (idxv)); JSValue cells = JS_NewObject(ctx); \
        JSValueConst row = (rowv); \
        if (JS_IsObject(row)) { JSValue objc = global_prop(ctx, "Object"); JSValue kf = JS_GetPropertyStr(ctx, objc, "keys"); JSValue rk = JS_Call(ctx, kf, objc, 1, (JSValueConst *)&row); JS_FreeValue(ctx, kf); JS_FreeValue(ctx, objc); \
            int64_t rkn = 0; JS_GetLength(ctx, rk, &rkn); for (int64_t ki = 0; ki < rkn; ki++) { JSValue k = JS_GetPropertyInt64(ctx, rk, ki); \
                bool found = false; for (uint32_t j = 0; j < nkeys; j++) { JSValue ek = JS_GetPropertyUint32(ctx, keys, j); const char *a2 = JS_ToCString(ctx, ek); const char *b2 = JS_ToCString(ctx, k); if (a2 && b2 && strcmp(a2, b2) == 0) { found = true; } if (a2) JS_FreeCString(ctx, a2); if (b2) JS_FreeCString(ctx, b2); JS_FreeValue(ctx, ek); if (found) break; } \
                if (!found) { JS_SetPropertyUint32(ctx, keys, nkeys++, JS_DupValue(ctx, k)); } \
                JSAtom ka = JS_ValueToAtom(ctx, k); JSValue cv = JS_GetProperty(ctx, row, ka); JS_SetProperty(ctx, cells, ka, cv); JS_FreeAtom(ctx, ka); JS_FreeValue(ctx, k); } \
            JS_FreeValue(ctx, rk); } \
        else { JS_SetPropertyStr(ctx, r, "value", JS_DupValue(ctx, row)); hasValues = true; } \
        JS_SetPropertyStr(ctx, r, "cells", cells); JS_SetPropertyUint32(ctx, rows, nrows++, r); } while (0)

    if (dt_instanceof(ctx, data, "Map")) {
        JSValue entries = JS_GetPropertyStr(ctx, data, "entries"); JSValue it = JS_Call(ctx, entries, data, 0, NULL); JS_FreeValue(ctx, entries);
        JSValue nextfn = JS_GetPropertyStr(ctx, it, "next"); int64_t i = 0;
        for (;;) { JSValue res = JS_Call(ctx, nextfn, it, 0, NULL); JSValue done = JS_GetPropertyStr(ctx, res, "done"); if (JS_ToBool(ctx, done)) { JS_FreeValue(ctx, done); JS_FreeValue(ctx, res); break; } JS_FreeValue(ctx, done); JSValue pair = JS_GetPropertyStr(ctx, res, "value"); JSValue val = JS_GetPropertyInt64(ctx, pair, 1); char ib[24]; snprintf(ib, sizeof ib, "%lld", (long long)i++); DT_ADD(JS_NewString(ctx, ib), val); JS_FreeValue(ctx, val); JS_FreeValue(ctx, pair); JS_FreeValue(ctx, res); }
        JS_FreeValue(ctx, nextfn); JS_FreeValue(ctx, it);
    } else if (dt_instanceof(ctx, data, "Set")) {
        JSValue valuesfn = JS_GetPropertyStr(ctx, data, "values"); JSValue it = JS_Call(ctx, valuesfn, data, 0, NULL); JS_FreeValue(ctx, valuesfn);
        JSValue nextfn = JS_GetPropertyStr(ctx, it, "next"); int64_t i = 0;
        for (;;) { JSValue res = JS_Call(ctx, nextfn, it, 0, NULL); JSValue done = JS_GetPropertyStr(ctx, res, "done"); if (JS_ToBool(ctx, done)) { JS_FreeValue(ctx, done); JS_FreeValue(ctx, res); break; } JS_FreeValue(ctx, done); JSValue val = JS_GetPropertyStr(ctx, res, "value"); char ib[24]; snprintf(ib, sizeof ib, "%lld", (long long)i++); DT_ADD(JS_NewString(ctx, ib), val); JS_FreeValue(ctx, val); JS_FreeValue(ctx, res); }
        JS_FreeValue(ctx, nextfn); JS_FreeValue(ctx, it);
    } else {
        JSValue objc = global_prop(ctx, "Object"); JSValue kf = JS_GetPropertyStr(ctx, objc, "keys"); JSValue dk = JS_Call(ctx, kf, objc, 1, (JSValueConst *)&data); JS_FreeValue(ctx, kf); JS_FreeValue(ctx, objc);
        int64_t dkn = 0; JS_GetLength(ctx, dk, &dkn);
        for (int64_t i = 0; i < dkn && i < 200; i++) { JSValue k = JS_GetPropertyInt64(ctx, dk, i); JSAtom ka = JS_ValueToAtom(ctx, k); JSValue val = JS_GetProperty(ctx, data, ka); JS_FreeAtom(ctx, ka); DT_ADD(JS_ToString(ctx, k), val); JS_FreeValue(ctx, val); JS_FreeValue(ctx, k); }
        JS_FreeValue(ctx, dk);
    }
    #undef DT_ADD

    /* use = Array.isArray(cols) ? cols.map(String) : keys.slice(0, 40) */
    JSValue use = JS_NewArray(ctx); uint32_t nuse = 0;
    if (dt_array_is(ctx, cols)) {
        int64_t cn = 0; JS_GetLength(ctx, cols, &cn);
        for (int64_t i = 0; i < cn; i++) { JSValue c = JS_GetPropertyInt64(ctx, cols, i); JS_SetPropertyUint32(ctx, use, nuse++, JS_ToString(ctx, c)); JS_FreeValue(ctx, c); }
    } else {
        for (uint32_t i = 0; i < nkeys && i < 40; i++) { JSValue k = JS_GetPropertyUint32(ctx, keys, i); JS_SetPropertyUint32(ctx, use, nuse++, JS_DupValue(ctx, k)); JS_FreeValue(ctx, k); }
    }

    web_buf *out = &s->out;
    web_buf_puts(out, "{\"cols\":[");
    for (uint32_t i = 0; i < nuse; i++) { if (i) { web_buf_puts(out, ","); } JSValue c = JS_GetPropertyUint32(ctx, use, i); dt_str(ctx, out, c); JS_FreeValue(ctx, c); }
    web_buf_puts(out, "],\"values\":"); web_buf_puts(out, hasValues ? "true" : "false"); web_buf_puts(out, ",\"rows\":[");
    for (uint32_t ri = 0; ri < nrows; ri++) {
        if (ri) { web_buf_puts(out, ","); }
        JSValue r = JS_GetPropertyUint32(ctx, rows, ri);
        JSValue iv = JS_GetPropertyStr(ctx, r, "i");
        web_buf_puts(out, "{\"i\":"); dt_str(ctx, out, iv); JS_FreeValue(ctx, iv);
        /* "v": r.value !== undefined || "value" in r ? node(r.value) : null */
        JSAtom va = JS_NewAtom(ctx, "value"); bool has = JS_HasProperty(ctx, r, va) > 0; JS_FreeAtom(ctx, va);
        web_buf_puts(out, ",\"v\":");
        if (has) { JSValue val = JS_GetPropertyStr(ctx, r, "value"); dt_ser sub; dt_ser_init(&sub, ctx, s->state, 50); dt_node(&sub, val); web_buf_put(out, (const char *)sub.out.p, sub.out.len); dt_ser_free(&sub); JS_FreeValue(ctx, val); }
        else { web_buf_puts(out, "null"); }
        web_buf_puts(out, ",\"c\":[");
        JSValue cells = JS_GetPropertyStr(ctx, r, "cells");
        for (uint32_t ci = 0; ci < nuse; ci++) {
            if (ci) { web_buf_puts(out, ","); }
            JSValue k = JS_GetPropertyUint32(ctx, use, ci);
            JSAtom ka = JS_ValueToAtom(ctx, k);
            bool kin = JS_HasProperty(ctx, cells, ka) > 0;
            if (kin) { JSValue cv = JS_GetProperty(ctx, cells, ka); dt_ser sub; dt_ser_init(&sub, ctx, s->state, 50); dt_node(&sub, cv); web_buf_put(out, (const char *)sub.out.p, sub.out.len); dt_ser_free(&sub); JS_FreeValue(ctx, cv); }
            else { web_buf_puts(out, "null"); }
            JS_FreeAtom(ctx, ka); JS_FreeValue(ctx, k);
        }
        web_buf_puts(out, "]}");
        JS_FreeValue(ctx, cells); JS_FreeValue(ctx, r);
    }
    web_buf_puts(out, "]}");
    JS_FreeValue(ctx, rows); JS_FreeValue(ctx, keys); JS_FreeValue(ctx, use);
}

/* show(val, err): its description for the tree (if on), then its text through orig.error/info */
static void dt_show(JSContext *ctx, JSValueConst state, JSValueConst val, bool err)
{
    if (dt_on(ctx, state)) {
        JSValue holder = JS_NewArray(ctx); JS_SetPropertyUint32(ctx, holder, 0, JS_DupValue(ctx, val));
        int64_t id = dt_keep(ctx, state, holder);
        dt_ser ser; dt_ser_init(&ser, ctx, state, 600);
        web_buf_puts(&ser.out, "{\"l\":\""); web_buf_puts(&ser.out, err ? "error" : "result");
        char head[48]; snprintf(head, sizeof head, "\",\"r\":%lld,\"a\":[", (long long)id); web_buf_puts(&ser.out, head);
        dt_node(&ser, val);
        web_buf_puts(&ser.out, "]}");
        dt_send(ctx, state, "dt", (const char *)(ser.out.p ? ser.out.p : (uint8_t *)""), ser.out.len);
        dt_ser_free(&ser);
        JS_FreeValue(ctx, holder);
    }
    /* text */
    JSValue text;
    if (err) {
        JSValue stack = JS_IsObject(val) ? JS_GetPropertyStr(ctx, val, "stack") : JS_UNDEFINED;
        if (!JS_IsUndefined(stack) && !JS_IsNull(stack)) { text = JS_ToString(ctx, stack); }
        else { text = JS_ToString(ctx, val); }
        JS_FreeValue(ctx, stack);
    } else if (JS_IsString(val)) {
        text = JS_JSONStringify(ctx, val, JS_UNDEFINED, JS_UNDEFINED);
    } else if (JS_IsFunction(ctx, val)) {
        web_buf fb = {0}; dt_fdesc(ctx, val, &fb);
        /* dt_fdesc produced a JSON string; parse it back to the plain text */
        text = JS_JSONParse(ctx, (const char *)(fb.p ? fb.p : (uint8_t *)"\"\""), fb.len ? fb.len : 2, "<dt>");
        if (JS_IsException(text)) { JS_FreeValue(ctx, JS_GetException(ctx)); text = JS_ToString(ctx, val); }
        web_buf_free(&fb);
    } else {
        text = JS_ToString(ctx, val);
    }
    JSValue console = global_prop(ctx, "console");
    JSValue f = dt_orig(ctx, state, err ? "error" : "info");
    JS_Call(ctx, f, console, 1, (JSValueConst *)&text);
    JS_FreeValue(ctx, f); JS_FreeValue(ctx, console); JS_FreeValue(ctx, text);
}

/* store(v): keep v under temp1/temp2..., log "> tempN", show(v) */
static void dt_store(JSContext *ctx, JSValueConst state, JSValueConst v)
{
    JSValue tv = JS_GetPropertyStr(ctx, state, "temps"); int64_t temps = 0; JS_ToInt64(ctx, &temps, tv); JS_FreeValue(ctx, tv);
    temps += 1; JS_SetPropertyStr(ctx, state, "temps", JS_NewInt64(ctx, temps));
    char name[32]; snprintf(name, sizeof name, "temp%lld", (long long)temps);
    if (JS_DefinePropertyValueStr(ctx, wj_the_realm.global, name, JS_DupValue(ctx, v), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE) < 0) { JS_FreeValue(ctx, JS_GetException(ctx)); return; }
    JSValue console = global_prop(ctx, "console");
    JSValue logf = dt_orig(ctx, state, "log");
    char line[40]; snprintf(line, sizeof line, "> %s", name);
    JSValueConst la = JS_NewString(ctx, line);
    JSValue r = JS_Call(ctx, logf, console, 1, &la); JS_FreeValue(ctx, (JSValue)la); JS_FreeValue(ctx, r); JS_FreeValue(ctx, logf); JS_FreeValue(ctx, console);
    dt_show(ctx, state, v, false);
}
/* pick(id): refs.get(id); the first object/function, else a[0] (wrapped as {v}) */
static bool dt_pick(JSContext *ctx, JSValueConst state, int64_t id, JSValue *out)
{
    JSValue refs = JS_GetPropertyStr(ctx, state, "refs");
    JSValue getfn = JS_GetPropertyStr(ctx, refs, "get");
    JSValueConst idv = JS_NewInt64(ctx, id);
    JSValue a = JS_Call(ctx, getfn, refs, 1, &idv);
    JS_FreeValue(ctx, (JSValue)idv); JS_FreeValue(ctx, getfn); JS_FreeValue(ctx, refs);
    if (!JS_IsObject(a)) { JS_FreeValue(ctx, a); return false; }
    int64_t n = 0; JS_GetLength(ctx, a, &n);
    if (n == 0) { JS_FreeValue(ctx, a); return false; }
    for (int64_t i = 0; i < n; i++) { JSValue x = JS_GetPropertyInt64(ctx, a, i); if (!JS_IsNull(x) && (JS_IsObject(x) || JS_IsFunction(ctx, x))) { *out = x; JS_FreeValue(ctx, a); return true; } JS_FreeValue(ctx, x); }
    *out = JS_GetPropertyInt64(ctx, a, 0);
    JS_FreeValue(ctx, a);
    return true;
}

/* state.store(id) */
static JSValue dt_m_store(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    int64_t id = 0; JS_ToInt64(ctx, &id, wj_arg(argc, (JSValue *)argv, 0));
    JSValue v;
    if (dt_pick(ctx, data[0], id, &v)) { dt_store(ctx, data[0], v); JS_FreeValue(ctx, v); }
    return JS_UNDEFINED;
}
/* state.storeNode(path): walk document.childNodes by indices, store it */
static JSValue dt_m_store_node(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    JSValueConst path = wj_arg(argc, (JSValue *)argv, 0);
    JSValue n = global_prop(ctx, "document");
    int64_t pn = 0; JS_GetLength(ctx, path, &pn);
    for (int64_t i = 0; i < pn && JS_IsObject(n); i++) {
        JSValue iv = JS_GetPropertyInt64(ctx, path, i); int64_t idx = 0; JS_ToInt64(ctx, &idx, iv); JS_FreeValue(ctx, iv);
        JSValue cn = JS_GetPropertyStr(ctx, n, "childNodes");
        JSValue next = JS_GetPropertyInt64(ctx, cn, idx);
        JS_FreeValue(ctx, cn); JS_FreeValue(ctx, n);
        n = next;
    }
    if (JS_IsObject(n)) { dt_store(ctx, data[0], n); }
    JS_FreeValue(ctx, n);
    return JS_UNDEFINED;
}
/* state.copy(id): the value as JSON text (cycles/Maps/Sets/errors/nodes), sent as \u0001dtx: */
static JSValue dt_m_copy(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    int64_t id = 0; JS_ToInt64(ctx, &id, wj_arg(argc, (JSValue *)argv, 0));
    JSValue v;
    if (!dt_pick(ctx, data[0], id, &v)) { return JS_UNDEFINED; }
    /* this mirrors the old copy(): a JSON.stringify with a replacer. The replacer is JavaScript the engine runs; we
     * build it once and call JSON.stringify(v, replacer, 2). For a string/undefined/function, the plain forms. */
    JSValue text;
    if (JS_IsString(v)) { text = JS_DupValue(ctx, v); }
    else if (JS_IsUndefined(v)) { text = JS_NewString(ctx, "undefined"); }
    else if (JS_IsFunction(ctx, v)) {
        JSValue fp = global_prop(ctx, "Function"); JSValue fproto = JS_GetPropertyStr(ctx, fp, "prototype"); JSValue tsfn = JS_GetPropertyStr(ctx, fproto, "toString");
        text = JS_Call(ctx, tsfn, v, 0, NULL);
        JS_FreeValue(ctx, tsfn); JS_FreeValue(ctx, fproto); JS_FreeValue(ctx, fp);
        if (JS_IsException(text)) { JS_FreeValue(ctx, JS_GetException(ctx)); text = JS_ToString(ctx, v); }
    } else {
        /* JSON.stringify(v, replacer, 2) with the replacer captured on the state object (_copyReplacer) */
        JSValue replacer = JS_GetPropertyStr(ctx, data[0], "_copyReplacer");
        JSValue json = global_prop(ctx, "JSON");
        JSValue stringify = JS_GetPropertyStr(ctx, json, "stringify");
        JSValueConst sa[3] = { v, replacer, JS_NewInt32(ctx, 2) };
        text = JS_Call(ctx, stringify, json, 3, sa);
        JS_FreeValue(ctx, (JSValue)sa[2]); JS_FreeValue(ctx, stringify); JS_FreeValue(ctx, json); JS_FreeValue(ctx, replacer);
        if (JS_IsException(text)) { JS_FreeValue(ctx, JS_GetException(ctx)); text = JS_ToString(ctx, v); }
    }
    const char *c = JS_ToCString(ctx, text);
    web_buf msg = {0}; web_buf_puts(&msg, "\x01" "dtx:"); web_buf_puts(&msg, c ? c : "");
    JSValue console = global_prop(ctx, "console");
    JSValue debug = dt_orig(ctx, data[0], "debug");
    JSValueConst a = JS_NewStringLen(ctx, (const char *)(msg.p ? msg.p : (uint8_t *)""), msg.len);
    JSValue r = JS_Call(ctx, debug, console, 1, &a); JS_FreeValue(ctx, (JSValue)a); JS_FreeValue(ctx, r); JS_FreeValue(ctx, debug); JS_FreeValue(ctx, console);
    if (c) { JS_FreeCString(ctx, c); }
    web_buf_free(&msg); JS_FreeValue(ctx, text); JS_FreeValue(ctx, v);
    return JS_UNDEFINED;
}
/* state.eval(src): (0, eval)(src), await retry, then show */
static JSValue dt_m_eval(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    JSValue srcv = JS_ToString(ctx, wj_arg(argc, (JSValue *)argv, 0));
    const char *src = JS_ToCString(ctx, srcv);
    size_t slen = src ? strlen(src) : 0;
    JSValue r = JS_Eval(ctx, src ? src : "", slen, "<console>", JS_EVAL_TYPE_GLOBAL);
    bool thrown = false;
    if (JS_IsException(r)) {
        JSValue e = JS_GetException(ctx);
        /* SyntaxError with `await`: wrap as an async IIFE */
        bool is_syntax = dt_instanceof(ctx, e, "SyntaxError");
        bool has_await = src && strstr(src, "await") != NULL;
        if (is_syntax && has_await) {
            web_buf w = {0}; web_buf_puts(&w, "(async () => ("); web_buf_put(&w, src, slen); web_buf_puts(&w, "\n))()");
            r = JS_Eval(ctx, (const char *)w.p, w.len, "<console>", JS_EVAL_TYPE_GLOBAL);
            web_buf_free(&w);
            if (JS_IsException(r)) { JS_FreeValue(ctx, JS_GetException(ctx)); r = e; thrown = true; } else { JS_FreeValue(ctx, e); }
        } else { r = e; thrown = true; }
    }
    if (src) { JS_FreeCString(ctx, src); }
    JS_FreeValue(ctx, srcv);
    /* a thenable (not a function): show it, then on settle show the value/error */
    if (!thrown && JS_IsObject(r) && !JS_IsFunction(ctx, r)) {
        JSValue then = JS_GetPropertyStr(ctx, r, "then");
        if (JS_IsFunction(ctx, then)) {
            dt_show(ctx, data[0], r, false);
            /* r.then(v=>show(v,false), e=>show(e,true)) via web_then with C reactions capturing state */
            JSValueConst rd[1] = { data[0] };
            JSValue d = web_then(ctx, r, dt_then_ok, dt_then_err, 1, rd);
            JS_FreeValue(ctx, d);
            JS_FreeValue(ctx, then); JS_FreeValue(ctx, r);
            return JS_UNDEFINED;
        }
        JS_FreeValue(ctx, then);
    }
    dt_show(ctx, data[0], r, thrown);
    JS_FreeValue(ctx, r);
    return JS_UNDEFINED;
}
static JSValue dt_then_ok(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    dt_show(ctx, data[0], wj_arg(argc, (JSValue *)argv, 0), false);
    return JS_UNDEFINED;
}
static JSValue dt_then_err(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    dt_show(ctx, data[0], wj_arg(argc, (JSValue *)argv, 0), true);
    return JS_UNDEFINED;
}
/* state.complete(path): the names an expression offers (own and inherited, enumerable first), sent as \u0001dtc: */
static JSValue dt_m_complete(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    JSValue pathv = JS_ToString(ctx, wj_arg(argc, (JSValue *)argv, 0));
    const char *path = JS_ToCString(ctx, pathv);
    JSValue o;
    if (!path || path[0] == 0) { o = JS_DupValue(ctx, wj_the_realm.global); }
    else { o = JS_Eval(ctx, path, strlen(path), "<console>", JS_EVAL_TYPE_GLOBAL); if (JS_IsException(o)) { JS_FreeValue(ctx, JS_GetException(ctx)); if (path) { JS_FreeCString(ctx, path); } JS_FreeValue(ctx, pathv); return JS_UNDEFINED; } }
    if (path) { JS_FreeCString(ctx, path); }
    JS_FreeValue(ctx, pathv);
    if (JS_IsNull(o) || JS_IsUndefined(o)) { JS_FreeValue(ctx, o); return JS_UNDEFINED; }
    JSValue objc = global_prop(ctx, "Object");
    JSValue p = JS_IsObject(o) ? JS_DupValue(ctx, o) : JS_ToObject(ctx, o);
    /* a Set of seen names, a list of up to 400 */
    JSValue setc = global_prop(ctx, "Set");
    JSValue seenset = JS_CallConstructor(ctx, setc, 0, NULL);
    JS_FreeValue(ctx, setc);
    JSValue list = JS_NewArray(ctx); uint32_t nlist = 0;
    int depth = 0;
    JSValue gopn = JS_GetPropertyStr(ctx, objc, "getOwnPropertyNames");
    JSValue gpo = JS_GetPropertyStr(ctx, objc, "getPrototypeOf");
    while (JS_IsObject(p) && depth++ < 8) {
        JSValue names = JS_Call(ctx, gopn, objc, 1, (JSValueConst *)&p);
        int64_t nn = 0; JS_GetLength(ctx, names, &nn);
        for (int64_t i = 0; i < nn; i++) {
            if (nlist >= 400) { break; }
            JSValue k = JS_GetPropertyInt64(ctx, names, i);
            if (!set_has_value(ctx, seenset, k)) { set_add_value(ctx, seenset, k); JS_SetPropertyUint32(ctx, list, nlist++, JS_DupValue(ctx, k)); }
            JS_FreeValue(ctx, k);
        }
        JS_FreeValue(ctx, names);
        JSValue next = JS_Call(ctx, gpo, objc, 1, (JSValueConst *)&p);
        JS_FreeValue(ctx, p);
        p = next;
    }
    JS_FreeValue(ctx, gopn); JS_FreeValue(ctx, gpo); JS_FreeValue(ctx, p); JS_FreeValue(ctx, seenset); JS_FreeValue(ctx, objc); JS_FreeValue(ctx, o);
    /* JSON.stringify(list) */
    JSValue json = JS_JSONStringify(ctx, list, JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeValue(ctx, list);
    const char *c = JS_ToCString(ctx, json);
    web_buf msg = {0}; web_buf_puts(&msg, "\x01" "dtc:"); web_buf_puts(&msg, c ? c : "[]");
    JSValue console = global_prop(ctx, "console");
    JSValue debug = dt_orig(ctx, data[0], "debug");
    JSValueConst a = JS_NewStringLen(ctx, (const char *)(msg.p ? msg.p : (uint8_t *)""), msg.len);
    JSValue r = JS_Call(ctx, debug, console, 1, &a); JS_FreeValue(ctx, (JSValue)a); JS_FreeValue(ctx, r); JS_FreeValue(ctx, debug); JS_FreeValue(ctx, console);
    if (c) { JS_FreeCString(ctx, c); }
    web_buf_free(&msg); JS_FreeValue(ctx, json);
    return JS_UNDEFINED;
}

/* Set helpers for complete() */
static bool set_has_value(JSContext *ctx, JSValueConst set, JSValueConst v) { JSValue f = JS_GetPropertyStr(ctx, set, "has"); JSValue r = JS_Call(ctx, f, set, 1, &v); bool has = JS_ToBool(ctx, r); JS_FreeValue(ctx, r); JS_FreeValue(ctx, f); return has; }
static void set_add_value(JSContext *ctx, JSValueConst set, JSValueConst v) { JSValue f = JS_GetPropertyStr(ctx, set, "add"); JSValue r = JS_Call(ctx, f, set, 1, &v); JS_FreeValue(ctx, r); JS_FreeValue(ctx, f); }

/* the JavaScript replacer for copy(): compiled once and kept on the state as _copyReplacer */
static const char *DT_COPY_REPLACER =
    "(function(){ const stack=[]; return function(k,x){"
    "while(stack.length && stack[stack.length-1]!==this) stack.pop();"
    "if(typeof x===\"bigint\") return x+\"n\";"
    "if(typeof x===\"function\") return undefined;"
    "if(typeof x===\"symbol\") return String(x);"
    "if(x!==null && typeof x===\"object\"){"
    "if(typeof Node!==\"undefined\" && x instanceof Node) return x.nodeType===1?x.outerHTML:String(x.nodeValue!==null?x.nodeValue:x.nodeName);"
    "if(x instanceof Error) return {name:x.name,message:x.message,stack:x.stack};"
    "if(stack.indexOf(x)>=0) return \"[Circular]\";"
    "stack.push(x);"
    "if(x instanceof Map) return Array.from(x.entries());"
    "if(x instanceof Set) return Array.from(x.values());"
    "} return x; }; })()";

/* ---- install ---- */

void wj_devtools_install(JSContext *ctx)
{
    JSValue console = global_prop(ctx, "console");
    if (!JS_IsObject(console)) { JS_FreeValue(ctx, console); return; }
    JSValue logfn = JS_GetPropertyStr(ctx, console, "log");
    if (!JS_IsFunction(ctx, logfn)) { JS_FreeValue(ctx, logfn); JS_FreeValue(ctx, console); return; }
    JS_FreeValue(ctx, logfn);

    /* state = { on:false, max:262144, refs:new Map(), rid:0, temps:0, _orig:{...} } */
    JSValue state = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, state, "on", JS_FALSE);
    JS_SetPropertyStr(ctx, state, "max", JS_NewInt32(ctx, 262144));
    JSValue mapc = global_prop(ctx, "Map");
    JS_SetPropertyStr(ctx, state, "refs", JS_CallConstructor(ctx, mapc, 0, NULL));
    JS_FreeValue(ctx, mapc);
    JS_SetPropertyStr(ctx, state, "rid", JS_NewInt32(ctx, 0));
    JS_SetPropertyStr(ctx, state, "temps", JS_NewInt32(ctx, 0));
    /* _orig: the original methods, before wrapping */
    JSValue orig = JS_NewObject(ctx);
    static const char *const names[] = { "log", "info", "warn", "error", "debug", "dir", "dirxml", "table", "assert", "trace" };
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) { JS_SetPropertyStr(ctx, orig, names[i], JS_GetPropertyStr(ctx, console, names[i])); }
    JS_SetPropertyStr(ctx, state, "_orig", orig);
    /* the copy replacer */
    JSValue replacer = JS_Eval(ctx, DT_COPY_REPLACER, strlen(DT_COPY_REPLACER), "<devtools>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(replacer)) { JS_FreeValue(ctx, JS_GetException(ctx)); replacer = JS_UNDEFINED; }
    JS_SetPropertyStr(ctx, state, "_copyReplacer", replacer);

    /* console[Symbol.for("wren.devtools")] = state (hidden) */
    JSAtom sa = dt_symbol_atom(ctx);
    JS_DefinePropertyValue(ctx, console, sa, JS_DupValue(ctx, state), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
    JS_FreeAtom(ctx, sa);

    /* wrap log/info/warn/error/debug/dir/dirxml (level: dir/dirxml -> log) */
    static const char *const wrapped[] = { "log", "info", "warn", "error", "debug", "dir", "dirxml" };
    JSValue origobj = JS_GetPropertyStr(ctx, state, "_orig");
    for (size_t i = 0; i < sizeof wrapped / sizeof wrapped[0]; i++) {
        const char *m = wrapped[i];
        const char *level = (strcmp(m, "dir") == 0 || strcmp(m, "dirxml") == 0) ? "log" : m;
        JSValue f = JS_GetPropertyStr(ctx, origobj, m);
        JSValue data[3] = { JS_DupValue(ctx, state), JS_NewString(ctx, level), f };
        JSValue wrapper = JS_NewCFunctionData(ctx, dt_console_wrapper, 0, 0, 3, data);
        /* name it after the method, length 0 */
        JS_DefinePropertyValueStr(ctx, wrapper, "name", JS_NewString(ctx, m), JS_PROP_CONFIGURABLE);
        JS_FreeValue(ctx, data[0]); JS_FreeValue(ctx, data[1]); JS_FreeValue(ctx, data[2]);
        JS_DefinePropertyValueStr(ctx, console, m, wrapper, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE);
    }
    /* table */
    {
        JSValue f = JS_GetPropertyStr(ctx, origobj, "table");
        JSValue data[2] = { JS_DupValue(ctx, state), f };
        JSValue wrapper = JS_NewCFunctionData(ctx, dt_console_table, 0, 0, 2, data);
        JS_DefinePropertyValueStr(ctx, wrapper, "name", JS_NewString(ctx, "table"), JS_PROP_CONFIGURABLE);
        JS_FreeValue(ctx, data[0]); JS_FreeValue(ctx, data[1]);
        JS_DefinePropertyValueStr(ctx, console, "table", wrapper, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE);
    }
    /* assert (magic 1) */
    {
        JSValue f = JS_GetPropertyStr(ctx, origobj, "assert");
        JSValue data[3] = { JS_DupValue(ctx, state), JS_NewString(ctx, "error"), f };
        JSValue wrapper = JS_NewCFunctionData(ctx, dt_console_wrapper, 0, 1, 3, data);
        JS_DefinePropertyValueStr(ctx, wrapper, "name", JS_NewString(ctx, "assert"), JS_PROP_CONFIGURABLE);
        JS_FreeValue(ctx, data[0]); JS_FreeValue(ctx, data[1]); JS_FreeValue(ctx, data[2]);
        JS_DefinePropertyValueStr(ctx, console, "assert", wrapper, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE);
    }
    JS_FreeValue(ctx, origobj);

    /* state methods: eval, store, storeNode, copy, complete */
    JSValueConst d1[1] = { state };
    JS_SetPropertyStr(ctx, state, "eval", JS_NewCFunctionData(ctx, dt_m_eval, 1, 0, 1, d1));
    JS_SetPropertyStr(ctx, state, "store", JS_NewCFunctionData(ctx, dt_m_store, 1, 0, 1, d1));
    JS_SetPropertyStr(ctx, state, "storeNode", JS_NewCFunctionData(ctx, dt_m_store_node, 1, 0, 1, d1));
    JS_SetPropertyStr(ctx, state, "copy", JS_NewCFunctionData(ctx, dt_m_copy, 1, 0, 1, d1));
    JS_SetPropertyStr(ctx, state, "complete", JS_NewCFunctionData(ctx, dt_m_complete, 1, 0, 1, d1));

    JS_FreeValue(ctx, state);
    JS_FreeValue(ctx, console);
}
