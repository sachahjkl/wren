package layout

import "wb:base"
import "wb:dom"

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
	b.flags -= {.Ifc, .Flattened, .Bfc_Floats}
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
