/* test262_host.c: the host side of test262 inside the engine module, for src/tools/test262 only.
 *
 * Compiled to nothing unless WREN_TEST262 is defined: tools/test262.ps1 builds a separate image of the engine
 * (tools/build_js.ps1 -Out build\js-test262 -ExtraFlags -DWREN_TEST262=1), identical to the shipped one plus this file,
 * so that the conformance measured is the shipped engine's. The browser's image never contains it.
 *
 * What it provides is what QuickJS-ng's own runner (run-test262.c, pinned with the engine) gives a test, so that a
 * result here can be compared with the native one test by test:
 *   * the globals print and gc, and $262 (global, gc, createRealm, evalScript, detachArrayBuffer, IsHTMLDDA,
 *     codePointRange, agent);
 *   * a module loader reading files through the host (test262.fileSize / test262.readFile), with the runner's name
 *     resolution and import attributes (json, text, bytes);
 *   * wj_t262_eval: run-test262's eval_buf (a classic script or a module; the module's promise or the async test's
 *     $DONE decide; the exception's text is kept for the host, which compares it with the expected error).
 * $262.agent needs threads, which this module does not have: its functions throw (the host lists those tests apart).
 */
#if defined(WREN_TEST262)
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "qjs_internal.h"

extern volatile int32_t wj_interrupt;   /* qjs_realm.c: raised by the host when a task runs too long */

WR_IMPORT("test262", "fileSize") int32_t wr_test262_fileSize(const uint8_t *path, uint32_t path_len);
WR_IMPORT("test262", "readFile") int32_t wr_test262_readFile(const uint8_t *path, uint32_t path_len, uint8_t *out, uint32_t cap);

static int t262_async_done;     /* "Test262:AsyncTestComplete" prints (2 after a failure print) */
static char *t262_test_name;    /* the test's file name: base of the module names without a '/' */
static char *t262_message;      /* the text of the last exception (JS ToString), for the host */
static uint32_t t262_message_len;

static void t262_set_message(const char *s, size_t n)
{
    free(t262_message);
    t262_message = malloc(n + 1);
    if (!t262_message) { t262_message_len = 0; return; }
    memcpy(t262_message, s, n);
    t262_message[n] = 0;
    t262_message_len = (uint32_t)n;
}

static JSValue t262_print(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    for (int i = 0; i < argc; i++) {
        size_t n;
        const char *s = JS_ToCStringLen(ctx, &n, argv[i]);
        if (!s) { return JS_EXCEPTION; }
        if (strcmp(s, "Test262:AsyncTestComplete") == 0) {
            t262_async_done++;
        } else if (strncmp(s, "Test262:AsyncTestFailure", 24) == 0) {
            t262_async_done = 2;   /* forces an error, as run-test262 does */
        }
        JS_FreeCString(ctx, s);
    }
    return JS_UNDEFINED;
}

static JSValue t262_gc(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    JS_RunGC(JS_GetRuntime(ctx));
    return JS_UNDEFINED;
}

static JSValue t262_detach(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc > 0) { JS_DetachArrayBuffer(ctx, argv[0]); }
    return JS_UNDEFINED;
}

static JSValue t262_eval_script(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    size_t n;
    const char *s = JS_ToCStringLen(ctx, &n, argc > 0 ? argv[0] : JS_UNDEFINED);
    if (!s) { return JS_EXCEPTION; }
    JSValue r = JS_Eval(ctx, s, n, "<evalScript>", JS_EVAL_TYPE_GLOBAL);
    JS_FreeCString(ctx, s);
    return r;
}

static JSValue t262_is_html_dda(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(ctx); WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    return JS_NULL;
}

static JSValue t262_no_agent(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    return JS_ThrowTypeError(ctx, "$262.agent is not supported: the Wasm engine has no threads");
}

static JSValue t262_helpers(JSContext *ctx);

static JSValue t262_create_realm(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSContext *ctx1 = JS_NewContext(JS_GetRuntime(ctx));
    if (!ctx1) { return JS_ThrowOutOfMemory(ctx); }
    JSValue r = t262_helpers(ctx1);
    JS_FreeContext(ctx1);   /* the returned $262 holds the context */
    return r;
}

