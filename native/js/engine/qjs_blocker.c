/* qjs_blocker.c: the content blocker's scriptlets that change what a JavaScript API does (set-constant, abort-on-property-read /
 * write, abort-current-script, abort-on-stack-trace, no-setTimeout-if, no-setInterval-if, the nano boosters, no-fetch-if, no-xhr-if,
 * addEventListener-defuser, window.open-defuser, noeval, nowebrtc, json-prune on JSON.parse), installed in the realm before the page's
 * first script as NATIVE hooks: accessor properties and replaced functions that are C functions of the engine (no interpreted wrapper,
 * no JavaScript source for the blocker to compile or run), deciding with the page's values (function text, current script, arguments)
 * in C. A call of a hooked API the rule does not concern costs the check and the call of the original: tens of nanoseconds.
 *
 * The browser sends the rules once, as text (wj_hook_install): records separated by 0x1e, fields by 0x1f, the first field the canonical
 * scriptlet name of uBlock Origin, then its arguments as written in the filter. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "quickjs.h"
#include "wj.h"
#include "qjs_internal.h"

/* ---- patterns: `text`, `/regex/flags`, `!text` (negated); empty matches everything ---- */

typedef struct needle {
    int mode;   /* 0 any, 1 text, 2 regex, 3 never (a regex that does not compile) */
    bool neg;
    char *text;
    JSValue re;
} needle;

static void clear_exception(JSContext *ctx) { JS_FreeValue(ctx, JS_GetException(ctx)); }

static void needle_init(JSContext *ctx, needle *n, const char *p)
{
    memset(n, 0, sizeof *n);
    n->re = JS_UNDEFINED;
    if (!p || !*p) { n->mode = 0; return; }
    if (*p == '!') { n->neg = true; p++; }
    size_t len = strlen(p);
    if (len >= 2 && p[0] == '/') {
        const char *end = strrchr(p, '/');
        if (end && end > p) {
            char flags[16];
            size_t fi = 0;
            bool ok = true;
            for (const char *f = end + 1; *f; f++) {
                if (!strchr("gimsuyd", *f) || fi + 1 >= sizeof flags) { ok = false; break; }
                if (*f != 'g' && *f != 'y') { flags[fi++] = *f; }
            }
            flags[fi] = 0;
            if (ok) {
                JSValue g = JS_GetGlobalObject(ctx);
                JSValue ctor = JS_GetPropertyStr(ctx, g, "RegExp");
                JSValue args[2] = { JS_NewStringLen(ctx, p + 1, (size_t)(end - p - 1)), JS_NewString(ctx, flags) };
                JSValue re = JS_CallConstructor(ctx, ctor, 2, args);
                JS_FreeValue(ctx, args[0]);
                JS_FreeValue(ctx, args[1]);
                JS_FreeValue(ctx, ctor);
                JS_FreeValue(ctx, g);
                if (JS_IsException(re)) { clear_exception(ctx); n->mode = 3; } else { n->mode = 2; n->re = re; }
                return;
            }
        }
    }
    n->mode = 1;
    n->text = strdup(p);
}

static bool needle_test(JSContext *ctx, const needle *n, const char *s)
{
    if (n->mode == 0) { return true; }
    bool hit = false;
    if (n->mode == 1) {
        hit = strstr(s, n->text) != NULL;
    } else if (n->mode == 2) {
        JSValue str = JS_NewString(ctx, s);
        JSAtom a = JS_NewAtom(ctx, "test");
        JSValue r = JS_Invoke(ctx, n->re, a, 1, &str);
        JS_FreeAtom(ctx, a);
        JS_FreeValue(ctx, str);
        if (JS_IsException(r)) { clear_exception(ctx); } else { hit = JS_ToBool(ctx, r) > 0; }
        JS_FreeValue(ctx, r);
    }
    return hit != n->neg;
}

static bool needle_test_value(JSContext *ctx, const needle *n, JSValueConst v)
{
    if (n->mode == 0) { return true; }
    const char *s = JS_ToCString(ctx, v);
    if (!s) { clear_exception(ctx); return needle_test(ctx, n, ""); }
    bool r = needle_test(ctx, n, s);
    JS_FreeCString(ctx, s);
    return r;
}

/* ---- rules ---- */

enum { R_SET_CONST, R_AOPR, R_AOPW, R_ACS, R_AOST, R_TIMER, R_BOOST, R_FETCH, R_XHR, R_AELD, R_WOPEN, R_JSON };

typedef struct ftest { char *key; needle n; } ftest;

typedef struct rule {
    int kind;
    char **parts;
    int nparts;
    needle n1, n2;
    JSValue val;
    char *delay;      /* timers: the delay to match ("" or NULL: any) */
    double boost;
    ftest *tests;
    int ntests;
    bool body_empty;  /* no-fetch-if: "emptyStr" */
    bool replace_obj; /* window.open-defuser: return an object */
    bool aborted;     /* set-constant: only when the property exists */
    char **paths[16];
    int plen[16];
    int npaths;
    char **req[16];
    int rlen[16];
    int nreq;
} rule;

