// dom_html.odin: members of HTML elements the generated glue cannot make: attributes "limited to only known values"
// (crossOrigin, referrerPolicy, loading, method, enctype...), URLs with a fallback (form.action), numbers with their
// clamping (progress, meter, textarea.cols), script.textContent / innerText (Trusted Types overloads), validity
// (ValidityState), setRangeText's overloads, the live lists of forms (selectedOptions, fieldset.elements, labels),
// and a few members of Document and Element over existing browser functions. HTML §2.6.1 for the reflection rules.
// Ported from native/js/runtime/dom_html.c, same symbols and behaviour.
//
// An enumerated attribute is a declaration (Reflect_Enum: its keywords, its missing and invalid value defaults, as
// HTML's IDL says it) and a pair of one-line members naming it; the reading is one procedure. The other reflections
// are wj_reflect_get / wj_reflect_set (reflect.odin).
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") nothing: abi.Nothing

// The content attribute `name` of element `el`: its value (in the scratch buffer until the next host call), false
// when absent.
@(private = "file")
attr_read :: proc(el: u64, name: string) -> (string, bool) {
	s: string
	if jsb.host(&s, api_decl.Element_getAttribute, wj.wr_Element_getAttribute, api_decl.Element(el), name) != .None { return "", false }
	return s, true
}

// ---- enumerated attributes ----

// A keyword of an enumerated attribute and the value it maps to ("" canon: the keyword itself).
@(private = "file")
Keyword :: struct { kw, canon: string }

// HTML's enumerated attribute: its keywords and the values of the missing and invalid states (missing_null: the
// missing value default is no state: null).
@(private = "file")
Reflect_Enum :: struct {
	keywords:     []Keyword,
	missing:      string,
	missing_null: bool,
	invalid:      string,
}

@(private = "file") E_CORS := Reflect_Enum{keywords = {{"anonymous", ""}, {"use-credentials", ""}, {"", "anonymous"}}, missing_null = true, invalid = "anonymous"}
@(private = "file") E_REFERRER := Reflect_Enum{keywords = {
	{"", ""}, {"no-referrer", ""}, {"no-referrer-when-downgrade", ""}, {"same-origin", ""}, {"origin", ""},
	{"strict-origin", ""}, {"origin-when-cross-origin", ""}, {"strict-origin-when-cross-origin", ""}, {"unsafe-url", ""},
}}
@(private = "file") E_LOADING := Reflect_Enum{keywords = {{"lazy", ""}, {"eager", ""}}, missing = "eager", invalid = "eager"}
@(private = "file") E_DECODING := Reflect_Enum{keywords = {{"sync", ""}, {"async", ""}, {"auto", ""}}, missing = "auto", invalid = "auto"}
@(private = "file") E_PRIORITY := Reflect_Enum{keywords = {{"high", ""}, {"low", ""}, {"auto", ""}}, missing = "auto", invalid = "auto"}
@(private = "file") E_ONOFF := Reflect_Enum{keywords = {{"on", ""}, {"off", ""}}, missing = "on", invalid = "on"}
@(private = "file") E_METHOD := Reflect_Enum{keywords = {{"get", ""}, {"post", ""}, {"dialog", ""}}, missing = "get", invalid = "get"}
@(private = "file") E_ENCTYPE := Reflect_Enum{keywords = {{"application/x-www-form-urlencoded", ""}, {"multipart/form-data", ""}, {"text/plain", ""}},
	missing = "application/x-www-form-urlencoded", invalid = "application/x-www-form-urlencoded"}
@(private = "file") E_FORM_METHOD := Reflect_Enum{keywords = {{"get", ""}, {"post", ""}, {"dialog", ""}}, invalid = "get"}
@(private = "file") E_FORM_ENCTYPE := Reflect_Enum{keywords = {{"application/x-www-form-urlencoded", ""}, {"multipart/form-data", ""}, {"text/plain", ""}},
	invalid = "application/x-www-form-urlencoded"}
@(private = "file") E_TRACK := Reflect_Enum{keywords = {{"subtitles", ""}, {"captions", ""}, {"descriptions", ""}, {"chapters", ""}, {"metadata", ""}},
	missing = "subtitles", invalid = "metadata"}
@(private = "file") E_PRELOAD := Reflect_Enum{keywords = {{"none", ""}, {"metadata", ""}, {"auto", ""}, {"", "auto"}}, missing = "metadata", invalid = "metadata"}
@(private = "file") E_SCOPE := Reflect_Enum{keywords = {{"row", ""}, {"col", ""}, {"rowgroup", ""}, {"colgroup", ""}}}
@(private = "file") E_AS := Reflect_Enum{keywords = {
	{"fetch", ""}, {"audio", ""}, {"audioworklet", ""}, {"document", ""}, {"embed", ""}, {"font", ""}, {"frame", ""},
	{"iframe", ""}, {"image", ""}, {"json", ""}, {"manifest", ""}, {"object", ""}, {"paintworklet", ""}, {"report", ""},
	{"script", ""}, {"serviceworker", ""}, {"sharedworker", ""}, {"style", ""}, {"track", ""}, {"video", ""},
	{"webidentity", ""}, {"worker", ""}, {"xslt", ""},
}}
// declarative shadow roots
@(private = "file") E_SHADOW_MODE := Reflect_Enum{keywords = {{"open", ""}, {"closed", ""}}}
@(private = "file") E_SLOT_ASSIGNMENT := Reflect_Enum{keywords = {{"named", ""}, {"manual", ""}}, missing = "named", invalid = "named"}

@(private = "file")
enum_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32, attr: string, e: ^Reflect_Enum) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, iface)
	if o == nil { return wj.EXCEPTION }
	v, present := attr_read(o.handle, attr)
	if !present { return e.missing_null ? wj.NULL : wj.new_string_len(ctx, e.missing) }
	for k in e.keywords {
		if ascii_ieq(v, k.kw) { return wj.new_string_len(ctx, k.canon != "" ? k.canon : k.kw) }
	}
	return wj.new_string_len(ctx, e.invalid)
}

// the setter writes the value as given (null removes the attribute of a nullable one)
@(private = "file")
enum_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32, attr: cstring, v: wj.JSValue, nullable := false) -> wj.JSValue {
	return wj_reflect_set(ctx, this_val, iface, attr, i32(nullable ? Kind.Nullable_String : Kind.String), v, 0, 0, 0)
}

@(export, link_name = "wjr_HTMLImageElement_get_crossOrigin")    wjr_HTMLImageElement_get_crossOrigin    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLImageElement"), "crossorigin", &E_CORS) }
@(export, link_name = "wjr_HTMLImageElement_set_crossOrigin")    wjr_HTMLImageElement_set_crossOrigin    :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLImageElement"), "crossorigin", v, true) }
@(export, link_name = "wjr_HTMLMediaElement_get_crossOrigin")    wjr_HTMLMediaElement_get_crossOrigin    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLMediaElement"), "crossorigin", &E_CORS) }
@(export, link_name = "wjr_HTMLMediaElement_set_crossOrigin")    wjr_HTMLMediaElement_set_crossOrigin    :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLMediaElement"), "crossorigin", v, true) }
@(export, link_name = "wjr_HTMLMediaElement_get_preload")        wjr_HTMLMediaElement_get_preload        :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLMediaElement"), "preload", &E_PRELOAD) }
@(export, link_name = "wjr_HTMLMediaElement_set_preload")        wjr_HTMLMediaElement_set_preload        :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLMediaElement"), "preload", v) }
@(export, link_name = "wjr_HTMLLinkElement_get_crossOrigin")     wjr_HTMLLinkElement_get_crossOrigin     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLLinkElement"), "crossorigin", &E_CORS) }
@(export, link_name = "wjr_HTMLLinkElement_set_crossOrigin")     wjr_HTMLLinkElement_set_crossOrigin     :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLLinkElement"), "crossorigin", v, true) }