/* run-test262's add_helpers1: print, gc and $262 on the context's global; returns $262. */
static JSValue t262_helpers(JSContext *ctx)
{
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "print", JS_NewCFunction(ctx, t262_print, "print", 1));
    JS_SetPropertyStr(ctx, global, "gc", JS_NewCFunction(ctx, t262_gc, "gc", 0));
    static const JSCFunctionListEntry props[] = {
        JS_CFUNC_DEF("codePointRange", 2, js_string_codePointRange),
        JS_CFUNC_DEF("createRealm", 0, t262_create_realm),
        JS_CFUNC_DEF("detachArrayBuffer", 1, t262_detach),
        JS_CFUNC_DEF("evalScript", 1, t262_eval_script),
        JS_CFUNC_DEF("gc", 0, t262_gc),
    };
    static const JSCFunctionListEntry agent_props[] = {
        JS_CFUNC_DEF("start", 1, t262_no_agent),
        JS_CFUNC_DEF("getReport", 0, t262_no_agent),
        JS_CFUNC_DEF("broadcast", 2, t262_no_agent),
        JS_CFUNC_DEF("report", 1, t262_no_agent),
        JS_CFUNC_DEF("leaving", 0, t262_no_agent),
        JS_CFUNC_DEF("receiveBroadcast", 1, t262_no_agent),
        JS_CFUNC_DEF("sleep", 1, t262_no_agent),
        JS_CFUNC_DEF("monotonicNow", 0, t262_no_agent),
    };
    JSValue dda = JS_NewCFunction(ctx, t262_is_html_dda, "IsHTMLDDA", 0);
    JS_SetIsHTMLDDA(ctx, dda);
    JSValue o = JS_NewObject(ctx);
    JS_SetPropertyFunctionList(ctx, o, props, (int)(sizeof props / sizeof props[0]));
    JS_SetPropertyStr(ctx, o, "IsHTMLDDA", dda);
    JSValue agent = JS_NewObject(ctx);
    JS_SetPropertyFunctionList(ctx, agent, agent_props, (int)(sizeof agent_props / sizeof agent_props[0]));
    JS_SetPropertyStr(ctx, o, "agent", agent);
    JS_SetPropertyStr(ctx, o, "global", JS_GetGlobalObject(ctx));
    JS_SetPropertyStr(ctx, global, "$262", JS_DupValue(ctx, o));
    JS_FreeValue(ctx, global);
    return o;
}

/* ---- modules: files come from the host ---- */

static char *t262_load(JSContext *ctx, const char *name, size_t *len)
{
    uint32_t n = (uint32_t)strlen(name);
    int32_t size = wr_test262_fileSize((const uint8_t *)name, n);
    if (size < 0) { return NULL; }
    char *buf = js_malloc(ctx, (size_t)size + 1);
    if (!buf) { return NULL; }
    int32_t got = wr_test262_readFile((const uint8_t *)name, n, (uint8_t *)buf, (uint32_t)size);
    if (got != size) { js_free(ctx, buf); return NULL; }
    buf[size] = 0;
    *len = (size_t)size;
    return buf;
}

static int t262_default_init(JSContext *ctx, JSModuleDef *m)
{
    return JS_SetModuleExport(ctx, m, "default", JS_GetModulePrivateValue(ctx, m));
}

enum { T262_JS, T262_JSON, T262_TEXT, T262_BYTES };

static int t262_import_type(JSContext *ctx, JSValueConst attributes)
{
    if (JS_IsUndefined(attributes)) { return T262_JS; }
    JSValue str = JS_GetPropertyStr(ctx, attributes, "type");
    if (JS_IsException(str)) { return -1; }
    if (!JS_IsString(str)) { JS_FreeValue(ctx, str); return T262_JS; }
    size_t n;
    const char *s = JS_ToCStringLen(ctx, &n, str);
    JS_FreeValue(ctx, str);
    if (!s) { return -1; }
    int r;
    if (n == 4 && !memcmp(s, "json", 4)) { r = T262_JSON; }
    else if (n == 4 && !memcmp(s, "text", 4)) { r = T262_TEXT; }
    else if (n == 5 && !memcmp(s, "bytes", 5)) { r = T262_BYTES; }
    else { JS_ThrowTypeError(ctx, "unsupported module type: '%s'", s); r = -1; }
    JS_FreeCString(ctx, s);
    return r;
}

