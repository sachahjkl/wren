// TEST-ONLY reference compiler for the Odin JavaScript runtime (src/engine/jsrt).
//
// Until the Odin front-end (src/engine/frontend, agent E1) compiles everything test262 needs, the
// runtime's judge uses QuickJS-ng 0.17's own compiler, built from the pinned engine source into a
// DLL, as its `Host_Config.compile` hook: source text in, JS_WriteObject bytecode out. It is never
// shipped and links nothing into Wren; tools/jsrt_test262.ps1 builds it with the pinned Zig.
//
// It includes quickjs.c so a direct eval can be compiled against the caller's scopes: the runtime
// passes the calling function's variable and closure tables (QParent), from which a stand-in
// JSFunctionBytecode is built for add_closure_variables, exactly as __JS_EvalInternal does with a
// live stack frame.

#include "quickjs.c"

typedef struct {
    const char *name;
    int scope_level, scope_next, var_kind, is_const, is_lexical;
} QVarDef;

typedef struct {
    const char *name;
    int var_idx, closure_type, is_const, is_lexical, var_kind;
} QClosureVar;

typedef struct {
    int arg_count, var_count, closure_var_count;
    const QVarDef *vardefs;
    const QClosureVar *closure_vars;
    int is_strict, new_target_allowed, super_call_allowed, super_allowed, arguments_allowed;
} QParent;

/* one compiler per thread: the judge runs tests on several threads */
static _Thread_local JSRuntime *g_rt;
static _Thread_local JSContext *g_ctx;
static _Thread_local int g_uses;

static void qjsc_reset(void)
{
    if (g_ctx) JS_FreeContext(g_ctx);
    if (g_rt) JS_FreeRuntime(g_rt);
    g_rt = JS_NewRuntime();
    JS_SetMaxStackSize(g_rt, 0);
    g_ctx = JS_NewContext(g_rt);
    g_uses = 0;
}

static void copy_error(JSContext *ctx, char *err, size_t cap, int *kind)
{
    JSValue e = JS_GetException(ctx);
    const char *s = NULL;
    *kind = 1;
    if (JS_IsObject(e)) {
        JSValue name = JS_GetPropertyStr(ctx, e, "name");
        const char *n = JS_ToCString(ctx, name);
        if (n && strcmp(n, "SyntaxError") == 0) *kind = 0;
        else if (n && strcmp(n, "ReferenceError") == 0) *kind = 2;
        else if (n && strcmp(n, "RangeError") == 0) *kind = 3;
        else if (n && strcmp(n, "TypeError") == 0) *kind = 4;
        if (n) JS_FreeCString(ctx, n);
        JS_FreeValue(ctx, name);
        JSValue msg = JS_GetPropertyStr(ctx, e, "message");
        s = JS_ToCString(ctx, msg);
        JS_FreeValue(ctx, msg);
    } else {
        s = JS_ToCString(ctx, e);
    }
    if (cap > 0) {
        snprintf(err, cap, "%s", s ? s : "compile error");
    }
    if (s) JS_FreeCString(ctx, s);
    JS_FreeValue(ctx, e);
}

static JSValue compile_direct_eval(JSContext *ctx, const char *input, size_t input_len,
                                   const char *filename, const QParent *qp, int scope_idx)
{
    JSParseState s1, *s = &s1;
    JSFunctionDef *fd;
    JSFunctionBytecode *b;
    JSValue fun_obj = JS_EXCEPTION;
    int i, n, err;

    b = js_mallocz(ctx, sizeof(*b));
    b->arg_count = qp->arg_count;
    b->var_count = qp->var_count;
    b->closure_var_count = qp->closure_var_count;
    b->is_strict_mode = qp->is_strict;
    b->new_target_allowed = qp->new_target_allowed;
    b->super_call_allowed = qp->super_call_allowed;
    b->super_allowed = qp->super_allowed;
    b->arguments_allowed = qp->arguments_allowed;
    n = qp->arg_count + qp->var_count;
    if (n > 0) {
        b->vardefs = js_mallocz(ctx, sizeof(b->vardefs[0]) * n);
        for (i = 0; i < n; i++) {
            JSVarDef *vd = &b->vardefs[i];
            vd->var_name = JS_NewAtom(ctx, qp->vardefs[i].name);
            vd->scope_level = qp->vardefs[i].scope_level;
            vd->scope_next = qp->vardefs[i].scope_next;
            vd->var_kind = qp->vardefs[i].var_kind;
            vd->is_const = qp->vardefs[i].is_const;
            vd->is_lexical = qp->vardefs[i].is_lexical;
        }
    }
    if (qp->closure_var_count > 0) {
        b->closure_var = js_mallocz(ctx, sizeof(b->closure_var[0]) * qp->closure_var_count);
        for (i = 0; i < qp->closure_var_count; i++) {
            JSClosureVar *cv = &b->closure_var[i];
            cv->var_name = JS_NewAtom(ctx, qp->closure_vars[i].name);
            cv->var_idx = qp->closure_vars[i].var_idx;
            cv->closure_type = qp->closure_vars[i].closure_type;
            cv->is_const = qp->closure_vars[i].is_const;
            cv->is_lexical = qp->closure_vars[i].is_lexical;
            cv->var_kind = qp->closure_vars[i].var_kind;
        }
    }

    js_parse_init(ctx, s, input, input_len, filename, 1);
    skip_shebang(&s->buf_ptr, s->buf_end);
    fd = js_new_function_def(ctx, NULL, true, false, filename, 1, 1);
    if (!fd)
        goto done;
    s->cur_func = fd;
    fd->eval_type = JS_EVAL_TYPE_DIRECT;
    fd->has_this_binding = false;
    fd->new_target_allowed = b->new_target_allowed;
    fd->super_call_allowed = b->super_call_allowed;
    fd->super_allowed = b->super_allowed;
    fd->arguments_allowed = b->arguments_allowed;
    fd->is_strict_mode = b->is_strict_mode;
    fd->func_name = JS_DupAtom(ctx, JS_ATOM__eval_);
    if (add_closure_variables(ctx, fd, b, scope_idx)) {
        js_free_function_def(ctx, fd);
        goto done;
    }
    s->is_module = false;
    s->allow_html_comments = true;
    push_scope(s);
    fd->body_scope = fd->scope_level;
    err = js_parse_program(s);
    if (err) {
        free_token(s, &s->token);
        js_free_function_def(ctx, fd);
        goto done;
    }
    fun_obj = js_create_function(ctx, fd);
done:
    for (i = 0; i < n; i++)
        JS_FreeAtom(ctx, b->vardefs[i].var_name);
    for (i = 0; i < qp->closure_var_count; i++)
        JS_FreeAtom(ctx, b->closure_var[i].var_name);
    js_free(ctx, b->vardefs);
    js_free(ctx, b->closure_var);
    js_free(ctx, b);
    return fun_obj;
}

