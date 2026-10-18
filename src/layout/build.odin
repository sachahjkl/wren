package layout

import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:style"

// Box tree construction (CSS 2.1 §9.2, CSS Tables §3.9 fix-up, CSS Display). One iterative walk of the DOM in document
// order: a hostile document as deep as the DOM allows costs heap, never native stack. Boxes nested deeper than
// `layout.max_depth` are flattened (their elements act like display: contents), so every later recursive step is bounded.
//
// Inline content is not a tree of boxes for layout purposes: each inline formatting context gets a flat list of items
// (text, inline box open/close, atomic inlines, floats, absolutely positioned boxes, forced breaks), which line layout and
// intrinsic sizing walk without recursion. Inline boxes still exist as boxes (for painting, hit testing, positioning).

@(private)
Mode :: enum u8 { Block, Inline, Flex, Table, Row_Group, Row, None }

@(private)
Frame_Kind :: enum u8 { Visit, Pseudo, Close }

@(private)
Frame :: struct {
	kind:   Frame_Kind,
	node:   base.Handle,
	pcs:    ^style.Computed,   // Pseudo: the generated box's style
	parent: i32,               // box children attach to
	ifc:    i32,               // Inline mode: the inline formatting context root
	mode:   Mode,
	cb:     i32,               // containing block of absolutely positioned descendants
	fcb:    i32,               // containing block of fixed descendants: the root, or the nearest transformed ancestor
	depth:  i32,
	deco:   style.Decorations, // text decorations propagated from ancestors
	deco_color: css.Color,
	deco_box: i32,             // the box whose text-decoration-color that is (NONE: none)
}

@(private)
Level :: enum u8 { Block, Inline, Atomic, Table_Internal, Column, Out_Of_Flow }

@(private)
level_of :: proc(d: style.Display) -> Level {
	switch d {
	case .Block, .Flow_Root, .List_Item, .Flex, .Grid, .Table: return .Block
	case .Inline: return .Inline
	case .Inline_Block, .Inline_Flex, .Inline_Grid, .Inline_Table: return .Atomic
	case .Table_Row_Group, .Table_Header_Group, .Table_Footer_Group, .Table_Row, .Table_Cell, .Table_Caption: return .Table_Internal
	case .Table_Column, .Table_Column_Group: return .Column
	case .Contents, .None: return .Inline
	}
	return .Inline
}

@(private)
is_replaced_element :: proc(n: ^dom.Node) -> bool {
	switch len(n.name) {
	case 3: return n.name == "img"
	case 5: return n.name == "input" || n.name == "embed" || n.name == "video" || n.name == "audio" || n.name == "meter"
	case 6: return n.name == "select" || n.name == "iframe" || n.name == "canvas" || n.name == "object"
	case 8: return n.name == "textarea" || n.name == "progress"
	}
	return false
}

@(private)
is_control_element :: proc(n: ^dom.Node) -> bool {
	switch len(n.name) {
	case 5: return n.name == "input"
	case 6: return n.name == "select" || n.name == "button"
	case 8: return n.name == "textarea"
	}
	return false
}

@(private)
collapsible_ws_only :: proc(text: string, ws: style.White_Space) -> bool {
	if ws == .Pre || ws == .Pre_Wrap || ws == .Break_Spaces { return text == "" }
	for i in 0 ..< len(text) {
		b := text[i]
		if b == '\n' && ws == .Pre_Line { return false }
		if b != ' ' && b != '\t' && b != '\n' && b != '\r' && b != '\f' { return false }
	}
	return true
}

@(private)
new_box :: proc(c: ^Ctx, kind: Box_Kind, cs: ^style.Computed, node: base.Handle, parent: i32, depth: i32) -> i32 {
	idx := i32(len(c.l.boxes))
	append(&c.l.boxes, Box{
		node = node, cs = cs, kind = kind, parent = parent, first = NONE, last = NONE, next = NONE, pos_ref = parent,
		cb = NONE, abs_first = NONE, abs_last = NONE, abs_next = NONE, static_ref = NONE, ifc_root = NONE,
		cur_anon = NONE, fi = -1, baseline = -1, last_baseline = -1, clip_owner = NONE, space = 0, clip = NONE,
		content_space = 0, content_clip = NONE, group = NONE, scroll_space = NONE, depth = depth,
		colspan = 1, rowspan = 1, layer = NONE,
	})
	append(&c.l.inc.info, Box_Info{cb = NONE, fcb = NONE, deco_box = NONE})
	if parent != NONE {
		p := &c.l.boxes[parent]
		if p.last == NONE { p.first = idx } else { c.l.boxes[p.last].next = idx }
		p.last = idx
	}
	return idx
}

@(private)
add_item :: proc(c: ^Ctx, it: Inline_Item) { append(&c.l.inline_items, it) }

