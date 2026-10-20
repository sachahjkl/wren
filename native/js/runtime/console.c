/* console.c: the console namespace (Console Standard). Arguments are formatted here, the way browsers show them on a
 * single line (strings as is at the top level, quoted inside objects; arrays, objects, errors with their stack, DOM
 * nodes as <tag id class>, functions, symbols, depth- and length-limited), then sent to the browser's console with
 * their level (js.Engine_console). printf-style substitutions (%s %d %i %f %o %O %c) are applied to the first
 * argument. Counters, timers and group indentation are kept per realm. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "../engine/qjs_internal.h"

typedef struct sb { char *p; size_t n, cap; } sb;

static void sb_put(sb *b, const char *s, size_t n)
{
    if (b->n + n + 1 > b->cap) {
        size_t c = b->cap ? b->cap : 128;
        while (c < b->n + n + 1) { c *= 2; }
        char *q = realloc(b->p, c);
        if (!q) { return; }
        b->p = q;
        b->cap = c;
    }
    memcpy(b->p + b->n, s, n);
    b->n += n;
    b->p[b->n] = 0;
}
static void sb_str(sb *b, const char *s) { sb_put(b, s, strlen(s)); }

#define INSPECT_MAX_DEPTH 2
#define INSPECT_MAX_ITEMS 100
#define INSPECT_MAX_STRING 10000

static int console_indent;

static void inspect(JSContext *ctx, sb *b, JSValueConst v, int depth, bool top);

static void put_js_string(JSContext *ctx, sb *b, JSValueConst v, bool quoted)
{
    size_t n;
    const char *s = JS_ToCStringLen(ctx, &n, v);
    if (!s) { JS_FreeValue(ctx, JS_GetException(ctx)); sb_str(b, "?"); return; }
    if (n > INSPECT_MAX_STRING) { n = INSPECT_MAX_STRING; }
    if (quoted) {
        sb_put(b, "'", 1);
        for (size_t i = 0; i < n; i++) {
            char c = s[i];
            if (c == '\'') { sb_put(b, "\\'", 2); }
            else if (c == '\n') { sb_put(b, "\\n", 2); }
            else if (c == '\\') { sb_put(b, "\\\\", 2); }
            else { sb_put(b, &c, 1); }
        }
        sb_put(b, "'", 1);
    } else {
        sb_put(b, s, n);
    }
    JS_FreeCString(ctx, s);
}

static void put_key(JSContext *ctx, sb *b, JSAtom atom)
{
    JSValue k = JS_AtomToValue(ctx, atom);
    if (JS_IsSymbol(k)) { sb_put(b, "[", 1); put_js_string(ctx, b, k, false); sb_put(b, "]", 1); JS_FreeValue(ctx, k); return; }
    size_t n;
    const char *s = JS_ToCStringLen(ctx, &n, k);
    JS_FreeValue(ctx, k);
    if (!s) { JS_FreeValue(ctx, JS_GetException(ctx)); return; }
    bool ident = n > 0 && !(s[0] >= '0' && s[0] <= '9');
    for (size_t i = 0; i < n && ident; i++) {
        char c = s[i];
        ident = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$';
    }
    if (ident) { sb_put(b, s, n); } else { sb_put(b, "'", 1); sb_put(b, s, n); sb_put(b, "'", 1); }
    JS_FreeCString(ctx, s);
}

/* <tag id="..." class="..."> for an element, #text "..." for a text node, #document... */
extern bool wj_describe_node(JSContext *ctx, sb *b, JSValueConst v) __attribute__((weak));