static rule **rules;
static int nrules, caprules;

static rule *new_rule(int kind)
{
    if (nrules == caprules) {
        caprules = caprules ? caprules * 2 : 16;
        rules = realloc(rules, (size_t)caprules * sizeof *rules);
    }
    rule *r = calloc(1, sizeof *r);
    r->kind = kind;
    r->val = JS_UNDEFINED;
    rules[nrules++] = r;
    return r;
}

static char **split_chars(const char *s, const char *seps, int *count)
{
    char **out = NULL;
    int n = 0;
    const char *p = s;
    while (*p) {
        while (*p && strchr(seps, *p)) { p++; }
        if (!*p) { break; }
        const char *q = p;
        while (*q && !strchr(seps, *q)) { q++; }
        out = realloc(out, (size_t)(n + 1) * sizeof *out);
        out[n++] = strndup(p, (size_t)(q - p));
        p = q;
    }
    *count = n;
    return out;
}

static bool is_object(JSValueConst v) { return JS_IsObject(v); }

/* ---- small natives ---- */

static JSValue fn_noop(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return JS_UNDEFINED; }
static JSValue fn_true(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return JS_TRUE; }
static JSValue fn_false(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return JS_FALSE; }

static uint32_t rng_state = 0x9e3779b9u;
static uint32_t next_rand(void)
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

static JSValue reference_error(JSContext *ctx)
{
    char name[13];
    for (int i = 0; i < 12; i++) { name[i] = (char)('a' + (int)(next_rand() % 26)); }
    name[12] = 0;
    return JS_ThrowReferenceError(ctx, "%s is not defined", name);
}

static JSValue fn_throw(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return reference_error(ctx); }

static JSValue promise_static(JSContext *ctx, const char *method, JSValue arg)
{
    JSValue g = JS_GetGlobalObject(ctx);
    JSValue P = JS_GetPropertyStr(ctx, g, "Promise");
    JSAtom a = JS_NewAtom(ctx, method);
    JSValue r = JS_Invoke(ctx, P, a, JS_IsUndefined(arg) ? 0 : 1, &arg);
    JS_FreeAtom(ctx, a);
    JS_FreeValue(ctx, P);
    JS_FreeValue(ctx, g);
    JS_FreeValue(ctx, arg);
    return r;
}

static JSValue fn_resolve_empty(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return promise_static(ctx, "resolve", JS_NewObject(ctx)); }
static JSValue fn_reject_undef(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return promise_static(ctx, "reject", JS_UNDEFINED); }
static JSValue fn_resolve_undef(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return promise_static(ctx, "resolve", JS_UNDEFINED); }

/* The value a scriptlet names (`set-constant`'s second argument). */
static JSValue to_value(JSContext *ctx, const char *v)
{
    if (!strcmp(v, "undefined")) { return JS_UNDEFINED; }
    if (!strcmp(v, "false")) { return JS_FALSE; }
    if (!strcmp(v, "true")) { return JS_TRUE; }
    if (!strcmp(v, "null")) { return JS_NULL; }
    if (!strcmp(v, "emptyObj")) { return JS_NewObject(ctx); }
    if (!strcmp(v, "emptyArr")) { return JS_NewArray(ctx); }
    if (!strcmp(v, "noopFunc")) { return JS_NewCFunction(ctx, fn_noop, "", 0); }
    if (!strcmp(v, "trueFunc")) { return JS_NewCFunction(ctx, fn_true, "", 0); }
    if (!strcmp(v, "falseFunc")) { return JS_NewCFunction(ctx, fn_false, "", 0); }
    if (!strcmp(v, "throwFunc")) { return JS_NewCFunction(ctx, fn_throw, "", 0); }
    if (!strcmp(v, "noopPromiseResolve")) { return JS_NewCFunction(ctx, fn_resolve_empty, "", 0); }
    if (!strcmp(v, "noopPromiseReject")) { return JS_NewCFunction(ctx, fn_reject_undef, "", 0); }
    if (!strcmp(v, "NaN")) { return JS_NewFloat64(ctx, NAN); }
    if (!strcmp(v, "Infinity")) { return JS_NewFloat64(ctx, INFINITY); }
    if (!strcmp(v, "-Infinity")) { return JS_NewFloat64(ctx, -INFINITY); }
    char *end;
    double d = strtod(v, &end);
    if (*v && !*end && fabs(d) <= 32767) { return JS_NewFloat64(ctx, d); }
    return JS_NewString(ctx, v);
}

/* ---- the current script, the call stack ---- */

