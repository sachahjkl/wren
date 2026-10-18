package layout

import "core:mem/virtual"
import "core:time"
import "wb:base"
import "wb:style"

// Entry points. A layout is redone from scratch when the document, its styles, the viewport or the scale change; what
// survives is the scroll offset of each scroll container. All per-pass memory is either the layout's own arrays (reused,
// their capacity kept) or the temp allocator.

// Lays out the document. The result stays valid until the next call (strings of the document are referenced, not copied).
run :: proc(l: ^Layout, input: Input) {
	if can_refresh(l, input) && refresh(l, input) { return }
	if !l.arena_ready {
		_ = virtual.arena_init_growing(&l.arena)
		l.arena_ready = true
	} else {
		virtual.arena_free_all(&l.arena)
	}
	if l.scroll == nil { l.scroll = make(map[base.Handle]Vec2) }
	clear(&l.boxes); clear(&l.inline_items); clear(&l.lines); clear(&l.frags); clear(&l.fonts); clear(&l.items)
	clear(&l.node_box)
	l.mutations = input.doc.mutations
	l.serial = input.styled.serial
	l.layout_serial = input.styled.layout_serial
	l.canvas = input.styled.canvas
	l.styled = input.styled
	l.last_pass = .Full
	l.passes[.Full] += 1
	l.viewport = input.viewport
	l.scale = input.scale
	l.settings = input.settings^
	l.valid = true

	marker: u8
	c := Ctx{
		l = l, d = input.doc, st = input.styled, set = &l.settings, text = input.text, replaced = input.replaced,
		scale = input.scale, vp = input.viewport, sa = virtual.arena_allocator(&l.arena), last_fi = -1,
		stack_base = uintptr(&marker), stack_limit = l.settings.max_stack_bytes,
	}
	c.font_cache = make(map[Font_Key]i32, 64, context.temp_allocator)
	c.anon_cs = make(map[Anon_Key]^style.Computed, 16, context.temp_allocator)
	c.counters = make(map[base.Handle]List_Counter, 16, context.temp_allocator)
	c.lb_bufs = make([dynamic]^LB_Buffers, 0, 8, context.temp_allocator)

	t0 := time.tick_now()
	build_tree(&c)
	l.canvas_els = {c.root_el, c.body_el}
	t1 := time.tick_now()
	root := &l.boxes[0]
	root.pos = {0, 0}
	root.size = input.viewport
	layout_contents(&c, 0, input.viewport.x, input.viewport.y, -1, nil)
	l.boxes[0].size = input.viewport
	t2 := time.tick_now()
	finish(&c)
	t3 := time.tick_now()
	build_display_list(&c)
	note_refresh_inputs(l)
	t4 := time.tick_now()
	build_bands(l, max(input.band_h, 16) * input.scale)
	t5 := time.tick_now()
	ms :: proc(a, b: time.Tick) -> f32 { return f32(time.duration_milliseconds(time.tick_diff(a, b))) }
	l.stats = {ms(t0, t1), ms(t1, t2), ms(t2, t3), ms(t3, t4), ms(t4, t5)}
}

// Forgets the result (and, unless kept, the scroll offsets): a new document is coming.
reset :: proc(l: ^Layout, keep_scroll := false) {
	clear(&l.boxes); clear(&l.inline_items); clear(&l.lines); clear(&l.frags); clear(&l.fonts); clear(&l.items)
	clear(&l.spaces); clear(&l.clips); clear(&l.groups); clear(&l.band_start); clear(&l.band_items); clear(&l.node_box)
	if !keep_scroll { clear(&l.scroll) }
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
	if l.arena_ready { virtual.arena_destroy(&l.arena) }
	l^ = {}
}

// Font of a display item (Text, Marker).
item_font :: proc(l: ^Layout, it: ^Display_Item) -> ^Font_Info {
	if it.fi < 0 || int(it.fi) >= len(l.fonts) { return nil }
	return &l.fonts[it.fi]
}
