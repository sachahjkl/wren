/* web_animations.c: Web Animations for JavaScript (Element.animate, Animation, KeyframeEffect, document.timeline,
 * AnimationPlaybackEvent) and the details of the browser's AnimationEvent / TransitionEvent.
 *
 * The browser keeps each animation's timing model and plays its effect (module animations, src/page/web_animations.odin);
 * what is here is what needs the language: the arguments read as Web Animations says (a keyframes argument in both of
 * its forms, the timing dictionaries), the KeyframeEffect object (its keyframes, as getKeyframes returns them, and
 * its timing, sent to the browser packed whenever the effect belongs to an animation), and the ready / finished
 * promises, settled from what the browser reports (Animation_takeOps) in the notify microtask of the animation. An
 * animation's wrapper is kept alive while the browser says it may still matter (k / u: running, pending, events to
 * fire, an effect shown); a new one is kept until the first report. */
#include <math.h>
#include <stdlib.h>
#include "web.h"

static const char *const fill_names[] = { "none", "forwards", "backwards", "both", "auto", NULL };
enum { FILL_AUTO = 4 };
static const char *const direction_names[] = { "normal", "reverse", "alternate", "alternate-reverse", NULL };
static const char *const composite_names[] = { "replace", "add", "accumulate", NULL };
static const char *const composite_auto_names[] = { "replace", "add", "accumulate", "auto", NULL };
static const char *const iteration_composite_names[] = { "replace", "accumulate", NULL };
static const char *const play_state_names[] = { "idle", "running", "paused", "finished" };
static const char *const replace_state_names[] = { "active", "removed", "persisted" };

/* ---- timing ---- */

typedef struct fx_timing {
    double delay, end_delay, duration /* NAN: "auto" */, iterations, iteration_start;
    int fill, direction;
    char *easing;   /* malloc'ed */
} fx_timing;

static void timing_default(fx_timing *t)
{
    memset(t, 0, sizeof *t);
    t->duration = NAN;
    t->iterations = 1;
    t->fill = FILL_AUTO;
}

static bool easing_check(JSContext *ctx, const char *s, size_t n)
{
    if (wr_Animation_validEasing((const uint8_t *)s, (uint32_t)n)) { return true; }
    JS_ThrowTypeError(ctx, "'%.*s' is not a valid value for easing", (int)(n > 64 ? 64 : n), s);
    return false;
}

static bool read_double(JSContext *ctx, JSValueConst dict, const char *name, bool restricted, bool *has, double *out)
{
    JSValue v;
    *has = false;
    if (!web_dict_get(ctx, dict, name, &v)) { return false; }
    if (JS_IsUndefined(v)) { return true; }
    bool ok = wj_to_double(ctx, v, out, restricted);
    JS_FreeValue(ctx, v);
    *has = ok;
    return ok;
}

static bool read_enum(JSContext *ctx, JSValueConst dict, const char *name, const char *const *values, const char *type, bool *has, int *out)
{
    JSValue v;
    *has = false;
    if (!web_dict_get(ctx, dict, name, &v)) { return false; }
    if (JS_IsUndefined(v)) { return true; }
    wj_str s;
    bool ok = wj_to_str(ctx, v, &s, 0, "");
    JS_FreeValue(ctx, v);
    if (!ok) { return false; }
    int i = wj_enum_index(&s, values);
    if (i < 0) { return wj_check_enum(ctx, &s, values, type); }
    wj_str_free(ctx, &s);
    *out = i;
    *has = true;
    return true;
}

/* Reads EffectTiming / OptionalEffectTiming members of `dict` into `t` (members absent keep their value), checked as
 * "update the timing properties of an animation effect" says before anything changes. */
static bool timing_read(JSContext *ctx, JSValueConst dict, fx_timing *t)
{
    fx_timing n = *t;
    n.easing = NULL;
    bool has;
    double d;
    int e;
    char *easing = NULL;
    if (!read_double(ctx, dict, "delay", true, &has, &d)) { return false; }
    if (has) { n.delay = d; }
    if (!read_enum(ctx, dict, "direction", direction_names, "PlaybackDirection", &has, &e)) { return false; }
    if (has) { n.direction = e; }
    JSValue dur;
    if (!web_dict_get(ctx, dict, "duration", &dur)) { return false; }
    if (!JS_IsUndefined(dur)) {
        if (JS_IsString(dur)) {
            const char *s = JS_ToCString(ctx, dur);
            bool is_auto = s && strcmp(s, "auto") == 0;
            if (s) { JS_FreeCString(ctx, s); }
            JS_FreeValue(ctx, dur);
            if (!is_auto) { JS_ThrowTypeError(ctx, "duration must be a non-negative number or the string 'auto'"); return false; }
            n.duration = NAN;
        } else {
            bool ok = wj_to_double(ctx, dur, &d, false);
            JS_FreeValue(ctx, dur);
            if (!ok) { return false; }
            if (isnan(d) || d < 0) { JS_ThrowTypeError(ctx, "duration must be a non-negative number or the string 'auto'"); return false; }
            n.duration = d;
        }
    }
    JSValue ez;
    if (!web_dict_get(ctx, dict, "easing", &ez)) { return false; }
    if (!JS_IsUndefined(ez)) {
        wj_str s;
        bool ok = wj_to_str(ctx, ez, &s, 0, "");
        JS_FreeValue(ctx, ez);
        if (!ok) { return false; }
        if (!easing_check(ctx, s.ptr ? s.ptr : "", s.len)) { wj_str_free(ctx, &s); return false; }
        easing = web_strndup(s.ptr ? s.ptr : "", s.len);
        wj_str_free(ctx, &s);
        if (!easing) { JS_ThrowOutOfMemory(ctx); return false; }
    }
    if (!read_double(ctx, dict, "endDelay", true, &has, &d)) { free(easing); return false; }
    if (has) { n.end_delay = d; }
    if (!read_enum(ctx, dict, "fill", fill_names, "FillMode", &has, &e)) { free(easing); return false; }
    if (has) { n.fill = e; }
    if (!read_double(ctx, dict, "iterationStart", true, &has, &d)) { free(easing); return false; }
    if (has) {
        if (d < 0) { free(easing); JS_ThrowTypeError(ctx, "iterationStart must be non-negative"); return false; }
        n.iteration_start = d;
    }
    if (!read_double(ctx, dict, "iterations", false, &has, &d)) { free(easing); return false; }
    if (has) {
        if (isnan(d) || d < 0) { free(easing); JS_ThrowTypeError(ctx, "iterations must be non-negative"); return false; }
        n.iterations = d;
    }
    if (easing) { free(t->easing); n.easing = easing; } else { n.easing = t->easing; }
    *t = n;
    return true;
}

/* KeyframeEffectOptions or a duration */
static bool timing_from_options(JSContext *ctx, JSValueConst opt, fx_timing *t)
{
    if (JS_IsUndefined(opt) || JS_IsNull(opt) || JS_IsObject(opt)) { return timing_read(ctx, opt, t); }
    double d;
    if (!wj_to_double(ctx, opt, &d, false)) { return false; }
    if (isnan(d) || d < 0) { JS_ThrowTypeError(ctx, "duration must be a non-negative number"); return false; }
    t->duration = d;
    return true;
}

static double active_duration(const fx_timing *t)
{
    double dur = isnan(t->duration) ? 0 : t->duration;
    if (dur == 0 || t->iterations == 0) { return 0; }
    return dur * t->iterations;
}

/* ---- keyframes ---- */

/* The CSS name of a keyframe member ("backgroundColor" -> "background-color", "cssFloat" -> "float"): NULL when the
 * member does not name a property (Web Animations 1 §5.10.3, "animation property name to IDL attribute name"). */
static char *css_name_of(const char *s, size_t n)
{
    if (n >= 2 && s[0] == '-' && s[1] == '-') { return web_strndup(s, n); }
    if (n == 0 || memchr(s, '-', n)) { return NULL; }
    if (n == 8 && memcmp(s, "cssFloat", 8) == 0) { return web_strndup("float", 5); }
    if (n == 9 && memcmp(s, "cssOffset", 9) == 0) { return web_strndup("offset", 6); }
    web_buf b = { 0 };
    size_t i = 0;
    if (n > 6 && memcmp(s, "webkit", 6) == 0 && s[6] >= 'A' && s[6] <= 'Z') { web_buf_puts(&b, "-webkit"); i = 6; }
    for (; i < n; i++) {
        char c = s[i];
        if (c >= 'A' && c <= 'Z') { char x[2] = { '-', (char)(c - 'A' + 'a') }; web_buf_put(&b, x, 2); }
        else { web_buf_put(&b, &c, 1); }
    }
    web_buf_put(&b, "", 1);
    if (b.failed) { web_buf_free(&b); return NULL; }
    return (char *)b.p;
}

static bool reserved_member(const char *s)
{
    return strcmp(s, "offset") == 0 || strcmp(s, "easing") == 0 || strcmp(s, "composite") == 0 || strcmp(s, "computedOffset") == 0;
}

