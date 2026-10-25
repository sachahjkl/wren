package style

import "core:slice"
import "core:strings"
import "wb:base"
import "wb:css"
import "wb:dom"

// Container queries (CSS Containment 3): container-type / container-name, @container rules and cq units.
//
// A query depends on the size of an ancestor's box, which only layout knows. The engine keeps the content-box sizes the
// embedder measured after the last layout (`engine_set_container_sizes`); a change marks the styles for a full pass,
// and the embedder lays out again (src/browser/container_queries.odin bounds that loop). On the first pass no size is
// known yet: size queries are unknown (false) and cq units use the small viewport, as with no container at all.
// Elements with container-type get size containment in the inline axis (and in both for `size`), which is what makes
// one round enough: their size does not depend on what the queries change inside them.

Container_Type :: enum u8 { Normal, Size, Inline_Size }

// CSS Scrollbars 1 and Overflow 3 (scrollbar-gutter). The bars of this browser are overlays: `none` hides them, `thin`
// narrows them, the colors are for the painter; a gutter is never reserved (overlay bars take no room), so
// scrollbar-gutter is kept for completeness only.
Scrollbar_Width :: enum u8 { Auto, Thin, None }
Scrollbar_Colors :: struct { auto: bool, thumb, track: css.Color }   // auto: the browser's colors (the initial value)
Scrollbar_Gutter :: enum u8 { Auto, Stable, Stable_Both_Edges }

// One query container, as the descendants of an element see it (a chain to the root, nearest first).
Container_Ctx :: struct {
	node:   base.Handle,
	type:   Container_Type,
	names:  []string,
	size:   css.Container_Size,
	parent: ^Container_Ctx,
}

// Conditions of the @container rules around a style rule (nested ones form a chain).
Cq_Cond :: struct {
	query: ^css.Container_Query,
	next:  ^Cq_Cond,
}

// Records the content-box sizes (CSS px) of the elements that are query containers. Returns true when a query or a cq
// unit may now resolve differently: the caller restyles (the engine has set `restyle_needed`) and lays out again.
engine_set_container_sizes :: proc(e: ^Engine, sizes: map[base.Handle][2]f32) -> bool {
	// the containers whose size is new or differs; one that is gone from the list (hidden, removed) cannot be restyled
	// by its subtree: the whole document is
	changed := make([dynamic]base.Handle, 0, 4, context.temp_allocator)
	for h, s in sizes {
		old, ok := e.container_sizes[h]
		if !ok || abs(old.x - s.x) > 0.01 || abs(old.y - s.y) > 0.01 { append(&changed, h) }
	}
	gone := false
	for h in e.container_sizes { if h not_in sizes { gone = true; break } }
	if len(changed) == 0 && !gone { return false }
	clear(&e.container_sizes)
	for h, s in sizes { e.container_sizes[h] = s }
	if !e.container_dependent { return false }
	if gone || !e.settings.cq_partial || !e.settings.inc_enabled {
		e.restyle_needed = true
		clear(&e.container_pending)
		return true
	}
	for h in changed { if !slice.contains(e.container_pending[:], h) { append(&e.container_pending, h) } }
	return true
}