@(export, link_name = "wjr_HTMLAnchorElement_get_referrerPolicy") wjr_HTMLAnchorElement_get_referrerPolicy :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLAnchorElement"), "referrerpolicy", &E_REFERRER) }
@(export, link_name = "wjr_HTMLAnchorElement_set_referrerPolicy") wjr_HTMLAnchorElement_set_referrerPolicy :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLAnchorElement"), "referrerpolicy", v) }
@(export, link_name = "wjr_HTMLAreaElement_get_referrerPolicy")   wjr_HTMLAreaElement_get_referrerPolicy   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLAreaElement"), "referrerpolicy", &E_REFERRER) }
@(export, link_name = "wjr_HTMLAreaElement_set_referrerPolicy")   wjr_HTMLAreaElement_set_referrerPolicy   :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLAreaElement"), "referrerpolicy", v) }
@(export, link_name = "wjr_HTMLImageElement_get_referrerPolicy")  wjr_HTMLImageElement_get_referrerPolicy  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLImageElement"), "referrerpolicy", &E_REFERRER) }
@(export, link_name = "wjr_HTMLImageElement_set_referrerPolicy")  wjr_HTMLImageElement_set_referrerPolicy  :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLImageElement"), "referrerpolicy", v) }
@(export, link_name = "wjr_HTMLIFrameElement_get_referrerPolicy") wjr_HTMLIFrameElement_get_referrerPolicy :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLIFrameElement"), "referrerpolicy", &E_REFERRER) }
@(export, link_name = "wjr_HTMLIFrameElement_set_referrerPolicy") wjr_HTMLIFrameElement_set_referrerPolicy :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLIFrameElement"), "referrerpolicy", v) }
@(export, link_name = "wjr_HTMLLinkElement_get_referrerPolicy")   wjr_HTMLLinkElement_get_referrerPolicy   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLLinkElement"), "referrerpolicy", &E_REFERRER) }
@(export, link_name = "wjr_HTMLLinkElement_set_referrerPolicy")   wjr_HTMLLinkElement_set_referrerPolicy   :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLLinkElement"), "referrerpolicy", v) }

@(export, link_name = "wjr_HTMLImageElement_get_loading")   wjr_HTMLImageElement_get_loading   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLImageElement"), "loading", &E_LOADING) }
@(export, link_name = "wjr_HTMLImageElement_set_loading")   wjr_HTMLImageElement_set_loading   :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLImageElement"), "loading", v) }
@(export, link_name = "wjr_HTMLIFrameElement_get_loading")  wjr_HTMLIFrameElement_get_loading  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLIFrameElement"), "loading", &E_LOADING) }
@(export, link_name = "wjr_HTMLIFrameElement_set_loading")  wjr_HTMLIFrameElement_set_loading  :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLIFrameElement"), "loading", v) }
@(export, link_name = "wjr_HTMLImageElement_get_decoding")  wjr_HTMLImageElement_get_decoding  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLImageElement"), "decoding", &E_DECODING) }
@(export, link_name = "wjr_HTMLImageElement_set_decoding")  wjr_HTMLImageElement_set_decoding  :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLImageElement"), "decoding", v) }

@(export, link_name = "wjr_HTMLImageElement_get_fetchPriority")  wjr_HTMLImageElement_get_fetchPriority  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLImageElement"), "fetchpriority", &E_PRIORITY) }
@(export, link_name = "wjr_HTMLImageElement_set_fetchPriority")  wjr_HTMLImageElement_set_fetchPriority  :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLImageElement"), "fetchpriority", v) }
@(export, link_name = "wjr_HTMLLinkElement_get_fetchPriority")   wjr_HTMLLinkElement_get_fetchPriority   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLLinkElement"), "fetchpriority", &E_PRIORITY) }
@(export, link_name = "wjr_HTMLLinkElement_set_fetchPriority")   wjr_HTMLLinkElement_set_fetchPriority   :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLLinkElement"), "fetchpriority", v) }
@(export, link_name = "wjr_HTMLScriptElement_get_fetchPriority") wjr_HTMLScriptElement_get_fetchPriority :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLScriptElement"), "fetchpriority", &E_PRIORITY) }
@(export, link_name = "wjr_HTMLScriptElement_set_fetchPriority") wjr_HTMLScriptElement_set_fetchPriority :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLScriptElement"), "fetchpriority", v) }

@(export, link_name = "wjr_HTMLLinkElement_get_as")         wjr_HTMLLinkElement_get_as         :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLLinkElement"), "as", &E_AS) }
@(export, link_name = "wjr_HTMLLinkElement_set_as")         wjr_HTMLLinkElement_set_as         :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLLinkElement"), "as", v) }
@(export, link_name = "wjr_HTMLTrackElement_get_kind")      wjr_HTMLTrackElement_get_kind      :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLTrackElement"), "kind", &E_TRACK) }
@(export, link_name = "wjr_HTMLTrackElement_set_kind")      wjr_HTMLTrackElement_set_kind      :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLTrackElement"), "kind", v) }
@(export, link_name = "wjr_HTMLTableCellElement_get_scope") wjr_HTMLTableCellElement_get_scope :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLTableCellElement"), "scope", &E_SCOPE) }
@(export, link_name = "wjr_HTMLTableCellElement_set_scope") wjr_HTMLTableCellElement_set_scope :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLTableCellElement"), "scope", v) }

@(export, link_name = "wjr_HTMLTemplateElement_get_shadowRootMode")           wjr_HTMLTemplateElement_get_shadowRootMode           :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLTemplateElement"), "shadowrootmode", &E_SHADOW_MODE) }
@(export, link_name = "wjr_HTMLTemplateElement_set_shadowRootMode")           wjr_HTMLTemplateElement_set_shadowRootMode           :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLTemplateElement"), "shadowrootmode", v) }
@(export, link_name = "wjr_HTMLTemplateElement_get_shadowRootSlotAssignment") wjr_HTMLTemplateElement_get_shadowRootSlotAssignment :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLTemplateElement"), "shadowrootslotassignment", &E_SLOT_ASSIGNMENT) }
@(export, link_name = "wjr_HTMLTemplateElement_set_shadowRootSlotAssignment") wjr_HTMLTemplateElement_set_shadowRootSlotAssignment :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLTemplateElement"), "shadowrootslotassignment", v) }

