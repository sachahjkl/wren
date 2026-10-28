// dom_style.odin: CSSOM for JavaScript: element.style and getComputedStyle (CSSStyleDeclaration / CSSStyleProperties),
// with one attribute per CSS property in its camel-cased, webkit-cased and dashed spellings (CSSOM §6.7.1), defined
// once on the prototype at pre-initialization (wj_dom_preinit). Ported from native/js/runtime/dom_style.c with the same
// behaviour and symbols. The values are the browser's (src/page/js_dom_style.odin).
package odin_glue

import "../odin/wj"

// CSS properties that get attributes (the standard ones browsers expose); "float" is cssFloat.
@(private = "file") css_properties := [?]string{
	"accent-color", "align-content", "align-items", "align-self", "all", "animation", "animation-composition",
	"animation-delay", "animation-direction", "animation-duration", "animation-fill-mode", "animation-iteration-count",
	"animation-name", "animation-play-state", "animation-timing-function", "appearance", "aspect-ratio",
	"backdrop-filter", "backface-visibility", "background", "background-attachment", "background-blend-mode",
	"background-clip", "background-color", "background-image", "background-origin", "background-position",
	"background-position-x", "background-position-y", "background-repeat", "background-size", "block-size", "border",
	"border-block", "border-block-color", "border-block-end", "border-block-end-color", "border-block-end-style",
	"border-block-end-width", "border-block-start", "border-block-start-color", "border-block-start-style",
	"border-block-start-width", "border-block-style", "border-block-width", "border-bottom", "border-bottom-color",
	"border-bottom-left-radius", "border-bottom-right-radius", "border-bottom-style", "border-bottom-width",
	"border-collapse", "border-color", "border-end-end-radius", "border-end-start-radius", "border-image",
	"border-inline", "border-inline-color", "border-inline-end", "border-inline-end-color", "border-inline-end-style",
	"border-inline-end-width", "border-inline-start", "border-inline-start-color", "border-inline-start-style",
	"border-inline-start-width", "border-inline-style", "border-inline-width", "border-left", "border-left-color",
	"border-left-style", "border-left-width", "border-radius", "border-right", "border-right-color", "border-right-style",
	"border-right-width", "border-spacing", "border-start-end-radius", "border-start-start-radius", "border-style",
	"border-top", "border-top-color", "border-top-left-radius", "border-top-right-radius", "border-top-style",
	"border-top-width", "border-width", "bottom", "box-shadow", "box-sizing", "break-after", "break-before",
	"break-inside", "caption-side", "caret-color", "clear", "clip", "clip-path", "color", "color-scheme", "column-count",
	"column-gap", "column-rule", "column-width", "columns", "contain", "container", "container-name", "container-type",
	"content", "content-visibility", "counter-increment", "counter-reset", "counter-set", "cursor", "direction",
	"display", "empty-cells", "fill", "filter", "flex", "flex-basis", "flex-direction", "flex-flow", "flex-grow",
	"flex-shrink", "flex-wrap", "float", "font", "font-family", "font-feature-settings", "font-kerning", "font-size",
	"font-stretch", "font-style", "font-variant", "font-variant-caps", "font-variant-east-asian",
	"font-variant-ligatures", "font-variant-numeric", "font-variant-position", "font-variation-settings", "font-weight",
	"gap", "grid", "grid-area", "grid-auto-columns", "grid-auto-flow", "grid-auto-rows", "grid-column",
	"grid-column-end", "grid-column-gap", "grid-column-start", "grid-gap", "grid-row", "grid-row-end", "grid-row-gap",
	"grid-row-start", "grid-template", "grid-template-areas", "grid-template-columns", "grid-template-rows", "height",
	"hyphens", "image-rendering", "inline-size", "inset", "inset-block", "inset-block-end", "inset-block-start",
	"inset-inline", "inset-inline-end", "inset-inline-start", "isolation", "justify-content", "justify-items",
	"justify-self", "left", "letter-spacing", "line-break", "line-height", "list-style", "list-style-image",
	"list-style-position", "list-style-type", "margin", "margin-block", "margin-block-end", "margin-block-start",
	"margin-bottom", "margin-inline", "margin-inline-end", "margin-inline-start", "margin-left", "margin-right",
	"margin-top", "mask", "mask-clip", "mask-composite", "mask-image", "mask-mode", "mask-origin", "mask-position",
	"mask-repeat", "mask-size", "max-block-size", "max-height", "max-inline-size", "max-width", "min-block-size",
	"min-height", "min-inline-size", "min-width", "mix-blend-mode", "object-fit", "object-position", "opacity", "order",
	"outline", "outline-color", "outline-offset", "outline-style", "outline-width", "overflow", "overflow-anchor",
	"overflow-wrap", "overflow-x", "overflow-y", "overscroll-behavior", "overscroll-behavior-x",
	"overscroll-behavior-y", "padding", "padding-block", "padding-block-end", "padding-block-start", "padding-bottom",
	"padding-inline", "padding-inline-end", "padding-inline-start", "padding-left", "padding-right", "padding-top",
	"page-break-after", "page-break-before", "page-break-inside", "perspective", "perspective-origin", "place-content",
	"place-items", "place-self", "pointer-events", "position", "quotes", "resize", "right", "rotate", "row-gap",
	"scale", "scroll-behavior", "scroll-margin", "scroll-padding", "scroll-snap-align", "scroll-snap-type",
	"scrollbar-color", "scrollbar-gutter", "scrollbar-width", "stroke", "stroke-width", "tab-size", "table-layout",
	"text-align", "text-align-last", "text-decoration", "text-decoration-color", "text-decoration-line",
	"text-decoration-style", "text-decoration-thickness", "text-indent", "text-overflow", "text-rendering",
	"text-shadow", "text-transform", "text-underline-offset", "text-wrap", "text-wrap-mode", "text-wrap-style", "top",
	"touch-action", "transform", "transform-box", "transform-origin", "transform-style", "transition",
	"transition-behavior", "transition-delay", "transition-duration", "transition-property",
	"transition-timing-function", "translate", "unicode-bidi", "user-select", "vertical-align", "visibility",
	"white-space", "white-space-collapse", "width", "will-change", "word-break", "word-spacing", "word-wrap",
	"writing-mode", "z-index", "zoom",
	"-webkit-align-items", "-webkit-animation", "-webkit-appearance", "-webkit-backface-visibility",
	"-webkit-background-clip", "-webkit-border-radius", "-webkit-box-shadow", "-webkit-box-sizing", "-webkit-filter",
	"-webkit-flex", "-webkit-flex-direction", "-webkit-justify-content", "-webkit-line-clamp", "-webkit-mask",
	"-webkit-mask-image", "-webkit-text-fill-color", "-webkit-text-size-adjust", "-webkit-text-stroke",
	"-webkit-transform", "-webkit-transform-origin", "-webkit-transition", "-webkit-user-select",
}

