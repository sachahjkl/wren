/* modules.c: ECMAScript modules as HTML loads them ("fetch a module script graph", "resolve a module specifier",
 * import(), import.meta).
 *
 * QuickJS loads the modules a module imports synchronously, while it links it; a browser fetches them over the
 * network. So the browser fetches the whole graph first (src/page/js_load_modules.odin):
 *   1. each module's source, once it arrived, is compiled here without being run (wj_module_prepare), which registers
 *      it with the engine under its URL and tells the browser what it imports (Module_request: the browser resolves
 *      the specifier, import maps included, and fetches what it does not have yet);
 *   2. once every module of the graph is there, the root is linked and evaluated (wj_module_run): the engine finds the
 *      imports among the modules it compiled (normalize = the browser's resolution); a module the engine let go of
 *      meanwhile (a failed link frees every unlinked module) is compiled again from the browser's copy (the loader).
 * import() goes through the browser the same way (the dynamic import hook): it starts the graph, and calls
 * wj_module_import_done in a task of its own when the graph is complete or failed.
 *
 * Module names are absolute URLs; an inline <script type=module> is named after its document with a
 * "#inline-module-<n>" fragment (relative specifiers resolve against the document, import.meta.url is the document's
 * URL). JSON modules (import ... with {type: "json"}) are synthetic modules whose default export is the parsed value.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"

enum { MODULE_JS = 0, MODULE_JSON = 1 };

static const char INLINE_MARK[] = "#inline-module-";

/* ---- strings from the browser ---- */

/* A NUL-terminated copy (js_malloc) of the browser's string result in wj_scratch, or NULL. */
static char *scratch_cstr(JSContext *ctx, int32_t n)
{
    char *s = js_malloc(ctx, (size_t)(n > 0 ? n : 0) + 1);
    if (!s) { return NULL; }
    if (n > 0) { memcpy(s, wj_scratch.data, (size_t)n); }
    s[n > 0 ? n : 0] = 0;
    return s;
}

/* The error message the browser recorded for its last failed call (web.Exception_message), into `buf`. */
static void browser_message(char *buf, size_t cap, const char *fallback)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_Exception_message(wj_scratch.data, wj_scratch.cap));
    if (n <= 0) { snprintf(buf, cap, "%s", fallback); return; }
    size_t len = (size_t)n < cap - 1 ? (size_t)n : cap - 1;
    memcpy(buf, wj_scratch.data, len);
    buf[len] = 0;
}

/* ---- import.meta ---- */

static JSValue meta_resolve(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    if (argc < 1) { return wj_throw_arity(ctx, "import.meta.resolve", 1, argc); }
    wj_str spec, base;
    if (!wj_to_str(ctx, argv[0], &spec, 0, "")) { return JS_EXCEPTION; }
    if (!wj_to_str(ctx, data[0], &base, 0, "")) { wj_str_free(ctx, &spec); return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Module_resolve((const uint8_t *)spec.ptr, (uint32_t)spec.len, (const uint8_t *)base.ptr, (uint32_t)base.len, wj_scratch.data, wj_scratch.cap));
    wj_str_free(ctx, &spec);
    wj_str_free(ctx, &base);
    if (n < 0) {
        char msg[512];
        browser_message(msg, sizeof msg, "Failed to resolve module specifier");
        return JS_ThrowTypeError(ctx, "%s", msg);
    }
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n);
}

/* import.meta.url (the module's URL, the document's for an inline module) and import.meta.resolve. */
static int set_meta(JSContext *ctx, JSModuleDef *m, const char *name)
{
    JSValue meta = JS_GetImportMeta(ctx, m);
    if (JS_IsException(meta)) { return -1; }
    const char *mark = strstr(name, INLINE_MARK);
    size_t len = mark ? (size_t)(mark - name) : strlen(name);
    JS_DefinePropertyValueStr(ctx, meta, "url", JS_NewStringLen(ctx, name, len), JS_PROP_C_W_E);
    JSValue base = JS_NewString(ctx, name);
    JSValue fn = JS_NewCFunctionData(ctx, meta_resolve, 1, 0, 1, &base);
    JS_FreeValue(ctx, base);
    JS_DefinePropertyValueStr(ctx, meta, "resolve", fn, JS_PROP_C_W_E);
    JS_FreeValue(ctx, meta);
    return 0;
}

