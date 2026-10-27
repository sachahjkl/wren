/* web_clipboard.c: navigator.clipboard (Clipboard API) and ClipboardItem, native. writeText / readText are browser
 * functions (module navigator: Clipboard_writeText, Clipboard_readText); read / write and ClipboardItem are built here
 * on top of them, in place of the old prelude/clipboard.js. Only text/plain goes through the system clipboard: an item
 * with another type is accepted, but write() keeps text/plain and rejects when there is none (NotAllowedError, as for a
 * type the browser cannot put on the clipboard), and read() gives one item with the clipboard's text.
 *
 * ClipboardItem keeps its data on a non-enumerable own property `_s`: a plain object { map, types, style } where `map`
 * is the engine's Map (type -> a Promise), exactly as the JavaScript kept it on a WeakMap. */
#include <stdio.h>
#include <stdlib.h>
#include "web.h"

static JSValue global_prop(JSContext *ctx, const char *name) { return JS_GetPropertyStr(ctx, wj_the_realm.global, name); }

/* ---- ClipboardItem state ---- */

static const char *const PRESENTATION_STYLES[] = { "unspecified", "inline", "attachment", NULL };

/* the `_s` object of a ClipboardItem, or NULL + TypeError ("Illegal invocation") on the wrong receiver */
static JSValue ci_state(JSContext *ctx, JSValueConst item)
{
    JSValue s = JS_GetPropertyStr(ctx, item, "_s");
    if (!JS_IsObject(s)) { JS_FreeValue(ctx, s); return JS_ThrowTypeError(ctx, "Illegal invocation"); }
    return s;
}

/* ClipboardItem(items, options) */
static JSValue ci_ctor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Please use the 'new' operator, this object constructor cannot be called as a function."); }
    if (argc < 1) { return JS_ThrowTypeError(ctx, "Failed to construct 'ClipboardItem': 1 argument required, but only 0 present."); }
    JSValueConst items = argv[0];
    if (JS_IsNull(items) || !JS_IsObject(items)) { return JS_ThrowTypeError(ctx, "Failed to construct 'ClipboardItem': The provided value is not of type 'record<DOMString, ClipboardItemData>'."); }
    /* Object.keys(items) */
    JSValue objc = global_prop(ctx, "Object");
    JSValue keysfn = JS_GetPropertyStr(ctx, objc, "keys");
    JSValue keys = JS_Call(ctx, keysfn, objc, 1, (JSValueConst *)&items);
    JS_FreeValue(ctx, keysfn); JS_FreeValue(ctx, objc);
    if (JS_IsException(keys)) { return keys; }
    uint32_t nkeys = 0; JSValue klen = JS_GetPropertyStr(ctx, keys, "length"); JS_ToUint32(ctx, &nkeys, klen); JS_FreeValue(ctx, klen);
    if (nkeys == 0) { JS_FreeValue(ctx, keys); return JS_ThrowTypeError(ctx, "Failed to construct 'ClipboardItem': At least one entry must be provided"); }

    char *style = NULL;
    JSValueConst options = wj_arg(argc, (JSValue *)argv, 1);
    if (!JS_IsUndefined(options) && !JS_IsNull(options)) {
        if (!JS_IsObject(options)) { JS_FreeValue(ctx, keys); return JS_ThrowTypeError(ctx, "Failed to construct 'ClipboardItem': The provided value is not of type 'ClipboardItemOptions'."); }
        JSValue ps = JS_GetPropertyStr(ctx, options, "presentationStyle");
        if (!JS_IsUndefined(ps)) {
            const char *s = JS_ToCString(ctx, ps);
            bool ok = false;
            for (const char *const *p = PRESENTATION_STYLES; *p; p++) { if (s && strcmp(*p, s) == 0) { ok = true; break; } }
            if (!ok) { JSValue e = JS_ThrowTypeError(ctx, "Failed to construct 'ClipboardItem': The provided value '%s' is not a valid enum value of type PresentationStyle.", s ? s : ""); if (s) { JS_FreeCString(ctx, s); } JS_FreeValue(ctx, ps); JS_FreeValue(ctx, keys); return e; }
            style = web_strndup(s, strlen(s));
            JS_FreeCString(ctx, s);
        }
        JS_FreeValue(ctx, ps);
    }

    /* map = new Map(); for (k of keys) map.set(String(k), Promise.resolve(items[k])) */
    JSValue mapc = global_prop(ctx, "Map");
    JSValue map = JS_CallConstructor(ctx, mapc, 0, NULL);
    JS_FreeValue(ctx, mapc);
    JSValue mapset = JS_GetPropertyStr(ctx, map, "set");
    JSValue promisec = global_prop(ctx, "Promise");
    JSValue resolve = JS_GetPropertyStr(ctx, promisec, "resolve");
    /* types: a plain array of the string keys, frozen */
    JSValue types = JS_NewArray(ctx);
    for (uint32_t i = 0; i < nkeys; i++) {
        JSValue kv = JS_GetPropertyUint32(ctx, keys, i);
        JSValue ks = JS_ToString(ctx, kv);
        JS_FreeValue(ctx, kv);
        JSAtom ka = JS_ValueToAtom(ctx, ks);
        JSValue val = JS_GetProperty(ctx, items, ka);
        JS_FreeAtom(ctx, ka);
        JSValue p = JS_Call(ctx, resolve, promisec, 1, (JSValueConst *)&val);
        JS_FreeValue(ctx, val);
        JSValueConst setargs[2] = { ks, p };
        JSValue sr = JS_Call(ctx, mapset, map, 2, setargs);
        JS_FreeValue(ctx, sr); JS_FreeValue(ctx, p);
        JS_SetPropertyUint32(ctx, types, i, JS_DupValue(ctx, ks));
        JS_FreeValue(ctx, ks);
    }
    JS_FreeValue(ctx, resolve); JS_FreeValue(ctx, promisec); JS_FreeValue(ctx, mapset); JS_FreeValue(ctx, keys);
    web_freeze(ctx, types);

    /* the object from new.target's prototype */
    JSValue proto = JS_GetPropertyStr(ctx, new_target, "prototype");
    JSValue obj = JS_IsObject(proto) ? JS_NewObjectProto(ctx, proto) : JS_NewObject(ctx);
    JS_FreeValue(ctx, proto);
    JSValue s = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, s, "map", map);
    JS_SetPropertyStr(ctx, s, "types", types);
    JS_SetPropertyStr(ctx, s, "style", JS_NewString(ctx, style ? style : "unspecified"));
    free(style);
    JS_DefinePropertyValueStr(ctx, obj, "_s", s, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
    return obj;
}

