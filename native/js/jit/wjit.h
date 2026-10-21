/* Wren's JavaScript JIT: hot QuickJS functions compiled to WebAssembly at run time.
 *
 * Included at the end of quickjs.c (patch 0005-wren-jit) to see the engine's internals. WebAssembly stays the only
 * execution engine: the code made here is a Wasm module the browser compiles with Cranelift (Engine_jitCompile) and
 * instantiates in the engine's own store, importing the engine's memory and a few of its exports; its function is put in
 * the engine's table and called through it (call_indirect) like any C function pointer.
 *
 * Model: the compiled code keeps the interpreter's frame exactly (arguments, locals and operand stack in the frame's
 * memory, same layout), so leaving it at any instruction boundary is free: the interpreter carries on from (pc, sp).
 *   - hot ops are compiled inline with their fast path (ints, locals, stack shuffles, branches, returns); their rare
 *     cases, and every other op, go through wjit_step, which runs one op with the interpreter's own code (the body of
 *     JS_CallInternal's switch, extracted at build time by tools/build_js.ps1 into wjit_step_body.h): nothing is
 *     re-implemented for them, so every op of a normal function compiles;
 *   - control flow is structured from the bytecode (loops = back edges; forward branches = blocks); a function whose
 *     flow cannot be structured simply, or that uses finally/with (gosub, ret, with_*), stays interpreted from there;
 *   - exits: return (value + sp), exception (pc + sp: the interpreter's handler runs, catch blocks included), deopt
 *     (pc + sp: the interpreter resumes).
 * A function is compiled at its javascript.jit.call_threshold-th call. Nothing is compiled unless the embedder turned
 * the JIT on with wj_jit_configure (it must provide Engine_jitCompile). */

#ifdef WREN_JIT

#define WJIT_EXPORT(name) __attribute__((export_name(name), visibility("default")))
/* the browser's side (api/js.widl) */
__attribute__((import_module("js"), import_name("Engine_jitCompile"))) int32_t wr_Engine_jitCompile(const uint8_t *module, uint32_t module_len);
__attribute__((import_module("js"), import_name("Engine_jitPoll"))) int32_t wr_Engine_jitPoll(int32_t ticket);

/* JSFunctionBytecode.wjit_index besides a table index: */
#define WJIT_NONE 0       /* not compiled (yet) */
#define WJIT_NEVER (-1)   /* cannot be: interpreted for good */
#define WJIT_PENDING (-2) /* being compiled in the background; wjit_calls holds the ticket */

/* ---- configuration and statistics -------------------------------------------------------------------------- */

typedef struct WJitConfig {
    int enabled;
    uint32_t call_threshold;      /* compile at that call */
    uint32_t loop_threshold;      /* or after that many loop iterations (back edges) */
    uint32_t max_functions;       /* per realm, 0 = no limit */
    uint32_t max_bytecode_bytes;  /* larger functions stay interpreted */
    uint32_t inline_ops;          /* 0: every op through wjit_step (for testing the step path) */
    uint32_t off;                 /* testing: WJIT_OFF_* paths turned off (bisecting a difference) */
} WJitConfig;

typedef struct WJitStats {
    double compiled, failed, refused, module_bytes, bytecode_bytes, compile_ms_engine;
    double entries, exits_return, exits_exception, exits_deopt, steps, pending, osr_entries;
} WJitStats;

/* bumped by the browser's compile threads each time one of this engine's functions is compiled (wj_jit_done_address):
   a pending function asks the browser only when it changed since it last asked */
static volatile uint32_t wjit_done_count;

static WJitConfig wjit_config = { 0, 2, 500, 0, 65536, 1 };
static WJitStats wjit_stats;

WJIT_EXPORT("wj_jit_configure")
void wj_jit_configure(int32_t flags, int32_t call_threshold, int32_t max_functions, int32_t max_bytecode_bytes,
                      int32_t loop_threshold)
{
    wjit_config.loop_threshold = loop_threshold < 1 ? 1 : (uint32_t)loop_threshold;
    wjit_config.enabled = (flags & 1) != 0;
    wjit_config.inline_ops = (flags & 2) == 0;
    wjit_config.off = ((uint32_t)flags >> 8) & 0xff;
    wjit_config.call_threshold = call_threshold < 1 ? 1 : (uint32_t)call_threshold;
    wjit_config.max_functions = max_functions < 0 ? 0 : (uint32_t)max_functions;
    wjit_config.max_bytecode_bytes = max_bytecode_bytes < 1 ? 1 : (uint32_t)max_bytecode_bytes;
}

/* ops run through wjit_step, by opcode (what to compile inline next) */
static uint32_t wjit_step_ops[256];

WJIT_EXPORT("wj_jit_step_count")
uint32_t wj_jit_step_count(int32_t op) { return op >= 0 && op < 256 ? wjit_step_ops[op] : 0; }

WJIT_EXPORT("wj_jit_stat")
double wj_jit_stat(int32_t which)
{
    const double *s = (const double *)&wjit_stats;
    if (which < 0 || which >= (int32_t)(sizeof(wjit_stats) / sizeof(double)))
        return -1;
    return s[which];
}

/* paths the testing flags of wj_jit_configure (bits 8..15) turn off */
#define WJIT_OFF_PUT_FIELD 1      /* property writes: step */
#define WJIT_OFF_ARRAY 2          /* array elements: step */
#define WJIT_OFF_NUMBERS 4        /* doubles, identity equality, ToInt32: step */
#define WJIT_OFF_CALL 8           /* calls: step */
#define WJIT_OFF_GLOBAL 16        /* global reads: step */
#define WJIT_OFF_FIELD 32         /* property reads: step */

/* ---- inline caches --------------------------------------------------------------------------------------------
 * One per property access site (get_field, get_field2, get_length, put_field) of a compiled function. Keyed by the
 * receiver's shape, which the cache holds a counted reference to: a shared shape is never changed in place (QuickJS
 * clones a hashed shape with other users before adding, deleting or redefining a property; an unhashed one, the shape of an
 * object that had a property deleted, belongs to its object alone and is changed and reallocated in place, whatever its count:
 * such shapes are never cached), so while cached the receiver's
 * property layout, and its prototype (part of the shape), cannot change under the cache. When the property is found
 * on a prototype (WJIT_IC_DEPTH levels up at most: the DOM's getters are on Element.prototype or Node.prototype), the
 * shape of every prototype on the way is held and checked the same way: each fixes the next prototype and proves the
 * property is not on it. Values are always read from the object, never cached. The function's bytecode reports these
 * references to the cycle collector (wjit_mark). */

#define WJIT_IC_DEPTH 6

typedef struct WJitIC {
    JSShape *shape;          /* receiver's shape at the last fill (counted), NULL: empty */
    JSShape *own;            /* == shape when the property is the receiver's own plain data property: the inline path */
    JSObject *holder;        /* the prototype that has it, NULL when own */
    JSShape *holder_shape;   /* its shape at the fill (counted) */
    uint32_t index;          /* in prop[] of the receiver or of the holder */
    uint16_t kind;           /* 0 data, 1 accessor */
    uint16_t depth;          /* of the holder: 0 own, 1 the receiver's prototype... */
    JSShape *protos[WJIT_IC_DEPTH - 1];   /* the shapes of the prototypes between (counted) */
} WJitIC;

typedef struct WJitData {
    uint32_t nic;
    WJitIC ic[];
} WJitData;

static void wjit_ic_clear(JSRuntime *rt, WJitIC *ic)
{
    if (ic->shape)
        js_free_shape(rt, ic->shape);
    if (ic->holder_shape)
        js_free_shape(rt, ic->holder_shape);
    for (int i = 0; i + 1 < ic->depth; i++)
        js_free_shape(rt, ic->protos[i]);
    memset(ic, 0, sizeof(*ic));
}

static void wjit_release(JSRuntime *rt, JSFunctionBytecode *b)
{
    WJitData *d = b->wjit_data;
    uint32_t i;
    if (!d)
        return;
    b->wjit_data = NULL;
    for (i = 0; i < d->nic; i++)
        wjit_ic_clear(rt, &d->ic[i]);
    js_free_rt(rt, d);
}

static void wjit_mark(JSRuntime *rt, JSFunctionBytecode *b, JS_MarkFunc *mark_func)
{
    WJitData *d = b->wjit_data;
    uint32_t i;
    if (!d)
        return;
    for (i = 0; i < d->nic; i++) {
        if (d->ic[i].shape)
            mark_func(rt, &d->ic[i].shape->header);
        if (d->ic[i].holder_shape)
            mark_func(rt, &d->ic[i].holder_shape->header);
        for (int k = 0; k + 1 < d->ic[i].depth; k++)
            mark_func(rt, &d->ic[i].protos[k]->header);
    }
}

/* fills ic: the property is at prop[index] of h, `depth` prototypes up from p0 (all shapes hashed: checked by the
   callers) */
static void wjit_ic_set(JSRuntime *rt, WJitIC *ic, JSObject *p0, JSObject *h, int depth, uint32_t index, int kind)
{
    JSObject *q;
    int i;
    wjit_ic_clear(rt, ic);
    ic->shape = js_dup_shape(p0->shape);
    ic->index = index;
    ic->kind = (uint16_t)kind;
    ic->depth = (uint16_t)depth;
    if (depth == 0) {
        if (!kind)
            ic->own = p0->shape;
        return;
    }
    q = p0->shape->proto;
    for (i = 0; i + 1 < depth; i++) {
        ic->protos[i] = js_dup_shape(q->shape);
        q = q->shape->proto;
    }
    ic->holder = h;
    ic->holder_shape = js_dup_shape(h->shape);
}

/* a read of atom on p0: cached when it is an own data or accessor property, or one of its prototypes' */
static void wjit_ic_fill_get(JSRuntime *rt, WJitIC *ic, JSObject *p0, JSAtom atom)
{
    JSObject *p = p0;
    JSShapeProperty *prs;
    JSProperty *pr;
    int depth, t;
    if (!p0->shape->is_hashed)
        return;
    for (depth = 0; depth < WJIT_IC_DEPTH; depth++) {
        if (!p->shape->is_hashed)
            return;
        prs = find_own_property(&pr, p, atom);
        if (prs) {
            t = prs->flags & JS_PROP_TMASK;
            if (t != 0 && t != JS_PROP_GETSET)
                return;
            wjit_ic_set(rt, ic, p0, p, depth, (uint32_t)(pr - p->prop), t ? 1 : 0);
            return;
        }
        if (p->is_exotic)
            return;
        p = p->shape->proto;
        if (!p)
            return;
    }
}

/* the prototype of the receiver (shape ic->shape) that has the property, when every shape on the way is still the
   cached one; NULL otherwise */
static inline JSObject *wjit_ic_holder(WJitIC *ic, JSObject *p)
{
    JSObject *h;
    int i;
    if (p->is_exotic)
        return NULL;
    h = ic->shape->proto;
    for (i = 0; i + 1 < ic->depth; i++) {
        if (h->shape != ic->protos[i] || h->is_exotic)
            return NULL;
        h = h->shape->proto;
    }
    return h->shape == ic->holder_shape ? h : NULL;
}

/* a write of atom on p0: cached when it is an own writable data property, or a setter of a prototype */
static void wjit_ic_fill_put(JSRuntime *rt, WJitIC *ic, JSObject *p0, JSAtom atom)
{
    JSShapeProperty *prs;
    JSProperty *pr;
    JSObject *p = p0;
    int depth;
    for (depth = 0; depth < WJIT_IC_DEPTH; depth++) {
        if (!p->shape->is_hashed)
            return;
        prs = find_own_property(&pr, p, atom);
        if (prs) {
            if (depth == 0) {
                if ((prs->flags & (JS_PROP_TMASK | JS_PROP_WRITABLE | JS_PROP_LENGTH)) != JS_PROP_WRITABLE)
                    return;
                wjit_ic_set(rt, ic, p0, p0, 0, (uint32_t)(pr - p0->prop), 0);
            } else if ((prs->flags & JS_PROP_TMASK) == JS_PROP_GETSET) {
                wjit_ic_set(rt, ic, p0, p, depth, (uint32_t)(pr - p->prop), 1);
            }
            /* (a data property of a prototype: the write adds an own property, a new shape) */
            return;
        }
        if (p->is_exotic)
            return;
        p = p->shape->proto;
        if (!p)
            return;
    }
}

/* ---- helpers the compiled code imports (exports of the engine) ------------------------------------------------ */

/* get_field, get_field2, get_length (pc: the op) through the site's cache; the compiled code took the own-data case
   already when it could */
WJIT_EXPORT("wjit_get_field")
int32_t wjit_get_field(WJitFrame *jf, JSValue *sp, uint8_t *pc, WJitIC *ic)
{
    JSContext *ctx = jf->ctx;
    int op = pc[0];
    JSAtom atom = op == OP_get_length ? JS_ATOM_length : get_u32(pc + 1);
    uint8_t *next = pc + (op == OP_get_length ? 1 : 5);
    JSValue obj = sp[-1], val;
    if (JS_VALUE_GET_TAG(obj) == JS_TAG_OBJECT) {
        JSObject *p = JS_VALUE_GET_OBJ(obj), *h = p;
        JSProperty *pr;
        if (p->shape == ic->shape) {
            if (ic->depth && !(h = wjit_ic_holder(ic, p)))
                goto miss;
            pr = &h->prop[ic->index];
            if (ic->kind == 0) {
                val = js_dup(pr->u.value);
                goto got;
            }
            if (!pr->u.getset.getter) {
                val = JS_UNDEFINED;
                goto got;
            }
            jf->sf->cur_pc = next;
            val = js_call_getter(ctx, pr->u.getset.getter, obj);
            if (JS_IsException(val))
                goto exc;
            goto got;
        }
    miss:
        wjit_ic_fill_get(ctx->rt, ic, p, atom);
    }
    jf->sf->cur_pc = next;
    val = JS_GetPropertyInternal(ctx, obj, atom, obj, false);
    if (JS_IsException(val))
        goto exc;
 got:
    if (op == OP_get_field2) {
        sp[0] = val;
    } else {
        JS_FreeValue(ctx, sp[-1]);
        sp[-1] = val;
    }
    return WJIT_OK;
 exc:
    jf->pc = next;
    jf->sp = sp;
    return WJIT_EXC;
}

