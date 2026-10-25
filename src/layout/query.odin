package layout

import "core:math"
import "core:slice"
import "wb:base"

// Spatial index, per-frame views (scroll and sticky offsets, effective clips, opacity), hit testing, scrolling and box
// queries for the shell.

// Bands per space: items grouped by horizontal band of their own space, so painting and hit testing visit only what is
// near (a long scrolling list inside a box is indexed in its own coordinates).
@(private)
BAND_ENTRIES_PER_ITEM :: 15

@(private)
build_bands :: proc(l: ^Layout, band_h: f32) {
	ns := len(l.spaces)
	ymin := make([]f32, ns, context.temp_allocator)
	ymax := make([]f32, ns, context.temp_allocator)
	count := make([]int, ns, context.temp_allocator)
	tall := make([]f64, ns, context.temp_allocator)   // the heights of the items added up
	for i in 0 ..< ns { ymin[i], ymax[i] = math.F32_MAX, -math.F32_MAX }
	for &it in l.items {
		s := it.space
		ymin[s] = min(ymin[s], it.rect.min.y)
		ymax[s] = max(ymax[s], it.rect.max.y)
		count[s] += 1
		tall[s] += f64(max(it.rect.max.y - it.rect.min.y, 0))
	}
	total: i32
	for i in 0 ..< ns {
		sp := &l.spaces[i]
		if count[i] == 0 { sp.band_first, sp.band_count, sp.band0 = total, 0, 0; continue }
		// an item is listed in every band it crosses: about tall / bh + count entries. Bands are made taller when items
		// are (thousands of overlapping page-high boxes listed in thousands of bands each: gigabytes, then u32 sums that
		// wrapped): at most BAND_ENTRIES_PER_ITEM entries per item on average
		bh := max(band_h, f32(tall[i] / f64(BAND_ENTRIES_PER_ITEM * count[i] + 4096)))
		nb := int((ymax[i] - ymin[i]) / bh) + 1
		nb = clamp(nb, 1, 2 * count[i] + 1)
		sp.band0 = ymin[i]
		sp.band_first, sp.band_count = total, i32(nb)
		sp.band_h = max(bh, (ymax[i] - ymin[i]) / f32(nb) + 0.001)
		total += i32(nb)
	}
	clear(&l.band_start)
	resize(&l.band_start, int(total) + 1)
	for i in 0 ..< len(l.band_start) { l.band_start[i] = 0 }
	span :: proc(sp: ^Space, r: Rect) -> (int, int) {
		b0 := clamp(int((r.min.y - sp.band0) / sp.band_h), 0, int(sp.band_count) - 1)
		b1 := clamp(int((r.max.y - sp.band0) / sp.band_h), b0, int(sp.band_count) - 1)
		return int(sp.band_first) + b0, int(sp.band_first) + b1
	}
	// the bands of each item, found once (the items are large: read them once more, not twice)
	spans := make([][2]u32, len(l.items), context.temp_allocator)
	for &it, i in l.items {
		b0, b1 := span(&l.spaces[it.space], it.rect)
		spans[i] = {u32(b0), u32(b1)}
		for b in b0 ..= b1 { l.band_start[b + 1] += 1 }
	}
	for b in 1 ..< len(l.band_start) { l.band_start[b] += l.band_start[b - 1] }
	clear(&l.band_items)
	non_zero_resize(&l.band_items, int(l.band_start[len(l.band_start) - 1]))
	fill := make([]u32, int(total), context.temp_allocator)
	for sp, i in spans {
		for b in int(sp[0]) ..= int(sp[1]) {
			l.band_items[int(l.band_start[b] + fill[b])] = u32(i)
			fill[b] += 1
		}
	}
}

// What one frame needs: where each space is, the effective clip bounds (viewport coordinates), the effective opacity of
// each group, and the items that can be visible, in paint order.
//
// A layout point p of an item in space s is drawn at mats[s](p + offsets[s]): offsets are the scroll and sticky
// translations; mats[s] is the identity unless a transformed box encloses the space (Space.xform != NONE), then the
// product of the transforms, outermost first, each taken around where its box is drawn. Inside a 3D plane (Space.plane !=
// NONE) the product starts at the plane: mats is relative to the plane's frame, and ccs projects the plane.
View :: struct {
	offsets:  []Vec2,
	mats:     []Matrix,   // per space
	invs:     []Matrix,   // per space: inverse of mats (viewport -> untransformed)
	accs:     []Matrix4,  // per plane space: its frame -> the frame of what receives it (plane.odin)
	singular: []bool,     // per space: a transform above flattens it to nothing (not drawn, not hit)
	clips:    []Rect,     // per clip: bounds in viewport coordinates, intersected with the enclosing clips' bounds
	alphas:   []f32,
	visible:  []u32,
	viewport: Vec2,
	doc_scroll: f32,
	transformed: bool,    // some space is under a transform
}