@(private = "file") iface_style := i32(-2)
@(private = "file") iface_style_props := i32(-2)
@(private = "file") i_style :: proc "c" () -> i32 { if iface_style == -2 { iface_style = wj.iface("CSSStyleDeclaration") }; return iface_style }
@(private = "file") i_style_props :: proc "c" () -> i32 { if iface_style_props == -2 { iface_style_props = wj.iface("CSSStyleProperties") }; return iface_style_props }

@(private = "file")
style_of_this :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^wj.Dom_Impl { return wj.dom_impl_of(ctx, this_val, i_style()) }

@(private = "file")
style_get :: proc "c" (ctx: ^wj.Context, d: ^wj.Dom_Impl, name: [^]u8, length: uint) -> wj.JSValue {
	n: i32
	if d.kind == wj.DOM_STYLE_COMPUTED {
		dn := d.name != nil ? d.name : wj.raw_bytes("")
		n = wj.wr_ComputedStyle_get(d.node, dn, u32(d.name_len), name, u32(length), wj.wj_scratch.data, wj.wj_scratch.cap)
		if n > 0 && u32(n) > wj.wj_scratch.cap { if wj.wj_scratch_grow(u32(n)) { n = wj.wr_ComputedStyle_get(d.node, dn, u32(d.name_len), name, u32(length), wj.wj_scratch.data, wj.wj_scratch.cap) } }
	} else {
		n = wj.wr_InlineStyle_getProperty(d.node, name, u32(length), wj.wj_scratch.data, wj.wj_scratch.cap)
		if n > 0 && u32(n) > wj.wj_scratch.cap { if wj.wj_scratch_grow(u32(n)) { n = wj.wr_InlineStyle_getProperty(d.node, name, u32(length), wj.wj_scratch.data, wj.wj_scratch.cap) } }
	}
	return n < 0 ? wj.JS_NewString(ctx, "") : wj.JS_NewStringLen(ctx, wj.wj_scratch.data, uint(n))
}