WJIT_EXPORT("wjit_put_field")
int32_t wjit_put_field(WJitFrame *jf, JSValue *sp, uint8_t *pc, WJitIC *ic)
{
    JSContext *ctx = jf->ctx;
    JSAtom atom = get_u32(pc + 1);
    uint8_t *next = pc + 5;
    JSValue obj = sp[-2], val = sp[-1];
    int ret;
    if (JS_VALUE_GET_TAG(obj) == JS_TAG_OBJECT) {
        JSObject *p = JS_VALUE_GET_OBJ(obj), *h;
        if (p->shape == ic->shape) {
            if (!ic->depth) {
                set_value(ctx, &p->prop[ic->index].u.value, val);
                JS_FreeValue(ctx, obj);
                return WJIT_OK;
            }
            if ((h = wjit_ic_holder(ic, p)) && h->prop[ic->index].u.getset.setter) {
                jf->sf->cur_pc = next;
                ret = call_setter(ctx, h->prop[ic->index].u.getset.setter, obj, val, JS_PROP_THROW_STRICT);
                JS_FreeValue(ctx, obj);
                goto done;
            }
        }
        wjit_ic_fill_put(ctx->rt, ic, p, atom);
    }
    jf->sf->cur_pc = next;
    ret = JS_SetPropertyInternal2(ctx, obj, atom, val, obj, JS_PROP_THROW_STRICT);
    JS_FreeValue(ctx, obj);
 done:
    if (ret < 0) {
        jf->pc = next;
        jf->sp = sp - 2;
        return WJIT_EXC;
    }
    return WJIT_OK;
}

/* get_var, get_var_undef through the site's cache: the global lexical scope's shape (the variable is not declared
   there, or it is and its slot is known) and, for a property of the global object, that object's shape */
WJIT_EXPORT("wjit_get_var")
int32_t wjit_get_var(WJitFrame *jf, JSValue *sp, uint8_t *pc, WJitIC *ic)
{
    JSContext *ctx = jf->ctx;
    JSAtom atom = get_u32(pc + 1);
    uint8_t *next = pc + 5;
    JSObject *vo = JS_VALUE_GET_OBJ(ctx->global_var_obj), *go = JS_VALUE_GET_OBJ(ctx->global_obj);
    JSShapeProperty *prs;
    JSProperty *pr;
    JSValue val;
    if (vo->shape == ic->shape && ic->holder) {
        if (ic->holder == vo) {
            val = vo->prop[ic->index].u.value;
            if (!JS_IsUninitialized(val)) {
                sp[0] = js_dup(val);
                return WJIT_OK;
            }
        } else if (go->shape == ic->holder_shape) {
            sp[0] = js_dup(go->prop[ic->index].u.value);
            return WJIT_OK;
        }
    }
    /* fill: where JS_GetGlobalVar finds it without conversion (hashed shapes only, as wjit_ic_fill_get) */
    prs = find_own_property(&pr, vo, atom);
    if (!vo->shape->is_hashed) {
        /* not cached */
    } else if (prs) {
        wjit_ic_clear(ctx->rt, ic);
        ic->shape = js_dup_shape(vo->shape);
        ic->holder = vo;
        ic->index = (uint32_t)(pr - vo->prop);
    } else if (go->shape->is_hashed && (prs = find_own_property(&pr, go, atom)) && (prs->flags & JS_PROP_TMASK) == 0) {
        wjit_ic_clear(ctx->rt, ic);
        ic->shape = js_dup_shape(vo->shape);
        ic->holder = go;
        ic->holder_shape = js_dup_shape(go->shape);
        ic->index = (uint32_t)(pr - go->prop);
    }
    jf->sf->cur_pc = next;
    val = JS_GetGlobalVar(ctx, atom, pc[0] == OP_get_var);
    if (JS_IsException(val)) {
        jf->pc = next;
        jf->sp = sp;
        return WJIT_EXC;
    }
    sp[0] = val;
    return WJIT_OK;
}

/* call, call0..3, call_method, call_constructor, tail_call, tail_call_method (pc: the op): the interpreter's code
   without its dispatch */
WJIT_EXPORT("wjit_call")
int32_t wjit_call(WJitFrame *jf, JSValue *sp, uint8_t *pc)
{
    JSContext *ctx = jf->ctx;
    int op = pc[0], argc, n, i;
    JSValue *argv, ret;
    uint8_t *next;
    if (op >= OP_call0 && op <= OP_call3) {
        argc = op - OP_call0;
        next = pc + 1;
    } else {
        argc = get_u16(pc + 1);
        next = pc + 3;
    }
    argv = sp - argc;
    jf->sf->cur_pc = next;
    if (op == OP_call_method || op == OP_tail_call_method) {
        ret = JS_CallInternal(ctx, argv[-1], argv[-2], JS_UNDEFINED, argc, vc(argv), 0);
        n = 2;
    } else if (op == OP_call_constructor) {
        ret = JS_CallConstructorInternal(ctx, argv[-2], argv[-1], argc, vc(argv), 0);
        n = 2;
    } else {
        ret = JS_CallInternal(ctx, argv[-1], JS_UNDEFINED, JS_UNDEFINED, argc, vc(argv), 0);
        n = 1;
    }
    if (unlikely(JS_IsException(ret))) {
        jf->pc = next;
        jf->sp = sp;
        return WJIT_EXC;
    }
    if (op == OP_tail_call || op == OP_tail_call_method) {
        /* the function returns it; its frame (the call's operands included) is freed by the interpreter */
        jf->ret = ret;
        jf->sp = sp;
        return WJIT_RET;
    }
    for (i = -n; i < argc; i++)
        JS_FreeValue(ctx, argv[i]);
    sp[-argc - n] = ret;
    return WJIT_OK;
}

/* One op with the interpreter's own code, on the frame's memory. 0: done (the static stack depth after it holds),
   WJIT_EXC: it threw (jf->pc, jf->sp set), WJIT_RET: the function returned (tail calls; jf->ret, jf->sp). */
WJIT_EXPORT("wjit_step")
int32_t wjit_step(WJitFrame *jf, uint8_t *pc, JSValue *sp)
{
    JSContext *caller_ctx = jf->caller_ctx;
    JSContext *ctx = jf->ctx;
    JSRuntime *rt = ctx->rt;
    JSStackFrame *sf = jf->sf;
    JSObject *p = jf->p;
    JSFunctionBytecode *b = jf->b;
    JSValue *local_buf = jf->local_buf, *stack_buf = jf->stack_buf, *var_buf = jf->var_buf, *arg_buf = jf->arg_buf;
    JSValue ret_val, *pval;
    JSVarRef **var_refs = jf->var_refs;
    JSValueConst func_obj = jf->func_obj, this_obj = jf->this_obj, new_target = jf->new_target;
    JSValueConst *argv = jf->argv;
    int argc = jf->argc, flags = jf->flags;
    int opcode, i;
    (void)caller_ctx; (void)rt; (void)p; (void)local_buf; (void)stack_buf; (void)var_buf; (void)arg_buf;
    (void)pval; (void)var_refs; (void)func_obj; (void)this_obj; (void)new_target; (void)argv; (void)argc;
    (void)flags; (void)i; (void)b;
    wjit_stats.steps++;
    wjit_step_ops[*pc]++;
#undef SWITCH
#undef CASE
#undef DEFAULT
#undef BREAK
#define SWITCH(pc)      switch (opcode = *pc++)
#define CASE(op)        case op
#define DEFAULT         default
#define BREAK           goto wjit_step_ok
#undef WJIT_LOOP
#define WJIT_LOOP() ((void)0)   /* (branches are never run through wjit_step) */
    {
        int call_argc;
        JSValue *call_argv;
        (void)call_argc; (void)call_argv;
        SWITCH(pc) {
#include "wjit_step_body.h"
        }
    }
 wjit_step_ok:
    return WJIT_OK;
 exception:
    jf->pc = pc;
    jf->sp = sp;
    return WJIT_EXC;
 done:
    jf->ret = ret_val;
    jf->sp = sp;
    return WJIT_RET;
 done_generator:
    abort();   /* generators are never compiled */
#undef SWITCH
#undef CASE
#undef DEFAULT
#undef BREAK
}

/* JS_FreeValue once the count reached zero (the compiled code decrements it inline) */
WJIT_EXPORT("wjit_free")
void wjit_free(JSContext *ctx, JSValue v)
{
    js_free_value_rt(ctx->rt, v);
}

WJIT_EXPORT("wjit_decref")
void wjit_decref(JSContext *ctx, JSValue v)
{
    JS_FreeValue(ctx, v);
}

WJIT_EXPORT("wjit_poll")
int32_t wjit_poll(JSContext *ctx)
{
    return __js_poll_interrupts(ctx);
}

WJIT_EXPORT("wjit_to_bool")
int32_t wjit_to_bool(JSContext *ctx, JSValue v)
{
    return JS_ToBoolFree(ctx, v);
}

/* ---- a small Wasm writer ------------------------------------------------------------------------------------- */

typedef struct WBuf { uint8_t *p; uint32_t n, cap; int oom; } WBuf;

static void wb_reserve(WBuf *w, uint32_t more)
{
    uint32_t cap;
    uint8_t *q;
    if (w->oom || w->n + more <= w->cap)
        return;
    cap = w->cap ? w->cap * 2 : 1024;
    while (cap < w->n + more)
        cap *= 2;
    q = realloc(w->p, cap);
    if (!q) { w->oom = 1; return; }
    w->p = q;
    w->cap = cap;
}
static void wb_u8(WBuf *w, uint8_t b) { wb_reserve(w, 1); if (!w->oom) w->p[w->n++] = b; }
static void wb_bytes(WBuf *w, const void *p, uint32_t n) { wb_reserve(w, n); if (!w->oom) { memcpy(w->p + w->n, p, n); w->n += n; } }
static void wb_uleb(WBuf *w, uint64_t v) { do { uint8_t b = v & 0x7f; v >>= 7; if (v) b |= 0x80; wb_u8(w, b); } while (v); }
static void wb_sleb(WBuf *w, int64_t v)
{
    for (;;) {
        uint8_t b = v & 0x7f;
        v >>= 7;
        if ((v == 0 && !(b & 0x40)) || (v == -1 && (b & 0x40))) { wb_u8(w, b); return; }
        wb_u8(w, b | 0x80);
    }
}
static void wb_name(WBuf *w, const char *s) { uint32_t n = (uint32_t)strlen(s); wb_uleb(w, n); wb_bytes(w, s, n); }
static void wb_section(WBuf *w, uint8_t id, WBuf *body) { wb_u8(w, id); wb_uleb(w, body->n); wb_bytes(w, body->p, body->n); }

/* opcodes */
enum {
    W_UNREACHABLE = 0x00, W_BLOCK = 0x02, W_LOOP = 0x03, W_IF = 0x04, W_ELSE = 0x05, W_END = 0x0b, W_BR = 0x0c,
    W_BR_IF = 0x0d, W_RETURN = 0x0f, W_CALL = 0x10, W_DROP = 0x1a, W_SELECT = 0x1b,
    W_LGET = 0x20, W_LSET = 0x21, W_LTEE = 0x22,
    W_I32_LOAD = 0x28, W_I64_LOAD = 0x29, W_I32_LOAD16_U = 0x2f, W_I32_STORE = 0x36, W_I64_STORE = 0x37,
    W_I32_CONST = 0x41, W_I64_CONST = 0x42, W_F64_CONST = 0x44,
    W_I32_EQZ = 0x45, W_I32_EQ = 0x46, W_I32_NE = 0x47, W_I32_LT_S = 0x48, W_I32_LT_U = 0x49, W_I32_GT_S = 0x4a,
    W_I32_GT_U = 0x4b, W_I32_LE_S = 0x4c, W_I32_LE_U = 0x4d, W_I32_GE_S = 0x4e, W_I32_GE_U = 0x4f,
    W_I64_EQZ = 0x50, W_I64_EQ = 0x51, W_I64_NE = 0x52,
    W_F64_EQ = 0x61, W_F64_NE = 0x62, W_F64_LT = 0x63, W_F64_GT = 0x64, W_F64_LE = 0x65, W_F64_GE = 0x66,
    W_I32_ADD = 0x6a, W_I32_SUB = 0x6b, W_I32_MUL = 0x6c, W_I32_AND = 0x71, W_I32_OR = 0x72, W_I32_XOR = 0x73,
    W_I32_SHL = 0x74, W_I32_SHR_S = 0x75, W_I32_SHR_U = 0x76,
    W_I64_ADD = 0x7c, W_I64_SUB = 0x7d, W_I64_MUL = 0x7e, W_I64_AND = 0x83, W_I64_OR = 0x84, W_I64_XOR = 0x85,
    W_I64_SHL = 0x86, W_I64_SHR_S = 0x87, W_I64_SHR_U = 0x88,
    W_F64_NEG = 0x9a, W_F64_ADD = 0xa0, W_F64_SUB = 0xa1, W_F64_MUL = 0xa2, W_F64_DIV = 0xa3,
    W_I32_WRAP_I64 = 0xa7, W_I64_EXTEND_I32_S = 0xac, W_I64_EXTEND_I32_U = 0xad, W_F64_CONVERT_I32_S = 0xb7,
    W_I64_REINTERPRET_F64 = 0xbd, W_F64_REINTERPRET_I64 = 0xbf,
};
#define W_VOID 0x40
#define W_TI32 0x7f
#define W_TI64 0x7e
#define W_TF64 0x7c

/* imported functions (indices) and the compiled function's locals */
/* the reference count decremented inline (else in wjit_decref: smaller code) */
#ifndef WJIT_INLINE_DECREF
#define WJIT_INLINE_DECREF 1
#endif