// forms
@(export, link_name = "wjr_HTMLFormElement_get_autocomplete")  wjr_HTMLFormElement_get_autocomplete  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLFormElement"), "autocomplete", &E_ONOFF) }
@(export, link_name = "wjr_HTMLFormElement_set_autocomplete")  wjr_HTMLFormElement_set_autocomplete  :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLFormElement"), "autocomplete", v) }
@(export, link_name = "wjr_HTMLFormElement_get_method")        wjr_HTMLFormElement_get_method        :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLFormElement"), "method", &E_METHOD) }
@(export, link_name = "wjr_HTMLFormElement_set_method")        wjr_HTMLFormElement_set_method        :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLFormElement"), "method", v) }
@(export, link_name = "wjr_HTMLFormElement_get_enctype")       wjr_HTMLFormElement_get_enctype       :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLFormElement"), "enctype", &E_ENCTYPE) }
@(export, link_name = "wjr_HTMLFormElement_set_enctype")       wjr_HTMLFormElement_set_enctype       :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLFormElement"), "enctype", v) }
@(export, link_name = "wjr_HTMLFormElement_get_encoding")      wjr_HTMLFormElement_get_encoding      :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLFormElement"), "enctype", &E_ENCTYPE) }
@(export, link_name = "wjr_HTMLFormElement_set_encoding")      wjr_HTMLFormElement_set_encoding      :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLFormElement"), "enctype", v) }
@(export, link_name = "wjr_HTMLButtonElement_get_formMethod")  wjr_HTMLButtonElement_get_formMethod  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLButtonElement"), "formmethod", &E_FORM_METHOD) }
@(export, link_name = "wjr_HTMLButtonElement_set_formMethod")  wjr_HTMLButtonElement_set_formMethod  :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLButtonElement"), "formmethod", v) }
@(export, link_name = "wjr_HTMLButtonElement_get_formEnctype") wjr_HTMLButtonElement_get_formEnctype :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLButtonElement"), "formenctype", &E_FORM_ENCTYPE) }
@(export, link_name = "wjr_HTMLButtonElement_set_formEnctype") wjr_HTMLButtonElement_set_formEnctype :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLButtonElement"), "formenctype", v) }
@(export, link_name = "wjr_HTMLInputElement_get_formMethod")   wjr_HTMLInputElement_get_formMethod   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLInputElement"), "formmethod", &E_FORM_METHOD) }
@(export, link_name = "wjr_HTMLInputElement_set_formMethod")   wjr_HTMLInputElement_set_formMethod   :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLInputElement"), "formmethod", v) }
@(export, link_name = "wjr_HTMLInputElement_get_formEnctype")  wjr_HTMLInputElement_get_formEnctype  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return enum_get(ctx, t, ifc("HTMLInputElement"), "formenctype", &E_FORM_ENCTYPE) }
@(export, link_name = "wjr_HTMLInputElement_set_formEnctype")  wjr_HTMLInputElement_set_formEnctype  :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLInputElement"), "formenctype", v) }

// the autofill field of controls: the attribute as written (the autofill detail tokens are not validated)
@(private = "file")
string_get :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, iface: i32, attr: cstring) -> wj.JSValue { return wj_reflect_get(ctx, t, iface, attr, i32(Kind.String), 0, 0, 0, 0) }

@(export, link_name = "wjr_HTMLInputElement_get_autocomplete")    wjr_HTMLInputElement_get_autocomplete    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return string_get(ctx, t, ifc("HTMLInputElement"), "autocomplete") }
@(export, link_name = "wjr_HTMLInputElement_set_autocomplete")    wjr_HTMLInputElement_set_autocomplete    :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLInputElement"), "autocomplete", v) }
@(export, link_name = "wjr_HTMLSelectElement_get_autocomplete")   wjr_HTMLSelectElement_get_autocomplete   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return string_get(ctx, t, ifc("HTMLSelectElement"), "autocomplete") }
@(export, link_name = "wjr_HTMLSelectElement_set_autocomplete")   wjr_HTMLSelectElement_set_autocomplete   :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLSelectElement"), "autocomplete", v) }
@(export, link_name = "wjr_HTMLTextAreaElement_get_autocomplete") wjr_HTMLTextAreaElement_get_autocomplete :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return string_get(ctx, t, ifc("HTMLTextAreaElement"), "autocomplete") }
@(export, link_name = "wjr_HTMLTextAreaElement_set_autocomplete") wjr_HTMLTextAreaElement_set_autocomplete :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLTextAreaElement"), "autocomplete", v) }

// form.action, button.formAction: the attribute's URL, the document's URL when it is missing or empty
@(private = "file")
action_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32, attr: cstring) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, iface)
	if o == nil { return wj.EXCEPTION }
	if v, present := attr_read(o.handle, string(attr)); !present || len(v) == 0 {
		s: string
		jsb.host(&s, api_decl.Document_URL, wj.wr_Document_URL)
		return wj.new_string_len(ctx, s)
	}
	return wj_reflect_get(ctx, this_val, iface, attr, i32(Kind.Url), 0, 0, 0, 0)
}

@(export, link_name = "wjr_HTMLFormElement_get_action")       wjr_HTMLFormElement_get_action       :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return action_get(ctx, t, ifc("HTMLFormElement"), "action") }
@(export, link_name = "wjr_HTMLFormElement_set_action")       wjr_HTMLFormElement_set_action       :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLFormElement"), "action", v) }
@(export, link_name = "wjr_HTMLButtonElement_get_formAction") wjr_HTMLButtonElement_get_formAction :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return action_get(ctx, t, ifc("HTMLButtonElement"), "formaction") }
@(export, link_name = "wjr_HTMLButtonElement_set_formAction") wjr_HTMLButtonElement_set_formAction :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLButtonElement"), "formaction", v) }
@(export, link_name = "wjr_HTMLInputElement_get_formAction")  wjr_HTMLInputElement_get_formAction  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return action_get(ctx, t, ifc("HTMLInputElement"), "formaction") }
@(export, link_name = "wjr_HTMLInputElement_set_formAction")  wjr_HTMLInputElement_set_formAction  :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return enum_set(ctx, t, ifc("HTMLInputElement"), "formaction", v) }

// ---- script ----

// textContent / innerText are redeclared on HTMLScriptElement for Trusted Types: Node's and HTMLElement's behaviour
@(export, link_name = "wjr_HTMLScriptElement_get_textContent")
wjr_HTMLScriptElement_get_textContent :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return wjr_Node_get_textContent(ctx, t) }
@(export, link_name = "wjr_HTMLScriptElement_set_textContent")
wjr_HTMLScriptElement_set_textContent :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return wjr_Node_set_textContent(ctx, t, v) }

@(export, link_name = "wjr_HTMLScriptElement_get_innerText")
wjr_HTMLScriptElement_get_innerText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, t, ifc("HTMLScriptElement"))
	if o == nil { return wj.EXCEPTION }
	s: string
	st := jsb.host(&s, api_decl.HTMLElement_innerText, wj.wr_HTMLElement_innerText, api_decl.Element(o.handle))
	return dom_str(ctx, s, st, false, "HTMLScriptElement.innerText")
}