@(private = "file")
read_only_err :: proc "c" (ctx: ^wj.Context) -> wj.JSValue {
	return wj.wj_throw_dom(ctx, "NoModificationAllowedError", "Failed to set a property on 'CSSStyleDeclaration': These styles are computed, and therefore read-only.")
}

@(private = "file")
style_set :: proc "c" (ctx: ^wj.Context, d: ^wj.Dom_Impl, name: [^]u8, length: uint, value: wj.JSValue, priority: wj.JSValue) -> wj.JSValue {
	if d.kind == wj.DOM_STYLE_COMPUTED { return read_only_err(ctx) }
	v, p: wj.Str
	if !wj.wj_to_str(ctx, value, &v, wj.STR_NULL_EMPTY, "") { return wj.EXCEPTION }
	if !wj.wj_to_str(ctx, priority, &p, wj.STR_NULL_EMPTY | wj.STR_OPTIONAL, "") { wj.wj_str_free(ctx, &v); return wj.EXCEPTION }
	st := wj.wr_InlineStyle_setProperty(d.node, name, u32(length), wj.cstr_bytes(v.ptr), u32(v.len), wj.cstr_bytes(p.ptr), u32(p.len))
	wj.wj_str_free(ctx, &v)
	wj.wj_str_free(ctx, &p)
	return st < 0 ? wj.wj_throw_status(ctx, st, "CSSStyleDeclaration.setProperty") : wj.UNDEFINED
}

// the attributes of the properties: data = the CSS name
@(private = "file")
prop_getter :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	d := style_of_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	length: uint
	name := wj.JS_ToCStringLen(ctx, &length, data[0])
	if name == nil { return wj.EXCEPTION }
	r := style_get(ctx, d, wj.cstr_bytes(name), length)
	wj.JS_FreeCString(ctx, name)
	return r
}

@(private = "file")
prop_setter :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	d := style_of_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	length: uint
	name := wj.JS_ToCStringLen(ctx, &length, data[0])
	if name == nil { return wj.EXCEPTION }
	r := style_set(ctx, d, wj.cstr_bytes(name), length, argc > 0 ? argv[0] : wj.UNDEFINED, wj.UNDEFINED)
	wj.JS_FreeCString(ctx, name)
	return r
}

// build a NUL-terminated name into `buf`: prefix ("get "/"set ") + attr. buf must be large enough.
@(private = "file")
build_accessor_name :: proc "c" (buf: []u8, prefix: string, attr: []u8) -> cstring {
	k := 0
	for c in transmute([]u8)prefix { buf[k] = c; k += 1 }
	for i := 0; attr[i] != 0 && k < len(buf) - 1; i += 1 { buf[k] = attr[i]; k += 1 }
	buf[k] = 0
	return cstring(&buf[0])
}

