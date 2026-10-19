package layout

import "core:math"
import "wb:base"
import "wb:style"

// Splicing the display list. When an incremental pass changed only the content of some inline formatting contexts
// (text edited, inline elements added or removed inside a paragraph) and nothing else moved, finishing and the display
// list need not be made again: the new inline boxes get their coordinates, clips and spaces from their context root,
// and the items of each such context (its list marker and its lines, contiguous in paint order: display.odin,
// emit_own_lines) are replaced by new ones. Everything else keeps its items; only their styles are re-read, as the
// refresh path does.
//
// Conditions, all checked (else the pass finishes and builds the display list as usual):
//   * the pass had no other cause than those content changes (no viewport change, no style change for layout in the
//     style journal, no natural size or font change, no single child rebuilt);
//   * every rebuilt context root is a block container whose content, before and after, is only text and inline boxes
//     that are neither positioned nor stacking contexts nor outlined (their items are all in that one range), and which
//     is not a scroll container;
//   * no box outside those contexts moved or changed size (geometry snapshots taken as boxes are laid out again);
//   * the scrollable overflow and the document extent keep their value: what the context's content covered before and
//     covers now stays strictly inside them (or along an edge the container itself defines).

// A rebuilt context root that may be spliced, with what its content covered before.
@(private)
Splice_Root :: struct {
	box:    i32,
	before: Rect,     // layout coordinates
	any:    bool,     // it had content
}

@(private)
Snap :: struct {
	box:       i32,
	pos, size: Vec2,
	marker:    Vec2,
}

// Is the content of inline formatting context `p` only text and plain inline boxes? Styles are read from `st` (the
// current ones: before the boxes are re-pointed at them, their own records may be gone; no layout value of any element
// changed when this is asked).
@(private)
inline_only :: proc(l: ^Layout, st: ^style.Styled, p: i32) -> bool {
	b := &l.boxes[p]
	if .Ifc not_in b.flags || .Scroll in b.flags { return false }
	for i in b.items[0] ..< b.items[1] {
		it := &l.inline_items[i]
		#partial switch it.kind {
		case .Atomic, .Float, .Abs, .Block: return false
		case .Open:
			ib := &l.boxes[it.box]
			if .Positioned in ib.flags || .Stacking in ib.flags { return false }
			cs := style.style_of(st, ib.node)
			if cs != nil && .Pseudo in ib.flags { cs = .Pseudo_After in ib.flags ? cs.after : cs.before }
			if cs == nil || cs.outline_width > 0 { return false }
		}
	}
	return true
}

// What the lines of context `p` cover (layout coordinates), and whether there is anything.
@(private)
lines_extent :: proc(l: ^Layout, p: i32) -> (Rect, bool) {
	b := &l.boxes[p]
	r := Rect{{math.F32_MAX, math.F32_MAX}, {-math.F32_MAX, -math.F32_MAX}}
	any := false
	for li in b.lines[0] ..< b.lines[1] {
		ln := &l.lines[li]
		for fi in ln.frags[0] ..< ln.frags[1] {
			f := &l.frags[fi]
			if f.w <= 0 || f.h <= 0 { continue }
			r = rect_union(r, rect_shift(Rect{{f.x, f.y}, {f.x + f.w, f.y + f.h}}, b.abs))
			any = true
		}
	}
	return r, any
}

// Before the rebuild: the roots whose old items can be replaced.
@(private)
splice_candidates :: proc(l: ^Layout, st: ^style.Styled, roots: []i32) -> map[i32]Splice_Root {
	out := make(map[i32]Splice_Root, len(roots), context.temp_allocator)
	for r in roots {
		inf := &l.inc.info[r]
		if inf.items_gen != l.inc.dl_gen || !inline_only(l, st, r) { continue }
		ext, any := lines_extent(l, r)
		out[r] = Splice_Root{box = r, before = ext, any = any}
	}
	return out
}

// Snapshot of what a box laid out again may move: its children (and the rows of its row groups, the inline boxes of
// its lines), taken before it changes them.
@(private)
snap_children :: proc(c: ^Ctx, bi: i32) {
	pass := c.inc
	if !pass.snapping || pass.snapped[bi] { return }
	pass.snapped[bi] = true
	l := c.l
	b := &l.boxes[bi]
	append(&pass.snap, Snap{box = bi, pos = b.pos, size = b.size, marker = b.marker_pos})
	for ch := b.first; ch != NONE; ch = l.boxes[ch].next {
		k := &l.boxes[ch]
		append(&pass.snap, Snap{box = ch, pos = k.pos, size = k.size, marker = k.marker_pos})
		if k.kind == .Row_Group || k.kind == .Inline {
			for g := k.first; g != NONE; g = l.boxes[g].next {
				x := &l.boxes[g]
				append(&pass.snap, Snap{box = g, pos = x.pos, size = x.size, marker = x.marker_pos})
			}
		}
	}
	for a := b.abs_first; a != NONE; a = l.boxes[a].abs_next {
		k := &l.boxes[a]
		append(&pass.snap, Snap{box = a, pos = k.pos, size = k.size, marker = k.marker_pos})
	}
}

