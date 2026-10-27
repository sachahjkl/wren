/* web_navigator.c: navigator (HTML Navigator, WorkerNavigator) and navigator.sendBeacon (Beacon).
 *
 * The browser answers with what its requests say (module navigator: the User-Agent and Accept-Language preferences)
 * and what the preferences let pages see (platform, hardwareConcurrency, doNotTrack). Feature detection must stay
 * truthful: the members of Navigator the browser does not implement (clipboard, serviceWorker, geolocation,
 * mediaDevices, permissions...) are removed from the prototype at pre-initialization, so `"serviceWorker" in
 * navigator` is false rather than a getter that throws. */
#include <stdlib.h>
#include "web.h"

static JSValue make_navigator(JSContext *ctx)
{
    return wj_new_object(ctx, web_is_window() ? WJ_IFACE_Navigator : WJ_IFACE_WorkerNavigator, NULL, NULL);
}

/* navigator.userActivation (UserActivation): the transient/sticky activation state the browser already tracks
 * (UserActivation_isActive / _hasBeenActive). [SameObject]: the one object is kept on the Navigator. */
JSValue wjr_Navigator_get_userActivation(JSContext *ctx, JSValueConst this_val)
{
    if (!nav_this(ctx, this_val)) { return JS_EXCEPTION; }
    JSValue ua = web_extra_get(ctx, this_val, "userActivation");
    if (JS_IsObject(ua)) { return ua; }
    JS_FreeValue(ctx, ua);
    ua = wj_new_object(ctx, WJ_IFACE_UserActivation, NULL, NULL);
    if (JS_IsException(ua)) { return ua; }
    if (!web_extra_set(ctx, this_val, "userActivation", JS_DupValue(ctx, ua))) { JS_FreeValue(ctx, ua); return JS_EXCEPTION; }
    return ua;
}
JSValue wjr_UserActivation_get_isActive(JSContext *ctx, JSValueConst this_val) { return wj_this(ctx, this_val, WJ_IFACE_UserActivation) ? JS_NewBool(ctx, wr_UserActivation_isActive()) : JS_EXCEPTION; }
JSValue wjr_UserActivation_get_hasBeenActive(JSContext *ctx, JSValueConst this_val) { return wj_this(ctx, this_val, WJ_IFACE_UserActivation) ? JS_NewBool(ctx, wr_UserActivation_hasBeenActive()) : JS_EXCEPTION; }

JSValue wjr_Window_get_navigator(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return web_singleton(ctx, WEB_SINGLE_NAVIGATOR, make_navigator); }
JSValue wjr_Window_get_clientInformation(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return web_singleton(ctx, WEB_SINGLE_NAVIGATOR, make_navigator); }
JSValue wjr_WorkerGlobalScope_get_navigator(JSContext *ctx, JSValueConst this_val) { WJ_UNUSED(this_val); return web_singleton(ctx, WEB_SINGLE_NAVIGATOR, make_navigator); }

/* `this` is a Navigator or a WorkerNavigator */
static bool nav_this(JSContext *ctx, JSValueConst this_val)
{
    if (wj_unwrap(this_val, WJ_IFACE_Navigator) || wj_unwrap(this_val, WJ_IFACE_WorkerNavigator)) { return true; }
    JS_ThrowTypeError(ctx, "Illegal invocation");
    return false;
}

static JSValue nav_string(JSContext *ctx, JSValueConst this_val, int field)
{
    if (!nav_this(ctx, this_val)) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Navigator_get(field, wj_scratch.data, wj_scratch.cap));
    return JS_NewStringLen(ctx, (const char *)wj_scratch.data, n > 0 ? (size_t)n : 0);
}

JSValue wjr_NavigatorID_get_appCodeName(JSContext *ctx, JSValueConst this_val) { return nav_this(ctx, this_val) ? JS_NewString(ctx, "Mozilla") : JS_EXCEPTION; }
JSValue wjr_NavigatorID_get_appName(JSContext *ctx, JSValueConst this_val) { return nav_this(ctx, this_val) ? JS_NewString(ctx, "Netscape") : JS_EXCEPTION; }
JSValue wjr_NavigatorID_get_appVersion(JSContext *ctx, JSValueConst this_val) { return nav_string(ctx, this_val, wr_NavigatorField_App_Version); }
JSValue wjr_NavigatorID_get_platform(JSContext *ctx, JSValueConst this_val) { return nav_string(ctx, this_val, wr_NavigatorField_Platform); }
JSValue wjr_NavigatorID_get_product(JSContext *ctx, JSValueConst this_val) { return nav_this(ctx, this_val) ? JS_NewString(ctx, "Gecko") : JS_EXCEPTION; }
JSValue wjr_NavigatorID_get_productSub(JSContext *ctx, JSValueConst this_val) { return nav_this(ctx, this_val) ? JS_NewString(ctx, "20030107") : JS_EXCEPTION; }
JSValue wjr_NavigatorID_get_userAgent(JSContext *ctx, JSValueConst this_val) { return nav_string(ctx, this_val, wr_NavigatorField_User_Agent); }
JSValue wjr_NavigatorID_get_vendor(JSContext *ctx, JSValueConst this_val) { return nav_string(ctx, this_val, wr_NavigatorField_Vendor); }
JSValue wjr_NavigatorID_get_vendorSub(JSContext *ctx, JSValueConst this_val) { return nav_this(ctx, this_val) ? JS_NewString(ctx, "") : JS_EXCEPTION; }

