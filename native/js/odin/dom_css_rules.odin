// dom_css_rules.odin: the objects of CSSRule's family, made from a rule's serialized text (CSSStyleSheet_ruleText) when
// `sheet.cssRules` is read: the right interface for `instanceof`, and what a script reads of a rule. They are read-only views: a rule's
// `style` is parsed from its text in a detached element, so what is written there, or to `cssText` or `selectorText`, does not reach the sheet.
package odin_glue

import "../odin/wj"

@(private = "file")
Rule_Shape :: struct { iface: cstring, type: i32, at: string }

@(private = "file")
RULE_SHAPES := [?]Rule_Shape{
	{"CSSMediaRule", 4, "@media"}, {"CSSSupportsRule", 12, "@supports"}, {"CSSContainerRule", 0, "@container"},
	{"CSSLayerBlockRule", 0, "@layer"}, {"CSSImportRule", 3, "@import"}, {"CSSFontFaceRule", 5, "@font-face"},
	{"CSSKeyframesRule", 7, "@keyframes"}, {"CSSKeyframesRule", 7, "@-webkit-keyframes"}, {"CSSPageRule", 6, "@page"},
	{"CSSNamespaceRule", 10, "@namespace"},
}

@(private = "file")
is_space :: #force_inline proc "contextless" (c: u8) -> bool { return c == ' ' || c == '\n' || c == '\t' || c == '\r' }

@(private = "file")
trimmed :: proc "contextless" (s: string) -> string {
	a, b := 0, len(s)
	for a < b && is_space(s[a]) { a += 1 }
	for b > a && is_space(s[b - 1]) { b -= 1 }
	return s[a:b]
}

@(private = "file")
index_of :: proc "contextless" (s: string, c: u8) -> int {
	for i in 0 ..< len(s) { if s[i] == c { return i } }
	return -1
}

@(private = "file")
set_text :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring, s: string) {
	wj.web_extra_set(ctx, o, name, wj.new_string_len(ctx, transmute([]u8)s))
}

// The rule whose serialized text is `source`. `sheet`, `parent`: as parentStyleSheet and parentRule.
css_rule_make :: proc "contextless" (ctx: ^wj.Context, source: string, sheet, parent: wj.JSValue) -> wj.JSValue {
	text := trimmed(source)
	shape := Rule_Shape{"CSSStyleRule", 1, ""}
	if len(text) > 0 && text[0] == '@' {
		shape = Rule_Shape{"CSSRule", 0, ""}
		for s in RULE_SHAPES {
			if len(text) > len(s.at) && text[:len(s.at)] == s.at && (is_space(text[len(s.at)]) || text[len(s.at)] == '{' || text[len(s.at)] == ';') { shape = s; break }
		}
	}
	brace := index_of(text, '{')
	head := brace >= 0 ? trimmed(text[:brace]) : text
	if shape.at == "@layer" && brace < 0 { shape.iface = "CSSLayerStatementRule" }
	r := wj.wj_new_object(ctx, wj.iface(shape.iface), nil, nil)
	if wj.is_exception(r) { return r }
	set_text(ctx, r, "cssText", text)
	wj.web_extra_set(ctx, r, "type", wj.new_int32(shape.type))
	wj.web_extra_set(ctx, r, "parentStyleSheet", wj.JS_DupValue(ctx, sheet))
	wj.web_extra_set(ctx, r, "parentRule", wj.JS_DupValue(ctx, parent))
	if shape.at != "" { head = trimmed(head[len(shape.at):]) }
	if len(head) > 0 && head[len(head) - 1] == ';' { head = trimmed(head[:len(head) - 1]) }
	set_text(ctx, r, "head", head)
	if brace >= 0 && len(text) > brace + 1 {
		last := len(text) - 1
		for last > brace && text[last] != '}' { last -= 1 }
		if last > brace { set_text(ctx, r, "body", trimmed(text[brace + 1:last])) }
	}
	return r
}

@(private = "file")
extra_or_null :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, iface: cstring, name: cstring, fallback := wj.NULL) -> wj.JSValue {
	if wj.wj_this(ctx, t, wj.iface(iface)) == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, t, name)
	return wj.is_undefined(v) ? fallback : v
}

@(private = "file")
empty_string :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue { return wj.new_string_len(ctx, nil) }

@(export, link_name = "wjr_CSSRule_get_cssText")
wjr_CSSRule_get_cssText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or_null(ctx, t, "CSSRule", "cssText", empty_string(ctx)) }
@(export, link_name = "wjr_CSSRule_get_type")
wjr_CSSRule_get_type :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or_null(ctx, t, "CSSRule", "type", wj.new_int32(0)) }
@(export, link_name = "wjr_CSSRule_get_parentRule")
wjr_CSSRule_get_parentRule :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or_null(ctx, t, "CSSRule", "parentRule") }
@(export, link_name = "wjr_CSSRule_get_parentStyleSheet")
wjr_CSSRule_get_parentStyleSheet :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or_null(ctx, t, "CSSRule", "parentStyleSheet") }