@(export, link_name = "wjr_HTMLScriptElement_set_innerText")
wjr_HTMLScriptElement_set_innerText :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, t, ifc("HTMLScriptElement"))
	if o == nil { return wj.EXCEPTION }
	s: wj.Str
	if !wj.wj_to_str(ctx, v, &s, wj.STR_NULL_EMPTY, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	st := jsb.host(&nothing, api_decl.HTMLElement_set_innerText, wj.wr_HTMLElement_set_innerText, api_decl.Element(o.handle), str_view(s))
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "HTMLScriptElement.innerText") : wj.UNDEFINED
}

// base.href: the attribute's URL (the document's fallback base URL is its URL)
@(export, link_name = "wjr_HTMLBaseElement_get_href")
wjr_HTMLBaseElement_get_href :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return wj_reflect_get(ctx, t, ifc("HTMLBaseElement"), "href", i32(Kind.Url), 0, 0, 0, 0) }
@(export, link_name = "wjr_HTMLBaseElement_set_href")
wjr_HTMLBaseElement_set_href :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return wj_reflect_set(ctx, t, ifc("HTMLBaseElement"), "href", i32(Kind.Url), v, 0, 0, 0) }

// ---- img.width / img.height: the attribute, else the natural size ----

@(private = "file")
image_size :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, attr: string, width: bool) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, t, ifc("HTMLImageElement"))
	if o == nil { return wj.EXCEPTION }
	// HTML "rules for parsing non-negative integers"
	s, _ := attr_read(o.handle, attr)
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\f' || s[i] == '\r') { i += 1 }
	if i < len(s) && s[i] == '+' { i += 1 }
	if i < len(s) && s[i] >= '0' && s[i] <= '9' {
		x: f64
		for i < len(s) && s[i] >= '0' && s[i] <= '9' { x = x * 10 + f64(s[i] - '0'); i += 1 }
		if x <= 2147483647.0 { return wj.new_uint32(ctx, u32(x)) }
	}
	n: i32
	img := api_decl.Element(o.handle)
	if width { jsb.host(&n, api_decl.HTMLImageElement_naturalWidth, wj.wr_HTMLImageElement_naturalWidth, img) }
	else { jsb.host(&n, api_decl.HTMLImageElement_naturalHeight, wj.wr_HTMLImageElement_naturalHeight, img) }
	return wj.new_uint32(ctx, n > 0 ? u32(n) : 0)
}

@(export, link_name = "wjr_HTMLImageElement_get_width")
wjr_HTMLImageElement_get_width :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return image_size(ctx, t, "width", true) }
@(export, link_name = "wjr_HTMLImageElement_set_width")
wjr_HTMLImageElement_set_width :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return wj_reflect_set(ctx, t, ifc("HTMLImageElement"), "width", i32(Kind.Ulong), v, 0, 0, 0) }
@(export, link_name = "wjr_HTMLImageElement_get_height")
wjr_HTMLImageElement_get_height :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return image_size(ctx, t, "height", false) }
@(export, link_name = "wjr_HTMLImageElement_set_height")
wjr_HTMLImageElement_set_height :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return wj_reflect_set(ctx, t, ifc("HTMLImageElement"), "height", i32(Kind.Ulong), v, 0, 0, 0) }

// ---- numbers: textarea cols / rows, progress, meter ----

// "limited to only positive numbers with fallback": 1 ..= 2^31-1, else the default (on reading and on setting)
@(private = "file")
positive_set :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, iface: i32, attr: cstring, v: wj.JSValue, def: u32) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, t, iface)
	if o == nil { return wj.EXCEPTION }
	x: u32
	if !wj.wj_to_uint32(ctx, v, &x, 32, 0) { return wj.EXCEPTION }
	if x == 0 || x > 2147483647 { x = def }
	buf: [16]u8
	n := len(buf)
	for { n -= 1; buf[n] = u8('0' + x % 10); x /= 10; if x == 0 { break } }
	st := jsb.host(&nothing, api_decl.Element_setAttribute, wj.wr_Element_setAttribute, api_decl.Element(o.handle), string(attr), string(buf[n:]))
	return st != .None ? wj.wj_throw_status(ctx, i32(st), attr) : wj.UNDEFINED
}

@(export, link_name = "wjr_HTMLTextAreaElement_get_cols")
wjr_HTMLTextAreaElement_get_cols :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return wj_reflect_get(ctx, t, ifc("HTMLTextAreaElement"), "cols", i32(Kind.Ulong), 20, 3, 0, 0) }
@(export, link_name = "wjr_HTMLTextAreaElement_set_cols")
wjr_HTMLTextAreaElement_set_cols :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return positive_set(ctx, t, ifc("HTMLTextAreaElement"), "cols", v, 20) }
@(export, link_name = "wjr_HTMLTextAreaElement_get_rows")
wjr_HTMLTextAreaElement_get_rows :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return wj_reflect_get(ctx, t, ifc("HTMLTextAreaElement"), "rows", i32(Kind.Ulong), 2, 3, 0, 0) }
@(export, link_name = "wjr_HTMLTextAreaElement_set_rows")
wjr_HTMLTextAreaElement_set_rows :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return positive_set(ctx, t, ifc("HTMLTextAreaElement"), "rows", v, 2) }

// textarea.textLength: the value's length in UTF-16 code units
@(export, link_name = "wjr_HTMLTextAreaElement_get_textLength")
wjr_HTMLTextAreaElement_get_textLength :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("HTMLTextAreaElement")) == nil { return wj.EXCEPTION }
	v := wj.JS_GetPropertyStr(ctx, t, "value")
	if wj.is_exception(v) { return v }
	defer wj.JS_FreeValue(ctx, v)
	return wj.JS_GetPropertyStr(ctx, v, "length")
}

@(private = "file") NAN :: f64(0h7ff8_0000_0000_0000)

// a floating-point attribute: NaN when missing or not a number
@(private = "file")
number_attr :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, iface: i32, attr: cstring) -> f64 {
	v := wj_reflect_get(ctx, t, iface, attr, i32(Kind.Double), NAN, 0, 0, 0)
	x := NAN
	if !wj.is_exception(v) { wj.JS_ToFloat64(ctx, &x, v) }
	wj.JS_FreeValue(ctx, v)
	return x
}

@(private = "file")
or_default :: #force_inline proc "contextless" (x, def: f64) -> f64 { return wj.is_nan(x) ? def : x }

@(private = "file")
progress_max :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue) -> f64 {
	m := number_attr(ctx, t, ifc("HTMLProgressElement"), "max")
	return wj.is_nan(m) || m <= 0 ? 1.0 : m
}

// the current value; NaN for an indeterminate progress bar (no value attribute)
@(private = "file")
progress_value :: proc(ctx: ^wj.Context, t: wj.JSValue, o: ^wj.Obj) -> f64 {
	if _, present := attr_read(o.handle, "value"); !present { return NAN }
	v := number_attr(ctx, t, ifc("HTMLProgressElement"), "value")
	if wj.is_nan(v) || v < 0 { v = 0 }
	return min(v, progress_max(ctx, t))
}

@(export, link_name = "wjr_HTMLProgressElement_get_value")
wjr_HTMLProgressElement_get_value :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, t, ifc("HTMLProgressElement"))
	if o == nil { return wj.EXCEPTION }
	return wj.new_float64(ctx, or_default(progress_value(ctx, t, o), 0))
}