static JSValue ci_get_presentation_style(JSContext *ctx, JSValueConst this_val)
{
    JSValue s = ci_state(ctx, this_val);
    if (JS_IsException(s)) { return s; }
    JSValue v = JS_GetPropertyStr(ctx, s, "style");
    JS_FreeValue(ctx, s);
    return v;
}
static JSValue ci_get_types(JSContext *ctx, JSValueConst this_val)
{
    JSValue s = ci_state(ctx, this_val);
    if (JS_IsException(s)) { return s; }
    JSValue v = JS_GetPropertyStr(ctx, s, "types");
    JS_FreeValue(ctx, s);
    return v;
}

/* getType(type): p.then(v => typeof v === "string" ? new Blob([v], {type}) : v). `data` = [type string]. */
static JSValue ci_get_type_then(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic);
    JSValueConst v = wj_arg(argc, (JSValue *)argv, 0);
    if (JS_IsString(v)) {
        const char *sv = JS_ToCString(ctx, v);
        const char *type = JS_ToCString(ctx, data[0]);
        JSValue blob = web_blob_new(ctx, (const uint8_t *)(sv ? sv : ""), sv ? strlen(sv) : 0, type ? type : "", type ? strlen(type) : 0);
        if (sv) { JS_FreeCString(ctx, sv); }
        if (type) { JS_FreeCString(ctx, type); }
        return blob;
    }
    return JS_DupValue(ctx, v);
}
static JSValue ci_get_type(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSValue s = JS_GetPropertyStr(ctx, this_val, "_s");
    if (!JS_IsObject(s)) { JS_FreeValue(ctx, s); return web_promise_rejected(ctx, web_type_error(ctx, "Illegal invocation")); }
    JSValue type = JS_ToString(ctx, wj_arg(argc, (JSValue *)argv, 0));
    JSValue map = JS_GetPropertyStr(ctx, s, "map");
    JSValue get = JS_GetPropertyStr(ctx, map, "get");
    JSValue p = JS_Call(ctx, get, map, 1, (JSValueConst *)&type);
    JS_FreeValue(ctx, get); JS_FreeValue(ctx, map); JS_FreeValue(ctx, s);
    if (JS_IsUndefined(p)) {
        JS_FreeValue(ctx, p); JS_FreeValue(ctx, type);
        return web_promise_rejected(ctx, web_dom_exception(ctx, "NotFoundError", "Failed to execute 'getType' on 'ClipboardItem': The type was not found"));
    }
    JSValueConst reactdata[1] = { type };
    JSValue r = web_then(ctx, p, ci_get_type_then, NULL, 1, reactdata);
    JS_FreeValue(ctx, p); JS_FreeValue(ctx, type);
    return r;
}
static JSValue ci_supports(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    const char *s = JS_ToCString(ctx, wj_arg(argc, (JSValue *)argv, 0));
    char *low = s ? web_strndup(s, strlen(s)) : NULL;
    if (low) { web_ascii_lower(low, strlen(low)); }
    bool ok = low && strcmp(low, "text/plain") == 0;
    if (s) { JS_FreeCString(ctx, s); }
    free(low);
    return JS_NewBool(ctx, ok);
}

