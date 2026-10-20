package layout

import "core:fmt"
import "core:math"
import "core:strings"
import "wb:base"
import "wb:style"

// Comparison of two layouts of the same document and styles: what an incremental pass made against what a full pass
// makes (layout.incremental.verify, and the tests). Box indices may differ (a partial rebuild appends its boxes), so
// boxes are matched by their place in the tree (preorder) and every box reference is compared through that matching.
// Everything that reaches the painter or the queries is compared, exactly: box geometry and flags, lines, fragments,
// inline items, the display list, spaces, clips, opacity groups, the spatial index and the document extent.

@(private = "file")
Cmp :: struct {
	a, b:   ^Layout,
	ma, mb: []i32,      // box -> preorder position (-1: not in the tree)
	sb:     strings.Builder,
	bad:    bool,
}

@(private = "file")
fail :: proc(m: ^Cmp, format: string, args: ..any) {
	if m.bad { return }
	m.bad = true
	fmt.sbprintf(&m.sb, format, ..args)
}

@(private = "file")
feq :: #force_inline proc(x, y: f32) -> bool { return x == y || (math.is_nan(x) && math.is_nan(y)) }

@(private = "file")
veq :: proc(x, y: [$N]f32) -> bool {
	for i in 0 ..< N { if !feq(x[i], y[i]) { return false } }
	return true
}

@(private = "file")
req :: proc(x, y: Rect) -> bool { return veq(x.min, y.min) && veq(x.max, y.max) }

// Same box (through the matching), or both NONE.
@(private = "file")
beq :: proc(m: ^Cmp, x, y: i32) -> bool {
	if x < 0 || y < 0 { return x == y || (x < 0 && y < 0) }
	if int(x) >= len(m.ma) || int(y) >= len(m.mb) { return false }
	return m.ma[x] == m.mb[y] && m.ma[x] >= 0
}

@(private = "file")
font_eq :: proc(m: ^Cmp, x, y: i32) -> bool {
	if x < 0 || y < 0 { return x == y }
	fa, fb := m.a.fonts[x], m.b.fonts[y]
	return fa.font == fb.font && feq(fa.size, fb.size) && feq(fa.ascent, fb.ascent) && feq(fa.descent, fb.descent) &&
		feq(fa.x_height, fb.x_height) && feq(fa.line_h, fb.line_h) && feq(fa.space, fb.space)
}

@(private = "file")
order_map :: proc(l: ^Layout) -> ([]i32, []i32) {
	order := preorder(l)
	m := make([]i32, len(l.boxes), context.temp_allocator)
	for &x in m { x = -1 }
	for x, k in order { m[x] = i32(k) }
	return order, m
}