// Coordinates, clips, spaces and groups of the inline boxes of context `p` (all plain: see inline_only).
@(private)
finish_inline :: proc(l: ^Layout, p: i32) {
	pb := &l.boxes[p]
	stack := make([dynamic]i32, 0, 16, context.temp_allocator)
	for ch := pb.first; ch != NONE; ch = l.boxes[ch].next { append(&stack, ch) }
	for len(stack) > 0 {
		x := pop(&stack)
		b := &l.boxes[x]
		par := &l.boxes[b.parent]
		b.rel = {}
		b.abs = l.boxes[b.pos_ref].abs
		b.clip_owner = (.Clips in par.flags && .Propagated not_in par.flags && par.kind != .Inline) ? b.parent : par.clip_owner
		b.space, b.clip = par.content_space, par.content_clip
		b.content_space, b.content_clip = b.space, b.clip
		b.group = par.group
		b.scroll_space = NONE
		b.layer = NONE
		for ch := b.first; ch != NONE; ch = l.boxes[ch].next { append(&stack, ch) }
	}
}

// The rect `owner` (a scroll container, NONE: the document) gathers the scrollable overflow in, and the part of it
// the owner defines by itself.
@(private)
overflow_of :: proc(l: ^Layout, owner: i32) -> (all, base: Rect) {
	if owner == NONE { return l.inc.doc_extent, Rect{{0, 0}, l.viewport} }
	o := &l.boxes[owner]
	return o.overflow, padding_rect(o)
}

// Content of `p` going from `before` to `after` leaves the overflow it counts in unchanged.
@(private)
overflow_kept :: proc(l: ^Layout, p: i32, before: Rect, had: bool, after: Rect, has: bool) -> bool {
	b := &l.boxes[p]
	if .Clips in b.flags && .Propagated not_in b.flags { return true }   // its own clip holds it: its box is what counts
	owner := b.clip_owner
	// a transform between the context and the owner bounds the content by its transformed corners: not followed here
	for x := p; x != NONE && x != owner; x = containing_parent(&l.boxes[x]) {
		if .Transformed in l.boxes[x].flags { return false }
		if .Fixed in l.boxes[x].flags && owner == NONE { return true }   // in a fixed box: not part of the document
	}
	if owner != NONE && .Scroll not_in l.boxes[owner].flags { return true }   // only scroll containers gather it
	all, base := overflow_of(l, owner)
	if has && !(after.min.x >= all.min.x && after.min.y >= all.min.y && after.max.x <= all.max.x && after.max.y <= all.max.y) { return false }
	if had {
		// an edge the old content reached may have been defined by it alone
		if before.max.x >= all.max.x && base.max.x < all.max.x { return false }
		if before.max.y >= all.max.y && base.max.y < all.max.y { return false }
		if before.min.x <= all.min.x && base.min.x > all.min.x { return false }
		if before.min.y <= all.min.y && base.min.y > all.min.y { return false }
	}
	return true
}

// Every display item takes the style its box or inline item now has (a restyle hands out new records).
@(private)
remap_display_items :: proc(l: ^Layout) {
	for &it in l.items {
		if it.item >= 0 {
			it.cs = l.inline_items[it.item].cs
		} else if it.box >= 0 {
			it.cs = l.boxes[it.box].cs
		}
	}
}

// Replaces the items of context `p` (range info[p].items) by `fresh`. Returns false when the spatial index must be
// built again (counts or bands differ).
@(private)
replace_items :: proc(l: ^Layout, p: i32, fresh: []Display_Item) -> (bands_kept: bool) {
	r := l.inc.info[p].items
	old_n := int(r[1] - r[0])
	if old_n == len(fresh) {
		bands_kept = true
		for i in 0 ..< old_n {
			o := &l.items[int(r[0]) + i]
			if o.space != fresh[i].space || band_span(l, o.space, o.rect) != band_span(l, fresh[i].space, fresh[i].rect) { bands_kept = false }
			o^ = fresh[i]
		}
		return
	}
	delta := i32(len(fresh)) - i32(old_n)
	if delta > 0 {
		resize(&l.items, len(l.items) + int(delta))
		copy(l.items[int(r[1] + delta):], l.items[int(r[1]):len(l.items) - int(delta)])
	} else {
		copy(l.items[int(r[1] + delta):], l.items[int(r[1]):])
		resize(&l.items, len(l.items) + int(delta))
	}
	copy(l.items[int(r[0]):], fresh)
	// later ranges move
	for &inf in l.inc.info {
		if inf.items_gen == l.inc.dl_gen && inf.items[0] >= r[1] { inf.items += delta }
	}
	l.inc.info[p].items = {r[0], r[0] + i32(len(fresh))}
	for &ci in l.canvas_items { if ci >= r[1] { ci += delta } }
	return false
}