static bool current_script_matches(JSContext *ctx, const needle *n)
{
    JSValue g = JS_GetGlobalObject(ctx);
    JSValue doc = JS_GetPropertyStr(ctx, g, "document");
    JSValue cs = JS_IsObject(doc) ? JS_GetPropertyStr(ctx, doc, "currentScript") : JS_UNDEFINED;
    bool r;
    if (!JS_IsObject(cs)) {
        r = n->mode == 0;
    } else if (n->mode == 0) {
        r = true;
    } else {
        JSValue text = JS_GetPropertyStr(ctx, cs, "textContent");
        JSValue src = JS_GetPropertyStr(ctx, cs, "src");
        r = needle_test_value(ctx, n, text) || needle_test_value(ctx, n, src);
        JS_FreeValue(ctx, text);
        JS_FreeValue(ctx, src);
    }
    JS_FreeValue(ctx, cs);
    JS_FreeValue(ctx, doc);
    JS_FreeValue(ctx, g);
    return r;
}

static bool stack_matches(JSContext *ctx, const needle *n)
{
    if (n->mode == 0) { return true; }
    JSValue e = JS_NewError(ctx);
    JSValue s = JS_GetPropertyStr(ctx, e, "stack");
    bool r = needle_test_value(ctx, n, s);
    JS_FreeValue(ctx, s);
    JS_FreeValue(ctx, e);
    return r;
}

/* ---- property paths: set-constant, abort-on-property-read / write, abort-current-script, abort-on-stack-trace ---- */

static void trap_walk(JSContext *ctx, JSValueConst owner, int ri, int i);

/* The accessors at the end of a path. data[0] the rule index, data[1] the holder object (property v). magic: bit 0 setter. */
static JSValue leaf_accessor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *d)
{
    rule *r = rules[JS_VALUE_GET_INT(d[0])];
    bool setter = magic & 1;
    switch (r->kind) {
    case R_SET_CONST:
        return setter ? JS_UNDEFINED : JS_DupValue(ctx, r->val);
    case R_AOPR:
        return setter ? JS_UNDEFINED : reference_error(ctx);
    case R_AOPW:
        if (setter) { return reference_error(ctx); }
        return JS_GetPropertyStr(ctx, d[1], "v");
    case R_ACS:
        if (current_script_matches(ctx, &r->n1)) { return reference_error(ctx); }
        break;
    case R_AOST:
        if (stack_matches(ctx, &r->n1)) { return reference_error(ctx); }
        break;
    }
    if (setter) {
        JS_SetPropertyStr(ctx, d[1], "v", JS_DupValue(ctx, argc > 0 ? argv[0] : JS_UNDEFINED));
        return JS_UNDEFINED;
    }
    return JS_GetPropertyStr(ctx, d[1], "v");
}

static void leaf_install(JSContext *ctx, JSValueConst owner, const char *prop, int ri)
{
    rule *r = rules[ri];
    JSAtom atom = JS_NewAtom(ctx, prop);
    if (r->kind == R_SET_CONST && r->aborted && JS_HasProperty(ctx, owner, atom) <= 0) {
        JS_FreeAtom(ctx, atom);
        if (JS_HasException(ctx)) { clear_exception(ctx); }
        return;
    }
    JSValue holder = JS_NewObject(ctx);
    JSValue cur = JS_UNDEFINED;
    if (r->kind == R_AOPW || r->kind == R_ACS || r->kind == R_AOST) {
        cur = JS_GetProperty(ctx, owner, atom);
        if (JS_IsException(cur)) { clear_exception(ctx); cur = JS_UNDEFINED; }
    }
    JS_SetPropertyStr(ctx, holder, "v", cur);
    JSValue data[2] = { JS_NewInt32(ctx, ri), holder };
    JSValue get = JS_NewCFunctionData(ctx, leaf_accessor, 0, 0, 2, data);
    JSValue set = JS_NewCFunctionData(ctx, leaf_accessor, 1, 1, 2, data);
    JS_FreeValue(ctx, holder);
    if (JS_DefinePropertyGetSet(ctx, owner, atom, get, set, JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE) < 0) { clear_exception(ctx); }
    JS_FreeAtom(ctx, atom);
}

/* An intermediate object that does not exist yet: remember what is assigned and walk into it. data[0] rule, data[1] depth, data[2] holder. */
static JSValue mid_accessor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *d)
{
    if (!(magic & 1)) { return JS_GetPropertyStr(ctx, d[2], "v"); }
    JSValueConst v = argc > 0 ? argv[0] : JS_UNDEFINED;
    JS_SetPropertyStr(ctx, d[2], "v", JS_DupValue(ctx, v));
    if (is_object(v)) { trap_walk(ctx, v, JS_VALUE_GET_INT(d[0]), JS_VALUE_GET_INT(d[1]) + 1); }
    return JS_UNDEFINED;
}

