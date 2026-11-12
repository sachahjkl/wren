package style

import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:host"

// A stylesheet that arrives. cnn.com took fifteen full passes for its sheets, each with every rule of the page flattened again:
// 2.2 s, for sheets that match a few hundred elements of ten thousand.
//
// What a sheet of plain style rules changes is the style of the elements it matches, and what they pass on: nothing else, whatever
// its place among the others. So its rules are added to the index as it stands (engine_extend), numbered between those of its
// neighbours in the document, and also go to an index of their own (Engine.fresh); restyle_arrivals runs the elements through that
// small index, by the keys of the sheet's selectors (the same lookups as the cascade, on the entries of this sheet alone), and
// restyles those it matches as restyle_media does for a flipped @media block: each is computed again, its children where what they
// inherit changed.
//
// An @import that arrives after its sheet is such a sheet, with its place in the numbers of its parent (Import_Slot.placed).
//
// What decides beyond the elements a rule matches keeps the rebuild and the full pass: @layer (the order of layers), @property
// (a value's meaning), @position-try, ::part() / ::slotted() / :host (they style other trees), @keyframes of a name that elements
// already use, a sheet that came with others changed or removed, a sheet that belongs to a shadow tree. So does a sheet
// that matches more than style.incremental.max_ratio of the document: there a full pass, on the style threads, is the shorter way.
//
// A sheet that goes takes back what it gave the elements it matches, and what they passed on. Its rules stay in force until the mutations are
// marked (the invalidation index, a superset afterwards, and the restyle that follows see the document as the styles have it: an element
// that stopped matching a rule of the sheet with the same mutations is found by that rule); restyle_departures then moves its entries out of
// the index into Engine.fresh, runs the elements through them, and restyles those they match. npr.org made four full passes for that.

// Rules of a sheet are numbered from where the one before it ends, this far on: what a sheet that arrives between two others has.
SHEET_ORDER_GAP :: 1 << 15
// What an @import has not delivered yet keeps this many numbers in its sheet: its rules go there when they come, before the rest of the sheet.
IMPORT_ORDER_GAP :: 1 << 13
// Sheets gone that wait for the next rebuild (a script that puts in and takes out <style> elements for ever): past this many, a rebuild.
SHEETS_DEPARTED_MAX :: 64

// A rule a script inserted at the end of a sheet (CSSOM insertRule, what CSS-in-JS libraries do rule by rule).
@(private)
Arrived_Rule :: struct { sheet: ^Sheet, rule: ^css.Rule }

// `r` went into `s`: true when it arrives as a sheet does, or comes with one; else the rules are stale.
@(private)
rule_arrived :: proc(e: ^Engine, s: ^Sheet, r: ^css.Rule, at_end: bool) -> bool {
	if e.dirty_other { return false }
	for a in e.arrived { if a == s { s.version += 1; return true } }   // (its rules are read when it joins)
	if !at_end || !s.indexed || s.origin != .Author || s.in_layer { return false }
	s.version += 1
	e.dirty = true
	append(&e.arrived_rules, Arrived_Rule{s, r})
	return true
}

// The sheets in their places in the document, as the numbers of the rules in the index have them.
@(private)
sheets_sorted :: proc(e: ^Engine, doc: ^dom.Document) -> bool {
	order_sheets(e, doc)
	sheets_sort(e)
	last: u32
	for x in e.sheets {
		if !x.indexed { continue }
		if x.order_first < last { return false }
		last = x.order_first
	}
	return true
}

// Whether the rules of `list` can join an index: nothing there depends on the rest of the sheets.
@(private = "file")
rules_extend :: proc(list: []^css.Rule) -> bool {
	for r in list {
		#partial switch r.kind {
		case .Layer_Block, .Layer_Statement, .Property, .Position_Try: return false
		case .Media, .Supports, .Container: if !rules_extend(r.rules) { return false }
		case .Style: if !rules_extend(r.nested) { return false }
		}
	}
	return true
}

// Some element's animation-name is one of the @keyframes of `list`: they start, or change, what runs.
@(private = "file")
keyframes_in_use :: proc(list: []^css.Rule, used: ^map[string]bool) -> bool {
	for r in list {
		#partial switch r.kind {
		case .Keyframes: if r.name in used { return true }
		case .Media, .Supports, .Container: if keyframes_in_use(r.rules, used) { return true }
		}
	}
	return false
}

