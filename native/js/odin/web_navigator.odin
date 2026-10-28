// web_navigator.odin: navigator (HTML Navigator, WorkerNavigator), navigator.userActivation and navigator.sendBeacon
// (Beacon). Ported from native/js/runtime/web_navigator.c; same wjr_* symbols and web_navigator_preinit.
//
// The browser answers with what its requests say (the User-Agent and Accept-Language preferences) and what the
// preferences let pages see (platform, hardwareConcurrency, doNotTrack): each is a declared host call (api_decl
// navigator.odin). Feature detection must stay truthful: the members of Navigator the browser does not implement
// (clipboard, serviceWorker, geolocation, mediaDevices, permissions...) are removed from the prototype at
// pre-initialization, so `"serviceWorker" in navigator` is false rather than a getter that throws.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") if_navigator, if_worker_navigator, if_user_activation := i32(-2), i32(-2), i32(-2)

@(private = "file")
make_navigator :: proc "c" (ctx: ^wj.Context) -> wj.JSValue {
	iface := wj.is_window() ? iface_lazy(&if_navigator, "Navigator") : iface_lazy(&if_worker_navigator, "WorkerNavigator")
	return wj.wj_new_object(ctx, iface, nil, nil)
}

@(export, link_name = "wjr_Window_get_navigator")
wjr_Window_get_navigator :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wj.web_singleton(ctx, wj.SINGLE_NAVIGATOR, make_navigator) }
@(export, link_name = "wjr_Window_get_clientInformation")
wjr_Window_get_clientInformation :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wj.web_singleton(ctx, wj.SINGLE_NAVIGATOR, make_navigator) }
@(export, link_name = "wjr_WorkerGlobalScope_get_navigator")
wjr_WorkerGlobalScope_get_navigator :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wj.web_singleton(ctx, wj.SINGLE_NAVIGATOR, make_navigator) }

// `this` is a Navigator or a WorkerNavigator (a TypeError pending otherwise)
@(private = "file")
nav_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> bool {
	if is_a(this_val, &if_navigator, "Navigator") || is_a(this_val, &if_worker_navigator, "WorkerNavigator") { return true }
	wj.JS_ThrowTypeError(ctx, "Illegal invocation")
	return false
}

// A navigator member that is a declared host call with no argument (onLine, cookieEnabled...), its result to JS.
@(private = "file")
nav_call :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, $D: typeid, imp: $R, what: cstring) -> wj.JSValue {
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	return jsb.function(ctx, 0, nil, D, imp, what)
}

// A string member of Navigator (the browser's answer; "" when it has none).
@(private = "file")
nav_field :: proc "contextless" (ctx: ^wj.Context, field: api_decl.NavigatorField) -> string {
	context = m4_context()
	s: string
	jsb.host(&s, api_decl.Navigator_get, wj.wr_Navigator_get, field)
	return s
}

@(private = "file")
nav_string :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, field: api_decl.NavigatorField) -> wj.JSValue {
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	return js_string(ctx, nav_field(ctx, field))
}

@(private = "file")
nav_constant :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, s: cstring) -> wj.JSValue {
	return nav_this(ctx, this_val) ? wj.new_string(ctx, s) : wj.EXCEPTION
}

// navigator.userActivation (UserActivation): the transient / sticky activation state the browser tracks. [SameObject]:
// the one object is kept on the Navigator.
@(export, link_name = "wjr_Navigator_get_userActivation")
wjr_Navigator_get_userActivation :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	ua := wj.web_extra_get(ctx, this_val, "userActivation")
	if wj.is_object(ua) { return ua }
	wj.JS_FreeValue(ctx, ua)
	ua = wj.wj_new_object(ctx, iface_lazy(&if_user_activation, "UserActivation"), nil, nil)
	if wj.is_exception(ua) { return ua }
	if !wj.web_extra_set(ctx, this_val, "userActivation", wj.JS_DupValue(ctx, ua)) { wj.JS_FreeValue(ctx, ua); return wj.EXCEPTION }
	return ua
}

@(private = "file")
activation :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, $D: typeid, imp: $R, what: cstring) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface_lazy(&if_user_activation, "UserActivation")) == nil { return wj.EXCEPTION }
	return jsb.function(ctx, 0, nil, D, imp, what)
}
@(export, link_name = "wjr_UserActivation_get_isActive")
wjr_UserActivation_get_isActive :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return activation(ctx, t, api_decl.UserActivation_isActive, wj.wr_UserActivation_isActive, "UserActivation.isActive") }
@(export, link_name = "wjr_UserActivation_get_hasBeenActive")
wjr_UserActivation_get_hasBeenActive :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return activation(ctx, t, api_decl.UserActivation_hasBeenActive, wj.wr_UserActivation_hasBeenActive, "UserActivation.hasBeenActive") }

