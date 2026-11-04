// dom_css_rules.odin: the objects of CSSRule's family, made from a rule's serialized text (CSSStyleSheet_ruleText) when
// `sheet.cssRules` is read: the right interface for `instanceof`, and what a script reads of a rule. They are views: a rule's `style` is
// parsed from its text in a detached element; what is written there, or to `selectorText`, reaches the sheet for a top-level style rule
// (JSS's dynamic values, MUI's makeStyles with props), not for a rule inside another one.
package odin_glue

import "core:strconv"
import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file")
Rule_Shape :: struct { iface: cstring, type: i32, at: string }

@(private = "file")
RULE_SHAPES := [?]Rule_Shape{
	{"CSSMediaRule", 4, "@media"}, {"CSSSupportsRule", 12, "@supports"}, {"CSSContainerRule", 0, "@container"},
	{"CSSLayerBlockRule", 0, "@layer"}, {"CSSImportRule", 3, "@import"}, {"CSSFontFaceRule", 5, "@font-face"},
	{"CSSKeyframesRule", 7, "@keyframes"}, {"CSSKeyframesRule", 7, "@-webkit-keyframes"}, {"CSSPageRule", 6, "@page"},
	{"CSSNamespaceRule", 10, "@namespace"}, {"CSSPropertyRule", 0, "@property"},
}

// CSSRule's type constants the rules inside a rule depend on.
@(private = "file")
PAGE_RULE :: 6
@(private = "file")
KEYFRAMES_RULE :: 7

// A keyframe of a @keyframes rule (CSSRule.KEYFRAME_RULE), a margin rule of a @page (MARGIN_RULE).
@(private = "file")
KEYFRAME_SHAPE :: Rule_Shape{"CSSKeyframeRule", 8, ""}
@(private = "file")
MARGIN_SHAPE :: Rule_Shape{"CSSMarginRule", 9, ""}

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

// The rule whose serialized text is `source`. `sheet`, `parent`: as parentStyleSheet and parentRule; `known`: the shape the
// parent says it has (a keyframe, a margin rule), else told from the text.
css_rule_make :: proc "contextless" (ctx: ^wj.Context, source: string, sheet, parent: wj.JSValue, known := Rule_Shape{}) -> wj.JSValue {
	text := trimmed(source)
	shape := Rule_Shape{"CSSStyleRule", 1, ""}
	if known.iface != nil {
		shape = known   // (a margin rule's head is its at-keyword: CSSMarginRule.name)
	} else if len(text) > 0 && text[0] == '@' {
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

// A top-level rule whose style a script may have written gives the browser's text of it now; another, the text it was made with.
@(export, link_name = "wjr_CSSRule_get_cssText")
wjr_CSSRule_get_cssText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, t, wj.iface("CSSRule")) == nil { return wj.EXCEPTION }
	idv := wj.web_extra_get(ctx, t, "id")
	style := wj.web_extra_get(ctx, t, "style")
	sheet := wj.web_extra_get(ctx, t, "parentStyleSheet")
	defer { wj.JS_FreeValue(ctx, idv); wj.JS_FreeValue(ctx, style); wj.JS_FreeValue(ctx, sheet) }
	id: u32
	if o := wj.wj_unwrap(sheet, wj.iface("CSSStyleSheet")); o != nil && o.handle != 0 && !wj.is_undefined(style) && !wj.is_undefined(idv) && wj.JS_ToUint32(ctx, &id, idv) >= 0 {
		text: string
		jsb.host(&text, api_decl.CSSStyleSheet_ruleTextOf, wj.wr_CSSStyleSheet_ruleTextOf, api_decl.CSSStyleSheet(o.handle), id)
		if text != "" { return wj.new_string_len(ctx, transmute([]u8)text) }
	}
	return extra_or_null(ctx, t, "CSSRule", "cssText", empty_string(ctx))
}
@(export, link_name = "wjr_CSSRule_get_type")
wjr_CSSRule_get_type :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or_null(ctx, t, "CSSRule", "type", wj.new_int32(0)) }
@(export, link_name = "wjr_CSSRule_get_parentRule")
wjr_CSSRule_get_parentRule :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or_null(ctx, t, "CSSRule", "parentRule") }
@(export, link_name = "wjr_CSSRule_get_parentStyleSheet")
wjr_CSSRule_get_parentStyleSheet :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or_null(ctx, t, "CSSRule", "parentStyleSheet") }