// Applies the per-element flags that do not depend on where the box sits.
@(private)
box_flags_from_style :: proc(c: ^Ctx, bi: i32, cb, fcb: i32) {
	b := &c.l.boxes[bi]
	cs := b.cs
	switch cs.position {
	case .Static:
	case .Relative: b.flags += {.Positioned, .Relative}
	case .Sticky: b.flags += {.Positioned, .Sticky, .Stacking}
	case .Absolute: b.flags += {.Positioned, .Abs, .Bfc}
	case .Fixed:
		b.flags += {.Positioned, .Abs, .Bfc, .Stacking}
		// under a transformed ancestor a fixed box is positioned in it and moves with it (CSS Transforms 1 §3)
		if fcb == 0 { b.flags += {.Fixed} }
	}
	if .Positioned in b.flags && !cs.z_auto { b.flags += {.Stacking} }
	if cs.opacity < 1 || stacking_effect(cs) { b.flags += {.Stacking} }
	if b.kind != .Inline && style.has_transform(cs) { b.flags += {.Transformed, .Stacking} }
	if cs.float != .None && .Abs not_in b.flags { b.flags += {.Float, .Bfc} }
	if cs.visibility != .Visible { b.flags += {.Hidden} }
	if !cs.pointer_events { b.flags += {.No_Pointer} }
	if cs.overflow_x != .Visible || cs.overflow_y != .Visible {
		b.flags += {.Clips, .Bfc}
		if cs.overflow_x == .Scroll || cs.overflow_x == .Auto || cs.overflow_y == .Scroll || cs.overflow_y == .Auto { b.flags += {.Scroll} }
	}
	if cs.display == .Flow_Root || cs.display == .Inline_Block { b.flags += {.Bfc} }
	if .Abs in b.flags {
		cbi := cs.position == .Fixed ? fcb : cb
		b.cb = cbi
		b.pos_ref = cbi
		cbb := &c.l.boxes[cbi]
		if cbb.abs_last == NONE { cbb.abs_first = bi } else { c.l.boxes[cbb.abs_last].abs_next = bi }
		cbb.abs_last = bi
	}
}

// True when a block container's in-flow children include a block-level box (then inline runs get anonymous blocks).
@(private)
has_block_child :: proc(c: ^Ctx, h: base.Handle, cs: ^style.Computed, depth: i32) -> bool {
	if int(depth) + 1 >= c.set.max_depth { return false }
	if cs.before != nil && level_of(cs.before.display) == .Block { return true }
	if cs.after != nil && level_of(cs.after.display) == .Block { return true }
	// direct children without allocating; display: contents children are expanded with a stack
	stack: [dynamic]base.Handle
	n := dom.get(c.d, h)
	ch := n.first_child
	for {
		if ch == base.NIL_HANDLE {
			if len(stack) == 0 { return false }
			ch = pop(&stack)
		}
		xn := dom.get(c.d, ch)
		if xn == nil { ch = base.NIL_HANDLE; continue }
		next := xn.next
		if xn.kind == .Element {
			if xs := style.style_of(c.st, ch); xs != nil && xs.display != .None {
				if xs.display == .Contents {
					if stack == nil { stack = make([dynamic]base.Handle, 0, 8, context.temp_allocator) }
					if next != base.NIL_HANDLE { append(&stack, next) }
					next = xn.first_child
				} else if xs.position != .Absolute && xs.position != .Fixed && xs.float == .None {
					lv := level_of(xs.display)
					if lv == .Block || lv == .Table_Internal { return true }
				}
			}
		}
		ch = next
	}
}

// Pushes the children of `h` (and its generated ::before / ::after) to be visited with the given context.
@(private)
push_children :: proc(c: ^Ctx, stack: ^[dynamic]Frame, h: base.Handle, cs: ^style.Computed, f: Frame) {
	n := dom.get(c.d, h)
	if cs != nil && cs.after != nil {
		g := f
		g.kind, g.node, g.pcs = .Pseudo, h, cs.after
		append(stack, g)
	}
	for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(c.d, ch).prev {
		g := f
		g.kind, g.node = .Visit, ch
		append(stack, g)
	}
	if cs != nil && cs.before != nil {
		g := f
		g.kind, g.node, g.pcs = .Pseudo, h, cs.before
		append(stack, g)
	}
}

