package layout

import "wb:base"
import "wb:host"
import "wb:style"

// What box tree construction reads of each element's style, summed up on the layout threads before a full pass of a
// large document builds its tree. Construction walks the document in order and reads, per element, a dozen cache lines
// scattered over a 2 KB style made on another thread; with the summaries it reads 24 bytes per element, in handle
// order, and the style only for its font (and for list markers, generated content). The flags are those
// box_flags_from_style derives from the style alone; both paths go through style_sum_of.

@(private)
Sum_Bit :: enum u8 { Transform, Contains_Fixed, Before, After }

@(private)
Style_Sum :: struct {
	node:       base.Handle,   // the element this style is for (style_of: a recycled slot holds another one's)
	flags:      Box_Flags,
	display:    style.Display,
	position:   style.Position,
	float:      style.Float,
	visibility: style.Visibility,
	bits:       bit_set[Sum_Bit; u8],
}

@(private)
style_sum_of :: proc(cs: ^style.Computed) -> (s: Style_Sum) {
	s.node, s.display, s.position, s.float, s.visibility = cs.node, cs.display, cs.position, cs.float, cs.visibility
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
	sp := Sum_Pass{st = c.st, sums = make([]Style_Sum, n, context.temp_allocator)}
	sp.chunks = clamp(n / 2048, 1, host.thread_pool_size(pool) * 4)
	host.parallel_for(pool, sp.chunks, proc(data: rawptr, k: int) {
		sp := (^Sum_Pass)(data)
		n := len(sp.sums)
		lo, hi := k * n / sp.chunks, (k + 1) * n / sp.chunks
		AHEAD :: 4
		for i in lo ..< hi {
			if i + AHEAD < hi { prefetch_fields(rawptr(sp.st.by_node[i + AHEAD]), BUILD_FIELDS) }
			if cs := sp.st.by_node[i]; cs != nil { sp.sums[i] = style_sum_of(cs) } else { sp.sums[i] = {} }
		}
	}, &sp)
	c.sums = sp.sums
}