@(export, link_name = "wjr_CSSStyleRule_get_selectorText")
wjr_CSSStyleRule_get_selectorText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or_null(ctx, t, "CSSStyleRule", "head", empty_string(ctx)) }
// The browser changes a top-level rule's selector and gives its new text back; an invalid selector leaves the rule as it
// is (and a script's assignment does not throw). A rule inside another one is not changed.
@(export, link_name = "wjr_CSSStyleRule_set_selectorText")
wjr_CSSStyleRule_set_selectorText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, t, wj.iface("CSSStyleRule")) == nil { return wj.EXCEPTION }
	id: u32
	idv := wj.web_extra_get(ctx, t, "id")
	defer wj.JS_FreeValue(ctx, idv)
	if wj.is_undefined(idv) || wj.JS_ToUint32(ctx, &id, idv) < 0 { return wj.UNDEFINED }
	sheet := wj.web_extra_get(ctx, t, "parentStyleSheet")
	defer wj.JS_FreeValue(ctx, sheet)
	o := wj.wj_unwrap(sheet, wj.iface("CSSStyleSheet"))
	if o == nil || o.handle == 0 { return wj.UNDEFINED }
	sel, c, ok := wj.to_string_view(ctx, v)
	if !ok { return wj.EXCEPTION }
	defer wj.free_cstring(ctx, c)
	text: string
	jsb.host(&text, api_decl.CSSStyleSheet_setRuleSelector, wj.wr_CSSStyleSheet_setRuleSelector, api_decl.CSSStyleSheet(o.handle), id, sel)
	if text == "" { return wj.UNDEFINED }
	set_text(ctx, t, "cssText", text)
	brace := index_of(text, '{')
	set_text(ctx, t, "head", trimmed(text[:max(brace, 0)]))
	return wj.UNDEFINED
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
	// a top-level rule's: what is written to it reaches the sheet (rule_style_written)
	if id := wj.web_extra_get(ctx, t, "id"); !wj.is_undefined(id) {
		wj.web_extra_set(ctx, style, "ruleId", id)
		wj.web_extra_set(ctx, style, "sheet", wj.web_extra_get(ctx, t, "parentStyleSheet"))
	}
	wj.web_extra_set(ctx, t, "style", wj.JS_DupValue(ctx, style))
	return style
}