// Restyles the subtrees of the containers whose size changed (engine_set_container_sizes) in place: a query or a cq unit
// looks at an ancestor container only, so nothing outside those subtrees can differ. The container itself is restyled too
// (its record carries the chain of containers, with the sizes, that its children read). ok = false: it cannot be scoped
// (nothing was kept of the work in progress that a full pass would not make again), and the caller does a full pass;
// `changed`: some computed style differs (s.serial changed then).
restyle_containers :: proc(e: ^Engine, doc: ^dom.Document, s: ^Styled) -> (changed: bool, ok: bool) {
	if len(e.container_pending) == 0 { return false, true }
	if e.dirty { return cq_fail(e, "rules changed") }
	if e.restyle_needed { return cq_fail(e, "a full pass is due") }
	if s.mutations != doc.mutations { return cq_fail(e, "the document changed") }
	if int(s.arena.total_used) - int(s.base_used) + s.partial_bytes > e.settings.restyle_waste_bytes { return cq_fail(e, "memory left by partial restyles") }
	shadows := dom.has_shadow_trees(doc)
	p := pass_make(e, s, doc, s.state)
	defer pass_destroy(p)
	p.compare = true
	pending := make(map[base.Handle]bool, len(e.container_pending), context.temp_allocator)
	for h in e.container_pending { pending[h] = true }
	clear(&e.container_pending)
	for r in pending {
		n := dom.get(doc, r)
		if n == nil || n.kind != .Element || base_style_of(s, r) == nil { return cq_fail(e, "a container left the document") }
		if shadows && !dom.in_flat_tree(doc, r) { return cq_fail(e, "a container left the flat tree") }
		// inside another container's subtree that is restyled anyway
		covered := false
		for anc := flat_parent_element(doc, r); anc != base.NIL_HANDLE; anc = flat_parent_element(doc, anc) {
			if pending[anc] { covered = true; break }
		}
		if covered { continue }
		par := flat_parent_element(doc, r)
		if par == base.NIL_HANDLE { return cq_fail(e, "the root element is a container") }
		bloom: Bloom
		for anc := par; anc != base.NIL_HANDLE; anc = flat_parent_element(doc, anc) { bloom_add_element(&bloom, dom.get(doc, anc)) }
		style_subtree(p, r, base_style_of(s, par), bloom, root_ctx = node_ctx(p, r))
		if p.unscoped { return cq_fail(e, "a counter is reached") }
	}
	if p.changed {
		styled_serial += 1
		s.serial = styled_serial
		if p.layout_changed { s.layout_serial = s.serial }
		journal_stamp(s)
		update_canvas(s, doc)
	}
	return p.changed, true
}

@(private = "file")
cq_fail :: proc(e: ^Engine, why: string) -> (bool, bool) {
	e.last_restyle.fallback = why
	return false, false
}

// Some rule or value of the documents depends on container sizes.
engine_uses_container_queries :: proc(e: ^Engine) -> bool { return e.container_dependent }

// The query containers of a computed style pass: the elements whose container-type is not normal.
styled_containers :: proc(s: ^Styled, allocator := context.temp_allocator) -> []base.Handle {
	out := make([dynamic]base.Handle, allocator)
	for c in s.by_node { if c != nil && c.container_type != .Normal && c.display != .None { append(&out, c.node) } }
	return out[:]
}

@(private)
apply_container_prop :: proc(cx: ^Cx, p: Prop, vs: []css.Value) -> bool {
	c := cx.c
	#partial switch p {
	case .Container_Type:
		items := split_items(vs)
		// `scroll-state` (alone or with a size type) is accepted for the size part: scroll-state() queries stay unknown
		t := Container_Type.Normal
		seen := false
		for it in items {
			switch ident_lower(it) {
			case "normal": if len(items) != 1 { return false }
			case "size": if seen { return false }; t, seen = .Size, true
			case "inline-size": if seen { return false }; t, seen = .Inline_Size, true
			case "scroll-state":
			case: return false
			}
		}
		if len(items) == 0 { return false }
		c.container_type = t
	case .Container_Name:
		items := split_items(vs)
		if len(items) == 1 && ident_lower(items[0]) == "none" { c.container_name = nil; return true }
		names := make([]string, len(items), cx.alloc)
		for it, i in items {
			if !tok_is(it, .Ident) { return false }
			switch ident_lower(it) {
			case "none", "and", "or", "not", "initial", "inherit", "unset", "revert", "revert-layer", "default": return false
			}
			names[i] = strings.clone(it.tok.text, cx.alloc)
		}
		c.container_name = names
	case .Scrollbar_Width: return set_enum(vs, &c.scrollbar_width)
	case .Scrollbar_Color:
		items := split_items(vs)
		if len(items) == 1 && ident_lower(items[0]) == "auto" { c.scrollbar_color = {auto = true}; return true }
		if len(items) != 2 { return false }
		thumb, ok1 := parse_color(cx, items[0:1])
		track, ok2 := parse_color(cx, items[1:2])
		if !ok1 || !ok2 { return false }
		c.scrollbar_color = {thumb = thumb, track = track}
	case .Scrollbar_Gutter:
		items := split_items(vs)
		switch {
		case len(items) == 1 && ident_lower(items[0]) == "auto": c.scrollbar_gutter = .Auto
		case len(items) == 1 && ident_lower(items[0]) == "stable": c.scrollbar_gutter = .Stable
		case len(items) == 2 && ident_lower(items[0]) == "stable" && ident_lower(items[1]) == "both-edges",
		     len(items) == 2 && ident_lower(items[1]) == "stable" && ident_lower(items[0]) == "both-edges":
			c.scrollbar_gutter = .Stable_Both_Edges
		case: return false
		}
	}
	return true
}

