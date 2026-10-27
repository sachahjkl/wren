package page

// CSSOM stylesheets for JavaScript (api/js_cssom.widl, api/js_shadow.widl; native/js/runtime/shadow.c):
//   * constructed sheets (new CSSStyleSheet(), replace / replaceSync, adoptedStyleSheets: CSSOM §6.1.2);
//   * the sheets of <style> and <link rel=stylesheet> elements (LinkStyle.sheet, document.styleSheets,
//     shadowRoot.styleSheets), which scripts read and change like the others: CSS-in-JS libraries (Emotion, which MUI
//     and so React sites use, styled-components, JSS) create an empty <style> and fill it with sheet.insertRule, one
//     rule at a time; without `sheet` they throw before the first render and the page stays blank.
// An object here is a handle on one of the style engine's sheets; the rules and their texts are the engine's
// (src/style/cssom.odin). An element's sheet keeps one object for as long as the element keeps that sheet (a new text
// makes a new sheet, and a new object, as in other browsers).

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:style"

@(private)
Css_Sheet :: struct {
	id:      u64,            // the engine's sheet
	owner:   base.Handle,    // an element's sheet: its <style> or <link>; NIL_HANDLE for a constructed sheet
	media:   string,         // constructed: its media text (owned)
	version: u32,            // bumped by every change of its rules: the script's rule list rebuilds its items then
}

// The objects of the element sheets scripts have seen, by engine sheet (js_dom_collections.odin keeps it).
Js_Cssom :: struct {
	by_sheet:  map[u64]u64,       // engine sheet id -> object handle
	list:      [dynamic]u64,      // the last styleSheets list, of `list_root` ...
	list_root: base.Handle,
	list_key:  [3]u64,            // ... while the document's mutations, the sheet ids made and the sheet count are these
}

@(private)
js_cssom_destroy :: proc(p: ^Page, s: ^Js_Cssom) {
	delete(s.by_sheet)
	delete(s.list)
	s^ = {}
}

@(private)
css_sheet_vt := Object_VTable{name = "CSSStyleSheet", destroy = proc(p: ^Page, data: rawptr) {
	s := (^Css_Sheet)(data)
	if s.owner == base.NIL_HANDLE {
		if !p.closed && p.engine != nil { style.engine_constructed_destroy(p.engine, s.id) }
	} else if p.jsdom != nil {
		delete_key(&p.jsdom.cssom.by_sheet, s.id)
	}
	delete(s.media)
	free(s)
}}

@(private)
css_sheet_of :: proc(c: ^Call, h: u64) -> ^Css_Sheet {
	if c.page.engine == nil { return nil }
	return (^Css_Sheet)(object_data(c.page, h, &css_sheet_vt))
}

// The object of an element's engine sheet, made on first use. Objects of sheets that went away (their element got a
// new text, left the document) are released once they are as many as the sheets that remain.
@(private)
element_sheet_object :: proc(c: ^Call, s: ^style.Sheet) -> u64 {
	p := c.page
	st := &js_dom_state(p).cssom
	if h, ok := st.by_sheet[s.id]; ok && object_data(p, h, &css_sheet_vt) != nil { return h }
	if len(st.by_sheet) > 2 * len(p.engine.sheets) + 16 {
		gone := make([dynamic]u64, context.temp_allocator)
		for id, h in st.by_sheet { if style.engine_find_sheet(p.engine, id) == nil { append(&gone, h) } }
		for h in gone { object_release(p, h) }   // (its destroy forgets it)
	}
	cs := new(Css_Sheet)
	cs.id, cs.owner = s.id, s.owner
	h := object_create(p, &css_sheet_vt, cs, c.owner)
	st.by_sheet[s.id] = h
	return h
}

// The page's document, when the call is about it (sheets belong to the page's document only).
@(private)
cssom_doc :: proc(c: ^Call) -> ^dom.Document {
	d := call_doc(c)
	return d != nil && d == c.page.doc && c.page.engine != nil ? d : nil
}

LinkStyle_sheetOf :: proc(c: ^Call, node: Api_Node) -> u64 {
	p := c.page
	d := cssom_doc(c)
	if d == nil { return 0 }
	h := H(node.handle)
	n := dom.get(d, h)
	if n == nil || n.kind != .Element { return 0 }
	s: ^style.Sheet
	switch n.name {
	case "style":
		s = style.engine_style_element_sheet(p.engine, d, h, p.env.location.href)
		if s != nil {
			start_pending_imports(p)   // (a new sheet's @import rules load as the document's sync would start them)
			p.style_stale = true
		}
	case "link":
		s = style.engine_sheet_of_owner(p.engine, h)
		if s != nil && !s.from_link { s = nil }
	}
	return s != nil ? element_sheet_object(c, s) : 0
}