// A CSSStyleDeclaration was written (dom_style.odin): when it is a top-level style rule's, the rule takes its declarations.
rule_style_written :: proc "contextless" (ctx: ^wj.Context, style: wj.JSValue) {
	context = jsb.glue_context()
	idv := wj.web_extra_get(ctx, style, "ruleId")
	defer wj.JS_FreeValue(ctx, idv)
	id: u32
	if wj.is_undefined(idv) || wj.JS_ToUint32(ctx, &id, idv) < 0 { return }
	sheet := wj.web_extra_get(ctx, style, "sheet")
	defer wj.JS_FreeValue(ctx, sheet)
	o := wj.wj_unwrap(sheet, wj.iface("CSSStyleSheet"))
	if o == nil || o.handle == 0 { return }
	text := wj.JS_GetPropertyStr(ctx, style, "cssText")
	defer wj.JS_FreeValue(ctx, text)
	decls, c, ok := wj.to_string_view(ctx, text)
	if !ok { return }
	defer wj.free_cstring(ctx, c)
	nothing: abi.Nothing
	jsb.host(&nothing, api_decl.CSSStyleSheet_setRuleStyle, wj.wr_CSSStyleSheet_setRuleStyle, api_decl.CSSStyleSheet(o.handle), id, decls)
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
	known := Rule_Shape{}
	if kind := wj.web_extra_get(ctx, t, "type"); kind == wj.new_int32(PAGE_RULE) { known = MARGIN_SHAPE } else if kind == wj.new_int32(KEYFRAMES_RULE) { known = KEYFRAME_SHAPE }
	if wj.is_string(body) {
		text, c, ok := wj.to_string_view(ctx, body)
		if ok {
			defer wj.free_cstring(ctx, c)
			depth, start: int
			n: u32
			for i in 0 ..< len(text) {
				end := false
				switch text[i] {
				case '{': depth += 1
				case '}': depth -= 1; end = depth == 0
				case ';': end = depth == 0
				}
				if !end { continue }
				piece := trimmed(text[start:i + 1])
				start = i + 1
				// declarations of a style rule or a page beside its rules are no rule (a statement at-rule is)
				if text[i] == ';' && (len(piece) == 0 || piece[0] != '@') { continue }
				wj.array_set(ctx, list, n, css_rule_make(ctx, piece, sheet, t, known))
				n += 1
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

////////////////////////////////
// What a rule's serialized text says of it: the browser writes it in one form (src/page/js_cssom_serialize.odin)

// The longest URL an @import or @namespace rule gives back (the rest is cut).
@(private = "file")
CSS_URL_MAX_BYTES :: 8192

// The most queries a MediaList counts.
@(private = "file")
MEDIA_ITEMS_MAX :: 256

// The text of an extra, a view valid until `c` is freed ("" when it has none).
@(private = "file")
extra_view :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, name: cstring) -> (s: string, c: cstring) {
	v := wj.web_extra_get(ctx, t, name)
	defer wj.JS_FreeValue(ctx, v)
	if !wj.is_string(v) { return "", nil }
	text, cs, ok := wj.to_string_view(ctx, v)
	return ok ? text : "", ok ? cs : nil
}

@(private = "file")
has_prefix :: proc "contextless" (s, prefix: string) -> bool { return len(s) >= len(prefix) && s[:len(prefix)] == prefix }

// The end of the bracket opened just before `from` (len(s) when it is not closed); strings are skipped.
@(private = "file")
closing_paren :: proc "contextless" (s: string, from: int) -> int {
	depth := 1
	for i := from; i < len(s); i += 1 {
		switch s[i] {
		case '"':
			i += 1
			for i < len(s) && s[i] != '"' { if s[i] == '\\' { i += 1 }; i += 1 }
		case '(': depth += 1
		case ')':
			depth -= 1
			if depth == 0 { return i }
		}
	}
	return len(s)
}

// The contents of the first url("...") of `s`, its escapes undone, and what follows it.
@(private = "file")
url_of :: proc "contextless" (ctx: ^wj.Context, s: string) -> (url: wj.JSValue, rest: string) {
	PREFIX :: "url(\""
	at := -1
	for i in 0 ..< len(s) { if has_prefix(s[i:], PREFIX) { at = i; break } }
	if at < 0 { return wj.new_string_len(ctx, nil), s }
	buf: [CSS_URL_MAX_BYTES]u8
	n, i := 0, at + len(PREFIX)
	for i < len(s) && s[i] != '"' {
		if s[i] == '\\' { i += 1 }
		if i < len(s) && n < len(buf) { buf[n] = s[i]; n += 1 }
		i += 1
	}
	end := closing_paren(s, at + len(PREFIX) - 1)
	return wj.new_string_len(ctx, buf[:n]), trimmed(s[min(end + 1, len(s)):])
}

// A MediaList of a media query list's serialization, kept in the rule's extra `name` ([SameObject]).
@(private = "file")
media_list :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, name: cstring, text: string) -> wj.JSValue {
	kept := wj.web_extra_get(ctx, t, name)
	if !wj.is_undefined(kept) { return kept }
	l := wj.wj_new_object(ctx, wj.iface("MediaList"), nil, nil)
	if wj.is_exception(l) { return l }
	set_text(ctx, l, "text", text)
	wj.web_extra_set(ctx, t, name, wj.JS_DupValue(ctx, l))
	return l
}

// The queries of a MediaList: split at the commas outside brackets.
@(private = "file")
media_items :: proc "contextless" (text: string, out: ^[MEDIA_ITEMS_MAX][2]int) -> int {
	if len(text) == 0 { return 0 }
	n, depth, start := 0, 0, 0
	for i in 0 ..= len(text) {
		if i < len(text) {
			switch text[i] {
			case '(': depth += 1
			case ')': depth -= 1
			}
			if text[i] != ',' || depth != 0 { continue }
		}
		if n == MEDIA_ITEMS_MAX { break }
		out[n] = {start, i}
		n += 1
		start = i + 1
	}
	return n
}

// The sheet a MediaList is the media of (StyleSheet.media: its text is the browser's, live), 0 for a rule's.
@(private = "file")
media_sheet :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue) -> api_decl.CSSStyleSheet {
	v := wj.web_extra_get(ctx, t, "sheet")
	defer wj.JS_FreeValue(ctx, v)
	o := wj.wj_unwrap(v, wj.iface("CSSStyleSheet"))
	return o != nil ? api_decl.CSSStyleSheet(o.handle) : 0
}

// A MediaList's text: its sheet's media now, or what its rule says. A view until `c` is freed (when not nil).
@(private = "file")
media_text :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue) -> (text: string, c: cstring) {
	context = jsb.glue_context()
	if sheet := media_sheet(ctx, t); sheet != 0 {
		jsb.host(&text, api_decl.CSSStyleSheet_mediaText, wj.wr_CSSStyleSheet_mediaText, sheet)
		return text, nil
	}
	return extra_view(ctx, t, "text")
}