@(export, link_name = "wjr_HTMLProgressElement_set_value")
wjr_HTMLProgressElement_set_value :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return wj_reflect_set(ctx, t, ifc("HTMLProgressElement"), "value", i32(Kind.Double), v, 0, 0, 0) }

@(export, link_name = "wjr_HTMLProgressElement_get_max")
wjr_HTMLProgressElement_get_max :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("HTMLProgressElement")) == nil { return wj.EXCEPTION }
	return wj.new_float64(ctx, progress_max(ctx, t))
}

// "limited to only positive numbers": other values are ignored
@(export, link_name = "wjr_HTMLProgressElement_set_max")
wjr_HTMLProgressElement_set_max :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("HTMLProgressElement")) == nil { return wj.EXCEPTION }
	x: f64
	if !wj.wj_to_double(ctx, v, &x, true) { return wj.EXCEPTION }
	if x <= 0 { return wj.UNDEFINED }
	return wj_reflect_set(ctx, t, ifc("HTMLProgressElement"), "max", i32(Kind.Double), v, 0, 0, 0)
}

@(export, link_name = "wjr_HTMLProgressElement_get_position")
wjr_HTMLProgressElement_get_position :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, t, ifc("HTMLProgressElement"))
	if o == nil { return wj.EXCEPTION }
	v := progress_value(ctx, t, o)
	return wj.new_float64(ctx, wj.is_nan(v) ? -1 : v / progress_max(ctx, t))
}

// meter: HTML §4.10.14's boundaries, each clamped by the ones before
@(private = "file")
Meter_Value :: enum { Value, Min, Max, Low, High, Optimum }

@(private = "file")
meter_of :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue) -> (m: [Meter_Value]f64, ok: bool) {
	if wj.wj_this(ctx, t, ifc("HTMLMeterElement")) == nil { return }
	a :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, name: cstring) -> f64 { return number_attr(ctx, t, ifc("HTMLMeterElement"), name) }
	lo := or_default(a(ctx, t, "min"), 0)
	hi := max(or_default(a(ctx, t, "max"), 1.0), lo)
	m[.Min] = lo
	m[.Max] = hi
	m[.Value] = clamp(or_default(a(ctx, t, "value"), 0), lo, hi)
	m[.Low] = clamp(or_default(a(ctx, t, "low"), lo), lo, hi)
	m[.High] = min(max(or_default(a(ctx, t, "high"), hi), m[.Low]), hi)
	m[.Optimum] = clamp(or_default(a(ctx, t, "optimum"), (lo + hi) / 2), lo, hi)
	return m, true
}

@(private = "file")
meter_get :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, which: Meter_Value) -> wj.JSValue {
	m, ok := meter_of(ctx, t)
	return ok ? wj.new_float64(ctx, m[which]) : wj.EXCEPTION
}

@(private = "file")
meter_set :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, attr: cstring, v: wj.JSValue) -> wj.JSValue { return wj_reflect_set(ctx, t, ifc("HTMLMeterElement"), attr, i32(Kind.Double), v, 0, 0, 0) }

@(export, link_name = "wjr_HTMLMeterElement_get_value")   wjr_HTMLMeterElement_get_value   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return meter_get(ctx, t, .Value) }
@(export, link_name = "wjr_HTMLMeterElement_set_value")   wjr_HTMLMeterElement_set_value   :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return meter_set(ctx, t, "value", v) }
@(export, link_name = "wjr_HTMLMeterElement_get_min")     wjr_HTMLMeterElement_get_min     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return meter_get(ctx, t, .Min) }
@(export, link_name = "wjr_HTMLMeterElement_set_min")     wjr_HTMLMeterElement_set_min     :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return meter_set(ctx, t, "min", v) }
@(export, link_name = "wjr_HTMLMeterElement_get_max")     wjr_HTMLMeterElement_get_max     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return meter_get(ctx, t, .Max) }
@(export, link_name = "wjr_HTMLMeterElement_set_max")     wjr_HTMLMeterElement_set_max     :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return meter_set(ctx, t, "max", v) }
@(export, link_name = "wjr_HTMLMeterElement_get_low")     wjr_HTMLMeterElement_get_low     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return meter_get(ctx, t, .Low) }
@(export, link_name = "wjr_HTMLMeterElement_set_low")     wjr_HTMLMeterElement_set_low     :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return meter_set(ctx, t, "low", v) }
@(export, link_name = "wjr_HTMLMeterElement_get_high")    wjr_HTMLMeterElement_get_high    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return meter_get(ctx, t, .High) }
@(export, link_name = "wjr_HTMLMeterElement_set_high")    wjr_HTMLMeterElement_set_high    :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return meter_set(ctx, t, "high", v) }
@(export, link_name = "wjr_HTMLMeterElement_get_optimum") wjr_HTMLMeterElement_get_optimum :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return meter_get(ctx, t, .Optimum) }
@(export, link_name = "wjr_HTMLMeterElement_set_optimum") wjr_HTMLMeterElement_set_optimum :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return meter_set(ctx, t, "optimum", v) }

// ---- ValidityState: the control's flags, read when asked ----

@(private = "file") DOM_VALIDITY :: 100

@(private = "file")
validity_new :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, iface: i32) -> wj.JSValue {
	o := wj.wj_this(ctx, t, iface)
	if o == nil { return wj.EXCEPTION }
	return wj.dom_new(ctx, ifc("ValidityState"), DOM_VALIDITY, t, o.handle, nil)
}

@(export, link_name = "wjr_HTMLInputElement_get_validity")    wjr_HTMLInputElement_get_validity    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_new(ctx, t, ifc("HTMLInputElement")) }
@(export, link_name = "wjr_HTMLButtonElement_get_validity")   wjr_HTMLButtonElement_get_validity   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_new(ctx, t, ifc("HTMLButtonElement")) }
@(export, link_name = "wjr_HTMLSelectElement_get_validity")   wjr_HTMLSelectElement_get_validity   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_new(ctx, t, ifc("HTMLSelectElement")) }
@(export, link_name = "wjr_HTMLTextAreaElement_get_validity") wjr_HTMLTextAreaElement_get_validity :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_new(ctx, t, ifc("HTMLTextAreaElement")) }
@(export, link_name = "wjr_HTMLOutputElement_get_validity")   wjr_HTMLOutputElement_get_validity   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_new(ctx, t, ifc("HTMLOutputElement")) }
@(export, link_name = "wjr_HTMLFieldSetElement_get_validity") wjr_HTMLFieldSetElement_get_validity :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_new(ctx, t, ifc("HTMLFieldSetElement")) }
@(export, link_name = "wjr_HTMLObjectElement_get_validity")   wjr_HTMLObjectElement_get_validity   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_new(ctx, t, ifc("HTMLObjectElement")) }

// one flag of the control's validity (nil: valid, no flag set)
@(private = "file")
validity_flag :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, flag: Maybe(wj.wr_ValidityState_Flag)) -> wj.JSValue {
	context = jsb.glue_context()
	d := wj.dom_impl_of(ctx, t, ifc("ValidityState"))
	if d == nil { return wj.EXCEPTION }
	bits: u32
	jsb.host(&bits, api_decl.HTMLInputElement_validity, wj.wr_HTMLInputElement_validity, api_decl.Element(d.node))   // the same import for every control
	flags := transmute(wj.wr_ValidityState)bits
	if f, ok := flag.?; ok { return wj.new_bool(f in flags) }
	return wj.new_bool(flags == {})
}