// The animation names of the elements styled.
@(private = "file")
animation_names :: proc(s: ^Styled, out: ^map[string]bool) {
	for c in s.by_node {
		if c == nil { continue }
		for n in c.animation_name { if n != "" { out[n] = true } }
	}
}

// Adds the sheets that arrived to the index, if what they are allows: the rules are no longer dirty then, and restyle_arrivals is due.
// False: the rebuild stands, with a full pass.
engine_extend :: proc(e: ^Engine, doc: ^dom.Document, s: ^Styled) -> bool {
	refused :: proc(e: ^Engine, why: string) -> bool {
		e.last_restyle.fallback = why
		return false
	}
	if !e.dirty { return false }
	if e.dirty_other { return refused(e, "style rules changed (a sheet went, or was changed)") }
	if len(e.arrived) + len(e.arrived_rules) + len(e.arrived_imports) == 0 || !e.settings.inc_enabled || !e.settings.sheet_partial { return refused(e, "style rules changed") }
	if len(e.shadow.doc_adopted) > 0 { return refused(e, "style rules changed: the document has adopted sheets") }
	used: map[string]bool
	if sync.atomic_load(&s.motion) {
		used = make(map[string]bool, 16, context.temp_allocator)
		animation_names(s, &used)
	}
	for a in e.arrived {
		if a.in_layer { return refused(e, "a sheet in a layer came") }
		if !rules_extend(a.sheet.rules) { return refused(e, "a sheet with @layer, @property or @position-try came") }
		if len(used) > 0 && keyframes_in_use(a.sheet.rules, &used) { return refused(e, "a sheet came with @keyframes that elements use") }
	}
	for slot in e.arrived_imports {
		if !rules_extend(slot.child.sheet.rules) { return refused(e, "an @import with @layer, @property or @position-try came") }
		if len(used) > 0 && keyframes_in_use(slot.child.sheet.rules, &used) { return refused(e, "an @import came with @keyframes that elements use") }
	}
	for &a in e.arrived_rules {
		one := []^css.Rule{a.rule}
		if !rules_extend(one) { return refused(e, "a rule with @layer, @property or @position-try came") }
		if len(used) > 0 && keyframes_in_use(one, &used) { return refused(e, "a rule came with @keyframes that elements use") }
	}
	t0 := time.tick_now()
	defer { rebuild_total.n += 1; rebuild_total.ns += i64(time.tick_since(t0)); rebuild_total.sheets += len(e.arrived) }
	// those already in the index stand in the order they were numbered: a sheet moved in the document meanwhile is for the rebuild
	if !sheets_sorted(e, doc) { return refused(e, "a sheet moved in the document") }
	e.cur = &e.rules
	e.fresh_on = true
	defer e.fresh_on = false
	faces, frames := len(e.font_faces), len(e.keyframes)
	high := e.rules.order
	for x, i in e.sheets {
		if x.indexed || x.disabled || x.scope != base.NIL_HANDLE || x.constructed { continue }
		before, after: ^Sheet
		for k := i - 1; k >= 0; k -= 1 { if e.sheets[k].indexed { before = e.sheets[k]; break } }
		for k := i + 1; k < len(e.sheets); k += 1 { if e.sheets[k].indexed { after = e.sheets[k]; break } }
		from := before != nil ? before.order_last : 0
		e.rules.order = after != nil ? from + (after.order_first - from) / 2 : high + SHEET_ORDER_GAP
		x.order_first = e.rules.order
		flatten_sheet(e, x, LayerCtx{rank = UNLAYERED})
		x.order_last = e.rules.order
		x.indexed = true
		high = max(high, e.rules.order)
		if e.fresh_other || (after != nil && x.order_last >= after.order_first) {
			e.dirty_other = true   // (what was added goes with the rebuild)
			return refused(e, "a sheet came that styles another tree, or too long for its place")
		}
	}
	for slot in e.arrived_imports {
		e.rules.order = slot.order
		flatten_import(e, slot, LayerCtx{rank = UNLAYERED})
		if e.fresh_other || e.rules.order > slot.order + IMPORT_ORDER_GAP {
			e.dirty_other = true
			return refused(e, "an @import came that styles another tree, or too long for its place")
		}
	}
	for a in e.arrived_rules {
		x := a.sheet
		if x.disabled || (len(x.media) > 0 && !css.media_matches(x.media, e.env)) { continue }
		e.rules.order = x.order_last
		e.cur_base_url = x.base_url
		flatten_rule(e, a.rule, x.origin, LayerCtx{rank = UNLAYERED})
		x.order_last = e.rules.order
		high = max(high, e.rules.order)
		next := next_indexed(e, x)
		if e.fresh_other || (next != nil && x.order_last >= next.order_first) {
			e.dirty_other = true
			return refused(e, "a rule came that styles another tree, or too long for its place")
		}
	}
	e.cur_base_url = ""
	e.rules.order = high
	if len(e.font_faces) > faces {
		slice.stable_sort_by(e.font_faces[:], proc(a, b: Font_Face_Ref) -> bool { return a.order < b.order })
		parse_font_faces(e)
	}
	if len(e.keyframes) > frames {
		clear(&e.keyframe_sets)
		compile_keyframes(e)
	}
	e.rebuilds += 1
	inv_extend(e, &e.fresh.index)
	e.dirty = false
	e.arrivals_due = true
	clear(&e.arrived)
	clear(&e.arrived_rules)
	clear(&e.arrived_imports)
	return true
}