// The frame for the content of a new container box.
@(private)
child_frame :: proc(c: ^Ctx, bi: i32, f: Frame, has_block: bool) -> Frame {
	b := &c.l.boxes[bi]
	g := f
	g.parent = bi
	g.depth = b.depth
	if .Positioned in b.flags { g.cb = bi }
	if b.kind != .Inline && contains_fixed(b.cs) { g.cb, g.fcb = bi, bi }
	if .Atomic in b.flags || .Float in b.flags || .Abs in b.flags || b.kind == .Flex || b.kind == .Table {
		g.deco = {}   // decorations do not propagate into atomic inlines, floats and absolutely positioned boxes
	}
	g.deco += b.cs.text_decoration
	if b.cs.text_decoration != {} { g.deco_color, g.deco_box = b.cs.text_decoration_color, bi }
	switch b.kind {
	case .Inline: g.mode = .Inline
	case .Block, .Cell, .Caption:
		if has_block { g.mode = .Block } else { g.mode = .Inline; g.ifc = bi; b.flags += {.Ifc} }
	case .Flex: g.mode = .Flex
	case .Table: g.mode = .Table
	case .Row_Group: g.mode = .Row_Group
	case .Row: g.mode = .Row
	case .Replaced: g.mode = .None
	}
	return g
}

@(private)
kind_for :: proc(d: style.Display) -> Box_Kind {
	#partial switch d {
	case .Flex, .Inline_Flex: return .Flex
	case .Table, .Inline_Table: return .Table
	case .Table_Row_Group, .Table_Header_Group, .Table_Footer_Group: return .Row_Group
	case .Table_Row: return .Row
	case .Table_Cell: return .Cell
	case .Table_Caption: return .Caption
	case .Inline, .Contents: return .Inline
	}
	return .Block
}

build_tree :: proc(c: ^Ctx) {
	d := c.d
	root_cs := anon_style(c, c.st.initial, .Block)
	root := new_box(c, .Block, root_cs, d.root, NONE, 0)
	c.l.boxes[root].flags += {.Root, .Bfc, .Stacking, .Positioned}
	c.l.boxes[root].pos_ref = NONE

	// the root element or body passes its overflow to the viewport (CSS Overflow §3.3)
	c.root_el, c.body_el = canvas_elements(d)
	c.l.doc_scroll_y = true

	stack := make([dynamic]Frame, 0, 256, context.temp_allocator)
	top := Frame{kind = .Visit, parent = root, mode = .Block, cb = root, fcb = root, depth = 0, ifc = NONE, deco_box = NONE}
	{
		g := top
		rn := dom.get(d, d.root)
		for ch := rn.last_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).prev { g.node = ch; append(&stack, g) }
	}
	build_loop(c, &stack)
	propagate_overflow(c)
	group_items(c)
}

@(private)
build_loop :: proc(c: ^Ctx, stack: ^[dynamic]Frame) {
	for len(stack) > 0 {
		f := pop(stack)
		switch f.kind {
		case .Close: add_item(c, Inline_Item{kind = .Close, box = f.parent, ifc = f.ifc})
		case .Pseudo: visit_pseudo(c, stack, f)
		case .Visit: visit(c, stack, f)
		}
	}
}

// The root element and the body (their backgrounds may be the canvas, their overflow the viewport's).
@(private)
canvas_elements :: proc(d: ^dom.Document) -> (root_el, body_el: base.Handle) {
	for ch := dom.get(d, d.root).first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		if dom.get(d, ch).kind == .Element { root_el = ch; break }
	}
	if root_el != base.NIL_HANDLE {
		for ch := dom.get(d, root_el).first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
			if n := dom.get(d, ch); n.kind == .Element && n.name == "body" { body_el = ch; break }
		}
	}
	return
}

@(private)
propagate_overflow :: proc(c: ^Ctx) {
	pick := base.NIL_HANDLE
	if rc := style.style_of(c.st, c.root_el); rc != nil && (rc.overflow_x != .Visible || rc.overflow_y != .Visible) {
		pick = c.root_el
	} else if bc := style.style_of(c.st, c.body_el); bc != nil && (bc.overflow_x != .Visible || bc.overflow_y != .Visible) {
		pick = c.body_el
	}
	if pick == base.NIL_HANDLE { return }
	cs := style.style_of(c.st, pick)
	c.l.doc_scroll_y = cs.overflow_y != .Hidden && cs.overflow_y != .Clip
	if bi := box_index(c.l, pick); bi != NONE {
		b := &c.l.boxes[bi]
		b.flags -= {.Clips, .Scroll}
		b.flags += {.Propagated}
		if cs.display != .Flow_Root && cs.display != .Inline_Block && .Float not_in b.flags && .Abs not_in b.flags { b.flags -= {.Bfc} }
	}
}

// Items are appended in document order, which interleaves the items of nested contexts (an inline-block inside a
// paragraph): a counting sort by context makes each context's items one contiguous range, order preserved.
// `start`: only the items from there on (those of a partial rebuild, appended at the end) are grouped.
@(private)
group_items :: proc(c: ^Ctx, start := 0) {
	items := c.l.inline_items[start:]
	n := len(items)
	if n == 0 { return }
	nb := len(c.l.boxes)
	count := make([]i32, nb + 1, context.temp_allocator)
	for &it in items { count[it.ifc + 1] += 1 }
	for i in 1 ..= nb { count[i] += count[i - 1] }
	base := i32(start)
	for bi in 0 ..< nb {
		if count[bi + 1] > count[bi] {
			c.l.boxes[bi].items = {base + count[bi], base + count[bi + 1]}
		}
	}
	sorted := make([]Inline_Item, n, context.temp_allocator)
	fill := make([]i32, nb, context.temp_allocator)
	for &it in items {
		sorted[count[it.ifc] + fill[it.ifc]] = it
		fill[it.ifc] += 1
	}
	copy(items, sorted)
}