// ok = false: `report` says at the first difference is (allocated with `allocator`).
compare_layouts :: proc(a, b: ^Layout, allocator := context.temp_allocator) -> (ok: bool, report: string) {
	m := Cmp{a = a, b = b, sb = strings.builder_make(context.temp_allocator)}
	oa, ma := order_map(a)
	ob, mb := order_map(b)
	m.ma, m.mb = ma, mb
	if len(oa) != len(ob) {
		fail(&m, "box count %d / %d", len(oa), len(ob))
	}
	IGNORED :: Box_Flags{.Dead, .Bfc_Floats, .Neg_Margins}   // the last two may stay set after what made them went
	for k in 0 ..< min(len(oa), len(ob)) {
		if m.bad { break }
		x, y := &a.boxes[oa[k]], &b.boxes[ob[k]]
		at := fmt.tprintf("box #%d (node %v, %v)", k, x.node, x.kind)
		switch {
		case x.node != y.node || x.kind != y.kind: fail(&m, "%s: node / kind %v %v / %v %v", at, x.node, x.kind, y.node, y.kind)
		case x.flags - IGNORED != y.flags - IGNORED: fail(&m, "%s: flags %v / %v", at, x.flags - IGNORED, y.flags - IGNORED)
		case !beq(&m, x.parent, y.parent) || !beq(&m, x.pos_ref, y.pos_ref) || !beq(&m, x.cb, y.cb) || !beq(&m, x.static_ref, y.static_ref) || !beq(&m, x.ifc_root, y.ifc_root):
			fail(&m, "%s: references", at)
		case !veq(x.pos, y.pos) || !veq(x.size, y.size): fail(&m, "%s: pos %v size %v / pos %v size %v", at, x.pos, x.size, y.pos, y.size)
		case !veq(x.abs, y.abs) || !veq(x.rel, y.rel): fail(&m, "%s: abs %v / %v", at, x.abs, y.abs)
		case !veq(x.margin, y.margin) || !veq(x.border, y.border) || !veq(x.padding, y.padding):
			fail(&m, "%s: margin %v / %v, padding %v / %v", at, x.margin, y.margin, x.padding, y.padding)
		case !feq(x.baseline, y.baseline) || !feq(x.last_baseline, y.last_baseline) || !feq(x.pre_h, y.pre_h):
			fail(&m, "%s: baselines %v %v / %v %v", at, x.baseline, x.last_baseline, y.baseline, y.last_baseline)
		case x.marker != y.marker || !veq(x.marker_pos, y.marker_pos) || !feq(x.marker_w, y.marker_w): fail(&m, "%s: marker", at)
		case .Abs in x.flags && !veq(x.static_pos, y.static_pos): fail(&m, "%s: static position %v / %v", at, x.static_pos, y.static_pos)
		case x.space != y.space || x.clip != y.clip || x.content_space != y.content_space || x.content_clip != y.content_clip ||
		     x.group != y.group || x.scroll_space != y.scroll_space || !beq(&m, x.layer, y.layer) || !beq(&m, x.clip_owner, y.clip_owner):
			fail(&m, "%s: spaces / clips / group", at)
		case .Scroll in x.flags && !req(x.overflow, y.overflow): fail(&m, "%s: overflow %v / %v", at, x.overflow, y.overflow)
		case x.col != y.col || x.row != y.row || x.colspan != y.colspan || x.rowspan != y.rowspan: fail(&m, "%s: table slot", at)
		case !font_eq(&m, x.fi, y.fi): fail(&m, "%s: font", at)
		// an element's box points at its element's record; anonymous boxes at equal copies
		case (x.node == base.NIL_HANDLE || .Root in x.flags) ? !style.computed_equal(x.cs, y.cs) : x.cs != y.cs: fail(&m, "%s: style record", at)
		case x.lines[1] - x.lines[0] != y.lines[1] - y.lines[0]: fail(&m, "%s: %d / %d lines", at, x.lines[1] - x.lines[0], y.lines[1] - y.lines[0])
		case x.items[1] - x.items[0] != y.items[1] - y.items[0]: fail(&m, "%s: %d / %d inline items", at, x.items[1] - x.items[0], y.items[1] - y.items[0])
		}
		if m.bad { break }
		for i in 0 ..< x.items[1] - x.items[0] {
			p, q := &a.inline_items[x.items[0] + i], &b.inline_items[y.items[0] + i]
			what := ""
			switch {
			case p.kind != q.kind || p.text != q.text: what = "kind / text"
			case p.node != q.node || p.src != q.src: what = "node / source"
			case p.cs != q.cs: what = "style record"
			case !beq(&m, p.box, q.box): what = "box"
			case p.deco != q.deco || !beq(&m, p.deco_box, q.deco_box): what = "decorations"
			case p.kind == .Text && !font_eq(&m, p.fi, q.fi): what = "font"
			}
			if what != "" {
				fail(&m, "%s: inline item %d (%v %q / %v %q): %s", at, i, p.kind, p.text, q.kind, q.text, what)
				break
			}
		}
		for i in 0 ..< x.lines[1] - x.lines[0] {
			if m.bad { break }
			p, q := a.lines[x.lines[0] + i], b.lines[y.lines[0] + i]
			if !feq(p.y, q.y) || !feq(p.h, q.h) || !feq(p.baseline, q.baseline) || !feq(p.left, q.left) || !feq(p.width, q.width) ||
			   p.frags[1] - p.frags[0] != q.frags[1] - q.frags[0] {
				fail(&m, "%s: line %d: y %v h %v baseline %v left %v width %v (%d frags) / y %v h %v baseline %v left %v width %v (%d frags)", at, i,
					p.y, p.h, p.baseline, p.left, p.width, p.frags[1] - p.frags[0], q.y, q.h, q.baseline, q.left, q.width, q.frags[1] - q.frags[0])
				break
			}
			for j in 0 ..< p.frags[1] - p.frags[0] {
				f, g := a.frags[p.frags[0] + j], b.frags[q.frags[0] + j]
				same_item := (f.item < 0 && g.item < 0) || (f.item >= 0 && g.item >= 0 && f.item - x.items[0] == g.item - y.items[0])
				if f.kind != g.kind || f.flags != g.flags || !beq(&m, f.box, g.box) || !same_item || !feq(f.x, g.x) || !feq(f.y, g.y) ||
				   !feq(f.w, g.w) || !feq(f.h, g.h) || !feq(f.baseline, g.baseline) || f.text != g.text || !feq(f.extra, g.extra) || !font_eq(&m, f.fi, g.fi) {
					fail(&m, "%s: line %d fragment %d: %v %q at (%v, %v) w %v / %v %q at (%v, %v) w %v", at, i, j, f.kind, f.text, f.x, f.y, f.w, g.kind, g.text, g.x, g.y, g.w)
					break
				}
			}
		}
	}
	if !m.bad {
		switch {
		case !feq(a.height, b.height) || !feq(a.doc_width, b.doc_width) || a.doc_scroll_y != b.doc_scroll_y:
			fail(&m, "document extent %v x %v / %v x %v", a.doc_width, a.height, b.doc_width, b.height)
		case len(a.spaces) != len(b.spaces) || len(a.clips) != len(b.clips) || len(a.groups) != len(b.groups):
			fail(&m, "spaces / clips / groups: %d %d %d / %d %d %d", len(a.spaces), len(a.clips), len(a.groups), len(b.spaces), len(b.clips), len(b.groups))
		case len(a.items) != len(b.items): fail(&m, "display list: %d / %d items", len(a.items), len(b.items))
		}
	}
	for i in 0 ..< len(a.spaces) {
		if m.bad { break }
		p, q := a.spaces[i], b.spaces[i]
		if p.kind != q.kind || p.parent != q.parent || !beq(&m, p.box, q.box) || p.frame != q.frame || p.clip != q.clip || p.xform != q.xform ||
		   !req(p.port, q.port) || !req(p.limit, q.limit) || !veq(p.max_scroll, q.max_scroll) || !veq(p.inset, q.inset) || p.mat != q.mat ||
		   !feq(p.band0, q.band0) || !feq(p.band_h, q.band_h) || p.band_first != q.band_first || p.band_count != q.band_count {
			fail(&m, "space %d (%v)", i, p.kind)
		}
	}
	for i in 0 ..< len(a.clips) {
		if m.bad { break }
		p, q := a.clips[i], b.clips[i]
		if p.parent != q.parent || p.space != q.space || !beq(&m, p.box, q.box) || !req(p.rect, q.rect) || p.radii != q.radii { fail(&m, "clip %d", i) }
	}
	for i in 0 ..< len(a.groups) {
		if m.bad { break }
		p, q := a.groups[i], b.groups[i]
		if p.parent != q.parent || !beq(&m, p.box, q.box) || !feq(p.alpha, q.alpha) { fail(&m, "group %d", i) }
	}
	for i in 0 ..< len(a.items) {
		if m.bad { break }
		p, q := &a.items[i], &b.items[i]
		// the styles of anonymous boxes are records of each pass: compared through their box
		cs_same := p.cs == q.cs || (p.item < 0 && p.box >= 0 && a.boxes[p.box].node == base.NIL_HANDLE)
		if p.kind != q.kind || p.flags != q.flags || p.space != q.space || p.clip != q.clip || p.group != q.group || !beq(&m, p.box, q.box) ||
		   p.node != q.node || !req(p.rect, q.rect) || p.text != q.text || !font_eq(&m, p.fi, q.fi) || !feq(p.baseline, q.baseline) ||
		   !feq(p.extra, q.extra) || !req(p.thumb, q.thumb) || p.deco != q.deco || p.deco_color != q.deco_color || !beq(&m, p.deco_box, q.deco_box) || !cs_same {
			fail(&m, "display item %d: %v %q %v / %v %q %v", i, p.kind, p.text, p.rect, q.kind, q.text, q.rect)
		}
	}
	if !m.bad {
		switch {
		case len(a.band_start) != len(b.band_start) || len(a.band_items) != len(b.band_items): fail(&m, "spatial index size")
		case a.canvas_items != b.canvas_items: fail(&m, "canvas items %v / %v", a.canvas_items, b.canvas_items)
		case len(a.deco_items) != len(b.deco_items): fail(&m, "decorated items %d / %d", len(a.deco_items), len(b.deco_items))
		}
	}
	if !m.bad {
		for i in 0 ..< len(a.band_start) { if a.band_start[i] != b.band_start[i] { fail(&m, "band %d", i); break } }
		for i in 0 ..< len(a.band_items) { if a.band_items[i] != b.band_items[i] { fail(&m, "band item %d", i); break } }
		for i in 0 ..< len(a.deco_items) { if a.deco_items[i] != b.deco_items[i] { fail(&m, "decorated item %d", i); break } }
	}
	if !m.bad { return true, "" }
	return false, strings.clone(strings.to_string(m.sb), allocator)
}

// A full pass of the same input on the side, compared with this layout (layout.incremental.verify).
@(private)
verify_against_full :: proc(l: ^Layout, input: Input) {
	ref: Layout
	defer destroy(&ref)
	ref.scroll = make(map[base.Handle]Vec2)
	for k, v in l.scroll { ref.scroll[k] = v }
	run_full(&ref, input)
	ok, report := compare_layouts(l, &ref, context.allocator)
	if ok { return }
	l.inc.verify_failures += 1
	delete(l.inc.verify_report)
	l.inc.verify_report = report
}