@(export, link_name = "wjr_MediaList_get_mediaText")
wjr_MediaList_get_mediaText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, wj.iface("MediaList")) == nil { return wj.EXCEPTION }
	text, c := media_text(ctx, t)
	defer if c != nil { wj.free_cstring(ctx, c) }
	return wj.new_string_len(ctx, transmute([]u8)text)
}

// mediaText = v: a constructed sheet's media change (an element's sheet follows its media attribute); a rule's list is a view.
@(export, link_name = "wjr_MediaList_set_mediaText")
wjr_MediaList_set_mediaText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, t, wj.iface("MediaList")) == nil { return wj.EXCEPTION }
	text, c, ok := wj.to_string_view(ctx, v)
	if !ok { return wj.EXCEPTION }
	defer wj.free_cstring(ctx, c)
	if sheet := media_sheet(ctx, t); sheet != 0 {
		nothing: abi.Nothing
		jsb.host(&nothing, api_decl.CSSStyleSheet_setMediaText, wj.wr_CSSStyleSheet_setMediaText, sheet, text)
	}
	return wj.UNDEFINED
}

@(export, link_name = "wjr_MediaList_get_length")
wjr_MediaList_get_length :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, wj.iface("MediaList")) == nil { return wj.EXCEPTION }
	text, c := media_text(ctx, t)
	defer if c != nil { wj.free_cstring(ctx, c) }
	items: [MEDIA_ITEMS_MAX][2]int
	return wj.new_uint32(ctx, u32(media_items(text, &items)))
}

@(export, link_name = "wjr_MediaList_item")
wjr_MediaList_item :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, wj.iface("MediaList")) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "MediaList.item", 1, argc) }
	index: u32
	if wj.JS_ToUint32(ctx, &index, argv[0]) < 0 { return wj.EXCEPTION }
	text, c := media_text(ctx, t)
	defer if c != nil { wj.free_cstring(ctx, c) }
	items: [MEDIA_ITEMS_MAX][2]int
	if index >= u32(media_items(text, &items)) { return wj.NULL }   // (compared as u32: an int is 32 bits in the guest)
	return wj.new_string_len(ctx, transmute([]u8)trimmed(text[items[index][0]:items[index][1]]))
}

@(export, link_name = "wjr_MediaList_length_hook")
wjr_MediaList_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 {
	text, c := media_text(ctx, obj)
	defer if c != nil { wj.free_cstring(ctx, c) }
	items: [MEDIA_ITEMS_MAX][2]int
	return u32(media_items(text, &items))
}

@(export, link_name = "wjr_MediaList_index_get")
wjr_MediaList_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue {
	text, c := media_text(ctx, obj)
	defer if c != nil { wj.free_cstring(ctx, c) }
	items: [MEDIA_ITEMS_MAX][2]int
	found^ = index < u32(media_items(text, &items))
	if !found^ { return wj.UNDEFINED }
	return wj.new_string_len(ctx, transmute([]u8)trimmed(text[items[index][0]:items[index][1]]))
}

// StyleSheet.media ([SameObject]): a MediaList over the sheet's media. (The list holds the sheet, which holds the list
// in an extra: one cycle of two objects, which the collector frees together.)
@(export, link_name = "wjr_StyleSheet_get_media")
wjr_StyleSheet_get_media :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, wj.iface("CSSStyleSheet")) == nil { return wj.EXCEPTION }
	kept := wj.web_extra_get(ctx, t, "media")
	if !wj.is_undefined(kept) { return kept }
	l := wj.wj_new_object(ctx, wj.iface("MediaList"), nil, nil)
	if wj.is_exception(l) { return l }
	wj.web_extra_set(ctx, l, "sheet", wj.JS_DupValue(ctx, t))
	wj.web_extra_set(ctx, t, "media", wj.JS_DupValue(ctx, l))
	return l
}