@(private)
text_owner_cs :: proc(c: ^Ctx, h: base.Handle) -> (^style.Computed, base.Handle) {
	n := dom.get(c.d, h)
	for p := n.parent; p != base.NIL_HANDLE; p = dom.get(c.d, p).parent {
		if cs := style.style_of(c.st, p); cs != nil { return cs, p }
	}
	return c.st.initial, base.NIL_HANDLE
}

// The current anonymous block of a block container's inline run, created on first use.
@(private)
anon_block :: proc(c: ^Ctx, f: Frame) -> i32 {
	p := &c.l.boxes[f.parent]
	if p.cur_anon != NONE && c.l.boxes[p.cur_anon].kind == .Block { return p.cur_anon }
	cs := anon_style(c, p.cs, .Block)
	a := new_box(c, .Block, cs, base.NIL_HANDLE, f.parent, c.l.boxes[f.parent].depth + 1)
	c.l.boxes[a].flags += {.Anonymous, .Ifc}
	c.l.boxes[f.parent].cur_anon = a
	return a
}

@(private)
inline_frame :: proc(f: Frame, ifc: i32) -> Frame {
	g := f
	g.mode, g.parent, g.ifc = .Inline, ifc, ifc
	return g
}

// Anonymous table boxes around table-internal boxes in the wrong place (CSS Tables §3.9.1).
@(private)
anon_table_chain :: proc(c: ^Ctx, f: Frame, want: style.Display) -> Frame {
	g := f
	switch f.mode {
	case .Block, .Inline, .Flex, .None:
		p := &c.l.boxes[f.parent]
		t := p.cur_anon
		if t == NONE || c.l.boxes[t].kind != .Table {
			inline := f.mode == .Inline
			cs := anon_style(c, p.cs, inline ? .Inline_Table : .Table)
			cs.border_spacing = p.cs.border_spacing
			t = new_box(c, .Table, cs, base.NIL_HANDLE, f.parent, p.depth + 1)
			c.l.boxes[t].flags += {.Anonymous, .Bfc}
			if inline {
				c.l.boxes[t].flags += {.Atomic}
				c.l.boxes[t].ifc_root = f.ifc
				c.l.boxes[t].pos_ref = f.ifc
				add_item(c, Inline_Item{kind = .Atomic, box = t, ifc = f.ifc})
			}
			c.l.boxes[f.parent].cur_anon = t
		}
		g.parent, g.mode = t, .Table
		g.depth = c.l.boxes[t].depth
		return anon_table_chain(c, g, want)
	case .Table:
		#partial switch want {
		case .Table_Row_Group, .Table_Header_Group, .Table_Footer_Group, .Table_Caption: return g
		}
		p := &c.l.boxes[f.parent]
		rg := p.cur_anon
		if rg == NONE || c.l.boxes[rg].kind != .Row_Group {
			rg = new_box(c, .Row_Group, anon_style(c, p.cs, .Table_Row_Group), base.NIL_HANDLE, f.parent, p.depth + 1)
			c.l.boxes[rg].flags += {.Anonymous}
			c.l.boxes[f.parent].cur_anon = rg
		}
		g.parent, g.mode, g.depth = rg, .Row_Group, c.l.boxes[rg].depth
		return anon_table_chain(c, g, want)
	case .Row_Group:
		if want == .Table_Row { return g }
		p := &c.l.boxes[f.parent]
		r := p.cur_anon
		if r == NONE || c.l.boxes[r].kind != .Row {
			r = new_box(c, .Row, anon_style(c, p.cs, .Table_Row), base.NIL_HANDLE, f.parent, p.depth + 1)
			c.l.boxes[r].flags += {.Anonymous}
			c.l.boxes[f.parent].cur_anon = r
		}
		g.parent, g.mode, g.depth = r, .Row, c.l.boxes[r].depth
		return anon_table_chain(c, g, want)
	case .Row:
		if want == .Table_Cell { return g }
		p := &c.l.boxes[f.parent]
		cell := p.cur_anon
		if cell == NONE || c.l.boxes[cell].kind != .Cell {
			cell = new_box(c, .Cell, anon_style(c, p.cs, .Table_Cell), base.NIL_HANDLE, f.parent, p.depth + 1)
			c.l.boxes[cell].flags += {.Anonymous, .Bfc}
			c.l.boxes[f.parent].cur_anon = cell
		}
		g.parent, g.mode, g.depth = cell, .Block, c.l.boxes[cell].depth
		return g
	}
	return g
}

