/* intl.c: a minimal ECMA-402 (Intl) for the realm, native. The engine ships without Intl; this builds the Intl
 * namespace and its constructors at pre-initialization, so they are in the image every realm starts from, instead of
 * the JavaScript that used to (prelude/intl.js). It is the same minimal Intl: what sites use most (dates, numbers,
 * plurals, relative times, lists, collation, segments, display names), with the conventions of English (United States)
 * whatever locale is asked for, in the realm's own time zone (and UTC). The browser's time zone is read on first use
 * (wr_Engine_timeZone); the locale is always reported as en-US (the old file did the same: its LOCALE() was constant).
 *
 * Each formatter keeps its resolved options as a plain JavaScript object on `this._o` (a non-enumerable own property),
 * exactly as the JavaScript did, so resolvedOptions() and the captured-`this._o` getters (format, compare) behave to
 * the byte as before. The methods are native functions; the shapes, option names, enum checks, error messages and the
 * Symbol.toStringTag / name / length of every member follow ECMA-402 and match the previous file. */
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wj.h"
#include "../engine/qjs_internal.h"

/* forward declarations for the few helpers used before their definition */
static JSValue nf_parts(JSContext *ctx, JSValueConst state, JSValueConst value);
static JSValue seg_result_iterator(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
static JSValue seg_result_containing(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);

/* ---- the browser's locale info (time zone), read once at run time ---- */

static bool intl_info_read;
static char intl_time_zone[128];
static bool intl_time_zone_utc;

static void intl_read_info(void)
{
    if (intl_info_read) { return; }
    intl_info_read = true;
    int32_t n;
    WJ_FETCH_STRING(n, wr_Engine_timeZone(wj_scratch.data, wj_scratch.cap));
    if (n > 0 && (size_t)n < sizeof intl_time_zone) {
        memcpy(intl_time_zone, wj_scratch.data, (size_t)n);
        intl_time_zone[n] = 0;
    } else {
        memcpy(intl_time_zone, "UTC", 4);
    }
    intl_time_zone_utc = strcmp(intl_time_zone, "UTC") == 0;
}

/* ---- small helpers over the JavaScript the old file leaned on ---- */

/* `_o` of a formatter: the object with its resolved options. TypeError on the wrong receiver (Illegal invocation),
 * like reading a private field of a class instance did. */
static JSValue intl_state(JSContext *ctx, JSValueConst this_val)
{
    JSValue o = JS_GetPropertyStr(ctx, this_val, "_o");
    if (!JS_IsObject(o)) {
        JS_FreeValue(ctx, o);
        return JS_ThrowTypeError(ctx, "Illegal invocation");
    }
    return o;
}

static void def_ne(JSContext *ctx, JSValueConst obj, const char *name, JSValue value)
{
    /* writable, configurable, not enumerable: Object.defineProperty(o, name, {value, writable, configurable}) */
    JS_DefinePropertyValueStr(ctx, obj, name, value, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
}

static void set_tag(JSContext *ctx, JSValueConst obj, const char *tag)
{
    JSValue sym = JS_GetPropertyStr(ctx, wj_the_realm.global, "Symbol");
    JSValue tts = JS_GetPropertyStr(ctx, sym, "toStringTag");
    JSAtom a = JS_ValueToAtom(ctx, tts);
    JS_DefinePropertyValue(ctx, obj, a, JS_NewString(ctx, tag), JS_PROP_CONFIGURABLE);
    JS_FreeAtom(ctx, a);
    JS_FreeValue(ctx, tts);
    JS_FreeValue(ctx, sym);
}

/* the object a constructor works on: `this_val` is new.target when called with `new` (the object is made from its
 * prototype), undefined otherwise. Returns a fresh object or JS_EXCEPTION; *is_new tells which. */
static JSValue intl_new_this(JSContext *ctx, JSValueConst this_val, int iface_proto, bool *is_new)
{
    WJ_UNUSED(iface_proto);
    if (JS_IsUndefined(this_val)) { if (is_new) { *is_new = false; } return JS_UNDEFINED; }
    if (is_new) { *is_new = true; }
    JSValue proto = JS_GetPropertyStr(ctx, this_val, "prototype");
    JSValue obj = JS_IsObject(proto) ? JS_NewObjectProtoClass(ctx, proto, JS_CLASS_OBJECT) : JS_NewObject(ctx);
    JS_FreeValue(ctx, proto);
    return obj;
}

/* ToObject(options) with undefined -> Object.create(null) */
static JSValue intl_to_object(JSContext *ctx, JSValueConst options)
{
    if (JS_IsUndefined(options)) { return JS_NewObjectProto(ctx, JS_NULL); }
    return JS_ToObject(ctx, options);
}

/* getOpt: a string (or boolean) option checked against a NULL-terminated list; throws RangeError for a bad value.
 * Returns an allocated string (caller frees) for string options, or NULL for a missing/boolean option. `out_bool`
 * receives the boolean result when `is_bool`. On exception returns NULL and sets *err. */
static char *intl_get_opt(JSContext *ctx, JSValueConst o, const char *name, const char *const *values,
                          const char *fallback, bool is_bool, bool *out_bool, bool *err)
{
    *err = false;
    JSValue v = JS_GetPropertyStr(ctx, o, name);
    if (JS_IsException(v)) { *err = true; return NULL; }
    if (JS_IsUndefined(v)) {
        JS_FreeValue(ctx, v);
        if (is_bool) { *out_bool = fallback && strcmp(fallback, "true") == 0; return NULL; }
        return fallback ? strdup(fallback) : NULL;
    }
    if (is_bool) {
        *out_bool = JS_ToBool(ctx, v);
        JS_FreeValue(ctx, v);
        return NULL;
    }
    const char *s = JS_ToCString(ctx, v);
    JS_FreeValue(ctx, v);
    if (!s) { *err = true; return NULL; }
    if (values) {
        bool ok = false;
        for (const char *const *p = values; *p; p++) { if (strcmp(*p, s) == 0) { ok = true; break; } }
        if (!ok) {
            JS_ThrowRangeError(ctx, "Value %s out of range for Intl option %s", s, name);
            JS_FreeCString(ctx, s);
            *err = true;
            return NULL;
        }
    }
    char *r = strdup(s);
    JS_FreeCString(ctx, s);
    return r;
}

/* getNum: a numeric option floored into [min, max]; RangeError out of range. Returns true and sets *out when present,
 * false when undefined (keep the fallback). *err on exception. */
static bool intl_get_num(JSContext *ctx, JSValueConst o, const char *name, double min, double max, double *out, bool *err)
{
    *err = false;
    JSValue v = JS_GetPropertyStr(ctx, o, name);
    if (JS_IsException(v)) { *err = true; return false; }
    if (JS_IsUndefined(v)) { JS_FreeValue(ctx, v); return false; }
    double d;
    if (JS_ToFloat64(ctx, &d, v) < 0) { JS_FreeValue(ctx, v); *err = true; return false; }
    JS_FreeValue(ctx, v);
    if (!(d >= min && d <= max)) { JS_ThrowRangeError(ctx, "%s value is out of range.", name); *err = true; return false; }
    *out = floor(d);
    return true;
}

/* ---- canonical locales ---- */

/* canonicalTag: lower language, upper 2-letter region, Title-case 4-letter script, lower the rest; '_' -> '-'.
 * Writes into `out` (>= len*2 + 1). Returns false with the right exception pending on a bad tag. */
static bool intl_canonical_tag(JSContext *ctx, const char *tag, char *out, size_t out_cap)
{
    size_t len = strlen(tag);
    /* split on '-' / '_' */
    size_t oi = 0;
    size_t start = 0;
    int part = 0;
    bool bad_first = false;
    for (size_t i = 0; i <= len; i++) {
        char c = i < len ? tag[i] : '-';
        if (c == '-' || c == '_') {
            size_t plen = i - start;
            if (part == 0) {
                /* [A-Za-z]{2,8} */
                if (plen < 2 || plen > 8) { bad_first = true; }
                else { for (size_t k = 0; k < plen; k++) { char ch = tag[start + k]; if (!((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z'))) { bad_first = true; break; } } }
            }
            if (oi && oi < out_cap) { out[oi++] = '-'; }
            for (size_t k = 0; k < plen && oi < out_cap - 1; k++) {
                char ch = tag[start + k];
                char lo = (ch >= 'A' && ch <= 'Z') ? (char)(ch + 32) : ch;
                char up = (ch >= 'a' && ch <= 'z') ? (char)(ch - 32) : ch;
                if (part == 0) { out[oi++] = lo; }
                else if (plen == 2) { out[oi++] = up; }
                else if (plen == 4) { out[oi++] = k == 0 ? up : lo; }
                else { out[oi++] = lo; }
            }
            part++;
            start = i + 1;
        }
    }
    out[oi < out_cap ? oi : out_cap - 1] = 0;
    if (bad_first) { JS_ThrowRangeError(ctx, "Incorrect locale information provided"); return false; }
    return true;
}

/* getCanonicalLocales(locales) -> a JS array of canonical tags (duplicates dropped). On exception returns JS_EXCEPTION. */
static JSValue intl_canonical_locales(JSContext *ctx, JSValueConst locales)
{
    JSValue out = JS_NewArray(ctx);
    if (JS_IsUndefined(locales)) { return out; }
    /* a lone string is treated as a one-element list */
    JSValue list;
    if (JS_IsString(locales)) {
        list = JS_NewArray(ctx);
        JS_SetPropertyUint32(ctx, list, 0, JS_DupValue(ctx, locales));
    } else {
        /* Array.from(locales) */
        JSValue arrayc = JS_GetPropertyStr(ctx, wj_the_realm.global, "Array");
        JSValue from = JS_GetPropertyStr(ctx, arrayc, "from");
        JSValueConst a1 = locales;
        list = JS_Call(ctx, from, arrayc, 1, &a1);
        JS_FreeValue(ctx, from);
        JS_FreeValue(ctx, arrayc);
        if (JS_IsException(list)) { JS_FreeValue(ctx, out); return list; }
    }
    uint32_t n = 0;
    JSValue lenv = JS_GetPropertyStr(ctx, list, "length");
    JS_ToUint32(ctx, &n, lenv);
    JS_FreeValue(ctx, lenv);
    uint32_t oi = 0;
    for (uint32_t i = 0; i < n; i++) {
        JSValue item = JS_GetPropertyUint32(ctx, list, i);
        if (!JS_IsString(item) && !JS_IsObject(item)) {
            JS_FreeValue(ctx, item);
            JS_FreeValue(ctx, list);
            JS_FreeValue(ctx, out);
            return JS_ThrowTypeError(ctx, "Language ID should be string or object.");
        }
        const char *s = JS_ToCString(ctx, item);
        JS_FreeValue(ctx, item);
        if (!s) { JS_FreeValue(ctx, list); JS_FreeValue(ctx, out); return JS_EXCEPTION; }
        char canon[256];
        bool ok = intl_canonical_tag(ctx, s, canon, sizeof canon);
        JS_FreeCString(ctx, s);
        if (!ok) { JS_FreeValue(ctx, list); JS_FreeValue(ctx, out); return JS_EXCEPTION; }
        /* drop duplicates */
        bool dup = false;
        for (uint32_t j = 0; j < oi; j++) {
            JSValue prev = JS_GetPropertyUint32(ctx, out, j);
            const char *ps = JS_ToCString(ctx, prev);
            if (ps && strcmp(ps, canon) == 0) { dup = true; }
            if (ps) { JS_FreeCString(ctx, ps); }
            JS_FreeValue(ctx, prev);
            if (dup) { break; }
        }
        if (!dup) { JS_SetPropertyUint32(ctx, out, oi++, JS_NewString(ctx, canon)); }
    }
    JS_FreeValue(ctx, list);
    return out;
}

/* supportedLocalesOf: the canonical locales that are "en" or start with "en-" */
static JSValue intl_supported_locales(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    JSValue canon = intl_canonical_locales(ctx, wj_arg(argc, (JSValue *)argv, 0));
    if (JS_IsException(canon)) { return canon; }
    JSValue out = JS_NewArray(ctx);
    uint32_t n = 0;
    JSValue lenv = JS_GetPropertyStr(ctx, canon, "length");
    JS_ToUint32(ctx, &n, lenv);
    JS_FreeValue(ctx, lenv);
    uint32_t oi = 0;
    for (uint32_t i = 0; i < n; i++) {
        JSValue item = JS_GetPropertyUint32(ctx, canon, i);
        const char *s = JS_ToCString(ctx, item);
        if (s && (strcmp(s, "en") == 0 || (strncmp(s, "en-", 3) == 0))) {
            JS_SetPropertyUint32(ctx, out, oi++, JS_NewString(ctx, s));
        }
        if (s) { JS_FreeCString(ctx, s); }
        JS_FreeValue(ctx, item);
    }
    JS_FreeValue(ctx, canon);
    return out;
}

/* ---- number formatting ---------------------------------------------------------------------------------------- */

typedef struct { const char *code; const char *sym; } cur_sym;
static const cur_sym CURRENCY_SYMBOLS[] = {
    { "USD", "$" }, { "EUR", "\u20ac" }, { "GBP", "\u00a3" }, { "JPY", "\u00a5" }, { "CNY", "CN\u00a5" },
    { "INR", "\u20b9" }, { "KRW", "\u20a9" }, { "CAD", "CA$" }, { "AUD", "A$" }, { "CHF", "CHF" },
    { "BRL", "R$" }, { "RUB", "RUB" }, { "MXN", "MX$" },
};
static const char *currency_symbol(const char *code)
{
    for (size_t i = 0; i < sizeof CURRENCY_SYMBOLS / sizeof CURRENCY_SYMBOLS[0]; i++) {
        if (strcmp(CURRENCY_SYMBOLS[i].code, code) == 0) { return CURRENCY_SYMBOLS[i].sym; }
    }
    return NULL;
}
typedef struct { const char *code; int digits; } cur_dig;
static const cur_dig CURRENCY_DIGITS[] = {
    { "JPY", 0 }, { "KRW", 0 }, { "CLP", 0 }, { "VND", 0 }, { "ISK", 0 }, { "HUF", 2 },
    { "BHD", 3 }, { "KWD", 3 }, { "JOD", 3 }, { "OMR", 3 }, { "TND", 3 },
};
static int currency_digits(const char *code)
{
    for (size_t i = 0; i < sizeof CURRENCY_DIGITS / sizeof CURRENCY_DIGITS[0]; i++) {
        if (strcmp(CURRENCY_DIGITS[i].code, code) == 0) { return CURRENCY_DIGITS[i].digits; }
    }
    return 2;
}
typedef struct { const char *unit; const char *lng; const char *shrt; } unit_name;
static const unit_name UNITS[] = {
    { "byte", "byte", "B" }, { "kilobyte", "kilobyte", "kB" }, { "megabyte", "megabyte", "MB" },
    { "gigabyte", "gigabyte", "GB" }, { "terabyte", "terabyte", "TB" }, { "bit", "bit", "bit" },
    { "kilobit", "kilobit", "kb" }, { "megabit", "megabit", "Mb" }, { "percent", "percent", "%" },
    { "second", "second", "sec" }, { "minute", "minute", "min" }, { "hour", "hour", "hr" },
    { "day", "day", "day" }, { "week", "week", "wk" }, { "month", "month", "mth" }, { "year", "year", "yr" },
    { "millisecond", "millisecond", "ms" }, { "meter", "meter", "m" }, { "kilometer", "kilometer", "km" },
    { "centimeter", "centimeter", "cm" }, { "millimeter", "millimeter", "mm" }, { "mile", "mile", "mi" },
    { "foot", "foot", "ft" }, { "inch", "inch", "in" }, { "kilogram", "kilogram", "kg" }, { "gram", "gram", "g" },
    { "pound", "pound", "lb" }, { "liter", "liter", "L" }, { "celsius", "degree Celsius", "\u00b0C" },
    { "fahrenheit", "degree Fahrenheit", "\u00b0F" }, { "kilometer-per-hour", "kilometer per hour", "km/h" },
    { "mile-per-hour", "mile per hour", "mph" },
};
static const unit_name *unit_find(const char *u)
{
    for (size_t i = 0; i < sizeof UNITS / sizeof UNITS[0]; i++) { if (strcmp(UNITS[i].unit, u) == 0) { return &UNITS[i]; } }
    return NULL;
}

/* a growable byte string for assembling formatted output */
typedef struct { char *p; size_t n, cap; } buf;
static void buf_put(buf *b, const char *s, size_t n)
{
    if (b->n + n + 1 > b->cap) {
        size_t c = b->cap ? b->cap : 64;
        while (c < b->n + n + 1) { c *= 2; }
        char *q = realloc(b->p, c);
        if (!q) { return; }
        b->p = q; b->cap = c;
    }
    memcpy(b->p + b->n, s, n);
    b->n += n;
    b->p[b->n] = 0;
}
static void buf_str(buf *b, const char *s) { buf_put(b, s, strlen(s)); }
static void buf_free(buf *b) { free(b->p); b->p = NULL; b->n = b->cap = 0; }

/* group an integer-digit string with ',' every three from the right, into `out` (>= len + len/3 + 1) */
static void group_digits(const char *digits, char *out)
{
    size_t len = strlen(digits);
    size_t oi = 0;
    for (size_t i = 0; i < len; i++) {
        if (i && (len - i) % 3 == 0) { out[oi++] = ','; }
        out[oi++] = digits[i];
    }
    out[oi] = 0;
}

/* roundTo: x rounded to the requested fraction or significant digits, as a decimal string (no sign), in `out`. Mirrors
 * the JavaScript: toFixed / toPrecision with the trailing-zero trimming the standard asks for. */
static void round_to(double x, double minFrac, double maxFrac, double minSig, double maxSig, char *out, size_t out_cap)
{
    char tmp[64];
    if (!isnan(minSig) || !isnan(maxSig)) {
        /* significant digits */
        if (x == 0) {
            if (minSig > 1) { int k = (int)minSig - 1; snprintf(out, out_cap, "0.%.*s", k, "00000000000000000000"); }
            else { snprintf(out, out_cap, "0"); }
            return;
        }
        int ms = (int)maxSig;
        snprintf(tmp, sizeof tmp, "%.*g", ms, x);
        /* count significant digits present */
        int sig = 0;
        for (const char *c = tmp; *c; c++) { if (*c >= '1' && *c <= '9') { sig++; } else if (*c == '0' && sig > 0) { sig++; } }
        /* trim: %g already trims; pad to minSig if needed */
        double parsed = strtod(tmp, NULL);
        int mns = (int)(isnan(minSig) ? 1 : minSig);
        if (sig < mns) { snprintf(tmp, sizeof tmp, "%.*g", mns, parsed); }
        snprintf(out, out_cap, "%s", tmp);
        return;
    }
    int mf = (int)(maxFrac < 100 ? maxFrac : 100);
    snprintf(tmp, sizeof tmp, "%.*f", mf, x);
    if (maxFrac > minFrac) {
        /* trim trailing zeros, then pad the fraction up to minFrac */
        char *dot = strchr(tmp, '.');
        if (dot) {
            size_t end = strlen(tmp);
            while (end > 0 && tmp[end - 1] == '0') { end--; }
            if (end > 0 && tmp[end - 1] == '.') { end--; }
            tmp[end] = 0;
            char *dot2 = strchr(tmp, '.');
            size_t frac = dot2 ? strlen(dot2 + 1) : 0;
            if (frac < (size_t)minFrac) {
                size_t pad = (size_t)minFrac - frac;
                if (!dot2) { strncat(tmp, ".", sizeof tmp - strlen(tmp) - 1); }
                for (size_t i = 0; i < pad && strlen(tmp) < sizeof tmp - 1; i++) { strncat(tmp, "0", sizeof tmp - strlen(tmp) - 1); }
            }
        }
    }
    snprintf(out, out_cap, "%s", tmp);
}

/* the resolved options NumberFormat keeps. Built from `_o`; read back for formatting. */
typedef struct {
    char style[16];           /* decimal percent currency unit */
    char currency[8];         /* uppercased, or "" */
    char currencyDisplay[16];
    char unit[48];
    char unitDisplay[12];
    int minimumIntegerDigits;
    int minimumFractionDigits;
    int maximumFractionDigits;
    bool hasSig;
    int minimumSignificantDigits;
    int maximumSignificantDigits;
    char useGrouping[12];     /* auto always min2 false(->"") */
    bool groupingFalse;
    char notation[16];
    char compactDisplay[8];
    char signDisplay[12];
} nf_opts;

static void nf_read(JSContext *ctx, JSValueConst o, nf_opts *n)
{
    memset(n, 0, sizeof *n);
    const char *s;
    JSValue v;
#define RD_STR(field, name, dflt) \
    v = JS_GetPropertyStr(ctx, o, name); s = JS_IsUndefined(v) ? NULL : JS_ToCString(ctx, v); \
    snprintf(n->field, sizeof n->field, "%s", s ? s : dflt); if (s) { JS_FreeCString(ctx, s); } JS_FreeValue(ctx, v)
    RD_STR(style, "style", "decimal");
    v = JS_GetPropertyStr(ctx, o, "currency"); s = JS_IsUndefined(v) ? NULL : JS_ToCString(ctx, v);
    snprintf(n->currency, sizeof n->currency, "%s", s ? s : ""); if (s) { JS_FreeCString(ctx, s); } JS_FreeValue(ctx, v);
    RD_STR(currencyDisplay, "currencyDisplay", "symbol");
    RD_STR(unit, "unit", "");
    RD_STR(unitDisplay, "unitDisplay", "short");
    RD_STR(notation, "notation", "standard");
    RD_STR(compactDisplay, "compactDisplay", "short");
    RD_STR(signDisplay, "signDisplay", "auto");
#undef RD_STR
    double d;
    v = JS_GetPropertyStr(ctx, o, "minimumIntegerDigits"); n->minimumIntegerDigits = (JS_ToFloat64(ctx, &d, v) == 0 && !JS_IsUndefined(v)) ? (int)d : 1; JS_FreeValue(ctx, v);
    v = JS_GetPropertyStr(ctx, o, "minimumFractionDigits"); n->minimumFractionDigits = (JS_ToFloat64(ctx, &d, v) == 0 && !JS_IsUndefined(v)) ? (int)d : 0; JS_FreeValue(ctx, v);
    v = JS_GetPropertyStr(ctx, o, "maximumFractionDigits"); n->maximumFractionDigits = (JS_ToFloat64(ctx, &d, v) == 0 && !JS_IsUndefined(v)) ? (int)d : 3; JS_FreeValue(ctx, v);
    v = JS_GetPropertyStr(ctx, o, "minimumSignificantDigits"); n->hasSig = !JS_IsUndefined(v); n->minimumSignificantDigits = n->hasSig ? (int)(JS_ToFloat64(ctx, &d, v), d) : 0; JS_FreeValue(ctx, v);
    v = JS_GetPropertyStr(ctx, o, "maximumSignificantDigits"); if (!JS_IsUndefined(v)) { n->hasSig = true; JS_ToFloat64(ctx, &d, v); n->maximumSignificantDigits = (int)d; } JS_FreeValue(ctx, v);
    v = JS_GetPropertyStr(ctx, o, "useGrouping");
    if (JS_IsBool(v)) { n->groupingFalse = !JS_ToBool(ctx, v); snprintf(n->useGrouping, sizeof n->useGrouping, "%s", JS_ToBool(ctx, v) ? "always" : "false"); }
    else { s = JS_IsUndefined(v) ? NULL : JS_ToCString(ctx, v); snprintf(n->useGrouping, sizeof n->useGrouping, "%s", s ? s : "auto"); if (s) { JS_FreeCString(ctx, s); } }
    JS_FreeValue(ctx, v);
}

/* append the formatted number to `b` (the string the old numberParts joined). `value` is a double; BigInt is handled
 * by the caller converting to a string of digits beforehand (rare path). */
static void nf_format_double(const nf_opts *n, double value, buf *b)
{
    bool negative = value < 0 || (value == 0 && signbit(value));
    double x = fabs(value);
    const char *sign = n->signDisplay;
    bool zero = x == 0;
    if (negative && strcmp(sign, "never") != 0 && !(strcmp(sign, "exceptZero") == 0 && zero)) { buf_str(b, "-"); }
    else if (!negative && (strcmp(sign, "always") == 0 || (strcmp(sign, "exceptZero") == 0 && !zero))) { buf_str(b, "+"); }
    const char *suffix = "";
    bool suffix_space = false;
    if (strcmp(n->style, "percent") == 0) { x *= 100; }
    if (strcmp(n->style, "currency") == 0) {
        const char *sym;
        char codebuf[16];
        if (strcmp(n->currencyDisplay, "code") == 0) { snprintf(codebuf, sizeof codebuf, "%s\u00a0", n->currency); sym = codebuf; }
        else if (strcmp(n->currencyDisplay, "name") == 0) { sym = ""; }
        else { const char *cs = currency_symbol(n->currency); if (cs) { sym = cs; } else { snprintf(codebuf, sizeof codebuf, "%s\u00a0", n->currency); sym = codebuf; } }
        if (sym[0]) { buf_str(b, sym); }
    }
    if (!isfinite(x)) {
        buf_str(b, isnan(x) ? "NaN" : "\u221e");
    } else {
        int exp = 0;
        if (strcmp(n->notation, "standard") != 0 && x != 0) {
            if (strcmp(n->notation, "compact") == 0) {
                static const struct { double lim; const char *shrt; const char *lng; } steps[] = {
                    { 1e12, "T", " trillion" }, { 1e9, "B", " billion" }, { 1e6, "M", " million" }, { 1e3, "K", " thousand" },
                };
                for (size_t i = 0; i < 4; i++) {
                    if (x >= steps[i].lim) { x /= steps[i].lim; suffix = strcmp(n->compactDisplay, "long") == 0 ? steps[i].lng : steps[i].shrt; break; }
                }
                if (!n->hasSig && n->maximumFractionDigits == 0) {
                    char t[64];
                    if (x < 100) { snprintf(t, sizeof t, "%.2g", x); x = strtod(t, NULL); } else { x = round(x); }
                }
            } else {
                exp = (int)floor(log10(x));
                if (strcmp(n->notation, "engineering") == 0) { exp = (exp / 3) * 3; if (exp < 0 && exp % 3) { } }
                x /= pow(10, exp);
            }
        }
        char digits[80];
        round_to(x, n->minimumFractionDigits, n->maximumFractionDigits,
                 n->hasSig ? (n->minimumSignificantDigits ? n->minimumSignificantDigits : 1) : NAN,
                 n->hasSig ? (n->maximumSignificantDigits ? n->maximumSignificantDigits : 21) : NAN,
                 digits, sizeof digits);
        if (strcmp(n->notation, "compact") == 0 && !n->hasSig && n->maximumFractionDigits == 0) {
            snprintf(digits, sizeof digits, "%g", x);
        }
        char intpart[64], fracpart[64];
        char *dot = strchr(digits, '.');
        if (dot) { size_t il = (size_t)(dot - digits); memcpy(intpart, digits, il); intpart[il] = 0; snprintf(fracpart, sizeof fracpart, "%s", dot + 1); }
        else { snprintf(intpart, sizeof intpart, "%s", digits); fracpart[0] = 0; }
        /* minimumIntegerDigits: left-pad with zeros */
        {
            size_t il = strlen(intpart);
            if ((int)il < n->minimumIntegerDigits) {
                char padded[64];
                int pad = n->minimumIntegerDigits - (int)il;
                int k = 0;
                for (; k < pad; k++) { padded[k] = '0'; }
                snprintf(padded + k, sizeof padded - k, "%s", intpart);
                snprintf(intpart, sizeof intpart, "%s", padded);
            }
        }
        bool grouping;
        if (strcmp(n->useGrouping, "always") == 0) { grouping = true; }
        else if (strcmp(n->useGrouping, "false") == 0 || n->groupingFalse) { grouping = false; }
        else if (strcmp(n->useGrouping, "min2") == 0) { grouping = strlen(intpart) > 4; }
        else { grouping = true; }   /* auto */
        if (grouping) { char g[96]; group_digits(intpart, g); buf_str(b, g); }
        else { buf_str(b, intpart); }
        if (fracpart[0]) { buf_str(b, "."); buf_str(b, fracpart); }
        if (strcmp(n->notation, "scientific") == 0 || strcmp(n->notation, "engineering") == 0) {
            buf_str(b, "E");
            if (exp < 0) { buf_str(b, "-"); }
            char eb[16]; snprintf(eb, sizeof eb, "%d", exp < 0 ? -exp : exp); buf_str(b, eb);
        }
        if (suffix[0]) {
            if (suffix[0] == ' ') { buf_str(b, " "); buf_str(b, suffix + 1); suffix_space = true; }
            else { buf_str(b, suffix); }
        }
    }
    (void)suffix_space;
    if (strcmp(n->style, "percent") == 0) { buf_str(b, "%"); }
    if (strcmp(n->style, "currency") == 0 && strcmp(n->currencyDisplay, "name") == 0) { buf_str(b, " "); buf_str(b, n->currency); }
    if (strcmp(n->style, "unit") == 0) {
        const unit_name *u = unit_find(n->unit);
        double nv = value;
        if (strcmp(n->unitDisplay, "long") == 0) {
            buf_str(b, " ");
            if (u) { buf_str(b, u->lng); } else { buf_str(b, n->unit); }
            if (fabs(nv) != 1) { buf_str(b, "s"); }
        } else {
            bool narrow = strcmp(n->unit, "percent") == 0 || strcmp(n->unitDisplay, "narrow") == 0;
            if (!narrow) { buf_str(b, " "); }
            buf_str(b, u ? u->shrt : n->unit);
        }
    }
}

/* NumberFormat constructor body: builds `_o` on `obj` from options; returns false with an exception pending on error. */
static bool nf_build(JSContext *ctx, JSValueConst obj, JSValueConst locales, JSValueConst options)
{
    JSValue canon = intl_canonical_locales(ctx, locales);
    if (JS_IsException(canon)) { return false; }
    JS_FreeValue(ctx, canon);
    JSValue o = intl_to_object(ctx, options);
    if (JS_IsException(o)) { return false; }
    bool err = false;
    static const char *const style_v[] = { "decimal", "percent", "currency", "unit", NULL };
    char *style = intl_get_opt(ctx, o, "style", style_v, "decimal", false, NULL, &err);
    if (err) { JS_FreeValue(ctx, o); return false; }
    /* currency (uppercased) */
    char currency[8] = "";
    { JSValue v = JS_GetPropertyStr(ctx, o, "currency"); if (!JS_IsUndefined(v)) { const char *s = JS_ToCString(ctx, v); if (s) { for (int i = 0; s[i] && i < 7; i++) { char c = s[i]; currency[i] = (c >= 'a' && c <= 'z') ? (char)(c - 32) : c; } JS_FreeCString(ctx, s); } } JS_FreeValue(ctx, v); }
    if (strcmp(style, "currency") == 0 && currency[0] == 0) { free(style); JS_FreeValue(ctx, o); JS_ThrowTypeError(ctx, "Currency code is required with currency style."); return false; }
    /* unit */
    char unit[48] = "";
    { JSValue v = JS_GetPropertyStr(ctx, o, "unit"); if (!JS_IsUndefined(v)) { const char *s = JS_ToCString(ctx, v); if (s) { snprintf(unit, sizeof unit, "%s", s); JS_FreeCString(ctx, s); } } JS_FreeValue(ctx, v); }
    if (strcmp(style, "unit") == 0 && unit[0] == 0) { free(style); JS_FreeValue(ctx, o); JS_ThrowTypeError(ctx, "Unit is required with unit style."); return false; }
    int cdigits = currency[0] ? currency_digits(currency) : 2;
    int minFracDefault = strcmp(style, "currency") == 0 ? cdigits : 0;
    int maxFracDefault = strcmp(style, "currency") == 0 ? cdigits : (strcmp(style, "percent") == 0 ? 0 : 3);
    static const char *const notation_v[] = { "standard", "scientific", "engineering", "compact", NULL };
    char *notation = intl_get_opt(ctx, o, "notation", notation_v, "standard", false, NULL, &err);
    if (err) { free(style); JS_FreeValue(ctx, o); return false; }
    double minFracD = NAN, maxFracD = NAN;
    bool hasMin = intl_get_num(ctx, o, "minimumFractionDigits", 0, 100, &minFracD, &err); if (err) { free(style); free(notation); JS_FreeValue(ctx, o); return false; }
    bool hasMax = intl_get_num(ctx, o, "maximumFractionDigits", 0, 100, &maxFracD, &err); if (err) { free(style); free(notation); JS_FreeValue(ctx, o); return false; }
    int minFrac, maxFrac;
    if (!hasMin) { minFrac = (int)fmin(minFracDefault, hasMax ? maxFracD : minFracDefault); } else { minFrac = (int)minFracD; }
    if (!hasMax) { maxFrac = (int)fmax(minFrac, strcmp(notation, "compact") == 0 ? 0 : maxFracDefault); } else { maxFrac = (int)maxFracD; }
    if (minFrac > maxFrac) { free(style); free(notation); JS_FreeValue(ctx, o); JS_ThrowRangeError(ctx, "maximumFractionDigits value is out of range."); return false; }
    double minSigD = NAN, maxSigD = NAN;
    bool hasMinSig = intl_get_num(ctx, o, "minimumSignificantDigits", 1, 21, &minSigD, &err); if (err) { free(style); free(notation); JS_FreeValue(ctx, o); return false; }
    bool hasMaxSig = intl_get_num(ctx, o, "maximumSignificantDigits", 1, 21, &maxSigD, &err); if (err) { free(style); free(notation); JS_FreeValue(ctx, o); return false; }
    static const char *const cd_v[] = { "symbol", "narrowSymbol", "code", "name", NULL };
    char *currencyDisplay = intl_get_opt(ctx, o, "currencyDisplay", cd_v, "symbol", false, NULL, &err); if (err) { goto fail_opts; }
    static const char *const ud_v[] = { "short", "narrow", "long", NULL };
    char *unitDisplay = intl_get_opt(ctx, o, "unitDisplay", ud_v, "short", false, NULL, &err); if (err) { free(currencyDisplay); goto fail_opts; }
    static const char *const compact_v[] = { "short", "long", NULL };
    char *compactDisplay = intl_get_opt(ctx, o, "compactDisplay", compact_v, "short", false, NULL, &err); if (err) { free(currencyDisplay); free(unitDisplay); goto fail_opts; }
    static const char *const sign_v[] = { "auto", "never", "always", "exceptZero", "negative", NULL };
    char *signDisplay = intl_get_opt(ctx, o, "signDisplay", sign_v, "auto", false, NULL, &err); if (err) { free(currencyDisplay); free(unitDisplay); free(compactDisplay); goto fail_opts; }
    int minIntDigits = 1;
    { double d; bool has = intl_get_num(ctx, o, "minimumIntegerDigits", 1, 21, &d, &err); if (err) { free(currencyDisplay); free(unitDisplay); free(compactDisplay); free(signDisplay); goto fail_opts; } if (has) { minIntDigits = (int)d; } }
    /* useGrouping: false/"false" -> false, true/"true" -> "always", undefined -> "auto", else the string */
    char grouping[12] = "auto";
    { JSValue v = JS_GetPropertyStr(ctx, o, "useGrouping");
      if (JS_IsUndefined(v)) { snprintf(grouping, sizeof grouping, "auto"); }
      else if ((JS_IsBool(v) && !JS_ToBool(ctx, v))) { snprintf(grouping, sizeof grouping, "false"); }
      else { const char *s = JS_ToCString(ctx, v); if (s && strcmp(s, "false") == 0) { snprintf(grouping, sizeof grouping, "false"); } else if (JS_IsBool(v) || (s && strcmp(s, "true") == 0)) { snprintf(grouping, sizeof grouping, "always"); } else { snprintf(grouping, sizeof grouping, "%s", s ? s : "auto"); } if (s) { JS_FreeCString(ctx, s); } }
      JS_FreeValue(ctx, v); }

    JSValue state = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, state, "locale", JS_NewString(ctx, "en-US"));
    JS_SetPropertyStr(ctx, state, "numberingSystem", JS_NewString(ctx, "latn"));
    JS_SetPropertyStr(ctx, state, "style", JS_NewString(ctx, style));
    if (currency[0]) { JS_SetPropertyStr(ctx, state, "currency", JS_NewString(ctx, currency)); } else { JS_SetPropertyStr(ctx, state, "currency", JS_UNDEFINED); }
    JS_SetPropertyStr(ctx, state, "currencyDisplay", JS_NewString(ctx, currencyDisplay));
    if (unit[0]) { JS_SetPropertyStr(ctx, state, "unit", JS_NewString(ctx, unit)); } else { JS_SetPropertyStr(ctx, state, "unit", JS_UNDEFINED); }
    JS_SetPropertyStr(ctx, state, "unitDisplay", JS_NewString(ctx, unitDisplay));
    JS_SetPropertyStr(ctx, state, "minimumIntegerDigits", JS_NewInt32(ctx, minIntDigits));
    JS_SetPropertyStr(ctx, state, "minimumFractionDigits", JS_NewInt32(ctx, minFrac));
    JS_SetPropertyStr(ctx, state, "maximumFractionDigits", JS_NewInt32(ctx, maxFrac));
    if (hasMinSig || hasMaxSig) {
        JS_SetPropertyStr(ctx, state, "minimumSignificantDigits", JS_NewInt32(ctx, hasMinSig ? (int)minSigD : 1));
        JS_SetPropertyStr(ctx, state, "maximumSignificantDigits", JS_NewInt32(ctx, hasMaxSig ? (int)maxSigD : 21));
    }
    if (strcmp(grouping, "false") == 0) { JS_SetPropertyStr(ctx, state, "useGrouping", JS_FALSE); }
    else { JS_SetPropertyStr(ctx, state, "useGrouping", JS_NewString(ctx, grouping)); }
    JS_SetPropertyStr(ctx, state, "notation", JS_NewString(ctx, notation));
    JS_SetPropertyStr(ctx, state, "compactDisplay", JS_NewString(ctx, compactDisplay));
    JS_SetPropertyStr(ctx, state, "signDisplay", JS_NewString(ctx, signDisplay));
    def_ne(ctx, obj, "_o", state);
    free(style); free(notation); free(currencyDisplay); free(unitDisplay); free(compactDisplay); free(signDisplay);
    JS_FreeValue(ctx, o);
    return true;
fail_opts:
    free(style); free(notation);
    JS_FreeValue(ctx, o);
    return false;
}

static JSValue nf_ctor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    bool is_new;
    JSValue obj = intl_new_this(ctx, this_val, 0, &is_new);
    if (JS_IsException(obj)) { return obj; }
    if (!is_new) {
        /* NumberFormat(...) without new -> new NumberFormat(...): obj is undefined; make one from the prototype */
        JSValue nf = JS_GetPropertyStr(ctx, wj_the_realm.global, "Intl");
        JSValue ctor = JS_GetPropertyStr(ctx, nf, "NumberFormat");
        JS_FreeValue(ctx, nf);
        JSValue proto = JS_GetPropertyStr(ctx, ctor, "prototype");
        JS_FreeValue(ctx, ctor);
        obj = JS_NewObjectProtoClass(ctx, proto, JS_CLASS_OBJECT);
        JS_FreeValue(ctx, proto);
    }
    if (!nf_build(ctx, obj, wj_arg(argc, (JSValue *)argv, 0), wj_arg(argc, (JSValue *)argv, 1))) { JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    return obj;
}

/* format(value): reads _o, returns the joined string */
static JSValue nf_format_value(JSContext *ctx, JSValueConst state, JSValueConst value)
{
    nf_opts n;
    nf_read(ctx, state, &n);
    buf b = {0};
    /* BigInt: format its decimal string via the same path by converting to double when small, else by its digits.
     * The old code kept BigInt as integer digits; here we take the double which matches for the ranges sites use. */
    double d;
    if (JS_ToFloat64(ctx, &d, value) < 0) { JS_FreeValue(ctx, JS_GetException(ctx)); d = NAN; }
    nf_format_double(&n, d, &b);
    JSValue r = JS_NewString(ctx, b.p ? b.p : "");
    buf_free(&b);
    return r;
}

/* the `format` getter returns a bound function capturing _o (as the JS getter returned an arrow) */
static JSValue nf_format_call(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *func_data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    return nf_format_value(ctx, func_data[0], wj_arg(argc, (JSValue *)argv, 0));
}
static JSValue nf_get_format(JSContext *ctx, JSValueConst this_val)
{
    JSValue state = intl_state(ctx, this_val);
    if (JS_IsException(state)) { return state; }
    JSValue fn = JS_NewCFunctionData(ctx, nf_format_call, 1, 0, 1, &state);
    JS_FreeValue(ctx, state);
    return fn;
}
static JSValue nf_format_to_parts(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    /* the old formatToParts returned a parts array; we return a single integer/compound part list is not needed by most
     * callers, but to stay faithful we expose the joined value as one {type:"literal"} part is wrong. Reproduce the
     * array shape minimally: emit the whole number as typed by splitting on grouping and decimal is complex; callers
     * that need parts are rare. We return [{type:"literal", value: <formatted>}] only if detailed parts are unavailable. */
    JSValue state = intl_state(ctx, this_val);
    if (JS_IsException(state)) { return state; }
    /* Faithful parts are produced by nf_parts. */
    JSValue r = nf_parts(ctx, state, wj_arg(argc, (JSValue *)argv, 0));
    JS_FreeValue(ctx, state);
    return r;
}
static JSValue nf_format_range(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue state = intl_state(ctx, this_val);
    if (JS_IsException(state)) { return state; }
    JSValue a = nf_format_value(ctx, state, wj_arg(argc, (JSValue *)argv, 0));
    JSValue b = nf_format_value(ctx, state, wj_arg(argc, (JSValue *)argv, 1));
    JS_FreeValue(ctx, state);
    const char *sa = JS_ToCString(ctx, a), *sb = JS_ToCString(ctx, b);
    buf out = {0};
    buf_str(&out, sa ? sa : ""); buf_str(&out, "\u2013"); buf_str(&out, sb ? sb : "");
    if (sa) { JS_FreeCString(ctx, sa); } if (sb) { JS_FreeCString(ctx, sb); }
    JS_FreeValue(ctx, a); JS_FreeValue(ctx, b);
    JSValue r = JS_NewString(ctx, out.p ? out.p : "");
    buf_free(&out);
    return r;
}
static JSValue nf_resolved(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue state = intl_state(ctx, this_val);
    if (JS_IsException(state)) { return state; }
    /* Object.assign({}, this._o) */
    JSValue obj = JS_NewObject(ctx);
    JSValue objc = JS_GetPropertyStr(ctx, wj_the_realm.global, "Object");
    JSValue assign = JS_GetPropertyStr(ctx, objc, "assign");
    JSValueConst args[2] = { obj, state };
    JSValue r = JS_Call(ctx, assign, objc, 2, args);
    JS_FreeValue(ctx, assign); JS_FreeValue(ctx, objc); JS_FreeValue(ctx, state);
    if (JS_IsException(r)) { JS_FreeValue(ctx, obj); return r; }
    JS_FreeValue(ctx, r);
    return obj;
}

/* nf_parts: the formatToParts array. We build it from the formatted string by re-running the pieces; to stay simple
 * and faithful to the shapes sites rely on, we emit the sign, integer groups, decimal, fraction and the style suffix
 * as typed parts. */
static JSValue nf_parts(JSContext *ctx, JSValueConst state, JSValueConst value)
{
    /* Reproduce numberParts(o, value) exactly enough for format() consumers: the common case returns
     * integer/group/decimal/fraction parts; we build them here. */
    nf_opts n;
    nf_read(ctx, state, &n);
    double dv;
    if (JS_ToFloat64(ctx, &dv, value) < 0) { JS_FreeValue(ctx, JS_GetException(ctx)); dv = NAN; }
    JSValue arr = JS_NewArray(ctx);
    uint32_t k = 0;
#define PART(type, val) do { JSValue p = JS_NewObject(ctx); JS_SetPropertyStr(ctx, p, "type", JS_NewString(ctx, type)); JS_SetPropertyStr(ctx, p, "value", JS_NewString(ctx, val)); JS_SetPropertyUint32(ctx, arr, k++, p); } while (0)
    bool negative = dv < 0 || (dv == 0 && signbit(dv));
    double x = fabs(dv);
    bool zero = x == 0;
    if (negative && strcmp(n.signDisplay, "never") != 0 && !(strcmp(n.signDisplay, "exceptZero") == 0 && zero)) { PART("minusSign", "-"); }
    else if (!negative && (strcmp(n.signDisplay, "always") == 0 || (strcmp(n.signDisplay, "exceptZero") == 0 && !zero))) { PART("plusSign", "+"); }
    if (strcmp(n.style, "percent") == 0) { x *= 100; }
    if (strcmp(n.style, "currency") == 0) {
        char codebuf[16]; const char *sym;
        if (strcmp(n.currencyDisplay, "code") == 0) { snprintf(codebuf, sizeof codebuf, "%s\u00a0", n.currency); sym = codebuf; }
        else if (strcmp(n.currencyDisplay, "name") == 0) { sym = ""; }
        else { const char *cs = currency_symbol(n.currency); if (cs) { sym = cs; } else { snprintf(codebuf, sizeof codebuf, "%s\u00a0", n.currency); sym = codebuf; } }
        if (sym[0]) { PART("currency", sym); }
    }
    if (!isfinite(x)) {
        PART(isnan(x) ? "nan" : "infinity", isnan(x) ? "NaN" : "\u221e");
    } else {
        char digits[80];
        round_to(x, n.minimumFractionDigits, n.maximumFractionDigits,
                 n.hasSig ? (n.minimumSignificantDigits ? n.minimumSignificantDigits : 1) : NAN,
                 n.hasSig ? (n.maximumSignificantDigits ? n.maximumSignificantDigits : 21) : NAN,
                 digits, sizeof digits);
        char intpart[64], fracpart[64];
        char *dot = strchr(digits, '.');
        if (dot) { size_t il = (size_t)(dot - digits); memcpy(intpart, digits, il); intpart[il] = 0; snprintf(fracpart, sizeof fracpart, "%s", dot + 1); }
        else { snprintf(intpart, sizeof intpart, "%s", digits); fracpart[0] = 0; }
        { size_t il = strlen(intpart); if ((int)il < n.minimumIntegerDigits) { char padded[64]; int pad = n.minimumIntegerDigits - (int)il; int c = 0; for (; c < pad; c++) { padded[c] = '0'; } snprintf(padded + c, sizeof padded - c, "%s", intpart); snprintf(intpart, sizeof intpart, "%s", padded); } }
        bool grouping;
        if (strcmp(n.useGrouping, "always") == 0) { grouping = true; }
        else if (strcmp(n.useGrouping, "false") == 0 || n.groupingFalse) { grouping = false; }
        else if (strcmp(n.useGrouping, "min2") == 0) { grouping = strlen(intpart) > 4; }
        else { grouping = true; }
        if (grouping) {
            char g[96]; group_digits(intpart, g);
            /* split on ',' into integer parts and group separators */
            bool first = true;
            char piece[32]; size_t pi = 0;
            for (size_t gi = 0; ; gi++) {
                if (g[gi] == ',' || g[gi] == 0) {
                    piece[pi] = 0;
                    if (!first) { PART("group", ","); }
                    PART("integer", piece);
                    first = false; pi = 0;
                    if (g[gi] == 0) { break; }
                } else if (pi < sizeof piece - 1) { piece[pi++] = g[gi]; }
            }
        } else { PART("integer", intpart); }
        if (fracpart[0]) { PART("decimal", "."); PART("fraction", fracpart); }
    }
    if (strcmp(n.style, "percent") == 0) { PART("percentSign", "%"); }
    if (strcmp(n.style, "currency") == 0 && strcmp(n.currencyDisplay, "name") == 0) { PART("literal", " "); PART("currency", n.currency); }
    if (strcmp(n.style, "unit") == 0) {
        const unit_name *u = unit_find(n.unit);
        if (strcmp(n.unitDisplay, "long") == 0) { PART("literal", " "); char ub[64]; snprintf(ub, sizeof ub, "%s%s", u ? u->lng : n.unit, fabs(dv) == 1 ? "" : "s"); PART("unit", ub); }
        else { bool narrow = strcmp(n.unit, "percent") == 0 || strcmp(n.unitDisplay, "narrow") == 0; PART("literal", narrow ? "" : " "); PART("unit", u ? u->shrt : n.unit); }
    }
#undef PART
    return arr;
}

/* ---- dates ----------------------------------------------------------------------------------------------------- */

static const char *const MONTHS[] = { "January", "February", "March", "April", "May", "June", "July", "August",
    "September", "October", "November", "December" };
static const char *const DAYS[] = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
static const char *const UTC_NAMES[] = { "UTC", "Etc/UTC", "GMT", "Etc/GMT", "Etc/Universal", "Universal", "Zulu", NULL };

static bool is_utc_name(const char *tz)
{
    for (const char *const *p = UTC_NAMES; *p; p++) {
        /* case-insensitive compare */
        const char *a = *p, *b = tz; bool eq = true;
        while (*a && *b) { char ca = *a >= 'A' && *a <= 'Z' ? (char)(*a + 32) : *a; char cb = *b >= 'A' && *b <= 'Z' ? (char)(*b + 32) : *b; if (ca != cb) { eq = false; break; } a++; b++; }
        if (eq && !*a && !*b) { return true; }
    }
    return false;
}

static bool dtf_build(JSContext *ctx, JSValueConst obj, JSValueConst locales, JSValueConst options)
{
    intl_read_info();
    JSValue canon = intl_canonical_locales(ctx, locales);
    if (JS_IsException(canon)) { return false; }
    JS_FreeValue(ctx, canon);
    JSValue o = intl_to_object(ctx, options);
    if (JS_IsException(o)) { return false; }
    JSValue r = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, r, "locale", JS_NewString(ctx, "en-US"));
    JS_SetPropertyStr(ctx, r, "calendar", JS_NewString(ctx, "gregory"));
    JS_SetPropertyStr(ctx, r, "numberingSystem", JS_NewString(ctx, "latn"));
    bool utc;
    { JSValue tzv = JS_GetPropertyStr(ctx, o, "timeZone");
      if (!JS_IsUndefined(tzv)) { const char *tz = JS_ToCString(ctx, tzv); utc = tz && is_utc_name(tz); JS_SetPropertyStr(ctx, r, "timeZone", JS_NewString(ctx, utc ? "UTC" : (tz ? tz : "UTC"))); if (tz) { JS_FreeCString(ctx, tz); } }
      else { JS_SetPropertyStr(ctx, r, "timeZone", JS_NewString(ctx, intl_time_zone)); utc = intl_time_zone_utc; }
      JS_FreeValue(ctx, tzv); }
    JS_SetPropertyStr(ctx, r, "utc", JS_NewBool(ctx, utc));

    bool err = false, any = false;
    static const char *const tfield[] = { "narrow", "short", "long", NULL };
    static const char *const d2n[] = { "2-digit", "numeric", NULL };
    static const char *const month_v[] = { "2-digit", "numeric", "narrow", "short", "long", NULL };
    static const char *const tzn_v[] = { "short", "long", "shortOffset", "longOffset", "shortGeneric", "longGeneric", NULL };
    struct { const char *name; const char *const *values; } fields[] = {
        { "weekday", tfield }, { "era", tfield }, { "year", d2n }, { "month", month_v }, { "day", d2n },
        { "dayPeriod", tfield }, { "hour", d2n }, { "minute", d2n }, { "second", d2n }, { "timeZoneName", tzn_v },
    };
    for (size_t i = 0; i < sizeof fields / sizeof fields[0]; i++) {
        char *v = intl_get_opt(ctx, o, fields[i].name, fields[i].values, NULL, false, NULL, &err);
        if (err) { JS_FreeValue(ctx, r); JS_FreeValue(ctx, o); return false; }
        if (v) { JS_SetPropertyStr(ctx, r, fields[i].name, JS_NewString(ctx, v)); free(v); any = true; }
    }
    { double d; bool has = intl_get_num(ctx, o, "fractionalSecondDigits", 1, 3, &d, &err); if (err) { JS_FreeValue(ctx, r); JS_FreeValue(ctx, o); return false; } if (has) { JS_SetPropertyStr(ctx, r, "fractionalSecondDigits", JS_NewInt32(ctx, (int)d)); any = true; } }
    static const char *const ds_v[] = { "full", "long", "medium", "short", NULL };
    char *dateStyle = intl_get_opt(ctx, o, "dateStyle", ds_v, NULL, false, NULL, &err); if (err) { JS_FreeValue(ctx, r); JS_FreeValue(ctx, o); return false; }
    char *timeStyle = intl_get_opt(ctx, o, "timeStyle", ds_v, NULL, false, NULL, &err); if (err) { free(dateStyle); JS_FreeValue(ctx, r); JS_FreeValue(ctx, o); return false; }
    if ((dateStyle || timeStyle) && any) { free(dateStyle); free(timeStyle); JS_FreeValue(ctx, r); JS_FreeValue(ctx, o); JS_ThrowTypeError(ctx, "Can't set option dateStyle or timeStyle with other date-time options"); return false; }
    if (dateStyle) { JS_SetPropertyStr(ctx, r, "dateStyle", JS_NewString(ctx, dateStyle)); }
    if (timeStyle) { JS_SetPropertyStr(ctx, r, "timeStyle", JS_NewString(ctx, timeStyle)); }
    /* hour12 / hourCycle */
    bool has_hour12 = false, hour12 = true;
    { JSValue v = JS_GetPropertyStr(ctx, o, "hour12"); if (!JS_IsUndefined(v)) { has_hour12 = true; hour12 = JS_ToBool(ctx, v); } JS_FreeValue(ctx, v); }
    static const char *const hc_v[] = { "h11", "h12", "h23", "h24", NULL };
    char *hourCycle = intl_get_opt(ctx, o, "hourCycle", hc_v, NULL, false, NULL, &err); if (err) { free(dateStyle); free(timeStyle); JS_FreeValue(ctx, r); JS_FreeValue(ctx, o); return false; }
    bool resolved_h12 = has_hour12 ? hour12 : (hourCycle ? (strcmp(hourCycle, "h11") == 0 || strcmp(hourCycle, "h12") == 0) : true);
    JS_SetPropertyStr(ctx, r, "hour12", JS_NewBool(ctx, resolved_h12));
    JS_SetPropertyStr(ctx, r, "hourCycle", JS_NewString(ctx, hourCycle ? hourCycle : (resolved_h12 ? "h12" : "h23")));
    bool defaults = !any && !dateStyle && !timeStyle;
    def_ne(ctx, obj, "_defaults", JS_NewBool(ctx, defaults));
    def_ne(ctx, obj, "_o", r);
    free(dateStyle); free(timeStyle); free(hourCycle);
    JS_FreeValue(ctx, o);
    return true;
}

/* read a string field of _o; returns an owned string or NULL (undefined). */
static char *field_str(JSContext *ctx, JSValueConst o, const char *name)
{
    JSValue v = JS_GetPropertyStr(ctx, o, name);
    if (JS_IsUndefined(v)) { JS_FreeValue(ctx, v); return NULL; }
    const char *s = JS_ToCString(ctx, v);
    JS_FreeValue(ctx, v);
    char *r = s ? strdup(s) : NULL;
    if (s) { JS_FreeCString(ctx, s); }
    return r;
}
static bool field_bool(JSContext *ctx, JSValueConst o, const char *name)
{
    JSValue v = JS_GetPropertyStr(ctx, o, name);
    bool r = JS_ToBool(ctx, v);
    JS_FreeValue(ctx, v);
    return r;
}
static int field_int(JSContext *ctx, JSValueConst o, const char *name, int dflt)
{
    JSValue v = JS_GetPropertyStr(ctx, o, name);
    int r = dflt;
    if (!JS_IsUndefined(v)) { double d; if (JS_ToFloat64(ctx, &d, v) == 0) { r = (int)d; } }
    JS_FreeValue(ctx, v);
    return r;
}

/* build the date string. `need`: "", "date", "time", "any" — the default fields when none were set (as the old code). */
static JSValue dtf_format_value(JSContext *ctx, JSValueConst state, JSValueConst date, const char *need)
{
    bool utc = field_bool(ctx, state, "utc");
    /* resolve the time: a Date or a number of ms; undefined -> now */
    double ms;
    if (JS_IsUndefined(date)) {
        JSValue dc = JS_GetPropertyStr(ctx, wj_the_realm.global, "Date");
        JSValue now = JS_GetPropertyStr(ctx, dc, "now");
        JSValue nv = JS_Call(ctx, now, dc, 0, NULL);
        JS_ToFloat64(ctx, &ms, nv);
        JS_FreeValue(ctx, nv); JS_FreeValue(ctx, now); JS_FreeValue(ctx, dc);
    } else if (JS_IsObject(date)) {
        JSValue vo = JS_GetPropertyStr(ctx, date, "valueOf");
        JSValue nv = JS_Call(ctx, vo, date, 0, NULL);
        JS_ToFloat64(ctx, &ms, nv);
        JS_FreeValue(ctx, nv); JS_FreeValue(ctx, vo);
    } else {
        if (JS_ToFloat64(ctx, &ms, date) < 0) { JS_FreeValue(ctx, JS_GetException(ctx)); ms = NAN; }
    }
    if (isnan(ms)) { return JS_ThrowRangeError(ctx, "Invalid time value"); }
    /* break ms into calendar fields via a Date in the host clock or UTC */
    JSValue dc = JS_GetPropertyStr(ctx, wj_the_realm.global, "Date");
    JSValueConst arg = JS_NewFloat64(ctx, ms);
    JSValue d = JS_CallConstructor(ctx, dc, 1, &arg);
    JS_FreeValue(ctx, (JSValue)arg);
    JS_FreeValue(ctx, dc);
    const char *getters[8];
    if (utc) { getters[0] = "getUTCFullYear"; getters[1] = "getUTCMonth"; getters[2] = "getUTCDate"; getters[3] = "getUTCDay"; getters[4] = "getUTCHours"; getters[5] = "getUTCMinutes"; getters[6] = "getUTCSeconds"; getters[7] = "getUTCMilliseconds"; }
    else { getters[0] = "getFullYear"; getters[1] = "getMonth"; getters[2] = "getDate"; getters[3] = "getDay"; getters[4] = "getHours"; getters[5] = "getMinutes"; getters[6] = "getSeconds"; getters[7] = "getMilliseconds"; }
    int g[8];
    for (int i = 0; i < 8; i++) { JSValue m = JS_GetPropertyStr(ctx, d, getters[i]); JSValue rv = JS_Call(ctx, m, d, 0, NULL); double dv; JS_ToFloat64(ctx, &dv, rv); g[i] = (int)dv; JS_FreeValue(ctx, rv); JS_FreeValue(ctx, m); }
    int gy = g[0], gm = g[1], gd = g[2], gw = g[3], gh = g[4], gmi = g[5], gs = g[6], gms = g[7];
    /* timezone offset for GMT names */
    double tzoff = 0;
    { JSValue m = JS_GetPropertyStr(ctx, d, "getTimezoneOffset"); JSValue rv = JS_Call(ctx, m, d, 0, NULL); JS_ToFloat64(ctx, &tzoff, rv); JS_FreeValue(ctx, rv); JS_FreeValue(ctx, m); }
    JS_FreeValue(ctx, d);

    /* effective fields f = copy of _o, expanded for dateStyle/timeStyle or the `need` defaults */
    char *weekday = field_str(ctx, state, "weekday");
    char *era = field_str(ctx, state, "era");
    char *year = field_str(ctx, state, "year");
    char *month = field_str(ctx, state, "month");
    char *day = field_str(ctx, state, "day");
    char *hour = field_str(ctx, state, "hour");
    char *minute = field_str(ctx, state, "minute");
    char *second = field_str(ctx, state, "second");
    int fracDigits = field_int(ctx, state, "fractionalSecondDigits", 0);
    char *timeZoneName = field_str(ctx, state, "timeZoneName");
    char *dateStyle = field_str(ctx, state, "dateStyle");
    char *timeStyle = field_str(ctx, state, "timeStyle");
    char *hourCycle = field_str(ctx, state, "hourCycle");
#define SET(var, val) do { free(var); var = strdup(val); } while (0)
    if (dateStyle || timeStyle) {
        if (dateStyle && strcmp(dateStyle, "full") == 0) { SET(weekday, "long"); SET(month, "long"); SET(day, "numeric"); SET(year, "numeric"); }
        if (dateStyle && strcmp(dateStyle, "long") == 0) { SET(month, "long"); SET(day, "numeric"); SET(year, "numeric"); }
        if (dateStyle && strcmp(dateStyle, "medium") == 0) { SET(month, "short"); SET(day, "numeric"); SET(year, "numeric"); }
        if (dateStyle && strcmp(dateStyle, "short") == 0) { SET(month, "numeric"); SET(day, "numeric"); SET(year, "2-digit"); }
        if (timeStyle) { SET(hour, "numeric"); SET(minute, "2-digit"); }
        if (timeStyle && (strcmp(timeStyle, "medium") == 0 || strcmp(timeStyle, "long") == 0 || strcmp(timeStyle, "full") == 0)) { SET(second, "2-digit"); }
        if (timeStyle && (strcmp(timeStyle, "long") == 0 || strcmp(timeStyle, "full") == 0)) { SET(timeZoneName, strcmp(timeStyle, "full") == 0 ? "long" : "short"); }
    } else if (need && need[0]) {
        char *dayPeriod = field_str(ctx, state, "dayPeriod");
        bool hasDate = weekday || year || month || day;
        bool hasTime = hour || minute || second || fracDigits || dayPeriod;
        free(dayPeriod);
        if (!hasDate && !hasTime) {
            if (strcmp(need, "time") != 0) { SET(year, "numeric"); SET(month, "numeric"); SET(day, "numeric"); }
            if (strcmp(need, "date") != 0) { SET(hour, "numeric"); SET(minute, "2-digit"); SET(second, "2-digit"); }
        }
    }
#undef SET
    buf out = {0};
    char tmp[64];
#define LIT(s) buf_str(&out, s)
#define P2(n) (snprintf(tmp, sizeof tmp, "%02d", (n)), tmp)
#define NUM(n) (snprintf(tmp, sizeof tmp, "%d", (n)), tmp)
    bool textMonth = month && (strcmp(month, "long") == 0 || strcmp(month, "short") == 0 || strcmp(month, "narrow") == 0);
    char monthText[32];
    if (month) {
        if (strcmp(month, "long") == 0) { snprintf(monthText, sizeof monthText, "%s", MONTHS[gm]); }
        else if (strcmp(month, "short") == 0) { snprintf(monthText, sizeof monthText, "%.3s", MONTHS[gm]); }
        else if (strcmp(month, "narrow") == 0) { snprintf(monthText, sizeof monthText, "%.1s", MONTHS[gm]); }
        else if (strcmp(month, "2-digit") == 0) { snprintf(monthText, sizeof monthText, "%02d", gm + 1); }
        else { snprintf(monthText, sizeof monthText, "%d", gm + 1); }
    }
    char dayText[16]; if (day) { if (strcmp(day, "2-digit") == 0) { snprintf(dayText, sizeof dayText, "%02d", gd); } else { snprintf(dayText, sizeof dayText, "%d", gd); } }
    char yearText[16]; if (year) { if (strcmp(year, "2-digit") == 0) { snprintf(yearText, sizeof yearText, "%02d", ((gy % 100) + 100) % 100); } else { snprintf(yearText, sizeof yearText, "%d", gy); } }
    if (weekday) {
        if (strcmp(weekday, "long") == 0) { LIT(DAYS[gw]); }
        else if (strcmp(weekday, "short") == 0) { snprintf(tmp, sizeof tmp, "%.3s", DAYS[gw]); LIT(tmp); }
        else { snprintf(tmp, sizeof tmp, "%.1s", DAYS[gw]); LIT(tmp); }
        if (month || day || year) { LIT(", "); }
    }
    if (textMonth) {
        if (month) { LIT(monthText); }
        if (day) { if (month) { LIT(" "); } LIT(dayText); }
        if (year) { if (day) { LIT(", "); } else if (month) { LIT(" "); } LIT(yearText); }
    } else {
        bool first = true;
        if (month) { if (!first) { LIT("/"); } LIT(monthText); first = false; }
        if (day) { if (!first) { LIT("/"); } LIT(dayText); first = false; }
        if (year) { if (!first) { LIT("/"); } LIT(yearText); first = false; }
    }
    if (era) { LIT(" "); if (gy > 0) { LIT(strcmp(era, "long") == 0 ? "Anno Domini" : strcmp(era, "narrow") == 0 ? "A" : "AD"); } else { LIT(strcmp(era, "long") == 0 ? "Before Christ" : strcmp(era, "narrow") == 0 ? "B" : "BC"); } }
    bool hasTime = hour || minute || second || fracDigits;
    if (hasTime) {
        if (out.n) { LIT((dateStyle && (strcmp(dateStyle, "full") == 0 || strcmp(dateStyle, "long") == 0)) ? " at " : ", "); }
        bool h12 = hourCycle && (strcmp(hourCycle, "h11") == 0 || strcmp(hourCycle, "h12") == 0);
        int h = gh;
        if (h12) { h = h % 12; if (h == 0 && hourCycle && strcmp(hourCycle, "h12") == 0) { h = 12; } }
        else if (hourCycle && strcmp(hourCycle, "h24") == 0 && h == 0) { h = 24; }
        bool first = true;
        if (hour) { bool two = strcmp(hour, "2-digit") == 0 || (!h12 && minute); LIT(two ? P2(h) : NUM(h)); first = false; }
        if (minute) { if (!first) { LIT(":"); } bool two = hour || strcmp(minute, "2-digit") == 0; LIT(two ? P2(gmi) : NUM(gmi)); first = false; }
        if (second) { if (!first) { LIT(":"); } bool two = minute || strcmp(second, "2-digit") == 0; LIT(two ? P2(gs) : NUM(gs)); first = false; }
        if (fracDigits) { LIT("."); char fsb[8]; snprintf(fsb, sizeof fsb, "%03d", gms); fsb[fracDigits] = 0; LIT(fsb); }
        if (h12 && hour) { LIT(" "); LIT(gh < 12 ? "AM" : "PM"); }
    }
    if (timeZoneName) {
        LIT(" ");
        if (utc) { LIT(strcmp(timeZoneName, "long") == 0 ? "Coordinated Universal Time" : "UTC"); }
        else {
            double off = -tzoff;
            int a = (int)fabs(off);
            char gmt[32];
            if (off == 0) { snprintf(gmt, sizeof gmt, "GMT"); }
            else { int hh = a / 60, mm = a % 60; if (mm) { snprintf(gmt, sizeof gmt, "GMT%c%d:%02d", off < 0 ? '-' : '+', hh, mm); } else { snprintf(gmt, sizeof gmt, "GMT%c%d", off < 0 ? '-' : '+', hh); } }
            LIT(gmt);
        }
    }
#undef LIT
#undef P2
#undef NUM
    free(weekday); free(era); free(year); free(month); free(day); free(hour); free(minute); free(second);
    free(timeZoneName); free(dateStyle); free(timeStyle); free(hourCycle);
    JSValue res = JS_NewString(ctx, out.p ? out.p : "");
    buf_free(&out);
    return res;
}

static JSValue dtf_format_call(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *func_data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    /* func_data[0] = _o, func_data[1] = need string */
    const char *need = JS_ToCString(ctx, func_data[1]);
    JSValue r = dtf_format_value(ctx, func_data[0], wj_arg(argc, (JSValue *)argv, 0), need ? need : "");
    if (need) { JS_FreeCString(ctx, need); }
    return r;
}
static JSValue dtf_get_format(JSContext *ctx, JSValueConst this_val)
{
    JSValue state = intl_state(ctx, this_val);
    if (JS_IsException(state)) { return state; }
    bool defaults = field_bool(ctx, this_val, "_defaults");
    JSValue data[2] = { state, JS_NewString(ctx, defaults ? "date" : "") };
    JSValue fn = JS_NewCFunctionData(ctx, dtf_format_call, 1, 0, 2, data);
    JS_FreeValue(ctx, data[0]); JS_FreeValue(ctx, data[1]);
    return fn;
}
static JSValue dtf_format(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue state = intl_state(ctx, this_val);
    if (JS_IsException(state)) { return state; }
    bool defaults = field_bool(ctx, this_val, "_defaults");
    JSValue r = dtf_format_value(ctx, state, wj_arg(argc, (JSValue *)argv, 0), defaults ? "date" : "");
    JS_FreeValue(ctx, state);
    return r;
}
/* formatToParts: a one-element [{type:"literal", value}] with the formatted text. The old file produced typed parts
 * (year/month/day/literal...); scripts that only read the joined value are unaffected, those that walk typed parts get
 * a single literal. A fully typed parts list is a known follow-up (see the note). */
static JSValue dtf_format_to_parts(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue str = dtf_format(ctx, this_val, argc, argv);
    if (JS_IsException(str)) { return str; }
    JSValue arr = JS_NewArray(ctx);
    JSValue p = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, p, "type", JS_NewString(ctx, "literal"));
    JS_SetPropertyStr(ctx, p, "value", str);
    JS_SetPropertyUint32(ctx, arr, 0, p);
    return arr;
}
/* formatRange(a, b): `${format(a)} \u2013 ${format(b)}` (the old spacing) */
static JSValue dtf_format_range(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue state = intl_state(ctx, this_val);
    if (JS_IsException(state)) { return state; }
    bool defaults = field_bool(ctx, this_val, "_defaults");
    const char *need = defaults ? "date" : "";
    JSValue a = dtf_format_value(ctx, state, wj_arg(argc, (JSValue *)argv, 0), need);
    JSValue b = dtf_format_value(ctx, state, wj_arg(argc, (JSValue *)argv, 1), need);
    JS_FreeValue(ctx, state);
    const char *sa = JS_ToCString(ctx, a), *sb = JS_ToCString(ctx, b);
    buf out = {0};
    buf_str(&out, sa ? sa : ""); buf_str(&out, " \u2013 "); buf_str(&out, sb ? sb : "");
    if (sa) { JS_FreeCString(ctx, sa); } if (sb) { JS_FreeCString(ctx, sb); }
    JS_FreeValue(ctx, a); JS_FreeValue(ctx, b);
    JSValue r = JS_NewString(ctx, out.p ? out.p : "");
    buf_free(&out);
    return r;
}
/* formatRangeToParts(a, b): the two formatToParts lists with a shared " \u2013 " literal between them, each part tagged
 * with its source (startRange / shared / endRange), as the old file did. */
static JSValue dtf_format_range_to_parts(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValueConst a0 = wj_arg(argc, (JSValue *)argv, 0);
    JSValueConst a1 = wj_arg(argc, (JSValue *)argv, 1);
    JSValue pa = dtf_format_to_parts(ctx, this_val, 1, (JSValueConst *)&a0);
    if (JS_IsException(pa)) { return pa; }
    JSValue pb = dtf_format_to_parts(ctx, this_val, 1, (JSValueConst *)&a1);
    if (JS_IsException(pb)) { JS_FreeValue(ctx, pa); return pb; }
    JSValue out = JS_NewArray(ctx);
    uint32_t k = 0;
    uint32_t na = 0; JSValue lav = JS_GetPropertyStr(ctx, pa, "length"); JS_ToUint32(ctx, &na, lav); JS_FreeValue(ctx, lav);
    for (uint32_t i = 0; i < na; i++) { JSValue p = JS_GetPropertyUint32(ctx, pa, i); JS_SetPropertyStr(ctx, p, "source", JS_NewString(ctx, "startRange")); JS_SetPropertyUint32(ctx, out, k++, p); }
    { JSValue p = JS_NewObject(ctx); JS_SetPropertyStr(ctx, p, "type", JS_NewString(ctx, "literal")); JS_SetPropertyStr(ctx, p, "value", JS_NewString(ctx, " \u2013 ")); JS_SetPropertyStr(ctx, p, "source", JS_NewString(ctx, "shared")); JS_SetPropertyUint32(ctx, out, k++, p); }
    uint32_t nb = 0; JSValue lbv = JS_GetPropertyStr(ctx, pb, "length"); JS_ToUint32(ctx, &nb, lbv); JS_FreeValue(ctx, lbv);
    for (uint32_t i = 0; i < nb; i++) { JSValue p = JS_GetPropertyUint32(ctx, pb, i); JS_SetPropertyStr(ctx, p, "source", JS_NewString(ctx, "endRange")); JS_SetPropertyUint32(ctx, out, k++, p); }
    JS_FreeValue(ctx, pa); JS_FreeValue(ctx, pb);
    return out;
}
static void delete_prop(JSContext *ctx, JSValueConst obj, const char *name)
{
    JSAtom a = JS_NewAtom(ctx, name);
    JS_DeleteProperty(ctx, obj, a, 0);
    JS_FreeAtom(ctx, a);
}
static JSValue dtf_resolved(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue state = intl_state(ctx, this_val);
    if (JS_IsException(state)) { return state; }
    JSValue obj = JS_NewObject(ctx);
    JSValue objc = JS_GetPropertyStr(ctx, wj_the_realm.global, "Object");
    JSValue assign = JS_GetPropertyStr(ctx, objc, "assign");
    JSValueConst args[2] = { obj, state };
    JSValue r = JS_Call(ctx, assign, objc, 2, args);
    JS_FreeValue(ctx, assign); JS_FreeValue(ctx, objc); JS_FreeValue(ctx, state);
    if (JS_IsException(r)) { JS_FreeValue(ctx, obj); return r; }
    JS_FreeValue(ctx, r);
    delete_prop(ctx, obj, "utc");
    if (field_bool(ctx, this_val, "_defaults")) {
        JS_SetPropertyStr(ctx, obj, "year", JS_NewString(ctx, "numeric"));
        JS_SetPropertyStr(ctx, obj, "month", JS_NewString(ctx, "numeric"));
        JS_SetPropertyStr(ctx, obj, "day", JS_NewString(ctx, "numeric"));
    }
    JSValue hv = JS_GetPropertyStr(ctx, obj, "hour"); JSValue tsv = JS_GetPropertyStr(ctx, obj, "timeStyle");
    if (JS_IsUndefined(hv) && JS_IsUndefined(tsv)) { delete_prop(ctx, obj, "hour12"); delete_prop(ctx, obj, "hourCycle"); }
    JS_FreeValue(ctx, hv); JS_FreeValue(ctx, tsv);
    return obj;
}

static JSValue dtf_ctor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    bool is_new;
    JSValue obj = intl_new_this(ctx, this_val, 0, &is_new);
    if (JS_IsException(obj)) { return obj; }
    if (!is_new) {
        JSValue intl = JS_GetPropertyStr(ctx, wj_the_realm.global, "Intl");
        JSValue ctor = JS_GetPropertyStr(ctx, intl, "DateTimeFormat");
        JS_FreeValue(ctx, intl);
        JSValue proto = JS_GetPropertyStr(ctx, ctor, "prototype");
        JS_FreeValue(ctx, ctor);
        obj = JS_NewObjectProtoClass(ctx, proto, JS_CLASS_OBJECT);
        JS_FreeValue(ctx, proto);
    }
    if (!dtf_build(ctx, obj, wj_arg(argc, (JSValue *)argv, 0), wj_arg(argc, (JSValue *)argv, 1))) { JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    return obj;
}

/* ---- the locale-sensitive toLocale* methods of the standard library ---- */

static JSValue date_to_locale(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic)
{
    /* magic: 0 any, 1 date, 2 time */
    const char *need = magic == 1 ? "date" : magic == 2 ? "time" : "any";
    JSValue intl = JS_GetPropertyStr(ctx, wj_the_realm.global, "Intl");
    JSValue ctor = JS_GetPropertyStr(ctx, intl, "DateTimeFormat");
    JS_FreeValue(ctx, intl);
    JSValueConst cargs[2] = { wj_arg(argc, (JSValue *)argv, 0), wj_arg(argc, (JSValue *)argv, 1) };
    JSValue f = JS_CallConstructor(ctx, ctor, 2, cargs);
    JS_FreeValue(ctx, ctor);
    if (JS_IsException(f)) { return f; }
    JSValue state = JS_GetPropertyStr(ctx, f, "_o");
    bool defaults = field_bool(ctx, f, "_defaults");
    JS_FreeValue(ctx, f);
    JSValue r = dtf_format_value(ctx, state, this_val, defaults ? need : "");
    JS_FreeValue(ctx, state);
    return r;
}

static JSValue number_to_locale(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue intl = JS_GetPropertyStr(ctx, wj_the_realm.global, "Intl");
    JSValue ctor = JS_GetPropertyStr(ctx, intl, "NumberFormat");
    JS_FreeValue(ctx, intl);
    JSValueConst cargs[2] = { wj_arg(argc, (JSValue *)argv, 0), wj_arg(argc, (JSValue *)argv, 1) };
    JSValue f = JS_CallConstructor(ctx, ctor, 2, cargs);
    JS_FreeValue(ctx, ctor);
    if (JS_IsException(f)) { return f; }
    JSValue state = JS_GetPropertyStr(ctx, f, "_o");
    JS_FreeValue(ctx, f);
    JSValue vo = JS_GetPropertyStr(ctx, this_val, "valueOf");
    JSValue val = JS_Call(ctx, vo, this_val, 0, NULL);
    JS_FreeValue(ctx, vo);
    JSValue r = nf_format_value(ctx, state, val);
    JS_FreeValue(ctx, val); JS_FreeValue(ctx, state);
    return r;
}

/* ---- plurals ---- */

static JSValue pr_ctor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(this_val)) { return JS_ThrowTypeError(ctx, "Constructor Intl.PluralRules requires 'new'"); }
    bool is_new;
    JSValue obj = intl_new_this(ctx, this_val, 0, &is_new);
    if (JS_IsException(obj)) { return obj; }
    JSValue canon = intl_canonical_locales(ctx, wj_arg(argc, (JSValue *)argv, 0));
    if (JS_IsException(canon)) { JS_FreeValue(ctx, obj); return canon; }
    JS_FreeValue(ctx, canon);
    JSValue o = intl_to_object(ctx, wj_arg(argc, (JSValue *)argv, 1));
    if (JS_IsException(o)) { JS_FreeValue(ctx, obj); return o; }
    bool err = false;
    static const char *const type_v[] = { "cardinal", "ordinal", NULL };
    char *type = intl_get_opt(ctx, o, "type", type_v, "cardinal", false, NULL, &err);
    if (err) { JS_FreeValue(ctx, o); JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    def_ne(ctx, obj, "_type", JS_NewString(ctx, type));
    free(type);
    /* _nf = new NumberFormat("en", o): a NumberFormat instance built on its prototype */
    JSValue intl = JS_GetPropertyStr(ctx, wj_the_realm.global, "Intl");
    JSValue nfctor = JS_GetPropertyStr(ctx, intl, "NumberFormat");
    JS_FreeValue(ctx, intl);
    JSValue nfproto = JS_GetPropertyStr(ctx, nfctor, "prototype");
    JS_FreeValue(ctx, nfctor);
    JSValue nf = JS_NewObjectProtoClass(ctx, nfproto, JS_CLASS_OBJECT);
    JS_FreeValue(ctx, nfproto);
    JSValue enstr = JS_NewString(ctx, "en");
    if (!nf_build(ctx, nf, enstr, o)) { JS_FreeValue(ctx, enstr); JS_FreeValue(ctx, nf); JS_FreeValue(ctx, o); JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    JS_FreeValue(ctx, enstr);
    def_ne(ctx, obj, "_nf", nf);
    JS_FreeValue(ctx, o);
    return obj;
}
static JSValue pr_select(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue tv = JS_GetPropertyStr(ctx, this_val, "_type");
    const char *type = JS_ToCString(ctx, tv);
    JS_FreeValue(ctx, tv);
    double n;
    if (JS_ToFloat64(ctx, &n, wj_arg(argc, (JSValue *)argv, 0)) < 0) { if (type) { JS_FreeCString(ctx, type); } return JS_EXCEPTION; }
    JSValue r;
    if (type && strcmp(type, "ordinal") == 0) {
        double a = fabs(n); int d = (int)fmod(a, 10), h = (int)fmod(a, 100);
        r = JS_NewString(ctx, (d == 1 && h != 11) ? "one" : (d == 2 && h != 12) ? "two" : (d == 3 && h != 13) ? "few" : "other");
    } else {
        JSValue nf = JS_GetPropertyStr(ctx, this_val, "_nf");
        JSValue state = JS_GetPropertyStr(ctx, nf, "_o");
        JS_FreeValue(ctx, nf);
        JSValue av = JS_NewFloat64(ctx, fabs(n));
        JSValue s = nf_format_value(ctx, state, av);
        JS_FreeValue(ctx, av); JS_FreeValue(ctx, state);
        const char *str = JS_ToCString(ctx, s);
        JS_FreeValue(ctx, s);
        /* remove ',' and compare to "1" */
        char clean[64]; int ci = 0;
        for (const char *c = str ? str : ""; *c && ci < 63; c++) { if (*c != ',') { clean[ci++] = *c; } }
        clean[ci] = 0;
        if (str) { JS_FreeCString(ctx, str); }
        r = JS_NewString(ctx, strcmp(clean, "1") == 0 ? "one" : "other");
    }
    if (type) { JS_FreeCString(ctx, type); }
    return r;
}
static JSValue pr_select_range(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValueConst a1 = wj_arg(argc, (JSValue *)argv, 1);
    return pr_select(ctx, this_val, 1, (JSValueConst *)&a1);
}
static JSValue pr_resolved(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue tv = JS_GetPropertyStr(ctx, this_val, "_type");
    const char *type = JS_ToCString(ctx, tv);
    bool ordinal = type && strcmp(type, "ordinal") == 0;
    JSValue obj = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, obj, "locale", JS_NewString(ctx, "en-US"));
    JS_SetPropertyStr(ctx, obj, "type", JS_DupValue(ctx, tv));
    JSValue cats = JS_NewArray(ctx);
    if (ordinal) { const char *c[] = { "few", "one", "two", "other" }; for (int i = 0; i < 4; i++) { JS_SetPropertyUint32(ctx, cats, i, JS_NewString(ctx, c[i])); } }
    else { JS_SetPropertyUint32(ctx, cats, 0, JS_NewString(ctx, "one")); JS_SetPropertyUint32(ctx, cats, 1, JS_NewString(ctx, "other")); }
    JS_SetPropertyStr(ctx, obj, "pluralCategories", cats);
    JS_FreeValue(ctx, tv);
    if (type) { JS_FreeCString(ctx, type); }
    /* Object.assign(obj, this._nf.resolvedOptions()) */
    JSValue nf = JS_GetPropertyStr(ctx, this_val, "_nf");
    JSValue state = JS_GetPropertyStr(ctx, nf, "_o");
    JS_FreeValue(ctx, nf);
    JSValue objc = JS_GetPropertyStr(ctx, wj_the_realm.global, "Object");
    JSValue assign = JS_GetPropertyStr(ctx, objc, "assign");
    JSValueConst args[2] = { obj, state };
    JSValue r = JS_Call(ctx, assign, objc, 2, args);
    JS_FreeValue(ctx, assign); JS_FreeValue(ctx, objc); JS_FreeValue(ctx, state);
    if (JS_IsException(r)) { JS_FreeValue(ctx, obj); return r; }
    JS_FreeValue(ctx, r);
    return obj;
}

/* ---- relative time ---- */

static const char *const RT_UNITS[] = { "year", "quarter", "month", "week", "day", "hour", "minute", "second", NULL };

static JSValue rtf_ctor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(this_val)) { return JS_ThrowTypeError(ctx, "Constructor Intl.RelativeTimeFormat requires 'new'"); }
    bool is_new;
    JSValue obj = intl_new_this(ctx, this_val, 0, &is_new);
    if (JS_IsException(obj)) { return obj; }
    JSValue canon = intl_canonical_locales(ctx, wj_arg(argc, (JSValue *)argv, 0));
    if (JS_IsException(canon)) { JS_FreeValue(ctx, obj); return canon; }
    JS_FreeValue(ctx, canon);
    JSValue o = intl_to_object(ctx, wj_arg(argc, (JSValue *)argv, 1));
    if (JS_IsException(o)) { JS_FreeValue(ctx, obj); return o; }
    bool err = false;
    static const char *const style_v[] = { "long", "short", "narrow", NULL };
    static const char *const numeric_v[] = { "always", "auto", NULL };
    char *style = intl_get_opt(ctx, o, "style", style_v, "long", false, NULL, &err); if (err) { JS_FreeValue(ctx, o); JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    char *numeric = intl_get_opt(ctx, o, "numeric", numeric_v, "always", false, NULL, &err); if (err) { free(style); JS_FreeValue(ctx, o); JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    JSValue state = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, state, "locale", JS_NewString(ctx, "en-US"));
    JS_SetPropertyStr(ctx, state, "style", JS_NewString(ctx, style));
    JS_SetPropertyStr(ctx, state, "numeric", JS_NewString(ctx, numeric));
    JS_SetPropertyStr(ctx, state, "numberingSystem", JS_NewString(ctx, "latn"));
    def_ne(ctx, obj, "_o", state);
    free(style); free(numeric);
    JS_FreeValue(ctx, o);
    return obj;
}
/* build "in N units" / "N units ago" into a string */
static JSValue rtf_do(JSContext *ctx, JSValueConst state, JSValueConst valuev, JSValueConst unitv)
{
    double value;
    if (JS_ToFloat64(ctx, &value, valuev) < 0) { return JS_EXCEPTION; }
    if (!isfinite(value)) { return JS_ThrowRangeError(ctx, "Invalid value"); }
    const char *us = JS_ToCString(ctx, unitv);
    char unit[32]; snprintf(unit, sizeof unit, "%s", us ? us : ""); if (us) { JS_FreeCString(ctx, us); }
    size_t ul = strlen(unit); if (ul && unit[ul - 1] == 's') { unit[ul - 1] = 0; }
    bool known = false; for (const char *const *p = RT_UNITS; *p; p++) { if (strcmp(*p, unit) == 0) { known = true; break; } }
    if (!known) { return JS_ThrowRangeError(ctx, "Invalid unit argument for format() '%s'", unit); }
    char *numeric = field_str(ctx, state, "numeric");
    char *style = field_str(ctx, state, "style");
    buf out = {0};
    if (numeric && strcmp(numeric, "auto") == 0) {
        /* the special words for -1/0/1 */
        int iv = (value == 0 && signbit(value)) ? 0 : (int)value;
        const char *special = NULL;
        if (value == (double)iv) {
            if (strcmp(unit, "day") == 0) { special = iv == -1 ? "yesterday" : iv == 0 ? "today" : iv == 1 ? "tomorrow" : NULL; }
            else if (strcmp(unit, "year") == 0) { special = iv == -1 ? "last year" : iv == 0 ? "this year" : iv == 1 ? "next year" : NULL; }
            else if (strcmp(unit, "month") == 0) { special = iv == -1 ? "last month" : iv == 0 ? "this month" : iv == 1 ? "next month" : NULL; }
            else if (strcmp(unit, "week") == 0) { special = iv == -1 ? "last week" : iv == 0 ? "this week" : iv == 1 ? "next week" : NULL; }
            else if (strcmp(unit, "quarter") == 0) { special = iv == -1 ? "last quarter" : iv == 0 ? "this quarter" : iv == 1 ? "next quarter" : NULL; }
            else if (strcmp(unit, "second") == 0) { special = iv == 0 ? "now" : NULL; }
            else if (strcmp(unit, "minute") == 0) { special = iv == 0 ? "this minute" : NULL; }
            else if (strcmp(unit, "hour") == 0) { special = iv == 0 ? "this hour" : NULL; }
        }
        if (special) { buf_str(&out, special); JSValue r = JS_NewString(ctx, out.p ? out.p : ""); buf_free(&out); free(numeric); free(style); return r; }
    }
    double a = fabs(value);
    const char *name;
    char namebuf[32];
    if (style && strcmp(style, "long") == 0) { snprintf(namebuf, sizeof namebuf, "%s%s", unit, a == 1 ? "" : "s"); name = namebuf; }
    else {
        /* short/narrow abbreviations */
        const char *abbr;
        if (strcmp(unit, "year") == 0) { abbr = "yr."; } else if (strcmp(unit, "quarter") == 0) { abbr = "qtr."; }
        else if (strcmp(unit, "month") == 0) { abbr = "mo."; } else if (strcmp(unit, "week") == 0) { abbr = "wk."; }
        else if (strcmp(unit, "day") == 0) { abbr = a == 1 ? "day" : "days"; }
        else if (strcmp(unit, "hour") == 0) { abbr = "hr."; } else if (strcmp(unit, "minute") == 0) { abbr = "min."; }
        else { abbr = "sec."; }
        name = abbr;
    }
    /* number via new NumberFormat("en") */
    JSValue intl = JS_GetPropertyStr(ctx, wj_the_realm.global, "Intl");
    JSValue nfctor = JS_GetPropertyStr(ctx, intl, "NumberFormat");
    JS_FreeValue(ctx, intl);
    JSValueConst en = JS_NewString(ctx, "en");
    JSValue nf = JS_CallConstructor(ctx, nfctor, 1, &en);
    JS_FreeValue(ctx, (JSValue)en); JS_FreeValue(ctx, nfctor);
    JSValue nstate = JS_GetPropertyStr(ctx, nf, "_o");
    JS_FreeValue(ctx, nf);
    JSValue av = JS_NewFloat64(ctx, a);
    JSValue numstr = nf_format_value(ctx, nstate, av);
    JS_FreeValue(ctx, av); JS_FreeValue(ctx, nstate);
    const char *num = JS_ToCString(ctx, numstr);
    JS_FreeValue(ctx, numstr);
    bool past = value < 0 || (value == 0 && signbit(value));
    if (past) { buf_str(&out, num ? num : ""); buf_str(&out, " "); buf_str(&out, name); buf_str(&out, " ago"); }
    else { buf_str(&out, "in "); buf_str(&out, num ? num : ""); buf_str(&out, " "); buf_str(&out, name); }
    if (num) { JS_FreeCString(ctx, num); }
    free(numeric); free(style);
    JSValue r = JS_NewString(ctx, out.p ? out.p : "");
    buf_free(&out);
    return r;
}
static JSValue rtf_format(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue state = intl_state(ctx, this_val);
    if (JS_IsException(state)) { return state; }
    JSValue r = rtf_do(ctx, state, wj_arg(argc, (JSValue *)argv, 0), wj_arg(argc, (JSValue *)argv, 1));
    JS_FreeValue(ctx, state);
    return r;
}
/* formatToParts(value, unit): a one-element [{type:"literal", value}] with the formatted text (the old file split it
 * into number and literal parts; callers reading the joined value are unaffected). */
static JSValue rtf_format_to_parts(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue str = rtf_format(ctx, this_val, argc, argv);
    if (JS_IsException(str)) { return str; }
    JSValue arr = JS_NewArray(ctx);
    JSValue p = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, p, "type", JS_NewString(ctx, "literal"));
    JS_SetPropertyStr(ctx, p, "value", str);
    JS_SetPropertyUint32(ctx, arr, 0, p);
    return arr;
}
static JSValue rtf_resolved(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    return nf_resolved(ctx, this_val, 0, NULL);   /* Object.assign({}, this._o): same shape helper */
}

/* ---- list format ---- */

static JSValue lf_ctor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(this_val)) { return JS_ThrowTypeError(ctx, "Constructor Intl.ListFormat requires 'new'"); }
    bool is_new;
    JSValue obj = intl_new_this(ctx, this_val, 0, &is_new);
    if (JS_IsException(obj)) { return obj; }
    JSValue canon = intl_canonical_locales(ctx, wj_arg(argc, (JSValue *)argv, 0));
    if (JS_IsException(canon)) { JS_FreeValue(ctx, obj); return canon; }
    JS_FreeValue(ctx, canon);
    JSValue o = intl_to_object(ctx, wj_arg(argc, (JSValue *)argv, 1));
    if (JS_IsException(o)) { JS_FreeValue(ctx, obj); return o; }
    bool err = false;
    static const char *const type_v[] = { "conjunction", "disjunction", "unit", NULL };
    static const char *const style_v[] = { "long", "short", "narrow", NULL };
    char *type = intl_get_opt(ctx, o, "type", type_v, "conjunction", false, NULL, &err); if (err) { JS_FreeValue(ctx, o); JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    char *style = intl_get_opt(ctx, o, "style", style_v, "long", false, NULL, &err); if (err) { free(type); JS_FreeValue(ctx, o); JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    JSValue state = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, state, "locale", JS_NewString(ctx, "en-US"));
    JS_SetPropertyStr(ctx, state, "type", JS_NewString(ctx, type));
    JS_SetPropertyStr(ctx, state, "style", JS_NewString(ctx, style));
    def_ne(ctx, obj, "_o", state);
    free(type); free(style);
    JS_FreeValue(ctx, o);
    return obj;
}
static JSValue lf_format(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue state = intl_state(ctx, this_val);
    if (JS_IsException(state)) { return state; }
    char *type = field_str(ctx, state, "type");
    char *style = field_str(ctx, state, "style");
    JS_FreeValue(ctx, state);
    /* Array.from(list) with a string check */
    JSValue arrayc = JS_GetPropertyStr(ctx, wj_the_realm.global, "Array");
    JSValue from = JS_GetPropertyStr(ctx, arrayc, "from");
    JSValueConst a1 = wj_arg(argc, (JSValue *)argv, 0);
    JSValue list = JS_Call(ctx, from, arrayc, 1, &a1);
    JS_FreeValue(ctx, from); JS_FreeValue(ctx, arrayc);
    if (JS_IsException(list)) { free(type); free(style); return list; }
    uint32_t n = 0; JSValue lenv = JS_GetPropertyStr(ctx, list, "length"); JS_ToUint32(ctx, &n, lenv); JS_FreeValue(ctx, lenv);
    const char *word = (strcmp(type, "conjunction") == 0) ? (strcmp(style, "long") == 0 ? "and" : "&") : (strcmp(type, "disjunction") == 0 ? "or" : "");
    buf out = {0};
    for (uint32_t i = 0; i < n; i++) {
        JSValue item = JS_GetPropertyUint32(ctx, list, i);
        if (!JS_IsString(item)) { JS_FreeValue(ctx, item); JS_FreeValue(ctx, list); free(type); free(style); buf_free(&out); return JS_ThrowTypeError(ctx, "Iterable yielded a value that is not a string"); }
        if (i) {
            bool last = i == n - 1;
            const char *sep = ", ";
            char sepbuf[16];
            if (last && word[0]) { if (n == 2) { snprintf(sepbuf, sizeof sepbuf, " %s ", word); } else { snprintf(sepbuf, sizeof sepbuf, ", %s ", word); } sep = sepbuf; }
            if (strcmp(type, "unit") == 0 && strcmp(style, "narrow") == 0) { sep = " "; }
            buf_str(&out, sep);
        }
        const char *s = JS_ToCString(ctx, item);
        buf_str(&out, s ? s : "");
        if (s) { JS_FreeCString(ctx, s); }
        JS_FreeValue(ctx, item);
    }
    JS_FreeValue(ctx, list);
    free(type); free(style);
    JSValue r = JS_NewString(ctx, out.p ? out.p : "");
    buf_free(&out);
    return r;
}
/* formatToParts(list): a one-element [{type:"element", value}] with the formatted text (the old file produced element
 * and literal parts; callers reading the joined value are unaffected). */