/* ---- the native class and its install at pre-initialization ---- */

static JSValue clipboarditem_ctor_obj;   /* kept to recognise a ClipboardItem in write() */

static void wj_install_clipboard(JSContext *ctx)
{
    JSValue proto = JS_NewObject(ctx);
    static const JSCFunctionListEntry ci_proto[] = {
        JS_CGETSET_DEF("presentationStyle", ci_get_presentation_style, NULL),
        JS_CGETSET_DEF("types", ci_get_types, NULL),
        JS_CFUNC_DEF("getType", 1, ci_get_type),
    };
    JS_SetPropertyFunctionList(ctx, proto, ci_proto, (int)WEB_COUNT(ci_proto));
    /* Symbol.toStringTag = "ClipboardItem" */
    JSValue sym = global_prop(ctx, "Symbol");
    JSValue tts = JS_GetPropertyStr(ctx, sym, "toStringTag");
    JSAtom ta = JS_ValueToAtom(ctx, tts);
    JS_DefinePropertyValue(ctx, proto, ta, JS_NewString(ctx, "ClipboardItem"), JS_PROP_CONFIGURABLE);
    JS_FreeAtom(ctx, ta); JS_FreeValue(ctx, tts); JS_FreeValue(ctx, sym);

    JSValue ctor = JS_NewCFunction2(ctx, (JSCFunction *)ci_ctor, "ClipboardItem", 1, JS_CFUNC_constructor, 0);
    JS_SetConstructor(ctx, ctor, proto);
    JS_DefinePropertyValueStr(ctx, ctor, "prototype", JS_DupValue(ctx, proto), 0);
    JS_DefinePropertyValueStr(ctx, ctor, "supports", JS_NewCFunction(ctx, ci_supports, "supports", 1), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
    JS_FreeValue(ctx, proto);

    clipboarditem_ctor_obj = JS_DupValue(ctx, ctor);
    JS_DefinePropertyValueStr(ctx, wj_the_realm.global, "ClipboardItem", ctor, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
}

/* whether `v` is a ClipboardItem of this realm (has our prototype with an `_s`) */
static bool is_clipboard_item(JSContext *ctx, JSValueConst v)
{
    if (!JS_IsObject(v)) { return false; }
    JSValue proto = JS_GetPropertyStr(ctx, clipboarditem_ctor_obj, "prototype");
    JSValue vproto = JS_GetPrototype(ctx, v);
    bool same = JS_VALUE_GET_PTR(proto) == JS_VALUE_GET_PTR(vproto);
    JS_FreeValue(ctx, proto); JS_FreeValue(ctx, vproto);
    if (!same) { return false; }
    JSValue s = JS_GetPropertyStr(ctx, v, "_s");
    bool ok = JS_IsObject(s);
    JS_FreeValue(ctx, s);
    return ok;
}

/* ---- navigator.clipboard ---- */

static JSValue make_clipboard(JSContext *ctx) { return wj_new_object(ctx, WJ_IFACE_Clipboard, NULL, NULL); }

JSValue wjr_Navigator_get_clipboard(JSContext *ctx, JSValueConst this_val)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Navigator)) { return JS_EXCEPTION; }
    return web_singleton(ctx, WEB_SINGLE_CLIPBOARD, make_clipboard);
}

