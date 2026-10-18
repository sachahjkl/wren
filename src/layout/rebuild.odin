package layout

import "wb:base"
import "wb:dom"
import "wb:style"

// Partial rebuilds of the box tree: the content of one box is made again from the document, exactly as the full
// build would make it, from the frame its content was given then (remembered in Box_Info: containing blocks, text
// decorations, list number). The old descendants are marked Dead; the new boxes and their inline items go at the end
// of the arrays.
//
// The box itself stays: what it is depends on its own style and on its ancestors, not on its content, except whether
// it holds blocks or only inline content (its Ifc flag), which is decided again. A rebuild is refused upstream when the
// result could depend on what comes before the box in the document (generated quotes).

@(private)
note_frame :: proc(c: ^Ctx, bi: i32, g: Frame) {
	inf := &c.l.inc.info[bi]
	inf.cb, inf.fcb = g.cb, g.fcb
	inf.deco, inf.deco_color, inf.deco_box = g.deco, g.deco_color, g.deco_box
}

@(private)
kill_items :: proc(c: ^Ctx, b: ^Box) {
	l := c.l
	for i in b.items[0] ..< b.items[1] {
		it := &l.inline_items[i]
		it.cs, it.node = nil, base.NIL_HANDLE
	}
	l.inc.dead_items += int(b.items[1] - b.items[0])
	l.inc.live_items -= int(b.items[1] - b.items[0])
	b.items = {}
	if b.lines[1] > b.lines[0] {
		l.inc.dead_lines += int(b.lines[1] - b.lines[0])
		l.inc.dead_frags += int(l.lines[b.lines[1] - 1].frags[1] - l.lines[b.lines[0]].frags[0])
	}
	b.lines = {}
}

// Marks every descendant of `bi` Dead and empties `bi`: no children, no items, no lines, no absolutely positioned
// boxes (all of those it was the containing block of are inside it).
@(private)
kill_contents :: proc(c: ^Ctx, bi: i32) {
	l := c.l
	stack := make([dynamic]i32, 0, 32, context.temp_allocator)
	abs_cbs := make(map[i32]bool, 4, context.temp_allocator)
	for ch := l.boxes[bi].first; ch != NONE; ch = l.boxes[ch].next { append(&stack, ch) }
	for len(stack) > 0 {
		x := pop(&stack)
		b := &l.boxes[x]
		for ch := b.first; ch != NONE; ch = l.boxes[ch].next { append(&stack, ch) }
		b.flags += {.Dead}
		b.inc = {}
		l.inc.dead_boxes += 1
		l.inc.live_boxes -= 1
		if b.node != base.NIL_HANDLE && .Pseudo not_in b.flags {
			i := int(base.handle_index(b.node))
			if i < len(l.node_box) && l.node_box[i] == x { l.node_box[i] = NONE }
		}
		if .Abs in b.flags && b.cb != NONE { abs_cbs[b.cb] = true }
		kill_items(c, b)
	}
	b := &l.boxes[bi]
	kill_items(c, b)
	b.first, b.last, b.cur_anon = NONE, NONE, NONE
	b.abs_first, b.abs_last = NONE, NONE
	b.flags -= {.Ifc, .Flattened, .Bfc_Floats, .Neg_Margins}
	b.marker, b.marker_w = "", 0
	// containing blocks outside the subtree drop their dead absolutely positioned boxes (order kept)
	for cb in abs_cbs {
		cbb := &l.boxes[cb]
		if .Dead in cbb.flags || cb == bi { continue }
		prev := NONE
		for a := cbb.abs_first; a != NONE; {
			next := l.boxes[a].abs_next
			if .Dead in l.boxes[a].flags {
				if prev == NONE { cbb.abs_first = next } else { l.boxes[prev].abs_next = next }
				if cbb.abs_last == a { cbb.abs_last = prev }
			} else {
				prev = a
			}
			a = next
		}
	}
}