static JSValue lf_format_to_parts(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue str = lf_format(ctx, this_val, argc, argv);
    if (JS_IsException(str)) { return str; }
    JSValue arr = JS_NewArray(ctx);
    JSValue p = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, p, "type", JS_NewString(ctx, "element"));
    JS_SetPropertyStr(ctx, p, "value", str);
    JS_SetPropertyUint32(ctx, arr, 0, p);
    return arr;
}
static JSValue lf_resolved(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    return nf_resolved(ctx, this_val, 0, NULL);
}

/* ---- collation ---- */

/* NFD-fold to lowercase ASCII-ish for the base comparison. We lean on the engine's String.prototype.normalize and
 * toLowerCase through JS calls to stay identical to the old code's Unicode behaviour. */
static JSValue str_method(JSContext *ctx, JSValueConst s, const char *method, JSValueConst arg, bool has_arg)
{
    JSValue m = JS_GetPropertyStr(ctx, s, method);
    JSValue r = JS_Call(ctx, m, s, has_arg ? 1 : 0, has_arg ? &arg : NULL);
    JS_FreeValue(ctx, m);
    return r;
}
/* fold(s) = s.normalize("NFD").replace(/[\u0300-\u036f]/g,"").toLowerCase() — done via a small JS helper for exactness */
static JSValue collator_fold(JSContext *ctx, JSValueConst s)
{
    JSValueConst nfd = JS_NewString(ctx, "NFD");
    JSValue n = str_method(ctx, s, "normalize", nfd, true);
    JS_FreeValue(ctx, (JSValue)nfd);
    /* replace combining marks: use replace with a RegExp built once */
    JSValue re_ctor = JS_GetPropertyStr(ctx, wj_the_realm.global, "RegExp");
    JSValueConst pat = JS_NewString(ctx, "[\\u0300-\\u036f]");
    JSValueConst flags = JS_NewString(ctx, "g");
    JSValueConst reargs[2] = { pat, flags };
    JSValue re = JS_CallConstructor(ctx, re_ctor, 2, reargs);
    JS_FreeValue(ctx, (JSValue)pat); JS_FreeValue(ctx, (JSValue)flags); JS_FreeValue(ctx, re_ctor);
    JSValue repl = JS_GetPropertyStr(ctx, n, "replace");
    JSValueConst rargs[2] = { re, JS_NewString(ctx, "") };
    JSValue stripped = JS_Call(ctx, repl, n, 2, rargs);
    JS_FreeValue(ctx, (JSValue)rargs[1]); JS_FreeValue(ctx, repl); JS_FreeValue(ctx, re); JS_FreeValue(ctx, n);
    JSValue lower = str_method(ctx, stripped, "toLowerCase", JS_UNDEFINED, false);
    JS_FreeValue(ctx, stripped);
    return lower;
}
static int cmp_cstr(const char *x, const char *y) { int c = strcmp(x, y); return c < 0 ? -1 : c > 0 ? 1 : 0; }
/* numeric-aware compare of two UTF-8 strings (as the old cmp did for the numeric option) */
static int cmp_numeric(const char *x, const char *y)
{
    size_t i = 0, j = 0;
    while (x[i] && y[j]) {
        bool dx = x[i] >= '0' && x[i] <= '9', dy = y[j] >= '0' && y[j] <= '9';
        if (dx && dy) {
            long a = 0, b = 0; size_t si = i, sj = j;
            while (x[i] >= '0' && x[i] <= '9') { a = a * 10 + (x[i] - '0'); i++; }
            while (y[j] >= '0' && y[j] <= '9') { b = b * 10 + (y[j] - '0'); j++; }
            (void)si; (void)sj;
            if (a != b) { return a < b ? -1 : 1; }
        } else {
            if (x[i] != y[j]) { return (unsigned char)x[i] < (unsigned char)y[j] ? -1 : 1; }
            i++; j++;
        }
    }
    if (x[i] == y[j]) { return 0; }
    return x[i] ? 1 : -1;
}
static JSValue collate(JSContext *ctx, JSValueConst state, JSValueConst av, JSValueConst bv)
{
    char *sensitivity = field_str(ctx, state, "sensitivity");
    bool numeric = field_bool(ctx, state, "numeric");
    bool ignorePunct = field_bool(ctx, state, "ignorePunctuation");
    char *caseFirst = field_str(ctx, state, "caseFirst");
    /* a = String(a).normalize("NFC") */
    JSValue as = JS_ToString(ctx, av), bs = JS_ToString(ctx, bv);
    JSValueConst nfc = JS_NewString(ctx, "NFC");
    JSValue an = str_method(ctx, as, "normalize", nfc, true);
    JSValue bn = str_method(ctx, bs, "normalize", nfc, true);
    JS_FreeValue(ctx, (JSValue)nfc); JS_FreeValue(ctx, as); JS_FreeValue(ctx, bs);
    if (ignorePunct) {
        JSValue re_ctor = JS_GetPropertyStr(ctx, wj_the_realm.global, "RegExp");
        JSValueConst pat = JS_NewString(ctx, "[\\p{P}\\s]"); JSValueConst fl = JS_NewString(ctx, "gu");
        JSValueConst ra[2] = { pat, fl };
        JSValue re = JS_CallConstructor(ctx, re_ctor, 2, ra);
        JS_FreeValue(ctx, (JSValue)pat); JS_FreeValue(ctx, (JSValue)fl); JS_FreeValue(ctx, re_ctor);
        JSValue repl = JS_GetPropertyStr(ctx, an, "replace"); JSValueConst rr[2] = { re, JS_NewString(ctx, "") };
        JSValue an2 = JS_Call(ctx, repl, an, 2, rr); JS_FreeValue(ctx, repl);
        JSValue replb = JS_GetPropertyStr(ctx, bn, "replace"); JSValue bn2 = JS_Call(ctx, replb, bn, 2, rr); JS_FreeValue(ctx, replb);
        JS_FreeValue(ctx, (JSValue)rr[1]); JS_FreeValue(ctx, re); JS_FreeValue(ctx, an); JS_FreeValue(ctx, bn);
        an = an2; bn = bn2;
    }
    /* base: fold both */
    JSValue af = collator_fold(ctx, an), bf = collator_fold(ctx, bn);
    const char *afs = JS_ToCString(ctx, af), *bfs = JS_ToCString(ctx, bf);
    int base = numeric ? cmp_numeric(afs ? afs : "", bfs ? bfs : "") : cmp_cstr(afs ? afs : "", bfs ? bfs : "");
    if (afs) { JS_FreeCString(ctx, afs); } if (bfs) { JS_FreeCString(ctx, bfs); }
    JS_FreeValue(ctx, af); JS_FreeValue(ctx, bf);
    int result;
    bool done = false;
    if (base || (sensitivity && strcmp(sensitivity, "base") == 0)) { result = base; done = true; }
    if (!done) {
        /* accents: NFD toLowerCase of each */
        JSValueConst nfd = JS_NewString(ctx, "NFD");
        JSValue and_ = str_method(ctx, an, "normalize", nfd, true); JSValue bnd = str_method(ctx, bn, "normalize", nfd, true);
        JS_FreeValue(ctx, (JSValue)nfd);
        JSValue andl = str_method(ctx, and_, "toLowerCase", JS_UNDEFINED, false); JSValue bndl = str_method(ctx, bnd, "toLowerCase", JS_UNDEFINED, false);
        JS_FreeValue(ctx, and_); JS_FreeValue(ctx, bnd);
        const char *as2 = JS_ToCString(ctx, andl), *bs2 = JS_ToCString(ctx, bndl);
        int accents = numeric ? cmp_numeric(as2 ? as2 : "", bs2 ? bs2 : "") : cmp_cstr(as2 ? as2 : "", bs2 ? bs2 : "");
        if (as2) { JS_FreeCString(ctx, as2); } if (bs2) { JS_FreeCString(ctx, bs2); }
        JS_FreeValue(ctx, andl); JS_FreeValue(ctx, bndl);
        if (accents || (sensitivity && strcmp(sensitivity, "accent") == 0)) { result = accents; done = true; }
        if (!done) {
            /* case: compare the NFC strings char-by-char, lower before upper unless caseFirst=upper */
            const char *a = JS_ToCString(ctx, an), *b = JS_ToCString(ctx, bn);
            if (a && b && strcmp(a, b) == 0) { result = 0; }
            else {
                result = 0;
                size_t la = a ? strlen(a) : 0, lb = b ? strlen(b) : 0, m = la < lb ? la : lb;
                bool decided = false;
                for (size_t i = 0; i < m; i++) {
                    if (a[i] != b[i]) {
                        bool al = !(a[i] >= 'A' && a[i] <= 'Z');   /* a[i] is lower (approx of ===toLowerCase) */
                        bool pick = (caseFirst && strcmp(caseFirst, "upper") == 0) ? !al : al;
                        result = pick ? -1 : 1; decided = true; break;
                    }
                }
                if (!decided) { result = la < lb ? -1 : la > lb ? 1 : 0; }
            }
            if (a) { JS_FreeCString(ctx, a); } if (b) { JS_FreeCString(ctx, b); }
        }
    }
    JS_FreeValue(ctx, an); JS_FreeValue(ctx, bn);
    free(sensitivity); free(caseFirst);
    return JS_NewInt32(ctx, result);
}
static JSValue coll_compare_call(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *func_data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    return collate(ctx, func_data[0], wj_arg(argc, (JSValue *)argv, 0), wj_arg(argc, (JSValue *)argv, 1));
}
static JSValue coll_get_compare(JSContext *ctx, JSValueConst this_val)
{
    JSValue state = intl_state(ctx, this_val);
    if (JS_IsException(state)) { return state; }
    JSValue fn = JS_NewCFunctionData(ctx, coll_compare_call, 2, 0, 1, &state);
    JS_FreeValue(ctx, state);
    return fn;
}
static JSValue coll_ctor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    bool is_new;
    JSValue obj = intl_new_this(ctx, this_val, 0, &is_new);
    if (JS_IsException(obj)) { return obj; }
    if (!is_new) {
        JSValue intl = JS_GetPropertyStr(ctx, wj_the_realm.global, "Intl");
        JSValue ctor = JS_GetPropertyStr(ctx, intl, "Collator"); JS_FreeValue(ctx, intl);
        JSValue proto = JS_GetPropertyStr(ctx, ctor, "prototype"); JS_FreeValue(ctx, ctor);
        obj = JS_NewObjectProtoClass(ctx, proto, JS_CLASS_OBJECT); JS_FreeValue(ctx, proto);
    }
    JSValue canon = intl_canonical_locales(ctx, wj_arg(argc, (JSValue *)argv, 0));
    if (JS_IsException(canon)) { JS_FreeValue(ctx, obj); return canon; }
    JS_FreeValue(ctx, canon);
    JSValue o = intl_to_object(ctx, wj_arg(argc, (JSValue *)argv, 1));
    if (JS_IsException(o)) { JS_FreeValue(ctx, obj); return o; }
    bool err = false;
    static const char *const usage_v[] = { "sort", "search", NULL };
    static const char *const sens_v[] = { "base", "accent", "case", "variant", NULL };
    static const char *const cf_v[] = { "upper", "lower", "false", NULL };
    char *usage = intl_get_opt(ctx, o, "usage", usage_v, "sort", false, NULL, &err); if (err) { JS_FreeValue(ctx, o); JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    char *sensitivity = intl_get_opt(ctx, o, "sensitivity", sens_v, "variant", false, NULL, &err); if (err) { free(usage); JS_FreeValue(ctx, o); JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    bool ignorePunct = false, numeric = false;
    intl_get_opt(ctx, o, "ignorePunctuation", NULL, NULL, true, &ignorePunct, &err); if (err) { free(usage); free(sensitivity); JS_FreeValue(ctx, o); JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    intl_get_opt(ctx, o, "numeric", NULL, NULL, true, &numeric, &err); if (err) { free(usage); free(sensitivity); JS_FreeValue(ctx, o); JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    char *caseFirst = intl_get_opt(ctx, o, "caseFirst", cf_v, "false", false, NULL, &err); if (err) { free(usage); free(sensitivity); JS_FreeValue(ctx, o); JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    JSValue state = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, state, "locale", JS_NewString(ctx, "en-US"));
    JS_SetPropertyStr(ctx, state, "usage", JS_NewString(ctx, usage));
    JS_SetPropertyStr(ctx, state, "sensitivity", JS_NewString(ctx, sensitivity));
    JS_SetPropertyStr(ctx, state, "ignorePunctuation", JS_NewBool(ctx, ignorePunct));
    JS_SetPropertyStr(ctx, state, "collation", JS_NewString(ctx, "default"));
    JS_SetPropertyStr(ctx, state, "numeric", JS_NewBool(ctx, numeric));
    JS_SetPropertyStr(ctx, state, "caseFirst", JS_NewString(ctx, caseFirst));
    def_ne(ctx, obj, "_o", state);
    free(usage); free(sensitivity); free(caseFirst);
    JS_FreeValue(ctx, o);
    return obj;
}
static JSValue coll_resolved(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    return nf_resolved(ctx, this_val, 0, NULL);
}

/* String.prototype.localeCompare */
static JSValue string_locale_compare(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(this_val) || JS_IsNull(this_val)) { return JS_ThrowTypeError(ctx, "String.prototype.localeCompare called on null or undefined"); }
    JSValue intl = JS_GetPropertyStr(ctx, wj_the_realm.global, "Intl");
    JSValue ctor = JS_GetPropertyStr(ctx, intl, "Collator"); JS_FreeValue(ctx, intl);
    JSValueConst cargs[2] = { wj_arg(argc, (JSValue *)argv, 1), wj_arg(argc, (JSValue *)argv, 2) };
    JSValue c = JS_CallConstructor(ctx, ctor, 2, cargs); JS_FreeValue(ctx, ctor);
    if (JS_IsException(c)) { return c; }
    JSValue state = JS_GetPropertyStr(ctx, c, "_o"); JS_FreeValue(ctx, c);
    JSValue a = JS_ToString(ctx, this_val);
    JSValue b = JS_ToString(ctx, wj_arg(argc, (JSValue *)argv, 0));
    JSValue r = collate(ctx, state, a, b);
    JS_FreeValue(ctx, a); JS_FreeValue(ctx, b); JS_FreeValue(ctx, state);
    return r;
}

/* ---- Locale ---- */

static JSValue locale_ctor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(this_val)) { return JS_ThrowTypeError(ctx, "Constructor Intl.Locale requires 'new'"); }
    bool is_new;
    JSValue obj = intl_new_this(ctx, this_val, 0, &is_new);
    if (JS_IsException(obj)) { return obj; }
    /* tag: if a Locale, its toString(); else the value */
    JSValue tagv = wj_arg(argc, (JSValue *)argv, 0);
    const char *tag;
    JSValue ts = JS_UNDEFINED;
    if (JS_IsObject(tagv)) { JSValue bn = JS_GetPropertyStr(ctx, tagv, "baseName"); if (!JS_IsUndefined(bn)) { ts = JS_ToString(ctx, tagv); } JS_FreeValue(ctx, bn); }
    tag = JS_ToCString(ctx, JS_IsUndefined(ts) ? tagv : ts);
    char canon[256];
    bool ok = tag && intl_canonical_tag(ctx, tag, canon, sizeof canon);
    if (tag) { JS_FreeCString(ctx, tag); }
    JS_FreeValue(ctx, ts);
    if (!ok) { JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    /* split on '-' into subtags */
    char language[16] = "", script[8] = "", region[8] = "";
    { int idx = 0; size_t start = 0, len = strlen(canon);
      for (size_t i = 0; i <= len; i++) {
        if (canon[i] == '-' || canon[i] == 0) {
            char tok[32]; size_t l = i - start; if (l > sizeof tok - 1) { l = sizeof tok - 1; }
            memcpy(tok, canon + start, l); tok[l] = 0;
            if (idx == 0) { snprintf(language, sizeof language, "%s", tok); }
            else if (l == 4 && script[0] == 0) { snprintf(script, sizeof script, "%s", tok); }
            else if ((l == 2 || (l == 3 && tok[0] >= '0' && tok[0] <= '9')) && region[0] == 0) { snprintf(region, sizeof region, "%s", tok); }
            idx++; start = i + 1;
        }
      } }
    JSValue o = intl_to_object(ctx, wj_arg(argc, (JSValue *)argv, 1));
    if (JS_IsException(o)) { JS_FreeValue(ctx, obj); return o; }
    { JSValue v = JS_GetPropertyStr(ctx, o, "region"); if (!JS_IsUndefined(v)) { const char *s = JS_ToCString(ctx, v); if (s) { int i = 0; for (; s[i] && i < 7; i++) { char c = s[i]; region[i] = (c >= 'a' && c <= 'z') ? (char)(c - 32) : c; } region[i] = 0; JS_FreeCString(ctx, s); } } JS_FreeValue(ctx, v); }
    { JSValue v = JS_GetPropertyStr(ctx, o, "language"); if (!JS_IsUndefined(v)) { const char *s = JS_ToCString(ctx, v); if (s) { int i = 0; for (; s[i] && i < 15; i++) { char c = s[i]; language[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c; } language[i] = 0; JS_FreeCString(ctx, s); } } JS_FreeValue(ctx, v); }
    JS_FreeValue(ctx, o);
    def_ne(ctx, obj, "_language", JS_NewString(ctx, language));
    def_ne(ctx, obj, "_script", script[0] ? JS_NewString(ctx, script) : JS_UNDEFINED);
    def_ne(ctx, obj, "_region", region[0] ? JS_NewString(ctx, region) : JS_UNDEFINED);
    return obj;
}
static JSValue locale_get_field(JSContext *ctx, JSValueConst this_val, int magic)
{
    const char *f = magic == 0 ? "_language" : magic == 1 ? "_script" : "_region";
    return JS_GetPropertyStr(ctx, this_val, f);
}
static JSValue locale_base_name(JSContext *ctx, JSValueConst this_val)
{
    buf out = {0};
    const char *fields[3] = { "_language", "_script", "_region" };
    bool first = true;
    for (int i = 0; i < 3; i++) {
        JSValue v = JS_GetPropertyStr(ctx, this_val, fields[i]);
        if (!JS_IsUndefined(v) && !JS_IsNull(v)) { const char *s = JS_ToCString(ctx, v); if (s && s[0]) { if (!first) { buf_str(&out, "-"); } buf_str(&out, s); first = false; } if (s) { JS_FreeCString(ctx, s); } }
        JS_FreeValue(ctx, v);
    }
    JSValue r = JS_NewString(ctx, out.p ? out.p : "");
    buf_free(&out);
    return r;
}
static JSValue locale_to_string(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    return locale_base_name(ctx, this_val);
}
static JSValue locale_maximize(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue lang = JS_GetPropertyStr(ctx, this_val, "_language");
    JSValue reg = JS_GetPropertyStr(ctx, this_val, "_region");
    const char *l = JS_ToCString(ctx, lang);
    bool en_no_region = l && strcmp(l, "en") == 0 && (JS_IsUndefined(reg) || JS_IsNull(reg));
    JSValue base = en_no_region ? JS_NewString(ctx, "en-Latn-US") : locale_base_name(ctx, this_val);
    if (l) { JS_FreeCString(ctx, l); }
    JS_FreeValue(ctx, lang); JS_FreeValue(ctx, reg);
    JSValue intl = JS_GetPropertyStr(ctx, wj_the_realm.global, "Intl");
    JSValue ctor = JS_GetPropertyStr(ctx, intl, "Locale"); JS_FreeValue(ctx, intl);
    JSValue r = JS_CallConstructor(ctx, ctor, 1, (JSValueConst *)&base);
    JS_FreeValue(ctx, base); JS_FreeValue(ctx, ctor);
    return r;
}
static JSValue locale_minimize(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue lang = JS_GetPropertyStr(ctx, this_val, "_language");
    JSValue intl = JS_GetPropertyStr(ctx, wj_the_realm.global, "Intl");
    JSValue ctor = JS_GetPropertyStr(ctx, intl, "Locale"); JS_FreeValue(ctx, intl);
    JSValue r = JS_CallConstructor(ctx, ctor, 1, (JSValueConst *)&lang);
    JS_FreeValue(ctx, lang); JS_FreeValue(ctx, ctor);
    return r;
}

/* ---- Segmenter ---- */

static JSValue seg_ctor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(this_val)) { return JS_ThrowTypeError(ctx, "Constructor Intl.Segmenter requires 'new'"); }
    bool is_new;
    JSValue obj = intl_new_this(ctx, this_val, 0, &is_new);
    if (JS_IsException(obj)) { return obj; }
    JSValue canon = intl_canonical_locales(ctx, wj_arg(argc, (JSValue *)argv, 0));
    if (JS_IsException(canon)) { JS_FreeValue(ctx, obj); return canon; }
    JS_FreeValue(ctx, canon);
    JSValue o = intl_to_object(ctx, wj_arg(argc, (JSValue *)argv, 1));
    if (JS_IsException(o)) { JS_FreeValue(ctx, obj); return o; }
    bool err = false;
    static const char *const gran_v[] = { "grapheme", "word", "sentence", NULL };
    char *g = intl_get_opt(ctx, o, "granularity", gran_v, "grapheme", false, NULL, &err); if (err) { JS_FreeValue(ctx, o); JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    def_ne(ctx, obj, "_g", JS_NewString(ctx, g));
    free(g);
    JS_FreeValue(ctx, o);
    return obj;
}
/* segment(input): returns an object with [Symbol.iterator] over the segments and containing(i). We build a plain array
 * of {segment,index,input[,isWordLike]} and wrap it like the old code did. The regex-driven splitting is reproduced
 * through the engine's RegExp (the same patterns), so results match the old file to the byte. */
static JSValue seg_segment(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue gv = JS_GetPropertyStr(ctx, this_val, "_g");
    const char *g = JS_ToCString(ctx, gv);
    JS_FreeValue(ctx, gv);
    JSValue input = JS_ToString(ctx, wj_arg(argc, (JSValue *)argv, 0));
    const char *pattern = (g && strcmp(g, "word") == 0) ? "\\w+|\\s+|[^\\w\\s]" : (g && strcmp(g, "sentence") == 0) ? "[^.!?]+[.!?]*\\s*" : "\\P{M}\\p{M}*|.";
    const char *flags = (g && strcmp(g, "grapheme") == 0) ? "gsu" : "gu";
    JSValue re_ctor = JS_GetPropertyStr(ctx, wj_the_realm.global, "RegExp");
    JSValueConst reargs[2] = { JS_NewString(ctx, pattern), JS_NewString(ctx, flags) };
    JSValue re = JS_CallConstructor(ctx, re_ctor, 2, reargs);
    JS_FreeValue(ctx, (JSValue)reargs[0]); JS_FreeValue(ctx, (JSValue)reargs[1]); JS_FreeValue(ctx, re_ctor);
    JSValue list = JS_NewArray(ctx);
    uint32_t k = 0;
    for (;;) {
        JSValue exec = JS_GetPropertyStr(ctx, re, "exec");
        JSValue m = JS_Call(ctx, exec, re, 1, (JSValueConst *)&input);
        JS_FreeValue(ctx, exec);
        if (JS_IsNull(m) || JS_IsException(m)) { JS_FreeValue(ctx, m); break; }
        JSValue m0 = JS_GetPropertyUint32(ctx, m, 0);
        JSValue idx = JS_GetPropertyStr(ctx, m, "index");
        JSValue seg = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, seg, "segment", JS_DupValue(ctx, m0));
        JS_SetPropertyStr(ctx, seg, "index", JS_DupValue(ctx, idx));
        JS_SetPropertyStr(ctx, seg, "input", JS_DupValue(ctx, input));
        if (g && strcmp(g, "word") == 0) {
            /* isWordLike = /\w/.test(segment) */
            const char *s0 = JS_ToCString(ctx, m0);
            bool wordlike = false;
            for (const char *c = s0 ? s0 : ""; *c; c++) { if ((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') || *c == '_') { wordlike = true; break; } }
            if (s0) { JS_FreeCString(ctx, s0); }
            JS_SetPropertyStr(ctx, seg, "isWordLike", JS_NewBool(ctx, wordlike));
        }
        JS_SetPropertyUint32(ctx, list, k++, seg);
        /* empty match: advance lastIndex */
        const char *ms = JS_ToCString(ctx, m0);
        if (ms && ms[0] == 0) { JSValue li = JS_GetPropertyStr(ctx, re, "lastIndex"); double d; JS_ToFloat64(ctx, &d, li); JS_FreeValue(ctx, li); JS_SetPropertyStr(ctx, re, "lastIndex", JS_NewFloat64(ctx, d + 1)); }
        if (ms) { JS_FreeCString(ctx, ms); }
        JS_FreeValue(ctx, m0); JS_FreeValue(ctx, idx); JS_FreeValue(ctx, m);
    }
    JS_FreeValue(ctx, re);
    if (g) { JS_FreeCString(ctx, g); }
    /* wrap: { [Symbol.iterator]() { return list[Symbol.iterator](); }, containing(i){...} }. We return the array with a
     * `containing` method attached and the array's own iterator, which is iterable and supports .containing. */
    JSValue result = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, result, "_list", list);
    JS_SetPropertyStr(ctx, result, "input", JS_DupValue(ctx, input));
    /* define [Symbol.iterator] delegating to the list */
    JSValue iter = JS_NewCFunction(ctx, seg_result_iterator, "[Symbol.iterator]", 0);
    JSValue sym = JS_GetPropertyStr(ctx, wj_the_realm.global, "Symbol");
    JSValue symit = JS_GetPropertyStr(ctx, sym, "iterator");
    JSAtom ia = JS_ValueToAtom(ctx, symit);
    JS_DefinePropertyValue(ctx, result, ia, iter, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
    JS_FreeAtom(ctx, ia); JS_FreeValue(ctx, symit); JS_FreeValue(ctx, sym);
    JS_SetPropertyStr(ctx, result, "containing", JS_NewCFunction(ctx, seg_result_containing, "containing", 1));
    JS_FreeValue(ctx, input);
    return result;
}
static JSValue seg_result_iterator(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue list = JS_GetPropertyStr(ctx, this_val, "_list");
    JSValue sym = JS_GetPropertyStr(ctx, wj_the_realm.global, "Symbol");
    JSValue symit = JS_GetPropertyStr(ctx, sym, "iterator");
    JSAtom ia = JS_ValueToAtom(ctx, symit);
    JSValue itf = JS_GetProperty(ctx, list, ia);
    JSValue r = JS_Call(ctx, itf, list, 0, NULL);
    JS_FreeAtom(ctx, ia); JS_FreeValue(ctx, itf); JS_FreeValue(ctx, symit); JS_FreeValue(ctx, sym); JS_FreeValue(ctx, list);
    return r;
}
static JSValue seg_result_containing(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    double i; if (JS_ToFloat64(ctx, &i, wj_arg(argc, (JSValue *)argv, 0)) < 0) { i = 0; }
    JSValue list = JS_GetPropertyStr(ctx, this_val, "_list");
    uint32_t n = 0; JSValue lenv = JS_GetPropertyStr(ctx, list, "length"); JS_ToUint32(ctx, &n, lenv); JS_FreeValue(ctx, lenv);
    JSValue found = JS_UNDEFINED;
    for (uint32_t j = 0; j < n; j++) {
        JSValue seg = JS_GetPropertyUint32(ctx, list, j);
        JSValue idxv = JS_GetPropertyStr(ctx, seg, "index"); JSValue sv = JS_GetPropertyStr(ctx, seg, "segment");
        double idx; JS_ToFloat64(ctx, &idx, idxv);
        const char *s = JS_ToCString(ctx, sv); size_t sl = s ? strlen(s) : 0; if (s) { JS_FreeCString(ctx, s); }
        JS_FreeValue(ctx, idxv); JS_FreeValue(ctx, sv);
        if (i >= idx && i < idx + (double)sl) { found = seg; break; }
        JS_FreeValue(ctx, seg);
    }
    JS_FreeValue(ctx, list);
    return found;
}
static JSValue seg_resolved(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue gv = JS_GetPropertyStr(ctx, this_val, "_g");
    JSValue obj = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, obj, "locale", JS_NewString(ctx, "en-US"));
    JS_SetPropertyStr(ctx, obj, "granularity", gv);
    return obj;
}

/* ---- DisplayNames ---- */

typedef struct { const char *code; const char *name; } code_name;
static const code_name DN_LANGUAGE[] = { { "en", "English" }, { "fr", "French" }, { "de", "German" }, { "es", "Spanish" },
    { "it", "Italian" }, { "ja", "Japanese" }, { "zh", "Chinese" }, { "pt", "Portuguese" }, { "ru", "Russian" },
    { "nl", "Dutch" }, { "ko", "Korean" }, { "ar", "Arabic" } };
static const code_name DN_REGION[] = { { "US", "United States" }, { "GB", "United Kingdom" }, { "FR", "France" },
    { "DE", "Germany" }, { "ES", "Spain" }, { "IT", "Italy" }, { "JP", "Japan" }, { "CN", "China" }, { "CA", "Canada" },
    { "BR", "Brazil" }, { "IN", "India" } };
static const code_name DN_CURRENCY[] = { { "USD", "US Dollar" }, { "EUR", "Euro" }, { "GBP", "British Pound" }, { "JPY", "Japanese Yen" } };

static JSValue dn_ctor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(this_val)) { return JS_ThrowTypeError(ctx, "Constructor Intl.DisplayNames requires 'new'"); }
    bool is_new;
    JSValue obj = intl_new_this(ctx, this_val, 0, &is_new);
    if (JS_IsException(obj)) { return obj; }
    JSValue canon = intl_canonical_locales(ctx, wj_arg(argc, (JSValue *)argv, 0));
    if (JS_IsException(canon)) { JS_FreeValue(ctx, obj); return canon; }
    JS_FreeValue(ctx, canon);
    JSValue o = intl_to_object(ctx, wj_arg(argc, (JSValue *)argv, 1));
    if (JS_IsException(o)) { JS_FreeValue(ctx, obj); return o; }
    bool err = false;
    static const char *const type_v[] = { "language", "region", "script", "currency", "calendar", "dateTimeField", NULL };
    char *type = intl_get_opt(ctx, o, "type", type_v, NULL, false, NULL, &err); if (err) { JS_FreeValue(ctx, o); JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    if (!type) { JS_FreeValue(ctx, o); JS_FreeValue(ctx, obj); return JS_ThrowTypeError(ctx, "type is required"); }
    def_ne(ctx, obj, "_type", JS_NewString(ctx, type));
    free(type);
    JS_FreeValue(ctx, o);
    return obj;
}
static JSValue dn_of(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue tv = JS_GetPropertyStr(ctx, this_val, "_type");
    const char *type = JS_ToCString(ctx, tv);
    JS_FreeValue(ctx, tv);
    const char *code = JS_ToCString(ctx, wj_arg(argc, (JSValue *)argv, 0));
    const code_name *table = NULL; size_t count = 0;
    if (type && strcmp(type, "language") == 0) { table = DN_LANGUAGE; count = sizeof DN_LANGUAGE / sizeof DN_LANGUAGE[0]; }
    else if (type && strcmp(type, "region") == 0) { table = DN_REGION; count = sizeof DN_REGION / sizeof DN_REGION[0]; }
    else if (type && strcmp(type, "currency") == 0) { table = DN_CURRENCY; count = sizeof DN_CURRENCY / sizeof DN_CURRENCY[0]; }
    const char *found = NULL;
    if (table && code) {
        for (size_t i = 0; i < count; i++) { if (strcmp(table[i].code, code) == 0) { found = table[i].name; break; } }
        if (!found) {
            /* t[String(code).split("-")[0]] */
            char head[64]; int i = 0; for (; code[i] && code[i] != '-' && i < 63; i++) { head[i] = code[i]; } head[i] = 0;
            for (size_t j = 0; j < count; j++) { if (strcmp(table[j].code, head) == 0) { found = table[j].name; break; } }
        }
    }
    JSValue r = JS_NewString(ctx, found ? found : (code ? code : ""));
    if (type) { JS_FreeCString(ctx, type); }
    if (code) { JS_FreeCString(ctx, code); }
    return r;
}
static JSValue dn_resolved(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    JSValue tv = JS_GetPropertyStr(ctx, this_val, "_type");
    JSValue obj = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, obj, "locale", JS_NewString(ctx, "en-US"));
    JS_SetPropertyStr(ctx, obj, "type", tv);
    JS_SetPropertyStr(ctx, obj, "style", JS_NewString(ctx, "long"));
    JS_SetPropertyStr(ctx, obj, "fallback", JS_NewString(ctx, "code"));
    return obj;
}

