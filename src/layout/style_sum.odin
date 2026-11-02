package layout

import "wb:base"
import "wb:host"
import "wb:style"

// Chunks of the style sums: one per this many nodes, at most this many per thread; and the styles prefetched ahead.
STYLE_SUM_NODES_PER_CHUNK :: 2048
STYLE_SUM_CHUNKS_PER_THREAD :: 4
PREFETCH_STYLES_AHEAD :: 4

// What box tree construction reads of each element's style, summed up on the layout threads before a full pass of a
// large document builds its tree. Construction walks the document in order and reads, per element, a dozen cache lines
// scattered over a 2 KB style made on another thread; with the summaries it reads 24 bytes per element, in handle
// order, and the style only for its text, a font it does not inherit, list markers and generated content. The flags are
// those box_flags_from_style derives from the style alone; both paths go through style_sum_of. Whether an element's font
// is its parent's is found there too (Parent_Font): most elements inherit theirs, and construction then reads none of their
// font properties.

// Parent_Font: its font is its parent element's (the same key, font_key_of): the box takes its parent's. Neg_Block,
// Neg_Inline: a negative top or bottom, left or right margin (mark_box_flow_flags).
@(private)
Sum_Bit :: enum u8 { Transform, Contains_Fixed, Before, After, Frames, Spans, Parent_Font, Neg_Block, Neg_Inline }

@(private)
Style_Sum :: struct {
	node:       base.Handle,   // the element this style is for (style_of: a recycled slot holds another one's)
	flags:      Box_Flags,
	display:    style.Display,
	position:   style.Position,
	float:      style.Float,
	visibility: style.Visibility,
	bits:       bit_set[Sum_Bit; u16],
	deco:       style.Decorations,   // text-decoration-line (child_frame)
}

@(private)
style_sum_of :: proc(cs: ^style.Computed) -> (s: Style_Sum) {
	s.display, s.position, s.float, s.visibility, s.deco = cs.display, cs.position, cs.float, cs.visibility, cs.text_decoration
	switch cs.position {
	case .Static:
	case .Relative: s.flags += {.Positioned, .Relative}
	case .Sticky: s.flags += {.Positioned, .Sticky, .Stacking}
	case .Absolute: s.flags += {.Positioned, .Abs, .Bfc}
	case .Fixed: s.flags += {.Positioned, .Abs, .Bfc, .Stacking}
	}
	if .Positioned in s.flags && !cs.z_auto { s.flags += {.Stacking} }
	if cs.opacity < 1 || stacking_effect(cs) { s.flags += {.Stacking} }
	if box_effects(cs) != {} { s.flags += {.Effects} }
	if cs.mix_blend_mode != .Normal { s.flags += {.Blends} }
	if cs.float != .None && .Abs not_in s.flags { s.flags += {.Float, .Bfc} }
	if cs.visibility != .Visible { s.flags += {.Hidden} }
	if !cs.pointer_events { s.flags += {.No_Pointer} }
	if cs.overflow_x != .Visible || cs.overflow_y != .Visible {
		s.flags += {.Clips, .Bfc}
		if cs.overflow_x == .Scroll || cs.overflow_x == .Auto || cs.overflow_y == .Scroll || cs.overflow_y == .Auto { s.flags += {.Scroll} }
	}
	if cs.display == .Flow_Root || cs.display == .Inline_Block { s.flags += {.Bfc} }
	if style.has_transform(cs) { s.bits += {.Transform} }
	if contains_fixed(cs) { s.bits += {.Contains_Fixed} }
	if cs.before != nil { s.bits += {.Before} }
	if cs.after != nil { s.bits += {.After} }
	if cs.frames { s.bits += {.Frames} }
	if cs.column_span == .All { s.bits += {.Spans} }
	if negative_margin(cs.margin[.Top]) || negative_margin(cs.margin[.Bottom]) { s.bits += {.Neg_Block} }
	if negative_margin(cs.margin[.Left]) || negative_margin(cs.margin[.Right]) { s.bits += {.Neg_Inline} }
	return
}

// The summary of `h`'s style (nil: no style). Only when c.sums is set.
@(private)
sum_of :: #force_inline proc(c: ^Ctx, h: base.Handle) -> ^Style_Sum {
	i := int(base.handle_index(h))
	if i >= len(c.sums) { return nil }
	s := &c.sums[i]
	return s.node == h && s.node != base.NIL_HANDLE ? s : nil
}

@(private)
Sum_Pass :: struct {
	st:     ^style.Styled,
	sums:   []Style_Sum,
	c:      ^Ctx,   // (read: the parent of a node, up)
	chunks: int,
}

// Sets c.sums for a full pass over a large document, when the layout threads are free.
@(private)
style_sums :: proc(c: ^Ctx) {
	n := len(c.st.by_node)
	if par_threads(c.l.settings.threads) <= 0 || n < max(c.l.settings.threads_min_boxes, 1) { return }
	pool := par_acquire(c.l.settings.threads)
	if pool == nil { return }
	defer par_release()
	sp := Sum_Pass{st = c.st, sums = make([]Style_Sum, n, context.temp_allocator), c = c}
	sp.chunks = clamp(n / STYLE_SUM_NODES_PER_CHUNK, 1, host.thread_pool_size(pool) * STYLE_SUM_CHUNKS_PER_THREAD)
	host.parallel_for(pool, sp.chunks, proc(data: rawptr, k: int) {
		sp := (^Sum_Pass)(data)
		n := len(sp.sums)
		lo, hi := k * n / sp.chunks, (k + 1) * n / sp.chunks
		for i in lo ..< hi {
			if i + PREFETCH_STYLES_AHEAD < hi {
				ahead := rawptr(sp.st.by_node[i + PREFETCH_STYLES_AHEAD])
				prefetch_fields(ahead, BUILD_FIELDS)   // (the font's properties are inherited: in the group BUILD_FIELDS points at)
			}
			if cs := sp.st.by_node[i]; cs != nil {
				sp.sums[i] = style_sum_of(cs)
				sp.sums[i].node = sp.st.nodes[i]
				// (a group shared with the parent: the same font, without reading its key)
				if ps := style.style_of(sp.st, up(sp.c, sp.st.nodes[i])); ps != nil && (ps.inherited_group == cs.inherited_group || font_key_of(ps, true) == font_key_of(cs, true)) { sp.sums[i].bits += {.Parent_Font} }
			} else {
				sp.sums[i] = {}
			}
		}
	}, &sp)
	c.sums = sp.sums
}