// The space draws untransformed (only its offset applies).
space_plain :: #force_inline proc(l: ^Layout, s: i32) -> bool { return l.spaces[s].xform == NONE }

// Viewport point -> untransformed layout point of space `s` (offset removed). ok = false: the space is flattened.
view_to_local :: proc(l: ^Layout, v: ^View, s: i32, p: Vec2) -> (Vec2, bool) {
	if space_plain(l, s) { return p - v.offsets[s], true }
	if v.singular[s] { return {}, false }
	if pl := l.spaces[s].plane; pl != NONE {
		u, _, ok := plane_point(l, v, pl, p)
		if !ok { return {}, false }
		if s == pl { return u - v.offsets[s], true }
		return mat_apply(v.invs[s], u) - v.offsets[s], true
	}
	return mat_apply(v.invs[s], p) - v.offsets[s], true
}

// Untransformed layout point of space `s` -> viewport point.
view_from_local :: proc(l: ^Layout, v: ^View, s: i32, p: Vec2) -> Vec2 {
	q := p + v.offsets[s]
	if space_plain(l, s) { return q }
	if pl := l.spaces[s].plane; pl != NONE {
		r, _ := plane_project(l, v, pl, mat_apply(v.mats[s], q))
		return r
	}
	return mat_apply(v.mats[s], q)
}

// Is the viewport point `p` inside clip `ci` and all the clips around it (rounded corners and transforms respected)?
clip_contains :: proc(l: ^Layout, v: ^View, ci: i32, p: Vec2) -> bool {
	for c := ci; c != NONE; c = l.clips[c].parent {
		cl := &l.clips[c]
		// (the bounds of a clip inside a plane are in the plane's frame: the exact test below covers it)
		if l.spaces[cl.space].plane == NONE && !rect_contains(v.clips[c], p) { return false }
		if space_plain(l, cl.space) && cl.radii == {} { continue }
		q, ok := view_to_local(l, v, cl.space, p)
		if !ok || !rounded_contains(cl.rect, cl.radii, q) { return false }
	}
	return true
}

scroll_offset_of :: proc(l: ^Layout, sp: ^Space) -> Vec2 {
	b := &l.boxes[sp.box]
	off, _ := l.scroll[b.node]
	return {clamp(off.x, 0, sp.max_scroll.x), clamp(off.y, 0, sp.max_scroll.y)}
}

@(private)
sticky_offset :: proc(l: ^Layout, sp: ^Space, viewport: Vec2, doc_scroll: f32) -> Vec2 {
	view: Rect
	if sp.frame > FIXED_SPACE {
		f := &l.spaces[sp.frame]
		so := scroll_offset_of(l, f)
		view = Rect{f.port.min + so, f.port.max + so}
	} else if sp.frame == FIXED_SPACE {
		view = Rect{{0, 0}, viewport}
	} else {
		view = Rect{{0, doc_scroll}, {viewport.x, doc_scroll + viewport.y}}
	}
	r, lim := sp.port, sp.limit
	d: Vec2
	in2 := sp.inset
	if !math.is_nan(in2[0]) {
		want := view.min.y + in2[0]
		if r.min.y < want { d.y = max(min(want - r.min.y, lim.max.y - r.max.y), 0) }
	}
	if !math.is_nan(in2[2]) && d.y == 0 {
		want := view.max.y - in2[2]
		if r.max.y > want { d.y = min(max(want - r.max.y, lim.min.y - r.min.y), 0) }
	}
	if !math.is_nan(in2[3]) {
		want := view.min.x + in2[3]
		if r.min.x < want { d.x = max(min(want - r.min.x, lim.max.x - r.max.x), 0) }
	}
	if !math.is_nan(in2[1]) && d.x == 0 {
		want := view.max.x - in2[1]
		if r.max.x > want { d.x = min(max(want - r.max.x, lim.min.x - r.min.x), 0) }
	}
	return d
}