@(private = "file")
define_prop :: proc "c" (ctx: ^wj.Context, proto: wj.JSValue, attr: cstring, css: cstring) {
	name := wj.JS_NewString(ctx, css)
	gbuf, sbuf: [96]u8
	attr_bytes := ([^]u8)(rawptr(attr))
	// find attr length
	al := 0
	for attr_bytes[al] != 0 { al += 1 }
	attr_slice := attr_bytes[:al + 1]
	gname := build_accessor_name(gbuf[:], "get ", attr_slice)
	sname := build_accessor_name(sbuf[:], "set ", attr_slice)
	data := [1]wj.JSValue{ name }
	g := wj.JS_NewCFunctionData2(ctx, prop_getter, gname, 0, 0, 1, &data[0])
	s := wj.JS_NewCFunctionData2(ctx, prop_setter, sname, 1, 0, 1, &data[0])
	wj.JS_FreeValue(ctx, name)
	a := wj.JS_NewAtom(ctx, attr)
	wj.JS_DefinePropertyGetSet(ctx, proto, a, g, s, wj.PROP_CONFIGURABLE | wj.PROP_ENUMERABLE)
	wj.JS_FreeAtom(ctx, a)
}

// camel-cased attribute of a CSS name: margin-top -> marginTop; with webkit_lower, -webkit-x -> webkitX (else WebkitX)
@(private = "file")
camel :: proc "c" (css: string, out: []u8, webkit_lower: bool) -> cstring {
	o := 0
	i := 0
	up := false
	if len(css) > 0 && css[0] == '-' {
		i = 1
		if !webkit_lower { up = true }
	}
	for ; i < len(css) && o + 1 < len(out); i += 1 {
		c := css[i]
		if c == '-' { up = true; continue }
		if up && c >= 'a' && c <= 'z' { c -= 32 }
		up = false
		out[o] = c; o += 1
	}
	out[o] = 0
	return cstring(&out[0])
}

@(export, link_name = "wj_dom_preinit")
wj_dom_preinit :: proc "c" (ctx: ^wj.Context) -> i32 {
	proto := wj.wj_the_realm.protos[i_style_props()]
	if !wj.is_object(proto) { return 0 }
	for css in css_properties {
		cssz: [128]u8
		for i in 0..<len(css) { cssz[i] = css[i] }
		cssz[len(css)] = 0
		css_c := cstring(&cssz[0])
		name: [128]u8
		if css != "float" {
			define_prop(ctx, proto, camel(css, name[:], true), css_c)
			if css[0] == '-' {
				define_prop(ctx, proto, camel(css, name[:], false), css_c)
			}
		}
		if contains_dash(css) { define_prop(ctx, proto, css_c, css_c) }
	}
	return 0
}

@(private = "file") contains_dash :: proc "c" (s: string) -> bool { for c in transmute([]u8)s { if c == '-' { return true } }; return false }

// ---- the objects ----

@(export, link_name = "wjr_ElementCSSInlineStyle_get_style")
wjr_ElementCSSInlineStyle_get_style :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, iface_element())
	if o == nil { return wj.EXCEPTION }
	return wj.dom_new(ctx, i_style_props(), wj.DOM_STYLE_INLINE, this_val, o.handle, nil)
}

@(export, link_name = "wjr_Window_getComputedStyle")
wjr_Window_getComputedStyle :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface_win_style()) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Window.getComputedStyle", 1, argc) }
	el := wj.wj_unwrap(argv[0], iface_element())
	if el == nil || el.handle == 0 { return wj.wj_throw_type(ctx, "Failed to execute 'getComputedStyle' on 'Window': parameter 1 is not of type 'Element'.") }
	pseudo: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 1), &pseudo, wj.STR_NULLABLE, "") { return wj.EXCEPTION }
	d: ^wj.Dom_Impl
	obj := wj.dom_new(ctx, i_style_props(), wj.DOM_STYLE_COMPUTED, argv[0], el.handle, &d)
	if !wj.is_exception(obj) && pseudo.ptr != nil && pseudo.len > 0 {
		d.name = wj.dom_strndup(wj.cstr_bytes(pseudo.ptr), pseudo.len)
		d.name_len = pseudo.len
	}
	wj.wj_str_free(ctx, &pseudo)
	return obj
}

@(private = "file") iface_window_s := i32(-2)
@(private = "file") iface_win_style :: proc "c" () -> i32 { if iface_window_s == -2 { iface_window_s = wj.iface("Window") }; return iface_window_s }

