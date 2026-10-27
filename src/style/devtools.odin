package style

// What the developer tools' Styles pane reads of the style engine, and what it writes back: the rules of the sheets that
// match an element (selector as written, where it is, its declarations as text), and the replacement of a rule's declarations
// (an edit, a property switched off) which makes the engine rebuild its index at the next style pass. Nothing here is used
// while the panel is closed.

import "base:runtime"
import "core:slice"
import "core:strings"
import "wb:base"
import "wb:css"
import "wb:dom"

Dev_Decl :: struct {
	name:      string,
	value:     string,
	important: bool,
}

Dev_Rule :: struct {
	rule:     ^css.Rule,         // the rule in its sheet (what edits change)
	sheet:    ^Sheet,
	selector: string,            // the selector list as written
	spec:     css.Specificity,   // of the selector of the list that matched
	origin:   Origin,
	order:    int,               // source order over all the sheets
	line:     int,               // where in the sheet's text (1-based)
	url:      string,            // the sheet's address ("" for a <style> element: it is the document's)
	owner:    base.Handle,       // the <style> or <link> element
	media:    string,            // "@media (...)" around it, "" for none
	layer:    string,
	decls:    []Dev_Decl,
}

// The rules of every sheet (the document's, the user's, and the browser's when `ua`) that match `el`, strongest first.
// Strings and the slice live in `allocator`.
dev_matched_rules :: proc(e: ^Engine, doc: ^dom.Document, state: State, el: base.Handle, ua: bool, allocator := context.temp_allocator) -> []Dev_Rule {
	out := make([dynamic]Dev_Rule, 0, 16, allocator)
	m: Match_Ctx
	match_ctx_init(&m, doc, state, context.temp_allocator)
	m.ignore_state = false
	order := 0
	visit :: proc(e: ^Engine, m: ^Match_Ctx, out: ^[dynamic]Dev_Rule, s: ^Sheet, rules: []^css.Rule, el: base.Handle, media, layer: string, order: ^int, allocator: runtime.Allocator) {
		for r in rules {
			if r == nil { continue }
			#partial switch r.kind {
			case .Style:
				order^ += 1
				best: css.Specificity
				hit := false
				for &c in r.selectors {
					if c.pseudo_element != .None { continue }
					if matches_complex(m, el, &c) {
						if !hit || css.specificity_less(best, c.specificity) { best = c.specificity }
						hit = true
					}
				}
				if hit {
					d := make([]Dev_Decl, len(r.declarations), allocator)
					for decl, i in r.declarations {
						d[i] = Dev_Decl{name = decl.name, value = css.serialize_values(decl.value, allocator), important = decl.important}
					}
					append(out, Dev_Rule{rule = r, sheet = s, selector = strings.clone(r.selector_text, allocator), spec = best, origin = s.origin, order = order^,
						line = s.sheet != nil ? css.line_of(s.sheet, r.pos) : 0, url = s.base_url, owner = s.owner, media = media, layer = layer, decls = d})
				}
				if len(r.nested) > 0 { visit(e, m, out, s, r.nested, el, media, layer, order, allocator) }
			case .Media:
				if css.media_matches(r.media, e.env) {
					text := strings.concatenate({"@media ", css.serialize_values(r.prelude, context.temp_allocator)}, allocator)
					if len(r.prelude) == 0 { text = "@media" }
					visit(e, m, out, s, r.rules, el, media == "" ? text : strings.concatenate({media, " ", text}, allocator), layer, order, allocator)
				}
			case .Supports:
				visit(e, m, out, s, r.rules, el, media, layer, order, allocator)
			case .Layer_Block:
				visit(e, m, out, s, r.rules, el, media, r.layer == "" ? "(anonymous)" : r.layer, order, allocator)
			}
		}
	}
	walk :: proc(e: ^Engine, m: ^Match_Ctx, out: ^[dynamic]Dev_Rule, s: ^Sheet, el: base.Handle, ua: bool, order: ^int, allocator: runtime.Allocator) {
		if s.origin == .UA && !ua { return }
		if s.disabled { return }
		if s.sheet != nil && css.media_matches(s.media, e.env) {
			visit(e, m, out, s, s.sheet.rules, el, "", s.layer, order, allocator)
		}
		for &slot in s.imports { if slot.child != nil { walk(e, m, out, slot.child, el, ua, order, allocator) } }
	}
	for s in e.sheets { walk(e, &m, &out, s, el, ua, &order, allocator) }
	match_ctx_destroy(&m)
	// strongest first: later origin, then specificity, then later in the source
	slice.stable_sort_by(out[:], proc(a, b: Dev_Rule) -> bool {
		if a.origin != b.origin { return a.origin > b.origin }
		if a.spec != b.spec { return css.specificity_less(b.spec, a.spec) }
		return a.order > b.order
	})
	return out[:]
}