@(export, link_name = "wjr_NavigatorID_get_appCodeName") wjr_NavigatorID_get_appCodeName :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nav_constant(ctx, t, "Mozilla") }
@(export, link_name = "wjr_NavigatorID_get_appName")     wjr_NavigatorID_get_appName     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nav_constant(ctx, t, "Netscape") }
@(export, link_name = "wjr_NavigatorID_get_appVersion")  wjr_NavigatorID_get_appVersion  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nav_string(ctx, t, .App_Version) }
@(export, link_name = "wjr_NavigatorID_get_platform")    wjr_NavigatorID_get_platform    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nav_string(ctx, t, .Platform) }
@(export, link_name = "wjr_NavigatorID_get_product")     wjr_NavigatorID_get_product     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nav_constant(ctx, t, "Gecko") }
@(export, link_name = "wjr_NavigatorID_get_productSub")  wjr_NavigatorID_get_productSub  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nav_constant(ctx, t, "20030107") }
@(export, link_name = "wjr_NavigatorID_get_userAgent")   wjr_NavigatorID_get_userAgent   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nav_string(ctx, t, .User_Agent) }
@(export, link_name = "wjr_NavigatorID_get_vendor")      wjr_NavigatorID_get_vendor      :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nav_string(ctx, t, .Vendor) }
@(export, link_name = "wjr_NavigatorID_get_vendorSub")   wjr_NavigatorID_get_vendorSub   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nav_constant(ctx, t, "") }

// navigator.languages: the same frozen array until the preference changes
@(private = "file") languages_cache := wj.UNDEFINED
@(private = "file") languages_text: [dynamic]u8

@(private = "file")
languages :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	context = m4_context()
	text := nav_field(ctx, .Languages)
	if wj.is_object(languages_cache) && string(languages_text[:]) == text { return wj.JS_DupValue(ctx, languages_cache) }
	clear(&languages_text)
	append(&languages_text, text)
	wj.JS_FreeValue(ctx, languages_cache)
	arr := wj.JS_NewArray(ctx)
	k: u32
	rest := string(languages_text[:])
	for len(rest) > 0 {
		tag := rest
		for c, i in transmute([]u8)rest { if c == ',' { tag = rest[:i]; break } }
		rest = len(tag) < len(rest) ? rest[len(tag) + 1:] : ""
		if len(tag) > 0 { wj.array_set(ctx, arr, k, js_string(ctx, tag)); k += 1 }
	}
	freeze(ctx, arr)
	languages_cache = arr
	return wj.JS_DupValue(ctx, arr)
}

@(export, link_name = "wjr_NavigatorLanguage_get_languages")
wjr_NavigatorLanguage_get_languages :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	return languages(ctx)
}

@(export, link_name = "wjr_NavigatorLanguage_get_language")
wjr_NavigatorLanguage_get_language :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	l := languages(ctx)
	first := wj.JS_GetPropertyUint32(ctx, l, 0)
	wj.JS_FreeValue(ctx, l)
	if wj.is_undefined(first) { return wj.new_string(ctx, "en-US") }
	return first
}

@(export, link_name = "wjr_NavigatorOnLine_get_onLine")
wjr_NavigatorOnLine_get_onLine :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nav_call(ctx, t, api_decl.Navigator_onLine, wj.wr_Navigator_onLine, "Navigator.onLine") }
@(export, link_name = "wjr_NavigatorCookies_get_cookieEnabled")
wjr_NavigatorCookies_get_cookieEnabled :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nav_call(ctx, t, api_decl.Navigator_cookieEnabled, wj.wr_Navigator_cookieEnabled, "Navigator.cookieEnabled") }
@(export, link_name = "wjr_NavigatorConcurrentHardware_get_hardwareConcurrency")
wjr_NavigatorConcurrentHardware_get_hardwareConcurrency :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nav_call(ctx, t, api_decl.Navigator_hardwareConcurrency, wj.wr_Navigator_hardwareConcurrency, "Navigator.hardwareConcurrency") }
@(export, link_name = "wjr_Navigator_get_maxTouchPoints")
wjr_Navigator_get_maxTouchPoints :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nav_call(ctx, t, api_decl.Navigator_maxTouchPoints, wj.wr_Navigator_maxTouchPoints, "Navigator.maxTouchPoints") }
@(export, link_name = "wjr_NavigatorPlugins_get_pdfViewerEnabled")
wjr_NavigatorPlugins_get_pdfViewerEnabled :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nav_this(ctx, t) ? wj.FALSE : wj.EXCEPTION }
@(export, link_name = "wjr_NavigatorPlugins_javaEnabled")
wjr_NavigatorPlugins_javaEnabled :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return nav_this(ctx, t) ? wj.FALSE : wj.EXCEPTION }