/* A new normalized keyframe: {offset, easing, composite} (computedOffset is added once known). */
static JSValue frame_new(JSContext *ctx)
{
    JSValue f = JS_NewObject(ctx);
    if (JS_IsException(f)) { return f; }
    JS_SetPropertyStr(ctx, f, "offset", JS_NULL);
    JS_SetPropertyStr(ctx, f, "easing", JS_NewString(ctx, "linear"));
    JS_SetPropertyStr(ctx, f, "composite", JS_NewString(ctx, "auto"));
    return f;
}

/* The value of a property in a keyframe: a string (sequence form; an array as its string). */
static JSValue value_string(JSContext *ctx, JSValueConst v) { return JS_ToString(ctx, v); }

typedef struct seq_state { JSValue frames; uint32_t n; } seq_state;

static bool member_copy(JSContext *ctx, JSValueConst key, JSValueConst value, void *opaque)
{
    JSValue frame = *(JSValue *)opaque;
    const char *k = JS_ToCString(ctx, key);
    if (!k) { return false; }
    bool ok = true;
    if (!reserved_member(k)) {
        char *css = css_name_of(k, strlen(k));
        if (css) {
            free(css);
            JSValue s = value_string(ctx, value);
            if (JS_IsException(s)) { ok = false; } else { JS_SetPropertyStr(ctx, frame, k, s); }
        }
    }
    JS_FreeCString(ctx, k);
    return ok;
}

/* offset / easing / composite of one keyframe object (BaseKeyframe) */
static bool base_keyframe(JSContext *ctx, JSValueConst src, JSValue frame)
{
    JSValue v;
    if (!web_dict_get(ctx, src, "offset", &v)) { return false; }
    if (!JS_IsUndefined(v) && !JS_IsNull(v)) {
        double d;
        bool ok = wj_to_double(ctx, v, &d, true);
        JS_FreeValue(ctx, v);
        if (!ok) { return false; }
        JS_SetPropertyStr(ctx, frame, "offset", JS_NewFloat64(ctx, d));
    } else {
        JS_FreeValue(ctx, v);
    }
    if (!web_dict_get(ctx, src, "easing", &v)) { return false; }
    if (!JS_IsUndefined(v)) {
        JSValue s = JS_ToString(ctx, v);
        JS_FreeValue(ctx, v);
        if (JS_IsException(s)) { return false; }
        JS_SetPropertyStr(ctx, frame, "easing", s);
    }
    int e;
    bool has;
    if (!read_enum(ctx, src, "composite", composite_auto_names, "CompositeOperationOrAuto", &has, &e)) { return false; }
    if (has) { JS_SetPropertyStr(ctx, frame, "composite", JS_NewString(ctx, composite_auto_names[e])); }
    return true;
}

static bool seq_item(JSContext *ctx, JSValueConst item, void *opaque)
{
    seq_state *st = opaque;
    if (!JS_IsUndefined(item) && !JS_IsNull(item) && !JS_IsObject(item)) {
        JS_ThrowTypeError(ctx, "Failed to execute 'animate': a keyframe is not an object");
        return false;
    }
    JSValue frame = frame_new(ctx);
    if (JS_IsException(frame)) { return false; }
    bool ok = base_keyframe(ctx, item, frame) && (!JS_IsObject(item) || web_for_record(ctx, item, member_copy, &frame));
    if (!ok) { JS_FreeValue(ctx, frame); return false; }
    wj_array_set(ctx, st->frames, st->n++, frame);
    return true;
}

static double frame_offset(JSContext *ctx, JSValueConst frame, const char *name, bool *has)
{
    JSValue v = JS_GetPropertyStr(ctx, frame, name);
    double d = 0;
    *has = JS_IsNumber(v);
    if (*has) { JS_ToFloat64(ctx, &d, v); }
    JS_FreeValue(ctx, v);
    return d;
}

/* A list member of a property-indexed keyframe (a value, or a sequence of them): an array (counted). */
static JSValue as_list(JSContext *ctx, JSValueConst v)
{
    int it = web_is_iterable(ctx, v);
    if (it < 0) { return JS_EXCEPTION; }
    if (it && !JS_IsString(v)) {
        JSValue from = JS_GetPropertyStr(ctx, wj_the_realm.global, "Array");
        JSValue fn = JS_GetPropertyStr(ctx, from, "from");
        JSValue r = JS_Call(ctx, fn, from, 1, &v);
        JS_FreeValue(ctx, fn);
        JS_FreeValue(ctx, from);
        return r;
    }
    JSValue a = JS_NewArray(ctx);
    if (!JS_IsException(a)) { wj_array_set(ctx, a, 0, JS_DupValue(ctx, v)); }
    return a;
}

static uint32_t list_length(JSContext *ctx, JSValueConst a)
{
    int64_t n = 0;
    JS_GetLength(ctx, a, &n);
    return (uint32_t)(n < 0 ? 0 : n);
}

typedef struct pi_state { JSValue frames; uint32_t n; JSValueConst src; } pi_state;

/* the frame at computed offset `off` (made, in order, when there is none) */
static JSValue pi_frame_at(JSContext *ctx, pi_state *st, double off)
{
    uint32_t at = st->n;
    for (uint32_t i = 0; i < st->n; i++) {
        JSValue f = JS_GetPropertyUint32(ctx, st->frames, i);
        bool has;
        double o = frame_offset(ctx, f, "computedOffset", &has);
        if (o == off) { return f; }
        JS_FreeValue(ctx, f);
        if (o > off) { at = i; break; }
    }
    JSValue f = frame_new(ctx);
    if (JS_IsException(f)) { return f; }
    JS_SetPropertyStr(ctx, f, "computedOffset", JS_NewFloat64(ctx, off));
    for (uint32_t i = st->n; i > at; i--) { wj_array_set(ctx, st->frames, i, JS_GetPropertyUint32(ctx, st->frames, i - 1)); }
    wj_array_set(ctx, st->frames, at, JS_DupValue(ctx, f));
    st->n++;
    return f;
}

static bool pi_member(JSContext *ctx, JSValueConst key, JSValueConst value, void *opaque)
{
    pi_state *st = opaque;
    const char *k = JS_ToCString(ctx, key);
    if (!k) { return false; }
    bool ok = true;
    char *css = reserved_member(k) ? NULL : css_name_of(k, strlen(k));
    if (css) {
        free(css);
        JSValue list = as_list(ctx, value);
        if (JS_IsException(list)) { ok = false; }
        uint32_t n = ok ? list_length(ctx, list) : 0;
        for (uint32_t i = 0; ok && i < n; i++) {
            JSValue v = JS_GetPropertyUint32(ctx, list, i);
            JSValue s = value_string(ctx, v);
            JS_FreeValue(ctx, v);
            if (JS_IsException(s)) { ok = false; break; }
            JSValue f = pi_frame_at(ctx, st, n == 1 ? 1.0 : (double)i / (double)(n - 1));
            if (JS_IsException(f)) { JS_FreeValue(ctx, s); ok = false; break; }
            JS_SetPropertyStr(ctx, f, k, s);
            JS_FreeValue(ctx, f);
        }
        JS_FreeValue(ctx, list);
    }
    JS_FreeCString(ctx, k);
    return ok;
}

/* offset, easing, composite of a property-indexed keyframe, given to the frames in order (easings and composites
 * repeat when there are fewer than frames) */
static bool pi_spread(JSContext *ctx, pi_state *st)
{
    static const char *const names[] = { "offset", "easing", "composite" };
    for (int m = 0; m < 3; m++) {
        JSValue v;
        if (!web_dict_get(ctx, st->src, names[m], &v)) { return false; }
        if (JS_IsUndefined(v)) { continue; }
        JSValue list = (m == 0 && JS_IsNull(v)) ? JS_NewArray(ctx) : as_list(ctx, v);
        JS_FreeValue(ctx, v);
        if (JS_IsException(list)) { return false; }
        uint32_t n = list_length(ctx, list);
        for (uint32_t i = 0; i < st->n && n > 0; i++) {
            if (m == 0 && i >= n) { break; }
            JSValue x = JS_GetPropertyUint32(ctx, list, m == 0 ? i : i % n);
            JSValue f = JS_GetPropertyUint32(ctx, st->frames, i);
            bool ok = true;
            if (m == 0) {
                if (!JS_IsNull(x)) {
                    double d;
                    ok = wj_to_double(ctx, x, &d, true);
                    if (ok) { JS_SetPropertyStr(ctx, f, "offset", JS_NewFloat64(ctx, d)); }
                }
            } else {
                wj_str s;
                ok = wj_to_str(ctx, x, &s, 0, "");
                if (ok && m == 2) {
                    int e = wj_enum_index(&s, composite_auto_names);
                    if (e < 0) { ok = wj_check_enum(ctx, &s, composite_auto_names, "CompositeOperationOrAuto"); }
                    else { JS_SetPropertyStr(ctx, f, "composite", JS_NewString(ctx, composite_auto_names[e])); wj_str_free(ctx, &s); }
                } else if (ok) {
                    JS_SetPropertyStr(ctx, f, "easing", JS_NewStringLen(ctx, s.ptr ? s.ptr : "", s.len));
                    wj_str_free(ctx, &s);
                }
            }
            JS_FreeValue(ctx, f);
            JS_FreeValue(ctx, x);
            if (!ok) { JS_FreeValue(ctx, list); return false; }
        }
        JS_FreeValue(ctx, list);
    }
    return true;
}