@(export, link_name = "wjr_CSSMediaRule_get_media")
wjr_CSSMediaRule_get_media :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, wj.iface("CSSMediaRule")) == nil { return wj.EXCEPTION }
	text, c := extra_view(ctx, t, "head")
	defer if c != nil { wj.free_cstring(ctx, c) }
	return media_list(ctx, t, "media", text)
}

// `global[method](head)`, or its `field`: window.matchMedia(head).matches, CSS.supports(head).
@(private = "file")
head_test :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, iface, global, method: cstring, field: cstring = nil) -> wj.JSValue {
	if wj.wj_this(ctx, t, wj.iface(iface)) == nil { return wj.EXCEPTION }
	g := wj.global_get(ctx, global)
	defer wj.JS_FreeValue(ctx, g)
	arg := [1]wj.JSValue{wj.web_extra_get(ctx, t, "head")}
	defer wj.JS_FreeValue(ctx, arg[0])
	r := wj.invoke(ctx, g, method, arg[:])
	if wj.is_exception(r) || field == nil { return r }
	defer wj.JS_FreeValue(ctx, r)
	return wj.JS_GetPropertyStr(ctx, r, field)
}

@(export, link_name = "wjr_CSSMediaRule_get_matches")
wjr_CSSMediaRule_get_matches :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return head_test(ctx, t, "CSSMediaRule", "window", "matchMedia", "matches") }
@(export, link_name = "wjr_CSSSupportsRule_get_matches")
wjr_CSSSupportsRule_get_matches :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return head_test(ctx, t, "CSSSupportsRule", "CSS", "supports") }

@(export, link_name = "wjr_CSSPageRule_get_selectorText")
wjr_CSSPageRule_get_selectorText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or_null(ctx, t, "CSSPageRule", "head", empty_string(ctx)) }
// The longest head a setter writes (a page selector, a keyframe's keys): the rest is cut.
@(private = "file")
CSS_HEAD_MAX_BYTES :: 1024

// Text written into a fixed buffer (the glue has no allocator to lend): what does not fit is dropped.
@(private = "file")
Text_Buf :: struct { b: [CSS_HEAD_MAX_BYTES]u8, n: int }

@(private = "file")
put :: proc "contextless" (t: ^Text_Buf, s: string) {
	k := min(len(s), len(t.b) - t.n)
	copy(t.b[t.n:t.n + k], s[:k])
	t.n += k
}

@(private = "file")
text_of :: #force_inline proc "contextless" (t: ^Text_Buf) -> string { return string(t.b[:t.n]) }

// A new head for the rule's view: its cssText becomes `prefix`, the head (after a space when there is one), then its block.
@(private = "file")
set_head :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, prefix, head: string) {
	text, c := extra_view(ctx, t, "cssText")
	defer if c != nil { wj.free_cstring(ctx, c) }
	set_text(ctx, t, "head", head)
	block := text[max(index_of(text, '{'), 0):]
	sep := prefix != "" && head != "" ? " " : ""
	n := len(prefix) + len(sep) + len(head) + 1 + len(block)
	buf := ([^]u8)(wj.malloc(uint(n)))
	if buf == nil { return }
	defer wj.free(buf)
	at := 0
	for part in ([5]string{prefix, sep, head, " ", block}) {
		copy(buf[at:at + len(part)], part)
		at += len(part)
	}
	set_text(ctx, t, "cssText", string(buf[:n]))
}

// The pseudo-classes of a page selector (CSS Paged Media §3.1).
@(private = "file")
PAGE_PSEUDOS :: [?]string{"first", "left", "right", "blank"}