/* ---- compiling ---- */

static int json_module_init(JSContext *ctx, JSModuleDef *m)
{
    JSValue v = JS_GetModulePrivateValue(ctx, m);
    return JS_SetModuleExport(ctx, m, "default", v);
}

/* Compiles a module named `name` (registered with the engine, not run): its JSModuleDef, NULL with an exception
 * pending. */
static JSModuleDef *compile_module(JSContext *ctx, const char *src, size_t len, const char *name, int type)
{
    if (type == MODULE_JSON) {
        JSValue v = JS_ParseJSON(ctx, src, len, name);
        if (JS_IsException(v)) { return NULL; }
        JSModuleDef *m = JS_NewCModule(ctx, name, json_module_init);
        if (!m) { JS_FreeValue(ctx, v); return NULL; }
        if (JS_AddModuleExport(ctx, m, "default") < 0) { JS_FreeValue(ctx, v); return NULL; }
        JS_SetModulePrivateValue(ctx, m, v);
        return m;
    }
    JSEvalOptions opt = {
        .version = JS_EVAL_OPTIONS_VERSION,
        .eval_flags = JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY | JS_EVAL_FLAG_WREN_NO_RESOLVE,
        .filename = name,
        .line_num = 1,
    };
    JSValue fn = JS_Eval2(ctx, src, len, &opt);
    if (JS_IsException(fn)) { return NULL; }
    JSModuleDef *m = JS_VALUE_GET_PTR(fn);
    if (set_meta(ctx, m, name) < 0) { JS_FreeValue(ctx, fn); return NULL; }
    JS_FreeValue(ctx, fn);   /* the engine keeps the module among its loaded ones */
    return m;
}

/* The type of an import from its attributes: MODULE_JS, MODULE_JSON, -1 (TypeError pending) for another. */
static int import_type(JSContext *ctx, JSValueConst attributes)
{
    if (!JS_IsObject(attributes)) { return MODULE_JS; }
    JSValue t = JS_GetPropertyStr(ctx, attributes, "type");
    if (JS_IsException(t)) { return -1; }
    if (JS_IsUndefined(t)) { return MODULE_JS; }
    const char *s = JS_ToCString(ctx, t);
    JS_FreeValue(ctx, t);
    if (!s) { return -1; }
    int r = strcmp(s, "json") == 0 ? MODULE_JSON : -1;
    if (r < 0) { JS_ThrowTypeError(ctx, "unsupported module type \"%s\"", s); }
    JS_FreeCString(ctx, s);
    return r;
}

/* ---- errors to rethrow ---- */

/* HTML keeps a module script's parse error (or an import it cannot resolve) as its "error to rethrow": reported when a
 * <script type=module> of that graph runs, the rejection of an import() of it. Kept here by module name. */
typedef struct rethrow { char *name; JSValue error; } rethrow;
static rethrow *rethrows;
static uint32_t rethrow_n, rethrow_cap;

static void rethrow_keep(JSContext *ctx, const char *name, JSValue error)
{
    for (uint32_t i = 0; i < rethrow_n; i++) {
        if (strcmp(rethrows[i].name, name) == 0) { JS_FreeValue(ctx, rethrows[i].error); rethrows[i].error = error; return; }
    }
    if (rethrow_n == rethrow_cap) {
        uint32_t cap = rethrow_cap ? rethrow_cap * 2 : 8;
        rethrow *n = realloc(rethrows, cap * sizeof *n);
        if (!n) { JS_FreeValue(ctx, error); return; }
        rethrows = n;
        rethrow_cap = cap;
    }
    size_t len = strlen(name);
    char *copy = malloc(len + 1);
    if (!copy) { JS_FreeValue(ctx, error); return; }
    memcpy(copy, name, len + 1);
    rethrows[rethrow_n].name = copy;
    rethrows[rethrow_n].error = error;
    rethrow_n++;
}