/* "Process a keyframes argument" (Web Animations 1 §5.10.3): the normalized keyframes (an array, counted), offsets
 * checked and computed, easings checked. */
static JSValue keyframes_process(JSContext *ctx, JSValueConst kf)
{
    JSValue frames = JS_NewArray(ctx);
    if (JS_IsException(frames) || JS_IsUndefined(kf) || JS_IsNull(kf)) { return frames; }
    if (!JS_IsObject(kf)) { JS_FreeValue(ctx, frames); return JS_ThrowTypeError(ctx, "keyframes must be an object or null"); }
    int it = web_is_iterable(ctx, kf);
    if (it < 0) { JS_FreeValue(ctx, frames); return JS_EXCEPTION; }
    uint32_t n = 0;
    bool sequence = it > 0;
    if (sequence) {
        seq_state st = { frames, 0 };
        if (!web_for_of(ctx, kf, seq_item, &st)) { JS_FreeValue(ctx, frames); return JS_EXCEPTION; }
        n = st.n;
    } else {
        pi_state st = { frames, 0, kf };
        if (!web_for_record(ctx, kf, pi_member, &st) || !pi_spread(ctx, &st)) { JS_FreeValue(ctx, frames); return JS_EXCEPTION; }
        n = st.n;
    }
    /* offsets: in [0, 1], never decreasing (TypeError); the missing ones spread evenly between the known ones */
    double *off = calloc(n ? n : 1, sizeof *off);
    bool *known = calloc(n ? n : 1, sizeof *known);
    if (!off || !known) { free(off); free(known); JS_FreeValue(ctx, frames); return JS_ThrowOutOfMemory(ctx); }
    double last = -INFINITY;
    for (uint32_t i = 0; i < n; i++) {
        JSValue f = JS_GetPropertyUint32(ctx, frames, i);
        off[i] = frame_offset(ctx, f, "offset", &known[i]);
        JS_FreeValue(ctx, f);
        if (!known[i]) { continue; }
        if (off[i] < 0 || off[i] > 1) { free(off); free(known); JS_FreeValue(ctx, frames); return JS_ThrowTypeError(ctx, "Offsets must be null or in the range [0,1]."); }
        if (off[i] < last) { free(off); free(known); JS_FreeValue(ctx, frames); return JS_ThrowTypeError(ctx, "Offsets must be monotonically non-decreasing."); }
        last = off[i];
    }
    if (!sequence) {
        /* property-indexed: the frames were made at their computed offsets; explicit offsets replace them */
        for (uint32_t i = 0; i < n; i++) {
            if (known[i]) { continue; }
            JSValue f = JS_GetPropertyUint32(ctx, frames, i);
            bool has;
            double o = frame_offset(ctx, f, "computedOffset", &has);
            JS_FreeValue(ctx, f);
            if (has) { off[i] = o; known[i] = true; }
        }
    }
    if (n > 0 && !known[n - 1]) { off[n - 1] = 1; known[n - 1] = true; }
    if (n > 1 && !known[0]) { off[0] = 0; known[0] = true; }
    for (uint32_t i = 1; i < n; i++) {
        if (known[i]) { continue; }
        uint32_t j = i;
        while (!known[j]) { j++; }
        for (uint32_t k = i; k < j; k++) { off[k] = off[i - 1] + (off[j] - off[i - 1]) * (double)(k - i + 1) / (double)(j - i + 1); known[k] = true; }
        i = j;
    }
    bool ok = true;
    for (uint32_t i = 0; i < n && ok; i++) {
        JSValue f = JS_GetPropertyUint32(ctx, frames, i);
        JS_SetPropertyStr(ctx, f, "computedOffset", JS_NewFloat64(ctx, off[i]));
        JSValue ez = JS_GetPropertyStr(ctx, f, "easing");
        size_t len = 0;
        const char *s = JS_ToCStringLen(ctx, &len, ez);
        ok = s && easing_check(ctx, s, len);
        if (s) { JS_FreeCString(ctx, s); }
        JS_FreeValue(ctx, ez);
        JS_FreeValue(ctx, f);
    }
    free(off);
    free(known);
    if (!ok) { JS_FreeValue(ctx, frames); return JS_EXCEPTION; }
    return frames;
}

static void buf_put_clean(web_buf *b, const char *s, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '\x1e' || s[i] == '\x1f') { continue; }
        web_buf_put(b, &s[i], 1);
    }
}

typedef struct pack_state { web_buf *b; } pack_state;

static bool pack_member(JSContext *ctx, JSValueConst key, JSValueConst value, void *opaque)
{
    pack_state *ps = opaque;
    size_t kn = 0, vn = 0;
    const char *k = JS_ToCStringLen(ctx, &kn, key);
    if (!k) { return false; }
    if (!reserved_member(k)) {
        char *css = css_name_of(k, kn);
        const char *v = css ? JS_ToCStringLen(ctx, &vn, value) : NULL;
        if (css && v) {
            web_buf_put(ps->b, "\x1f", 1);
            web_buf_puts(ps->b, css);
            web_buf_put(ps->b, "\x1f", 1);
            buf_put_clean(ps->b, v, vn);
        }
        if (v) { JS_FreeCString(ctx, v); }
        free(css);
    }
    JS_FreeCString(ctx, k);
    return true;
}

/* The keyframes as the browser takes them (see api/animations.widl), in `b`. */
static bool keyframes_pack(JSContext *ctx, JSValueConst frames, web_buf *b)
{
    uint32_t n = list_length(ctx, frames);
    for (uint32_t i = 0; i < n; i++) {
        JSValue f = JS_GetPropertyUint32(ctx, frames, i);
        bool has;
        double off = frame_offset(ctx, f, "computedOffset", &has);
        char num[40];
        snprintf(num, sizeof num, "%.17g", off);
        if (i > 0) { web_buf_put(b, "\x1e", 1); }
        web_buf_puts(b, num);
        web_buf_put(b, "\x1f", 1);
        JSValue ez = JS_GetPropertyStr(ctx, f, "easing");
        size_t len = 0;
        const char *s = JS_ToCStringLen(ctx, &len, ez);
        if (s) { buf_put_clean(b, s, len); JS_FreeCString(ctx, s); }
        JS_FreeValue(ctx, ez);
        /* the keyframe's own composite operation ("auto": the effect's) */
        JSValue co = JS_GetPropertyStr(ctx, f, "composite");
        if (JS_IsString(co)) {
            const char *c = JS_ToCStringLen(ctx, &len, co);
            if (c && (strcmp(c, "replace") == 0 || strcmp(c, "add") == 0 || strcmp(c, "accumulate") == 0)) {
                web_buf_puts(b, "\x1f" "composite" "\x1f");
                web_buf_puts(b, c);
            }
            if (c) { JS_FreeCString(ctx, c); }
        }
        JS_FreeValue(ctx, co);
        pack_state ps = { b };
        bool ok = web_for_record(ctx, f, pack_member, &ps);
        JS_FreeValue(ctx, f);
        if (!ok) { return false; }
    }
    if (b->failed) { JS_ThrowOutOfMemory(ctx); return false; }
    return true;
}

/* ---- KeyframeEffect ---- */

typedef struct fx_impl {
    JSValue target;        /* Element, or null */
    JSValue pseudo;        /* string, or null: effects on pseudo-elements are kept but not shown */
    JSValue frames;        /* the normalized keyframes */
    fx_timing t;
    int composite, iteration_composite;
    uint64_t anim;         /* the browser's animation it is the effect of (0: none) */
} fx_impl;

static void fx_free(void *p)
{
    fx_impl *e = p;
    JSRuntime *rt = web_rt();
    JS_FreeValueRT(rt, e->target);
    JS_FreeValueRT(rt, e->pseudo);
    JS_FreeValueRT(rt, e->frames);
    free(e->t.easing);
    free(e);
}

static void fx_mark(void *rt, void *p, void *mark_func)
{
    fx_impl *e = p;
    wj_mark(rt, e->target, mark_func);
    wj_mark(rt, e->pseudo, mark_func);
    wj_mark(rt, e->frames, mark_func);
}

static fx_impl *fx_of(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_KeyframeEffect);
    return o && o->impl_free == fx_free ? o->impl : NULL;
}

static fx_impl *fx_this(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_AnimationEffect)) { return NULL; }
    fx_impl *e = fx_of(this_val);
    if (!e) { JS_ThrowTypeError(ctx, "Illegal invocation"); }
    return e;
}