static void trap_walk(JSContext *ctx, JSValueConst owner, int ri, int i)
{
    rule *r = rules[ri];
    const char *prop = r->parts[i];
    if (i == r->nparts - 1) { leaf_install(ctx, owner, prop, ri); return; }
    JSAtom atom = JS_NewAtom(ctx, prop);
    JSValue cur = JS_GetProperty(ctx, owner, atom);
    if (JS_IsException(cur)) { clear_exception(ctx); JS_FreeAtom(ctx, atom); return; }
    if (is_object(cur)) { trap_walk(ctx, cur, ri, i + 1); JS_FreeValue(ctx, cur); JS_FreeAtom(ctx, atom); return; }
    JSPropertyDescriptor desc;
    int has = JS_GetOwnProperty(ctx, &desc, owner, atom);
    if (has > 0) {
        bool fixed = !(desc.flags & JS_PROP_CONFIGURABLE);
        JS_FreeValue(ctx, desc.value); JS_FreeValue(ctx, desc.getter); JS_FreeValue(ctx, desc.setter);
        if (fixed) { JS_FreeValue(ctx, cur); JS_FreeAtom(ctx, atom); return; }
    }
    JSValue holder = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, holder, "v", cur);
    JSValue data[3] = { JS_NewInt32(ctx, ri), JS_NewInt32(ctx, i), holder };
    JSValue get = JS_NewCFunctionData(ctx, mid_accessor, 0, 0, 3, data);
    JSValue set = JS_NewCFunctionData(ctx, mid_accessor, 1, 1, 3, data);
    JS_FreeValue(ctx, holder);
    if (JS_DefinePropertyGetSet(ctx, owner, atom, get, set, JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE) < 0) { clear_exception(ctx); }
    JS_FreeAtom(ctx, atom);
}

/* ---- timers ---- */

static bool delay_matches(JSContext *ctx, const char *want, JSValueConst d)
{
    if (!want || !*want) { return true; }
    const char *s = JS_ToCString(ctx, d);
    if (!s) { clear_exception(ctx); return false; }
    bool r;
    if (want[0] == '!') { r = strcmp(s, want + 1) != 0; } else { r = strcmp(s, want) == 0; }
    JS_FreeCString(ctx, s);
    return r;
}

/* data[0] the original, data[1] the rule index; magic 0: no-setTimeout/Interval-if, 1: the nano booster */
static JSValue timer_hook(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *d)
{
    rule *r = rules[JS_VALUE_GET_INT(d[1])];
    JSValueConst cb = argc > 0 ? argv[0] : JS_UNDEFINED;
    JSValueConst dl = argc > 1 ? argv[1] : JS_UNDEFINED;
    if (needle_test_value(ctx, &r->n1, cb)) {
        if (magic == 0) {
            if (delay_matches(ctx, r->delay, dl)) { return JS_NewInt32(ctx, 0); }
        } else {
            double x = 0;
            bool any = !r->delay || !*r->delay || !strcmp(r->delay, "*");
            if (JS_ToFloat64(ctx, &x, dl) < 0) { clear_exception(ctx); x = NAN; }
            if (any || x == atof(r->delay)) {
                JSValue copy[16];
                int n = argc < 16 ? argc : 16;
                for (int i = 0; i < n; i++) { copy[i] = JS_DupValue(ctx, argv[i]); }
                if (n > 1) {
                    JS_FreeValue(ctx, copy[1]);
                    double nd = floor(x * r->boost);
                    copy[1] = JS_NewFloat64(ctx, nd > 0 ? nd : 0);
                }
                JSValue res = JS_Call(ctx, d[0], this_val, n, copy);
                for (int i = 0; i < n; i++) { JS_FreeValue(ctx, copy[i]); }
                return res;
            }
        }
    }
    return JS_Call(ctx, d[0], this_val, argc, argv);
}

static JSValue wrap_global_function(JSContext *ctx, JSValueConst owner, const char *prop, JSCFunctionData *fn, int ri, int magic, int length)
{
    JSValue orig = JS_GetPropertyStr(ctx, owner, prop);
    if (!JS_IsFunction(ctx, orig)) { JS_FreeValue(ctx, orig); return JS_UNDEFINED; }
    JSValue data[2] = { orig, JS_NewInt32(ctx, ri) };
    JSValue w = JS_NewCFunctionData2(ctx, fn, prop, length, magic, 2, data);
    JS_FreeValue(ctx, orig);
    return w;
}

static void replace_property(JSContext *ctx, JSValueConst owner, const char *prop, JSValue w)
{
    if (JS_IsUndefined(w)) { return; }
    JSAtom a = JS_NewAtom(ctx, prop);
    if (JS_DefinePropertyValue(ctx, owner, a, w, JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE) < 0) { clear_exception(ctx); }
    JS_FreeAtom(ctx, a);
}

/* ---- fetch and XMLHttpRequest ---- */

static void tests_init(JSContext *ctx, rule *r, const char *needle_arg)
{
    int n = 0;
    char **parts = split_chars(needle_arg ? needle_arg : "", " \t", &n);
    r->tests = calloc((size_t)(n ? n : 1), sizeof *r->tests);
    for (int i = 0; i < n; i++) {
        char *colon = strchr(parts[i], ':');
        bool key = colon && colon > parts[i];
        if (key) { for (char *c = parts[i]; c < colon; c++) { if (*c < 'a' || *c > 'z') { key = false; } } }
        if (key) { *colon = 0; r->tests[i].key = strdup(parts[i]); needle_init(ctx, &r->tests[i].n, colon + 1); }
        else { r->tests[i].key = strdup("url"); needle_init(ctx, &r->tests[i].n, parts[i]); }
        free(parts[i]);
    }
    free(parts);
    r->ntests = n;
}