/* The error to rethrow of module `name` (a new reference), or undefined. */
static JSValue rethrow_get(JSContext *ctx, const char *name, size_t len)
{
    for (uint32_t i = 0; i < rethrow_n; i++) {
        if (strlen(rethrows[i].name) == len && memcmp(rethrows[i].name, name, len) == 0) { return JS_DupValue(ctx, rethrows[i].error); }
    }
    return JS_UNDEFINED;
}

/* A module script whose graph has a module with an error to rethrow runs: the error is reported (HTML "run a module
 * script"). */
WJ_EXPORT("wj_module_report") void wj_module_report(uint32_t url, uint32_t url_len)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    JSValue e = rethrow_get(ctx, (const char *)(uintptr_t)url, url_len);
    if (!JS_IsUndefined(e)) { wj_report_exception(ctx, e); }
}

/* The browser has a module's source: compile it and tell the browser what it imports. 0 ok, 2 it does not compile or
 * one of its imports cannot be resolved (its error to rethrow is kept, not reported now). */
WJ_EXPORT("wj_module_prepare")
int32_t wj_module_prepare(uint32_t src, uint32_t src_len, uint32_t url, uint32_t url_len, int32_t type)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    char *name = js_malloc(ctx, url_len + 1);
    if (!name) { return 2; }
    memcpy(name, (const void *)(uintptr_t)url, url_len);
    name[url_len] = 0;
    JSModuleDef *m = compile_module(ctx, (const char *)(uintptr_t)src, src_len, name, type);
    if (!m) { rethrow_keep(ctx, name, JS_GetException(ctx)); js_free(ctx, name); return 2; }
    int n = JS_GetModuleRequestCount(m);
    int32_t status = 0;
    for (int i = 0; i < n && status == 0; i++) {
        JSValue attrs = JS_UNDEFINED;
        JSAtom a = JS_GetModuleRequest(ctx, m, i, &attrs);
        if (a == JS_ATOM_NULL) { JS_FreeValue(ctx, attrs); continue; }
        int t = import_type(ctx, attrs);
        JS_FreeValue(ctx, attrs);
        size_t sl;
        const char *spec = JS_AtomToCStringLen(ctx, &sl, a);
        JS_FreeAtom(ctx, a);
        if (t < 0 || !spec) {
            if (spec) { JS_FreeCString(ctx, spec); }
            rethrow_keep(ctx, name, JS_GetException(ctx));
            status = 2;
            break;
        }
        int32_t st = wr_Module_request((const uint8_t *)name, url_len, (const uint8_t *)spec, (uint32_t)sl, t);
        if (st < 0) {
            char msg[512];
            browser_message(msg, sizeof msg, "Failed to resolve module specifier");
            JS_ThrowTypeError(ctx, "%s", msg);
            rethrow_keep(ctx, name, JS_GetException(ctx));
            status = 2;
        }
        JS_FreeCString(ctx, spec);
    }
    js_free(ctx, name);
    return status;
}

/* ---- the engine's module loader: resolution and modules it does not have ---- */

static char *module_normalize(JSContext *ctx, const char *base, const char *spec, void *opaque)
{
    WJ_UNUSED(opaque);
    int32_t n;
    WJ_FETCH_STRING(n, wr_Module_resolve((const uint8_t *)spec, (uint32_t)strlen(spec), (const uint8_t *)base, (uint32_t)strlen(base), wj_scratch.data, wj_scratch.cap));
    if (n < 0) {
        char msg[512];
        browser_message(msg, sizeof msg, "Failed to resolve module specifier");
        JS_ThrowTypeError(ctx, "%s", msg);
        return NULL;
    }
    return scratch_cstr(ctx, n);
}