/* Sends the effect to its animation's browser side. */
static bool fx_push(JSContext *ctx, fx_impl *e)
{
    if (!e->anim) { return true; }
    uint64_t target = 0;
    if (JS_IsNull(e->pseudo)) {
        wj_obj *o = wj_unwrap(e->target, WJ_IFACE_Element);
        if (o) { target = o->handle; }
    }
    web_buf b = { 0 };
    if (!keyframes_pack(ctx, e->frames, &b)) { web_buf_free(&b); return false; }
    const char *ez = e->t.easing ? e->t.easing : "linear";
    int fill = e->t.fill == FILL_AUTO ? 0 : e->t.fill;
    /* fill modes in the style engine's order: none, forwards, backwards, both */
    int32_t st = wr_Animation_setEffect(e->anim, target, b.p ? b.p : (const uint8_t *)"", (uint32_t)b.len, e->t.duration, e->t.delay,
        e->t.end_delay, e->t.iterations, e->t.iteration_start, e->t.direction, fill, (const uint8_t *)ez, (uint32_t)strlen(ez), e->composite);
    web_buf_free(&b);
    if (st < 0) { wj_throw_status(ctx, st, "KeyframeEffect"); return false; }
    return true;
}

static JSValue fx_new(JSContext *ctx, JSValueConst new_target, JSValueConst target, JSValueConst keyframes, JSValueConst options)
{
    if (!JS_IsNull(target) && !JS_IsUndefined(target) && !wj_unwrap(target, WJ_IFACE_Element)) {
        return JS_ThrowTypeError(ctx, "Failed to construct 'KeyframeEffect': parameter 1 is not of type 'Element'.");
    }
    fx_impl *e = calloc(1, sizeof *e);
    if (!e) { return JS_ThrowOutOfMemory(ctx); }
    e->target = JS_IsUndefined(target) ? JS_NULL : JS_DupValue(ctx, target);
    e->pseudo = JS_NULL;
    e->frames = JS_UNDEFINED;
    timing_default(&e->t);
    JSValue frames = keyframes_process(ctx, keyframes);
    if (JS_IsException(frames) || !timing_from_options(ctx, options, &e->t)) { JS_FreeValue(ctx, frames); fx_free(e); return JS_EXCEPTION; }
    e->frames = frames;
    if (JS_IsObject(options)) {
        bool has;
        int v;
        if (!read_enum(ctx, options, "composite", composite_names, "CompositeOperation", &has, &v)) { fx_free(e); return JS_EXCEPTION; }
        if (has) { e->composite = v; }
        if (!read_enum(ctx, options, "iterationComposite", iteration_composite_names, "IterationCompositeOperation", &has, &v)) { fx_free(e); return JS_EXCEPTION; }
        if (has) { e->iteration_composite = v; }
        JSValue pe;
        if (!web_dict_get(ctx, options, "pseudoElement", &pe)) { fx_free(e); return JS_EXCEPTION; }
        if (!JS_IsUndefined(pe) && !JS_IsNull(pe)) {
            JSValue s = JS_ToString(ctx, pe);
            JS_FreeValue(ctx, pe);
            if (JS_IsException(s)) { fx_free(e); return s; }
            const char *c = JS_ToCString(ctx, s);
            bool valid = c && (strcmp(c, "::before") == 0 || strcmp(c, "::after") == 0 || strcmp(c, "::marker") == 0 || strcmp(c, ":before") == 0 || strcmp(c, ":after") == 0);
            if (c) { JS_FreeCString(ctx, c); }
            if (!valid) { JS_FreeValue(ctx, s); fx_free(e); return wj_throw_dom(ctx, "SyntaxError", "Invalid pseudoElement"); }
            e->pseudo = s;
        } else {
            JS_FreeValue(ctx, pe);
        }
    }
    JSValue obj = wj_new_object_for(ctx, WJ_IFACE_KeyframeEffect, new_target, NULL, NULL);
    if (JS_IsException(obj)) { fx_free(e); return obj; }
    web_set_impl(obj, e, fx_free, fx_mark);
    return obj;
}

JSValue wjr_KeyframeEffect_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor KeyframeEffect requires 'new'"); }
    fx_impl *src = argc == 1 ? fx_of(argv[0]) : NULL;
    if (src) {
        /* new KeyframeEffect(source): a copy of its target, keyframes and timing */
        JSValue obj = fx_new(ctx, new_target, src->target, JS_NULL, JS_UNDEFINED);
        if (JS_IsException(obj)) { return obj; }
        fx_impl *e = fx_of(obj);
        JS_FreeValue(ctx, e->frames);
        e->frames = JS_DupValue(ctx, src->frames);
        JS_FreeValue(ctx, e->pseudo);
        e->pseudo = JS_DupValue(ctx, src->pseudo);
        free(e->t.easing);
        e->t = src->t;
        e->t.easing = src->t.easing ? web_strndup(src->t.easing, strlen(src->t.easing)) : NULL;
        e->composite = src->composite;
        e->iteration_composite = src->iteration_composite;
        return obj;
    }
    if (argc < 2) { return wj_throw_arity(ctx, "KeyframeEffect", 2, argc); }
    return fx_new(ctx, new_target, argv[0], argv[1], wj_arg(argc, (JSValue *)argv, 2));
}

JSValue wjr_KeyframeEffect_get_target(JSContext *ctx, JSValueConst this_val)
{
    fx_impl *e = fx_this(ctx, this_val);
    return e ? JS_DupValue(ctx, e->target) : JS_EXCEPTION;
}