@(export, link_name = "wjr_CSSStyleDeclaration_length_hook")
wjr_CSSStyleDeclaration_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 {
	o := wj.obj_of(obj)
	d := o != nil ? (^wj.Dom_Impl)(o.impl) : nil
	if d == nil { return 0 }
	if d.kind == wj.DOM_STYLE_COMPUTED { return wj.wr_ComputedStyle_count() }
	if d.kind == wj.DOM_STYLE_INLINE { return wj.wr_InlineStyle_length(d.node) }
	return 0
}

@(private = "file")
item_of :: proc "c" (ctx: ^wj.Context, d: ^wj.Dom_Impl, i: u32) -> wj.JSValue {
	n: i32
	if d.kind == wj.DOM_STYLE_COMPUTED {
		n = wj.wr_ComputedStyle_name(i, wj.wj_scratch.data, wj.wj_scratch.cap)
		if n > 0 && u32(n) > wj.wj_scratch.cap { if wj.wj_scratch_grow(u32(n)) { n = wj.wr_ComputedStyle_name(i, wj.wj_scratch.data, wj.wj_scratch.cap) } }
	} else {
		n = wj.wr_InlineStyle_item(d.node, i, wj.wj_scratch.data, wj.wj_scratch.cap)
		if n > 0 && u32(n) > wj.wj_scratch.cap { if wj.wj_scratch_grow(u32(n)) { n = wj.wr_InlineStyle_item(d.node, i, wj.wj_scratch.data, wj.wj_scratch.cap) } }
	}
	return n <= 0 ? wj.JS_NewString(ctx, "") : wj.JS_NewStringLen(ctx, wj.wj_scratch.data, uint(n))
}

@(export, link_name = "wjr_CSSStyleDeclaration_index_get")
wjr_CSSStyleDeclaration_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue {
	o := wj.obj_of(obj)
	d := o != nil ? (^wj.Dom_Impl)(o.impl) : nil
	found^ = false
	if d == nil || index >= wjr_CSSStyleDeclaration_length_hook(ctx, obj) { return wj.UNDEFINED }
	found^ = true
	return item_of(ctx, d, index)
}

@(export, link_name = "wjr_CSSStyleDeclaration_get_length")
wjr_CSSStyleDeclaration_get_length :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if style_of_this(ctx, this_val) == nil { return wj.EXCEPTION }
	return wj.new_uint32(ctx, wjr_CSSStyleDeclaration_length_hook(ctx, this_val))
}

@(export, link_name = "wjr_CSSStyleDeclaration_item")
wjr_CSSStyleDeclaration_item :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := style_of_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "CSSStyleDeclaration.item", 1, argc) }
	i: u32
	if !wj.wj_to_uint32(ctx, argv[0], &i, 32, 0) { return wj.EXCEPTION }
	return item_of(ctx, d, i)
}

@(export, link_name = "wjr_CSSStyleDeclaration_getPropertyValue")
wjr_CSSStyleDeclaration_getPropertyValue :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := style_of_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "CSSStyleDeclaration.getPropertyValue", 1, argc) }
	s: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &s, 0, "") { return wj.EXCEPTION }
	r := style_get(ctx, d, wj.cstr_bytes(s.ptr), s.len)
	wj.wj_str_free(ctx, &s)
	return r
}

@(export, link_name = "wjr_CSSStyleDeclaration_getPropertyPriority")
wjr_CSSStyleDeclaration_getPropertyPriority :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := style_of_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "CSSStyleDeclaration.getPropertyPriority", 1, argc) }
	if d.kind == wj.DOM_STYLE_COMPUTED { return wj.JS_NewString(ctx, "") }
	s: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &s, 0, "") { return wj.EXCEPTION }
	n := wj.wr_InlineStyle_priority(d.node, wj.cstr_bytes(s.ptr), u32(s.len), wj.wj_scratch.data, wj.wj_scratch.cap)
	if n > 0 && u32(n) > wj.wj_scratch.cap { if wj.wj_scratch_grow(u32(n)) { n = wj.wr_InlineStyle_priority(d.node, wj.cstr_bytes(s.ptr), u32(s.len), wj.wj_scratch.data, wj.wj_scratch.cap) } }
	wj.wj_str_free(ctx, &s)
	return n <= 0 ? wj.JS_NewString(ctx, "") : wj.JS_NewStringLen(ctx, wj.wj_scratch.data, uint(n))
}