static JSModuleDef *module_loader(JSContext *ctx, const char *name, void *opaque, JSValueConst attributes)
{
    WJ_UNUSED(opaque);
    int type = import_type(ctx, attributes);
    if (type < 0) { return NULL; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Module_source((const uint8_t *)name, (uint32_t)strlen(name), wj_scratch.data, wj_scratch.cap));
    if (n < 0) {
        JS_ThrowTypeError(ctx, "Failed to load module script: %s", name);
        return NULL;
    }
    /* the scratch buffer may move while compiling (nested calls): a copy */
    char *src = js_malloc(ctx, (size_t)n + 1);
    if (!src) { return NULL; }
    memcpy(src, wj_scratch.data, (size_t)n);
    src[n] = 0;
    JSModuleDef *m = compile_module(ctx, src, (size_t)n, name, type);
    js_free(ctx, src);
    return m;
}

static int module_check_attributes(JSContext *ctx, void *opaque, JSValueConst attributes)
{
    WJ_UNUSED(opaque);
    JSPropertyEnum *tab = NULL;
    uint32_t len = 0;
    if (JS_GetOwnPropertyNames(ctx, &tab, &len, attributes, JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) < 0) { return -1; }
    int r = 0;
    for (uint32_t i = 0; i < len && r == 0; i++) {
        const char *k = JS_AtomToCString(ctx, tab[i].atom);
        if (k && strcmp(k, "type") != 0) { JS_ThrowSyntaxError(ctx, "unsupported import attribute \"%s\"", k); r = -1; }
        if (k) { JS_FreeCString(ctx, k); }
    }
    JS_FreePropertyEnum(ctx, tab, len);
    return r;
}

/* ---- running a graph ---- */

static JSValue evaluation_rejected(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic); WJ_UNUSED(data);
    wj_report_exception(ctx, JS_DupValue(ctx, argc > 0 ? argv[0] : JS_UNDEFINED));
    return JS_UNDEFINED;
}

/* Links and evaluates the module graph whose root is `url` (every module of it prepared). 0 ok (or still evaluating:
 * top-level await), 1 it threw (reported, now or when its evaluation settles). */
WJ_EXPORT("wj_module_run") int32_t wj_module_run(uint32_t url, uint32_t url_len)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    char *name = js_malloc(ctx, url_len + 1);
    if (!name) { return 1; }
    memcpy(name, (const void *)(uintptr_t)url, url_len);
    name[url_len] = 0;
    JSValue promise = JS_LoadModule(ctx, "", name);
    js_free(ctx, name);
    if (JS_IsException(promise)) { wj_report_pending(ctx); return 1; }
    int32_t status = 0;
    JSPromiseStateEnum st = JS_PromiseState(ctx, promise);
    if (st == JS_PROMISE_REJECTED) {
        JSValue reason = JS_PromiseResult(ctx, promise);
        JS_PromiseMarkAsHandled(ctx, promise);
        wj_report_exception(ctx, reason);
        status = 1;
    } else if (st == JS_PROMISE_PENDING) {
        /* top-level await: a later rejection is reported when it happens */
        JSValue on_reject = JS_NewCFunctionData(ctx, evaluation_rejected, 1, 0, 0, NULL);
        /* the engine's own then (Promise.prototype.then may be a script's by now) */
        JSValue r = JS_PromiseThen(ctx, promise, JS_UNDEFINED, on_reject);
        if (JS_IsException(r)) { wj_report_pending(ctx); } else { JS_FreeValue(ctx, r); }
        JS_FreeValue(ctx, on_reject);
    }
    JS_FreeValue(ctx, promise);
    return status;
}

/* ---- import() ---- */

typedef struct pending_import {
    bool     used;
    JSValue  funcs[2];     /* resolve, reject (counted) */
    JSValue  attributes;   /* counted */
} pending_import;

static pending_import *imports;
static uint32_t import_cap;