// A table-internal box ends the current run of anonymous table boxes when something else comes.
@(private)
end_anon_run :: proc(c: ^Ctx, parent: i32) {
	c.l.boxes[parent].cur_anon = NONE
}

@(private)
visit :: proc(c: ^Ctx, stack: ^[dynamic]Frame, f: Frame) {
	n := dom.get(c.d, f.node)
	if n == nil { return }
	switch n.kind {
	case .Document, .Comment: return
	case .Text: visit_text(c, f, n); return
	case .Element:
	}
	cs := style.style_of(c.st, f.node)
	if cs == nil || cs.display == .None { return }
	if cs.visibility == .Collapse && (cs.display == .Table_Row || cs.display == .Table_Row_Group || cs.display == .Table_Column) { return }
	if cs.display == .Contents || int(f.depth) + 1 >= c.set.max_depth {
		if cs.display != .Contents { c.l.boxes[f.parent].flags += {.Flattened} }
		if n.name == "br" && f.mode == .Inline { add_item(c, Inline_Item{kind = .Break, box = NONE, ifc = f.ifc, cs = cs, node = f.node}); return }
		push_children(c, stack, f.node, cs, f)
		return
	}
	if n.name == "br" {
		g := f
		if f.mode == .Block { g = inline_frame(f, anon_block(c, f)) }
		if g.mode == .Inline { add_item(c, Inline_Item{kind = .Break, box = NONE, ifc = g.ifc, cs = cs, node = f.node}) }
		return
	}
	replaced := is_replaced_element(n)
	if n.name == "input" {
		if t, ok := dom.get_attribute(c.d, f.node, "type"); ok && strings.equal_fold(t, "hidden") { return }
	}
	place_element(c, stack, f, f.node, n, cs, replaced, false)
}

@(private)
visit_pseudo :: proc(c: ^Ctx, stack: ^[dynamic]Frame, f: Frame) {
	pcs := f.pcs
	if pcs.display == .None { return }
	n := dom.get(c.d, f.node)
	place_element(c, stack, f, f.node, n, pcs, false, true)
}

