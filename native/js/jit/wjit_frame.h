/* Wren's JavaScript JIT (wjit.h): the frame the interpreter shares with compiled code, and the interpreter's hook.
 * Included by quickjs.c before JS_CallInternal (patch 0005-wren-jit). */

typedef struct WJitFrame {
    JSContext *caller_ctx;
    JSContext *ctx;
    JSStackFrame *sf;
    JSFunctionBytecode *b;
    JSObject *p;
    JSValue *local_buf, *arg_buf, *var_buf, *stack_buf;
    JSVarRef **var_refs;
    JSValueConst *argv;
    int argc, flags;
    JSValue func_obj, this_obj, new_target;
    uint8_t *pc;   /* out: where the interpreter resumes (deopt), or the pc of an exception */
    JSValue *sp;   /* out */
    JSValue ret;   /* out: the return value */
} WJitFrame;

/* what compiled code (and wjit_step) returns */
enum { WJIT_OK = 0, WJIT_EXC = 1, WJIT_DEOPT = 2, WJIT_RET = 3 };   /* (and WJIT_NOENTRY, wjit.h) */

static inline int wjit_ready(JSContext *ctx, JSFunctionBytecode *b);
static int wjit_run(WJitFrame *jf, JSFunctionBytecode *b);
static inline int wjit_loop(JSContext *ctx, JSFunctionBytecode *b, const uint8_t *pc);
static int wjit_run_at(WJitFrame *jf, JSFunctionBytecode *b, int entry);

/* in JS_CallInternal, after a backward branch to pc: enter the compiled code at this loop header (on-stack
   replacement: the frame is the same); the interpreter goes on when it has no entry there (remembered) */
#define WJIT_LOOP() do { \
        if (unlikely(wjit_loop(ctx, b, pc))) { \
            WJitFrame jf_; \
            int st_; \
            jf_.caller_ctx = caller_ctx; jf_.ctx = ctx; jf_.sf = sf; jf_.b = b; jf_.p = p; \
            jf_.local_buf = local_buf; jf_.arg_buf = arg_buf; jf_.var_buf = var_buf; jf_.stack_buf = stack_buf; \
            jf_.var_refs = var_refs; jf_.argv = argv; jf_.argc = argc; jf_.flags = flags; \
            jf_.func_obj = func_obj; jf_.this_obj = this_obj; jf_.new_target = new_target; jf_.sp = sp; \
            st_ = wjit_run_at(&jf_, b, (int)(pc - b->byte_code_buf)); \
            if (st_ == 4) { \
                b->wjit_osr_miss = (uint32_t)(pc - b->byte_code_buf); \
            } else { \
                sp = jf_.sp; \
                if (st_ == WJIT_RET) { ret_val = jf_.ret; goto done; } \
                pc = jf_.pc; \
                if (st_ == WJIT_EXC) goto exception; \
            } \
        } \
    } while (0)