// navigator.plugins / mimeTypes: empty (no plugins; pdfViewerEnabled is false)
@(private = "file")
empty_frozen :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	arr := wj.JS_NewArray(ctx)
	if !wj.is_exception(arr) { freeze(ctx, arr) }
	return arr
}
@(export, link_name = "wjr_NavigatorPlugins_get_plugins")
wjr_NavigatorPlugins_get_plugins :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nav_this(ctx, t) ? empty_frozen(ctx) : wj.EXCEPTION }
@(export, link_name = "wjr_NavigatorPlugins_get_mimeTypes")
wjr_NavigatorPlugins_get_mimeTypes :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nav_this(ctx, t) ? empty_frozen(ctx) : wj.EXCEPTION }

// ---- sendBeacon ----

@(export, link_name = "wjr_Navigator_sendBeacon")
wjr_Navigator_sendBeacon :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Navigator.sendBeacon", 1, argc) }
	u, abs: wj.Str
	if !wj.web_to_usv(ctx, argv[0], &u) { return wj.EXCEPTION }
	resolved := wj.web_resolve_url(ctx, u.ptr, u.len, &abs)
	wj.wj_str_free(ctx, &u)
	if !resolved { return wj.EXCEPTION }
	defer wj.libc_free(abs.ptr)
	url := str_view(abs)
	if len(url) < 5 || (url[:5] != "http:" && url[:5] != "https") {
		return wj.JS_ThrowTypeError(ctx, "Failed to execute 'sendBeacon' on 'Navigator': Beacons are only supported over HTTP(S).")
	}
	data := wj.arg(argc, argv, 1)
	e := wj.Extracted{nil, 0, nil, wj.UNDEFINED}
	body: Maybe(abi.Bytes)
	if !wj.is_nullish(data) {
		if wj.web_stream_is(data) { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'sendBeacon' on 'Navigator': a ReadableStream body is not allowed") }
		if !wj.web_extract_body(ctx, data, &e, "Navigator.sendBeacon") { return wj.EXCEPTION }
		body = abi.Bytes(e.data != nil ? e.data[:e.len] : wj.empty_ptr()[:0])
	}
	defer wj.web_extracted_free(ctx, &e)
	sent: bool
	jsb.host(&sent, api_decl.Beacon_send, wj.wr_Beacon_send, url, body, cstr_string(e.type))
	return wj.new_bool(sent)
}

// ---- members not in the IDL the browser implements, and those it does not ----

// (getters: the engine calls a JS_CFUNC_getter with (ctx, this) only, so they have the Getter shape)
@(private = "file")
get_webdriver :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return nav_this(ctx, this_val) ? wj.FALSE : wj.EXCEPTION
}

@(private = "file")
get_do_not_track :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	s := nav_field(ctx, .Do_Not_Track)
	return len(s) > 0 ? js_string(ctx, s) : wj.NULL
}

@(private = "file")
define_getter :: proc "contextless" (ctx: ^wj.Context, proto: wj.JSValue, name: cstring, fn: wj.Getter) {
	g := wj.new_getter(ctx, cast(wj.Native)fn, name)
	a := wj.JS_NewAtom(ctx, name)
	wj.JS_DefinePropertyGetSet(ctx, proto, a, g, wj.UNDEFINED, wj.PROP_CONFIGURABLE | wj.PROP_ENUMERABLE)
	wj.JS_FreeAtom(ctx, a)
}

// removes the attributes and operations of `iface` that nothing implements from its prototype
@(private = "file")
drop_unimplemented :: proc "contextless" (ctx: ^wj.Context, iface: i32) {
	proto := wj.realm_proto(iface)
	if !wj.is_object(proto) { return }
	for m in wj.members_of(iface) {
		if m.name == nil { continue }
		missing := (m.kind == wj.M_ATTRIBUTE && m.get == nil) || (m.kind == wj.M_METHOD && m.fn == nil)
		if !missing { continue }
		a := wj.JS_NewAtom(ctx, m.name)
		wj.JS_DeleteProperty(ctx, proto, a, 0)
		wj.JS_FreeAtom(ctx, a)
	}
}

@(export, link_name = "web_navigator_preinit")
web_navigator_preinit :: proc "c" (ctx: ^wj.Context) -> i32 {
	navigator := iface_lazy(&if_navigator, "Navigator")
	for iface in ([2]i32{navigator, iface_lazy(&if_worker_navigator, "WorkerNavigator")}) {
		if iface < 0 { continue }
		drop_unimplemented(ctx, iface)
		proto := wj.realm_proto(iface)
		if !wj.is_object(proto) { continue }
		define_getter(ctx, proto, "webdriver", get_webdriver)
		if iface == navigator { define_getter(ctx, proto, "doNotTrack", get_do_not_track) }
	}
	return 0
}
