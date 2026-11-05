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

// Every rule a script's list names has a number (css.Rule.id), never reused in the engine: a script's CSSRule object
// stays that rule's. Top-level rules get theirs with the list, the rules inside one when a script lists them.
Cssom_List :: struct {
	rules: [dynamic]^css.Rule,   // the sheet's top-level rules, in order (Sheet.sheet.rules is a view of it)
	texts: [dynamic]string,      // the text of each (owned): what the sheet's text is made of once a script changed it
}

// Where a rule numbered by the CSSOM is: the rule, the top-level rule it is in (its index in the list), and the style
// rule its selectors nest in (CSS Nesting: nil at the top level, or in groups outside any style rule).
Rule_Place :: struct {
	rule: ^css.Rule,
	top:  int,
	nest: ^css.Rule,
}

Rule_Edit_Error :: enum u8 {
	None,
	No_Sheet,     // the sheet is gone
	Index,        // IndexSizeError
	Syntax,       // SyntaxError: not one valid rule (or an @import into a constructed sheet)
	Hierarchy,    // HierarchyRequestError: a rule placed before an @import
	Import,       // inserting or deleting an @import of an element's sheet: not supported (its load is the page's)
	Too_Many,     // past style.max_rules
	No_Rule,      // the rule a script named is gone
	Invalid_State, // InvalidStateError: an @namespace rule inserted or removed beside other rules than @import and @namespace
}

@(private)
cssom_list_free :: proc(s: ^Sheet) {
	l := s.cssom
	if l == nil { return }
	for t in l.texts { delete(t) }
	delete(l.texts)
	delete(l.rules)
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

is_import_text :: proc(r: string) -> bool { return len(r) >= 7 && base.ascii_equal_fold(r[:7], "@import") }

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
	for r in l.rules { rule_number(e, r) }
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

// cssRules[index], parsed (its cssText is serialized from it: page/js_cssom_serialize.odin); nil past the end.
engine_sheet_rule :: proc(e: ^Engine, id: u64, index: int) -> ^css.Rule {
	s := cssom_sheet(e, id)
	if s == nil { return nil }
	l := cssom_list(e, s)
	return index >= 0 && index < len(l.rules) ? l.rules[index] : nil
}

// The identity of cssRules[index] (0 past the end).
engine_sheet_rule_id :: proc(e: ^Engine, id: u64, index: int) -> u32 {
	r := engine_sheet_rule(e, id, index)
	return r != nil ? r.id : 0
}

@(private)
rule_number :: proc(e: ^Engine, r: ^css.Rule) {
	if r.id != 0 { return }
	e.next_rule_id += 1
	r.id = e.next_rule_id
}

// The place of the rule numbered `rule_id` in the sheet's list, through the rules a list shows (css.rule_children):
// only through numbered ones, a rule being numbered when the list of the rule it is in is read.
@(private)
rule_place :: proc(l: ^Cssom_List, rule_id: u32) -> (Rule_Place, bool) {
	if rule_id == 0 { return {}, false }
	stack := make([dynamic]Rule_Place, context.temp_allocator)
	for r, i in l.rules { append(&stack, Rule_Place{r, i, nil}) }
	for len(stack) > 0 {
		at := pop(&stack)
		if at.rule.id == rule_id { return at, true }
		nest := at.rule.kind == .Style ? at.rule : at.nest
		for k in css.rule_children(at.rule) { if k.id != 0 { append(&stack, Rule_Place{k, at.top, nest}) } }
	}
	return {}, false
}

@(private)
rule_of :: proc(e: ^Engine, id: u64, rule_id: u32) -> (s: ^Sheet, l: ^Cssom_List, at: Rule_Place, ok: bool) {
	s = cssom_sheet(e, id)
	if s == nil { return }
	l = cssom_list(e, s)
	at, ok = rule_place(l, rule_id)
	return
}

@(private)
rules_changed :: proc(e: ^Engine, s: ^Sheet) {
	s.version += 1
	sheet_changed(e, s)
}

// The rule numbered `rule_id` (nil when it is gone).
engine_rule_by_id :: proc(e: ^Engine, id: u64, rule_id: u32) -> ^css.Rule {
	_, _, at, ok := rule_of(e, id, rule_id)
	return ok ? at.rule : nil
}

// The top-level rule the rule numbered `rule_id` is in, as an index of the list (-1 when it is gone).
engine_rule_top :: proc(e: ^Engine, id: u64, rule_id: u32) -> int {
	_, _, at, ok := rule_of(e, id, rule_id)
	return ok ? at.top : -1
}

// CSSGroupingRule.cssRules.length of the rule numbered `rule_id`.
engine_rule_child_count :: proc(e: ^Engine, id: u64, rule_id: u32) -> int {
	_, _, at, ok := rule_of(e, id, rule_id)
	return ok ? len(css.rule_children(at.rule)) : 0
}

// The identity of cssRules[index] of the rule numbered `rule_id` (0 past the end), given when first asked.
engine_rule_child_id :: proc(e: ^Engine, id: u64, rule_id: u32, index: int) -> u32 {
	_, _, at, ok := rule_of(e, id, rule_id)
	kids := ok ? css.rule_children(at.rule) : nil
	if index < 0 || index >= len(kids) { return 0 }
	rule_number(e, kids[index])
	return kids[index].id
}

// CSSOM "insert a CSS rule" at `index` of the sheet's own list.
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
	if r.kind == .Import && s.constructed { return .Syntax }
	if err := placement_error(l.rules[:], r.kind, index); err != .None { return err }
	if r.kind == .Import { return .Import }
	at_end := index == len(l.rules)
	inject_at(&l.rules, index, r)
	inject_at(&l.texts, index, strings.clone(t))
	rule_number(e, r)
	s.sheet.rules = l.rules[:]
	if !rule_arrived(e, s, r, at_end) { rules_changed(e, s) }
	return .None
}