/* the array buffer's storage (quickjs-libc's js_realloc_array_buffer) */
static void *t262_realloc_bytes(JSRuntime *rt, void *opaque, void *ptr, size_t size)
{
    WJ_UNUSED(opaque);
    return js_realloc_rt(rt, ptr, size);
}

/* quickjs-libc's js_module_load behind run-test262's js_module_loader_test (a bare name is relative to the test). */
static JSModuleDef *t262_module_loader(JSContext *ctx, const char *module_name, void *opaque, JSValueConst attributes)
{
    WJ_UNUSED(opaque);
    char path[1024];
    if (!strchr(module_name, '/') && t262_test_name) {
        const char *slash = strrchr(t262_test_name, '/');
        if (slash) {
            int dir = (int)(slash - t262_test_name);
            if ((size_t)dir + 1 + strlen(module_name) + 1 > sizeof path) {
                JS_ThrowReferenceError(ctx, "module name too long: '%s'", module_name);
                return NULL;
            }
            memcpy(path, t262_test_name, (size_t)dir);
            path[dir] = '/';
            strcpy(path + dir + 1, module_name);
            module_name = path;
        }
    }
    int type = t262_import_type(ctx, attributes);
    if (type < 0) { return NULL; }
    size_t nl = strlen(module_name);
    if (type == T262_JS && nl >= 5 && !strcmp(module_name + nl - 5, ".json")) { type = T262_JSON; }
    size_t len = 0;
    char *buf = t262_load(ctx, module_name, &len);
    if (!buf) {
        JS_ThrowReferenceError(ctx, "could not load module filename '%s'", module_name);
        return NULL;
    }
    JSValue val;
    switch (type) {
    case T262_JS: val = JS_Eval(ctx, buf, len, module_name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY); break;
    case T262_JSON: val = JS_ParseJSON(ctx, buf, len, module_name); break;
    case T262_TEXT: val = JS_NewStringLen(ctx, buf, len); break;
    default:
        val = JS_NewUint8Array(ctx, (uint8_t *)buf, len, t262_realloc_bytes, NULL, false);
        if (!JS_IsException(val)) {
            JSValue ab = JS_GetTypedArrayBuffer(ctx, val, NULL, NULL, NULL);
            JS_SetImmutableArrayBuffer(ab, true);
            JS_FreeValue(ctx, ab);
            buf = NULL;   /* the array owns it */
        }
        break;
    }
    if (buf) { js_free(ctx, buf); }
    if (JS_IsException(val)) { return NULL; }
    JSModuleDef *m;
    if (type == T262_JS) {
        m = JS_VALUE_GET_PTR(val);
        /* import.meta.url as quickjs-libc gives it (without realpath on this platform) */
        JSValue meta = JS_GetImportMeta(ctx, m);
        if (JS_IsException(meta)) { JS_FreeValue(ctx, val); return NULL; }
        char url[1100];
        size_t ul = strlen(module_name);
        if (strchr(module_name, ':')) { memcpy(url, module_name, ul < sizeof url - 1 ? ul : sizeof url - 1); url[ul < sizeof url - 1 ? ul : sizeof url - 1] = 0; }
        else { strcpy(url, "file://"); strncat(url, module_name, sizeof url - 8); }
        JS_DefinePropertyValueStr(ctx, meta, "url", JS_NewString(ctx, url), JS_PROP_C_W_E);
        JS_DefinePropertyValueStr(ctx, meta, "main", JS_FALSE, JS_PROP_C_W_E);
        JS_FreeValue(ctx, meta);
        JS_FreeValue(ctx, val);   /* the module is referenced by the runtime */
    } else {
        m = JS_NewCModule(ctx, module_name, t262_default_init);
        if (!m) { JS_FreeValue(ctx, val); return NULL; }
        JS_AddModuleExport(ctx, m, "default");
        JS_SetModulePrivateValue(ctx, m, val);
    }
    return m;
}

/* ---- the host's entry points ---- */

/* Once per realm (after wj_realm_start with no web interfaces): the helpers, the module loader, [[CanBlock]].
 * `name` is the test's file name (module names without a '/' are relative to it). 0 ok. */