@(export, link_name = "wjr_CSSStyleRule_get_selectorText")
wjr_CSSStyleRule_get_selectorText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or_null(ctx, t, "CSSStyleRule", "head", empty_string(ctx)) }
// (ignored, as the header says: an invalid selector must leave the rule as it is, and a script's assignment must not throw)
@(export, link_name = "wjr_CSSStyleRule_set_selectorText")
wjr_CSSStyleRule_set_selectorText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	return wj.wj_this(ctx, t, wj.iface("CSSStyleRule")) == nil ? wj.EXCEPTION : wj.UNDEFINED
}

@(export, link_name = "wjr_CSSConditionRule_get_conditionText")
wjr_CSSConditionRule_get_conditionText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or_null(ctx, t, "CSSConditionRule", "head", empty_string(ctx)) }
@(export, link_name = "wjr_CSSLayerBlockRule_get_name")
wjr_CSSLayerBlockRule_get_name :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or_null(ctx, t, "CSSLayerBlockRule", "head", empty_string(ctx)) }
@(export, link_name = "wjr_CSSKeyframesRule_get_name")
wjr_CSSKeyframesRule_get_name :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or_null(ctx, t, "CSSKeyframesRule", "head", empty_string(ctx)) }

// A declaration block as a style object: in a detached element of its own, made once.
@(private = "file")
rule_style :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, iface: cstring) -> wj.JSValue {
	if wj.wj_this(ctx, t, wj.iface(iface)) == nil { return wj.EXCEPTION }
	kept := wj.web_extra_get(ctx, t, "style")
	if !wj.is_undefined(kept) { return kept }
	doc := wj.global_get(ctx, "document")
	defer wj.JS_FreeValue(ctx, doc)
	tag := [1]wj.JSValue{wj.new_string(ctx, "div")}
	defer wj.JS_FreeValue(ctx, tag[0])
	el := wj.invoke(ctx, doc, "createElement", tag[:])
	if wj.is_exception(el) { return el }
	defer wj.JS_FreeValue(ctx, el)
	style := wj.JS_GetPropertyStr(ctx, el, "style")
	if wj.is_exception(style) { return style }
	body := wj.web_extra_get(ctx, t, "body")
	if wj.is_string(body) { wj.JS_SetPropertyStr(ctx, style, "cssText", wj.JS_DupValue(ctx, body)) }
	wj.JS_FreeValue(ctx, body)
	wj.web_extra_set(ctx, t, "style", wj.JS_DupValue(ctx, style))
	return style
}

@(export, link_name = "wjr_CSSStyleRule_get_style")
wjr_CSSStyleRule_get_style :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return rule_style(ctx, t, "CSSStyleRule") }
@(export, link_name = "wjr_CSSFontFaceRule_get_style")
wjr_CSSFontFaceRule_get_style :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return rule_style(ctx, t, "CSSFontFaceRule") }

// The rules of a block: split at the top level of its braces. An array with `item`, as a list made once.
@(private = "file")
nested_rules :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, iface: cstring) -> wj.JSValue {
	if wj.wj_this(ctx, t, wj.iface(iface)) == nil { return wj.EXCEPTION }
	kept := wj.web_extra_get(ctx, t, "rules")
	if !wj.is_undefined(kept) { return kept }
	list := wj.JS_NewArray(ctx)
	sheet := wj.web_extra_get(ctx, t, "parentStyleSheet")
	defer wj.JS_FreeValue(ctx, sheet)
	body := wj.web_extra_get(ctx, t, "body")
	defer wj.JS_FreeValue(ctx, body)
	if wj.is_string(body) {
		text, c, ok := wj.to_string_view(ctx, body)
		if ok {
			defer wj.free_cstring(ctx, c)
			depth, start: int
			n: u32
			for i in 0 ..< len(text) {
				switch text[i] {
				case '{': depth += 1
				case '}':
					depth -= 1
					if depth == 0 {
						wj.array_set(ctx, list, n, css_rule_make(ctx, text[start:i + 1], sheet, t))
						n += 1
						start = i + 1
					}
				case ';':
					if depth == 0 {
						wj.array_set(ctx, list, n, css_rule_make(ctx, text[start:i + 1], sheet, t))
						n += 1
						start = i + 1
					}
				}
			}
		}
	}
	wj.web_extra_set(ctx, t, "rules", wj.JS_DupValue(ctx, list))
	return list
}

@(export, link_name = "wjr_CSSGroupingRule_get_cssRules")
wjr_CSSGroupingRule_get_cssRules :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nested_rules(ctx, t, "CSSGroupingRule") }
@(export, link_name = "wjr_CSSKeyframesRule_get_cssRules")
wjr_CSSKeyframesRule_get_cssRules :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return nested_rules(ctx, t, "CSSKeyframesRule") }
