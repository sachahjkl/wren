package style

// The CSSOM rule list of a sheet (insertRule, deleteRule, cssRules), for the sheet of a <style> or a <link> as for a
// constructed one. A sheet gets its list the first time a script asks (Cssom_List): the text of each top-level rule
// beside the parsed rule, the sheet's `sheet.rules` then being a view of that list. Inserting a rule parses only that
// rule, into the sheet's own memory, so a library that inserts its rules one at a time (Emotion, styled-components,
// JSS: thousands of insertRule calls into one empty <style>) costs one rule's parse each, not the whole sheet's.
//
// The element's text stays the sheet's `source`: the document's sync (document.odin) keeps the sheet, rules a script
// changed included, while the text of the <style> does not change; a new text makes a new sheet (HTML "update a style
// block"), as in other browsers.

import "core:strings"
import "wb:base"
import "wb:css"
import "wb:dom"

Cssom_List :: struct {
	rules: [dynamic]^css.Rule,   // the sheet's top-level rules, in order (Sheet.sheet.rules is a view of it)
	texts: [dynamic]string,      // the text of each (owned): what cssRules[i].cssText gives
	ids:   [dynamic]u32,         // a number per rule, never reused in the engine: a script's CSSRule object stays that rule's
}

Rule_Edit_Error :: enum u8 {
	None,
	No_Sheet,     // the sheet is gone
	Index,        // IndexSizeError
	Syntax,       // SyntaxError: not one valid rule (or an @import into a constructed sheet)
	Hierarchy,    // HierarchyRequestError: a rule placed before an @import
	Import,       // inserting or deleting an @import of an element's sheet: not supported (its load is the page's)
	Too_Many,     // past style.max_rules
}

@(private)
cssom_list_free :: proc(s: ^Sheet) {
	l := s.cssom
	if l == nil { return }
	for t in l.texts { delete(t) }
	delete(l.texts)
	delete(l.rules)
	delete(l.ids)
	free(l)
	s.cssom = nil
}

// The top-level rules of a stylesheet's text, as written (the source of each, trimmed): what cssRules lists.
// Strings, comments and nested blocks are skipped over; a rule ends at its block's closing brace, or at a semicolon
// for a statement at-rule.
split_rules :: proc(text: string, allocator := context.temp_allocator) -> [dynamic]string {
	out := make([dynamic]string, allocator)
	depth, start := 0, 0
	i := 0
	for i < len(text) {
		ch := text[i]
		switch {
		case ch == '/' && i + 1 < len(text) && text[i + 1] == '*':
			end := strings.index(text[i + 2:], "*/")
			if start == i && depth == 0 { start = end < 0 ? len(text) : i + 2 + end + 2 }   // a comment before a rule
			i = end < 0 ? len(text) : i + 2 + end + 2
			continue
		case ch == '"' || ch == '\'':
			i += 1
			for i < len(text) && text[i] != ch {
				if text[i] == '\\' { i += 1 }
				i += 1
			}
		case ch == '{': depth += 1
		case ch == '}':
			depth -= 1
			if depth <= 0 {
				depth = 0
				if r := strings.trim_space(text[start:i + 1]); r != "" { append(&out, r) }
				start = i + 1
			}
		case ch == ';' && depth == 0:
			if r := strings.trim_space(text[start:i + 1]); r != "" { append(&out, r) }
			start = i + 1
		}
		i += 1
	}
	if r := strings.trim_space(text[min(start, len(text)):]); r != "" { append(&out, r) }
	return out
}

is_import_text :: proc(r: string) -> bool { return len(r) >= 7 && strings.equal_fold(r[:7], "@import") }

// The sheet's list, made on first use. When its text splits into as many rules as were parsed (a sheet without
// invalid rules: nearly always) the parsed rules are taken as they are; otherwise each piece is parsed alone, so that
// the texts and the rules agree one to one (a piece that is not a valid rule is left out of both, as the parser left
// it out). @import rules keep the rule their load slot points to.
@(private)
cssom_list :: proc(e: ^Engine, s: ^Sheet) -> ^Cssom_List {
	if s.cssom != nil { return s.cssom }
	l := new(Cssom_List)
	pieces := split_rules(s.sheet.source)
	if len(pieces) == len(s.sheet.rules) {
		append(&l.rules, ..s.sheet.rules)
		for t in pieces { append(&l.texts, strings.clone(t)) }
	} else {
		opt := parse_options(&e.settings)
		imp := 0
		for t in pieces {
			if is_import_text(t) {
				if imp < len(s.imports) {
					append(&l.rules, s.imports[imp].rule)
					append(&l.texts, strings.clone(t))
					imp += 1
				}
				continue
			}
			r := css.parse_rule_into(s.sheet, t, opt)
			if r == nil || r.kind == .Import { continue }
			append(&l.rules, r)
			append(&l.texts, strings.clone(t))
		}
	}
	for _ in l.rules { e.next_rule_id += 1; append(&l.ids, e.next_rule_id) }
	s.sheet.rules = l.rules[:]
	s.cssom = l
	return l
}

// The text of what the sheet holds now: its source, or its rules joined once a script changed them (the rule sets of
// shadow trees are keyed by and parsed again from it: scope.odin).
sheet_rules_text :: proc(s: ^Sheet, allocator := context.temp_allocator) -> string {
	if s.sheet == nil { return "" }
	if s.cssom == nil { return s.sheet.source }
	return strings.join(s.cssom.texts[:], "\n", allocator)
}