static JSValue prop_of(JSContext *ctx, JSValueConst o, const char *name)
{
    if (!is_object(o)) { return JS_UNDEFINED; }
    JSValue v = JS_GetPropertyStr(ctx, o, name);
    if (JS_IsException(v)) { clear_exception(ctx); return JS_UNDEFINED; }
    return v;
}

static bool test_value_str(JSContext *ctx, const needle *n, JSValueConst v, const char *dflt)
{
    if (JS_IsUndefined(v) || JS_IsNull(v)) { return needle_test(ctx, n, dflt); }
    return needle_test_value(ctx, n, v);
}

static JSValue fetch_hook(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *d)
{
    rule *r = rules[JS_VALUE_GET_INT(d[1])];
    JSValueConst input = argc > 0 ? argv[0] : JS_UNDEFINED;
    JSValueConst init = argc > 1 ? argv[1] : JS_UNDEFINED;
    bool all = true;
    for (int i = 0; i < r->ntests && all; i++) {
        const char *k = r->tests[i].key;
        JSValue v = JS_UNDEFINED;
        bool ok;
        if (!strcmp(k, "url")) {
            v = JS_IsString(input) ? JS_DupValue(ctx, input) : prop_of(ctx, input, "url");
            ok = test_value_str(ctx, &r->tests[i].n, v, "");
        } else if (!strcmp(k, "method")) {
            v = prop_of(ctx, init, "method");
            if (JS_IsUndefined(v)) { JS_FreeValue(ctx, v); v = prop_of(ctx, input, "method"); }
            ok = test_value_str(ctx, &r->tests[i].n, v, "GET");
        } else {
            v = prop_of(ctx, init, k);
            ok = test_value_str(ctx, &r->tests[i].n, v, "");
        }
        JS_FreeValue(ctx, v);
        all = ok;
    }
    if (!all) { return JS_Call(ctx, d[0], this_val, argc, argv); }
    JSValue g = JS_GetGlobalObject(ctx);
    JSValue R = JS_GetPropertyStr(ctx, g, "Response");
    JSValue resp = JS_UNDEFINED;
    if (JS_IsFunction(ctx, R)) {
        JSValue args[2] = { JS_NewString(ctx, r->body_empty ? "" : "{}"), JS_NewObject(ctx) };
        JS_SetPropertyStr(ctx, args[1], "status", JS_NewInt32(ctx, 200));
        JS_SetPropertyStr(ctx, args[1], "statusText", JS_NewString(ctx, "OK"));
        resp = JS_CallConstructor(ctx, R, 2, args);
        JS_FreeValue(ctx, args[0]);
        JS_FreeValue(ctx, args[1]);
        if (JS_IsException(resp)) { clear_exception(ctx); resp = JS_UNDEFINED; }
    }
    if (JS_IsUndefined(resp)) { resp = JS_NewObject(ctx); }
    JS_FreeValue(ctx, R);
    JS_FreeValue(ctx, g);
    return promise_static(ctx, "resolve", resp);
}

/* XMLHttpRequest: open records the method and URL, send is answered when they match. */
static JSValue xhr_open_hook(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *d)
{
    if (is_object(this_val)) {
        JS_DefinePropertyValueStr(ctx, this_val, "__wbm", argc > 0 ? JS_DupValue(ctx, argv[0]) : JS_UNDEFINED, JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE);
        JS_DefinePropertyValueStr(ctx, this_val, "__wbu", argc > 1 ? JS_DupValue(ctx, argv[1]) : JS_UNDEFINED, JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE);
    }
    return JS_Call(ctx, d[0], this_val, argc, argv);
}

static JSValue xhr_events(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *d)
{
    JSValueConst xhr = d[0];
    JSValue g = JS_GetGlobalObject(ctx);
    JSValue E = JS_GetPropertyStr(ctx, g, "Event");
    static const char *names[3] = { "readystatechange", "load", "loadend" };
    JSValue h = JS_GetPropertyStr(ctx, xhr, "onreadystatechange");
    if (JS_IsFunction(ctx, h)) { JSValue r = JS_Call(ctx, h, xhr, 0, NULL); if (JS_IsException(r)) { clear_exception(ctx); } JS_FreeValue(ctx, r); }
    JS_FreeValue(ctx, h);
    for (int i = 0; i < 3 && JS_IsFunction(ctx, E); i++) {
        JSValue name = JS_NewString(ctx, names[i]);
        JSValue ev = JS_CallConstructor(ctx, E, 1, &name);
        JS_FreeValue(ctx, name);
        if (JS_IsException(ev)) { clear_exception(ctx); continue; }
        JSAtom a = JS_NewAtom(ctx, "dispatchEvent");
        JSValue r = JS_Invoke(ctx, xhr, a, 1, &ev);
        JS_FreeAtom(ctx, a);
        if (JS_IsException(r)) { clear_exception(ctx); }
        JS_FreeValue(ctx, r);
        JS_FreeValue(ctx, ev);
    }
    JS_FreeValue(ctx, E);
    JS_FreeValue(ctx, g);
    return JS_UNDEFINED;
}