JSValue wjr_KeyframeEffect_set_target(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    fx_impl *e = fx_this(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    if (!JS_IsNull(v) && !JS_IsUndefined(v) && !wj_unwrap(v, WJ_IFACE_Element)) { return JS_ThrowTypeError(ctx, "Failed to set the 'target' property on 'KeyframeEffect': The provided value is not of type 'Element'."); }
    JS_FreeValue(ctx, e->target);
    e->target = JS_IsUndefined(v) ? JS_NULL : JS_DupValue(ctx, v);
    return fx_push(ctx, e) ? JS_UNDEFINED : JS_EXCEPTION;
}

JSValue wjr_KeyframeEffect_get_pseudoElement(JSContext *ctx, JSValueConst this_val)
{
    fx_impl *e = fx_this(ctx, this_val);
    return e ? JS_DupValue(ctx, e->pseudo) : JS_EXCEPTION;
}

JSValue wjr_KeyframeEffect_set_pseudoElement(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    fx_impl *e = fx_this(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    JSValue s = JS_NULL;
    if (!JS_IsNull(v)) {
        s = JS_ToString(ctx, v);
        if (JS_IsException(s)) { return s; }
        const char *c = JS_ToCString(ctx, s);
        bool valid = c && (strcmp(c, "::before") == 0 || strcmp(c, "::after") == 0 || strcmp(c, "::marker") == 0);
        if (c) { JS_FreeCString(ctx, c); }
        if (!valid) { JS_FreeValue(ctx, s); return wj_throw_dom(ctx, "SyntaxError", "Invalid pseudoElement"); }
    }
    JS_FreeValue(ctx, e->pseudo);
    e->pseudo = s;
    return fx_push(ctx, e) ? JS_UNDEFINED : JS_EXCEPTION;
}

JSValue wjr_KeyframeEffect_get_composite(JSContext *ctx, JSValueConst this_val)
{
    fx_impl *e = fx_this(ctx, this_val);
    return e ? JS_NewString(ctx, composite_names[e->composite]) : JS_EXCEPTION;
}

JSValue wjr_KeyframeEffect_set_composite(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    fx_impl *e = fx_this(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    wj_str s;
    if (!wj_to_str(ctx, v, &s, 0, "")) { return JS_EXCEPTION; }
    int i = wj_enum_index(&s, composite_names);
    wj_str_free(ctx, &s);
    if (i < 0) { return JS_UNDEFINED; }   /* an enum attribute ignores other values */
    e->composite = i;
    return fx_push(ctx, e) ? JS_UNDEFINED : JS_EXCEPTION;
}

JSValue wjr_KeyframeEffect_get_iterationComposite(JSContext *ctx, JSValueConst this_val)
{
    fx_impl *e = fx_this(ctx, this_val);
    return e ? JS_NewString(ctx, iteration_composite_names[e->iteration_composite]) : JS_EXCEPTION;
}

JSValue wjr_KeyframeEffect_set_iterationComposite(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    fx_impl *e = fx_this(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    wj_str s;
    if (!wj_to_str(ctx, v, &s, 0, "")) { return JS_EXCEPTION; }
    int i = wj_enum_index(&s, iteration_composite_names);
    wj_str_free(ctx, &s);
    if (i >= 0) { e->iteration_composite = i; }
    return JS_UNDEFINED;
}

static bool frame_copy_member(JSContext *ctx, JSValueConst key, JSValueConst value, void *opaque)
{
    JSAtom a = JS_ValueToAtom(ctx, key);
    if (a == JS_ATOM_NULL) { return false; }
    int r = JS_SetProperty(ctx, *(JSValue *)opaque, a, JS_DupValue(ctx, value));
    JS_FreeAtom(ctx, a);
    return r >= 0;
}

JSValue wjr_KeyframeEffect_getKeyframes(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    fx_impl *e = fx_this(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    uint32_t n = list_length(ctx, e->frames);
    JSValue out = JS_NewArray(ctx);
    for (uint32_t i = 0; i < n && !JS_IsException(out); i++) {
        JSValue f = JS_GetPropertyUint32(ctx, e->frames, i);
        JSValue copy = JS_NewObject(ctx);
        if (!web_for_record(ctx, f, frame_copy_member, &copy)) { JS_FreeValue(ctx, f); JS_FreeValue(ctx, copy); JS_FreeValue(ctx, out); return JS_EXCEPTION; }
        JS_FreeValue(ctx, f);
        wj_array_set(ctx, out, i, copy);
    }
    return out;
}

JSValue wjr_KeyframeEffect_setKeyframes(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    fx_impl *e = fx_this(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "KeyframeEffect.setKeyframes", 1, argc); }
    JSValue frames = keyframes_process(ctx, argv[0]);
    if (JS_IsException(frames)) { return frames; }
    JS_FreeValue(ctx, e->frames);
    e->frames = frames;
    return fx_push(ctx, e) ? JS_UNDEFINED : JS_EXCEPTION;
}

static void timing_put(JSContext *ctx, JSValue obj, const fx_timing *t, bool computed)
{
    JS_SetPropertyStr(ctx, obj, "delay", JS_NewFloat64(ctx, t->delay));
    JS_SetPropertyStr(ctx, obj, "direction", JS_NewString(ctx, direction_names[t->direction]));
    if (computed || !isnan(t->duration)) { JS_SetPropertyStr(ctx, obj, "duration", JS_NewFloat64(ctx, isnan(t->duration) ? 0 : t->duration)); }
    else { JS_SetPropertyStr(ctx, obj, "duration", JS_NewString(ctx, "auto")); }
    JS_SetPropertyStr(ctx, obj, "easing", JS_NewString(ctx, t->easing ? t->easing : "linear"));
    JS_SetPropertyStr(ctx, obj, "endDelay", JS_NewFloat64(ctx, t->end_delay));
    JS_SetPropertyStr(ctx, obj, "fill", JS_NewString(ctx, fill_names[computed && t->fill == FILL_AUTO ? 0 : t->fill]));
    JS_SetPropertyStr(ctx, obj, "iterationStart", JS_NewFloat64(ctx, t->iteration_start));
    JS_SetPropertyStr(ctx, obj, "iterations", JS_NewFloat64(ctx, t->iterations));
}

JSValue wjr_AnimationEffect_getTiming(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    fx_impl *e = fx_this(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    JSValue obj = JS_NewObject(ctx);
    if (!JS_IsException(obj)) { timing_put(ctx, obj, &e->t, false); }
    return obj;
}

static JSValue nullable(JSContext *ctx, double v) { return isnan(v) ? JS_NULL : JS_NewFloat64(ctx, v); }

JSValue wjr_AnimationEffect_getComputedTiming(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    fx_impl *e = fx_this(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    JSValue obj = JS_NewObject(ctx);
    if (JS_IsException(obj)) { return obj; }
    timing_put(ctx, obj, &e->t, true);
    double active = active_duration(&e->t);
    double end = e->t.delay + active + e->t.end_delay;
    JS_SetPropertyStr(ctx, obj, "activeDuration", JS_NewFloat64(ctx, active));
    JS_SetPropertyStr(ctx, obj, "endTime", JS_NewFloat64(ctx, end > 0 ? end : 0));
    JS_SetPropertyStr(ctx, obj, "localTime", e->anim ? nullable(ctx, wr_Animation_computedTiming(e->anim, 0)) : JS_NULL);
    JS_SetPropertyStr(ctx, obj, "progress", e->anim ? nullable(ctx, wr_Animation_computedTiming(e->anim, 1)) : JS_NULL);
    JS_SetPropertyStr(ctx, obj, "currentIteration", e->anim ? nullable(ctx, wr_Animation_computedTiming(e->anim, 2)) : JS_NULL);
    return obj;
}

JSValue wjr_AnimationEffect_updateTiming(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    fx_impl *e = fx_this(ctx, this_val);
    if (!e) { return JS_EXCEPTION; }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 0);
    if (!web_dict_check(ctx, opt, "updateTiming") || !timing_read(ctx, opt, &e->t)) { return JS_EXCEPTION; }
    return fx_push(ctx, e) ? JS_UNDEFINED : JS_EXCEPTION;
}

/* ---- the document timeline ---- */

static JSValue make_timeline(JSContext *ctx) { return wj_new_object(ctx, WJ_IFACE_DocumentTimeline, NULL, NULL); }

static JSValue document_timeline(JSContext *ctx) { return web_singleton(ctx, WEB_SINGLE_TIMELINE, make_timeline); }

JSValue wjr_Document_get_timeline(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Document)) { return JS_EXCEPTION; }
    return document_timeline(ctx);
}

/* new DocumentTimeline({originTime}): the document's timeline seen from another origin. (Animations associated with
 * one play on the document timeline: their times are not shifted.) */
typedef struct tl_impl { double origin; } tl_impl;

JSValue wjr_DocumentTimeline_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor DocumentTimeline requires 'new'"); }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 0);
    if (!web_dict_check(ctx, opt, "DocumentTimeline")) { return JS_EXCEPTION; }
    bool has;
    double origin = 0;
    if (!read_double(ctx, opt, "originTime", true, &has, &origin)) { return JS_EXCEPTION; }
    tl_impl *t = calloc(1, sizeof *t);
    if (!t) { return JS_ThrowOutOfMemory(ctx); }
    t->origin = has ? origin : 0;
    return wj_new_object_for(ctx, WJ_IFACE_DocumentTimeline, new_target, t, free);
}

JSValue wjr_AnimationTimeline_get_currentTime(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_AnimationTimeline);
    if (!o) { return JS_EXCEPTION; }
    double origin = o->impl && o->impl_free == free ? ((tl_impl *)o->impl)->origin : 0;
    return nullable(ctx, wr_DocumentTimeline_currentTime() - origin);
}

JSValue wjr_AnimationTimeline_get_duration(JSContext *ctx, JSValueConst this_val)
{
    return wj_this(ctx, this_val, WJ_IFACE_AnimationTimeline) ? JS_NULL : JS_EXCEPTION;
}

/* ---- Animation ---- */

typedef struct an_impl {
    uint64_t host;
    uint32_t slot;
    uint32_t pin;
    JSValue effect, timeline, id;
    JSValue ready, ready_fn[2];        /* the resolving functions while pending (undefined otherwise) */
    JSValue finished, finished_fn[2];
} an_impl;

/* notify slots -> the animation's wrapper (not counted; cleared when it dies) */
static JSValue *an_slots;
static uint32_t an_slots_cap;

static void an_free(void *p)
{
    an_impl *a = p;
    JSRuntime *rt = web_rt();
    if (a->slot && a->slot < an_slots_cap) { an_slots[a->slot] = JS_UNDEFINED; }
    JS_FreeValueRT(rt, a->effect);
    JS_FreeValueRT(rt, a->timeline);
    JS_FreeValueRT(rt, a->id);
    JS_FreeValueRT(rt, a->ready);
    JS_FreeValueRT(rt, a->ready_fn[0]);
    JS_FreeValueRT(rt, a->ready_fn[1]);
    JS_FreeValueRT(rt, a->finished);
    JS_FreeValueRT(rt, a->finished_fn[0]);
    JS_FreeValueRT(rt, a->finished_fn[1]);
    free(a);
}

static void an_mark(void *rt, void *p, void *mark_func)
{
    an_impl *a = p;
    wj_mark(rt, a->effect, mark_func);
    wj_mark(rt, a->timeline, mark_func);
    wj_mark(rt, a->id, mark_func);
    wj_mark(rt, a->ready, mark_func);
    wj_mark(rt, a->ready_fn[0], mark_func);
    wj_mark(rt, a->ready_fn[1], mark_func);
    wj_mark(rt, a->finished, mark_func);
    wj_mark(rt, a->finished_fn[0], mark_func);
    wj_mark(rt, a->finished_fn[1], mark_func);
}

static an_impl *an_this(JSContext *ctx, JSValueConst this_val)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Animation);
    if (!o) { return NULL; }
    if (!o->impl || o->impl_free != an_free) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o->impl;
}

static JSValue noop(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data)
{
    WJ_UNUSED(ctx); WJ_UNUSED(this_val); WJ_UNUSED(argc); WJ_UNUSED(argv); WJ_UNUSED(magic); WJ_UNUSED(data);
    return JS_UNDEFINED;
}