/* navigator.languages: the same frozen array until the preference changes */
static JSValue languages_cache = JS_UNDEFINED;
static char *languages_text;

static JSValue languages(JSContext *ctx)
{
    int32_t n;
    WJ_FETCH_STRING(n, wr_Navigator_get(wr_NavigatorField_Languages, wj_scratch.data, wj_scratch.cap));
    size_t len = n > 0 ? (size_t)n : 0;
    if (JS_IsObject(languages_cache) && languages_text && strlen(languages_text) == len && memcmp(languages_text, wj_scratch.data, len) == 0) {
        return JS_DupValue(ctx, languages_cache);
    }
    free(languages_text);
    languages_text = web_strndup((const char *)wj_scratch.data, len);
    JS_FreeValue(ctx, languages_cache);
    JSValue arr = JS_NewArray(ctx);
    uint32_t k = 0;
    const char *t = languages_text ? languages_text : "";
    while (*t) {
        const char *e = strchr(t, ',');
        size_t l = e ? (size_t)(e - t) : strlen(t);
        if (l) { wj_array_set(ctx, arr, k++, JS_NewStringLen(ctx, t, l)); }
        t += l + (e ? 1 : 0);
    }
    JSValue object = JS_GetPropertyStr(ctx, wj_the_realm.global, "Object");
    JSValue freeze = JS_GetPropertyStr(ctx, object, "freeze");
    JSValue frozen = JS_Call(ctx, freeze, object, 1, (JSValueConst *)&arr);
    JS_FreeValue(ctx, freeze);
    JS_FreeValue(ctx, object);
    JS_FreeValue(ctx, frozen);
    languages_cache = arr;
    return JS_DupValue(ctx, arr);
}

JSValue wjr_NavigatorLanguage_get_languages(JSContext *ctx, JSValueConst this_val)
{
    if (!nav_this(ctx, this_val)) { return JS_EXCEPTION; }
    return languages(ctx);
}

JSValue wjr_NavigatorLanguage_get_language(JSContext *ctx, JSValueConst this_val)
{
    if (!nav_this(ctx, this_val)) { return JS_EXCEPTION; }
    JSValue l = languages(ctx);
    JSValue first = JS_GetPropertyUint32(ctx, l, 0);
    JS_FreeValue(ctx, l);
    if (JS_IsUndefined(first)) { return JS_NewString(ctx, "en-US"); }
    return first;
}

JSValue wjr_NavigatorOnLine_get_onLine(JSContext *ctx, JSValueConst this_val) { return nav_this(ctx, this_val) ? JS_NewBool(ctx, wr_Navigator_onLine() != 0) : JS_EXCEPTION; }
JSValue wjr_NavigatorCookies_get_cookieEnabled(JSContext *ctx, JSValueConst this_val) { return nav_this(ctx, this_val) ? JS_NewBool(ctx, wr_Navigator_cookieEnabled() != 0) : JS_EXCEPTION; }
JSValue wjr_NavigatorConcurrentHardware_get_hardwareConcurrency(JSContext *ctx, JSValueConst this_val) { return nav_this(ctx, this_val) ? JS_NewInt32(ctx, wr_Navigator_hardwareConcurrency()) : JS_EXCEPTION; }
JSValue wjr_NavigatorPlugins_get_pdfViewerEnabled(JSContext *ctx, JSValueConst this_val) { return nav_this(ctx, this_val) ? JS_FALSE : JS_EXCEPTION; }
JSValue wjr_NavigatorPlugins_javaEnabled(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return nav_this(ctx, this_val) ? JS_FALSE : JS_EXCEPTION; }
JSValue wjr_Navigator_get_maxTouchPoints(JSContext *ctx, JSValueConst this_val) { return nav_this(ctx, this_val) ? JS_NewInt32(ctx, wr_Navigator_maxTouchPoints()) : JS_EXCEPTION; }

/* navigator.plugins / mimeTypes: empty (PluginArray, MimeTypeArray: no plugins; pdfViewerEnabled is false) */
static JSValue empty_frozen(JSContext *ctx)
{
    static const char src[] = "Object.freeze([])";
    return JS_Eval(ctx, src, sizeof src - 1, "<web>", JS_EVAL_TYPE_GLOBAL);
}