// The sheet of `slot` came. True: it joins the rules as a sheet that arrives does (or with its parent, which has not joined them yet).
@(private)
import_arrives :: proc(e: ^Engine, parent: ^Sheet, slot: ^Import_Slot) -> bool {
	top := parent
	for top.parent != nil { top = top.parent }
	if e.dirty_other || top.origin != .Author || top.scope != base.NIL_HANDLE || top.constructed { return false }
	for a := parent; a != nil; a = a.parent { if a.in_layer { return false } }
	if slot.rule.layer != "" { return false }
	for a in e.arrived { if a == top { return true } }
	if !top.indexed || !slot.placed || top.order_first == top.order_last { return false }   // (a media that does not match: its numbers are of an earlier rebuild)
	e.dirty = true
	append(&e.arrived_imports, slot)
	return true
}

// The sheet after `s` among those of the index.
@(private = "file")
next_indexed :: proc(e: ^Engine, s: ^Sheet) -> ^Sheet {
	seen := false
	for x in e.sheets {
		if seen && x.indexed { return x }
		if x == s { seen = true }
	}
	return nil
}


@(private)
fresh_clear :: proc(e: ^Engine) {
	index_free(&e.fresh.index)
	e.arrivals_due, e.fresh_other = false, false
}

@(private)
departed_free :: proc(e: ^Engine) {
	for s in e.departed { sheet_free(s) }
	clear(&e.departed)
	e.departures_due = false
}

// Rules that style the elements they match and nothing else, or that the engine keeps by their number (@keyframes, @font-face).
@(private = "file")
rules_plain :: proc(list: []^css.Rule) -> bool {
	for r in list {
		#partial switch r.kind {
		case .Style: if !rules_plain(r.nested) { return false }
		case .Media, .Supports, .Container: if !rules_plain(r.rules) { return false }
		case .Keyframes, .Font_Face, .Namespace, .Unknown:
		case: return false
		}
	}
	return true
}

@(private = "file")
in_ranges :: proc(order: u32, ranges: [][2]u32) -> bool {
	for r in ranges { if order > r[0] && order <= r[1] { return true } }
	return false
}

// `s` went, and is out of Engine.sheets.
@(private)
sheet_departs :: proc(e: ^Engine, s: ^Sheet) {
	plain := s.indexed && s.origin == .Author && s.scope == base.NIL_HANDLE && !s.constructed && !s.in_layer && len(s.imports) == 0 && !s.disabled
	if plain && e.settings.inc_enabled && e.settings.sheet_partial && !e.dirty_other && len(e.departed) < SHEETS_DEPARTED_MAX && rules_plain(s.sheet.rules) {
		append(&e.departed, s)
		e.departures_due = true
		return
	}
	sheet_changed(e, s)
	sheet_free(s)
}

// The sheets that left wait for restyle_departures.
engine_departures_due :: proc(e: ^Engine) -> bool { return e.departures_due }