// document.styleSheets / shadowRoot.styleSheets: the list is made again only when the document, or its sheets, changed.
@(private)
tree_sheet_list :: proc(c: ^Call, root: Api_Node) -> []u64 {
	p := c.page
	d := cssom_doc(c)
	if d == nil { return nil }
	r := H(root.handle)
	if r != d.root && !dom.is_shadow_root(d, r) { return nil }
	st := &js_dom_state(p).cssom
	key := [3]u64{d.mutations, p.engine.next_sheet_id, u64(len(p.engine.sheets))}
	if st.list_root == r && st.list_key == key {
		live := true
		for h in st.list { if object_data(p, h, &css_sheet_vt) == nil { live = false; break } }
		if live { return st.list[:] }
	}
	ids := style.engine_tree_sheets(p.engine, d, r, p.env.location.href)
	start_pending_imports(p)
	clear(&st.list)
	for id in ids {
		if s := style.engine_find_sheet(p.engine, id); s != nil { append(&st.list, element_sheet_object(c, s)) }
	}
	st.list_root = r
	st.list_key = {d.mutations, p.engine.next_sheet_id, u64(len(p.engine.sheets))}   // (bringing <style> sheets up to date may have made some)
	return st.list[:]
}

DocumentOrShadowRoot_sheetCount :: proc(c: ^Call, root: Api_Node) -> u32 { return u32(len(tree_sheet_list(c, root))) }

DocumentOrShadowRoot_sheetAt :: proc(c: ^Call, root: Api_Node, index: u32) -> u64 {
	l := tree_sheet_list(c, root)
	return int(index) < len(l) ? l[index] : 0
}

CSSStyleSheet_isSheet :: proc(c: ^Call, sheet: u64) -> bool { return css_sheet_of(c, sheet) != nil }

CSSStyleSheet_isConstructed :: proc(c: ^Call, sheet: u64) -> bool {
	s := css_sheet_of(c, sheet)
	return s != nil && s.owner == base.NIL_HANDLE
}

// The element of an element's sheet while that element still has it (0: a constructed sheet, or one it lost).
@(private)
sheet_owner_now :: proc(c: ^Call, s: ^Css_Sheet) -> base.Handle {
	if s == nil || s.owner == base.NIL_HANDLE { return base.NIL_HANDLE }
	es := style.engine_find_sheet(c.page.engine, s.id)
	return es != nil && es.owner == s.owner && dom.get(c.page.doc, s.owner) != nil ? s.owner : base.NIL_HANDLE
}

CSSStyleSheet_ownerNodeOf :: proc(c: ^Call, sheet: u64) -> u64 { return u64(sheet_owner_now(c, css_sheet_of(c, sheet))) }

// sheet.href: the URL a <link>'s sheet came from ("" for null: a <style>'s or a constructed sheet).
CSSStyleSheet_hrefOf :: proc(c: ^Call, sheet: u64) -> string {
	s := css_sheet_of(c, sheet)
	if s == nil || s.owner == base.NIL_HANDLE { return "" }
	es := style.engine_find_sheet(c.page.engine, s.id)
	return es != nil && es.from_link ? es.base_url : ""
}

// sheet.title: the owner's title attribute ("" for null).
CSSStyleSheet_titleOf :: proc(c: ^Call, sheet: u64) -> string {
	o := sheet_owner_now(c, css_sheet_of(c, sheet))
	if o == base.NIL_HANDLE { return "" }
	t, _ := dom.get_attribute(c.page.doc, o, "title")
	return t
}

CSSStyleSheet_ruleId :: proc(c: ^Call, sheet: u64, index: u32) -> u32 {
	s := css_sheet_of(c, sheet)
	return s != nil ? style.engine_sheet_rule_id(c.page.engine, s.id, int(index)) : 0
}

CSSStyleSheet_rulesVersion :: proc(c: ^Call, sheet: u64) -> u32 {
	s := css_sheet_of(c, sheet)
	return s != nil ? s.version : 0
}

////////////////////////////////
// Constructed sheets and the rule lists of every sheet

CSSStyleSheet_create :: proc(c: ^Call, media: string, disabled: bool, base_url: string) -> u64 {
	p := c.page
	if p.engine == nil { return 0 }
	s := new(Css_Sheet)
	s.media = strings.clone(media)
	s.id = style.engine_constructed_create(p.engine, "", media, base_url != "" ? base_url : p.env.location.href)
	if disabled { style.engine_constructed_set_disabled(p.engine, s.id, true) }
	return object_create(p, &css_sheet_vt, s, c.owner)
}

CSSStyleSheet_replaceText :: proc(c: ^Call, sheet: u64, text: string) -> Api_Error {
	s := css_sheet_of(c, sheet)
	if s == nil || s.owner != base.NIL_HANDLE { return fail(c, .Not_Allowed, "Failed to execute 'replace' on 'CSSStyleSheet': Can't call replace on non-constructed CSSStyleSheets.") }
	kept := make([dynamic]string, context.temp_allocator)
	for r in style.split_rules(text) {
		if style.is_import_text(r) { continue }   // replace() and replaceSync() ignore @import (CSSOM §6.1.2)
		append(&kept, r)
	}
	style.engine_constructed_replace(c.page.engine, s.id, strings.join(kept[:], "\n", context.temp_allocator))
	s.version += 1
	return .None
}

