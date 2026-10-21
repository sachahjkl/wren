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
enum { WJIT_OK = 0, WJIT_EXC = 1, WJIT_DEOPT = 2, WJIT_RET = 3 };

static inline int wjit_ready(JSContext *ctx, JSFunctionBytecode *b);
static int wjit_run(WJitFrame *jf, JSFunctionBytecode *b);