@(export, link_name = "wjr_ValidityState_get_valueMissing")    wjr_ValidityState_get_valueMissing    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_flag(ctx, t, .Value_Missing) }
@(export, link_name = "wjr_ValidityState_get_typeMismatch")    wjr_ValidityState_get_typeMismatch    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_flag(ctx, t, .Type_Mismatch) }
@(export, link_name = "wjr_ValidityState_get_patternMismatch") wjr_ValidityState_get_patternMismatch :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_flag(ctx, t, .Pattern_Mismatch) }
@(export, link_name = "wjr_ValidityState_get_tooLong")         wjr_ValidityState_get_tooLong         :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_flag(ctx, t, .Too_Long) }
@(export, link_name = "wjr_ValidityState_get_tooShort")        wjr_ValidityState_get_tooShort        :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_flag(ctx, t, .Too_Short) }
@(export, link_name = "wjr_ValidityState_get_rangeUnderflow")  wjr_ValidityState_get_rangeUnderflow  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_flag(ctx, t, .Range_Underflow) }
@(export, link_name = "wjr_ValidityState_get_rangeOverflow")   wjr_ValidityState_get_rangeOverflow   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_flag(ctx, t, .Range_Overflow) }
@(export, link_name = "wjr_ValidityState_get_stepMismatch")    wjr_ValidityState_get_stepMismatch    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_flag(ctx, t, .Step_Mismatch) }
@(export, link_name = "wjr_ValidityState_get_badInput")        wjr_ValidityState_get_badInput        :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_flag(ctx, t, .Bad_Input) }
@(export, link_name = "wjr_ValidityState_get_customError")     wjr_ValidityState_get_customError     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_flag(ctx, t, .Custom_Error) }
@(export, link_name = "wjr_ValidityState_get_valid")           wjr_ValidityState_get_valid           :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return validity_flag(ctx, t, nil) }

// ---- setRangeText(replacement) / setRangeText(replacement, start, end, selectMode) ----

@(private = "file")
set_range_text :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, input: bool) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, t, input ? ifc("HTMLInputElement") : ifc("HTMLTextAreaElement"))
	if o == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "setRangeText", 1, argc) }
	if argc == 2 { return wj.wj_throw_type(ctx, "Failed to execute 'setRangeText': 2 arguments match no overload.") }
	start, end := i32(-1), i32(-1)
	mode := api_decl.SelectionMode.Preserve
	if argc >= 3 {
		s, e: u32
		if !wj.wj_to_uint32(ctx, argv[1], &s, 32, 0) || !wj.wj_to_uint32(ctx, argv[2], &e, 32, 0) { return wj.EXCEPTION }
		if s > e { return wj.wj_throw_dom(ctx, "IndexSizeError", "The start is after the end.") }
		start, end = i32(min(s, u32(max(i32)))), i32(min(e, u32(max(i32))))
		if m := wj.arg(argc, argv, 3); !wj.is_undefined(m) {
			n: uint
			ms := wj.to_cstring_len(ctx, &n, m)
			if ms == nil { return wj.EXCEPTION }
			switch string(([^]u8)(rawptr(ms))[:n]) {
			case "select":   mode = .Select
			case "start":    mode = .Start
			case "end":      mode = .End
			case "preserve": mode = .Preserve
			case:
				wj.JS_FreeCString(ctx, ms)
				return wj.wj_throw_type(ctx, "Failed to execute 'setRangeText': not a valid SelectionMode.")
			}
			wj.JS_FreeCString(ctx, ms)
		}
	}
	s: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &s, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	control := api_decl.Element(o.handle)
	st: abi.Api_Error
	if input { st = jsb.host5(&nothing, api_decl.HTMLInputElement_setRangeText, wj.wr_HTMLInputElement_setRangeText, control, str_view(s), start, end, mode) }
	else { st = jsb.host5(&nothing, api_decl.HTMLTextAreaElement_setRangeText, wj.wr_HTMLTextAreaElement_setRangeText, control, str_view(s), start, end, mode) }
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "setRangeText") : wj.UNDEFINED
}

@(export, link_name = "wjr_HTMLInputElement_setRangeText")
wjr_HTMLInputElement_setRangeText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return set_range_text(ctx, t, argc, argv, true) }
@(export, link_name = "wjr_HTMLTextAreaElement_setRangeText")
wjr_HTMLTextAreaElement_setRangeText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return set_range_text(ctx, t, argc, argv, false) }

// input.valueAsDate: a Date, or null when the type has no date or the value none
@(export, link_name = "wjr_HTMLInputElement_get_valueAsDate")
wjr_HTMLInputElement_get_valueAsDate :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, t, ifc("HTMLInputElement"))
	if o == nil { return wj.EXCEPTION }
	ms: f64
	jsb.host(&ms, api_decl.HTMLInputElement_valueAsDate, wj.wr_HTMLInputElement_valueAsDate, api_decl.Element(o.handle))
	return wj.is_nan(ms) ? wj.NULL : wj.JS_NewDate(ctx, ms)
}

@(export, link_name = "wjr_HTMLInputElement_set_valueAsDate")
wjr_HTMLInputElement_set_valueAsDate :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, t, ifc("HTMLInputElement"))
	if o == nil { return wj.EXCEPTION }
	ms := NAN
	if !wj.is_null(v) {
		if !wj.JS_IsDate(v) { return wj.wj_throw_type(ctx, "Failed to set 'valueAsDate': the value is not a Date.") }
		n := wj.JS_ToNumber(ctx, v)
		if wj.is_exception(n) { return n }
		wj.JS_ToFloat64(ctx, &ms, n)
		wj.JS_FreeValue(ctx, n)
	}
	st := jsb.host(&nothing, api_decl.HTMLInputElement_setValueAsDate, wj.wr_HTMLInputElement_setValueAsDate, api_decl.Element(o.handle), ms)
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "HTMLInputElement.valueAsDate") : wj.UNDEFINED
}

// input.width / height (image buttons): the attributes
@(export, link_name = "wjr_HTMLInputElement_get_width")
wjr_HTMLInputElement_get_width :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return wj_reflect_get(ctx, t, ifc("HTMLInputElement"), "width", i32(Kind.Ulong), 0, 0, 0, 0) }
@(export, link_name = "wjr_HTMLInputElement_set_width")
wjr_HTMLInputElement_set_width :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return wj_reflect_set(ctx, t, ifc("HTMLInputElement"), "width", i32(Kind.Ulong), v, 0, 0, 0) }
@(export, link_name = "wjr_HTMLInputElement_get_height")
wjr_HTMLInputElement_get_height :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return wj_reflect_get(ctx, t, ifc("HTMLInputElement"), "height", i32(Kind.Ulong), 0, 0, 0, 0) }
@(export, link_name = "wjr_HTMLInputElement_set_height")
wjr_HTMLInputElement_set_height :: proc "c" (ctx: ^wj.Context, t, v: wj.JSValue) -> wj.JSValue { return wj_reflect_set(ctx, t, ifc("HTMLInputElement"), "height", i32(Kind.Ulong), v, 0, 0, 0) }