@(export, link_name = "wjr_CSSStyleDeclaration_setProperty")
wjr_CSSStyleDeclaration_setProperty :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := style_of_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "CSSStyleDeclaration.setProperty", 2, argc) }
	s: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &s, 0, "") { return wj.EXCEPTION }
	r := style_set(ctx, d, wj.cstr_bytes(s.ptr), s.len, argv[1], wj.arg(argc, argv, 2))
	wj.wj_str_free(ctx, &s)
	return r
}

@(export, link_name = "wjr_CSSStyleDeclaration_removeProperty")
wjr_CSSStyleDeclaration_removeProperty :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := style_of_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "CSSStyleDeclaration.removeProperty", 1, argc) }
	if d.kind == wj.DOM_STYLE_COMPUTED { return read_only_err(ctx) }
	s: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &s, 0, "") { return wj.EXCEPTION }
	// not retried: the removal happens once
	n := wj.wr_InlineStyle_removeProperty(d.node, wj.cstr_bytes(s.ptr), u32(s.len), wj.wj_scratch.data, wj.wj_scratch.cap)
	wj.wj_str_free(ctx, &s)
	if n < 0 { return wj.wj_throw_status(ctx, n, "CSSStyleDeclaration.removeProperty") }
	if u32(n) > wj.wj_scratch.cap { n = i32(wj.wj_scratch.cap) }
	return wj.JS_NewStringLen(ctx, wj.wj_scratch.data, uint(n))
}

@(export, link_name = "wjr_CSSStyleDeclaration_get_cssText")
wjr_CSSStyleDeclaration_get_cssText :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	d := style_of_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	if d.kind == wj.DOM_STYLE_COMPUTED { return wj.JS_NewString(ctx, "") }
	n := wj.wr_InlineStyle_cssText(d.node, wj.wj_scratch.data, wj.wj_scratch.cap)
	if n > 0 && u32(n) > wj.wj_scratch.cap { if wj.wj_scratch_grow(u32(n)) { n = wj.wr_InlineStyle_cssText(d.node, wj.wj_scratch.data, wj.wj_scratch.cap) } }
	return n <= 0 ? wj.JS_NewString(ctx, "") : wj.JS_NewStringLen(ctx, wj.wj_scratch.data, uint(n))
}

@(export, link_name = "wjr_CSSStyleDeclaration_set_cssText")
wjr_CSSStyleDeclaration_set_cssText :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	d := style_of_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	if d.kind == wj.DOM_STYLE_COMPUTED { return read_only_err(ctx) }
	s: wj.Str
	if !wj.wj_to_str(ctx, v, &s, wj.STR_NULL_EMPTY, "") { return wj.EXCEPTION }
	st := wj.wr_InlineStyle_setCssText(d.node, wj.cstr_bytes(s.ptr), u32(s.len))
	wj.wj_str_free(ctx, &s)
	return st < 0 ? wj.wj_throw_status(ctx, st, "CSSStyleDeclaration.cssText") : wj.UNDEFINED
}

@(export, link_name = "wjr_CSSStyleDeclaration_get_parentRule")
wjr_CSSStyleDeclaration_get_parentRule :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return style_of_this(ctx, this_val) != nil ? wj.NULL : wj.EXCEPTION }

@(export, link_name = "wjr_CSSStyleProperties_get_cssFloat")
wjr_CSSStyleProperties_get_cssFloat :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	d := style_of_this(ctx, this_val)
	return d != nil ? style_get(ctx, d, wj.raw_bytes("float"), 5) : wj.EXCEPTION
}