// The decorated text items of a replaced range (deco_items is in item order): those of the old range go, later ones
// move with the items, those of the new range come.
@(private)
splice_deco_items :: proc(l: ^Layout, r_old: [2]i32, r_new: [2]i32) {
	delta := (r_new[1] - r_new[0]) - (r_old[1] - r_old[0])
	lo := 0
	for lo < len(l.deco_items) && l.deco_items[lo] < r_old[0] { lo += 1 }
	hi := lo
	for hi < len(l.deco_items) && l.deco_items[hi] < r_old[1] { hi += 1 }
	for &di in l.deco_items[hi:] { di += delta }
	remove_range(&l.deco_items, lo, hi)
	at := lo
	for i in r_new[0] ..< r_new[1] {
		it := &l.items[i]
		if it.kind == .Text && it.deco != {} && it.deco_box > 0 { inject_at(&l.deco_items, at, i); at += 1 }
	}
}

@(private)
band_span :: proc(l: ^Layout, s: i32, r: Rect) -> [2]int {
	sp := &l.spaces[s]
	if sp.band_count == 0 { return {-1, -1} }
	b0 := clamp(int((r.min.y - sp.band0) / sp.band_h), 0, int(sp.band_count) - 1)
	b1 := clamp(int((r.max.y - sp.band0) / sp.band_h), b0, int(sp.band_count) - 1)
	return {b0, b1}
}

// Splices what it can. false: nothing was changed in the display list; the caller finishes and builds it as usual.
@(private)
try_splice :: proc(c: ^Ctx, roots: []i32, cand: map[i32]Splice_Root, input: Input) -> bool {
	l := c.l
	pass := c.inc
	if !pass.snapping { return false }
	for r in roots {
		if r not_in cand || !inline_only(l, c.st, r) { return false }
	}
	// nothing outside the contexts moved
	inside := make(map[i32]bool, 16, context.temp_allocator)
	for r in roots { inside[r] = true }
	in_root :: proc(l: ^Layout, x: i32, inside: map[i32]bool) -> bool {
		for p := l.boxes[x].parent; p != NONE; p = l.boxes[p].parent { if inside[p] { return true } }
		return false
	}
	for &s in pass.snap {
		b := &l.boxes[s.box]
		if .Dead in b.flags || in_root(l, s.box, inside) { continue }
		if b.pos != s.pos || b.size != s.size { return false }
		if b.marker_pos != s.marker && !inside[s.box] { return false }
	}
	// coordinates of the new inline boxes, then the overflow test
	for r in roots { finish_inline(l, r) }
	for r in roots {
		after, has := lines_extent(l, r)
		sr := cand[r]
		if !overflow_kept(l, r, sr.before, sr.any, after, has) { return false }
	}
	// from here on the display list changes
	bands_kept := true
	outlines := make([dynamic]i32, 0, 0, context.temp_allocator)
	scrollers := make([dynamic]i32, 0, 0, context.temp_allocator)
	p := Paint_Ctx{c = c, outlines = &outlines, scrollers = &scrollers}
	fresh := make([dynamic]Display_Item, 0, 32, context.temp_allocator)
	for r in roots {
		// generate at the end of the list, move aside, then replace the old range
		start := len(l.items)
		gen := l.inc.dl_gen
		saved := l.inc.info[r]
		emit_own_lines(&p, r)
		l.inc.info[r] = saved
		l.inc.info[r].items_gen = gen
		clear(&fresh)
		append(&fresh, ..l.items[start:])
		resize(&l.items, start)
		r_old := l.inc.info[r].items
		if !replace_items(l, r, fresh[:]) { bands_kept = false }
		splice_deco_items(l, r_old, l.inc.info[r].items)
	}
	remap_display_items(l)
	// the loose-style flag of the refresh path
	for r in roots {
		b := &l.boxes[r]
		for i in b.items[0] ..< b.items[1] {
			it := &l.inline_items[i]
			if it.node != base.NIL_HANDLE && box_index(l, it.node) == NONE { l.loose_styles = true }
		}
	}
	if !bands_kept { build_bands(l, max(input.band_h, 16) * input.scale) }
	if !refresh_paint_values(l, input) {
		// a transform moved and some container starts or stops scrolling: finish everything after all
		finish(c)
		build_display_list(c)
		note_refresh_inputs(l)
		build_bands(l, max(input.band_h, 16) * input.scale)
	}
	return true
}