/* rejects with AbortError a pending promise, marked handled (Web Animations: [[PromiseIsHandled]]) */
static void reject_abort(JSContext *ctx, JSValue promise, JSValue fn[2])
{
    if (JS_IsUndefined(fn[1])) { return; }
    JSValue d = web_then(ctx, promise, NULL, noop, 0, NULL);
    JS_FreeValue(ctx, d);
    web_settle(ctx, fn[1], web_dom_exception(ctx, "AbortError", "The animation was cancelled."));
    JS_FreeValue(ctx, fn[0]);
    JS_FreeValue(ctx, fn[1]);
    fn[0] = fn[1] = JS_UNDEFINED;
}

static void resolve_with(JSContext *ctx, JSValue fn[2], JSValueConst obj)
{
    if (JS_IsUndefined(fn[0])) { return; }
    web_settle(ctx, fn[0], JS_DupValue(ctx, obj));
    JS_FreeValue(ctx, fn[0]);
    JS_FreeValue(ctx, fn[1]);
    fn[0] = fn[1] = JS_UNDEFINED;
}

static void renew(JSContext *ctx, JSValue *promise, JSValue fn[2])
{
    JS_FreeValue(ctx, *promise);
    JS_FreeValue(ctx, fn[0]);
    JS_FreeValue(ctx, fn[1]);
    fn[0] = fn[1] = JS_UNDEFINED;
    *promise = web_promise_new(ctx, fn);
}

/* Applies what the browser reported (Animation_takeOps). */
static void an_sync(JSContext *ctx, JSValueConst obj, an_impl *a)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_Animation_takeOps(a->host, wj_scratch.data, wj_scratch.cap));
    if (n <= 0) { return; }
    char ops[256];
    int32_t take = n < (int32_t)sizeof ops ? n : (int32_t)sizeof ops;
    memcpy(ops, wj_scratch.data, (size_t)take);
    wr_Animation_dropOps(a->host, take);
    for (int32_t i = 0; i < take; i++) {
        switch (ops[i]) {
        case 'r': resolve_with(ctx, a->ready_fn, obj); break;
        case 'n': renew(ctx, &a->ready, a->ready_fn); break;
        case 'R':
            reject_abort(ctx, a->ready, a->ready_fn);
            JS_FreeValue(ctx, a->ready);
            a->ready = web_promise_resolved(ctx, obj);
            break;
        case 'f': resolve_with(ctx, a->finished_fn, obj); break;
        case 'F':
            reject_abort(ctx, a->finished, a->finished_fn);
            renew(ctx, &a->finished, a->finished_fn);
            break;
        case 'm': renew(ctx, &a->finished, a->finished_fn); break;
        case 'k': if (!a->pin) { a->pin = web_pin(ctx, obj); } break;
        case 'u': if (a->pin) { web_unpin(ctx, a->pin); a->pin = 0; } break;
        default: break;
        }
    }
    if (n > take) { an_sync(ctx, obj, a); }
}

WJ_EXPORT("wj_cb_animation") void wj_cb_animation(int32_t user);

WJ_EXPORT("wj_cb_animation") void wj_cb_animation(int32_t user)
{
    JSContext *ctx = wj_the_realm.ctx;
    wj_stack_enter(ctx);
    if (user <= 0 || (uint32_t)user >= an_slots_cap || JS_IsUndefined(an_slots[user])) { return; }
    JSValue self = JS_DupValue(ctx, an_slots[user]);
    wj_obj *o = wj_obj_of(self);
    if (o && o->impl_free == an_free) { an_sync(ctx, self, o->impl); }
    JS_FreeValue(ctx, self);
}

static uint32_t slot_alloc(JSValueConst obj)
{
    for (uint32_t i = 1; i < an_slots_cap; i++) { if (JS_IsUndefined(an_slots[i])) { an_slots[i] = obj; return i; } }
    uint32_t cap = an_slots_cap ? an_slots_cap * 2 : 32;
    JSValue *s = realloc(an_slots, cap * sizeof *s);
    if (!s) { return 0; }
    for (uint32_t i = an_slots_cap; i < cap; i++) { s[i] = JS_UNDEFINED; }
    uint32_t at = an_slots_cap ? an_slots_cap : 1;
    an_slots = s;
    an_slots_cap = cap;
    an_slots[at] = obj;
    return at;
}

static JSValue an_new(JSContext *ctx, JSValueConst new_target)
{
    an_impl *a = calloc(1, sizeof *a);
    if (!a) { return JS_ThrowOutOfMemory(ctx); }
    a->effect = JS_NULL;
    a->timeline = JS_UNDEFINED;
    a->id = JS_NewString(ctx, "");
    a->ready = a->finished = JS_UNDEFINED;
    a->ready_fn[0] = a->ready_fn[1] = a->finished_fn[0] = a->finished_fn[1] = JS_UNDEFINED;
    /* the slot is reserved (null) until the wrapper exists: the browser's first report comes in a microtask after */
    a->slot = slot_alloc(JS_NULL);
    uint64_t host = wr_Animation_create((uint32_t)(uintptr_t)&wj_cb_animation, (int32_t)a->slot);
    if (!host) { an_free(a); return JS_ThrowTypeError(ctx, "Animation: no document"); }
    a->host = host;
    JSValue obj = wj_wrap_owned(ctx, host, WJ_IFACE_Animation, new_target);
    if (JS_IsException(obj)) { an_free(a); return obj; }
    web_set_impl(obj, a, an_free, an_mark);
    if (a->slot) { an_slots[a->slot] = obj; }
    a->timeline = document_timeline(ctx);
    a->ready = web_promise_resolved(ctx, obj);
    a->finished = web_promise_new(ctx, a->finished_fn);
    a->pin = web_pin(ctx, obj);
    return obj;
}

/* animation.effect = v (a KeyframeEffect, or null) */
static bool an_set_effect(JSContext *ctx, an_impl *a, JSValueConst v)
{
    fx_impl *e = JS_IsNull(v) || JS_IsUndefined(v) ? NULL : fx_of(v);
    if (!e && !JS_IsNull(v) && !JS_IsUndefined(v)) { JS_ThrowTypeError(ctx, "The provided value is not of type 'AnimationEffect'."); return false; }
    fx_impl *old = fx_of(a->effect);
    if (old == e && e) { return true; }
    if (old) { old->anim = 0; }
    JSValue prev = a->effect;
    a->effect = JS_NULL;
    if (e && e->anim && e->anim != a->host) {
        /* an effect belongs to one animation: the other one loses it */
        JSValue other = wj_cached(ctx, e->anim);
        wj_obj *oo = wj_obj_of(other);
        if (oo && oo->impl_free == an_free) {
            an_impl *b = oo->impl;
            JSValue x = b->effect;
            b->effect = JS_NULL;
            JS_FreeValue(ctx, x);
        }
        wr_Animation_clearEffect(e->anim);
        e->anim = 0;
    }
    JS_FreeValue(ctx, prev);
    if (!e) { wr_Animation_clearEffect(a->host); return true; }
    a->effect = JS_DupValue(ctx, v);
    e->anim = a->host;
    return fx_push(ctx, e);
}

static bool an_set_timeline(JSContext *ctx, an_impl *a, JSValueConst v)
{
    if (!JS_IsNull(v) && !wj_unwrap(v, WJ_IFACE_AnimationTimeline)) { JS_ThrowTypeError(ctx, "The provided value is not of type 'AnimationTimeline'."); return false; }
    JS_FreeValue(ctx, a->timeline);
    a->timeline = JS_DupValue(ctx, v);
    wr_Animation_setTimeline(a->host, !JS_IsNull(v));
    return true;
}