@(private)
cssom_sheet :: proc(e: ^Engine, id: u64) -> ^Sheet {
	s := engine_find_sheet(e, id)
	return s != nil && s.sheet != nil ? s : nil
}

// cssRules.length
engine_sheet_rule_count :: proc(e: ^Engine, id: u64) -> int {
	s := cssom_sheet(e, id)
	return s != nil ? len(cssom_list(e, s).rules) : 0
}

// cssRules[index].cssText; false past the end.
engine_sheet_rule_text :: proc(e: ^Engine, id: u64, index: int) -> (string, bool) {
	s := cssom_sheet(e, id)
	if s == nil { return "", false }
	l := cssom_list(e, s)
	if index < 0 || index >= len(l.texts) { return "", false }
	return l.texts[index], true
}

// The identity of cssRules[index] (0 past the end).
engine_sheet_rule_id :: proc(e: ^Engine, id: u64, index: int) -> u32 {
	s := cssom_sheet(e, id)
	if s == nil { return 0 }
	l := cssom_list(e, s)
	return index >= 0 && index < len(l.ids) ? l.ids[index] : 0
}

// CSSOM "insert a CSS rule" at `index`.
engine_sheet_insert_rule :: proc(e: ^Engine, id: u64, text: string, index: int) -> Rule_Edit_Error {
	s := cssom_sheet(e, id)
	if s == nil { return .No_Sheet }
	l := cssom_list(e, s)
	if index < 0 || index > len(l.rules) { return .Index }
	t := strings.trim_space(text)
	if len(split_rules(t)) != 1 { return .Syntax }
	opt := parse_options(&e.settings)
	if len(l.rules) >= opt.max_rules { return .Too_Many }
	r := css.parse_rule_into(s.sheet, t, opt)
	if r == nil { return .Syntax }
	if r.kind == .Import { return s.constructed ? .Syntax : .Import }
	// @import rules come before every other rule
	if index < len(l.rules) && l.rules[index].kind == .Import { return .Hierarchy }
	inject_at(&l.rules, index, r)
	inject_at(&l.texts, index, strings.clone(t))
	e.next_rule_id += 1
	inject_at(&l.ids, index, e.next_rule_id)
	s.sheet.rules = l.rules[:]
	s.version += 1
	sheet_changed(e, s)
	return .None
}

// sheet.disabled = v, for any sheet a script holds (an element's sheet stops applying while its element stays).
engine_sheet_set_disabled :: proc(e: ^Engine, id: u64, disabled: bool) {
	s := cssom_sheet(e, id)
	if s == nil || s.disabled == disabled { return }
	s.disabled = disabled
	s.version += 1
	sheet_changed(e, s)
}

// CSSOM "remove a CSS rule" at `index`.
engine_sheet_delete_rule :: proc(e: ^Engine, id: u64, index: int) -> Rule_Edit_Error {
	s := cssom_sheet(e, id)
	if s == nil { return .No_Sheet }
	l := cssom_list(e, s)
	if index < 0 || index >= len(l.rules) { return .Index }
	if l.rules[index].kind == .Import && len(s.imports) > 0 { return .Import }
	delete(l.texts[index])
	ordered_remove(&l.texts, index)
	ordered_remove(&l.rules, index)
	ordered_remove(&l.ids, index)
	s.sheet.rules = l.rules[:]
	s.version += 1
	sheet_changed(e, s)
	return .None
}

// The sheet of a <style> element as HTML has it at this moment ("update a style block" runs when the element is
// inserted or its text changes, before any script can look): the engine's sheet when its text, media and tree are
// still the element's, else a new one in its place. nil when the element has no sheet (not connected, not CSS, the
// `disabled` attribute, author styles off, too large). The document's sync finds the same sheet and keeps it.
engine_style_element_sheet :: proc(e: ^Engine, doc: ^dom.Document, el: base.Handle, base_url: string) -> ^Sheet {
	n := dom.get(doc, el)
	if n == nil || n.kind != .Element || n.name != "style" { return nil }
	old := engine_sheet_of_owner(e, el)
	if old != nil && old.from_link { old = nil }
	if _, off := attr(n, "disabled"); off || !is_css_type(n) || !dom.is_connected(doc, el) {
		return nil
	}
	text := dom.text_content(doc, el)
	media, _ := attr(n, "media")
	scope := dom.has_shadow_trees(doc) ? dom.containing_shadow_root(doc, el) : base.NIL_HANDLE
	if old != nil {
		if old.scope == scope && old.sheet.source == text && old.media_text == media { return old }
		engine_remove_sheet(e, old)
	}
	return engine_add_sheet(e, text, el, media, base_url, scope = scope)
}

// The document's sheets of the tree whose root is `root` (the document node, or a shadow root): the sheets of its
// <style> and <link> elements in tree order, not those of shadow trees inside it (document.styleSheets). <style>
// sheets are brought up to date first (engine_style_element_sheet).
engine_tree_sheets :: proc(e: ^Engine, doc: ^dom.Document, root: base.Handle, base_url: string, allocator := context.temp_allocator) -> []u64 {
	out := make([dynamic]u64, allocator)
	for h := root; h != base.NIL_HANDLE; h = dom.next_in_tree(doc, h, root) {
		n := dom.get(doc, h)
		if n.kind != .Element { continue }
		switch n.name {
		case "style":
			if s := engine_style_element_sheet(e, doc, h, base_url); s != nil { append(&out, s.id) }
		case "link":
			if s := engine_sheet_of_owner(e, h); s != nil && s.from_link { append(&out, s.id) }
		}
	}
	return out[:]
}