static JSValue xhr_send_hook(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *d)
{
    rule *r = rules[JS_VALUE_GET_INT(d[1])];
    bool all = is_object(this_val);
    for (int i = 0; i < r->ntests && all; i++) {
        JSValue v = JS_GetPropertyStr(ctx, this_val, !strcmp(r->tests[i].key, "method") ? "__wbm" : "__wbu");
        all = test_value_str(ctx, &r->tests[i].n, v, "");
        JS_FreeValue(ctx, v);
    }
    if (!all) { return JS_Call(ctx, d[0], this_val, argc, argv); }
    static const char *props[4] = { "readyState", "status", "responseText", "response" };
    for (int i = 0; i < 4; i++) {
        JSValue v = i == 0 ? JS_NewInt32(ctx, 4) : (i == 1 ? JS_NewInt32(ctx, 200) : JS_NewString(ctx, ""));
        JS_DefinePropertyValueStr(ctx, this_val, props[i], v, JS_PROP_CONFIGURABLE);
    }
    JSValue g = JS_GetGlobalObject(ctx);
    JSValue st = JS_GetPropertyStr(ctx, g, "setTimeout");
    if (JS_IsFunction(ctx, st)) {
        JSValue data[1] = { JS_DupValue(ctx, this_val) };
        JSValue cb = JS_NewCFunctionData(ctx, xhr_events, 0, 0, 1, data);
        JS_FreeValue(ctx, data[0]);
        JSValue args[2] = { cb, JS_NewInt32(ctx, 1) };
        JSValue t = JS_Call(ctx, st, g, 2, args);
        JS_FreeValue(ctx, t);
        JS_FreeValue(ctx, cb);
    }
    JS_FreeValue(ctx, st);
    JS_FreeValue(ctx, g);
    return JS_UNDEFINED;
}

/* ---- addEventListener, window.open ---- */

static JSValue aeld_hook(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *d)
{
    rule *r = rules[JS_VALUE_GET_INT(d[1])];
    if (argc >= 2 && needle_test_value(ctx, &r->n1, argv[0])) {
        JSValue src = JS_UNDEFINED;
        if (JS_IsFunction(ctx, argv[1])) { src = JS_DupValue(ctx, argv[1]); } else if (is_object(argv[1])) { src = JS_GetPropertyStr(ctx, argv[1], "handleEvent"); }
        bool hit = r->n2.mode == 0 || (JS_IsFunction(ctx, src) && needle_test_value(ctx, &r->n2, src)) || (!JS_IsFunction(ctx, src) && needle_test(ctx, &r->n2, ""));
        JS_FreeValue(ctx, src);
        if (hit) { return JS_UNDEFINED; }
    }
    return JS_Call(ctx, d[0], this_val, argc, argv);
}

static JSValue wopen_hook(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *d)
{
    rule *r = rules[JS_VALUE_GET_INT(d[1])];
    bool hit = argc > 0 ? needle_test_value(ctx, &r->n1, argv[0]) : needle_test(ctx, &r->n1, "");
    if (!hit) { return JS_Call(ctx, d[0], this_val, argc, argv); }
    if (!r->replace_obj) { return JS_NULL; }
    JSValue o = JS_NewObject(ctx);
    static const char *noops[5] = { "close", "focus", "blur", "postMessage", "open" };
    for (int i = 0; i < 5; i++) { JS_SetPropertyStr(ctx, o, noops[i], JS_NewCFunction(ctx, fn_noop, noops[i], 0)); }
    return o;
}

/* ---- noeval, nowebrtc ---- */

static JSValue webrtc_stub(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue o = JS_NewObject(ctx);
    static const char *noops[3] = { "close", "addEventListener", "removeEventListener" };
    static const char *proms[4] = { "createOffer", "createAnswer", "setLocalDescription", "setRemoteDescription" };
    for (int i = 0; i < 3; i++) { JS_SetPropertyStr(ctx, o, noops[i], JS_NewCFunction(ctx, fn_noop, noops[i], 0)); }
    for (int i = 0; i < 4; i++) { JS_SetPropertyStr(ctx, o, proms[i], JS_NewCFunction(ctx, fn_resolve_undef, proms[i], 0)); }
    JS_SetPropertyStr(ctx, o, "createDataChannel", JS_NewCFunction(ctx, fn_noop, "createDataChannel", 0));
    return o;
}

/* ---- json-prune on JSON.parse ---- */