// JS_WriteModule drops import attributes. The runtime reads a request name "spec\0type" as the
// specifier `spec` imported `with { type: "type" }`, so the `type` attribute is folded in here.
static void encode_request_types(JSContext *ctx, JSModuleDef *m)
{
    for (int i = 0; i < m->req_module_entries_count; i++) {
        JSReqModuleEntry *rme = &m->req_module_entries[i];
        if (!JS_IsObject(rme->attributes))
            continue;
        JSValue t = JS_GetPropertyStr(ctx, rme->attributes, "type");
        if (JS_IsString(t)) {
            size_t nl, tl;
            const char *name = JS_AtomToCStringLen(ctx, &nl, rme->module_name);
            const char *type = JS_ToCStringLen(ctx, &tl, t);
            if (name && type) {
                char *buf = malloc(nl + 1 + tl);
                memcpy(buf, name, nl);
                buf[nl] = '\0';
                memcpy(buf + nl + 1, type, tl);
                JSAtom a = JS_NewAtomLen(ctx, buf, nl + 1 + tl);
                free(buf);
                JS_FreeAtom(ctx, rme->module_name);
                rme->module_name = a;
            }
            JS_FreeCString(ctx, name);
            JS_FreeCString(ctx, type);
        }
        JS_FreeValue(ctx, t);
    }
}

// kind: 0 script, 1 module, 2 indirect eval, 3 Function constructor source, 4 direct eval
__declspec(dllexport) int qjsc_compile(const char *src, size_t src_len, const char *filename,
                                       int kind, int strict, const QParent *parent, int scope_idx,
                                       uint8_t **out, size_t *out_len,
                                       char *err, size_t err_cap, int *err_kind)
{
    JSValue obj;
    int flags;
    char *buf;

    if (!g_rt || ++g_uses > 2000)
        qjsc_reset();
    JSContext *ctx = g_ctx;
    *out = NULL;
    *out_len = 0;
    /* the parser needs a NUL-terminated buffer */
    buf = malloc(src_len + 1);
    memcpy(buf, src, src_len);
    buf[src_len] = '\0';
    switch (kind) {
    case 1:
        flags = JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY | JS_EVAL_FLAG_WREN_NO_RESOLVE;
        obj = JS_EvalInternal(ctx, ctx->global_obj, buf, src_len, filename, 1, flags, -1);
        break;
    case 2:
        flags = JS_EVAL_TYPE_INDIRECT | JS_EVAL_FLAG_COMPILE_ONLY | (strict ? JS_EVAL_FLAG_STRICT : 0);
        obj = JS_EvalInternal(ctx, ctx->global_obj, buf, src_len, filename, 1, flags, -1);
        break;
    case 4:
        obj = compile_direct_eval(ctx, buf, src_len, filename, parent, scope_idx);
        break;
    default:
        flags = JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY | (strict ? JS_EVAL_FLAG_STRICT : 0);
        obj = JS_EvalInternal(ctx, ctx->global_obj, buf, src_len, filename, 1, flags, -1);
        break;
    }
    free(buf);
    if (JS_IsException(obj)) {
        copy_error(ctx, err, err_cap, err_kind);
        return -1;
    }
    if (JS_VALUE_GET_TAG(obj) == JS_TAG_MODULE)
        encode_request_types(ctx, JS_VALUE_GET_PTR(obj));
    *out = JS_WriteObject(ctx, out_len, obj, JS_WRITE_OBJ_BYTECODE);
    JS_FreeValue(ctx, obj);
    if (!*out) {
        copy_error(ctx, err, err_cap, err_kind);
        return -1;
    }
    return 0;
}

__declspec(dllexport) void qjsc_free(void *p)
{
    js_free(g_ctx, p);
}