enum { WF_STEP, WF_FREE, WF_POLL, WF_TO_BOOL, WF_GET_FIELD, WF_PUT_FIELD, WF_CALL, WF_GET_VAR, WF_DECREF, WF_COUNT };
enum {
    LP_JF = 0, LP_ENTRY = 1,
    L_CTX = 2, L_SB, L_VB, L_AB, L_VR, L_R, L_I0, L_I1,   /* i32: 2..9 */
    L_A0 = 10, L_A1, L_A2, L_A3, L_A4, L_A5, L_A6, L_A7,  /* i64: 10..17 */
    L_F0 = 18, L_F1 = 19,                                  /* f64 */
};
#define WJIT_N_I32 8
#define WJIT_N_I64 8
#define WJIT_N_F64 2

/* ---- code emission ------------------------------------------------------------------------------------------- */

#define WJIT_MAX_OSR 16
#define WJIT_NOENTRY 4   /* the compiled code has no entry at that pc: nothing was done */

typedef struct WJitC {
    JSContext *ctx;
    JSFunctionBytecode *b;
    WBuf code;
    const uint8_t *bc;
    int len;
    int16_t *depth;        /* stack depth before each instruction, -1: not reached */
    int32_t *catch_pos;    /* innermost catch at each instruction (compute_stack_size's rule) */
    int32_t *blk_of;       /* block index of the instruction starting a block, -1 otherwise */
    int nblk;
    int32_t *blk_start;    /* per block */
    int32_t *loop_end;     /* per block: last block of the loop it heads, -1 when not a header */
    /* structured constructs */
    int ncons;
    struct WJitCons { int kind; int start, end; } *cons;   /* kind 0 block (end = target), 1 loop (start = header),
                                                              2 entry block (from the prologue to an OSR entry) */
    int *stack;            /* open constructs (indices into cons) */
    int nstack;
    int nosr;
    int osr_blk[WJIT_MAX_OSR];   /* loop headers the interpreter may enter the code at (on-stack replacement) */
    const char *why;       /* why it was refused */
    WJitData *data;        /* the inline caches */
    uint32_t nic_used;
} WJitC;

static void e_op(WJitC *c, uint8_t op) { wb_u8(&c->code, op); }
static void e_lget(WJitC *c, int l) { wb_u8(&c->code, W_LGET); wb_uleb(&c->code, (uint32_t)l); }
static void e_lset(WJitC *c, int l) { wb_u8(&c->code, W_LSET); wb_uleb(&c->code, (uint32_t)l); }
static void e_ltee(WJitC *c, int l) { wb_u8(&c->code, W_LTEE); wb_uleb(&c->code, (uint32_t)l); }
static void e_i32(WJitC *c, int32_t v) { wb_u8(&c->code, W_I32_CONST); wb_sleb(&c->code, v); }
static void e_i64(WJitC *c, int64_t v) { wb_u8(&c->code, W_I64_CONST); wb_sleb(&c->code, v); }
static void e_mem(WJitC *c, uint8_t op, uint32_t align, uint32_t off) { wb_u8(&c->code, op); wb_uleb(&c->code, align); wb_uleb(&c->code, off); }
static void e_ld64(WJitC *c, int base, uint32_t off) { e_lget(c, base); e_mem(c, W_I64_LOAD, 3, off); }
static void e_ld32(WJitC *c, int base, uint32_t off) { e_lget(c, base); e_mem(c, W_I32_LOAD, 2, off); }
static void e_call(WJitC *c, int f) { wb_u8(&c->code, W_CALL); wb_uleb(&c->code, (uint32_t)f); }
static void e_block(WJitC *c, uint8_t kind) { wb_u8(&c->code, kind); wb_u8(&c->code, W_VOID); }
static void e_br(WJitC *c, uint8_t op, int depth) { wb_u8(&c->code, op); wb_uleb(&c->code, (uint32_t)depth); }

/* stack slot d (0 = bottom of the operand stack) */
#define SLOT(d) ((uint32_t)(d) * 8u)

static void e_store_slot_from(WJitC *c, int d, int l) { e_lget(c, L_SB); e_lget(c, l); e_mem(c, W_I64_STORE, 3, SLOT(d)); }
static void e_load_slot_to(WJitC *c, int d, int l) { e_ld64(c, L_SB, SLOT(d)); e_lset(c, l); }
static void e_store_const_slot(WJitC *c, int d, uint64_t v) { e_lget(c, L_SB); e_i64(c, (int64_t)v); e_mem(c, W_I64_STORE, 3, SLOT(d)); }

/* tag (high 32 bits) of the i64 in local l, as an i32 on the stack */
static void e_tag(WJitC *c, int l) { e_lget(c, l); e_i64(c, 32); e_op(c, W_I64_SHR_U); e_op(c, W_I32_WRAP_I64); }

/* js_dup of the value in local l */
static void e_dup(WJitC *c, int l)
{
    e_tag(c, l); e_i32(c, JS_TAG_FIRST); e_op(c, W_I32_GE_U);
    e_block(c, W_IF);
      e_lget(c, l); e_op(c, W_I32_WRAP_I64); e_i32(c, 4); e_op(c, W_I32_SUB); e_ltee(c, L_I0);
      e_lget(c, L_I0); e_mem(c, W_I32_LOAD, 2, 0); e_i32(c, 1); e_op(c, W_I32_ADD);
      e_mem(c, W_I32_STORE, 2, 0);
    e_op(c, W_END);
}

/* JS_FreeValue of the value in local l */
static void e_free(WJitC *c, int l)
{
    e_tag(c, l); e_i32(c, JS_TAG_FIRST); e_op(c, W_I32_GE_U);
    e_block(c, W_IF);
    if (!WJIT_INLINE_DECREF) {
        /* smaller code (compiles faster): the count in the helper */
        e_lget(c, L_CTX); e_lget(c, l); e_call(c, WF_DECREF);
        e_op(c, W_END);
        return;
    }
      e_lget(c, l); e_op(c, W_I32_WRAP_I64); e_i32(c, 4); e_op(c, W_I32_SUB); e_ltee(c, L_I0);
      e_lget(c, L_I0); e_mem(c, W_I32_LOAD, 2, 0); e_i32(c, 1); e_op(c, W_I32_SUB); e_ltee(c, L_I1);
      e_mem(c, W_I32_STORE, 2, 0);
      e_lget(c, L_I1); e_i32(c, 0); e_op(c, W_I32_LE_S);
      e_block(c, W_IF);
        e_lget(c, L_CTX); e_lget(c, l); e_call(c, WF_FREE);
      e_op(c, W_END);
    e_op(c, W_END);
}

static uint32_t pc_abs(WJitC *c, int pos) { return (uint32_t)(uintptr_t)(c->bc + pos); }

/* leaves the function: jf->pc = pc(pos), jf->sp = slot(d), return code */
static void e_exit(WJitC *c, int code, int pos, int d)
{
    e_lget(c, LP_JF); e_i32(c, (int32_t)pc_abs(c, pos)); e_mem(c, W_I32_STORE, 2, offsetof(WJitFrame, pc));
    e_lget(c, LP_JF); e_lget(c, L_SB); e_i32(c, (int32_t)SLOT(d)); e_op(c, W_I32_ADD); e_mem(c, W_I32_STORE, 2, offsetof(WJitFrame, sp));
    e_i32(c, code); e_op(c, W_RETURN);
}

/* the op at pos through wjit_step, the operand stack at depth d; returns from the function unless it completed */
static void e_step(WJitC *c, int pos, int d)
{
    e_lget(c, LP_JF); e_i32(c, (int32_t)pc_abs(c, pos));
    e_lget(c, L_SB); e_i32(c, (int32_t)SLOT(d)); e_op(c, W_I32_ADD);
    e_call(c, WF_STEP); e_ltee(c, L_R);
    e_block(c, W_IF); e_lget(c, L_R); e_op(c, W_RETURN); e_op(c, W_END);
}

/* interrupt poll (js_poll_interrupts) at a branch; an exception leaves with the pc of `pos_after` */
static void e_poll(WJitC *c, int pos_after, int d)
{
    uint32_t off = offsetof(JSContext, interrupt_counter);
    e_lget(c, L_CTX); e_lget(c, L_CTX); e_mem(c, W_I32_LOAD, 2, off); e_i32(c, 1); e_op(c, W_I32_SUB); e_ltee(c, L_I0);
    e_mem(c, W_I32_STORE, 2, off);
    e_lget(c, L_I0); e_i32(c, 0); e_op(c, W_I32_LE_S);
    e_block(c, W_IF);
      e_lget(c, L_CTX); e_call(c, WF_POLL);
      e_block(c, W_IF); e_exit(c, WJIT_EXC, pos_after, d); e_op(c, W_END);
    e_op(c, W_END);
}

/* ---- control-flow structure ---------------------------------------------------------------------------------- */

static int wjit_cons_find(WJitC *c, int kind, int key)
{
    int i;
    for (i = c->nstack - 1; i >= 0; i--) {
        struct WJitCons *k = &c->cons[c->stack[i]];
        if (k->kind == kind && (kind == 0 ? k->end == key : k->start == key))
            return c->nstack - 1 - i;
    }
    return -1;
}

/* branch from the current block to block t (forward: the block construct ending at t; backward: the loop at t) */
static int e_branch(WJitC *c, uint8_t op, int from, int t)
{
    int depth = t <= from ? wjit_cons_find(c, 1, t) : wjit_cons_find(c, 0, t);
    if (depth < 0) { c->why = "branch target not in scope"; return -1; }
    e_br(c, op, depth);
    return 0;
}

static int wjit_label_target(const uint8_t *bc, int pos, int op)
{
    switch (op) {
    case OP_goto: case OP_if_true: case OP_if_false: case OP_catch: case OP_gosub:
        return pos + 1 + (int32_t)get_u32(bc + pos + 1);
    case OP_goto16:
        return pos + 1 + (int16_t)get_u16(bc + pos + 1);
    case OP_goto8: case OP_if_true8: case OP_if_false8:
        return pos + 1 + (int8_t)bc[pos + 1];
    default:
        return -1;
    }
}

/* ops after which the interpreter does not fall through */
static int wjit_is_terminator(int op)
{
    switch (op) {
    case OP_return: case OP_return_undef: case OP_throw: case OP_throw_error: case OP_tail_call:
    case OP_tail_call_method: case OP_goto: case OP_goto8: case OP_goto16:
        return 1;
    default:
        return 0;
    }
}

/* ops the compiled code does not handle: the interpreter takes over there */
static int wjit_is_exit(int op)
{
    switch (op) {
    case OP_invalid: case OP_gosub: case OP_ret: case OP_with_get_var: case OP_with_put_var: case OP_with_delete_var:
    case OP_with_make_ref: case OP_with_get_ref: case OP_with_get_ref_undef: case OP_return_async:
    case OP_initial_yield: case OP_yield: case OP_yield_star: case OP_async_yield_star: case OP_await:
    case OP_for_await_of_start:
        return 1;
    default:
        return op >= OP_COUNT;
    }
}

static int wjit_is_branch(int op)
{
    switch (op) {
    case OP_goto: case OP_goto8: case OP_goto16: case OP_if_true: case OP_if_false: case OP_if_true8: case OP_if_false8:
        return 1;
    default:
        return 0;
    }
}

/* stack depths (compute_stack_size's walk, catch levels included); marks the reached instructions */
static int wjit_analyze(WJitC *c)
{
    const uint8_t *bc = c->bc;
    int len = c->len, n = 0, pos, i;
    int32_t *work = js_malloc_rt(c->ctx->rt, sizeof(int32_t) * (len + 1));
    if (!work) { c->why = "out of memory"; return -1; }
    for (i = 0; i < len; i++) { c->depth[i] = -1; c->catch_pos[i] = -1; }
#define WJIT_PUSH(at, dep, cp) do { \
        int at_ = (at); \
        if (at_ < 0 || at_ >= len) { c->why = "jump out of the function"; goto fail; } \
        if (c->depth[at_] < 0) { c->depth[at_] = (int16_t)(dep); c->catch_pos[at_] = (cp); work[n++] = at_; } \
        else if (c->depth[at_] != (dep)) { c->why = "inconsistent stack depth"; goto fail; } \
    } while (0)
    WJIT_PUSH(0, 0, -1);
    while (n > 0) {
        int op, stack_len, catch_pos, n_pop, next, level, catch_level;
        const JSOpCode *oi;
        pos = work[--n];
        op = bc[pos];
        stack_len = c->depth[pos];
        catch_pos = c->catch_pos[pos];
        if (op == 0 || op >= OP_COUNT) { c->why = "invalid opcode"; goto fail; }
        oi = &short_opcode_info(op);
        if (pos + oi->size > len) { c->why = "truncated"; goto fail; }
        if (wjit_is_exit(op))
            continue;
        n_pop = oi->n_pop;
        if (oi->fmt == OP_FMT_npop || oi->fmt == OP_FMT_npop_u16)
            n_pop += get_u16(bc + pos + 1);
        else if (oi->fmt == OP_FMT_npopx)
            n_pop += op - OP_call0;
        if (stack_len < n_pop) { c->why = "stack underflow"; goto fail; }
        stack_len += oi->n_push - n_pop;
        next = pos + oi->size;
        switch (op) {
        case OP_tail_call: case OP_tail_call_method: case OP_return: case OP_return_undef: case OP_throw:
        case OP_throw_error:
            continue;
        case OP_goto: case OP_goto16: case OP_goto8:
            next = wjit_label_target(bc, pos, op);
            break;
        case OP_if_true: case OP_if_false: case OP_if_true8: case OP_if_false8:
            WJIT_PUSH(wjit_label_target(bc, pos, op), stack_len, catch_pos);
            break;
        case OP_catch:
            /* its target is only reached by an exception: the interpreter's business */
            catch_pos = pos;
            break;
        case OP_for_of_start: case OP_for_await_of_start:
            catch_pos = pos;
            break;
        case OP_drop: catch_level = stack_len; goto check_catch;
        case OP_nip: case OP_nip1: catch_level = stack_len - 1; goto check_catch;
        case OP_iterator_close:
            catch_level = stack_len + 2;
        check_catch:
            if (catch_pos >= 0) {
                level = c->depth[catch_pos];
                if (bc[catch_pos] != OP_catch)
                    level++;
                if (catch_level == level)
                    catch_pos = c->catch_pos[catch_pos];
            }
            break;
        case OP_nip_catch:
            if (catch_pos < 0) { c->why = "nip_catch without catch"; goto fail; }
            stack_len = c->depth[catch_pos];
            if (bc[catch_pos] != OP_catch)
                stack_len++;
            stack_len++;
            catch_pos = c->catch_pos[catch_pos];
            break;
        default:
            break;
        }
        WJIT_PUSH(next, stack_len, catch_pos);
    }