static bool path_rec(JSContext *ctx, JSValueConst o, char **parts, int n, int i, bool del, int depth)
{
    if (!is_object(o) || depth > 12) { return false; }
    const char *key = parts[i];
    bool wild = !strcmp(key, "*") || !strcmp(key, "[]") || !strcmp(key, "[-]");
    bool last = i == n - 1;
    bool hit = false;
    if (wild) {
        JSPropertyEnum *tab;
        uint32_t len;
        if (JS_GetOwnPropertyNames(ctx, &tab, &len, o, JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) < 0) { clear_exception(ctx); return false; }
        for (uint32_t k = 0; k < len; k++) {
            if (last) { hit = true; if (del) { JS_DeleteProperty(ctx, o, tab[k].atom, 0); } }
            else {
                JSValue child = JS_GetProperty(ctx, o, tab[k].atom);
                if (path_rec(ctx, child, parts, n, i + 1, del, depth + 1)) { hit = true; }
                JS_FreeValue(ctx, child);
            }
        }
        JS_FreePropertyEnum(ctx, tab, len);
        return hit;
    }
    JSAtom a = JS_NewAtom(ctx, key);
    int has = JS_HasProperty(ctx, o, a);
    if (has > 0) {
        if (last) { hit = true; if (del) { JS_DeleteProperty(ctx, o, a, 0); } }
        else {
            JSValue child = JS_GetProperty(ctx, o, a);
            hit = path_rec(ctx, child, parts, n, i + 1, del, depth + 1);
            JS_FreeValue(ctx, child);
        }
    } else if (has < 0) { clear_exception(ctx); }
    JS_FreeAtom(ctx, a);
    return hit;
}

static JSValue json_hook(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *d)
{
    rule *r = rules[JS_VALUE_GET_INT(d[1])];
    JSValue res = JS_Call(ctx, d[0], this_val, argc, argv);
    if (JS_IsException(res) || !is_object(res)) { return res; }
    if (r->n1.mode != 0 && !stack_matches(ctx, &r->n1)) { return res; }
    for (int i = 0; i < r->nreq; i++) { if (!path_rec(ctx, res, r->req[i], r->rlen[i], 0, false, 0)) { return res; } }
    for (int i = 0; i < r->npaths; i++) { path_rec(ctx, res, r->paths[i], r->plen[i], 0, true, 0); }
    return res;
}

/* ---- installation ---- */

static void paths_init(char ***dst, int *lens, int *count, const char *spec)
{
    int n = 0;
    char **words = split_chars(spec ? spec : "", " \t\r\n", &n);
    for (int i = 0; i < n && *count < 16; i++) {
        int k = 0;
        dst[*count] = split_chars(words[i], ".", &k);
        lens[*count] = k;
        if (k > 0) { (*count)++; }
        free(words[i]);
    }
    free(words);
}

static const char *argn(const char **a, int n, int i) { return i < n ? a[i] : ""; }