// ---- live lists of forms (collection kinds of src/page/js_dom_collections.odin) ----

@(private = "file")
Form_Collection :: enum i32 { Selected_Options = 18, Fieldset_Elements = 19, Map_Areas = 20, Labels = 21 }

@(private = "file")
live_of :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, iface: i32, kind: Form_Collection, list_iface: i32) -> wj.JSValue {
	o := wj.wj_this(ctx, t, iface)
	if o == nil { return wj.EXCEPTION }
	return wj.dom_live_list(ctx, t, o.handle, i32(kind), nil, 0, list_iface)
}

@(export, link_name = "wjr_HTMLSelectElement_get_selectedOptions")
wjr_HTMLSelectElement_get_selectedOptions :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return live_of(ctx, t, ifc("HTMLSelectElement"), .Selected_Options, ifc("HTMLCollection")) }
@(export, link_name = "wjr_HTMLFieldSetElement_get_elements")
wjr_HTMLFieldSetElement_get_elements :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return live_of(ctx, t, ifc("HTMLFieldSetElement"), .Fieldset_Elements, ifc("HTMLCollection")) }
@(export, link_name = "wjr_HTMLMapElement_get_areas")
wjr_HTMLMapElement_get_areas :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return live_of(ctx, t, ifc("HTMLMapElement"), .Map_Areas, ifc("HTMLCollection")) }

// control.labels: null for a hidden input
@(private = "file")
labels_of :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, iface: i32) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, t, iface)
	if o == nil { return wj.EXCEPTION }
	if iface == ifc("HTMLInputElement") {
		if type, present := attr_read(o.handle, "type"); present && ascii_ieq(type, "hidden") { return wj.NULL }
	}
	return wj.dom_live_list(ctx, t, o.handle, i32(Form_Collection.Labels), nil, 0, ifc("NodeList"))
}

@(export, link_name = "wjr_HTMLInputElement_get_labels")    wjr_HTMLInputElement_get_labels    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return labels_of(ctx, t, ifc("HTMLInputElement")) }
@(export, link_name = "wjr_HTMLButtonElement_get_labels")   wjr_HTMLButtonElement_get_labels   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return labels_of(ctx, t, ifc("HTMLButtonElement")) }
@(export, link_name = "wjr_HTMLSelectElement_get_labels")   wjr_HTMLSelectElement_get_labels   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return labels_of(ctx, t, ifc("HTMLSelectElement")) }
@(export, link_name = "wjr_HTMLTextAreaElement_get_labels") wjr_HTMLTextAreaElement_get_labels :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return labels_of(ctx, t, ifc("HTMLTextAreaElement")) }
@(export, link_name = "wjr_HTMLOutputElement_get_labels")   wjr_HTMLOutputElement_get_labels   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return labels_of(ctx, t, ifc("HTMLOutputElement")) }
@(export, link_name = "wjr_HTMLMeterElement_get_labels")    wjr_HTMLMeterElement_get_labels    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return labels_of(ctx, t, ifc("HTMLMeterElement")) }
@(export, link_name = "wjr_HTMLProgressElement_get_labels") wjr_HTMLProgressElement_get_labels :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return labels_of(ctx, t, ifc("HTMLProgressElement")) }

// select.namedItem(name): its options'
@(export, link_name = "wjr_HTMLSelectElement_namedItem")
wjr_HTMLSelectElement_namedItem :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("HTMLSelectElement")) == nil { return wj.EXCEPTION }
	opts := wj.JS_GetPropertyStr(ctx, t, "options")
	if wj.is_exception(opts) { return opts }
	defer wj.JS_FreeValue(ctx, opts)
	return wjr_HTMLCollection_namedItem(ctx, opts, argc, argv)
}

// ---- Document ----

@(private = "file")
hidden :: proc "contextless" () -> bool {
	context = jsb.glue_context()
	s: api_decl.VisibilityState
	jsb.host(&s, api_decl.Document_visibilityState, wj.wr_Document_visibilityState)
	return s == .Hidden
}

@(export, link_name = "wjr_Document_get_hidden")
wjr_Document_get_hidden :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("Document")) == nil { return wj.EXCEPTION }
	return wj.new_bool(hidden())
}

@(export, link_name = "wjr_Document_get_visibilityState")
wjr_Document_get_visibilityState :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("Document")) == nil { return wj.EXCEPTION }
	return wj.new_string(ctx, hidden() ? "hidden" : "visible")
}

// document.elementsFromPoint, getHTML() and setHTMLUnsafe(): shadow.c

// ---- Element ----

// Pointer capture lives in the browser (src/page/pointer_input.odin): it retargets the pointer's events and fires
// gotpointercapture / lostpointercapture.
@(private = "file")
Capture_Op :: enum { Set, Release, Has }

@(private = "file")
pointer_capture :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, op: Capture_Op, what: cstring) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, t, ifc("Element"))
	if o == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, what, 1, argc) }
	id: i32
	if !wj.wj_to_int32(ctx, argv[0], &id, 32, 0) { return wj.EXCEPTION }
	el := api_decl.Element(o.handle)
	st: abi.Api_Error
	switch op {
	case .Set:     st = jsb.host(&nothing, api_decl.PointerCapture_set, wj.wr_PointerCapture_set, el, id)
	case .Release: st = jsb.host(&nothing, api_decl.PointerCapture_release, wj.wr_PointerCapture_release, el, id)
	case .Has:
		has: bool
		jsb.host(&has, api_decl.PointerCapture_has, wj.wr_PointerCapture_has, el, id)
		return wj.new_bool(has)
	}
	return st != .None ? wj.wj_throw_status(ctx, i32(st), what) : wj.UNDEFINED
}

@(export, link_name = "wjr_Element_setPointerCapture")
wjr_Element_setPointerCapture :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return pointer_capture(ctx, t, argc, argv, .Set, "Element.setPointerCapture") }
@(export, link_name = "wjr_Element_releasePointerCapture")
wjr_Element_releasePointerCapture :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return pointer_capture(ctx, t, argc, argv, .Release, "Element.releasePointerCapture") }
@(export, link_name = "wjr_Element_hasPointerCapture")
wjr_Element_hasPointerCapture :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return pointer_capture(ctx, t, argc, argv, .Has, "Element.hasPointerCapture") }

// The computed style of `el` (getComputedStyle of the realm's global).
@(private = "file")
computed_style :: proc "contextless" (ctx: ^wj.Context, el: wj.JSValue) -> wj.JSValue {
	global := wj.JS_GetGlobalObject(ctx)
	defer wj.JS_FreeValue(ctx, global)
	gcs := wj.JS_GetPropertyStr(ctx, global, "getComputedStyle")
	defer wj.JS_FreeValue(ctx, gcs)
	arg := el
	return wj.JS_Call(ctx, gcs, global, 1, &arg)
}

@(private = "file") visibility_options := [4]cstring{"checkVisibilityCSS", "visibilityProperty", "checkOpacity", "opacityProperty"}