#undef WJIT_PUSH
    js_free_rt(c->ctx->rt, work);
    return 0;
 fail:
    js_free_rt(c->ctx->rt, work);
    return -1;
}

/* blocks of reached instructions, loops, and the block/loop constructs that structure the flow */
static int wjit_structure(WJitC *c)
{
    const uint8_t *bc = c->bc;
    int len = c->len, pos, i, j, prev_flow = 0;
    JSRuntime *rt = c->ctx->rt;
    uint8_t *leader = js_mallocz_rt(rt, len + 1);
    if (!leader) { c->why = "out of memory"; return -1; }
    /* leaders: entry, branch targets, what follows a branch or an exit */
    for (pos = 0; pos < len; ) {
        int op = bc[pos], size = short_opcode_info(op).size;
        if (c->depth[pos] >= 0) {
            if (!prev_flow)
                leader[pos] = 1;
            if (wjit_is_branch(op)) {
                leader[wjit_label_target(bc, pos, op)] = 1;
                if (pos + size < len) leader[pos + size] = 1;
            }
            prev_flow = !(wjit_is_terminator(op) || wjit_is_exit(op) || wjit_is_branch(op));
        } else {
            prev_flow = 0;
        }
        pos += size;
    }
    c->nblk = 0;
    for (pos = 0; pos < len; pos += short_opcode_info(bc[pos]).size) {
        c->blk_of[pos] = -1;
        if (c->depth[pos] >= 0 && leader[pos])
            c->blk_start[c->nblk++] = pos;
    }
    for (i = 0; i < c->nblk; i++)
        c->blk_of[c->blk_start[i]] = i;
    js_free_rt(rt, leader);

    /* loops: a back edge x -> h makes h a loop header; the loop spans blocks h..max(x) */
    for (i = 0; i < c->nblk; i++)
        c->loop_end[i] = -1;
    for (i = 0; i < c->nblk; i++) {
        int end = i + 1 < c->nblk ? c->blk_start[i + 1] : len, last = -1, op, t;
        for (pos = c->blk_start[i]; pos < end && c->depth[pos] >= 0; pos += short_opcode_info(bc[pos]).size)
            last = pos;
        op = bc[last];
        if (!wjit_is_branch(op))
            continue;
        t = c->blk_of[wjit_label_target(bc, last, op)];
        if (t < 0) { c->why = "branch to a non-leader"; return -1; }
        if (t <= i && c->loop_end[t] < i)
            c->loop_end[t] = i;
    }
    /* loops must nest; nothing may enter one but through its header */
    for (i = 0; i < c->nblk; i++) {
        if (c->loop_end[i] < 0)
            continue;
        for (j = i + 1; j <= c->loop_end[i]; j++) {
            if (c->loop_end[j] >= 0 && c->loop_end[j] > c->loop_end[i]) { c->why = "overlapping loops"; return -1; }
        }
    }
    c->ncons = 0;
    for (i = 0; i < c->nblk; i++) {
        if (c->loop_end[i] >= 0) {
            c->cons[c->ncons].kind = 1;
            c->cons[c->ncons].start = i;
            c->cons[c->ncons].end = c->loop_end[i] + 1;
            c->ncons++;
        }
    }
    /* forward branches: one block per target, ending at it, starting early enough to enclose its sources and to
       nest with every loop and earlier block */
    for (j = 0; j < c->nblk; j++) {
        int s = -1, changed, k;
        for (i = 0; i < j; i++) {
            int end = i + 1 < c->nblk ? c->blk_start[i + 1] : len, last = -1, op;
            for (pos = c->blk_start[i]; pos < end && c->depth[pos] >= 0; pos += short_opcode_info(bc[pos]).size)
                last = pos;
            op = bc[last];
            if (!wjit_is_branch(op) || c->blk_of[wjit_label_target(bc, last, op)] != j || i + 1 == j)
                continue;
            /* entering a loop elsewhere than at its header */
            for (k = 0; k < c->nblk; k++) {
                if (c->loop_end[k] >= 0 && k < j && j <= c->loop_end[k] && (i < k || i > c->loop_end[k])) {
                    c->why = "irreducible flow";
                    return -1;
                }
            }
            if (s < 0 || i < s)
                s = i;
        }
        if (s < 0)
            continue;
        do {
            changed = 0;
            for (k = 0; k < c->ncons; k++) {
                struct WJitCons *q = &c->cons[k];
                /* leaving a loop: the block encloses it */
                if (q->kind == 1 && q->start < s && s < q->end && j >= q->end) { s = q->start; changed = 1; }
                /* an earlier block it would cross: it encloses that one */
                else if (q->kind == 0 && q->start < s && s < q->end && q->end < j) { s = q->start; changed = 1; }
            }
        } while (changed);
        for (k = 0; k < c->ncons; k++) {
            struct WJitCons *q = &c->cons[k];
            if (q->kind == 1 && s < q->start && q->start < j && j < q->end) { c->why = "block crosses a loop"; return -1; }
        }
        c->cons[c->ncons].kind = 0;
        c->cons[c->ncons].start = s;
        c->cons[c->ncons].end = j;
        c->ncons++;
    }
    /* OSR entries: headers of loops no construct encloses (an entry block from the prologue can then end there) */
    c->nosr = 0;
    for (i = 1; i < c->nblk && c->nosr < WJIT_MAX_OSR; i++) {
        int k, header = 0, inside = 0;
        if (c->loop_end[i] < 0)
            continue;
        for (k = 0; k < c->ncons; k++) {
            struct WJitCons *q = &c->cons[k];
            if (q->kind == 1 && q->start == i) header = 1;
            if (q->start < i && q->end > i) inside = 1;
        }
        if (header && !inside)
            c->osr_blk[c->nosr++] = i;
    }
    return 0;
}

/* ---- per-op code --------------------------------------------------------------------------------------------- */

#define JSV_INT_TAG_ZERO 0

/* pushes JS value constant at slot d */
static void e_push_const(WJitC *c, int d, JSValue v)
{
    if (JS_VALUE_HAS_REF_COUNT(v)) {
        e_i64(c, (int64_t)v); e_lset(c, L_A0);
        e_dup(c, L_A0);
        e_store_slot_from(c, d, L_A0);
    } else {
        e_store_const_slot(c, d, v);
    }
}

/* both values in a0/a1 are ints -> i32 condition */
static void e_both_int(WJitC *c, int a, int b)
{
    e_lget(c, a); e_lget(c, b); e_op(c, W_I64_OR); e_i64(c, 32); e_op(c, W_I64_SHR_U); e_op(c, W_I64_EQZ);
}

/* int32 in i32 local/stack -> JSValue int (i64 on the stack) */
static void e_mk_int(WJitC *c) { e_op(c, W_I64_EXTEND_I32_U); }

static void e_mk_bool_from_i32(WJitC *c) { e_op(c, W_I64_EXTEND_I32_U); e_i64(c, (int64_t)JS_TAG_BOOL << 32); e_op(c, W_I64_OR); }

/* the fast-path frame: block $done { block $slow { <fast> br $done } <slow> } */
static void e_fast_begin(WJitC *c) { e_block(c, W_BLOCK); e_block(c, W_BLOCK); }
static void e_fast_end_slow(WJitC *c) { e_br(c, W_BR, 1); e_op(c, W_END); }
static void e_fast_done(WJitC *c) { e_op(c, W_END); }

static void e_float_binop(WJitC *c, int op, int d);
static void e_identity_eq(WJitC *c, int op, int d);
static void e_int32_binop(WJitC *c, int op, int d);

/* binary op on two ints in slots d-2, d-1, result in slot d-2 */
static void e_int_binop(WJitC *c, int op, int pos, int d)
{
    e_fast_begin(c);
      e_load_slot_to(c, d - 2, L_A0);
      e_load_slot_to(c, d - 1, L_A1);
      if (op == OP_div) {
          e_br(c, W_BR, 0);   /* (no int path: the result is a double or an int, decided in the float path) */
          goto binop_slow;
      }
      e_both_int(c, L_A0, L_A1); e_op(c, W_I32_EQZ); e_br(c, W_BR_IF, 0);
      switch (op) {
      case OP_add: case OP_sub: case OP_mul:
          e_lget(c, L_A0); e_op(c, W_I32_WRAP_I64); e_op(c, W_I64_EXTEND_I32_S);
          e_lget(c, L_A1); e_op(c, W_I32_WRAP_I64); e_op(c, W_I64_EXTEND_I32_S);
          e_op(c, op == OP_add ? W_I64_ADD : op == OP_sub ? W_I64_SUB : W_I64_MUL);
          e_lset(c, L_A2);
          /* overflow: the result does not fit in an int32 */
          e_lget(c, L_A2); e_lget(c, L_A2); e_op(c, W_I32_WRAP_I64); e_op(c, W_I64_EXTEND_I32_S); e_op(c, W_I64_NE);
          e_br(c, W_BR_IF, 0);
          if (op == OP_mul) {
              /* 0 with a negative operand is -0: a double */
              e_lget(c, L_A2); e_op(c, W_I64_EQZ);
              e_lget(c, L_A0); e_lget(c, L_A1); e_op(c, W_I64_OR); e_op(c, W_I32_WRAP_I64); e_i32(c, 0); e_op(c, W_I32_LT_S);
              e_op(c, W_I32_AND); e_br(c, W_BR_IF, 0);
          }
          e_lget(c, L_SB); e_lget(c, L_A2); e_op(c, W_I32_WRAP_I64); e_mk_int(c); e_mem(c, W_I64_STORE, 3, SLOT(d - 2));
          break;
      case OP_and: case OP_or: case OP_xor:
          e_lget(c, L_SB); e_lget(c, L_A0); e_lget(c, L_A1);
          e_op(c, op == OP_and ? W_I64_AND : op == OP_or ? W_I64_OR : W_I64_XOR);
          e_mem(c, W_I64_STORE, 3, SLOT(d - 2));
          break;
      case OP_shl: case OP_sar:
          e_lget(c, L_SB);
          e_lget(c, L_A0); e_op(c, W_I32_WRAP_I64);
          e_lget(c, L_A1); e_op(c, W_I32_WRAP_I64);   /* Wasm masks the count with 31 */
          e_op(c, op == OP_shl ? W_I32_SHL : W_I32_SHR_S);
          e_mk_int(c); e_mem(c, W_I64_STORE, 3, SLOT(d - 2));
          break;
      case OP_shr:
          e_lget(c, L_A0); e_op(c, W_I32_WRAP_I64); e_lget(c, L_A1); e_op(c, W_I32_WRAP_I64); e_op(c, W_I32_SHR_U);
          e_ltee(c, L_I1); e_i32(c, 0); e_op(c, W_I32_LT_S); e_br(c, W_BR_IF, 0);   /* > INT32_MAX: a double */
          e_lget(c, L_SB); e_lget(c, L_I1); e_mk_int(c); e_mem(c, W_I64_STORE, 3, SLOT(d - 2));
          break;
      default: {
          uint8_t w;
          switch (op) {
          case OP_lt: w = W_I32_LT_S; break;
          case OP_lte: w = W_I32_LE_S; break;
          case OP_gt: w = W_I32_GT_S; break;
          case OP_gte: w = W_I32_GE_S; break;
          case OP_eq: case OP_strict_eq: w = W_I32_EQ; break;
          default: w = W_I32_NE; break;
          }
          e_lget(c, L_SB);
          e_lget(c, L_A0); e_op(c, W_I32_WRAP_I64); e_lget(c, L_A1); e_op(c, W_I32_WRAP_I64); e_op(c, w);
          e_mk_bool_from_i32(c); e_mem(c, W_I64_STORE, 3, SLOT(d - 2));
          break;
      }
      }
 binop_slow:
    e_fast_end_slow(c);
      switch (op) {
      case OP_add: case OP_sub: case OP_mul: case OP_div: case OP_lt: case OP_lte: case OP_gt: case OP_gte:
          e_float_binop(c, op, d);
          break;
      case OP_eq: case OP_neq: case OP_strict_eq: case OP_strict_neq:
          e_float_binop(c, op, d);
          e_identity_eq(c, op, d);
          break;
      case OP_and: case OP_or: case OP_xor: case OP_shl: case OP_sar: case OP_shr:
          e_int32_binop(c, op, d);
          break;
      default:
          break;
      }
      e_step(c, pos, d);
    e_fast_done(c);
}

/* set_value(slot at address local base + off, value in local v) */
static void e_set_value(WJitC *c, int base, uint32_t off, int v)
{
    e_ld64(c, base, off); e_lset(c, L_A7);
    e_lget(c, base); e_lget(c, v); e_mem(c, W_I64_STORE, 3, off);
    e_free(c, L_A7);
}

/* address of var_refs[idx]->pvalue into L_I1 */
static void e_var_ref_ptr(WJitC *c, int idx)
{
    e_ld32(c, L_VR, (uint32_t)idx * 4); e_mem(c, W_I32_LOAD, 2, offsetof(JSVarRef, pvalue)); e_lset(c, L_I1);
}

/* ---- numbers (NaN-boxed doubles) */

static void e_f64(WJitC *c, double v) { wb_u8(&c->code, W_F64_CONST); wb_bytes(&c->code, &v, 8); }
#define WJIT_F64_BIAS ((int64_t)((uint64_t)JS_FLOAT64_TAG_ADDEND << 32))

/* i32: the value in local l is a number (int or double) */
static void e_is_num(WJitC *c, int l)
{
    e_tag(c, l); e_ltee(c, L_I0); e_op(c, W_I32_EQZ);
    e_lget(c, L_I0); e_i32(c, -JS_TAG_FIRST); e_op(c, W_I32_ADD); e_i32(c, JS_TAG_FLOAT64 - JS_TAG_FIRST); e_op(c, W_I32_GE_U);
    e_op(c, W_I32_OR);
}