WJ_EXPORT("wj_t262_setup") int32_t wj_t262_setup(uint32_t name, uint32_t name_len, int32_t can_block)
{
    JSContext *ctx = wj_the_realm.ctx;
    if (!ctx) { return -1; }
    JSRuntime *rt = JS_GetRuntime(ctx);
    wj_stack_enter(NULL);
    free(t262_test_name);
    t262_test_name = malloc(name_len + 1);
    if (!t262_test_name) { return -1; }
    memcpy(t262_test_name, (const void *)(uintptr_t)name, name_len);
    t262_test_name[name_len] = 0;
    JS_SetCanBlock(rt, can_block != 0);
    JS_SetModuleLoaderFunc2(rt, NULL, t262_module_loader, NULL, NULL);
    JS_FreeValue(ctx, t262_helpers(ctx));
    return 0;
}

enum {
    T262_EVAL_MODULE = 1 << 0,
    T262_EVAL_STRICT = 1 << 1,
    T262_EVAL_ASYNC  = 1 << 2,   /* flags: [async]: the test calls $DONE exactly once */
};

/* run-test262's eval_buf: 0 when it completed normally, 1 when it threw (wj_t262_message: the exception as a string,
 * "<name>: <message>" for errors), 2 when it threw something that has no string (a negative test then fails, as in
 * run-test262). `src` has a NUL after `src_len` bytes. */
WJ_EXPORT("wj_t262_eval") int32_t wj_t262_eval(uint32_t src, uint32_t src_len, uint32_t name, uint32_t name_len, int32_t flags)
{
    JSContext *ctx = wj_the_realm.ctx;
    JSRuntime *rt = JS_GetRuntime(ctx);
    wj_stack_enter(NULL);
    char file[1024];
    size_t n = name_len < sizeof file - 1 ? name_len : sizeof file - 1;
    memcpy(file, (const void *)(uintptr_t)name, n);
    file[n] = 0;
    int eval_flags = ((flags & T262_EVAL_MODULE) ? JS_EVAL_TYPE_MODULE : JS_EVAL_TYPE_GLOBAL) |
                     ((flags & T262_EVAL_STRICT) ? JS_EVAL_FLAG_STRICT : 0);
    bool is_async = (flags & T262_EVAL_ASYNC) != 0;
    bool ret_promise = (flags & T262_EVAL_MODULE) != 0;
    t262_async_done = 0;
    t262_set_message("", 0);
    JSValue res = JS_Eval(ctx, (const char *)(uintptr_t)src, src_len, file, eval_flags);
    if ((is_async || ret_promise) && !JS_IsException(res)) {
        JSValue promise = JS_UNDEFINED;
        if (ret_promise) { promise = res; } else { JS_FreeValue(ctx, res); }
        for (;;) {
            JSContext *ctx1;
            int r = JS_ExecutePendingJob(rt, &ctx1);
            if (r < 0) { res = JS_EXCEPTION; break; }
            if (r == 0) {
                if (is_async) {
                    res = t262_async_done != 1 ? JS_ThrowTypeError(ctx, "$DONE() not called") : JS_UNDEFINED;
                } else {
                    JSPromiseStateEnum st = JS_PromiseState(ctx, promise);
                    if (st == JS_PROMISE_FULFILLED) { res = JS_UNDEFINED; }
                    else if (st == JS_PROMISE_REJECTED) { res = JS_Throw(ctx, JS_PromiseResult(ctx, promise)); }
                    else { res = JS_ThrowTypeError(ctx, "promise is pending"); }
                }
                break;
            }
            if (wj_interrupt) { res = JS_ThrowInternalError(ctx, "interrupted"); break; }
        }
        JS_FreeValue(ctx, promise);
    }
    if (!JS_IsException(res)) {
        JS_FreeValue(ctx, res);
        return 0;
    }
    JSValue exc = JS_GetException(ctx);
    size_t ml = 0;
    const char *m = JS_ToCStringLen(ctx, &ml, exc);
    int32_t code = 1;
    if (m) {
        t262_set_message(m, ml);
        JS_FreeCString(ctx, m);
    } else {
        JS_FreeValue(ctx, JS_GetException(ctx));
        static const char none[] = "(an exception that has no string)";
        t262_set_message(none, sizeof none - 1);
        code = 2;
    }
    JS_FreeValue(ctx, exc);
    return code;
}

WJ_EXPORT("wj_t262_message") uint32_t wj_t262_message(void) { return (uint32_t)(uintptr_t)t262_message; }
WJ_EXPORT("wj_t262_message_len") uint32_t wj_t262_message_len(void) { return t262_message_len; }

#endif /* WREN_TEST262 */