// selectorText = v: a page name and pseudo-classes without spaces between (name:first:left), else nothing changes.
@(export, link_name = "wjr_CSSPageRule_set_selectorText")
wjr_CSSPageRule_set_selectorText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, wj.iface("CSSPageRule")) == nil { return wj.EXCEPTION }
	sel, c, ok := wj.to_string_view(ctx, v)
	if !ok { return wj.EXCEPTION }
	defer wj.free_cstring(ctx, c)
	rest := trimmed(sel)
	out: Text_Buf
	name_end := index_of(rest, ':')
	if name_end < 0 { name_end = len(rest) }
	for ch in transmute([]u8)rest[:name_end] { if !(ch == '-' || ch == '_' || (ch >= '0' && ch <= '9') || (ch | 0x20 >= 'a' && ch | 0x20 <= 'z') || ch >= 0x80) { return wj.UNDEFINED } }
	put(&out, rest[:name_end])
	rest = rest[name_end:]
	for len(rest) > 0 {
		rest = rest[1:]   // (the ':')
		end := index_of(rest, ':')
		if end < 0 { end = len(rest) }
		known := false
		pseudos := PAGE_PSEUDOS
		for name in pseudos {
			if !wj.ascii_ieq(rest[:end], name) { continue }
			put(&out, ":")
			put(&out, name)
			known = true
		}
		if !known { return wj.UNDEFINED }
		rest = rest[end:]
	}
	set_head(ctx, t, "@page", text_of(&out))
	return wj.UNDEFINED
}

// keyText = v: percentages from 0% to 100%, `from` and `to`, comma-separated (normalized: "from, 50.0%" is "0%, 50%");
// SyntaxError for anything else.
@(export, link_name = "wjr_CSSKeyframeRule_set_keyText")
wjr_CSSKeyframeRule_set_keyText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	PERCENT_MAX :: 100
	context = jsb.glue_context()   // (strconv's: it allocates nothing)
	if wj.wj_this(ctx, t, wj.iface("CSSKeyframeRule")) == nil { return wj.EXCEPTION }
	keys, c, ok := wj.to_string_view(ctx, v)
	if !ok { return wj.EXCEPTION }
	defer wj.free_cstring(ctx, c)
	out: Text_Buf
	for rest := keys; true; {
		end := index_of(rest, ',')
		key := trimmed(rest[:end < 0 ? len(rest) : end])
		if out.n > 0 { put(&out, ", ") }
		switch {
		case wj.ascii_ieq(key, "from"): put(&out, "0%")
		case wj.ascii_ieq(key, "to"): put(&out, "100%")
		case len(key) > 1 && key[len(key) - 1] == '%':
			n, good := strconv.parse_f64(key[:len(key) - 1])
			if !good || !(n >= 0 && n <= PERCENT_MAX) { return wj.wj_throw_dom(ctx, "SyntaxError", "The key is not a keyframe selector.") }
			buf: [32]u8
			s := strconv.write_float(buf[:], n, 'f', -1, 64)
			if len(s) > 0 && s[0] == '+' { s = s[1:] }
			if len(s) > 2 && s[len(s) - 2:] == ".0" { s = s[:len(s) - 2] }
			put(&out, s)
			put(&out, "%")
		case: return wj.wj_throw_dom(ctx, "SyntaxError", "The key is not a keyframe selector.")
		}
		if end < 0 { break }
		rest = rest[end + 1:]
	}
	set_head(ctx, t, "", text_of(&out))
	return wj.UNDEFINED
}

@(export, link_name = "wjr_CSSPageRule_get_style")
wjr_CSSPageRule_get_style :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return rule_style(ctx, t, "CSSPageRule") }
@(export, link_name = "wjr_CSSKeyframeRule_get_keyText")
wjr_CSSKeyframeRule_get_keyText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or_null(ctx, t, "CSSKeyframeRule", "head", empty_string(ctx)) }
@(export, link_name = "wjr_CSSKeyframeRule_get_style")
wjr_CSSKeyframeRule_get_style :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return rule_style(ctx, t, "CSSKeyframeRule") }
@(export, link_name = "wjr_CSSMarginRule_get_style")
wjr_CSSMarginRule_get_style :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return rule_style(ctx, t, "CSSMarginRule") }

@(export, link_name = "wjr_CSSMarginRule_get_name")
wjr_CSSMarginRule_get_name :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, wj.iface("CSSMarginRule")) == nil { return wj.EXCEPTION }
	text, c := extra_view(ctx, t, "head")
	defer if c != nil { wj.free_cstring(ctx, c) }
	return wj.new_string_len(ctx, transmute([]u8)(len(text) > 0 ? text[1:] : text))
}