/* readText() natively (host promise of text), as the generated glue does */
static JSValue clipboard_read_text(JSContext *ctx)
{
    uint64_t r = wr_Clipboard_readText();
    return wj_promise_from_host(ctx, r, WJ_HOST_TEXT, NULL, JS_UNDEFINED);
}
static JSValue clipboard_write_text(JSContext *ctx, const char *text, size_t len)
{
    uint64_t r = wr_Clipboard_writeText((const uint8_t *)(text ? text : ""), (uint32_t)len);
    return wj_promise_from_host(ctx, r, WJ_HOST_UNDEFINED, NULL, JS_UNDEFINED);
}

/* read(): readText().then(text => text === "" ? [] : [new ClipboardItem({"text/plain": new Blob([text], {type})})]) */
static JSValue read_then(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic); WJ_UNUSED(data);
    const char *text = JS_ToCString(ctx, wj_arg(argc, (JSValue *)argv, 0));
    size_t tlen = text ? strlen(text) : 0;
    JSValue arr = JS_NewArray(ctx);
    if (text && tlen > 0) {
        JSValue blob = web_blob_new(ctx, (const uint8_t *)text, tlen, "text/plain", 10);
        JSValue items = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, items, "text/plain", blob);
        JSValueConst cargs[1] = { items };
        JSValue item = ci_ctor(ctx, clipboarditem_ctor_obj, 1, cargs);
        JS_FreeValue(ctx, items);
        JS_SetPropertyUint32(ctx, arr, 0, item);
    }
    if (text) { JS_FreeCString(ctx, text); }
    return arr;
}

JSValue wjr_Clipboard_read(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    if (!wj_this(ctx, this_val, WJ_IFACE_Clipboard)) { return web_promise_reject_pending(ctx); }
    JSValue p = clipboard_read_text(ctx);
    JSValue r = web_then(ctx, p, read_then, NULL, 0, NULL);
    JS_FreeValue(ctx, p);
    return r;
}

/* write(): the second stage, text in hand -> writeText(text). */
static JSValue write_text_then(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic); WJ_UNUSED(data);
    JSValueConst v = wj_arg(argc, (JSValue *)argv, 0);
    const char *text = JS_ToCString(ctx, v);
    JSValue r = clipboard_write_text(ctx, text, text ? strlen(text) : 0);
    if (text) { JS_FreeCString(ctx, text); }
    return r;
}
/* write(): the first stage, a text/plain promise's value -> its text (typeof v === "string" ? v : v.text()). */
static JSValue write_value_then(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data)
{
    WJ_UNUSED(this_val); WJ_UNUSED(magic); WJ_UNUSED(data);
    JSValueConst v = wj_arg(argc, (JSValue *)argv, 0);
    if (JS_IsString(v)) { return JS_DupValue(ctx, v); }
    /* v.text() (a Blob) -> a promise of a string */
    JSValue textfn = JS_GetPropertyStr(ctx, v, "text");
    JSValue r = JS_Call(ctx, textfn, v, 0, NULL);
    JS_FreeValue(ctx, textfn);
    return r;
}

/* collect the items of an iterable into an array; each must be a ClipboardItem. */
typedef struct { JSContext *ctx; JSValue list; uint32_t n; bool bad; } write_collect;
static bool write_collect_one(JSContext *ctx, JSValueConst item, void *opaque)
{
    write_collect *w = opaque;
    if (!is_clipboard_item(ctx, item)) {
        w->bad = true;
        JS_ThrowTypeError(ctx, "Failed to execute 'write' on 'Clipboard': Failed to read the 'ClipboardItem' sequence: Failed to convert element to 'ClipboardItem'.");
        return false;
    }
    JS_SetPropertyUint32(ctx, w->list, w->n++, JS_DupValue(ctx, item));
    return true;
}