// Whether a rule of `kind` may go at `index` of a sheet's top-level rules (CSSOM "insert a CSS rule" steps 5 and 6): @import
// rules before any other but layer statements, @namespace rules after them and before the rest (Hierarchy), and an
// @namespace rule only into a list of @import and @namespace rules (Invalid_State).
@(private)
placement_error :: proc(rules: []^css.Rule, kind: css.Rule_Kind, index: int) -> Rule_Edit_Error {
	is_head :: proc(k: css.Rule_Kind) -> bool { return k == .Import || k == .Namespace || k == .Layer_Statement }
	#partial switch kind {
	case .Import:
		for r in rules[:index] { if r.kind != .Import && r.kind != .Layer_Statement { return .Hierarchy } }
	case .Namespace:
		for r in rules { if !is_head(r.kind) { return .Invalid_State } }
		for r in rules[index:] { if r.kind == .Import { return .Hierarchy } }
	case:
		for r in rules[index:] { if r.kind == .Import || r.kind == .Namespace { return .Hierarchy } }
	}
	return .None
}

// CSSGroupingRule.insertRule(text, index) on the rule numbered `rule_id` (a group, or a style rule: CSS Nesting). Inside
// a style rule the text is read as its block's (declarations alone are a nested declarations rule); a rule that parses
// but cannot be there (@import, @namespace, @font-face in a style rule...) is Hierarchy. `top`: the top-level rule
// changed, whose text the caller makes again (engine_sheet_set_rule_text).
engine_rule_insert :: proc(e: ^Engine, id: u64, rule_id: u32, text: string, index: int) -> (top: int, err: Rule_Edit_Error) {
	s, l, at, ok := rule_of(e, id, rule_id)
	if s == nil { return -1, .No_Sheet }
	if !ok || !css.rule_is_group(at.rule) { return -1, .No_Rule }
	kids := css.rule_children(at.rule)
	if index < 0 || index > len(kids) { return -1, .Index }
	opt := parse_options(&e.settings)
	if len(l.rules) >= opt.max_rules { return -1, .Too_Many }
	nest := at.rule.kind == .Style ? at.rule : at.nest
	t := strings.trim_space(text)
	r: ^css.Rule
	if nest != nil { r = css.parse_nested_rule_into(s.sheet, t, opt, nest) } else if len(split_rules(t)) == 1 { r = css.parse_rule_into(s.sheet, t, opt) }
	if r == nil {
		// a valid rule that cannot be there, or no rule
		return -1, nest != nil && len(split_rules(t)) == 1 && css.parse_rule_into(s.sheet, t, opt) != nil ? .Hierarchy : .Syntax
	}
	if r.kind == .Import || r.kind == .Namespace { return -1, .Hierarchy }
	if r.selector_text == "" && r.kind == .Style && !any_known_property(r.declarations) { return -1, .Syntax }   // (csswg-drafts#10520)
	grown := make([]^css.Rule, len(kids) + 1, s.sheet.alloc)
	copy(grown, kids[:index])
	grown[index] = r
	copy(grown[index + 1:], kids[index:])
	css.rule_children_set(at.rule, grown)
	rule_number(e, r)
	rules_changed(e, s)
	return at.top, .None
}

// Whether a declaration names a property (custom ones included): declarations alone make a nested declarations rule
// only then.
@(private)
any_known_property :: proc(decls: []css.Declaration) -> bool {
	for d in decls {
		if strings.has_prefix(d.name, "--") { return true }
		if _, _, known := lookup_property(d.name); known { return true }
	}
	return false
}