// Creates the box of an element (or pseudo-element) according to where it appears, then schedules its content.
@(private)
place_element :: proc(c: ^Ctx, stack: ^[dynamic]Frame, f: Frame, h: base.Handle, n: ^dom.Node, cs: ^style.Computed, replaced, pseudo: bool) {
	out_of_flow := cs.position == .Absolute || cs.position == .Fixed
	floating := cs.float != .None && !out_of_flow
	lv := level_of(cs.display)
	if cs.display == .Contents { lv = .Inline }
	if lv == .Column { return }
	g := f

	// where the box goes
	switch f.mode {
	case .None: return
	case .Flex:
		if !out_of_flow {
			end_anon_run(c, f.parent)
			if lv == .Table_Internal {
				g = anon_table_chain(c, f, cs.display)
			}
			floating = false
		}
	case .Table, .Row_Group, .Row:
		if lv == .Table_Internal {
			if (f.mode == .Table && cs.display == .Table_Row) || (f.mode == .Table && cs.display == .Table_Cell) ||
			   (f.mode == .Row_Group && cs.display == .Table_Cell) {
				g = anon_table_chain(c, f, cs.display)
			} else if f.mode == .Row_Group && cs.display != .Table_Row {
				// a row group or caption inside a row group: content of an anonymous cell (which then wraps it in a table)
				g = anon_table_chain(c, f, .Block)
			} else if f.mode == .Row && cs.display != .Table_Cell {
				g = anon_table_chain(c, f, .Block)
			} else {
				end_anon_run(c, f.parent)
			}
		} else if !out_of_flow || f.mode != .Table {
			g = anon_table_chain(c, f, .Block)
		}
	case .Block:
		if lv == .Table_Internal && !out_of_flow && !floating {
			g = anon_table_chain(c, f, cs.display)
		} else if lv == .Block && !out_of_flow && !floating {
			end_anon_run(c, f.parent)
		} else if lv == .Inline || lv == .Atomic {
			g = inline_frame(f, anon_block(c, f))
		} else {
			// floats and absolutely positioned boxes join an open inline run, else they are block-level children
			p := &c.l.boxes[f.parent]
			if p.cur_anon != NONE && c.l.boxes[p.cur_anon].kind == .Block { g = inline_frame(f, p.cur_anon) }
		}
	case .Inline:
		if lv == .Table_Internal && !out_of_flow && !floating { g = anon_table_chain(c, f, cs.display) }
	}
	// landed in an anonymous cell: the cell's content follows block container rules
	if g.parent != f.parent && g.mode == .Block {
		if lv == .Table_Internal && !out_of_flow && !floating {
			g = anon_table_chain(c, g, cs.display)
		} else if lv == .Inline || lv == .Atomic {
			g = inline_frame(g, anon_block(c, g))
		}
	}

	// what the box is
	kind: Box_Kind
	if replaced {
		kind = .Replaced
	} else if g.mode == .Flex && !out_of_flow {
		kind = kind_for(cs.display)
		if kind == .Inline { kind = .Block }
	} else if out_of_flow || floating {
		kind = kind_for(cs.display)
		if kind == .Inline { kind = .Block }
	} else {
		kind = kind_for(cs.display)
	}
	if kind == .Inline && g.mode != .Inline { kind = .Block }

	bi := new_box(c, kind, cs, h, g.parent, g.depth + (kind == .Inline ? 0 : 1))
	b := &c.l.boxes[bi]
	if pseudo {
		b.flags += {.Pseudo}
		if ecs := style.style_of(c.st, h); ecs != nil && ecs.after == cs { b.flags += {.Pseudo_After} }
	}
	if !pseudo && is_control_element(n) { b.flags += {.Control} }
	box_flags_from_style(c, bi, g.cb, g.fcb)
	b = &c.l.boxes[bi]
	if g.mode == .Flex || g.mode == .Table || g.mode == .Row_Group || g.mode == .Row { b.flags -= {.Float} }
	if !pseudo { register_node(c, h, bi) }
	b.fi = font_info(c, cs)
	b = &c.l.boxes[bi]

	if g.mode == .Inline {
		b.ifc_root = g.ifc
		if .Abs not_in b.flags { b.pos_ref = g.ifc }
		switch {
		case .Abs in b.flags: add_item(c, Inline_Item{kind = .Abs, box = bi, ifc = g.ifc})
		case .Float in b.flags: add_item(c, Inline_Item{kind = .Float, box = bi, ifc = g.ifc})
		case kind == .Inline: add_item(c, Inline_Item{kind = .Open, src = box_src(b), box = bi, ifc = g.ifc, cs = cs, node = h})
		case lv == .Block || lv == .Table_Internal:
			b.flags += {.Block_In_Inline}
			add_item(c, Inline_Item{kind = .Block, box = bi, ifc = g.ifc})
		case:
			b.flags += {.Atomic, .Bfc}
			add_item(c, Inline_Item{kind = .Atomic, box = bi, ifc = g.ifc})
		}
	} else if g.mode == .Flex && .Abs not_in b.flags {
		b.flags += {.Bfc}
		if !cs.z_auto { b.flags += {.Stacking} }
	}
	if kind == .Cell || kind == .Caption || kind == .Flex || kind == .Table { b.flags += {.Bfc} }
	if kind == .Replaced { b.flags += {.Bfc} }
	if kind == .Cell {
		if v, ok := dom.get_attribute(c.d, h, "colspan"); ok { b.colspan = i32(clamp(parse_int(v, 1), 1, 1000)) }
		if v, ok := dom.get_attribute(c.d, h, "rowspan"); ok { b.rowspan = i32(clamp(parse_int(v, 1), 0, 65534)) }
	}
	if cs.display == .List_Item && !pseudo { b.flags += {.List_Item} }

	// content
	if kind == .Replaced { return }
	has_block := false
	if kind == .Block || kind == .Cell || kind == .Caption {
		has_block = pseudo ? false : has_block_child(c, h, cs, b.depth)
		if pseudo && cs.content.kind == .Items { has_block = false }
	}
	note_frame(c, bi, g)
	cf := child_frame(c, bi, g, has_block)
	if .List_Item in c.l.boxes[bi].flags { make_marker(c, bi, h, cf) }
	if kind == .Inline { append(stack, Frame{kind = .Close, parent = bi, ifc = g.ifc}) }
	if pseudo {
		emit_generated(c, h, cs, cf, box_src(&c.l.boxes[bi]))
		return
	}
	push_children(c, stack, h, cs, cf)
}

@(private)
box_src :: proc(b: ^Box) -> Item_Src {
	if .Pseudo not_in b.flags { return .Element }
	return .Pseudo_After in b.flags ? .After : .Before
}

@(private)
register_node :: proc(c: ^Ctx, h: base.Handle, bi: i32) {
	i := int(base.handle_index(h))
	for len(c.l.node_box) <= i { append(&c.l.node_box, NONE) }
	if c.l.node_box[i] == NONE || c.l.boxes[c.l.node_box[i]].node != h { c.l.node_box[i] = bi }
}

@(private)
parse_int :: proc(s: string, fallback: int) -> int {
	t := strings.trim_space(s)
	end := 0
	if end < len(t) && (t[end] == '-' || t[end] == '+') { end += 1 }
	for end < len(t) && t[end] >= '0' && t[end] <= '9' { end += 1 }
	v, ok := strconv.parse_int(t[:end])
	return ok ? v : fallback
}

