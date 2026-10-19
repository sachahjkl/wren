package layout

import "core:mem/virtual"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:style"

// Entry points. A pass is one of:
//   * refresh (refresh.odin): only paint-only values changed; boxes and display list stay, values are re-read;
//   * incremental (incremental.odin): from the journals of what changed (document mutations, style changes, viewport,
//     natural sizes, fonts), only the boxes concerned are rebuilt and laid out again;
//   * full: everything from scratch. What survives is the scroll offset of each scroll container.
// All per-pass memory is either the layout's own arrays (reused, their capacity kept) or the temp allocator.

// Lays out the document. The result stays valid until the next call (strings of the document are referenced, not copied).
run :: proc(l: ^Layout, input: Input) {
	if can_refresh(l, input) && refresh(l, input) { return }
	if run_incremental(l, input) { return }
	run_full(l, input)
	if input.settings.incremental { inc_after_full(l, input) }
}

@(private)
ctx_make :: proc(l: ^Layout, input: Input, marker: ^u8) -> Ctx {
	c := Ctx{
		l = l, d = input.doc, st = input.styled, set = &l.settings, text = input.text, replaced = input.replaced,
		scale = input.scale, vp = input.viewport, sa = virtual.arena_allocator(&l.arena), last_fi = -1,
		stack_base = uintptr(marker), stack_limit = l.settings.max_stack_bytes, rebuilding = NONE,
	}
	c.font_cache = make(map[Font_Key]i32, 64, context.temp_allocator)
	c.anon_cs = make(map[Anon_Key]^style.Computed, 16, context.temp_allocator)
	c.counters = make(map[base.Handle]List_Counter, 16, context.temp_allocator)
	c.lb_bufs = make([dynamic]^LB_Buffers, 0, 8, context.temp_allocator)
	return c
}

@(private)
note_inputs :: proc(l: ^Layout, input: Input) {
	l.mutations = input.doc.mutations
	l.serial = input.styled.serial
	l.layout_serial = input.styled.layout_serial
	l.canvas = input.styled.canvas
	l.styled = input.styled
	l.styled_pass = input.styled.pass_id
	l.viewport = input.viewport
	l.scale = input.scale
	l.settings = input.settings^
	l.valid = true
	l.inc.doc = input.doc
	l.inc.images_gen = input.images_generation
	l.inc.fonts_gen = input.fonts_generation
	l.inc.lh_normal = input.styled.line_height_normal
}

@(private)
run_full :: proc(l: ^Layout, input: Input) {
	if !l.arena_ready {
		_ = virtual.arena_init_growing(&l.arena)
		l.arena_ready = true
	} else {
		virtual.arena_free_all(&l.arena)
	}
	if l.scroll == nil { l.scroll = make(map[base.Handle]Vec2) }
	clear(&l.boxes); clear(&l.inline_items); clear(&l.lines); clear(&l.frags); clear(&l.fonts); clear(&l.items)
	clear(&l.node_box)
	inc_reset(l)
	note_inputs(l, input)
	l.last_pass = .Full
	l.passes[.Full] += 1

	marker: u8
	c := ctx_make(l, input, &marker)

	t0 := time.tick_now()
	reserve_tree(l, input.doc)
	style_sums(&c)
	l.tree_order = true
	build_tree(&c)
	c.sums = nil
	l.canvas_els = {c.root_el, c.body_el}
	mark_bfc_floats(&c, 0)
	reserve_lines(l)
	t1 := time.tick_now()
	pre_run(&c, layout_root)
	t2 := time.tick_now()
	finish(&c)
	t3 := time.tick_now()
	reserve(&l.items, len(l.boxes) + len(l.frags) + 64)
	build_display_list(&c)
	note_refresh_inputs(l)
	t4 := time.tick_now()
	build_bands(l, max(input.band_h, 16) * input.scale)
	t5 := time.tick_now()
	l.stats = {ms(t0, t1), ms(t1, t2), ms(t2, t3), ms(t3, t4), ms(t4, t5)}
	inc_note_full(l)
}

// The block layout of a pass: the initial containing block at the viewport, and everything in it.
@(private)
layout_root :: proc(c: ^Ctx) {
	l := c.l
	root := &l.boxes[0]
	root.pos = {0, 0}
	root.size = c.vp
	layout_contents(c, 0, c.vp.x, c.vp.y, -1, nil)
	l.boxes[0].size = c.vp
}

@(private)
ms :: proc(a, b: time.Tick) -> f32 { return f32(time.duration_milliseconds(time.tick_diff(a, b))) }

// A layout's arrays keep their capacity from one pass to the next; the first pass over a document (a fresh layout, a
// larger page) sizes them from the document instead of doubling them as it goes (each doubling copies everything and
// touches fresh memory). Estimates from the node count: about 3 boxes and 4 inline items for every 4 nodes.
@(private)
reserve_tree :: proc(l: ^Layout, d: ^dom.Document) {
	n := d.nodes.count
	reserve(&l.boxes, n * 3 / 4 + 64)
	reserve(&l.inc.info, n * 3 / 4 + 64)
	reserve(&l.inline_items, n + 64)
	// handle index -> box: every slot the document handed out, none yet
	used := int(d.nodes.used)
	if len(l.node_box) < used {
		old := len(l.node_box)
		resize(&l.node_box, used)
		for i in old ..< used { l.node_box[i] = NONE }
	}
}

// Lines and fragments, once the inline items are known: about one fragment per item, a line per two.
@(private)
reserve_lines :: proc(l: ^Layout) {
	n := len(l.inline_items)
	reserve(&l.frags, n + n / 4 + 64)
	reserve(&l.lines, n / 2 + 64)
}

// Forgets the result (and, unless kept, the scroll offsets): a new document is coming.
reset :: proc(l: ^Layout, keep_scroll := false) {
	clear(&l.boxes); clear(&l.inline_items); clear(&l.lines); clear(&l.frags); clear(&l.fonts); clear(&l.items)
	clear(&l.spaces); clear(&l.clips); clear(&l.groups); clear(&l.band_start); clear(&l.band_items); clear(&l.node_box)
	if !keep_scroll { clear(&l.scroll) }
	clear(&l.deco_items)
	inc_reset(l)
	pre_destroy(l)
	if l.arena_ready { virtual.arena_free_all(&l.arena) }
	l.valid = false
	l.last_pass = .None
	l.styled = nil
	l.height = 0
}

destroy :: proc(l: ^Layout) {
	delete(l.boxes); delete(l.inline_items); delete(l.lines); delete(l.frags); delete(l.fonts); delete(l.items)
	delete(l.spaces); delete(l.clips); delete(l.groups); delete(l.band_start); delete(l.band_items); delete(l.node_box)
	delete(l.scroll)
	delete(l.scratch)
	delete(l.deco_items)
	inc_destroy(l)
	pre_destroy(l)
	if l.arena_ready { virtual.arena_destroy(&l.arena) }
	l^ = {}
}

// Font of a display item (Text, Marker).
item_font :: proc(l: ^Layout, it: ^Display_Item) -> ^Font_Info {
	if it.fi < 0 || int(it.fi) >= len(l.fonts) { return nil }
	return &l.fonts[it.fi]
}