// `viewport`: device px; `doc_scroll`: the page's vertical scroll offset (device px). With `cull`, `visible` lists the
// items intersecting the viewport.
view_make :: proc(l: ^Layout, viewport: Vec2, doc_scroll: f32, cull := true, allocator := context.temp_allocator) -> View {
	v := View{viewport = viewport, doc_scroll = doc_scroll}
	ns := len(l.spaces)
	v.offsets = make([]Vec2, ns, allocator)
	v.mats = make([]Matrix, ns, allocator)
	v.invs = make([]Matrix, ns, allocator)
	v.accs = make([]Matrix4, ns, allocator)
	v.singular = make([]bool, ns, allocator)
	for i in 0 ..< ns {
		sp := &l.spaces[i]
		switch sp.kind {
		case .Document: v.offsets[i] = {0, -doc_scroll}
		case .Fixed: v.offsets[i] = {0, 0}
		case .Scroll: v.offsets[i] = v.offsets[sp.parent] - scroll_offset_of(l, sp)
		case .Sticky: v.offsets[i] = v.offsets[sp.parent] + sticky_offset(l, sp, viewport, doc_scroll)
		case .Transform: v.offsets[i] = v.offsets[sp.parent]
		}
		v.mats[i], v.invs[i] = IDENTITY, IDENTITY
		if sp.kind == .Transform && sp.proj {
			// a plane: its frame starts here (its own transform is the projection, accs)
			acc, ok := plane_acc(l, &v, i32(i))
			v.accs[i] = acc
			v.singular[i] = !ok || (sp.parent != NONE && v.singular[sp.parent])
			v.transformed = true
		} else if sp.kind == .Transform {
			// the box's transform, around where the box is drawn, then whatever encloses it
			outer := sp.parent != NONE ? v.mats[sp.parent] : IDENTITY
			m := mat_mul(outer, mat_shifted(sp.mat, v.offsets[i]))
			inv, ok := mat_inverse(m)
			v.mats[i], v.invs[i] = m, inv
			v.singular[i] = !ok || (sp.parent != NONE && v.singular[sp.parent])
			v.transformed = true
		} else if sp.parent != NONE {
			v.mats[i], v.invs[i], v.singular[i] = v.mats[sp.parent], v.invs[sp.parent], v.singular[sp.parent]
		}
	}
	v.clips = make([]Rect, len(l.clips), allocator)
	for i in 0 ..< len(l.clips) {
		cl := &l.clips[i]
		r := rect_shift(cl.rect, v.offsets[cl.space])
		if !space_plain(l, cl.space) { r = v.singular[cl.space] ? Rect{} : mat_bounds(v.mats[cl.space], r) }
		// (bounds of clips in different frames, a plane's and the page's, do not compare)
		if cl.parent != NONE && l.spaces[cl.space].plane == l.spaces[l.clips[cl.parent].space].plane { r = rect_intersect(r, v.clips[cl.parent]) }
		v.clips[i] = r
	}
	v.alphas = make([]f32, len(l.groups), allocator)
	for i in 0 ..< len(l.groups) {
		g := &l.groups[i]
		v.alphas[i] = g.alpha * (g.parent != NONE ? v.alphas[g.parent] : 1)
	}
	if !cull { return v }
	vis := make([dynamic]u32, 0, 1024, allocator)
	screen := Rect{{0, 0}, viewport}
	// filters spread what items paint: bands are searched that much further (each item then by its own groups' reach)
	reach: f32
	for &g in l.groups { reach = max(reach, g.reach) }
	for i in 0 ..< len(l.spaces) {
		sp := &l.spaces[i]
		if sp.band_count == 0 { continue }
		region := screen
		if sp.clip != NONE && sp.plane == NONE { region = rect_intersect(region, v.clips[sp.clip]) }
		if rect_empty(region) { continue }
		local: Rect
		if sp.plane != NONE {
			// inside a plane: its content is culled where it is projected (the compositor), not item by item here
			if v.singular[i] { continue }
			local = Rect{{-1e9, -1e9}, {1e9, 1e9}}
		} else if space_plain(l, i32(i)) {
			local = rect_shift(region, -v.offsets[i])
		} else {
			if v.singular[i] { continue }
			local = rect_shift(mat_bounds(v.invs[i], region), -v.offsets[i])
		}
		search := Rect{local.min - reach, local.max + reach}
		b0 := clamp(int((search.min.y - sp.band0) / sp.band_h), 0, int(sp.band_count) - 1)
		b1 := clamp(int((search.max.y - sp.band0) / sp.band_h), b0, int(sp.band_count) - 1)
		if search.max.y < sp.band0 || search.min.y > sp.band0 + f32(sp.band_count) * sp.band_h { continue }
		for b in b0 ..= b1 {
			g := int(sp.band_first) + b
			for idx in l.band_items[l.band_start[g]:l.band_start[g + 1]] {
				r := l.items[idx].rect
				if l.items[idx].kind == .Box && len(l.items[idx].cs.box_shadow) > 0 { append(&vis, idx); continue }
				// filters (blur, drop shadows) of the groups around it spread what it paints
				if g := l.items[idx].group; g != NONE && l.groups[g].reach > 0 { r = Rect{r.min - l.groups[g].reach, r.max + l.groups[g].reach} }
				if r.max.y < local.min.y || r.min.y > local.max.y || r.max.x < local.min.x || r.min.x > local.max.x {
					if l.items[idx].kind != .Text { continue }
					// text shadows and italic overhang reach a little outside the item
					if r.max.y + 8 < local.min.y || r.min.y - 8 > local.max.y { continue }
				}
				append(&vis, idx)
			}
		}
	}
	slice.sort(vis[:])
	n := 0
	for i in 0 ..< len(vis) {
		if n > 0 && vis[n - 1] == vis[i] { continue }
		vis[n] = vis[i]
		n += 1
	}
	v.visible = vis[:n]
	return v
}