// The entries of `list` of the rules numbered in `ranges` go (to `gone`); the others stay, in their order.
@(private = "file")
entries_split :: proc(list: ^[dynamic]Entry, ranges: [][2]u32, gone: ^[dynamic]Entry) {
	kept := 0
	for ent in list {
		if in_ranges(ent.rule.order, ranges) {
			if gone != nil { append(gone, ent) }
		} else {
			list[kept] = ent
			kept += 1
		}
	}
	resize(list, kept)
}

@(private = "file")
entries_move :: proc(from, to: ^map[string][dynamic]Entry, ranges: [][2]u32, own_key := false) {
	gone := make([dynamic]Entry, 0, 16, context.temp_allocator)
	for k, &list in from {
		clear(&gone)
		entries_split(&list, ranges, &gone)
		if len(gone) == 0 { continue }
		key := own_key ? strings.clone(k) : k
		dst := make([dynamic]Entry, 0, len(gone))
		append(&dst, ..gone[:])
		to[key] = dst
	}
}

// The entries of the rules numbered in `ranges`, out of the index of the document, into that of Engine.fresh.
@(private = "file")
index_take :: proc(e: ^Engine, ranges: [][2]u32) {
	rs, to := &e.rules, &e.fresh.index
	entries_move(&rs.index.by_id, &to.by_id, ranges)
	entries_move(&rs.index.by_class, &to.by_class, ranges)
	entries_move(&rs.index.by_tag, &to.by_tag, ranges)
	entries_move(&rs.index.by_attr, &to.by_attr, ranges, own_key = true)
	entries_move(&rs.index.by_attr_name, &to.by_attr_name, ranges)
	for k in to.by_attr { to.attr_names[k[:strings.index_byte(k, 0)]] = true }
	entries_split(&rs.index.root, ranges, &to.root)
	entries_split(&rs.index.universal, ranges, &to.universal)
	entries_split(&rs.index.backdrop, ranges, &to.backdrop)
	entries_split(&rs.state_entries, ranges, nil)
	// (what was parsed of the sheet goes with it)
	clear(&e.container_conds)
	e.container_conds_lost = true
	frames := len(e.keyframes)
	for i := len(e.keyframes) - 1; i >= 0; i -= 1 { if in_ranges(e.keyframes[i].order, ranges) { ordered_remove(&e.keyframes, i) } }
	if len(e.keyframes) < frames {
		clear(&e.keyframe_sets)
		compile_keyframes(e)
	}
	faces := len(e.font_faces)
	for i := len(e.font_faces) - 1; i >= 0; i -= 1 { if in_ranges(e.font_faces[i].order, ranges) { ordered_remove(&e.font_faces, i) } }
	if len(e.font_faces) < faces { parse_font_faces(e) }
}

// Whether a rule of the sheets that go styles another tree: what it reaches there is not found by matching the elements of this one.
@(private = "file")
styles_other_trees :: proc(rs: ^Rule_Set, ranges: [][2]u32) -> bool {
	for list in ([3][dynamic]Entry{rs.slotted_entries, rs.part_entries, rs.host_entries}) {
		for ent in list { if in_ranges(ent.rule.order, ranges) { return true } }
	}
	return false
}

// The elements that match the entries of Engine.fresh; past `limit`, false.
@(private = "file")
fresh_hits :: proc(e: ^Engine, doc: ^dom.Document, p: ^Pass, limit: int) -> (hits: [dynamic]base.Handle, ok: bool) {
	hits = make([dynamic]base.Handle, context.temp_allocator)
	Frame :: struct { h: base.Handle, bloom: Bloom }
	stack := make([dynamic]Frame, context.temp_allocator)
	root := dom.get(doc, doc.root)
	for c := root.last_child; c != base.NIL_HANDLE; c = dom.get(doc, c).prev { append(&stack, Frame{h = c}) }
	p.fresh_probe = true
	defer p.fresh_probe = false
	ctx := Elem_Ctx{set = &e.fresh}
	for len(stack) > 0 {
		f := pop(&stack)
		n := dom.get(doc, f.h)
		if n == nil || n.kind != .Element { continue }
		collect_entries(p, f.h, n, &f.bloom, ctx, nil)
		for l in p.lists {
			if len(l) > 0 { append(&hits, f.h); break }
		}
		if len(hits) > limit { return hits, false }
		child_bloom := f.bloom
		bloom_add_element(&child_bloom, n)
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).prev { append(&stack, Frame{h = ch, bloom = child_bloom}) }
	}
	return hits, true
}