static void inspect_object(JSContext *ctx, sb *b, JSValueConst v, int depth)
{
    if (JS_IsFunction(ctx, v)) {
        JSValue name = JS_GetPropertyStr(ctx, v, "name");
        size_t n = 0;
        const char *s = JS_IsString(name) ? JS_ToCStringLen(ctx, &n, name) : NULL;
        sb_str(b, "[Function");
        if (s && n) { sb_str(b, ": "); sb_put(b, s, n); }
        else { sb_str(b, " (anonymous)"); }
        sb_str(b, "]");
        if (s) { JS_FreeCString(ctx, s); }
        JS_FreeValue(ctx, name);
        return;
    }
    if (JS_IsError(v)) {
        JSValue st = JS_GetPropertyStr(ctx, v, "stack");
        JSValue str = JS_ToString(ctx, v);
        put_js_string(ctx, b, str, false);
        JS_FreeValue(ctx, str);
        if (JS_IsString(st)) {
            size_t n;
            const char *s = JS_ToCStringLen(ctx, &n, st);
            if (s && n) { sb_str(b, "\n"); sb_put(b, s, n); while (b->n && b->p[b->n - 1] == '\n') { b->p[--b->n] = 0; } }
            if (s) { JS_FreeCString(ctx, s); }
        }
        JS_FreeValue(ctx, st);
        return;
    }
    if (wj_describe_node && wj_obj_of(v) && wj_describe_node(ctx, b, v)) { return; }
    if (JS_IsDate(v) || JS_IsRegExp(v)) {
        JSValue s = JS_ToString(ctx, v);
        put_js_string(ctx, b, s, false);
        JS_FreeValue(ctx, s);
        return;
    }
    bool array = JS_IsArray(v);
    if (depth > INSPECT_MAX_DEPTH) { sb_str(b, JS_IsPromise(v) ? "[Promise]" : array ? "[Array]" : "[Object]"); return; }
    if (JS_IsPromise(v)) {
        JSPromiseStateEnum st = JS_PromiseState(ctx, v);
        sb_str(b, "Promise {");
        if (st == JS_PROMISE_PENDING) { sb_str(b, " <pending>"); }
        else {
            JSValue r = JS_PromiseResult(ctx, v);
            sb_str(b, st == JS_PROMISE_REJECTED ? " <rejected> " : " ");
            inspect(ctx, b, r, depth + 1, false);
            JS_FreeValue(ctx, r);
        }
        sb_str(b, " }");
        return;
    }
    if (array) {
        int64_t len = 0;
        if (JS_GetLength(ctx, v, &len) < 0) { JS_FreeValue(ctx, JS_GetException(ctx)); }
        sb_str(b, "[");
        for (int64_t i = 0; i < len && i < INSPECT_MAX_ITEMS; i++) {
            if (i) { sb_str(b, ", "); } else { sb_str(b, " "); }
            JSValue e = JS_GetPropertyInt64(ctx, v, i);
            inspect(ctx, b, e, depth + 1, false);
            JS_FreeValue(ctx, e);
        }
        if (len > INSPECT_MAX_ITEMS) { char t[64]; snprintf(t, sizeof t, ", ... %lld more items", (long long)(len - INSPECT_MAX_ITEMS)); sb_str(b, t); }
        sb_str(b, len ? " ]" : "]");
        return;
    }
    /* constructor name prefix for class instances ("Foo { a: 1 }"), none for plain objects */
    JSValue ctor = JS_GetPropertyStr(ctx, v, "constructor");
    if (JS_HasException(ctx)) { JS_FreeValue(ctx, JS_GetException(ctx)); }
    if (JS_IsFunction(ctx, ctor)) {
        JSValue name = JS_GetPropertyStr(ctx, ctor, "name");
        size_t n = 0;
        const char *s = JS_IsString(name) ? JS_ToCStringLen(ctx, &n, name) : NULL;
        if (s && n && strcmp(s, "Object") != 0) { sb_put(b, s, n); sb_str(b, " "); }
        if (s) { JS_FreeCString(ctx, s); }
        JS_FreeValue(ctx, name);
    }
    JS_FreeValue(ctx, ctor);
    JSPropertyEnum *tab = NULL;
    uint32_t count = 0;
    if (JS_GetOwnPropertyNames(ctx, &tab, &count, v, JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK | JS_GPN_ENUM_ONLY) < 0) {
        JS_FreeValue(ctx, JS_GetException(ctx));
        sb_str(b, "{}");
        return;
    }
    sb_str(b, "{");
    for (uint32_t i = 0; i < count; i++) {
        if (i >= INSPECT_MAX_ITEMS) { sb_str(b, ", ..."); break; }
        sb_str(b, i ? ", " : " ");
        put_key(ctx, b, tab[i].atom);
        sb_str(b, ": ");
        JSValue e = JS_GetProperty(ctx, v, tab[i].atom);
        if (JS_IsException(e)) { JS_FreeValue(ctx, JS_GetException(ctx)); sb_str(b, "[Exception]"); }
        else { inspect(ctx, b, e, depth + 1, false); }
        JS_FreeValue(ctx, e);
    }
    sb_str(b, count ? " }" : "}");
    JS_FreePropertyEnum(ctx, tab, count);
}