// Viewport rect of an item for this view, and whether its clip leaves anything of it.
item_rect :: proc(l: ^Layout, v: ^View, it: ^Display_Item) -> Rect {
	return rect_shift(it.rect, v.offsets[it.space])
}

Hit :: struct {
	node: base.Handle,   // the element hit (NIL: nothing)
	box:  i32,
	item: i32,
}

// Topmost hittable item under `p` (viewport coordinates): stacking order, clips (rounded corners included),
// transforms (the point goes through the inverse of each transformed space), pointer-events and visibility respected.
hit_test :: proc(l: ^Layout, p: Vec2, viewport: Vec2, doc_scroll: f32) -> Hit {
	if !l.valid || len(l.items) == 0 { return Hit{box = NONE, item = NONE} }
	v := view_make(l, viewport, doc_scroll, cull = false)
	best := i32(-1)
	best_plane, best_ctx := NONE, NONE   // the plane the best item is in, and the root of its 3D context
	best_z: f32
	for i in 0 ..< len(l.spaces) {
		sp := &l.spaces[i]
		if sp.band_count == 0 { continue }
		if sp.clip != NONE && sp.plane == NONE && !rect_contains(v.clips[sp.clip], p) { continue }
		local, ok := view_to_local(l, &v, i32(i), p)
		if !ok { continue }
		// where the ray meets the plane the space is in: items of planes in one 3D context are ordered by depth
		z: f32
		ctx := NONE
		if sp.plane != NONE {
			_, z, _ = plane_point(l, &v, sp.plane, p)
			ctx = l.spaces[sp.plane].ctx
		}
		// in f32 first: a point mapped through an extreme transform can be huge or NaN, which int() turns negative
		fb := (local.y - sp.band0) / sp.band_h
		if !(fb >= 0 && fb < f32(sp.band_count)) { continue }
		b := int(fb)
		g := int(sp.band_first) + b
		list := l.band_items[l.band_start[g]:l.band_start[g + 1]]
		sorted := ctx != NONE && ctx == best_ctx && sp.plane != best_plane
		for k := len(list) - 1; k >= 0; k -= 1 {
			idx := i32(list[k])
			if idx <= best && !sorted { break }
			it := &l.items[idx]
			if .Hit not_in it.flags || !rect_contains(it.rect, local) { continue }
			if it.clip != NONE && !clip_contains(l, &v, it.clip, p) { continue }
			if it.group != NONE && !group_clips_contain(l, &v, it.group, p) { continue }
			// nearer wins inside a 3D context (equal depth: the later item); anywhere else the later item
			if sorted && best >= 0 {
				if z < best_z - 1e-4 || (abs(z - best_z) <= 1e-4 && idx < best) { break }
			} else if idx <= best { break }
			best, best_plane, best_ctx, best_z = idx, sp.plane, ctx, z
			break
		}
	}
	if best < 0 { return Hit{box = NONE, item = NONE} }
	it := &l.items[best]
	return Hit{node = it.node, box = it.box, item = best}
}