JSValue wjr_Clipboard_write(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Clipboard)) { return web_promise_reject_pending(ctx); }
    if (argc < 1) { JS_ThrowTypeError(ctx, "Failed to execute 'write' on 'Clipboard': 1 argument required, but only 0 present."); return web_promise_reject_pending(ctx); }
    JSValueConst items = argv[0];
    int it = JS_IsObject(items) ? web_is_iterable(ctx, items) : 0;
    if (it <= 0) {
        if (it < 0) { return web_promise_reject_pending(ctx); }
        return web_promise_rejected(ctx, web_type_error(ctx, "Failed to execute 'write' on 'Clipboard': The provided value cannot be converted to a sequence."));
    }
    write_collect w = { ctx, JS_NewArray(ctx), 0, false };
    if (!web_for_of(ctx, items, write_collect_one, &w)) {
        JS_FreeValue(ctx, w.list);
        return web_promise_reject_pending(ctx);
    }
    if (w.n != 1) {
        JSValue e = web_dom_exception(ctx, "NotAllowedError", w.n == 0 ? "Failed to execute 'write' on 'Clipboard': There is no item to write." : "Failed to execute 'write' on 'Clipboard': Support for multiple ClipboardItems is not implemented.");
        JS_FreeValue(ctx, w.list);
        return web_promise_rejected(ctx, e);
    }
    JSValue item0 = JS_GetPropertyUint32(ctx, w.list, 0);
    JS_FreeValue(ctx, w.list);
    JSValue s = JS_GetPropertyStr(ctx, item0, "_s");
    JSValue map = JS_GetPropertyStr(ctx, s, "map");
    JSValue get = JS_GetPropertyStr(ctx, map, "get");
    JSValueConst plainkey = JS_NewString(ctx, "text/plain");
    JSValue plain = JS_Call(ctx, get, map, 1, &plainkey);
    JS_FreeValue(ctx, (JSValue)plainkey); JS_FreeValue(ctx, get);
    if (JS_IsUndefined(plain)) {
        JS_FreeValue(ctx, plain);
        /* the error names the first type: Array.from(st.map.keys())[0] */
        JSValue keysfn = JS_GetPropertyStr(ctx, map, "keys");
        JSValue keysit = JS_Call(ctx, keysfn, map, 0, NULL);
        JS_FreeValue(ctx, keysfn);
        JSValue arrayc = global_prop(ctx, "Array");
        JSValue from = JS_GetPropertyStr(ctx, arrayc, "from");
        JSValue keysarr = JS_Call(ctx, from, arrayc, 1, (JSValueConst *)&keysit);
        JS_FreeValue(ctx, from); JS_FreeValue(ctx, arrayc); JS_FreeValue(ctx, keysit);
        JSValue first = JS_GetPropertyUint32(ctx, keysarr, 0);
        const char *t = JS_ToCString(ctx, first);
        char msg[160];
        snprintf(msg, sizeof msg, "Failed to execute 'write' on 'Clipboard': Type %s does not match the blob's type or is not supported.", t ? t : "");
        if (t) { JS_FreeCString(ctx, t); }
        JS_FreeValue(ctx, first); JS_FreeValue(ctx, keysarr);
        JS_FreeValue(ctx, map); JS_FreeValue(ctx, s); JS_FreeValue(ctx, item0);
        return web_promise_rejected(ctx, web_dom_exception(ctx, "NotAllowedError", msg));
    }
    JS_FreeValue(ctx, map); JS_FreeValue(ctx, s); JS_FreeValue(ctx, item0);
    JSValue stage1 = web_then(ctx, plain, write_value_then, NULL, 0, NULL);
    JS_FreeValue(ctx, plain);
    if (JS_IsException(stage1)) { return web_promise_reject_pending(ctx); }
    JSValue r = web_then(ctx, stage1, write_text_then, NULL, 0, NULL);
    JS_FreeValue(ctx, stage1);
    return r;
}

int web_clipboard_preinit(JSContext *ctx)
{
    wj_install_clipboard(ctx);
    return 0;
}

/* ClipboardItem is created at pre-initialization (shared image): a worker's realm, or a document that is not a secure
 * context (SecureContext, Exposed=Window), does not have it */
int web_clipboard_start(JSContext *ctx, int kind)
{
    WJ_UNUSED(kind);
    if (web_is_window() && wr_Window_isSecureContext()) { return 0; }
    JSAtom a = JS_NewAtom(ctx, "ClipboardItem");
    JS_DeleteProperty(ctx, wj_the_realm.global, a, 0);
    JS_FreeAtom(ctx, a);
    return 0;
}