@(export, link_name = "wjr_CSSKeyframesRule_get_length")
wjr_CSSKeyframesRule_get_length :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	rules := nested_rules(ctx, t, "CSSKeyframesRule")
	if wj.is_exception(rules) { return rules }
	defer wj.JS_FreeValue(ctx, rules)
	return wj.JS_GetPropertyStr(ctx, rules, "length")
}

@(export, link_name = "wjr_CSSKeyframesRule_length_hook")
wjr_CSSKeyframesRule_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 {
	n: u32
	v := wjr_CSSKeyframesRule_get_length(ctx, obj)
	if !wj.is_exception(v) { wj.JS_ToUint32(ctx, &n, v) }
	wj.JS_FreeValue(ctx, v)
	return n
}

@(export, link_name = "wjr_CSSKeyframesRule_index_get")
wjr_CSSKeyframesRule_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue {
	found^ = false
	rules := nested_rules(ctx, obj, "CSSKeyframesRule")
	if wj.is_exception(rules) { return rules }
	defer wj.JS_FreeValue(ctx, rules)
	v := wj.JS_GetPropertyUint32(ctx, rules, index)
	found^ = !wj.is_undefined(v)
	return v
}

// findRule(select): the last keyframe whose keyText is `select` (from and to as 0% and 100%).
@(export, link_name = "wjr_CSSKeyframesRule_findRule")
wjr_CSSKeyframesRule_findRule :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "CSSKeyframesRule.findRule", 1, argc) }
	rules := nested_rules(ctx, t, "CSSKeyframesRule")
	if wj.is_exception(rules) { return rules }
	defer wj.JS_FreeValue(ctx, rules)
	want, wc, ok := wj.to_string_view(ctx, argv[0])
	if !ok { return wj.EXCEPTION }
	defer wj.free_cstring(ctx, wc)
	want = trimmed(want)
	if wj.ascii_ieq(want, "from") { want = "0%" } else if wj.ascii_ieq(want, "to") { want = "100%" }
	for i := wjr_CSSKeyframesRule_length_hook(ctx, t); i > 0; i -= 1 {
		r := wj.JS_GetPropertyUint32(ctx, rules, i - 1)
		key, kc := extra_view(ctx, r, "head")
		same := key == want
		if kc != nil { wj.free_cstring(ctx, kc) }
		if same { return r }
		wj.JS_FreeValue(ctx, r)
	}
	return wj.NULL
}

@(private = "file")
url_rule_href :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, iface: cstring) -> wj.JSValue {
	if wj.wj_this(ctx, t, wj.iface(iface)) == nil { return wj.EXCEPTION }
	text, c := extra_view(ctx, t, "head")
	defer if c != nil { wj.free_cstring(ctx, c) }
	url, _ := url_of(ctx, text)
	return url
}

@(export, link_name = "wjr_CSSImportRule_get_href")
wjr_CSSImportRule_get_href :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return url_rule_href(ctx, t, "CSSImportRule") }
@(export, link_name = "wjr_CSSNamespaceRule_get_namespaceURI")
wjr_CSSNamespaceRule_get_namespaceURI :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return url_rule_href(ctx, t, "CSSNamespaceRule") }

// What an @import says past its URL: layer or layer(name), supports(condition), then the media queries.
@(private = "file")
Import_Part :: enum u8 { Layer, Supports, Media }

@(private = "file")
import_part :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, which: Import_Part) -> wj.JSValue {
	if wj.wj_this(ctx, t, wj.iface("CSSImportRule")) == nil { return wj.EXCEPTION }
	text, c := extra_view(ctx, t, "head")
	defer if c != nil { wj.free_cstring(ctx, c) }
	url, rest := url_of(ctx, text)
	wj.JS_FreeValue(ctx, url)
	layer, supports := wj.NULL, wj.NULL
	switch {
	case has_prefix(rest, "layer("):
		end := closing_paren(rest, len("layer("))
		layer = wj.new_string_len(ctx, transmute([]u8)trimmed(rest[len("layer("):end]))
		rest = trimmed(rest[min(end + 1, len(rest)):])
	case has_prefix(rest, "layer") && (len(rest) == len("layer") || is_space(rest[len("layer")])):
		layer = empty_string(ctx)
		rest = trimmed(rest[len("layer"):])
	}
	if has_prefix(rest, "supports(") {
		end := closing_paren(rest, len("supports("))
		supports = wj.new_string_len(ctx, transmute([]u8)trimmed(rest[len("supports("):end]))
		rest = trimmed(rest[min(end + 1, len(rest)):])
	}
	switch which {
	case .Layer: wj.JS_FreeValue(ctx, supports); return layer
	case .Supports: wj.JS_FreeValue(ctx, layer); return supports
	case .Media:
	}
	wj.JS_FreeValue(ctx, layer)
	wj.JS_FreeValue(ctx, supports)
	return media_list(ctx, t, "media", rest)
}