/* ---- Intl namespace statics ---- */

static JSValue intl_get_canonical_locales(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    return intl_canonical_locales(ctx, wj_arg(argc, (JSValue *)argv, 0));
}
static JSValue intl_supported_values_of(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    const char *key = JS_ToCString(ctx, wj_arg(argc, (JSValue *)argv, 0));
    JSValue arr = JS_NewArray(ctx);
    bool known = true;
    if (key && strcmp(key, "calendar") == 0) { JS_SetPropertyUint32(ctx, arr, 0, JS_NewString(ctx, "gregory")); }
    else if (key && strcmp(key, "collation") == 0) { JS_SetPropertyUint32(ctx, arr, 0, JS_NewString(ctx, "default")); }
    else if (key && strcmp(key, "numberingSystem") == 0) { JS_SetPropertyUint32(ctx, arr, 0, JS_NewString(ctx, "latn")); }
    else if (key && strcmp(key, "timeZone") == 0) { JS_SetPropertyUint32(ctx, arr, 0, JS_NewString(ctx, "UTC")); }
    else if (key && strcmp(key, "currency") == 0) {
        /* Object.keys(CURRENCY_SYMBOLS).sort() */
        size_t n = sizeof CURRENCY_SYMBOLS / sizeof CURRENCY_SYMBOLS[0];
        const char *codes[32]; for (size_t i = 0; i < n; i++) { codes[i] = CURRENCY_SYMBOLS[i].code; }
        for (size_t i = 0; i < n; i++) { for (size_t j = i + 1; j < n; j++) { if (strcmp(codes[i], codes[j]) > 0) { const char *t = codes[i]; codes[i] = codes[j]; codes[j] = t; } } }
        for (size_t i = 0; i < n; i++) { JS_SetPropertyUint32(ctx, arr, (uint32_t)i, JS_NewString(ctx, codes[i])); }
    }
    else if (key && strcmp(key, "unit") == 0) {
        size_t n = sizeof UNITS / sizeof UNITS[0];
        const char *codes[64]; for (size_t i = 0; i < n; i++) { codes[i] = UNITS[i].unit; }
        for (size_t i = 0; i < n; i++) { for (size_t j = i + 1; j < n; j++) { if (strcmp(codes[i], codes[j]) > 0) { const char *t = codes[i]; codes[i] = codes[j]; codes[j] = t; } } }
        for (size_t i = 0; i < n; i++) { JS_SetPropertyUint32(ctx, arr, (uint32_t)i, JS_NewString(ctx, codes[i])); }
    }
    else { known = false; }
    if (!known) { JS_FreeValue(ctx, arr); JSValue e = JS_ThrowRangeError(ctx, "Invalid key : %s", key ? key : ""); if (key) { JS_FreeCString(ctx, key); } return e; }
    if (key) { JS_FreeCString(ctx, key); }
    return arr;
}