@(private)
text_transform :: proc(c: ^Ctx, text: string, t: style.Text_Transform, prev_letter: ^bool) -> string {
	if t == .None { return text }
	sb := strings.builder_make(0, len(text), c.sa)
	for r in text {
		out := r
		switch t {
		case .None:
		case .Uppercase: out = unicode.to_upper(r)
		case .Lowercase: out = unicode.to_lower(r)
		case .Capitalize:
			if !prev_letter^ && unicode.is_letter(r) { out = unicode.to_title(r) }
		}
		prev_letter^ = unicode.is_letter(r) || unicode.is_digit(r) || r == '\''
		buf, n := utf8.encode_rune(out)
		strings.write_bytes(&sb, buf[:n])
	}
	return strings.to_string(sb)
}

@(private)
visit_text :: proc(c: ^Ctx, f: Frame, n: ^dom.Node) {
	if len(n.text) == 0 { return }
	cs, owner := text_owner_cs(c, f.node)
	g := f
	switch f.mode {
	case .None: return
	case .Inline:
	case .Block:
		p := &c.l.boxes[f.parent]
		if collapsible_ws_only(n.text, cs.white_space) && (p.cur_anon == NONE || c.l.boxes[p.cur_anon].kind != .Block) { return }
		g = inline_frame(f, anon_block(c, f))
	case .Flex:
		if collapsible_ws_only(n.text, cs.white_space) { return }
		p := &c.l.boxes[f.parent]
		a := p.cur_anon
		if a == NONE || c.l.boxes[a].kind != .Block {
			a = new_box(c, .Block, anon_style(c, p.cs, .Block), base.NIL_HANDLE, f.parent, p.depth + 1)
			c.l.boxes[a].flags += {.Anonymous, .Ifc, .Bfc}
			c.l.boxes[f.parent].cur_anon = a
		}
		g = inline_frame(f, a)
	case .Table, .Row_Group, .Row:
		if collapsible_ws_only(n.text, cs.white_space) { return }
		g = anon_table_chain(c, f, .Block)
		if g.mode == .Block { g = inline_frame(g, anon_block(c, g)) }
	}
	prev := false
	text := text_transform(c, n.text, cs.text_transform, &prev)
	ib := c.l.boxes[g.parent].kind == .Inline ? g.parent : NONE
	src := owner == base.NIL_HANDLE ? Item_Src.Initial : Item_Src.Element
	add_item(c, Inline_Item{kind = .Text, src = src, box = ib, ifc = g.ifc, fi = font_info(c, cs), text = text, cs = cs, node = owner, deco = g.deco, deco_color = g.deco_color, deco_box = g.deco_box})
}

@(private)
emit_generated :: proc(c: ^Ctx, owner: base.Handle, cs: ^style.Computed, f: Frame, src: Item_Src) {
	if cs.content.kind != .Items || f.mode != .Inline { return }
	sb := strings.builder_make(c.sa)
	for it in cs.content.items {
		switch it.kind {
		case .Text: strings.write_string(&sb, it.text)
		case .Attr:
			if v, ok := dom.get_attribute(c.d, owner, it.text); ok { strings.write_string(&sb, v) }
		case .Open_Quote:
			strings.write_string(&sb, c.quote_depth % 2 == 0 ? "\u201c" : "\u2018")
			c.quote_depth += 1
			c.l.inc.quotes = true   // depends on everything before it in the document: no partial rebuilds
		case .Close_Quote:
			c.l.inc.quotes = true
			c.quote_depth = max(c.quote_depth - 1, 0)
			strings.write_string(&sb, c.quote_depth % 2 == 0 ? "\u201d" : "\u2019")
		case .Url:
		}
	}
	text := strings.to_string(sb)
	if text == "" { return }
	prev := false
	text = text_transform(c, text, cs.text_transform, &prev)
	ib := c.l.boxes[f.parent].kind == .Inline ? f.parent : NONE
	add_item(c, Inline_Item{kind = .Text, src = src, box = ib, ifc = f.ifc, fi = font_info(c, cs), text = text, cs = cs, node = owner, deco = f.deco, deco_color = f.deco_color, deco_box = f.deco_box})
}

////////////////////////////////
// List markers (CSS Lists §3, HTML ol/li numbering)

@(private)
make_marker :: proc(c: ^Ctx, bi: i32, h: base.Handle, cf: Frame) {
	b := &c.l.boxes[bi]
	cs := b.cs
	if cs.list_style_type == .None { return }
	ordinal := c.rebuilding == bi ? c.l.inc.info[bi].ordinal : list_ordinal(c, h)
	c.l.inc.info[bi].ordinal = ordinal
	text := marker_string(c, cs.list_style_type, ordinal)
	if cs.list_style_position == .Inside && cf.mode == .Inline {
		s := text
		if s == "" {
			#partial switch cs.list_style_type {
			case .Disc: s = "\u2022 "
			case .Circle: s = "\u25e6 "
			case .Square: s = "\u25aa "
			}
		} else {
			s = strings.concatenate({s, " "}, c.sa)
		}
		add_item(c, Inline_Item{kind = .Text, box = NONE, ifc = cf.ifc, fi = font_info(c, cs), text = s, cs = cs, node = h})
		return
	}
	b = &c.l.boxes[bi]
	b.marker = text
	b.fi = font_info(c, cs)
	b.marker_w = -1   // has a marker (text empty: a bullet shape)
}