static int import_hook(JSContext *ctx, JSValueConst basename, JSValueConst specifier, JSValueConst attributes,
                       JSValueConst *resolving_funcs, void *opaque)
{
    WJ_UNUSED(opaque);
    int type = import_type(ctx, attributes);
    if (type < 0) { return -1; }
    uint32_t id = 0;
    while (id < import_cap && imports[id].used) { id++; }
    if (id == import_cap) {
        uint32_t cap = import_cap ? import_cap * 2 : 16;
        pending_import *n = realloc(imports, cap * sizeof *n);
        if (!n) { JS_ThrowOutOfMemory(ctx); return -1; }
        memset(n + import_cap, 0, (cap - import_cap) * sizeof *n);
        imports = n;
        import_cap = cap;
    }
    wj_str spec, base;
    if (!wj_to_str(ctx, specifier, &spec, 0, "")) { return -1; }
    if (!JS_IsString(basename)) {
        /* code without a script (a function made by new Function in a handler...): the document is its base */
        base.ptr = NULL; base.len = 0; base.owned = false;
    } else if (!wj_to_str(ctx, basename, &base, 0, "")) {
        wj_str_free(ctx, &spec);
        return -1;
    }
    pending_import *pi = &imports[id];
    pi->used = true;
    pi->funcs[0] = JS_DupValue(ctx, resolving_funcs[0]);
    pi->funcs[1] = JS_DupValue(ctx, resolving_funcs[1]);
    pi->attributes = JS_DupValue(ctx, attributes);
    int32_t st = wr_Module_import((int32_t)id, (const uint8_t *)spec.ptr, (uint32_t)spec.len, (const uint8_t *)(base.ptr ? base.ptr : ""), (uint32_t)base.len, type);
    wj_str_free(ctx, &spec);
    wj_str_free(ctx, &base);
    if (st < 0) {
        char msg[512];
        browser_message(msg, sizeof msg, "Failed to resolve module specifier");
        JS_FreeValue(ctx, pi->funcs[0]);
        JS_FreeValue(ctx, pi->funcs[1]);
        JS_FreeValue(ctx, pi->attributes);
        pi->used = false;
        JS_ThrowTypeError(ctx, "%s", msg);
        return -1;
    }
    return 0;
}

/* The graph of an import() is complete (ok 1: link and evaluate it, settling the promise) or failed: 0, a TypeError
 * with `msg`; 2, the error to rethrow of module `msg` (it does not compile). */
WJ_EXPORT("wj_module_import_done")
void wj_module_import_done(int32_t id, uint32_t url, uint32_t url_len, int32_t ok, uint32_t msg, uint32_t msg_len)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    if (id < 0 || (uint32_t)id >= import_cap || !imports[id].used) { return; }
    pending_import pi = imports[id];
    imports[id].used = false;
    JSValue kept = ok == 2 ? rethrow_get(ctx, (const char *)(uintptr_t)msg, msg_len) : JS_UNDEFINED;
    if (ok == 2 && !JS_IsUndefined(kept)) {
        JSValue r = JS_Call(ctx, pi.funcs[1], JS_UNDEFINED, 1, &kept);
        JS_FreeValue(ctx, r);
        JS_FreeValue(ctx, kept);
    } else if (ok == 1) {
        char *name = js_malloc(ctx, url_len + 1);
        if (name) {
            memcpy(name, (const void *)(uintptr_t)url, url_len);
            name[url_len] = 0;
            JS_LoadModuleWithFuncs(ctx, "", name, (JSValueConst *)pi.funcs, pi.attributes);
            js_free(ctx, name);
        }
    } else {
        JS_ThrowTypeError(ctx, "%.*s", (int)msg_len, (const char *)(uintptr_t)msg);
        JSValue err = JS_GetException(ctx);
        JSValue r = JS_Call(ctx, pi.funcs[1], JS_UNDEFINED, 1, &err);
        JS_FreeValue(ctx, r);
        JS_FreeValue(ctx, err);
    }
    JS_FreeValue(ctx, pi.funcs[0]);
    JS_FreeValue(ctx, pi.funcs[1]);
    JS_FreeValue(ctx, pi.attributes);
}

/* Realm start (runtime/load.c). */
void wj_modules_start(JSContext *ctx)
{
    JSRuntime *rt = JS_GetRuntime(ctx);
    JS_SetModuleLoaderFunc2(rt, module_normalize, module_loader, module_check_attributes, NULL);
    JS_SetDynamicImportHook(rt, import_hook, NULL);
}
