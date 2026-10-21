# Regenerates native\js\patches\0005-wren-jit.patch (the JIT's hooks in quickjs.c) from the source build_js.ps1 left in
# build\js\src after patches 0001-0004 (run build_js.ps1 once without 0005, or with it: the hooks are removed first).
#   powershell -NoProfile -File native\js\jit\make_patch.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$src = Join-Path $root 'build\js\src\quickjs-0.17.0\quickjs.c'
$tmp = Join-Path ([IO.Path]::GetTempPath()) "wren_jit_patch_$PID"
New-Item -ItemType Directory -Force "$tmp\a", "$tmp\b" | Out-Null
$c = [IO.File]::ReadAllText($src).Replace("`r`n", "`n")
# start from the source without 0005: reverse it when it is applied
if ($c.Contains('wjit_frame.h')) {
    [IO.File]::WriteAllText("$tmp\a\quickjs.c", $c)
    Push-Location "$tmp\a"
    try {
        $env:GIT_CEILING_DIRECTORIES = $tmp
        & git apply -R --whitespace=nowarn (Join-Path $root 'native\js\patches\0005-wren-jit.patch')
        if ($LASTEXITCODE -ne 0) { throw 'cannot reverse 0005' }
    } finally { Pop-Location }
    $c = [IO.File]::ReadAllText("$tmp\a\quickjs.c").Replace("`r`n", "`n")
}
[IO.File]::WriteAllText("$tmp\a\quickjs.c", $c)

function Swap([string]$old, [string]$new) {
    $old = $old.Replace("`r`n", "`n"); $new = $new.Replace("`r`n", "`n")
    if (-not $script:c.Contains($old)) { throw "not found: $old" }
    $script:c = $script:c.Replace($old, $new)
}

Swap @"
    int pc2line_len;
    uint8_t *pc2line_buf;
    char *source;
} JSFunctionBytecode;
"@ @"
    int pc2line_len;
    uint8_t *pc2line_buf;
    char *source;
#ifdef WREN_JIT
    int32_t wjit_index;   /* WREN: table index of the compiled code (native/js/jit); 0 none yet, -1 never */
    uint32_t wjit_calls;  /* WREN: calls counted toward the JIT's threshold */
    void *wjit_data;      /* WREN: the compiled code's inline caches */
    uint32_t wjit_seen;   /* WREN: the JIT's completion count when last polled (being compiled) */
#endif
} JSFunctionBytecode;

#ifdef WREN_JIT
static void wjit_release(JSRuntime *rt, JSFunctionBytecode *b);
static void wjit_mark(JSRuntime *rt, JSFunctionBytecode *b, JS_MarkFunc *mark_func);
#endif
"@

Swap @"
            for(i = 0; i < b->cpool_count; i++) {
                JS_MarkValue(rt, b->cpool[i], mark_func);
            }
            if (b->realm)
                mark_func(rt, &b->realm->header);
"@ @"
            for(i = 0; i < b->cpool_count; i++) {
                JS_MarkValue(rt, b->cpool[i], mark_func);
            }
            if (b->realm)
                mark_func(rt, &b->realm->header);
#ifdef WREN_JIT
            wjit_mark(rt, b, mark_func);   /* WREN: the shapes the inline caches hold */
#endif
"@

Swap @"
/* argv[] is modified if (flags & JS_CALL_FLAG_COPY_ARGV) = 0. */
static JSValue JS_CallInternal(JSContext *caller_ctx,
"@ @"
#ifdef WREN_JIT
#include "wjit_frame.h"   /* WREN: hot functions compiled to WebAssembly (native/js/jit) */
#endif

/* argv[] is modified if (flags & JS_CALL_FLAG_COPY_ARGV) = 0. */
static JSValue JS_CallInternal(JSContext *caller_ctx,
"@

Swap @"
 restart:
    for(;;) {
        int call_argc;
        JSValue *call_argv;

"@ @"
#ifdef WREN_JIT
    /* WREN: compiled code runs on this very frame; it hands back a return value, an exception at (pc, sp) for the
       handler below, or (pc, sp) for the interpreter to carry on */
    if (wjit_ready(ctx, b)) {
        WJitFrame jf;
        int st;
        jf.caller_ctx = caller_ctx; jf.ctx = ctx; jf.sf = sf; jf.b = b; jf.p = p;
        jf.local_buf = local_buf; jf.arg_buf = arg_buf; jf.var_buf = var_buf; jf.stack_buf = stack_buf;
        jf.var_refs = var_refs; jf.argv = argv; jf.argc = argc; jf.flags = flags;
        jf.func_obj = func_obj; jf.this_obj = this_obj; jf.new_target = new_target;
        st = wjit_run(&jf, b);
        sp = jf.sp;
        if (st == WJIT_RET) {
            ret_val = jf.ret;
            goto done;
        }
        pc = jf.pc;
        if (st == WJIT_EXC)
            goto exception;
    }
#endif

 restart:
    for(;;) {
        int call_argc;
        JSValue *call_argv;

"@

Swap @"
static void free_function_bytecode(JSRuntime *rt, JSFunctionBytecode *b)
{
    int i;

"@ @"
static void free_function_bytecode(JSRuntime *rt, JSFunctionBytecode *b)
{
    int i;

#ifdef WREN_JIT
    wjit_release(rt, b);
#endif
"@

$c = $c.TrimEnd() + "`n`n#ifdef WREN_JIT`n#include `"wjit.h`"   /* WREN: the JIT (native/js/jit) */`n#endif`n"
[IO.File]::WriteAllText("$tmp\b\quickjs.c", $c)
Push-Location $tmp
try {
    $d = & git -c core.autocrlf=false -c diff.noprefix=false -c diff.mnemonicprefix=false diff --no-ext-diff --no-color --no-index a/quickjs.c b/quickjs.c
} finally { Pop-Location }
$txt = ($d -join "`n") + "`n"
$txt = $txt -replace '(?m)^index [0-9a-f]+\.\.[0-9a-f]+ 100644\n', ''
$txt = $txt -replace '(?m)^diff --git \S+ \S+$', 'diff --git a/quickjs.c b/quickjs.c' -replace '(?m)^--- \S+$', '--- a/quickjs.c' -replace '(?m)^\+\+\+ \S+$', '+++ b/quickjs.c'
[IO.File]::WriteAllText((Join-Path $root 'native\js\patches\0005-wren-jit.patch'), $txt)
[IO.Directory]::Delete($tmp, $true)
"0005-wren-jit.patch: $(([regex]::Matches($txt, '(?m)^@@')).Count) hunks"