static void inspect(JSContext *ctx, sb *b, JSValueConst v, int depth, bool top)
{
    if (JS_IsString(v)) { put_js_string(ctx, b, v, !top); return; }
    if (JS_IsSymbol(v)) {
        JSValue d = JS_GetPropertyStr(ctx, v, "description");
        sb_str(b, "Symbol(");
        if (JS_IsString(d)) { put_js_string(ctx, b, d, false); }
        sb_str(b, ")");
        JS_FreeValue(ctx, d);
        return;
    }
    if (JS_IsBigInt(v)) {
        JSValue s = JS_ToString(ctx, v);
        put_js_string(ctx, b, s, false);
        sb_str(b, "n");
        JS_FreeValue(ctx, s);
        return;
    }
    if (JS_IsObject(v)) { inspect_object(ctx, b, v, depth); return; }
    /* numbers (-0 shown as such), booleans, null, undefined */
    if (JS_IsNumber(v)) {
        double d;
        JS_ToFloat64(ctx, &d, v);
        if (d == 0 && signbit(d)) { sb_str(b, "-0"); return; }
    }
    JSValue s = JS_ToString(ctx, v);
    put_js_string(ctx, b, s, false);
    JS_FreeValue(ctx, s);
}

/* Formats arguments like console.log: substitutions in a string first argument, then the rest separated by spaces. */
static void format_args(JSContext *ctx, sb *b, int argc, JSValueConst *argv)
{
    for (int i = 0; i < console_indent; i++) { sb_str(b, "  "); }
    int next = 0;
    if (argc > 0 && JS_IsString(argv[0])) {
        size_t n;
        const char *f = JS_ToCStringLen(ctx, &n, argv[0]);
        next = 1;
        if (f) {
            for (size_t i = 0; i < n; i++) {
                if (f[i] != '%' || i + 1 >= n) { sb_put(b, &f[i], 1); continue; }
                char c = f[i + 1];
                if (c == '%') { sb_put(b, "%", 1); i++; continue; }
                if (!strchr("sdifoOc", c)) { sb_put(b, &f[i], 1); continue; }
                i++;
                if (next >= argc) { sb_put(b, &f[i - 1], 2); continue; }
                JSValueConst a = argv[next++];
                switch (c) {
                case 's': inspect(ctx, b, a, 1, true); break;
                case 'd': case 'i': {
                    double d;
                    if (JS_IsSymbol(a) || JS_ToFloat64(ctx, &d, a) < 0) { JS_FreeValue(ctx, JS_GetException(ctx)); sb_str(b, "NaN"); break; }
                    char t[64];
                    if (isnan(d)) { snprintf(t, sizeof t, "NaN"); } else { snprintf(t, sizeof t, "%.0f", trunc(d)); }
                    sb_str(b, t);
                    break;
                }
                case 'f': {
                    double d;
                    if (JS_IsSymbol(a) || JS_ToFloat64(ctx, &d, a) < 0) { JS_FreeValue(ctx, JS_GetException(ctx)); sb_str(b, "NaN"); break; }
                    JSValue s = JS_NewFloat64(ctx, d);
                    inspect(ctx, b, s, 1, true);
                    break;
                }
                case 'c': break;   /* CSS styling: ignored by a text console */
                default: inspect(ctx, b, a, 0, false); break;
                }
            }
            JS_FreeCString(ctx, f);
        }
    }
    for (int i = next; i < argc; i++) {
        if (b->n > 0 && (i > 0)) { sb_str(b, " "); }
        inspect(ctx, b, argv[i], 0, true);
    }
}

static JSValue console_emit(JSContext *ctx, int level, int argc, JSValueConst *argv)
{
    sb b = {0};
    format_args(ctx, &b, argc, argv);
    wj_console_text(level, b.p ? b.p : "", b.n);
    free(b.p);
    return JS_UNDEFINED;
}