/* the number in local l as an f64 in local f */
static void e_num_f64(WJitC *c, int l, int f)
{
    e_tag(c, l); e_op(c, W_I32_EQZ);
    wb_u8(&c->code, W_IF); wb_u8(&c->code, W_TF64);
      e_lget(c, l); e_op(c, W_I32_WRAP_I64); e_op(c, W_F64_CONVERT_I32_S);
    e_op(c, W_ELSE);
      e_lget(c, l); e_i64(c, WJIT_F64_BIAS); e_op(c, W_I64_ADD); e_op(c, W_F64_REINTERPRET_I64);
    e_op(c, W_END);
    e_lset(c, f);
}

/* js_float64 of the f64 in local f, as an i64 on the stack */
static void e_box_f64(WJitC *c, int f)
{
    e_i64(c, (int64_t)JS_NAN);
    e_lget(c, f); e_op(c, W_I64_REINTERPRET_F64); e_i64(c, WJIT_F64_BIAS); e_op(c, W_I64_SUB);
    e_lget(c, f); e_lget(c, f); e_op(c, W_F64_NE);
    e_op(c, W_SELECT);
}

/* js_number of the f64 in local f stored at slot d: an int when it is one (not -0) */
static void e_store_number(WJitC *c, int f, int d)
{
    e_lget(c, f); wb_u8(&c->code, 0xfc); wb_uleb(&c->code, 2); e_lset(c, L_I1);   /* i32.trunc_sat_f64_s */
    e_lget(c, L_I1); e_op(c, W_F64_CONVERT_I32_S); e_lget(c, f); e_op(c, W_F64_EQ);
    e_lget(c, f); e_op(c, W_I64_REINTERPRET_F64); e_i64(c, 0); e_op(c, 0x53 /* i64.lt_s */);
    e_lget(c, L_I1); e_op(c, W_I32_EQZ); e_op(c, W_I32_AND); e_op(c, W_I32_EQZ); e_op(c, W_I32_AND);
    e_block(c, W_IF);
      e_lget(c, L_SB); e_lget(c, L_I1); e_mk_int(c); e_mem(c, W_I64_STORE, 3, SLOT(d));
    e_op(c, W_ELSE);
      e_lget(c, L_SB); e_box_f64(c, f); e_mem(c, W_I64_STORE, 3, SLOT(d));
    e_op(c, W_END);
}

/* in the slow part of a binary op (operands in A0, A1; result to slot d-2): both numbers -> computed as doubles, then
   leaves the enclosing fast-path frame (br 1 from inside this block) */
static void e_float_binop(WJitC *c, int op, int d)
{
    e_block(c, W_BLOCK);
      e_is_num(c, L_A0); e_is_num(c, L_A1); e_op(c, W_I32_AND); e_op(c, W_I32_EQZ); e_br(c, W_BR_IF, 0);
      e_num_f64(c, L_A0, L_F0); e_num_f64(c, L_A1, L_F1);
      switch (op) {
      case OP_add: case OP_sub: case OP_mul: case OP_div:
          e_lget(c, L_F0); e_lget(c, L_F1);
          e_op(c, op == OP_add ? W_F64_ADD : op == OP_sub ? W_F64_SUB : op == OP_mul ? W_F64_MUL : W_F64_DIV);
          e_lset(c, L_F0);
          if (op == OP_div) {
              e_store_number(c, L_F0, d - 2);
          } else {
              e_lget(c, L_SB); e_box_f64(c, L_F0); e_mem(c, W_I64_STORE, 3, SLOT(d - 2));
          }
          break;
      default: {
          uint8_t w;
          switch (op) {
          case OP_lt: w = W_F64_LT; break;
          case OP_lte: w = W_F64_LE; break;
          case OP_gt: w = W_F64_GT; break;
          case OP_gte: w = W_F64_GE; break;
          case OP_eq: case OP_strict_eq: w = W_F64_EQ; break;
          default: w = W_F64_NE; break;
          }
          e_lget(c, L_SB); e_lget(c, L_F0); e_lget(c, L_F1); e_op(c, w); e_mk_bool_from_i32(c);
          e_mem(c, W_I64_STORE, 3, SLOT(d - 2));
          break;
      }
      }
      e_br(c, W_BR, 1);
    e_op(c, W_END);
}

/* where JSObject.is_HTMLDDA (a bit field) lives */
static int wjit_htmldda_off, wjit_htmldda_mask;

static void wjit_layout_init(void)
{
    JSObject o;
    const uint8_t *q = (const uint8_t *)&o;
    size_t i;
    if (wjit_htmldda_mask)
        return;
    memset(&o, 0, sizeof(o));
    o.is_HTMLDDA = 1;
    for (i = 0; i < sizeof(o); i++) {
        if (q[i]) { wjit_htmldda_off = (int)i; wjit_htmldda_mask = q[i]; return; }
    }
}

/* in the slow part of (strict) equality: objects, booleans, null, undefined (and ints) compared by identity; loose
   equality only between equal tags or null/undefined (what needs no conversion) */
static void e_identity_eq(WJitC *c, int op, int d)
{
    int loose = op == OP_eq || op == OP_neq, negate = op == OP_neq || op == OP_strict_neq;
    e_block(c, W_BLOCK);
      e_tag(c, L_A0); e_i32(c, 1); e_op(c, W_I32_ADD); e_i32(c, 4); e_op(c, W_I32_GT_U); e_br(c, W_BR_IF, 0);
      e_tag(c, L_A1); e_i32(c, 1); e_op(c, W_I32_ADD); e_i32(c, 4); e_op(c, W_I32_GT_U); e_br(c, W_BR_IF, 0);
      if (loose) {
          /* same tag: identity; both null/undefined: equal; anything else converts */
          e_tag(c, L_A0); e_tag(c, L_A1); e_op(c, W_I32_EQ);
          e_block(c, W_IF);
            e_lget(c, L_A0); e_lget(c, L_A1); e_op(c, W_I64_EQ); e_lset(c, L_R);
          e_op(c, W_ELSE);
            /* null and undefined are equal; an object equals neither, unless it is document.all (IsHTMLDDA) */
            e_tag(c, L_A0); e_i32(c, JS_TAG_NULL); e_op(c, W_I32_GE_S);
            e_tag(c, L_A1); e_i32(c, JS_TAG_NULL); e_op(c, W_I32_GE_S); e_op(c, W_I32_AND);
            e_block(c, W_IF);
              e_i32(c, 1); e_lset(c, L_R);
            e_op(c, W_ELSE);
              e_tag(c, L_A0); e_i32(c, JS_TAG_OBJECT); e_op(c, W_I32_EQ);
              wb_u8(&c->code, W_IF); wb_u8(&c->code, W_TI32);
                e_tag(c, L_A1); e_i32(c, JS_TAG_NULL); e_op(c, W_I32_LT_S); e_br(c, W_BR_IF, 3);
                e_lget(c, L_A0); e_op(c, W_I32_WRAP_I64);
              e_op(c, W_ELSE);
                e_tag(c, L_A1); e_i32(c, JS_TAG_OBJECT); e_op(c, W_I32_NE); e_br(c, W_BR_IF, 3);
                e_tag(c, L_A0); e_i32(c, JS_TAG_NULL); e_op(c, W_I32_LT_S); e_br(c, W_BR_IF, 3);
                e_lget(c, L_A1); e_op(c, W_I32_WRAP_I64);
              e_op(c, W_END);
              /* (the object, on the stack) */
              e_mem(c, 0x2d /* i32.load8_u */, 0, (uint32_t)wjit_htmldda_off); e_i32(c, wjit_htmldda_mask); e_op(c, W_I32_AND);
              e_lset(c, L_R);
            e_op(c, W_END);
          e_op(c, W_END);
      } else {
          e_lget(c, L_A0); e_lget(c, L_A1); e_op(c, W_I64_EQ); e_lset(c, L_R);
      }
      e_lget(c, L_SB); e_lget(c, L_R); if (negate) e_op(c, W_I32_EQZ); e_mk_bool_from_i32(c);
      e_mem(c, W_I64_STORE, 3, SLOT(d - 2));
      e_free(c, L_A0); e_free(c, L_A1);
      e_br(c, W_BR, 1);
    e_op(c, W_END);
}

/* ToInt32 of the number in local l (i32 on the stack); a double outside the int32 range leaves the block `depth`
   levels out (the caller's slow path) */
static void e_num_to_i32(WJitC *c, int l, int depth)
{
    e_tag(c, l); e_op(c, W_I32_EQZ);
    wb_u8(&c->code, W_IF); wb_u8(&c->code, W_TI32);
      e_lget(c, l); e_op(c, W_I32_WRAP_I64);
    e_op(c, W_ELSE);
      e_lget(c, l); e_i64(c, WJIT_F64_BIAS); e_op(c, W_I64_ADD); e_op(c, W_F64_REINTERPRET_I64);
      e_op(c, 0x9d /* f64.trunc */); e_ltee(c, L_F0);
      wb_u8(&c->code, 0xfc); wb_uleb(&c->code, 2); e_ltee(c, L_I1);   /* i32.trunc_sat_f64_s */
      e_op(c, W_F64_CONVERT_I32_S); e_lget(c, L_F0); e_op(c, W_F64_NE); e_br(c, W_BR_IF, depth + 1);
      e_lget(c, L_I1);
    e_op(c, W_END);
}

/* in the slow part of a bitwise op: numbers converted by ToInt32 (doubles within the int32 range) */
static void e_int32_binop(WJitC *c, int op, int d)
{
    e_block(c, W_BLOCK);
      e_is_num(c, L_A0); e_is_num(c, L_A1); e_op(c, W_I32_AND); e_op(c, W_I32_EQZ); e_br(c, W_BR_IF, 0);
      e_num_to_i32(c, L_A0, 0); e_lset(c, L_R);
      e_num_to_i32(c, L_A1, 0); e_lset(c, L_I1);
      e_lget(c, L_R); e_lget(c, L_I1);
      switch (op) {
      case OP_and: e_op(c, W_I32_AND); break;
      case OP_or: e_op(c, W_I32_OR); break;
      case OP_xor: e_op(c, W_I32_XOR); break;
      case OP_shl: e_op(c, W_I32_SHL); break;
      case OP_sar: e_op(c, W_I32_SHR_S); break;
      default: e_op(c, W_I32_SHR_U); break;
      }
      e_lset(c, L_R);
      if (op == OP_shr) {
          /* an unsigned result: a double past INT32_MAX */
          e_lget(c, L_R); e_i32(c, 0); e_op(c, W_I32_LT_S);
          e_block(c, W_IF);
            e_lget(c, L_R); e_op(c, 0xb8 /* f64.convert_i32_u */); e_lset(c, L_F0);
            e_lget(c, L_SB); e_box_f64(c, L_F0); e_mem(c, W_I64_STORE, 3, SLOT(d - 2));
            e_br(c, W_BR, 2);
          e_op(c, W_END);
      }
      e_lget(c, L_SB); e_lget(c, L_R); e_mk_int(c); e_mem(c, W_I64_STORE, 3, SLOT(d - 2));
      e_br(c, W_BR, 1);
    e_op(c, W_END);
}

static WJitIC *wjit_next_ic(WJitC *c)
{
    if (!c->data || c->nic_used >= c->data->nic)
        return NULL;
    return &c->data->ic[c->nic_used++];
}

/* a call to a helper (jf, slot(d), pc, [extra]) returning a status; leaves the function unless it is WJIT_OK */
static void e_helper(WJitC *c, int f, int pos, int d, uint32_t extra, int has_extra)
{
    e_lget(c, LP_JF);
    e_lget(c, L_SB); e_i32(c, (int32_t)SLOT(d)); e_op(c, W_I32_ADD);
    e_i32(c, (int32_t)pc_abs(c, pos));
    if (has_extra) e_i32(c, (int32_t)extra);
    e_call(c, f); e_ltee(c, L_R);
    e_block(c, W_IF); e_lget(c, L_R); e_op(c, W_RETURN); e_op(c, W_END);
}

/* p (i32 in L_I0) = the object in local l, or br_if 0 when it is not one */
static void e_obj_or_br(WJitC *c, int l)
{
    e_tag(c, l); e_i32(c, JS_TAG_OBJECT); e_op(c, W_I32_NE); e_br(c, W_BR_IF, 0);
    e_lget(c, l); e_op(c, W_I32_WRAP_I64); e_lset(c, L_I0);
}