// Wheel scrolling: the deepest scroll container under `p` that can still move in the direction of `delta` (device px,
// positive = towards the end) takes it. false: none did; the page scrolls.
scroll_wheel :: proc(l: ^Layout, p: Vec2, delta: Vec2, viewport: Vec2, doc_scroll: f32) -> bool {
	h := hit_test(l, p, viewport, doc_scroll)
	if h.item == NONE { return false }
	try :: proc(l: ^Layout, s: i32, delta: Vec2) -> bool {
		sp := &l.spaces[s]
		node := l.boxes[sp.box].node
		cur := scroll_offset_of(l, sp)
		next := Vec2{clamp(cur.x + delta.x, 0, sp.max_scroll.x), clamp(cur.y + delta.y, 0, sp.max_scroll.y)}
		if math.abs(next.x - cur.x) < 0.01 && math.abs(next.y - cur.y) < 0.01 { return false }
		l.scroll[node] = next
		return true
	}
	if b := &l.boxes[h.box]; b.scroll_space != NONE && try(l, b.scroll_space, delta) { return true }
	for s := l.items[h.item].space; s != NONE; s = l.spaces[s].parent {
		if l.spaces[s].kind == .Scroll && try(l, s, delta) { return true }
	}
	return false
}

// The bounds of clip `ci` alone (viewport coordinates, device px): the padding box of the box that clips, where it is
// drawn, not intersected with the clips around it (View.clips is). ok = false for a clip inside a 3D plane, whose frame
// has no bounds to compare with the page's. Rounded corners are not taken into account.
clip_bounds :: proc(l: ^Layout, v: ^View, ci: i32) -> (Rect, bool) {
	cl := &l.clips[ci]
	if l.spaces[cl.space].plane != NONE { return {}, false }
	r := rect_shift(cl.rect, v.offsets[cl.space])
	if !space_plain(l, cl.space) { r = v.singular[cl.space] ? Rect{} : mat_bounds(v.mats[cl.space], r) }
	return r, true
}

// Scroll offset of a scroll container (device px), for scrollTop / scrollLeft.
scroll_of :: proc(l: ^Layout, node: base.Handle) -> (Vec2, bool) {
	bi := box_index(l, node)
	if bi == NONE || l.boxes[bi].scroll_space == NONE { return {}, false }
	return scroll_offset_of(l, &l.spaces[l.boxes[bi].scroll_space]), true
}

// Sets the scroll offset of a scroll container (clamped). Returns the offset applied.
set_scroll :: proc(l: ^Layout, node: base.Handle, off: Vec2) -> (Vec2, bool) {
	bi := box_index(l, node)
	if bi == NONE || l.boxes[bi].scroll_space == NONE { return {}, false }
	sp := &l.spaces[l.boxes[bi].scroll_space]
	v := Vec2{clamp(off.x, 0, sp.max_scroll.x), clamp(off.y, 0, sp.max_scroll.y)}
	l.scroll[node] = v
	return v, true
}

// Largest scroll offset of a scroll container.
scroll_max :: proc(l: ^Layout, node: base.Handle) -> (Vec2, bool) {
	bi := box_index(l, node)
	if bi == NONE || l.boxes[bi].scroll_space == NONE { return {}, false }
	return l.spaces[l.boxes[bi].scroll_space].max_scroll, true
}

box_index :: proc(l: ^Layout, node: base.Handle) -> i32 {
	i := int(base.handle_index(node))
	if i >= len(l.node_box) { return NONE }
	bi := l.node_box[i]
	if bi == NONE || l.boxes[bi].node != node { return NONE }
	return bi
}