// Kills box `x` itself too and takes it out of its parent's children. Returns the child before it (NONE: it was the
// first), where a replacement goes.
@(private)
kill_box :: proc(c: ^Ctx, x: i32) -> i32 {
	l := c.l
	kill_contents(c, x)
	b := &l.boxes[x]
	b.flags += {.Dead}
	b.inc = {}
	l.inc.dead_boxes += 1
	l.inc.live_boxes -= 1
	if b.node != base.NIL_HANDLE && .Pseudo not_in b.flags {
		i := int(base.handle_index(b.node))
		if i < len(l.node_box) && l.node_box[i] == x { l.node_box[i] = NONE }
	}
	p := &l.boxes[b.parent]
	prev := NONE
	for ch := p.first; ch != NONE && ch != x; ch = l.boxes[ch].next { prev = ch }
	if prev == NONE { p.first = b.next } else { l.boxes[prev].next = b.next }
	if p.last == x { p.last = prev }
	b.next = NONE
	return prev
}

// Moves the last child of `p` to just after `after` (NONE: first).
@(private)
move_last_child :: proc(l: ^Layout, p: i32, after: i32) {
	pb := &l.boxes[p]
	x := pb.last
	if x == NONE || x == after { return }
	prev := NONE
	for ch := pb.first; ch != x; ch = l.boxes[ch].next { prev = ch }
	if after == prev { return }   // already there
	// unlink from the end
	if prev == NONE { pb.first = NONE } else { l.boxes[prev].next = NONE }
	pb.last = prev
	// link after `after`
	if after == NONE {
		l.boxes[x].next = pb.first
		pb.first = x
	} else {
		l.boxes[x].next = l.boxes[after].next
		l.boxes[after].next = x
	}
	if l.boxes[x].next == NONE { pb.last = x }
}

////////////////////////////////
// One child of a container made again, inserted or removed
//
// The common mutations (a block appended to a list of blocks, one section restyled) concern one block-level child of a
// block container with block children, or one item of a flex container. Its box alone is made again (or added, or
// dropped), among siblings that stay, when the full build would make the siblings exactly the same: the child is an
// ordinary in-flow block-level box before and after (not floating, not absolutely positioned, no list numbering that
// would shift), and the content just before it is a block-level box too, or nothing (inline content before it would
// share an anonymous block with what follows).

@(private)
Child_Plan :: struct {
	node:   base.Handle,
	old:    i32,       // its box now (NONE: none)
	old_p:  i32,       // ... and the container of that box
	new_p:  i32,       // the container of the box it must have (NONE: it makes none)
}

// A container whose children can be rebuilt one by one, and the mode its content is built in.
@(private)
child_container :: proc(l: ^Layout, p: i32) -> (Mode, bool) {
	if p == NONE { return .None, false }
	b := &l.boxes[p]
	if .Dead in b.flags || .Anonymous in b.flags || .Pseudo in b.flags || .Root in b.flags || b.node == base.NIL_HANDLE { return .None, false }
	if int(b.depth) + 2 >= l.settings.max_depth || .Flattened in b.flags { return .None, false }
	switch b.kind {
	case .Block: if .Ifc not_in b.flags { return .Block, true }
	case .Flex: return .Flex, true
	case .Inline, .Replaced, .Table, .Row_Group, .Row, .Cell, .Caption:
	}
	return .None, false
}

// An existing child box that can be dropped or replaced alone.
@(private)
simple_child_box :: proc(l: ^Layout, x: i32) -> bool {
	b := &l.boxes[x]
	if .Anonymous in b.flags || .Pseudo in b.flags { return false }
	return b.flags & {.Abs, .Float, .Atomic, .Block_In_Inline, .List_Item} == {} && b.kind != .Inline
}

// Will element `h` make an ordinary in-flow box in a container of `mode`? (decided from its style as the build does)
@(private)
simple_child_style :: proc(c: ^Ctx, h: base.Handle, mode: Mode) -> bool {
	n := dom.get(c.d, h)
	if n == nil || n.kind != .Element || n.name == "br" || n.name == "input" { return false }
	cs := style.style_of(c.st, h)
	if cs == nil || cs.display == .Contents || cs.display == .List_Item { return false }
	if cs.position == .Absolute || cs.position == .Fixed { return false }
	lv := level_of(cs.display)
	switch mode {
	case .Block: return lv == .Block && cs.float == .None
	case .Flex: return lv != .Table_Internal && lv != .Column
	case .Inline, .Table, .Row_Group, .Row, .None:
	}
	return false
}