/* one instruction; returns -1 when the function cannot be compiled */
static int wjit_emit_op(WJitC *c, int blk, int pos)
{
    const uint8_t *bc = c->bc;
    int op = bc[pos], d = c->depth[pos], idx = -1, kind = 0;   /* kind: 1 loc, 2 arg, 3 var_ref */
    const JSOpCode *oi = &short_opcode_info(op);
    int next = pos + oi->size;

    if (wjit_is_exit(op)) {
        e_exit(c, WJIT_DEOPT, pos, d);
        return 0;
    }
    if (!wjit_config.inline_ops && !wjit_is_branch(op) && op != OP_return && op != OP_return_undef)
        goto step;
    if (wjit_config.off) {
        uint32_t o = wjit_config.off;
        switch (op) {
        case OP_get_field: case OP_get_field2: case OP_get_length:
            if (o & WJIT_OFF_FIELD) goto step;
            if ((o & 64) && op == OP_get_length) goto step;
            if ((o & 128) && op == OP_get_field2) goto step;
            if ((o & 2) && op == OP_get_field) goto step;
            break;
        case OP_put_field:
            if (o & WJIT_OFF_PUT_FIELD) goto step;
            break;
        case OP_call: case OP_call0: case OP_call1: case OP_call2: case OP_call3: case OP_call_method:
        case OP_call_constructor: case OP_tail_call: case OP_tail_call_method:
            if (o & WJIT_OFF_CALL) goto step;
            break;
        case OP_get_var: case OP_get_var_undef:
            if (o & WJIT_OFF_GLOBAL) goto step;
            break;
        case OP_div: case OP_eq: case OP_neq: case OP_strict_eq: case OP_strict_neq:
            if (o & WJIT_OFF_NUMBERS) goto step;
            break;
        default:
            break;
        }
    }

    switch (op) {
    case OP_push_i32: e_store_const_slot(c, d, JS_MKVAL(JS_TAG_INT, (int32_t)get_u32(bc + pos + 1))); return 0;
    case OP_push_minus1: case OP_push_0: case OP_push_1: case OP_push_2: case OP_push_3: case OP_push_4:
    case OP_push_5: case OP_push_6: case OP_push_7:
        e_store_const_slot(c, d, JS_MKVAL(JS_TAG_INT, op - OP_push_0)); return 0;
    case OP_push_i8: e_store_const_slot(c, d, JS_MKVAL(JS_TAG_INT, (int8_t)bc[pos + 1])); return 0;
    case OP_push_i16: e_store_const_slot(c, d, JS_MKVAL(JS_TAG_INT, (int16_t)get_u16(bc + pos + 1))); return 0;
    case OP_undefined: e_store_const_slot(c, d, JS_UNDEFINED); return 0;
    case OP_null: e_store_const_slot(c, d, JS_NULL); return 0;
    case OP_push_false: e_store_const_slot(c, d, JS_FALSE); return 0;
    case OP_push_true: e_store_const_slot(c, d, JS_TRUE); return 0;
    case OP_push_const: e_push_const(c, d, c->b->cpool[get_u32(bc + pos + 1)]); return 0;
    case OP_push_const8: e_push_const(c, d, c->b->cpool[bc[pos + 1]]); return 0;

    case OP_get_loc: case OP_put_loc: case OP_set_loc: idx = get_u16(bc + pos + 1); kind = 1; break;
    case OP_get_loc8: case OP_put_loc8: case OP_set_loc8: idx = bc[pos + 1]; kind = 1; break;
    case OP_get_loc0: case OP_get_loc1: case OP_get_loc2: case OP_get_loc3: idx = op - OP_get_loc0; kind = 1; break;
    case OP_put_loc0: case OP_put_loc1: case OP_put_loc2: case OP_put_loc3: idx = op - OP_put_loc0; kind = 1; break;
    case OP_set_loc0: case OP_set_loc1: case OP_set_loc2: case OP_set_loc3: idx = op - OP_set_loc0; kind = 1; break;
    case OP_get_arg: case OP_put_arg: case OP_set_arg: idx = get_u16(bc + pos + 1); kind = 2; break;
    case OP_get_arg0: case OP_get_arg1: case OP_get_arg2: case OP_get_arg3: idx = op - OP_get_arg0; kind = 2; break;
    case OP_put_arg0: case OP_put_arg1: case OP_put_arg2: case OP_put_arg3: idx = op - OP_put_arg0; kind = 2; break;
    case OP_set_arg0: case OP_set_arg1: case OP_set_arg2: case OP_set_arg3: idx = op - OP_set_arg0; kind = 2; break;
    case OP_get_var_ref: case OP_put_var_ref: case OP_set_var_ref: idx = get_u16(bc + pos + 1); kind = 3; break;
    case OP_get_var_ref0: case OP_get_var_ref1: case OP_get_var_ref2: case OP_get_var_ref3: idx = op - OP_get_var_ref0; kind = 3; break;
    case OP_put_var_ref0: case OP_put_var_ref1: case OP_put_var_ref2: case OP_put_var_ref3: idx = op - OP_put_var_ref0; kind = 3; break;
    case OP_set_var_ref0: case OP_set_var_ref1: case OP_set_var_ref2: case OP_set_var_ref3: idx = op - OP_set_var_ref0; kind = 3; break;

    case OP_get_loc0_loc1:
        e_ld64(c, L_VB, 0); e_lset(c, L_A0); e_dup(c, L_A0); e_store_slot_from(c, d, L_A0);
        e_ld64(c, L_VB, 8); e_lset(c, L_A0); e_dup(c, L_A0); e_store_slot_from(c, d + 1, L_A0);
        return 0;
    case OP_get_loc_check:
        idx = get_u16(bc + pos + 1);
        e_fast_begin(c);
          e_ld64(c, L_VB, SLOT(idx)); e_lset(c, L_A0);
          e_tag(c, L_A0); e_i32(c, JS_TAG_UNINITIALIZED); e_op(c, W_I32_EQ); e_br(c, W_BR_IF, 0);
          e_dup(c, L_A0); e_store_slot_from(c, d, L_A0);
        e_fast_end_slow(c);
          e_step(c, pos, d);
        e_fast_done(c);
        return 0;

    case OP_drop:
        e_load_slot_to(c, d - 1, L_A0); e_free(c, L_A0); return 0;
    case OP_nip:
        e_load_slot_to(c, d - 2, L_A0); e_free(c, L_A0);
        e_load_slot_to(c, d - 1, L_A0); e_store_slot_from(c, d - 2, L_A0); return 0;
    case OP_nip1:
        e_load_slot_to(c, d - 3, L_A0); e_free(c, L_A0);
        e_load_slot_to(c, d - 2, L_A0); e_store_slot_from(c, d - 3, L_A0);
        e_load_slot_to(c, d - 1, L_A0); e_store_slot_from(c, d - 2, L_A0); return 0;
    case OP_dup:
        e_load_slot_to(c, d - 1, L_A0); e_dup(c, L_A0); e_store_slot_from(c, d, L_A0); return 0;
    case OP_dup1:   /* a b -> a a b */
        e_load_slot_to(c, d - 2, L_A0); e_load_slot_to(c, d - 1, L_A1);
        e_store_slot_from(c, d, L_A1); e_dup(c, L_A0); e_store_slot_from(c, d - 1, L_A0); return 0;
    case OP_dup2:
        e_load_slot_to(c, d - 2, L_A0); e_load_slot_to(c, d - 1, L_A1);
        e_dup(c, L_A0); e_dup(c, L_A1); e_store_slot_from(c, d, L_A0); e_store_slot_from(c, d + 1, L_A1); return 0;
    case OP_dup3:
        e_load_slot_to(c, d - 3, L_A0); e_load_slot_to(c, d - 2, L_A1); e_load_slot_to(c, d - 1, L_A2);
        e_dup(c, L_A0); e_dup(c, L_A1); e_dup(c, L_A2);
        e_store_slot_from(c, d, L_A0); e_store_slot_from(c, d + 1, L_A1); e_store_slot_from(c, d + 2, L_A2); return 0;
    case OP_insert2: case OP_insert3: case OP_insert4: {
        int n = op - OP_insert2 + 2, k;   /* x1..xn a -> a x1..xn a */
        e_load_slot_to(c, d - 1, L_A0);
        for (k = 1; k < n; k++) { e_load_slot_to(c, d - 1 - k, L_A1); e_store_slot_from(c, d - k, L_A1); }
        e_store_slot_from(c, d, L_A0);
        e_dup(c, L_A0); e_store_slot_from(c, d - n, L_A0);
        return 0;
    }
    case OP_swap:
        e_load_slot_to(c, d - 2, L_A0); e_load_slot_to(c, d - 1, L_A1);
        e_store_slot_from(c, d - 2, L_A1); e_store_slot_from(c, d - 1, L_A0); return 0;
    case OP_perm3:   /* obj a b -> a obj b */
        e_load_slot_to(c, d - 3, L_A0); e_load_slot_to(c, d - 2, L_A1);
        e_store_slot_from(c, d - 3, L_A1); e_store_slot_from(c, d - 2, L_A0); return 0;
    case OP_rot3l:   /* x a b -> a b x */
        e_load_slot_to(c, d - 3, L_A0); e_load_slot_to(c, d - 2, L_A1); e_load_slot_to(c, d - 1, L_A2);
        e_store_slot_from(c, d - 3, L_A1); e_store_slot_from(c, d - 2, L_A2); e_store_slot_from(c, d - 1, L_A0); return 0;
    case OP_rot3r:   /* a b x -> x a b */
        e_load_slot_to(c, d - 3, L_A0); e_load_slot_to(c, d - 2, L_A1); e_load_slot_to(c, d - 1, L_A2);
        e_store_slot_from(c, d - 3, L_A2); e_store_slot_from(c, d - 2, L_A0); e_store_slot_from(c, d - 1, L_A1); return 0;
    case OP_perm4:   /* obj prop a b -> a obj prop b */
        e_load_slot_to(c, d - 4, L_A0); e_load_slot_to(c, d - 3, L_A1); e_load_slot_to(c, d - 2, L_A2);
        e_store_slot_from(c, d - 4, L_A2); e_store_slot_from(c, d - 3, L_A0); e_store_slot_from(c, d - 2, L_A1); return 0;

    case OP_add: case OP_sub: case OP_mul: case OP_div: case OP_and: case OP_or: case OP_xor: case OP_shl: case OP_sar:
    case OP_shr: case OP_lt: case OP_lte: case OP_gt: case OP_gte: case OP_eq: case OP_neq: case OP_strict_eq:
    case OP_strict_neq:
        e_int_binop(c, op, pos, d);
        return 0;

    case OP_inc: case OP_dec: case OP_post_inc: case OP_post_dec: {
        int up = op == OP_inc || op == OP_post_inc;
        e_fast_begin(c);
          e_load_slot_to(c, d - 1, L_A0);
          e_tag(c, L_A0); e_br(c, W_BR_IF, 0);
          e_lget(c, L_A0); e_op(c, W_I32_WRAP_I64); e_ltee(c, L_I1);
          e_i32(c, up ? INT32_MAX : INT32_MIN); e_op(c, W_I32_EQ); e_br(c, W_BR_IF, 0);
          e_lget(c, L_SB); e_lget(c, L_I1); e_i32(c, 1); e_op(c, up ? W_I32_ADD : W_I32_SUB); e_mk_int(c);
          e_mem(c, W_I64_STORE, 3, SLOT(op == OP_inc || op == OP_dec ? d - 1 : d));
        e_fast_end_slow(c);
          e_step(c, pos, d);
        e_fast_done(c);
        return 0;
    }
    case OP_inc_loc: case OP_dec_loc: {
        int up = op == OP_inc_loc;
        idx = bc[pos + 1];
        e_fast_begin(c);
          e_ld64(c, L_VB, SLOT(idx)); e_lset(c, L_A0);
          e_tag(c, L_A0); e_br(c, W_BR_IF, 0);
          e_lget(c, L_A0); e_op(c, W_I32_WRAP_I64); e_ltee(c, L_I1);
          e_i32(c, up ? INT32_MAX : INT32_MIN); e_op(c, W_I32_EQ); e_br(c, W_BR_IF, 0);
          e_lget(c, L_VB); e_lget(c, L_I1); e_i32(c, 1); e_op(c, up ? W_I32_ADD : W_I32_SUB); e_mk_int(c);
          e_mem(c, W_I64_STORE, 3, SLOT(idx));
        e_fast_end_slow(c);
          e_step(c, pos, d);
        e_fast_done(c);
        return 0;
    }
    case OP_add_loc:
        idx = bc[pos + 1];
        e_fast_begin(c);
          e_ld64(c, L_VB, SLOT(idx)); e_lset(c, L_A0);
          e_load_slot_to(c, d - 1, L_A1);
          e_both_int(c, L_A0, L_A1); e_op(c, W_I32_EQZ); e_br(c, W_BR_IF, 0);
          e_lget(c, L_A0); e_op(c, W_I32_WRAP_I64); e_op(c, W_I64_EXTEND_I32_S);
          e_lget(c, L_A1); e_op(c, W_I32_WRAP_I64); e_op(c, W_I64_EXTEND_I32_S); e_op(c, W_I64_ADD); e_lset(c, L_A2);
          e_lget(c, L_A2); e_lget(c, L_A2); e_op(c, W_I32_WRAP_I64); e_op(c, W_I64_EXTEND_I32_S); e_op(c, W_I64_NE);
          e_br(c, W_BR_IF, 0);
          e_lget(c, L_VB); e_lget(c, L_A2); e_op(c, W_I32_WRAP_I64); e_mk_int(c); e_mem(c, W_I64_STORE, 3, SLOT(idx));
        e_fast_end_slow(c);
          /* two numbers: a double (no reference counts involved) */
          e_block(c, W_BLOCK);
            e_is_num(c, L_A0); e_is_num(c, L_A1); e_op(c, W_I32_AND); e_op(c, W_I32_EQZ); e_br(c, W_BR_IF, 0);
            e_num_f64(c, L_A0, L_F0); e_num_f64(c, L_A1, L_F1);
            e_lget(c, L_F0); e_lget(c, L_F1); e_op(c, W_F64_ADD); e_lset(c, L_F0);
            e_lget(c, L_VB); e_box_f64(c, L_F0); e_mem(c, W_I64_STORE, 3, SLOT(idx));
            e_br(c, W_BR, 1);
          e_op(c, W_END);
          e_step(c, pos, d);
        e_fast_done(c);
        return 0;

    case OP_is_undefined: case OP_is_null: {
        /* value -> bool; the value is freed */
        e_load_slot_to(c, d - 1, L_A0);
        e_lget(c, L_SB);
        e_tag(c, L_A0); e_i32(c, op == OP_is_undefined ? JS_TAG_UNDEFINED : JS_TAG_NULL); e_op(c, W_I32_EQ);
        e_mk_bool_from_i32(c); e_mem(c, W_I64_STORE, 3, SLOT(d - 1));
        e_free(c, L_A0);
        return 0;
    }

    case OP_if_true: case OP_if_false: case OP_if_true8: case OP_if_false8: {
        int t = c->blk_of[wjit_label_target(bc, pos, op)];
        int jump_if_true = op == OP_if_true || op == OP_if_true8;
        /* truthiness: ints, booleans, null, undefined inline */
        e_load_slot_to(c, d - 1, L_A0);
        e_tag(c, L_A0); e_i32(c, JS_TAG_UNDEFINED); e_op(c, W_I32_LE_U);
        wb_u8(&c->code, W_IF); wb_u8(&c->code, W_TI32);
          e_lget(c, L_A0); e_op(c, W_I32_WRAP_I64);
        e_op(c, W_ELSE);
          e_lget(c, L_CTX); e_lget(c, L_A0); e_call(c, WF_TO_BOOL);
        e_op(c, W_END);
        e_lset(c, L_R);
        e_poll(c, next, d - 1);
        if (t == blk + 1) {
            return 0;   /* both ways lead to the next block */
        }
        e_lget(c, L_R);
        if (!jump_if_true)
            e_op(c, W_I32_EQZ);
        return e_branch(c, W_BR_IF, blk, t);
    }
    case OP_goto: case OP_goto8: case OP_goto16: {
        int t = c->blk_of[wjit_label_target(bc, pos, op)];
        e_poll(c, next, d);
        if (t == blk + 1)
            return 0;
        return e_branch(c, W_BR, blk, t);
    }
    case OP_return:
        e_lget(c, LP_JF); e_ld64(c, L_SB, SLOT(d - 1)); e_mem(c, W_I64_STORE, 3, offsetof(WJitFrame, ret));
        e_lget(c, LP_JF); e_lget(c, L_SB); e_i32(c, (int32_t)SLOT(d - 1)); e_op(c, W_I32_ADD); e_mem(c, W_I32_STORE, 2, offsetof(WJitFrame, sp));
        e_i32(c, WJIT_RET); e_op(c, W_RETURN);
        return 0;
    case OP_return_undef:
        e_lget(c, LP_JF); e_i64(c, (int64_t)JS_UNDEFINED); e_mem(c, W_I64_STORE, 3, offsetof(WJitFrame, ret));
        e_lget(c, LP_JF); e_lget(c, L_SB); e_i32(c, (int32_t)SLOT(d)); e_op(c, W_I32_ADD); e_mem(c, W_I32_STORE, 2, offsetof(WJitFrame, sp));
        e_i32(c, WJIT_RET); e_op(c, W_RETURN);
        return 0;
    case OP_push_this:
        e_lget(c, LP_JF); e_mem(c, W_I64_LOAD, 3, offsetof(WJitFrame, this_obj)); e_lset(c, L_A0);
        if (c->b->is_strict_mode) {
            e_dup(c, L_A0); e_store_slot_from(c, d, L_A0);
            return 0;
        }
        e_fast_begin(c);
          e_tag(c, L_A0); e_i32(c, JS_TAG_OBJECT); e_op(c, W_I32_NE); e_br(c, W_BR_IF, 0);
          e_dup(c, L_A0); e_store_slot_from(c, d, L_A0);
        e_fast_end_slow(c);
          e_step(c, pos, d);
        e_fast_done(c);
        return 0;

    case OP_to_propkey: case OP_to_propkey2:
        e_fast_begin(c);
          if (op == OP_to_propkey2) {
              e_load_slot_to(c, d - 2, L_A1);
              e_tag(c, L_A1); e_i32(c, JS_TAG_NULL); e_op(c, W_I32_EQ);
              e_tag(c, L_A1); e_i32(c, JS_TAG_UNDEFINED); e_op(c, W_I32_EQ); e_op(c, W_I32_OR);
              e_br(c, W_BR_IF, 0);
          }
          e_load_slot_to(c, d - 1, L_A0);
          e_tag(c, L_A0); e_ltee(c, L_I0); e_op(c, W_I32_EQZ);
          e_lget(c, L_I0); e_i32(c, JS_TAG_STRING); e_op(c, W_I32_EQ); e_op(c, W_I32_OR);
          e_lget(c, L_I0); e_i32(c, JS_TAG_SYMBOL); e_op(c, W_I32_EQ); e_op(c, W_I32_OR);
          e_op(c, W_I32_EQZ); e_br(c, W_BR_IF, 0);
        e_fast_end_slow(c);
          e_step(c, pos, d);
        e_fast_done(c);
        return 0;

    case OP_is_undefined_or_null:
        e_load_slot_to(c, d - 1, L_A0);
        e_lget(c, L_SB);
        e_tag(c, L_A0); e_i32(c, JS_TAG_NULL); e_op(c, W_I32_EQ);
        e_tag(c, L_A0); e_i32(c, JS_TAG_UNDEFINED); e_op(c, W_I32_EQ); e_op(c, W_I32_OR);
        e_mk_bool_from_i32(c); e_mem(c, W_I64_STORE, 3, SLOT(d - 1));
        e_free(c, L_A0);
        return 0;

    case OP_lnot:
        e_fast_begin(c);
          e_load_slot_to(c, d - 1, L_A0);
          e_tag(c, L_A0); e_i32(c, JS_TAG_UNDEFINED); e_op(c, W_I32_GT_U); e_br(c, W_BR_IF, 0);
          e_lget(c, L_SB); e_lget(c, L_A0); e_op(c, W_I32_WRAP_I64); e_op(c, W_I32_EQZ); e_mk_bool_from_i32(c);
          e_mem(c, W_I64_STORE, 3, SLOT(d - 1));
        e_fast_end_slow(c);
          e_step(c, pos, d);
        e_fast_done(c);
        return 0;

    case OP_get_field: case OP_get_field2: case OP_get_length: {
        WJitIC *ic = wjit_next_ic(c);
        if (!ic)
            goto step;
        e_fast_begin(c);
          e_load_slot_to(c, d - 1, L_A0);
          e_obj_or_br(c, L_A0);
          e_lget(c, L_I0); e_mem(c, W_I32_LOAD, 2, offsetof(JSObject, shape));
          e_i32(c, (int32_t)(uintptr_t)ic); e_mem(c, W_I32_LOAD, 2, offsetof(WJitIC, own));
          e_op(c, W_I32_NE); e_br(c, W_BR_IF, 0);
          e_lget(c, L_I0); e_mem(c, W_I32_LOAD, 2, offsetof(JSObject, prop));
          e_i32(c, (int32_t)(uintptr_t)ic); e_mem(c, W_I32_LOAD, 2, offsetof(WJitIC, index)); e_i32(c, 3); e_op(c, W_I32_SHL);
          e_op(c, W_I32_ADD); e_mem(c, W_I64_LOAD, 3, 0); e_lset(c, L_A1);
          e_dup(c, L_A1);
          if (op == OP_get_field2) {
              e_store_slot_from(c, d, L_A1);
          } else {
              e_store_slot_from(c, d - 1, L_A1);
              e_free(c, L_A0);
          }
        e_fast_end_slow(c);
          e_helper(c, WF_GET_FIELD, pos, d, (uint32_t)(uintptr_t)ic, 1);
        e_fast_done(c);
        return 0;
    }
    case OP_put_field: {
        WJitIC *ic = wjit_next_ic(c);
        if (!ic)
            goto step;
        e_fast_begin(c);
          e_load_slot_to(c, d - 2, L_A0);
          e_obj_or_br(c, L_A0);
          e_lget(c, L_I0); e_mem(c, W_I32_LOAD, 2, offsetof(JSObject, shape));
          e_i32(c, (int32_t)(uintptr_t)ic); e_mem(c, W_I32_LOAD, 2, offsetof(WJitIC, own));
          e_op(c, W_I32_NE); e_br(c, W_BR_IF, 0);
          e_lget(c, L_I0); e_mem(c, W_I32_LOAD, 2, offsetof(JSObject, prop));
          e_i32(c, (int32_t)(uintptr_t)ic); e_mem(c, W_I32_LOAD, 2, offsetof(WJitIC, index)); e_i32(c, 3); e_op(c, W_I32_SHL);
          e_op(c, W_I32_ADD); e_lset(c, L_I1);
          e_lget(c, L_I1); e_mem(c, W_I64_LOAD, 3, 0); e_lset(c, L_A2);
          e_lget(c, L_I1); e_ld64(c, L_SB, SLOT(d - 1)); e_mem(c, W_I64_STORE, 3, 0);
          e_free(c, L_A2);
          e_free(c, L_A0);
        e_fast_end_slow(c);
          e_helper(c, WF_PUT_FIELD, pos, d, (uint32_t)(uintptr_t)ic, 1);
        e_fast_done(c);
        return 0;
    }

    case OP_get_array_el: case OP_get_array_el2: case OP_put_array_el: {
        int put = op == OP_put_array_el, o = put ? d - 3 : d - 2;
        e_fast_begin(c);
          e_load_slot_to(c, o, L_A0);
          e_load_slot_to(c, o + 1, L_A1);
          e_tag(c, L_A1); e_br(c, W_BR_IF, 0);   /* the index is an int */
          e_obj_or_br(c, L_A0);
          e_lget(c, L_I0); e_mem(c, W_I32_LOAD16_U, 1, offsetof(JSObject, class_id));
          e_i32(c, JS_CLASS_ARRAY); e_op(c, W_I32_NE); e_br(c, W_BR_IF, 0);
          e_lget(c, L_A1); e_op(c, W_I32_WRAP_I64);
          e_lget(c, L_I0); e_mem(c, W_I32_LOAD, 2, offsetof(JSObject, u.array.count));
          e_op(c, W_I32_GE_U); e_br(c, W_BR_IF, 0);
          e_lget(c, L_I0); e_mem(c, W_I32_LOAD, 2, offsetof(JSObject, u.array.u.values));
          e_lget(c, L_A1); e_op(c, W_I32_WRAP_I64); e_i32(c, 3); e_op(c, W_I32_SHL); e_op(c, W_I32_ADD); e_lset(c, L_I1);
          if (put) {
              e_lget(c, L_I1); e_mem(c, W_I64_LOAD, 3, 0); e_lset(c, L_A2);
              e_lget(c, L_I1); e_ld64(c, L_SB, SLOT(d - 1)); e_mem(c, W_I64_STORE, 3, 0);
              e_free(c, L_A2);
              e_free(c, L_A0);
          } else {
              e_lget(c, L_I1); e_mem(c, W_I64_LOAD, 3, 0); e_lset(c, L_A2);
              e_dup(c, L_A2);
              if (op == OP_get_array_el2) {
                  e_store_slot_from(c, d - 1, L_A2);
              } else {
                  e_store_slot_from(c, d - 2, L_A2);
                  e_free(c, L_A0);
              }
          }
        e_fast_end_slow(c);
          e_step(c, pos, d);
        e_fast_done(c);
        return 0;
    }

    case OP_call: case OP_call0: case OP_call1: case OP_call2: case OP_call3: case OP_call_method:
    case OP_call_constructor:
        e_helper(c, WF_CALL, pos, d, 0, 0);
        return 0;
    case OP_tail_call: case OP_tail_call_method:
        e_helper(c, WF_CALL, pos, d, 0, 0);
        e_op(c, W_UNREACHABLE);   /* (wjit_call returned WJIT_RET or WJIT_EXC: e_helper left) */
        return 0;

    case OP_get_var: case OP_get_var_undef: {
        WJitIC *ic = wjit_next_ic(c);
        if (!ic)
            goto step;
        e_helper(c, WF_GET_VAR, pos, d, (uint32_t)(uintptr_t)ic, 1);
        return 0;
    }

    default:
        goto step;
    }

    /* locals, arguments, closure variables */
    {
        int base = kind == 1 ? L_VB : kind == 2 ? L_AB : L_I1;
        uint32_t off = kind == 3 ? 0 : SLOT(idx);
        int is_get = 0, is_put = 0;
        switch (op) {
        case OP_get_loc: case OP_get_loc8: case OP_get_loc0: case OP_get_loc1: case OP_get_loc2: case OP_get_loc3:
        case OP_get_arg: case OP_get_arg0: case OP_get_arg1: case OP_get_arg2: case OP_get_arg3:
        case OP_get_var_ref: case OP_get_var_ref0: case OP_get_var_ref1: case OP_get_var_ref2: case OP_get_var_ref3:
            is_get = 1; break;
        case OP_put_loc: case OP_put_loc8: case OP_put_loc0: case OP_put_loc1: case OP_put_loc2: case OP_put_loc3:
        case OP_put_arg: case OP_put_arg0: case OP_put_arg1: case OP_put_arg2: case OP_put_arg3:
        case OP_put_var_ref: case OP_put_var_ref0: case OP_put_var_ref1: case OP_put_var_ref2: case OP_put_var_ref3:
            is_put = 1; break;
        default:
            break;
        }
        if (kind == 3)
            e_var_ref_ptr(c, idx);
        if (is_get) {
            e_ld64(c, base, off); e_lset(c, L_A0); e_dup(c, L_A0); e_store_slot_from(c, d, L_A0);
        } else if (is_put) {
            e_load_slot_to(c, d - 1, L_A0); e_set_value(c, base, off, L_A0);
        } else {   /* set: the value stays on the stack */
            e_load_slot_to(c, d - 1, L_A0); e_dup(c, L_A0); e_set_value(c, base, off, L_A0);
        }
        return 0;
    }

 step:
    if (wjit_is_branch(op)) { c->why = "branch through step"; return -1; }
    e_step(c, pos, d);
    if (wjit_is_terminator(op))
        e_op(c, W_UNREACHABLE);   /* throw, tail calls: wjit_step returned already */
    return 0;
}