JSValue wjr_console_log(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return console_emit(ctx, wr_ConsoleLevel_Log, argc, argv); }
JSValue wjr_console_info(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return console_emit(ctx, wr_ConsoleLevel_Info, argc, argv); }
JSValue wjr_console_warn(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return console_emit(ctx, wr_ConsoleLevel_Warn, argc, argv); }
JSValue wjr_console_error(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return console_emit(ctx, wr_ConsoleLevel_Error, argc, argv); }
JSValue wjr_console_debug(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return console_emit(ctx, wr_ConsoleLevel_Debug, argc, argv); }

JSValue wjr_console_trace(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    sb b = {0};
    sb_str(&b, "Trace");
    if (argc) { sb_str(&b, ": "); format_args(ctx, &b, argc, argv); }
    JSValue err = JS_NewError(ctx);
    JSValue st = JS_GetPropertyStr(ctx, err, "stack");
    if (JS_IsString(st)) { sb_str(&b, "\n"); put_js_string(ctx, &b, st, false); }
    JS_FreeValue(ctx, st);
    JS_FreeValue(ctx, err);
    wj_console_text(wr_ConsoleLevel_Log, b.p ? b.p : "", b.n);
    free(b.p);
    return JS_UNDEFINED;
}

JSValue wjr_console_assert(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc > 0 && JS_ToBool(ctx, argv[0])) { return JS_UNDEFINED; }
    sb b = {0};
    sb_str(&b, "Assertion failed");
    if (argc > 1) { sb_str(&b, ": "); format_args(ctx, &b, argc - 1, argv + 1); }
    wj_console_text(wr_ConsoleLevel_Error, b.p ? b.p : "", b.n);
    free(b.p);
    return JS_UNDEFINED;
}

JSValue wjr_console_group(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    if (argc) { console_emit(ctx, wr_ConsoleLevel_Log, argc, argv); }
    console_indent++;
    return JS_UNDEFINED;
}

JSValue wjr_console_groupEnd(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(ctx); WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (console_indent > 0) { console_indent--; }
    return JS_UNDEFINED;
}

/* labels for count / time: a small list, one per realm */
typedef struct label { struct label *next; char *name; double value; } label;
static label *counts, *timers;

static label *find_label(label **list, const char *name, bool create)
{
    for (label *l = *list; l; l = l->next) { if (strcmp(l->name, name) == 0) { return l; } }
    if (!create) { return NULL; }
    label *l = calloc(1, sizeof *l);
    if (!l) { return NULL; }
    l->name = strdup(name);
    l->next = *list;
    *list = l;
    return l;
}

static void drop_label(label **list, label *x)
{
    for (label **p = list; *p; p = &(*p)->next) {
        if (*p == x) { *p = x->next; free(x->name); free(x); return; }
    }
}

static const char *label_arg(JSContext *ctx, int argc, JSValueConst *argv)
{
    if (argc == 0 || JS_IsUndefined(argv[0])) { return NULL; }
    return JS_ToCString(ctx, argv[0]);
}

JSValue wjr_console_count(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    const char *s = label_arg(ctx, argc, argv);
    if (argc && !s && !JS_IsUndefined(argv[0])) { return JS_EXCEPTION; }
    const char *name = s ? s : "default";
    label *l = find_label(&counts, name, true);
    char t[600];
    snprintf(t, sizeof t, "%s%s: %.0f", "", name, l ? ++l->value : 0);
    wj_console_text(wr_ConsoleLevel_Info, t, strlen(t));
    if (s) { JS_FreeCString(ctx, s); }
    return JS_UNDEFINED;
}

JSValue wjr_console_countReset(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    const char *s = label_arg(ctx, argc, argv);
    label *l = find_label(&counts, s ? s : "default", false);
    if (l) { l->value = 0; }
    if (s) { JS_FreeCString(ctx, s); }
    return JS_UNDEFINED;
}

static double console_now(void) { return wr_Performance_now(); }

JSValue wjr_console_time(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    const char *s = label_arg(ctx, argc, argv);
    const char *name = s ? s : "default";
    if (find_label(&timers, name, false)) {
        char t[600];
        snprintf(t, sizeof t, "Timer '%s' already exists", name);
        wj_console_text(wr_ConsoleLevel_Warn, t, strlen(t));
    } else {
        label *l = find_label(&timers, name, true);
        if (l) { l->value = console_now(); }
    }
    if (s) { JS_FreeCString(ctx, s); }
    return JS_UNDEFINED;
}