// Does element `h` make no box at all (display: none, hidden input, detached)?
@(private)
makes_no_box :: proc(c: ^Ctx, h: base.Handle) -> bool {
	n := dom.get(c.d, h)
	if n == nil || n.kind != .Element { return true }
	cs := style.style_of(c.st, h)
	if cs == nil || cs.display == .None { return true }
	if n.name == "input" {
		if t, ok := dom.get_attribute(c.d, h, "type"); ok && t == "hidden" { return true }
	}
	return false
}

// The element is in the document (its ancestors reach the document node).
@(private)
attached :: proc(c: ^Ctx, h: base.Handle) -> bool {
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(c.d, cur)
		if n == nil { return false }
		if n.kind == .Document { return true }
		cur = n.parent
	}
	return false
}

// What comes before `h` among its siblings, skipping what makes nothing: a block-level box of the container `p`
// (returned, NONE: nothing before), or inline content (ok = false). `planned`: siblings that will get a box of their own.
@(private)
box_before :: proc(c: ^Ctx, h: base.Handle, p: i32, planned: map[base.Handle]bool) -> (i32, bool) {
	l := c.l
	for s := dom.get(c.d, h).prev; s != base.NIL_HANDLE; s = dom.get(c.d, s).prev {
		n := dom.get(c.d, s)
		switch n.kind {
		case .Document, .Comment: continue
		case .Text:
			cs, _ := text_owner_cs(c, s)
			if collapsible_ws_only(n.text, cs.white_space) || len(n.text) == 0 { continue }
			return NONE, false
		case .Element:
			if s in planned { return PLANNED_BOX, true }
			if makes_no_box(c, s) { continue }
			x := live_box(l, s)
			if x == NONE || l.boxes[x].parent != p || !simple_child_box(l, x) { return NONE, false }
			return x, true
		}
	}
	return NONE, true
}

// "A sibling that will be made just before": known when it is (place_children).
@(private) PLANNED_BOX :: i32(-2)

// Plans the children `touched` of their containers. false: some cannot be done one by one; the caller rebuilds the
// containers concerned whole.
@(private)
plan_children :: proc(c: ^Ctx, touched: []base.Handle, plans: ^[dynamic]Child_Plan) -> bool {
	l := c.l
	planned := make(map[base.Handle]bool, len(touched), context.temp_allocator)
	for h in touched {
		pl := Child_Plan{node = h, old = live_box(l, h), old_p = NONE, new_p = NONE}
		if pl.old != NONE {
			pl.old_p = l.boxes[pl.old].parent
			if _, ok := child_container(l, pl.old_p); !ok || !simple_child_box(l, pl.old) { return false }
		}
		if attached(c, h) && !makes_no_box(c, h) && !hidden_now(c, h) {
			pn := dom.get(c.d, h).parent
			pl.new_p = live_box(l, pn)
			mode, ok := child_container(l, pl.new_p)
			if !ok || !simple_child_style(c, h, mode) { return false }
			planned[h] = true
		}
		append(plans, pl)
	}
	// a removed box must not leave inline content on its left joining what follows it
	for &pl in plans {
		if pl.old == NONE || pl.old_p == pl.new_p { continue }
		prev := NONE
		for ch := l.boxes[pl.old_p].first; ch != pl.old; ch = l.boxes[ch].next { prev = ch }
		if prev != NONE && !simple_child_box(l, prev) { return false }
	}
	// a new box goes after a block-level box (or first)
	for &pl in plans {
		if pl.new_p == NONE { continue }
		if _, ok := box_before(c, pl.node, pl.new_p, planned); !ok { return false }
	}
	// a block container still has block children (else its content is inline: rebuilt whole)
	for &pl in plans {
		for p in ([2]i32{pl.old_p, pl.new_p}) {
			if p == NONE { continue }
			b := &l.boxes[p]
			// the box's style is still the old record here (styles are re-read later): the element's current one
			if b.kind == .Block && !has_block_child(c, b.node, style.style_of(c.st, b.node), b.depth) { return false }
		}
	}
	return true
}