JSValue wjr_Animation_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Constructor Animation requires 'new'"); }
    JSValue obj = an_new(ctx, new_target);
    if (JS_IsException(obj)) { return obj; }
    an_impl *a = wj_obj_of(obj)->impl;
    JSValueConst effect = wj_arg(argc, (JSValue *)argv, 0);
    if (!an_set_effect(ctx, a, effect)) { JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    if (argc >= 2 && !JS_IsUndefined(argv[1]) && !an_set_timeline(ctx, a, argv[1])) { JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    return obj;
}

JSValue wjr_Animation_get_effect(JSContext *ctx, JSValueConst this_val)
{
    an_impl *a = an_this(ctx, this_val);
    return a ? JS_DupValue(ctx, a->effect) : JS_EXCEPTION;
}

JSValue wjr_Animation_set_effect(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    an_impl *a = an_this(ctx, this_val);
    return a && an_set_effect(ctx, a, v) ? JS_UNDEFINED : JS_EXCEPTION;
}

JSValue wjr_Animation_get_timeline(JSContext *ctx, JSValueConst this_val)
{
    an_impl *a = an_this(ctx, this_val);
    return a ? JS_DupValue(ctx, a->timeline) : JS_EXCEPTION;
}

JSValue wjr_Animation_set_timeline(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    an_impl *a = an_this(ctx, this_val);
    return a && an_set_timeline(ctx, a, v) ? JS_UNDEFINED : JS_EXCEPTION;
}

JSValue wjr_Animation_get_id(JSContext *ctx, JSValueConst this_val)
{
    an_impl *a = an_this(ctx, this_val);
    return a ? JS_DupValue(ctx, a->id) : JS_EXCEPTION;
}

JSValue wjr_Animation_set_id(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    an_impl *a = an_this(ctx, this_val);
    if (!a) { return JS_EXCEPTION; }
    JSValue s = JS_ToString(ctx, v);
    if (JS_IsException(s)) { return s; }
    JS_FreeValue(ctx, a->id);
    a->id = s;
    return JS_UNDEFINED;
}

JSValue wjr_Animation_get_playState(JSContext *ctx, JSValueConst this_val)
{
    an_impl *a = an_this(ctx, this_val);
    if (!a) { return JS_EXCEPTION; }
    int32_t s = wr_Animation_playState(a->host);
    return JS_NewString(ctx, play_state_names[s >= 0 && s < 4 ? s : 0]);
}

JSValue wjr_Animation_get_replaceState(JSContext *ctx, JSValueConst this_val)
{
    an_impl *a = an_this(ctx, this_val);
    if (!a) { return JS_EXCEPTION; }
    int32_t s = wr_Animation_replaceState(a->host);
    return JS_NewString(ctx, replace_state_names[s >= 0 && s < 3 ? s : 0]);
}

JSValue wjr_Animation_get_ready(JSContext *ctx, JSValueConst this_val)
{
    an_impl *a = an_this(ctx, this_val);
    if (!a) { return JS_EXCEPTION; }
    an_sync(ctx, this_val, a);
    return JS_DupValue(ctx, a->ready);
}

JSValue wjr_Animation_get_finished(JSContext *ctx, JSValueConst this_val)
{
    an_impl *a = an_this(ctx, this_val);
    if (!a) { return JS_EXCEPTION; }
    an_sync(ctx, this_val, a);
    return JS_DupValue(ctx, a->finished);
}

/* CSSNumberish? as a double (CSS Typed OM values are not supported: a number) ; NaN for null */
static bool numberish(JSContext *ctx, JSValueConst v, double *out)
{
    if (JS_IsNull(v)) { *out = NAN; return true; }
    if (!wj_to_double(ctx, v, out, false)) { return false; }
    if (!isfinite(*out)) { JS_ThrowTypeError(ctx, "The provided double value is non-finite."); return false; }
    return true;
}

JSValue wjr_Animation_get_startTime(JSContext *ctx, JSValueConst this_val)
{
    an_impl *a = an_this(ctx, this_val);
    return a ? nullable(ctx, wr_Animation_startTime(a->host)) : JS_EXCEPTION;
}

JSValue wjr_Animation_set_startTime(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    an_impl *a = an_this(ctx, this_val);
    double d;
    if (!a || !numberish(ctx, v, &d)) { return JS_EXCEPTION; }
    wr_Animation_set_startTime(a->host, d);
    return JS_UNDEFINED;
}

JSValue wjr_Animation_get_currentTime(JSContext *ctx, JSValueConst this_val)
{
    an_impl *a = an_this(ctx, this_val);
    return a ? nullable(ctx, wr_Animation_currentTime(a->host)) : JS_EXCEPTION;
}

JSValue wjr_Animation_set_currentTime(JSContext *ctx, JSValueConst this_val, JSValueConst v)
{
    an_impl *a = an_this(ctx, this_val);
    double d;
    if (!a || !numberish(ctx, v, &d)) { return JS_EXCEPTION; }
    int32_t st = wr_Animation_set_currentTime(a->host, d);
    return st < 0 ? wj_throw_status(ctx, st, "Animation.currentTime") : JS_UNDEFINED;
}

JSValue wjr_Animation_get_overallProgress(JSContext *ctx, JSValueConst this_val)
{
    an_impl *a = an_this(ctx, this_val);
    if (!a) { return JS_EXCEPTION; }
    fx_impl *e = fx_of(a->effect);
    double cur = wr_Animation_currentTime(a->host);
    if (!e || isnan(cur)) { return JS_NULL; }
    double end = e->t.delay + active_duration(&e->t) + e->t.end_delay;
    if (end <= 0) { return JS_NewFloat64(ctx, cur < 0 ? 0 : 1); }
    if (isinf(end)) { return JS_NewFloat64(ctx, 0); }
    double p = cur / end;
    return JS_NewFloat64(ctx, p < 0 ? 0 : p > 1 ? 1 : p);
}

/* ---- Element.animate, getAnimations ---- */

JSValue wjr_Animatable_animate(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Element)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Element.animate", 1, argc); }
    JSValueConst options = wj_arg(argc, (JSValue *)argv, 1);
    JSValue effect = fx_new(ctx, JS_UNDEFINED, this_val, argv[0], options);
    if (JS_IsException(effect)) { return effect; }
    JSValue id = JS_UNDEFINED, timeline = JS_UNDEFINED;
    if (JS_IsObject(options)) {
        if (!web_dict_get(ctx, options, "id", &id) || !web_dict_get(ctx, options, "timeline", &timeline)) {
            JS_FreeValue(ctx, id);
            JS_FreeValue(ctx, effect);
            return JS_EXCEPTION;
        }
    }
    JSValue obj = an_new(ctx, JS_UNDEFINED);
    if (JS_IsException(obj)) { JS_FreeValue(ctx, id); JS_FreeValue(ctx, timeline); JS_FreeValue(ctx, effect); return obj; }
    an_impl *a = wj_obj_of(obj)->impl;
    bool ok = an_set_effect(ctx, a, effect);
    JS_FreeValue(ctx, effect);
    if (ok && !JS_IsUndefined(id)) {
        JSValue s = JS_ToString(ctx, id);
        if (JS_IsException(s)) { ok = false; } else { JS_FreeValue(ctx, a->id); a->id = s; }
    }
    if (ok && !JS_IsUndefined(timeline)) { ok = an_set_timeline(ctx, a, timeline); }
    JS_FreeValue(ctx, id);
    JS_FreeValue(ctx, timeline);
    if (ok) {
        int32_t st = wr_Animation_play(a->host);
        if (st < 0) { wj_throw_status(ctx, st, "Element.animate"); ok = false; }
    }
    if (!ok) { JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    return obj;
}

/* The wrapper of a CSS animation or transition the browser listed (CSSAnimation / CSSTransition): an Animation whose
 * effect is a KeyframeEffect on its target with its timing (no keyframes of its own: the style timeline runs it).
 * Undefined when the handle is not a CSS one. */
static JSValue css_wrap(JSContext *ctx, uint64_t host)
{
    an_impl *a = calloc(1, sizeof *a);
    if (!a) { return JS_ThrowOutOfMemory(ctx); }
    a->effect = JS_NULL;
    a->timeline = JS_UNDEFINED;
    a->id = JS_NewString(ctx, "");
    a->ready = a->finished = JS_UNDEFINED;
    a->ready_fn[0] = a->ready_fn[1] = a->finished_fn[0] = a->finished_fn[1] = JS_UNDEFINED;
    a->slot = slot_alloc(JS_NULL);
    wr_CssAnimationInfo info = { 0 };
    wr_Animation_cssBind(host, (uint32_t)(uintptr_t)&wj_cb_animation, (int32_t)a->slot, &info);
    if (info.kind != 1 && info.kind != 2) { an_free(a); return JS_UNDEFINED; }
    a->host = host;
    JSValue obj = wj_wrap_owned(ctx, host, info.kind == 1 ? WJ_IFACE_CSSAnimation : WJ_IFACE_CSSTransition, JS_UNDEFINED);
    if (JS_IsException(obj)) { an_free(a); return obj; }
    web_set_impl(obj, a, an_free, an_mark);
    if (a->slot) { an_slots[a->slot] = obj; }
    a->timeline = document_timeline(ctx);
    a->ready = web_promise_resolved(ctx, obj);
    a->finished = web_promise_new(ctx, a->finished_fn);
    JSValue target = wj_wrap_node(ctx, info.target);
    if (JS_IsException(target)) { JS_FreeValue(ctx, JS_GetException(ctx)); target = JS_NULL; }
    JSValue fx = fx_new(ctx, JS_UNDEFINED, target, JS_NULL, JS_UNDEFINED);
    JS_FreeValue(ctx, target);
    if (JS_IsException(fx)) { JS_FreeValue(ctx, JS_GetException(ctx)); return obj; }
    fx_impl *e = fx_of(fx);
    e->t.delay = info.delay;
    e->t.duration = info.duration;
    e->t.iterations = info.iterations;
    a->effect = fx;   /* (not pushed: e->anim stays 0, the browser keeps no script effect for it) */
    return obj;
}

static JSValue css_name(JSContext *ctx, JSValueConst this_val, int iface)
{
    wj_obj *o = wj_this(ctx, this_val, iface);
    if (!o) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Animation_cssName(o->handle, wj_scratch.data, wj_scratch.cap));
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
}