static JSValue console_time_report(JSContext *ctx, int argc, JSValueConst *argv, bool end)
{
    const char *s = label_arg(ctx, argc, argv);
    const char *name = s ? s : "default";
    label *l = find_label(&timers, name, false);
    char t[700];
    if (!l) {
        snprintf(t, sizeof t, "Timer '%s' does not exist", name);
        wj_console_text(wr_ConsoleLevel_Warn, t, strlen(t));
    } else {
        sb b = {0};
        snprintf(t, sizeof t, "%s: %.3f ms", name, console_now() - l->value);
        sb_str(&b, t);
        if (!end && argc > 1) { sb_str(&b, " "); format_args(ctx, &b, argc - 1, argv + 1); }
        wj_console_text(wr_ConsoleLevel_Info, b.p ? b.p : "", b.n);
        free(b.p);
        if (end) { drop_label(&timers, l); }
    }
    if (s) { JS_FreeCString(ctx, s); }
    return JS_UNDEFINED;
}

JSValue wjr_console_timeLog(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return console_time_report(ctx, argc, argv, false); }
JSValue wjr_console_timeEnd(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return console_time_report(ctx, argc, argv, true); }

JSValue wjr_console_dir(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    sb b = {0};
    if (argc) { inspect(ctx, &b, argv[0], 0, false); }
    wj_console_text(wr_ConsoleLevel_Log, b.p ? b.p : "", b.n);
    free(b.p);
    return JS_UNDEFINED;
}

JSValue wjr_console_groupCollapsed(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return wjr_console_group(ctx, this_val, argc, argv); }
JSValue wjr_console_dirxml(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return wjr_console_dir(ctx, this_val, argc, argv); }

JSValue wjr_console_table(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return wjr_console_log(ctx, this_val, argc, argv); }

JSValue wjr_console_clear(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(ctx); WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv);
    console_indent = 0;
    return JS_UNDEFINED;
}

/* The completion value of a script run from the browser's console ("run JavaScript"). */
void wj_console_inspect_result(JSContext *ctx, JSValueConst v)
{
    sb b = {0};
    inspect(ctx, &b, v, 0, false);
    wj_console_text(wr_ConsoleLevel_Info, b.p ? b.p : "", b.n);
    free(b.p);
}

/* Fallback before the bindings exist (or when they do not expose console): a console object with these members. */
void wj_install_console(JSContext *ctx, JSValueConst global)
{
    static const JSCFunctionListEntry funcs[] = {
        JS_CFUNC_DEF("log", 0, wjr_console_log), JS_CFUNC_DEF("info", 0, wjr_console_info),
        JS_CFUNC_DEF("warn", 0, wjr_console_warn), JS_CFUNC_DEF("error", 0, wjr_console_error),
        JS_CFUNC_DEF("debug", 0, wjr_console_debug), JS_CFUNC_DEF("trace", 0, wjr_console_trace),
        JS_CFUNC_DEF("assert", 0, wjr_console_assert), JS_CFUNC_DEF("group", 0, wjr_console_group),
        JS_CFUNC_DEF("groupCollapsed", 0, wjr_console_groupCollapsed), JS_CFUNC_DEF("groupEnd", 0, wjr_console_groupEnd),
        JS_CFUNC_DEF("count", 0, wjr_console_count), JS_CFUNC_DEF("countReset", 0, wjr_console_countReset),
        JS_CFUNC_DEF("time", 0, wjr_console_time), JS_CFUNC_DEF("timeLog", 0, wjr_console_timeLog),
        JS_CFUNC_DEF("timeEnd", 0, wjr_console_timeEnd), JS_CFUNC_DEF("dir", 0, wjr_console_dir),
        JS_CFUNC_DEF("dirxml", 0, wjr_console_dirxml), JS_CFUNC_DEF("table", 0, wjr_console_table),
        JS_CFUNC_DEF("clear", 0, wjr_console_clear),
    };
    JSValue c = JS_NewObject(ctx);
    JS_SetPropertyFunctionList(ctx, c, funcs, (int)(sizeof funcs / sizeof funcs[0]));
    JS_DefinePropertyValueStr(ctx, global, "console", c, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
}