static int wjit_emit_body(WJitC *c)
{
    const uint8_t *bc = c->bc;
    int i, k, pos;
    /* prologue */
    e_lget(c, LP_JF); e_mem(c, W_I32_LOAD, 2, offsetof(WJitFrame, ctx)); e_lset(c, L_CTX);
    e_lget(c, LP_JF); e_mem(c, W_I32_LOAD, 2, offsetof(WJitFrame, stack_buf)); e_lset(c, L_SB);
    e_lget(c, LP_JF); e_mem(c, W_I32_LOAD, 2, offsetof(WJitFrame, var_buf)); e_lset(c, L_VB);
    e_lget(c, LP_JF); e_mem(c, W_I32_LOAD, 2, offsetof(WJitFrame, arg_buf)); e_lset(c, L_AB);
    e_lget(c, LP_JF); e_mem(c, W_I32_LOAD, 2, offsetof(WJitFrame, var_refs)); e_lset(c, L_VR);
    c->nstack = 0;
    /* entries at loop headers (entry = the header's pc offset; 0 = the function's start): one block per entry,
       from here to the header, the latest outermost; everything before the header is inside them */
    for (k = c->nosr - 1; k >= 0; k--) {
        c->cons[c->ncons].kind = 2;
        c->cons[c->ncons].start = 0;
        c->cons[c->ncons].end = c->osr_blk[k];
        e_block(c, W_BLOCK);
        c->stack[c->nstack++] = c->ncons++;
    }
    /* (an entry the code does not have, whatever it has: nothing is done) */
    for (k = 0; k < c->nosr; k++) {
        e_lget(c, LP_ENTRY); e_i32(c, c->blk_start[c->osr_blk[k]]); e_op(c, W_I32_EQ);
        e_br(c, W_BR_IF, k);
    }
    e_lget(c, LP_ENTRY);
    e_block(c, W_IF); e_i32(c, WJIT_NOENTRY); e_op(c, W_RETURN); e_op(c, W_END);
    for (i = 0; i <= c->nblk; i++) {
        int end, last = -1;
        /* close what ends here (innermost first: they must be on top) */
        for (;;) {
            int top;
            if (c->nstack == 0) break;
            top = c->stack[c->nstack - 1];
            if (c->cons[top].end != i) break;
            e_op(c, W_END);
            c->nstack--;
        }
        for (k = 0; k < c->nstack; k++) {
            if (c->cons[c->stack[k]].end == i) { c->why = "constructs do not nest"; return -1; }
        }
        if (i == c->nblk)
            break;
        /* open what starts here: outermost (latest end) first; a block encloses a loop ending with it */
        for (;;) {
            int best = -1;
            for (k = 0; k < c->ncons; k++) {
                struct WJitCons *q = &c->cons[k];
                int open = 0, s;
                if (q->start != i) continue;
                for (s = 0; s < c->nstack; s++) if (c->stack[s] == k) open = 1;
                if (open) continue;
                if (best < 0 || q->end > c->cons[best].end ||
                    (q->end == c->cons[best].end && q->kind == 0 && c->cons[best].kind == 1))
                    best = k;
            }
            if (best < 0) break;
            if (c->nstack > 0 && c->cons[best].end > c->cons[c->stack[c->nstack - 1]].end) {
                c->why = "constructs do not nest";
                return -1;
            }
            e_block(c, c->cons[best].kind ? W_LOOP : W_BLOCK);
            c->stack[c->nstack++] = best;
        }
        end = i + 1 < c->nblk ? c->blk_start[i + 1] : c->len;
        for (pos = c->blk_start[i]; pos < end && c->depth[pos] >= 0; pos += short_opcode_info(bc[pos]).size) {
            last = pos;
            if (wjit_emit_op(c, i, pos) < 0)
                return -1;
            if (c->code.oom) { c->why = "out of memory"; return -1; }
            if (wjit_is_exit(bc[pos]))
                break;
        }
        (void)last;
    }
    if (c->nstack != 0) { c->why = "unclosed construct"; return -1; }
    e_op(c, W_UNREACHABLE);
    e_op(c, W_END);
    return 0;
}