// The styles of the elements that the rules of the sheets that left gave something, in place, the rules gone from the index. ok = false: the
// caller makes a full pass; `changed`: some computed style differs. The document's mutations are styled already.
restyle_departures :: proc(e: ^Engine, doc: ^dom.Document, s: ^Styled, pool: ^host.Thread_Pool = nil) -> (changed: bool, ok: bool) {
	if !e.departures_due { return false, true }
	ranges := make([dynamic][2]u32, 0, len(e.departed), context.temp_allocator)
	for x in e.departed {
		if x.indexed { append(&ranges, [2]u32{x.order_first, x.order_last}); x.indexed = false }
	}
	if styles_other_trees(&e.rules, ranges[:]) { return arrival_fail(e, "a sheet that styled another tree went") }
	if sync.atomic_load(&s.motion) {
		used := make(map[string]bool, 16, context.temp_allocator)
		animation_names(s, &used)
		for x in e.departed { if keyframes_in_use(x.sheet.rules, &used) { return arrival_fail(e, "a sheet went with @keyframes that elements use") } }
	}
	e.departures_due = false
	index_take(e, ranges[:])
	defer fresh_clear(e)
	if int(s.arena.total_used) - int(s.base_used) + s.partial_bytes > e.settings.restyle_waste_bytes { return arrival_fail(e, "memory left by partial restyles") }
	class_bits_resume(e, doc)
	defer e.class_bits_live = false
	p := pass_make(e, s, doc, s.state)
	defer pass_destroy(p)
	hits, within := fresh_hits(e, doc, p, int(e.settings.inc_max_ratio * f32(max(doc.nodes.count, 1))))
	if !within { return arrival_fail(e, "a sheet that went reaches too much") }
	return restyle_roots(e, doc, s, p, hits[:], pool)
}

// The elements forced hidden or shown since the last pass, in place: what compute_element says of each, and what they pass on.
restyle_hidden :: proc(e: ^Engine, doc: ^dom.Document, s: ^Styled, pool: ^host.Thread_Pool = nil) -> (changed: bool, ok: bool) {
	defer clear(&e.hidden_changed)
	roots := make([dynamic]base.Handle, 0, len(e.hidden_changed), context.temp_allocator)
	for h in e.hidden_changed { if connected(doc, h) && dom.get(doc, h).kind == .Element { append(&roots, h) } }
	if len(roots) == 0 { return false, true }
	p := pass_make(e, s, doc, s.state)
	defer pass_destroy(p)
	return restyle_roots(e, doc, s, p, roots[:], pool)
}

engine_hidden_changed :: proc(e: ^Engine) -> bool { return len(e.hidden_changed) > 0 }

@(private = "file")
arrival_fail :: proc(e: ^Engine, why: string) -> (bool, bool) {
	e.last_restyle.fallback = why
	return false, false
}

// The styles of the elements the rules of engine_extend reach, in place. ok = false: the caller makes a full pass; `changed`: some
// computed style differs (s.serial changed then). The document's mutations are styled already.
restyle_arrivals :: proc(e: ^Engine, doc: ^dom.Document, s: ^Styled, pool: ^host.Thread_Pool = nil) -> (changed: bool, ok: bool) {
	if !e.arrivals_due { return false, true }
	defer fresh_clear(e)
	ix := &e.fresh.index
	if len(ix.by_id) + len(ix.by_class) + len(ix.by_tag) + len(ix.by_attr) + len(ix.by_attr_name) + len(ix.root) + len(ix.universal) + len(ix.backdrop) == 0 { return false, true }
	if s.mutations != doc.mutations { return arrival_fail(e, "the document changed") }
	if int(s.arena.total_used) - int(s.base_used) + s.partial_bytes > e.settings.restyle_waste_bytes { return arrival_fail(e, "memory left by partial restyles") }
	class_bits_resume(e, doc)
	defer e.class_bits_live = false
	p := pass_make(e, s, doc, s.state)
	defer pass_destroy(p)
	hits, within := fresh_hits(e, doc, p, int(e.settings.inc_max_ratio * f32(max(doc.nodes.count, 1))))
	if !within { return arrival_fail(e, "a sheet that came reaches too much") }
	return restyle_roots(e, doc, s, p, hits[:], pool)
}