@(private)
list_ordinal :: proc(c: ^Ctx, h: base.Handle) -> i32 {
	n := dom.get(c.d, h)
	parent := n.parent
	ctr, ok := c.counters[parent]
	if !ok {
		ctr = {1, 1}
		pn := dom.get(c.d, parent)
		if pn != nil && pn.kind == .Element && pn.name == "ol" {
			_, reversed := dom.get_attribute(c.d, parent, "reversed")
			if reversed {
				ctr.step = -1
				count: i32
				for ch := pn.first_child; ch != base.NIL_HANDLE; ch = dom.get(c.d, ch).next {
					if s := style.style_of(c.st, ch); s != nil && s.display == .List_Item { count += 1 }
				}
				ctr.next = count
			}
			if v, has := dom.get_attribute(c.d, parent, "start"); has { ctr.next = i32(parse_int(v, int(ctr.next))) }
		}
	}
	if v, has := dom.get_attribute(c.d, h, "value"); has { ctr.next = i32(parse_int(v, int(ctr.next))) }
	ord := ctr.next
	ctr.next += ctr.step
	c.counters[parent] = ctr
	return ord
}

// Marker text; bullets (disc, circle, square) are shapes and return "".
@(private)
marker_string :: proc(c: ^Ctx, t: style.List_Style_Type, n: i32) -> string {
	switch t {
	case .None, .Disc, .Circle, .Square: return ""
	case .Decimal: return strings.concatenate({itoa(c, int(n)), "."}, c.sa)
	case .Decimal_Leading_Zero:
		s := itoa(c, abs(int(n)))
		if n >= 0 && n < 10 { return strings.concatenate({"0", s, "."}, c.sa) }
		return strings.concatenate({n < 0 ? "-" : "", s, "."}, c.sa)
	case .Lower_Alpha, .Upper_Alpha: return strings.concatenate({alphabetic(c, int(n), t == .Upper_Alpha ? 'A' : 'a', 26), "."}, c.sa)
	case .Lower_Roman, .Upper_Roman:
		if n < 1 || n > 3999 { return strings.concatenate({itoa(c, int(n)), "."}, c.sa) }
		return strings.concatenate({roman(c, int(n), t == .Upper_Roman), "."}, c.sa)
	case .Lower_Greek:
		if n < 1 { return strings.concatenate({itoa(c, int(n)), "."}, c.sa) }
		GREEK :: [24]rune{'α', 'β', 'γ', 'δ', 'ε', 'ζ', 'η', 'θ', 'ι', 'κ', 'λ', 'μ', 'ν', 'ξ', 'ο', 'π', 'ρ', 'σ', 'τ', 'υ', 'φ', 'χ', 'ψ', 'ω'}
		g := GREEK
		digits: [16]rune
		k := 0
		v := int(n)
		for v > 0 && k < len(digits) { v -= 1; digits[k] = g[v % 24]; k += 1; v /= 24 }
		sb := strings.builder_make(c.sa)
		for i := k - 1; i >= 0; i -= 1 { strings.write_rune(&sb, digits[i]) }
		strings.write_byte(&sb, '.')
		return strings.to_string(sb)
	}
	return ""
}

@(private)
itoa :: proc(c: ^Ctx, n: int) -> string {
	buf: [24]u8
	return strings.clone(strconv.write_int(buf[:], i64(n), 10), c.sa)
}

@(private)
alphabetic :: proc(c: ^Ctx, n: int, first: u8, base_n: int) -> string {
	if n < 1 { return itoa(c, n) }
	buf: [16]u8
	k := len(buf)
	v := n
	for v > 0 && k > 0 { v -= 1; k -= 1; buf[k] = first + u8(v % base_n); v /= base_n }
	return strings.clone(string(buf[k:]), c.sa)
}

@(private)
roman :: proc(c: ^Ctx, n: int, upper: bool) -> string {
	VALS :: [13]int{1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1}
	UP :: [13]string{"M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"}
	LO :: [13]string{"m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i"}
	vals, up, lo := VALS, UP, LO
	sb := strings.builder_make(c.sa)
	v := n
	for i in 0 ..< 13 {
		for v >= vals[i] { strings.write_string(&sb, upper ? up[i] : lo[i]); v -= vals[i] }
	}
	return strings.to_string(sb)
}