Box_Rects :: struct {
	border, padding, content: Rect,   // document coordinates (scroll offsets of containers and sticky shifts applied),
	                                  // before the transforms that apply to the box (its own and its ancestors')
	transformed: bool,                // some transform applies: the box is drawn at `transform` of these rects
	transform:   Matrix,              // document coordinates -> where they are drawn (document coordinates)
	inverse:     Matrix,              // the other way (identity when the transform is singular)
	quad:        [4]Vec2,             // corners of the drawn border box: top-left, top-right, bottom-right, bottom-left
	bounds:      Rect,                // bounds of the drawn border box (= border without a transform)
	projective:  bool,                // in a 3D plane: `inverse` is only the best affine map, `unproject` is exact
	unproject:   [9]f32,              // 3x3 (acting on x, y, 1, then the divide by w): where the box is drawn -> its untransformed rects
	fixed:   bool,                    // inside a position: fixed box: moves with the viewport
	visible: bool,                    // visibility: visible
}

// A point where the box is drawn (document coordinates) in the coordinates of its untransformed rects: what a click on
// a rotated text field means for its caret.
box_point_to_local :: proc(r: Box_Rects, p: Vec2) -> Vec2 {
	if !r.transformed { return p }
	if r.projective {
		if q, ok := h3_apply(r.unproject, p); ok { return q }
	}
	return mat_apply(r.inverse, p)
}

// Where an element's box is, for focus rings, carets and scroll-into-view. Inline boxes: the union of their fragments.
// Under a transform the rects are the box's own (local) geometry; `transform`, `quad` and `bounds` say where it shows.
box_of :: proc(l: ^Layout, node: base.Handle, viewport: Vec2, doc_scroll: f32) -> (Box_Rects, bool) {
	bi := box_index(l, node)
	if bi == NONE || !l.valid { return {}, false }
	v := view_make(l, viewport, doc_scroll, cull = false)
	return box_of_view(l, &v, node)
}

// box_of over a view made already (view_make with cull = false, for the viewport and page scroll the rects are wanted
// for): the observers read many boxes of one frame and make the view once. The view is stale after the layout changes.
box_of_view :: proc(l: ^Layout, v: ^View, node: base.Handle) -> (Box_Rects, bool) {
	bi := box_index(l, node)
	if bi == NONE || !l.valid { return {}, false }
	b := &l.boxes[bi]
	doc_scroll := v.doc_scroll
	off := v.offsets[b.space] + {0, doc_scroll}
	r: Box_Rects
	r.border = rect_shift(border_rect(b), off)
	if b.kind == .Inline {
		r.padding = Rect{r.border.min + {b.border[3], b.border[0]}, r.border.max - {b.border[1], b.border[2]}}
		r.content = Rect{r.padding.min + {b.padding[3], b.padding[0]}, r.padding.max - {b.padding[1], b.padding[2]}}
	} else {
		r.padding = rect_shift(padding_rect(b), off)
		r.content = rect_shift(content_rect(b), off)
	}
	sp := b.space
	for sp > FIXED_SPACE { sp = l.spaces[sp].parent }
	r.fixed = sp == FIXED_SPACE
	r.visible = .Hidden not_in b.flags
	r.transform, r.inverse = IDENTITY, IDENTITY
	q := r.border
	r.quad = {q.min, {q.max.x, q.min.y}, q.max, {q.min.x, q.max.y}}
	r.bounds = q
	if pl := l.spaces[b.space].plane; pl != NONE {
		// in a 3D plane: the corners go through the plane's projection (perspective divide included); `transform` is the
		// affine map that fits the first three corners (a stand-in for callers that want a 2D matrix; `unproject` is the exact
		// way back, see box_point_to_local), `bounds` the box of the quad (CSS Transforms 2: getBoundingClientRect)
		ds := Vec2{0, doc_scroll}
		corners := [4]Vec2{q.min, {q.max.x, q.min.y}, q.max, {q.min.x, q.max.y}}
		r.transformed = true
		first := true
		for c, k in corners {
			pp, ok := plane_project(l, v, pl, mat_apply(v.mats[b.space], c - ds))
			if v.singular[b.space] { ok = false }
			if !ok { continue }
			pp += ds
			r.quad[k] = pp
			if first { r.bounds = Rect{pp, pp}; first = false } else { r.bounds = rect_union(r.bounds, Rect{pp, pp}) }
		}
		if first { r.bounds = Rect{}; r.quad = {} }
		w, h := q.max.x - q.min.x, q.max.y - q.min.y
		if w > 0 && h > 0 && !first {
			ex := (r.quad[1] - r.quad[0]) / w
			ey := (r.quad[3] - r.quad[0]) / h
			x0 := q.min
			m := Matrix{ex.x, ex.y, ey.x, ey.y, 0, 0}
			m[4] = r.quad[0].x - (m[0] * x0.x + m[2] * x0.y)
			m[5] = r.quad[0].y - (m[1] * x0.x + m[3] * x0.y)
			r.transform = m
			if inv, ok := mat_inverse(m); ok { r.inverse = inv }
		}
		// the exact map: a document point -> viewport -> the plane's frame (perspective divide) -> the box's space
		if !v.singular[b.space] {
			fwd := h3_mul(h3_from_matrix(Matrix{1, 0, 0, 1, 0, ds.y}), h3_mul(plane_chain_h3(l, v, pl), h3_mul(h3_from_matrix(v.mats[b.space]), h3_from_matrix(Matrix{1, 0, 0, 1, 0, -ds.y}))))
			if inv, ok := h3_inverse(fwd); ok { r.projective, r.unproject = true, inv }
		}
	} else if !space_plain(l, b.space) {
		// the view's matrix works on viewport coordinates; these rects are in document coordinates
		ds := Vec2{0, doc_scroll}
		m := v.singular[b.space] ? Matrix{} : mat_shifted(v.mats[b.space], ds)
		r.transformed = true
		r.transform = m
		if inv, ok := mat_inverse(m); ok { r.inverse = inv }
		for &c in r.quad { c = mat_apply(m, c) }
		r.bounds = mat_bounds(m, q)
	}
	return r, true
}