@(export, link_name = "wjr_CSSImportRule_get_layerName")
wjr_CSSImportRule_get_layerName :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return import_part(ctx, t, .Layer) }
@(export, link_name = "wjr_CSSImportRule_get_supportsText")
wjr_CSSImportRule_get_supportsText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return import_part(ctx, t, .Supports) }
@(export, link_name = "wjr_CSSImportRule_get_media")
wjr_CSSImportRule_get_media :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return import_part(ctx, t, .Media) }

@(export, link_name = "wjr_CSSNamespaceRule_get_prefix")
wjr_CSSNamespaceRule_get_prefix :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, wj.iface("CSSNamespaceRule")) == nil { return wj.EXCEPTION }
	text, c := extra_view(ctx, t, "head")
	defer if c != nil { wj.free_cstring(ctx, c) }
	end := 0
	for end < len(text) && !is_space(text[end]) && !has_prefix(text[end:], "url(") { end += 1 }
	return wj.new_string_len(ctx, transmute([]u8)text[:end])
}

@(export, link_name = "wjr_CSSLayerStatementRule_get_nameList")
wjr_CSSLayerStatementRule_get_nameList :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, wj.iface("CSSLayerStatementRule")) == nil { return wj.EXCEPTION }
	text, c := extra_view(ctx, t, "head")
	defer if c != nil { wj.free_cstring(ctx, c) }
	list := wj.JS_NewArray(ctx)
	n: u32
	start := 0
	for i in 0 ..= len(text) {
		if i < len(text) && text[i] != ',' { continue }
		if name := trimmed(text[start:i]); name != "" { wj.array_set(ctx, list, n, wj.new_string_len(ctx, transmute([]u8)name)); n += 1 }
		start = i + 1
	}
	return list
}

// A descriptor of a @property block ("syntax", "inherits", "initial-value") as written.
@(private = "file")
descriptor_of :: proc "contextless" (body, name: string) -> (string, bool) {
	start := 0
	for i in 0 ..= len(body) {
		if i < len(body) && body[i] != ';' { continue }
		d := trimmed(body[start:i])
		start = i + 1
		if colon := index_of(d, ':'); colon > 0 && trimmed(d[:colon]) == name { return trimmed(d[colon + 1:]), true }
	}
	return "", false
}

@(private = "file")
property_descriptor :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, name: string) -> wj.JSValue {
	if wj.wj_this(ctx, t, wj.iface("CSSPropertyRule")) == nil { return wj.EXCEPTION }
	text, c := extra_view(ctx, t, "body")
	defer if c != nil { wj.free_cstring(ctx, c) }
	v, ok := descriptor_of(text, name)
	switch name {
	case "syntax":
		if len(v) >= 2 && v[0] == '"' { v = v[1:len(v) - 1] }   // a <string>: its contents
		return wj.new_string_len(ctx, transmute([]u8)v)
	case "inherits": return wj.new_bool(v == "true")
	}
	return ok ? wj.new_string_len(ctx, transmute([]u8)v) : wj.NULL
}

@(export, link_name = "wjr_CSSPropertyRule_get_name")
wjr_CSSPropertyRule_get_name :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return extra_or_null(ctx, t, "CSSPropertyRule", "head", empty_string(ctx)) }
@(export, link_name = "wjr_CSSPropertyRule_get_syntax")
wjr_CSSPropertyRule_get_syntax :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return property_descriptor(ctx, t, "syntax") }
@(export, link_name = "wjr_CSSPropertyRule_get_inherits")
wjr_CSSPropertyRule_get_inherits :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return property_descriptor(ctx, t, "inherits") }
@(export, link_name = "wjr_CSSPropertyRule_get_initialValue")
wjr_CSSPropertyRule_get_initialValue :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return property_descriptor(ctx, t, "initial-value") }