// checkVisibility(options): rendered (it has boxes), and with the options, not visibility:hidden / opacity:0
@(export, link_name = "wjr_Element_checkVisibility")
wjr_Element_checkVisibility :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("Element")) == nil { return wj.EXCEPTION }
	gcr := wj.JS_GetPropertyStr(ctx, t, "getClientRects")
	if wj.is_exception(gcr) { return gcr }
	rects := wj.JS_Call(ctx, gcr, t, 0, nil)
	wj.JS_FreeValue(ctx, gcr)
	if wj.is_exception(rects) { return rects }
	l := wj.JS_GetPropertyStr(ctx, rects, "length")
	wj.JS_FreeValue(ctx, rects)
	n: u32
	wj.JS_ToUint32(ctx, &n, l)
	wj.JS_FreeValue(ctx, l)
	if n == 0 { return wj.FALSE }
	want_visibility, want_opacity: bool
	if opts := wj.arg(argc, argv, 0); wj.is_object(opts) {
		for name, i in visibility_options {
			v := wj.JS_GetPropertyStr(ctx, opts, name)
			if wj.is_exception(v) { return v }
			on := wj.JS_ToBool(ctx, v) != 0
			wj.JS_FreeValue(ctx, v)
			if on { if i < 2 { want_visibility = true } else { want_opacity = true } }
		}
	}
	if !want_visibility && !want_opacity { return wj.TRUE }
	cs := computed_style(ctx, t)
	if wj.is_exception(cs) { return cs }
	defer wj.JS_FreeValue(ctx, cs)
	visible := true
	if want_visibility {
		v := wj.JS_GetPropertyStr(ctx, cs, "visibility")
		s := wj.JS_ToCString(ctx, v)
		if s != nil && !wj.str_eq(s, "visible") { visible = false }
		wj.JS_FreeCString(ctx, s)
		wj.JS_FreeValue(ctx, v)
	}
	if visible && want_opacity {
		// opacity:0 on the element or an ancestor
		cur := wj.JS_DupValue(ctx, t)
		for visible && wj.is_object(cur) {
			s2 := computed_style(ctx, cur)
			if wj.is_exception(s2) { wj.JS_FreeValue(ctx, cur); return s2 }
			op := wj.JS_GetPropertyStr(ctx, s2, "opacity")
			o := 1.0
			num := wj.JS_ToNumber(ctx, op)
			wj.JS_ToFloat64(ctx, &o, num)
			wj.JS_FreeValue(ctx, num)
			wj.JS_FreeValue(ctx, op)
			wj.JS_FreeValue(ctx, s2)
			if o == 0 { visible = false }
			parent := wj.JS_GetPropertyStr(ctx, cur, "parentElement")
			wj.JS_FreeValue(ctx, cur)
			cur = parent
		}
		wj.JS_FreeValue(ctx, cur)
	}
	return wj.new_bool(visible)
}

// [LegacyFactoryFunction]s (HTML §4.8.3, §4.8.11, §4.10.10): new Image(w, h), new Audio(src), new Option(text, value,
// defaultSelected, selected). The element comes from Document.prototype.createElement on the realm's document (a
// script replacing document.createElement does not change them), its attributes and IDL attributes are then set
// through the element itself.
@(private = "file")
factory_element :: proc "contextless" (ctx: ^wj.Context, tag: cstring) -> wj.JSValue {
	doc := wj.JS_GetPropertyStr(ctx, wj.realm_global(), "document")
	if wj.is_exception(doc) { return doc }
	defer wj.JS_FreeValue(ctx, doc)
	create := wj.JS_GetPropertyStr(ctx, wj.realm_proto(ifc("Document")), "createElement")
	defer wj.JS_FreeValue(ctx, create)
	name := wj.new_string(ctx, tag)
	defer wj.JS_FreeValue(ctx, name)
	return wj.JS_Call(ctx, create, doc, 1, &name)
}

// el.setAttribute(attr, String(value)); false with an exception pending
@(private = "file")
factory_set :: proc "contextless" (ctx: ^wj.Context, el: wj.JSValue, attr: cstring, value: wj.JSValue) -> bool {
	fn := wj.JS_GetPropertyStr(ctx, el, "setAttribute")
	defer wj.JS_FreeValue(ctx, fn)
	args := [2]wj.JSValue{wj.new_string(ctx, attr), wj.JS_ToString(ctx, value)}
	defer { wj.JS_FreeValue(ctx, args[0]); wj.JS_FreeValue(ctx, args[1]) }
	if wj.is_exception(args[1]) { return false }
	r := wj.JS_Call(ctx, fn, el, 2, &args[0])
	if wj.is_exception(r) { return false }
	wj.JS_FreeValue(ctx, r)
	return true
}

@(export, link_name = "wjr_HTMLImageElement_factory")
wjr_HTMLImageElement_factory :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Failed to construct 'Image': Please use the 'new' operator, this DOM object constructor cannot be called as a function.") }
	el := factory_element(ctx, "img")
	if wj.is_exception(el) { return el }
	names := [2]cstring{"width", "height"}
	for i in 0 ..< min(int(argc), 2) {
		if wj.is_undefined(argv[i]) { continue }
		if !factory_set(ctx, el, names[i], argv[i]) { wj.JS_FreeValue(ctx, el); return wj.EXCEPTION }
	}
	return el
}

@(export, link_name = "wjr_HTMLAudioElement_factory")
wjr_HTMLAudioElement_factory :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Failed to construct 'Audio': Please use the 'new' operator, this DOM object constructor cannot be called as a function.") }
	el := factory_element(ctx, "audio")
	if wj.is_exception(el) { return el }
	autov := wj.new_string(ctx, "auto")
	ok := factory_set(ctx, el, "preload", autov)
	wj.JS_FreeValue(ctx, autov)
	if ok && argc > 0 && !wj.is_undefined(argv[0]) { ok = factory_set(ctx, el, "src", argv[0]) }
	if !ok { wj.JS_FreeValue(ctx, el); return wj.EXCEPTION }
	return el
}

@(export, link_name = "wjr_HTMLOptionElement_factory")
wjr_HTMLOptionElement_factory :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Failed to construct 'Option': Please use the 'new' operator, this DOM object constructor cannot be called as a function.") }
	el := factory_element(ctx, "option")
	if wj.is_exception(el) { return el }
	ok := true
	if argc > 0 && !wj.is_undefined(argv[0]) {
		s := wj.JS_ToString(ctx, argv[0])
		ok = !wj.is_exception(s) && wj.JS_SetPropertyStr(ctx, el, "textContent", s) >= 0
	}
	if ok && argc > 1 && !wj.is_undefined(argv[1]) { ok = factory_set(ctx, el, "value", argv[1]) }
	if ok && argc > 2 && wj.JS_ToBool(ctx, argv[2]) != 0 {
		empty := wj.new_string(ctx, "")
		ok = factory_set(ctx, el, "selected", empty)
		wj.JS_FreeValue(ctx, empty)
	}
	if ok && argc > 3 { ok = wj.JS_SetPropertyStr(ctx, el, "selected", wj.new_bool(wj.JS_ToBool(ctx, argv[3]) != 0)) >= 0 }
	if !ok { wj.JS_FreeValue(ctx, el); return wj.EXCEPTION }
	return el
}