// The frame the content of container `p` was built with.
@(private)
content_frame :: proc(c: ^Ctx, p: i32) -> Frame {
	b := &c.l.boxes[p]
	inf := c.l.inc.info[p]
	g := Frame{kind = .Visit, node = b.node, parent = b.parent, mode = .Block, cb = inf.cb, fcb = inf.fcb, depth = b.depth,
		ifc = b.ifc_root, deco = inf.deco, deco_color = inf.deco_color, deco_box = inf.deco_box}
	return child_frame(c, p, g, true)
}

// Drops the old boxes of the plans (those inside a rebuilt subtree are dead already).
@(private)
drop_planned :: proc(c: ^Ctx, plans: []Child_Plan) {
	l := c.l
	for &pl in plans {
		if pl.old == NONE || .Dead in l.boxes[pl.old].flags || .Dead in l.boxes[pl.old_p].flags { continue }
		kill_box(c, pl.old)
		mark_dirty(l, pl.old_p)
	}
}

// Makes the new boxes of the plans, in document order within each container (`skip`: containers rebuilt whole).
@(private)
place_children :: proc(c: ^Ctx, plans: []Child_Plan, skip: map[i32]bool) {
	l := c.l
	// document order: plans sorted by the position of their node among its siblings
	order := make([dynamic]int, 0, len(plans), context.temp_allocator)
	for &pl, i in plans {
		if pl.new_p != NONE && .Dead not_in l.boxes[pl.new_p].flags && !skip[pl.new_p] { append(&order, i) }
	}
	pos := make([]int, len(plans), context.temp_allocator)
	for i in order {
		for s := dom.get(c.d, plans[i].node).prev; s != base.NIL_HANDLE; s = dom.get(c.d, s).prev { pos[i] += 1 }
	}
	for i in 1 ..< len(order) {
		x := order[i]
		j := i
		for j > 0 && pos[order[j - 1]] > pos[x] { order[j] = order[j - 1]; j -= 1 }
		order[j] = x
	}
	no_plans := make(map[base.Handle]bool, 0, context.temp_allocator)
	for i in order {
		pl := &plans[i]
		p := pl.new_p
		after, _ := box_before(c, pl.node, p, no_plans)   // siblings placed before are live boxes by now
		f := content_frame(c, p)
		f.kind, f.node = .Visit, pl.node
		stack := make([dynamic]Frame, 0, 32, context.temp_allocator)
		visit(c, &stack, f)
		build_loop(c, &stack)
		nb := live_box(l, pl.node)
		if nb == NONE { continue }
		move_last_child(l, p, after)
		mark_dirty(l, nb)
	}
}

// Makes the content of `bi` (emptied by kill_contents) again from its element.
@(private)
rebuild_contents :: proc(c: ^Ctx, bi: i32) {
	l := c.l
	b := &l.boxes[bi]
	h := b.node
	cs := b.cs
	n := dom.get(c.d, h)
	if n == nil { return }
	inf := l.inc.info[bi]
	g := Frame{kind = .Visit, node = h, parent = b.parent, mode = .Block, cb = inf.cb, fcb = inf.fcb, depth = b.depth,
		ifc = b.ifc_root, deco = inf.deco, deco_color = inf.deco_color, deco_box = inf.deco_box}
	has_block := false
	if b.kind == .Block || b.kind == .Cell || b.kind == .Caption {
		has_block = has_block_child(c, h, cs, b.depth)
	}
	cf := child_frame(c, bi, g, has_block)
	stack := make([dynamic]Frame, 0, 64, context.temp_allocator)
	if .List_Item in l.boxes[bi].flags {
		c.rebuilding = bi
		make_marker(c, bi, h, cf)
		c.rebuilding = NONE
	}
	push_children(c, &stack, h, cs, cf)
	build_loop(c, &stack)
}