/* the module around the function */
static int wjit_module(WJitC *c, WBuf *m)
{
    static const uint8_t header[8] = { 0, 'a', 's', 'm', 1, 0, 0, 0 };
    WBuf s = { 0 }, body = { 0 };
    int ok;
    wb_bytes(m, header, 8);
    /* types: 0 the function (jf, entry) -> status; 1 step, call; 2 free; 3 poll; 4 to_bool; 5 get_field, put_field */
    wb_uleb(&s, 6);
    wb_u8(&s, 0x60); wb_uleb(&s, 2); wb_u8(&s, W_TI32); wb_u8(&s, W_TI32); wb_uleb(&s, 1); wb_u8(&s, W_TI32);
    wb_u8(&s, 0x60); wb_uleb(&s, 3); wb_u8(&s, W_TI32); wb_u8(&s, W_TI32); wb_u8(&s, W_TI32); wb_uleb(&s, 1); wb_u8(&s, W_TI32);
    wb_u8(&s, 0x60); wb_uleb(&s, 2); wb_u8(&s, W_TI32); wb_u8(&s, W_TI64); wb_uleb(&s, 0);
    wb_u8(&s, 0x60); wb_uleb(&s, 1); wb_u8(&s, W_TI32); wb_uleb(&s, 1); wb_u8(&s, W_TI32);
    wb_u8(&s, 0x60); wb_uleb(&s, 2); wb_u8(&s, W_TI32); wb_u8(&s, W_TI64); wb_uleb(&s, 1); wb_u8(&s, W_TI32);
    wb_u8(&s, 0x60); wb_uleb(&s, 4); wb_u8(&s, W_TI32); wb_u8(&s, W_TI32); wb_u8(&s, W_TI32); wb_u8(&s, W_TI32); wb_uleb(&s, 1); wb_u8(&s, W_TI32);
    wb_section(m, 1, &s); s.n = 0;
    /* imports: the engine's memory and helpers */
    wb_uleb(&s, 1 + WF_COUNT);
    wb_name(&s, "e"); wb_name(&s, "memory"); wb_u8(&s, 0x02); wb_u8(&s, 0x00); wb_uleb(&s, 0);
    wb_name(&s, "e"); wb_name(&s, "wjit_step"); wb_u8(&s, 0x00); wb_uleb(&s, 1);
    wb_name(&s, "e"); wb_name(&s, "wjit_free"); wb_u8(&s, 0x00); wb_uleb(&s, 2);
    wb_name(&s, "e"); wb_name(&s, "wjit_poll"); wb_u8(&s, 0x00); wb_uleb(&s, 3);
    wb_name(&s, "e"); wb_name(&s, "wjit_to_bool"); wb_u8(&s, 0x00); wb_uleb(&s, 4);
    wb_name(&s, "e"); wb_name(&s, "wjit_get_field"); wb_u8(&s, 0x00); wb_uleb(&s, 5);
    wb_name(&s, "e"); wb_name(&s, "wjit_put_field"); wb_u8(&s, 0x00); wb_uleb(&s, 5);
    wb_name(&s, "e"); wb_name(&s, "wjit_call"); wb_u8(&s, 0x00); wb_uleb(&s, 1);
    wb_name(&s, "e"); wb_name(&s, "wjit_get_var"); wb_u8(&s, 0x00); wb_uleb(&s, 5);
    wb_name(&s, "e"); wb_name(&s, "wjit_decref"); wb_u8(&s, 0x00); wb_uleb(&s, 2);
    wb_section(m, 2, &s); s.n = 0;
    /* one function, exported as "f" */
    wb_uleb(&s, 1); wb_uleb(&s, 0);
    wb_section(m, 3, &s); s.n = 0;
    wb_uleb(&s, 1); wb_name(&s, "f"); wb_u8(&s, 0x00); wb_uleb(&s, WF_COUNT);
    wb_section(m, 7, &s); s.n = 0;
    /* code */
    wb_uleb(&body, 3);
    wb_uleb(&body, WJIT_N_I32); wb_u8(&body, W_TI32);
    wb_uleb(&body, WJIT_N_I64); wb_u8(&body, W_TI64);
    wb_uleb(&body, WJIT_N_F64); wb_u8(&body, W_TF64);
    wb_bytes(&body, c->code.p, c->code.n);
    wb_uleb(&s, 1); wb_uleb(&s, body.n); wb_bytes(&s, body.p, body.n);
    wb_section(m, 10, &s);
    ok = !(s.oom || body.oom || m->oom);
    free(s.p);
    free(body.p);
    return ok ? 0 : -1;
}

/* Compiles b; its table index (> 0) goes to b->wjit_index, -1 when it cannot be compiled (never tried again). */
static int wjit_compile(JSContext *ctx, JSFunctionBytecode *b)
{
    JSRuntime *rt = ctx->rt;
    WJitC c;
    WBuf m = { 0 };
    int32_t index = -1;
    size_t n;
    memset(&c, 0, sizeof(c));
    b->wjit_index = -1;
    wjit_layout_init();
    if (wjit_config.max_functions && wjit_stats.compiled >= wjit_config.max_functions) { wjit_stats.refused++; return -1; }
    if ((uint32_t)b->byte_code_len > wjit_config.max_bytecode_bytes) { wjit_stats.refused++; return -1; }
    c.ctx = ctx;
    c.b = b;
    c.bc = b->byte_code_buf;
    c.len = b->byte_code_len;
    n = (size_t)c.len + 1;
    c.depth = js_malloc_rt(rt, sizeof(int16_t) * n);
    c.catch_pos = js_malloc_rt(rt, sizeof(int32_t) * n);
    c.blk_of = js_malloc_rt(rt, sizeof(int32_t) * n);
    c.blk_start = js_malloc_rt(rt, sizeof(int32_t) * n);
    c.loop_end = js_malloc_rt(rt, sizeof(int32_t) * n);
    c.cons = js_malloc_rt(rt, sizeof(*c.cons) * n * 2);
    c.stack = js_malloc_rt(rt, sizeof(int) * n * 2);
    if (!c.depth || !c.catch_pos || !c.blk_of || !c.blk_start || !c.loop_end || !c.cons || !c.stack) { c.why = "out of memory"; goto fail; }
    if (wjit_analyze(&c) < 0 || wjit_structure(&c) < 0)
        goto fail;
    {
        /* one inline cache per property access site that runs */
        uint32_t nic = 0;
        int pos, op;
        for (pos = 0; pos < c.len; pos += short_opcode_info(op).size) {
            op = c.bc[pos];
            if (c.depth[pos] >= 0 && (op == OP_get_field || op == OP_get_field2 || op == OP_get_length || op == OP_put_field ||
                                      op == OP_get_var || op == OP_get_var_undef))
                nic++;
        }
        if (nic) {
            c.data = js_mallocz_rt(rt, sizeof(WJitData) + sizeof(WJitIC) * nic);
            if (!c.data) { c.why = "out of memory"; goto fail; }
            c.data->nic = nic;
        }
    }
    if (wjit_emit_body(&c) < 0 || wjit_module(&c, &m) < 0)
        goto fail;
    index = wr_Engine_jitCompile(m.p, m.n);
    if (index == 0) { c.why = "the browser did not compile it"; goto fail; }
    b->wjit_data = c.data;
    c.data = NULL;
    if (index < 0) {
        /* compiled in the background: the interpreter goes on until wjit_ready sees it attached */
        b->wjit_index = WJIT_PENDING;
        b->wjit_calls = (uint32_t)-index;
        b->wjit_seen = wjit_done_count - 1;
        wjit_stats.pending++;
    } else {
        b->wjit_index = index;
    }
    wjit_stats.compiled++;
    wjit_stats.module_bytes += m.n;
    wjit_stats.bytecode_bytes += c.len;
    goto done;
 fail:
    wjit_stats.failed++;
 done:
    js_free_rt(rt, c.depth); js_free_rt(rt, c.catch_pos); js_free_rt(rt, c.blk_of); js_free_rt(rt, c.blk_start);
    js_free_rt(rt, c.loop_end); js_free_rt(rt, c.cons); js_free_rt(rt, c.stack);
    js_free_rt(rt, c.data);   /* (not handed over: nothing cached yet) */
    free(c.code.p);
    free(m.p);
    return b->wjit_index;
}

WJIT_EXPORT("wj_jit_done_address")
uint32_t wj_jit_done_address(void) { return (uint32_t)(uintptr_t)&wjit_done_count; }

/* a function compiled in the background: attached now? */
static no_inline int wjit_poll_pending(JSContext *ctx, JSFunctionBytecode *b)
{
    int32_t r;
    uint32_t seen = wjit_done_count;
    if (b->wjit_seen == seen)
        return 0;
    r = wr_Engine_jitPoll((int32_t)b->wjit_calls);
    if (r < 0) {
        b->wjit_seen = seen;
        return 0;
    }
    wjit_stats.pending--;
    if (r == 0) {
        b->wjit_index = WJIT_NEVER;
        wjit_release(ctx->rt, b);
        wjit_stats.failed++;
        return 0;
    }
    b->wjit_index = r;
    return 1;
}

/* the interpreter's hook (JS_CallInternal, before its loop): runs the compiled code of b if it has (or now gets) any */
static inline int wjit_ready(JSContext *ctx, JSFunctionBytecode *b)
{
    if (b->wjit_index > 0)
        return 1;
    if (b->wjit_index == WJIT_PENDING)
        return wjit_poll_pending(ctx, b);
    if (b->wjit_index < 0 || !wjit_config.enabled || b->func_kind != JS_FUNC_NORMAL)
        return 0;
    if (++b->wjit_calls < wjit_config.call_threshold)
        return 0;
    return wjit_compile(ctx, b) > 0;
}

/* a back edge of the interpreter (WJIT_LOOP): counts toward compiling the function; true when it has compiled code
   that may have an entry at this loop header */
static no_inline int wjit_loop_slow(JSContext *ctx, JSFunctionBytecode *b)
{
    if (!wjit_config.enabled || b->func_kind != JS_FUNC_NORMAL)
        return 0;
    if (b->wjit_index == WJIT_PENDING)
        return wjit_poll_pending(ctx, b);
    if (++b->wjit_loops < wjit_config.loop_threshold)
        return 0;
    b->wjit_loops = 0;
    return wjit_compile(ctx, b) > 0;
}

static inline int wjit_loop(JSContext *ctx, JSFunctionBytecode *b, const uint8_t *pc)
{
    if (b->wjit_index > 0)
        return (uint32_t)(pc - b->byte_code_buf) != b->wjit_osr_miss;
    if (b->wjit_index == WJIT_NEVER)
        return 0;
    return wjit_loop_slow(ctx, b);
}

/* runs the compiled code from the loop header at `entry` (an offset in the bytecode; WJIT_NOENTRY when it has none
   there) */
static int wjit_run_at(WJitFrame *jf, JSFunctionBytecode *b, int entry)
{
    int st;
    st = ((int (*)(WJitFrame *, int))(uintptr_t)b->wjit_index)(jf, entry);
    if (st == WJIT_NOENTRY)
        return st;
    wjit_stats.osr_entries++;
    if (st == WJIT_RET) wjit_stats.exits_return++;
    else if (st == WJIT_EXC) wjit_stats.exits_exception++;
    else wjit_stats.exits_deopt++;
    return st;
}

static int wjit_run(WJitFrame *jf, JSFunctionBytecode *b)
{
    int st;
    wjit_stats.entries++;
    st = ((int (*)(WJitFrame *, int))(uintptr_t)b->wjit_index)(jf, 0);
    if (st == WJIT_RET) wjit_stats.exits_return++;
    else if (st == WJIT_EXC) wjit_stats.exits_exception++;
    else wjit_stats.exits_deopt++;
    return st;
}

#endif /* WREN_JIT */