// The page's own scroll bar (viewport coordinates), when the page is taller than the viewport.
doc_scrollbar :: proc(l: ^Layout, viewport: Vec2, doc_scroll: f32) -> (track, thumb: Rect, ok: bool) {
	if !l.valid || !l.settings.document_scrollbar || l.height <= viewport.y + 0.5 { return }
	// the viewport's bar follows the root element's scrollbar-width
	thin := false
	if len(l.boxes) > 0 {
		if r := l.boxes[0].first; r != NONE && l.boxes[r].cs != nil {
			#partial switch l.boxes[r].cs.scrollbar_width {
			case .None: return
			case .Thin: thin = true
			}
		}
	}
	s := l.scale
	w := l.settings.scrollbar_width * s * (thin ? 0.5 : 1)
	m := l.settings.scrollbar_margin * s
	track = Rect{{viewport.x - w - m, m}, {viewport.x - m, viewport.y - m}}
	th := max((track.max.y - track.min.y) * viewport.y / l.height, l.settings.scrollbar_min_thumb * s)
	th = min(th, track.max.y - track.min.y)
	range := l.height - viewport.y
	t := range > 0 ? clamp(doc_scroll / range, 0, 1) : 0
	y := track.min.y + (track.max.y - track.min.y - th) * t
	thumb = Rect{{track.min.x, y}, {track.max.x, y + th}}
	return track, thumb, true
}

// Thumb of a scroll bar item for this view (viewport coordinates).
scrollbar_thumb :: proc(l: ^Layout, v: ^View, it: ^Display_Item) -> Rect {
	b := &l.boxes[it.box]
	if b.scroll_space == NONE { return {} }
	sp := &l.spaces[b.scroll_space]
	track := item_rect(l, v, it)
	so := scroll_offset_of(l, sp)
	port := sp.port.max - sp.port.min
	min_t := l.settings.scrollbar_min_thumb * l.scale
	if .Vertical in it.flags {
		len_ := track.max.y - track.min.y
		th := min(max(len_ * port.y / (port.y + sp.max_scroll.y), min_t), len_)
		t := sp.max_scroll.y > 0 ? so.y / sp.max_scroll.y : 0
		y := track.min.y + (len_ - th) * t
		return Rect{{track.min.x, y}, {track.max.x, y + th}}
	}
	len_ := track.max.x - track.min.x
	th := min(max(len_ * port.x / (port.x + sp.max_scroll.x), min_t), len_)
	t := sp.max_scroll.x > 0 ? so.x / sp.max_scroll.x : 0
	x := track.min.x + (len_ - th) * t
	return Rect{{x, track.min.y}, {x + th, track.max.y}}
}