JSValue wjr_CSSAnimation_get_animationName(JSContext *ctx, JSValueConst this_val) { return css_name(ctx, this_val, WJ_IFACE_CSSAnimation); }
JSValue wjr_CSSTransition_get_transitionProperty(JSContext *ctx, JSValueConst this_val) { return css_name(ctx, this_val, WJ_IFACE_CSSTransition); }

static JSValue relevant_list(JSContext *ctx, uint64_t root, bool subtree)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_Animation_relevant(root, subtree, wj_scratch.data, wj_scratch.cap));
    if (n < 0) { return wj_throw_status(ctx, n, "getAnimations"); }
    uint32_t count = (uint32_t)n / 8;
    uint64_t *hs = malloc((count ? count : 1) * sizeof *hs);
    if (!hs) { return JS_ThrowOutOfMemory(ctx); }
    for (uint32_t i = 0; i < count; i++) {
        uint64_t v = 0;
        for (int k = 7; k >= 0; k--) { v = (v << 8) | wj_scratch.data[i * 8 + (uint32_t)k]; }
        hs[i] = v;
    }
    JSValue out = JS_NewArray(ctx);
    uint32_t at = 0;
    for (uint32_t i = 0; i < count && !JS_IsException(out); i++) {
        JSValue w = wj_cached(ctx, hs[i]);
        if (JS_IsObject(w)) { wj_array_set(ctx, out, at++, JS_DupValue(ctx, w)); continue; }
        w = css_wrap(ctx, hs[i]);   /* a CSS animation or transition seen for the first time */
        if (JS_IsException(w)) { JS_FreeValue(ctx, out); out = JS_EXCEPTION; break; }
        if (JS_IsObject(w)) { wj_array_set(ctx, out, at++, w); }
    }
    free(hs);
    return out;
}

JSValue wjr_Animatable_getAnimations(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_Element);
    if (!o) { return JS_EXCEPTION; }
    JSValueConst opt = wj_arg(argc, (JSValue *)argv, 0);
    if (!web_dict_check(ctx, opt, "getAnimations")) { return JS_EXCEPTION; }
    JSValue v;
    if (!web_dict_get(ctx, opt, "subtree", &v)) { return JS_EXCEPTION; }
    bool subtree = JS_ToBool(ctx, v);
    JS_FreeValue(ctx, v);
    return relevant_list(ctx, o->handle, subtree);
}

JSValue wjr_DocumentOrShadowRoot_getAnimations(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (wj_unwrap(this_val, WJ_IFACE_Document)) { return relevant_list(ctx, 0, true); }
    wj_obj *o = wj_this(ctx, this_val, WJ_IFACE_ShadowRoot);
    if (!o) { return JS_EXCEPTION; }
    return relevant_list(ctx, o->handle, true);
}

/* ---- events ---- */

static JSValue event_time(JSContext *ctx, JSValueConst this_val, const char *name, int which)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_AnimationPlaybackEvent)) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, name);
    if (!JS_IsUndefined(v)) { return v; }
    uint64_t h = web_event_host(this_val);
    return h ? nullable(ctx, wr_AnimationPlaybackEvent_time(h, which)) : JS_NULL;
}

JSValue wjr_AnimationPlaybackEvent_get_currentTime(JSContext *ctx, JSValueConst this_val) { return event_time(ctx, this_val, "currentTime", 0); }
JSValue wjr_AnimationPlaybackEvent_get_timelineTime(JSContext *ctx, JSValueConst this_val) { return event_time(ctx, this_val, "timelineTime", 1); }

static bool init_member(JSContext *ctx, JSValueConst ev, JSValueConst init, const char *name, int kind)
{
    JSValue v;
    if (!web_dict_get(ctx, init, name, &v)) { return false; }
    JSValue out;
    switch (kind) {
    case 0: {   /* double? = null */
        double d = NAN;
        if (!JS_IsUndefined(v) && !JS_IsNull(v) && !wj_to_double(ctx, v, &d, true)) { JS_FreeValue(ctx, v); return false; }
        out = JS_IsUndefined(v) || JS_IsNull(v) ? JS_NULL : JS_NewFloat64(ctx, d);
        break;
    }
    case 1: {   /* double = 0 */
        double d = 0;
        if (!JS_IsUndefined(v) && !wj_to_double(ctx, v, &d, true)) { JS_FreeValue(ctx, v); return false; }
        out = JS_NewFloat64(ctx, d);
        break;
    }
    default:    /* DOMString = "" */
        out = JS_IsUndefined(v) ? JS_NewString(ctx, "") : JS_ToString(ctx, v);
        if (JS_IsException(out)) { JS_FreeValue(ctx, v); return false; }
        break;
    }
    JS_FreeValue(ctx, v);
    return web_extra_set(ctx, ev, name, out);
}

JSValue wjr_AnimationPlaybackEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue ev = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_AnimationPlaybackEvent, "AnimationPlaybackEvent");
    if (JS_IsException(ev)) { return ev; }
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 1);
    if (!init_member(ctx, ev, init, "currentTime", 0) || !init_member(ctx, ev, init, "timelineTime", 0)) { JS_FreeValue(ctx, ev); return JS_EXCEPTION; }
    return ev;
}

/* AnimationEvent / TransitionEvent of the browser (page/animations.odin): Event_data the name, Event_code the elapsed
 * time in microseconds, Event_text the pseudo-element */
static JSValue host_event_string(JSContext *ctx, JSValueConst this_val, int iface, const char *name, bool text)
{
    if (!wj_this(ctx, this_val, iface)) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, name);
    if (!JS_IsUndefined(v)) { return v; }
    uint64_t h = web_event_host(this_val);
    if (!h) { return JS_NewString(ctx, ""); }
    int32_t n;
    if (text) { WJ_FETCH_STRING(n, wr_Event_text(h, wj_scratch.data, wj_scratch.cap)); }
    else { WJ_FETCH_STRING(n, wr_Event_data(h, wj_scratch.data, wj_scratch.cap)); }
    return n > 0 ? JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n) : JS_NewString(ctx, "");
}

static JSValue host_event_elapsed(JSContext *ctx, JSValueConst this_val, int iface)
{
    if (!wj_this(ctx, this_val, iface)) { return JS_EXCEPTION; }
    JSValue v = web_extra_get(ctx, this_val, "elapsedTime");
    if (!JS_IsUndefined(v)) { return v; }
    uint64_t h = web_event_host(this_val);
    return JS_NewFloat64(ctx, h ? (double)wr_Event_code(h) / 1e6 : 0);
}

JSValue wjr_AnimationEvent_get_animationName(JSContext *ctx, JSValueConst this_val) { return host_event_string(ctx, this_val, WJ_IFACE_AnimationEvent, "animationName", false); }
JSValue wjr_AnimationEvent_get_pseudoElement(JSContext *ctx, JSValueConst this_val) { return host_event_string(ctx, this_val, WJ_IFACE_AnimationEvent, "pseudoElement", true); }
JSValue wjr_AnimationEvent_get_elapsedTime(JSContext *ctx, JSValueConst this_val) { return host_event_elapsed(ctx, this_val, WJ_IFACE_AnimationEvent); }
JSValue wjr_TransitionEvent_get_propertyName(JSContext *ctx, JSValueConst this_val) { return host_event_string(ctx, this_val, WJ_IFACE_TransitionEvent, "propertyName", false); }
JSValue wjr_TransitionEvent_get_pseudoElement(JSContext *ctx, JSValueConst this_val) { return host_event_string(ctx, this_val, WJ_IFACE_TransitionEvent, "pseudoElement", true); }
JSValue wjr_TransitionEvent_get_elapsedTime(JSContext *ctx, JSValueConst this_val) { return host_event_elapsed(ctx, this_val, WJ_IFACE_TransitionEvent); }

JSValue wjr_AnimationEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue ev = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_AnimationEvent, "AnimationEvent");
    if (JS_IsException(ev)) { return ev; }
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 1);
    if (!init_member(ctx, ev, init, "animationName", 2) || !init_member(ctx, ev, init, "elapsedTime", 1) || !init_member(ctx, ev, init, "pseudoElement", 2)) { JS_FreeValue(ctx, ev); return JS_EXCEPTION; }
    return ev;
}

JSValue wjr_TransitionEvent_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    JSValue ev = wj_event_construct(ctx, new_target, argc, argv, WJ_IFACE_TransitionEvent, "TransitionEvent");
    if (JS_IsException(ev)) { return ev; }
    JSValueConst init = wj_arg(argc, (JSValue *)argv, 1);
    if (!init_member(ctx, ev, init, "propertyName", 2) || !init_member(ctx, ev, init, "elapsedTime", 1) || !init_member(ctx, ev, init, "pseudoElement", 2)) { JS_FreeValue(ctx, ev); return JS_EXCEPTION; }
    return ev;
}