// The context this element's children see: its own container (with the measured size) in front of its parent's.
@(private)
container_chain :: proc(e: ^Engine, c: ^Computed, parent: ^Computed, a := context.allocator) -> ^Container_Ctx {
	up := parent != nil ? parent.containers : nil
	if c.container_type == .Normal || c.display == .None { return up }
	ctx := new(Container_Ctx, a)
	ctx^ = Container_Ctx{node = c.node, type = c.container_type, names = c.container_name, parent = up}
	if s, ok := e.container_sizes[c.node]; ok {
		ctx.size.w, ctx.size.has_w = f64(s.x), true
		if c.container_type == .Size { ctx.size.h, ctx.size.has_h = f64(s.y), true }
	}
	return ctx
}

// cq units of an element: its nearest ancestor containers for each axis.
@(private)
container_units :: proc(lc: ^css.Length_Context, chain: ^Container_Ctx) {
	lc.has_cq_w, lc.has_cq_h = false, false
	for k := chain; k != nil; k = k.parent {
		if !lc.has_cq_w && k.size.has_w { lc.cq_w, lc.has_cq_w = k.size.w, true }
		if !lc.has_cq_h && k.size.has_h { lc.cq_h, lc.has_cq_h = k.size.h, true }
		if lc.has_cq_w && lc.has_cq_h { break }
	}
}

// Every @container condition around a rule holds for an element whose ancestors' containers are `chain` and whose
// parent's custom properties are `parent_custom` (style() queries without a name ask the parent).
@(private)
container_conditions_hold :: proc(conds: ^Cq_Cond, chain: ^Container_Ctx, parent_custom: ^Custom_Props) -> bool {
	for k := conds; k != nil; k = k.next {
		if !container_query_holds(k.query, chain, parent_custom) { return false }
	}
	return true
}

@(private)
container_query_holds :: proc(q: ^css.Container_Query, chain: ^Container_Ctx, parent_custom: ^Custom_Props) -> bool {
	// the query container: the nearest ancestor container with the name, and of a type the size features need
	needs_size := q.cond != nil && cq_needs_size(q.cond)
	target: ^Container_Ctx
	for k := chain; k != nil; k = k.parent {
		if q.name != "" {
			named := false
			for n in k.names { if n == q.name { named = true; break } }
			if !named { continue }
		}
		if needs_size && k.type == .Normal { continue }
		target = k
		break
	}
	if q.cond == nil { return target != nil }
	if target == nil && (needs_size || q.name != "") { return false }
	size := target != nil ? target.size : css.Container_Size{}
	return eval_cq(q.cond, size, parent_custom) == .True
}

@(private)
cq_needs_size :: proc(n: ^css.Cq_Node) -> bool {
	if n.kind == .Size { return true }
	for k in n.kids { if cq_needs_size(k) { return true } }
	return false
}

@(private)
eval_cq :: proc(n: ^css.Cq_Node, size: css.Container_Size, custom: ^Custom_Props) -> css.Tri {
	switch n.kind {
	case .Size: return css.cq_eval_size(n.size, size)
	case .Style:
		have := ""
		ok := false
		if custom != nil { have, ok = custom_get(custom, n.style_name) }
		if n.style_value == nil { return ok ? .True : .False }
		if !ok { return .False }
		want := css.serialize_values(n.style_value, context.temp_allocator)
		return normalize_ws(have) == normalize_ws(want) ? .True : .False
	case .Not:
		switch eval_cq(n.kids[0], size, custom) {
		case .True: return .False
		case .False: return .True
		case .Unknown: return .Unknown
		}
	case .And:
		r := css.Tri.True
		for k in n.kids {
			switch eval_cq(k, size, custom) {
			case .False: return .False
			case .Unknown: r = .Unknown
			case .True:
			}
		}
		return r
	case .Or:
		r := css.Tri.False
		for k in n.kids {
			switch eval_cq(k, size, custom) {
			case .True: return .True
			case .Unknown: r = .Unknown
			case .False:
			}
		}
		return r
	case .Unknown: return .Unknown
	}
	return .Unknown
}

// Whitespace runs collapsed and trimmed: custom property values compare as token sequences.
@(private)
normalize_ws :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	space := false
	for ch in strings.trim_space(s) {
		if ch == ' ' || ch == '\t' || ch == '\n' { space = true; continue }
		if space { strings.write_byte(&sb, ' '); space = false }
		strings.write_rune(&sb, ch)
	}
	return strings.to_string(sb)
}
