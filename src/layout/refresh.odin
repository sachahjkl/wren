package layout

import "core:sync"
import "core:time"
import "wb:base"
import "wb:style"

// The refresh path: when only paint-only values changed since the last full layout (style.layout_equal: transforms,
// opacity, colors, backgrounds, shadows, radii... the usual animations and hover effects), the boxes, lines and display
// list stay; only what is derived from those values is updated:
//   * the computed-style pointers of boxes, inline items and display items (an animation overlay or a partial restyle
//     hands out new Computed records), and the inherited paint-only values copied into anonymous boxes;
//   * the matrix of every Transform space, the alpha of every opacity group, the radii of every clip;
//   * the scrollable overflow and the document extent, when a transform applies (transformed bounds count).
// Anything that would change the structure (a scroll container starting or stopping to scroll, a node without a style)
// makes the refresh give up; the caller then lays out as usual.

@(private)
can_refresh :: proc(l: ^Layout, input: Input) -> bool {
	if !l.valid || l.last_pass == .None || !input.settings.paint_refresh { return false }
	st := input.styled
	return l.styled == rawptr(st) && l.layout_serial == st.layout_serial && l.canvas == st.canvas &&
		l.mutations == input.doc.mutations && l.viewport == input.viewport && l.scale == input.scale &&
		l.settings == input.settings^
}

// Inherited paint-only properties: what an anonymous box takes from its parent that can change without a layout.
@(private) anon_once: sync.Once
@(private) anon_list: [len(style.Prop)]style.Prop
@(private) anon_count: int

@(private)
anon_paint_props :: proc() -> []style.Prop {
	sync.once_do(&anon_once, proc() {
		// prop_tier first: it initializes the property tables is_inherited reads
		for p in style.Prop {
			if style.prop_tier(p) == .Paint && style.is_inherited(p) { anon_list[anon_count] = p; anon_count += 1 }
		}
	})
	return anon_list[:anon_count]
}

// After a full layout: what the refresh path needs to find quickly.
@(private)
note_refresh_inputs :: proc(l: ^Layout) {
	l.canvas_items = {NONE, NONE}
	root_el := l.boxes[0].first
	for &it, i in l.items {
		if it.kind != .Box || it.box < 0 { continue }
		if it.box == root_el { l.canvas_items[0] = i32(i) }
		if b := &l.boxes[it.box]; b.node == l.canvas_els[1] && b.node != base.NIL_HANDLE && .Pseudo not_in b.flags { l.canvas_items[1] = i32(i) }
	}
	l.loose_styles = false
	for &it in l.inline_items {
		if it.node != base.NIL_HANDLE && box_index(l, it.node) == NONE { l.loose_styles = true; break }
	}
}

@(private)
refresh :: proc(l: ^Layout, input: Input) -> bool {
	t0 := time.tick_now()
	st := input.styled
	remap := make(map[^style.Computed]^style.Computed, 256, context.temp_allocator)
	put :: proc(m: ^map[^style.Computed]^style.Computed, old, new: ^style.Computed) -> bool {
		if x, ok := m[old]; ok { return x == new }   // one record for two elements: cannot tell them apart
		m[old] = new
		return true
	}
	anon := anon_paint_props()
	// boxes in index order: a parent comes before its children (anonymous boxes copy from their parent)
	for &b in l.boxes {
		if .Root in b.flags { continue }
		if b.node == base.NIL_HANDLE {
			if b.parent == NONE || b.cs == nil { continue }
			pc := l.boxes[b.parent].cs
			for p in anon { style.copy_prop(b.cs, pc, p) }
			continue
		}
		el := style.style_of(st, b.node)
		if el == nil { return false }
		nc := el
		if .Pseudo in b.flags { nc = .Pseudo_After in b.flags ? el.after : el.before }
		if nc == nil { return false }
		if nc == b.cs { continue }   // an animation overlay is rewritten in place: same record, new values
		if !put(&remap, b.cs, nc) { return false }
		b.cs = nc
	}
	// nothing was replaced and every text belongs to an element with a box: inline and display items are up to date
	if len(remap) == 0 && !l.loose_styles { return refresh_rest(l, input, t0) }
	for &it in l.inline_items {
		if it.cs == nil { continue }
		if nc, ok := remap[it.cs]; ok { it.cs = nc; continue }
		if it.node == base.NIL_HANDLE { continue }   // the initial style: the same record for the whole pass
		// text whose owner generates no box (display: contents)
		el := style.style_of(st, it.node)
		if el == nil || !put(&remap, it.cs, el) { return false }
		it.cs = el
	}
	for &it in l.items {
		if it.cs != nil { if nc, ok := remap[it.cs]; ok { it.cs = nc } }
	}
	return refresh_rest(l, input, t0)
}

@(private = "file")
refresh_rest :: proc(l: ^Layout, input: Input, t0: time.Tick) -> bool {
	st := input.styled
	// the root's or body's background is the canvas: painted by the shell, not by their item
	for ii in l.canvas_items {
		if ii < 0 { continue }
		it := &l.items[ii]
		if l.boxes[it.box].cs.background_color == st.canvas { it.flags += {.No_Background} } else { it.flags -= {.No_Background} }
	}
	for &g in l.groups { g.alpha = max(l.boxes[g.box].cs.opacity, 0) }
	transforms := false   // some transform moved: the scrollable overflow follows
	for &sp in l.spaces {
		if sp.kind != .Transform { continue }
		m := box_matrix(l, &l.boxes[sp.box])
		if m != sp.mat { sp.mat = m; transforms = true }
	}
	for &cl in l.clips { cl.radii = clip_radii(l, &l.boxes[cl.box]) }
	if transforms && !refresh_overflow(l, input.viewport) { return false }
	l.serial = st.serial
	l.last_pass = .Refresh
	l.passes[.Refresh] += 1
	ms := f32(time.duration_milliseconds(time.tick_since(t0)))
	l.stats = {0, ms, 0, 0, 0}
	return true
}

// Scrollable overflow again (the transformed bounds moved). false: some container would start or stop scrolling.
@(private)
refresh_overflow :: proc(l: ^Layout, vp: Vec2) -> bool {
	order := preorder(l)
	doc := compute_overflow(l, order, fixed_boxes(l, order), vp)
	for &b in l.boxes {
		if .Scroll not_in b.flags || .Propagated in b.flags || b.kind == .Inline { continue }
		port := padding_rect(&b)
		ms := Vec2{max(b.overflow.max.x - port.max.x, 0), max(b.overflow.max.y - port.max.y, 0)}
		if b.cs.overflow_x != .Scroll && b.cs.overflow_x != .Auto { ms.x = 0 }
		if b.cs.overflow_y != .Scroll && b.cs.overflow_y != .Auto { ms.y = 0 }
		scrolls := ms.x > 0.5 || ms.y > 0.5
		if scrolls != (b.scroll_space != NONE) { return false }
		if !scrolls { continue }
		l.spaces[b.scroll_space].max_scroll = ms
		if off, ok := l.scroll[b.node]; ok { l.scroll[b.node] = {clamp(off.x, 0, ms.x), clamp(off.y, 0, ms.y)} }
	}
	l.height = l.doc_scroll_y ? max(doc.max.y, vp.y) : vp.y
	l.doc_width = max(doc.max.x, vp.x)
	return true
}