@(export, link_name = "wjr_CSSStyleProperties_set_cssFloat")
wjr_CSSStyleProperties_set_cssFloat :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	d := style_of_this(ctx, this_val)
	return d != nil ? style_set(ctx, d, wj.raw_bytes("float"), 5, v, wj.UNDEFINED) : wj.EXCEPTION
}

// ---- the CSS namespace ----

@(export, link_name = "wjr_CSS_supports")
wjr_CSS_supports :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_type(ctx, "Failed to execute 'supports' on 'CSS': 1 argument required, but only 0 present.") }
	a, b: wj.Str
	b = wj.Str{}
	if !wj.wj_to_str(ctx, argv[0], &a, 0, "") { return wj.EXCEPTION }
	r: bool
	if argc >= 2 {
		if !wj.wj_to_str(ctx, argv[1], &b, 0, "") { wj.wj_str_free(ctx, &a); return wj.EXCEPTION }
		r = wj.wr_CSS_supportsDeclaration(wj.cstr_bytes(a.ptr), u32(a.len), wj.cstr_bytes(b.ptr), u32(b.len)) != 0
		wj.wj_str_free(ctx, &b)
	} else {
		r = wj.wr_CSS_supportsCondition(wj.cstr_bytes(a.ptr), u32(a.len)) != 0
	}
	wj.wj_str_free(ctx, &a)
	return wj.new_bool(r)
}

@(export, link_name = "wjr_CSS_escape")
wjr_CSS_escape :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_type(ctx, "Failed to execute 'escape' on 'CSS': 1 argument required, but only 0 present.") }
	s := wj.JS_ToString(ctx, argv[0])
	if wj.is_exception(s) { return s }
	length: uint
	utf8 := wj.JS_ToCStringLen(ctx, &length, s)
	wj.JS_FreeValue(ctx, s)
	if utf8 == nil { return wj.EXCEPTION }
	cap := length * 8 + 1
	buf := ([^]u8)(wj.js_malloc(ctx, cap))
	if buf == nil { wj.JS_FreeCString(ctx, utf8); return wj.EXCEPTION }
	p := ([^]u8)(rawptr(utf8))
	o := uint(0)
	count := uint(0)
	first_dash := length > 0 && p[0] == '-'
	i := uint(0)
	for i < length {
		c := p[i]
		cl := c < 0x80 ? uint(1) : c < 0xE0 ? uint(2) : c < 0xF0 ? uint(3) : uint(4)
		if i + cl > length { cl = length - i }
		if c == 0 {
			buf[o] = 0xEF; buf[o+1] = 0xBF; buf[o+2] = 0xBD; o += 3   // U+FFFD
		} else if (c >= 0x01 && c <= 0x1F) || c == 0x7F || (count == 0 && c >= '0' && c <= '9') || (count == 1 && first_dash && c >= '0' && c <= '9') {
			o += write_hex_escape(buf[o:], c)
		} else if count == 0 && c == '-' && length == 1 {
			buf[o] = '\\'; buf[o+1] = '-'; o += 2
		} else if c >= 0x80 || c == '-' || c == '_' || (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') {
			for k in 0..<cl { buf[o + k] = p[i + k] }
			o += cl
		} else {
			buf[o] = '\\'; buf[o+1] = c; o += 2
		}
		i += cl
		count += 1
	}
	out := wj.JS_NewStringLen(ctx, buf, o)
	wj.js_free(ctx, buf)
	wj.JS_FreeCString(ctx, utf8)
	return out
}

// write "\<hex> " (a code point escape, as C's snprintf(buf, "\\%x ", c)). Returns bytes written.
@(private = "file")
write_hex_escape :: proc "c" (buf: [^]u8, c: u8) -> uint {
	digits := "0123456789abcdef"
	dg := transmute([]u8)digits
	o := uint(0)
	buf[o] = '\\'; o += 1
	if c >= 0x10 { buf[o] = dg[c >> 4]; o += 1 }
	buf[o] = dg[c & 0xF]; o += 1
	buf[o] = ' '; o += 1
	return o
}