// CSSGroupingRule.deleteRule(index) on the rule numbered `rule_id`.
engine_rule_delete :: proc(e: ^Engine, id: u64, rule_id: u32, index: int) -> (top: int, err: Rule_Edit_Error) {
	s, _, at, ok := rule_of(e, id, rule_id)
	if s == nil { return -1, .No_Sheet }
	if !ok || !css.rule_is_group(at.rule) { return -1, .No_Rule }
	kids := css.rule_children(at.rule)
	if index < 0 || index >= len(kids) { return -1, .Index }
	kept := make([]^css.Rule, len(kids) - 1, s.sheet.alloc)
	copy(kept, kids[:index])
	copy(kept[index:], kids[index + 1:])
	css.rule_children_set(at.rule, kept)
	rules_changed(e, s)
	return at.top, .None
}

// CSSStyleRule.selectorText = text, for the style rule numbered `rule_id`: -1 (nothing changed) when the rule is gone,
// is a nested declarations rule, or `text` is not a valid selector list; else the top-level rule changed. A rule nested
// in a style rule reads `&` against it; the rules nested in this one follow its new selectors (nest_again).
engine_sheet_set_selector :: proc(e: ^Engine, id: u64, rule_id: u32, text: string) -> (top: int) {
	s, _, at, ok := rule_of(e, id, rule_id)
	if !ok || at.rule.kind != .Style || at.rule.selector_text == "" { return -1 }
	vals := css.trim_values(css.parse_component_values(text, parse_options(&e.settings), s.sheet.alloc))
	sel, good := css.parse_selector_list(vals, s.sheet.alloc, at.nest != nil ? &at.nest.selectors : nil, &s.sheet.namespaces)
	if !good || len(vals) == 0 { return -1 }
	at.rule.selectors = sel
	at.rule.selector_text = css.serialize_selector_list(vals, s.sheet.alloc, &s.sheet.namespaces, nested = at.nest != nil)
	nest_again(e, s, at.rule, at.rule)
	rules_changed(e, s)
	return at.top
}

// The selectors of the rules inside `r` (a style rule, or a group in style rule `nest`) taken again against `nest`'s:
// CSS Nesting's & is resolved when a rule is parsed.
@(private)
nest_again :: proc(e: ^Engine, s: ^Sheet, r, nest: ^css.Rule) {
	for k in css.rule_children(r) {
		inner := nest
		if k.kind == .Style {
			if k.selector_text == "" {
				k.selectors = nest.selectors   // a nested declarations rule
			} else {
				vals := css.trim_values(css.parse_component_values(k.selector_text, parse_options(&e.settings), s.sheet.alloc))
				if sel, good := css.parse_selector_list(vals, s.sheet.alloc, &nest.selectors, &s.sheet.namespaces); good { k.selectors = sel }
			}
			inner = k
		}
		nest_again(e, s, k, inner)
	}
}

// CSSStyleRule.style (or a nested declarations rule's) written: the declarations of the style rule numbered `rule_id`
// are now those of `text` (the block a script wrote, serialized). -1 when the rule is gone or is no style rule, else the
// top-level rule changed.
engine_sheet_set_declarations :: proc(e: ^Engine, id: u64, rule_id: u32, text: string) -> (top: int) {
	s, _, at, ok := rule_of(e, id, rule_id)
	if !ok || at.rule.kind != .Style { return -1 }
	at.rule.declarations = css.parse_declarations(text, parse_options(&e.settings), s.sheet.alloc)
	rules_changed(e, s)
	return at.top
}

// The text of the top-level rule at `top` is now `text` (its serialization after a change: what the sheet's text is
// made of, sheet_rules_text).
engine_sheet_set_rule_text :: proc(e: ^Engine, id: u64, top: int, text: string) {
	s := cssom_sheet(e, id)
	if s == nil || s.cssom == nil || top < 0 || top >= len(s.cssom.texts) { return }
	delete(s.cssom.texts[top])
	s.cssom.texts[top] = strings.clone(text)
}

// sheet.disabled = v, for any sheet a script holds (an element's sheet stops applying while its element stays).
engine_sheet_set_disabled :: proc(e: ^Engine, id: u64, disabled: bool) {
	s := cssom_sheet(e, id)
	if s == nil || s.disabled == disabled { return }
	s.disabled = disabled
	rules_changed(e, s)
}

// CSSOM "remove a CSS rule" at `index` of the sheet's own list.
engine_sheet_delete_rule :: proc(e: ^Engine, id: u64, index: int) -> Rule_Edit_Error {
	s := cssom_sheet(e, id)
	if s == nil { return .No_Sheet }
	l := cssom_list(e, s)
	if index < 0 || index >= len(l.rules) { return .Index }
	if l.rules[index].kind == .Import && len(s.imports) > 0 { return .Import }
	if l.rules[index].kind == .Namespace {
		for r in l.rules { if r.kind != .Import && r.kind != .Namespace { return .Invalid_State } }
	}
	delete(l.texts[index])
	ordered_remove(&l.texts, index)
	ordered_remove(&l.rules, index)
	s.sheet.rules = l.rules[:]
	rules_changed(e, s)
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