CSSStyleSheet_ruleCount :: proc(c: ^Call, sheet: u64) -> u32 {
	s := css_sheet_of(c, sheet)
	return s != nil ? u32(style.engine_sheet_rule_count(c.page.engine, s.id)) : 0
}

CSSStyleSheet_ruleText :: proc(c: ^Call, sheet: u64, index: u32) -> (string, Api_Error) {
	s := css_sheet_of(c, sheet)
	if s != nil {
		if t, ok := style.engine_sheet_rule_text(c.page.engine, s.id, int(index)); ok { return t, .None }
	}
	return "", fail(c, .Index_Size, "The index is past the end of the rule list.")
}

@(private)
rule_edit_fail :: proc(c: ^Call, err: style.Rule_Edit_Error, op: string) -> Api_Error {
	switch err {
	case .None:      return .None
	case .No_Sheet:  return fail(c, .Invalid_State, fmt.tprintf("Failed to execute '%s' on 'CSSStyleSheet': the stylesheet is no longer in the document.", op))
	case .Index:     return fail(c, .Index_Size, fmt.tprintf("Failed to execute '%s' on 'CSSStyleSheet': The index provided is larger than the maximum index.", op))
	case .Syntax:    return fail(c, .Syntax, fmt.tprintf("Failed to execute '%s' on 'CSSStyleSheet': Failed to parse the rule.", op))
	case .Hierarchy: return fail(c, .Hierarchy, fmt.tprintf("Failed to execute '%s' on 'CSSStyleSheet': @import rules must come before every other rule.", op))
	case .Import:    return fail(c, .Not_Supported, fmt.tprintf("Failed to execute '%s' on 'CSSStyleSheet': inserting or removing an @import rule of an element's stylesheet is not supported.", op))
	case .Too_Many:  return fail(c, .Quota, fmt.tprintf("Failed to execute '%s' on 'CSSStyleSheet': the stylesheet has style.max_rules rules already.", op))
	}
	return .None
}

CSSStyleSheet_insertRuleAt :: proc(c: ^Call, sheet: u64, rule: string, index: u32) -> (u32, Api_Error) {
	s := css_sheet_of(c, sheet)
	if s == nil { return 0, fail(c, .Invalid_Handle, "not a stylesheet") }
	err := style.engine_sheet_insert_rule(c.page.engine, s.id, rule, int(index))
	if err == .Syntax && s.owner == base.NIL_HANDLE && style.is_import_text(strings.trim_space(rule)) {
		return 0, fail(c, .Syntax, "Failed to execute 'insertRule' on 'CSSStyleSheet': Can't insert @import rules into a constructed stylesheet.")
	}
	if err != .None { return 0, rule_edit_fail(c, err, "insertRule") }
	s.version += 1
	return index, .None
}

CSSStyleSheet_deleteRuleAt :: proc(c: ^Call, sheet: u64, index: u32) -> Api_Error {
	s := css_sheet_of(c, sheet)
	if s == nil { return fail(c, .Invalid_Handle, "not a stylesheet") }
	if err := style.engine_sheet_delete_rule(c.page.engine, s.id, int(index)); err != .None { return rule_edit_fail(c, err, "deleteRule") }
	s.version += 1
	return .None
}

CSSStyleSheet_isDisabled :: proc(c: ^Call, sheet: u64) -> bool {
	s := css_sheet_of(c, sheet)
	if s == nil { return false }
	sh := style.engine_find_sheet(c.page.engine, s.id)
	return sh != nil && sh.disabled
}

CSSStyleSheet_setDisabled :: proc(c: ^Call, sheet: u64, disabled: bool) {
	if s := css_sheet_of(c, sheet); s != nil { style.engine_sheet_set_disabled(c.page.engine, s.id, disabled) }
}

CSSStyleSheet_mediaText :: proc(c: ^Call, sheet: u64) -> string {
	s := css_sheet_of(c, sheet)
	if s == nil { return "" }
	if s.owner == base.NIL_HANDLE { return s.media }
	sh := style.engine_find_sheet(c.page.engine, s.id)
	return sh != nil ? sh.media_text : ""
}

CSSStyleSheet_setMediaText :: proc(c: ^Call, sheet: u64, media: string) {
	s := css_sheet_of(c, sheet)
	if s == nil || s.owner != base.NIL_HANDLE { return }   // (an element's sheet follows its media attribute)
	delete(s.media)
	s.media = strings.clone(media)
	style.engine_constructed_set_media(c.page.engine, s.id, media)
}