static void install_rule(JSContext *ctx, const char *name, const char **a, int n)
{
    JSValue g = JS_GetGlobalObject(ctx);
    if (!strcmp(name, "set-constant") || !strcmp(name, "abort-on-property-read") || !strcmp(name, "abort-on-property-write") ||
        !strcmp(name, "abort-current-script") || !strcmp(name, "abort-on-stack-trace")) {
        int kind = !strcmp(name, "set-constant") ? R_SET_CONST : !strcmp(name, "abort-on-property-read") ? R_AOPR :
                   !strcmp(name, "abort-on-property-write") ? R_AOPW : !strcmp(name, "abort-current-script") ? R_ACS : R_AOST;
        if (!*argn(a, n, 0)) { JS_FreeValue(ctx, g); return; }
        rule *r = new_rule(kind);
        r->parts = split_chars(argn(a, n, 0), ".", &r->nparts);
        if (r->nparts == 0) { JS_FreeValue(ctx, g); return; }
        if (kind == R_SET_CONST) {
            r->val = to_value(ctx, n > 1 ? a[1] : "undefined");
            r->aborted = !strcmp(argn(a, n, 2), "aborted");
        } else if (kind == R_ACS || kind == R_AOST) {
            needle_init(ctx, &r->n1, argn(a, n, 1));
        }
        trap_walk(ctx, g, nrules - 1, 0);
    } else if (!strcmp(name, "no-setTimeout-if") || !strcmp(name, "no-setInterval-if")) {
        rule *r = new_rule(R_TIMER);
        needle_init(ctx, &r->n1, argn(a, n, 0));
        r->delay = strdup(argn(a, n, 1));
        const char *prop = !strcmp(name, "no-setTimeout-if") ? "setTimeout" : "setInterval";
        replace_property(ctx, g, prop, wrap_global_function(ctx, g, prop, timer_hook, nrules - 1, 0, 2));
    } else if (!strcmp(name, "nano-setTimeout-booster") || !strcmp(name, "nano-setInterval-booster")) {
        rule *r = new_rule(R_BOOST);
        needle_init(ctx, &r->n1, argn(a, n, 0));
        r->delay = strdup(argn(a, n, 1));
        double b = *argn(a, n, 2) ? atof(a[2]) : 0.05;
        r->boost = (b >= 0.001 && b <= 50) ? b : 0.05;
        const char *prop = !strcmp(name, "nano-setTimeout-booster") ? "setTimeout" : "setInterval";
        replace_property(ctx, g, prop, wrap_global_function(ctx, g, prop, timer_hook, nrules - 1, 1, 2));
    } else if (!strcmp(name, "no-fetch-if")) {
        rule *r = new_rule(R_FETCH);
        tests_init(ctx, r, argn(a, n, 0));
        r->body_empty = !strcmp(argn(a, n, 1), "emptyStr");
        replace_property(ctx, g, "fetch", wrap_global_function(ctx, g, "fetch", fetch_hook, nrules - 1, 0, 1));
    } else if (!strcmp(name, "no-xhr-if")) {
        rule *r = new_rule(R_XHR);
        tests_init(ctx, r, argn(a, n, 0));
        JSValue X = JS_GetPropertyStr(ctx, g, "XMLHttpRequest");
        JSValue proto = JS_IsObject(X) ? JS_GetPropertyStr(ctx, X, "prototype") : JS_UNDEFINED;
        if (is_object(proto)) {
            replace_property(ctx, proto, "open", wrap_global_function(ctx, proto, "open", xhr_open_hook, nrules - 1, 0, 2));
            replace_property(ctx, proto, "send", wrap_global_function(ctx, proto, "send", xhr_send_hook, nrules - 1, 0, 0));
        }
        JS_FreeValue(ctx, proto);
        JS_FreeValue(ctx, X);
    } else if (!strcmp(name, "addEventListener-defuser")) {
        rule *r = new_rule(R_AELD);
        needle_init(ctx, &r->n1, argn(a, n, 0));
        needle_init(ctx, &r->n2, argn(a, n, 1));
        JSValue T = JS_GetPropertyStr(ctx, g, "EventTarget");
        JSValue proto = JS_IsObject(T) ? JS_GetPropertyStr(ctx, T, "prototype") : JS_UNDEFINED;
        if (is_object(proto)) { replace_property(ctx, proto, "addEventListener", wrap_global_function(ctx, proto, "addEventListener", aeld_hook, nrules - 1, 0, 2)); }
        JS_FreeValue(ctx, proto);
        JS_FreeValue(ctx, T);
    } else if (!strcmp(name, "window.open-defuser")) {
        rule *r = new_rule(R_WOPEN);
        needle_init(ctx, &r->n1, argn(a, n, 0));
        r->replace_obj = !strcmp(argn(a, n, 2), "obj");
        replace_property(ctx, g, "open", wrap_global_function(ctx, g, "open", wopen_hook, nrules - 1, 0, 0));
    } else if (!strcmp(name, "noeval")) {
        replace_property(ctx, g, "eval", JS_NewCFunction(ctx, fn_noop, "eval", 1));
    } else if (!strcmp(name, "nowebrtc")) {
        static const char *names[3] = { "RTCPeerConnection", "webkitRTCPeerConnection", "mozRTCPeerConnection" };
        for (int i = 0; i < 3; i++) {
            JSValue o = JS_GetPropertyStr(ctx, g, names[i]);
            if (JS_IsFunction(ctx, o)) { replace_property(ctx, g, names[i], JS_NewCFunction2(ctx, (JSCFunction *)webrtc_stub, names[i], 0, JS_CFUNC_constructor, 0)); }
            JS_FreeValue(ctx, o);
        }
    } else if (!strcmp(name, "json-prune")) {
        rule *r = new_rule(R_JSON);
        paths_init(r->paths, r->plen, &r->npaths, argn(a, n, 0));
        paths_init(r->req, r->rlen, &r->nreq, argn(a, n, 1));
        needle_init(ctx, &r->n1, argn(a, n, 2));
        JSValue J = JS_GetPropertyStr(ctx, g, "JSON");
        if (is_object(J) && r->npaths > 0) { replace_property(ctx, J, "parse", wrap_global_function(ctx, J, "parse", json_hook, nrules - 1, 0, 2)); }
        JS_FreeValue(ctx, J);
    }
    JS_FreeValue(ctx, g);
}

/* Installs the rules of a document. `spec` (len bytes, in this memory): records of fields, see the top of the file. Returns how many
 * rules were read. Meant to run once, before the page's first script. */
WJ_EXPORT("wj_hook_install")
int32_t wj_hook_install(uint32_t spec, uint32_t len)
{
    JSContext *ctx = wj_the_realm.ctx;
    const char *text = (const char *)(uintptr_t)spec;
    int32_t count = 0;
    size_t i = 0;
    while (i < len) {
        size_t j = i;
        while (j < len && text[j] != 0x1e) { j++; }
        /* one record text[i..j) */
        const char *fields[16];
        char *copy = strndup(text + i, j - i);
        int nf = 0;
        char *p = copy;
        while (nf < 16) {
            fields[nf++] = p;
            char *q = strchr(p, 0x1f);
            if (!q) { break; }
            *q = 0;
            p = q + 1;
        }
        if (nf > 0 && fields[0][0]) {
            install_rule(ctx, fields[0], fields + 1, nf - 1);
            count++;
        }
        free(copy);
        i = j + 1;
    }
    return count;
}