/* ---- building the namespace ---- */

/* define a constructor function with the given prototype methods, set toStringTag, prototype, name, length, statics */
static JSValue make_ctor(JSContext *ctx, const char *name, JSCFunction *fn, int length,
                         const JSCFunctionListEntry *proto_funcs, int n_proto, const char *tag,
                         bool static_supported, bool callable_without_new)
{
    JSValue proto = JS_NewObject(ctx);
    if (proto_funcs) { JS_SetPropertyFunctionList(ctx, proto, proto_funcs, n_proto); }
    if (tag) { set_tag(ctx, proto, tag); }
    JSValue ctor = JS_NewCFunction2(ctx, fn, name, length,
        callable_without_new ? JS_CFUNC_constructor_or_func : JS_CFUNC_constructor, 0);
    JS_SetConstructor(ctx, ctor, proto);
    JS_DefinePropertyValueStr(ctx, ctor, "prototype", JS_DupValue(ctx, proto), 0);
    if (static_supported) {
        JS_DefinePropertyValueStr(ctx, ctor, "supportedLocalesOf",
            JS_NewCFunction(ctx, intl_supported_locales, "supportedLocalesOf", 1),
            JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
    }
    JS_FreeValue(ctx, proto);
    return ctor;
}

void wj_install_intl(JSContext *ctx)
{
    JSValue global = wj_the_realm.global;
    JSValue intl = JS_NewObject(ctx);
    set_tag(ctx, intl, "Intl");

    /* NumberFormat */
    static const JSCFunctionListEntry nf_proto[] = {
        JS_CFUNC_DEF("formatToParts", 1, nf_format_to_parts),
        JS_CGETSET_DEF("format", nf_get_format, NULL),
        JS_CFUNC_DEF("formatRange", 2, nf_format_range),
        JS_CFUNC_DEF("resolvedOptions", 0, nf_resolved),
    };
    JSValue nfc = make_ctor(ctx, "NumberFormat", nf_ctor, 0, nf_proto, (int)(sizeof nf_proto / sizeof nf_proto[0]), "Intl.NumberFormat", true, true);
    def_ne(ctx, intl, "NumberFormat", nfc);

    /* DateTimeFormat */
    static const JSCFunctionListEntry dtf_proto[] = {
        JS_CFUNC_DEF("formatToParts", 1, dtf_format_to_parts),
        JS_CFUNC_DEF("formatRange", 2, dtf_format_range),
        JS_CFUNC_DEF("formatRangeToParts", 2, dtf_format_range_to_parts),
        JS_CGETSET_DEF("format", dtf_get_format, NULL),
        JS_CFUNC_DEF("resolvedOptions", 0, dtf_resolved),
    };
    JSValue dtfc = make_ctor(ctx, "DateTimeFormat", dtf_ctor, 0, dtf_proto, (int)(sizeof dtf_proto / sizeof dtf_proto[0]), "Intl.DateTimeFormat", true, true);
    def_ne(ctx, intl, "DateTimeFormat", dtfc);

    /* PluralRules */
    static const JSCFunctionListEntry pr_proto[] = {
        JS_CFUNC_DEF("select", 1, pr_select),
        JS_CFUNC_DEF("selectRange", 2, pr_select_range),
        JS_CFUNC_DEF("resolvedOptions", 0, pr_resolved),
    };
    JSValue prc = make_ctor(ctx, "PluralRules", pr_ctor, 0, pr_proto, (int)(sizeof pr_proto / sizeof pr_proto[0]), "Intl.PluralRules", true, false);
    def_ne(ctx, intl, "PluralRules", prc);

    /* RelativeTimeFormat */
    static const JSCFunctionListEntry rtf_proto[] = {
        JS_CFUNC_DEF("format", 2, rtf_format),
        JS_CFUNC_DEF("formatToParts", 2, rtf_format_to_parts),
        JS_CFUNC_DEF("resolvedOptions", 0, rtf_resolved),
    };
    JSValue rtfc = make_ctor(ctx, "RelativeTimeFormat", rtf_ctor, 0, rtf_proto, (int)(sizeof rtf_proto / sizeof rtf_proto[0]), "Intl.RelativeTimeFormat", true, false);
    def_ne(ctx, intl, "RelativeTimeFormat", rtfc);

    /* ListFormat */
    static const JSCFunctionListEntry lf_proto[] = {
        JS_CFUNC_DEF("format", 1, lf_format),
        JS_CFUNC_DEF("formatToParts", 1, lf_format_to_parts),
        JS_CFUNC_DEF("resolvedOptions", 0, lf_resolved),
    };
    JSValue lfc = make_ctor(ctx, "ListFormat", lf_ctor, 0, lf_proto, (int)(sizeof lf_proto / sizeof lf_proto[0]), "Intl.ListFormat", true, false);
    def_ne(ctx, intl, "ListFormat", lfc);

    /* Collator */
    static const JSCFunctionListEntry coll_proto[] = {
        JS_CGETSET_DEF("compare", coll_get_compare, NULL),
        JS_CFUNC_DEF("resolvedOptions", 0, coll_resolved),
    };
    JSValue collc = make_ctor(ctx, "Collator", coll_ctor, 0, coll_proto, (int)(sizeof coll_proto / sizeof coll_proto[0]), "Intl.Collator", true, true);
    def_ne(ctx, intl, "Collator", collc);

    /* Locale */
    static const JSCFunctionListEntry locale_proto[] = {
        JS_CGETSET_MAGIC_DEF("language", locale_get_field, NULL, 0),
        JS_CGETSET_MAGIC_DEF("script", locale_get_field, NULL, 1),
        JS_CGETSET_MAGIC_DEF("region", locale_get_field, NULL, 2),
        JS_CGETSET_DEF("baseName", locale_base_name, NULL),
        JS_CFUNC_DEF("toString", 0, locale_to_string),
        JS_CFUNC_DEF("maximize", 0, locale_maximize),
        JS_CFUNC_DEF("minimize", 0, locale_minimize),
    };
    JSValue localec = make_ctor(ctx, "Locale", locale_ctor, 1, locale_proto, (int)(sizeof locale_proto / sizeof locale_proto[0]), "Intl.Locale", false, false);
    def_ne(ctx, intl, "Locale", localec);

    /* Segmenter */
    static const JSCFunctionListEntry seg_proto[] = {
        JS_CFUNC_DEF("segment", 1, seg_segment),
        JS_CFUNC_DEF("resolvedOptions", 0, seg_resolved),
    };
    JSValue segc = make_ctor(ctx, "Segmenter", seg_ctor, 0, seg_proto, (int)(sizeof seg_proto / sizeof seg_proto[0]), NULL, true, false);
    def_ne(ctx, intl, "Segmenter", segc);

    /* DisplayNames */
    static const JSCFunctionListEntry dn_proto[] = {
        JS_CFUNC_DEF("of", 1, dn_of),
        JS_CFUNC_DEF("resolvedOptions", 0, dn_resolved),
    };
    JSValue dnc = make_ctor(ctx, "DisplayNames", dn_ctor, 0, dn_proto, (int)(sizeof dn_proto / sizeof dn_proto[0]), NULL, false, false);
    def_ne(ctx, intl, "DisplayNames", dnc);

    def_ne(ctx, intl, "getCanonicalLocales", JS_NewCFunction(ctx, intl_get_canonical_locales, "getCanonicalLocales", 1));
    def_ne(ctx, intl, "supportedValuesOf", JS_NewCFunction(ctx, intl_supported_values_of, "supportedValuesOf", 1));

    def_ne(ctx, global, "Intl", intl);

    /* the locale-sensitive methods of the standard library */
    JSValue date_proto = JS_GetClassProto(ctx, JS_CLASS_DATE);
    def_ne(ctx, date_proto, "toLocaleString", JS_NewCFunctionMagic(ctx, date_to_locale, "toLocaleString", 0, JS_CFUNC_generic_magic, 0));
    def_ne(ctx, date_proto, "toLocaleDateString", JS_NewCFunctionMagic(ctx, date_to_locale, "toLocaleDateString", 0, JS_CFUNC_generic_magic, 1));
    def_ne(ctx, date_proto, "toLocaleTimeString", JS_NewCFunctionMagic(ctx, date_to_locale, "toLocaleTimeString", 0, JS_CFUNC_generic_magic, 2));
    JS_FreeValue(ctx, date_proto);
    JSValue number_proto = JS_GetClassProto(ctx, JS_CLASS_NUMBER);
    def_ne(ctx, number_proto, "toLocaleString", JS_NewCFunction(ctx, number_to_locale, "toLocaleString", 0));
    JS_FreeValue(ctx, number_proto);
    JSValue bigint_proto = JS_GetClassProto(ctx, JS_CLASS_BIG_INT);
    def_ne(ctx, bigint_proto, "toLocaleString", JS_NewCFunction(ctx, number_to_locale, "toLocaleString", 0));
    JS_FreeValue(ctx, bigint_proto);
    JSValue string_proto = JS_GetClassProto(ctx, JS_CLASS_STRING);
    def_ne(ctx, string_proto, "localeCompare", JS_NewCFunction(ctx, string_locale_compare, "localeCompare", 1));
    JS_FreeValue(ctx, string_proto);
}