// Replaces the declarations of `rule` (the pane's own copy of them, with the edits and without the ones switched off) and has
// the engine rebuild what depends on them. The new values are parsed in the sheet's own memory.
dev_set_rule_decls :: proc(e: ^Engine, sheet: ^Sheet, rule: ^css.Rule, decls: []Dev_Decl) {
	if sheet == nil || sheet.sheet == nil || rule == nil { return }
	a := sheet.sheet.alloc
	opt := parse_options(&e.settings)
	out := make([]css.Declaration, len(decls), a)
	n := 0
	for d in decls {
		vals := css.parse_component_values(d.value, opt, a)
		vals = trim_ws(vals)
		if len(vals) == 0 && !strings.has_prefix(d.name, "--") { continue }
		name := strings.has_prefix(d.name, "--") ? strings.clone(d.name, a) : strings.to_lower(d.name, a)
		out[n] = css.Declaration{name = name, value = vals, important = d.important}
		n += 1
	}
	rule.declarations = out[:n]
	sheet_changed(e, sheet)
}

@(private)
trim_ws :: proc(vs: []css.Value) -> []css.Value {
	lo, hi := 0, len(vs)
	for lo < hi && vs[lo].kind == .Token && vs[lo].tok.kind == .Whitespace { lo += 1 }
	for hi > lo && vs[hi - 1].kind == .Token && vs[hi - 1].tok.kind == .Whitespace { hi -= 1 }
	return vs[lo:hi]
}

// The text of a style attribute as declarations (name, value, important), for the `element.style` block.
dev_parse_inline :: proc(e: ^Engine, text: string, allocator := context.temp_allocator) -> []Dev_Decl {
	opt := parse_options(&e.settings)
	ds := css.parse_declarations(text, opt, allocator)
	out := make([]Dev_Decl, len(ds), allocator)
	for d, i in ds { out[i] = Dev_Decl{name = d.name, value = css.serialize_values(d.value, allocator), important = d.important} }
	return out
}

// Whether a property is inherited by default (what the "Inherited from" sections list).
dev_inherited_property :: proc(name: string) -> bool {
	switch name {
	case "color", "cursor", "direction", "font", "font-family", "font-size", "font-style", "font-variant", "font-weight", "font-stretch",
	     "letter-spacing", "line-height", "list-style", "list-style-type", "list-style-position", "list-style-image", "text-align", "text-indent",
	     "text-transform", "text-shadow", "white-space", "word-spacing", "word-break", "overflow-wrap", "visibility", "quotes", "tab-size", "border-collapse",
	     "border-spacing", "caption-side", "empty-cells", "caret-color", "color-scheme", "font-kerning", "font-feature-settings", "hyphens", "text-rendering",
	     "font-optical-sizing", "font-variation-settings", "font-variant-ligatures", "font-variant-numeric", "font-variant-east-asian", "font-variant-position",
	     "text-decoration-skip-ink", "text-align-last", "text-justify", "writing-mode", "pointer-events", "accent-color", "fill", "stroke":
		return true
	}
	return strings.has_prefix(name, "--")
}