JSValue wjr_NavigatorPlugins_get_plugins(JSContext *ctx, JSValueConst this_val) { return nav_this(ctx, this_val) ? empty_frozen(ctx) : JS_EXCEPTION; }
JSValue wjr_NavigatorPlugins_get_mimeTypes(JSContext *ctx, JSValueConst this_val) { return nav_this(ctx, this_val) ? empty_frozen(ctx) : JS_EXCEPTION; }

/* ---- sendBeacon ---- */

JSValue wjr_Navigator_sendBeacon(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!nav_this(ctx, this_val)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Navigator.sendBeacon", 1, argc); }
    wj_str u;
    if (!web_to_usv(ctx, argv[0], &u)) { return JS_EXCEPTION; }
    wj_str abs;
    if (!web_resolve_url(ctx, u.ptr, u.len, &abs)) { wj_str_free(ctx, &u); return JS_EXCEPTION; }
    wj_str_free(ctx, &u);
    if (abs.len < 5 || (strncmp(abs.ptr, "http:", 5) != 0 && strncmp(abs.ptr, "https", 5) != 0)) {
        free((void *)abs.ptr);
        return JS_ThrowTypeError(ctx, "Failed to execute 'sendBeacon' on 'Navigator': Beacons are only supported over HTTP(S).");
    }
    JSValueConst data = wj_arg(argc, (JSValue *)argv, 1);
    web_extracted e = { NULL, 0, NULL, JS_UNDEFINED };
    bool has = !JS_IsUndefined(data) && !JS_IsNull(data);
    if (has) {
        if (web_stream_is(data)) { free((void *)abs.ptr); return JS_ThrowTypeError(ctx, "Failed to execute 'sendBeacon' on 'Navigator': a ReadableStream body is not allowed"); }
        if (!web_extract_body(ctx, data, &e, "Navigator.sendBeacon")) { free((void *)abs.ptr); return JS_EXCEPTION; }
    }
    int32_t ok = wr_Beacon_send((const uint8_t *)abs.ptr, (uint32_t)abs.len, has ? (e.data ? e.data : (const uint8_t *)"") : NULL, has ? (uint32_t)e.len : WR_ABSENT,
                                (const uint8_t *)(e.type ? e.type : ""), e.type ? (uint32_t)strlen(e.type) : 0);
    free((void *)abs.ptr);
    web_extracted_free(ctx, &e);
    return JS_NewBool(ctx, ok != 0);
}

/* ---- members not in the IDL the browser implements, and those it does not ---- */

static JSValue get_webdriver(JSContext *ctx, JSValueConst this_val) { return nav_this(ctx, this_val) ? JS_FALSE : JS_EXCEPTION; }

static JSValue get_do_not_track(JSContext *ctx, JSValueConst this_val)
{
    if (!nav_this(ctx, this_val)) { return JS_EXCEPTION; }
    int32_t n;
    WJ_FETCH_STRING(n, wr_Navigator_get(wr_NavigatorField_Do_Not_Track, wj_scratch.data, wj_scratch.cap));
    return n > 0 ? JS_NewStringLen(ctx, (const char *)wj_scratch.data, (size_t)n) : JS_NULL;
}

static void define_getter(JSContext *ctx, JSValueConst proto, const char *name, JSCFunction *fn)
{
    JSValue g = JS_NewCFunction2(ctx, fn, name, 0, JS_CFUNC_getter, 0);
    JSAtom a = JS_NewAtom(ctx, name);
    JS_DefinePropertyGetSet(ctx, proto, a, g, JS_UNDEFINED, JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE);
    JS_FreeAtom(ctx, a);
}

/* removes the attributes and operations of `iface` that nothing implements from its prototype */
static void drop_unimplemented(JSContext *ctx, int iface)
{
    JSValue proto = wj_the_realm.protos[iface];
    if (!JS_IsObject(proto)) { return; }
    const wj_interface *it = &wj_interfaces[iface];
    for (int m = 0; m < it->n_members; m++) {
        const wj_member *mb = &it->members[m];
        if (!mb->name) { continue; }
        bool missing = (mb->kind == WJ_M_ATTRIBUTE && !mb->get) || (mb->kind == WJ_M_METHOD && !mb->fn);
        if (!missing) { continue; }
        JSAtom a = JS_NewAtom(ctx, mb->name);
        JS_DeleteProperty(ctx, proto, a, 0);
        JS_FreeAtom(ctx, a);
    }
}

int web_navigator_preinit(JSContext *ctx)
{
    int ifaces[2] = { WJ_IFACE_Navigator, WJ_IFACE_WorkerNavigator };
    for (int i = 0; i < 2; i++) {
        drop_unimplemented(ctx, ifaces[i]);
        JSValue proto = wj_the_realm.protos[ifaces[i]];
        if (!JS_IsObject(proto)) { continue; }
        define_getter(ctx, proto, "webdriver", (JSCFunction *)(void *)get_webdriver);
        if (ifaces[i] == WJ_IFACE_Navigator) { define_getter(ctx, proto, "doNotTrack", (JSCFunction *)(void *)get_do_not_track); }
    }
    return 0;
}
