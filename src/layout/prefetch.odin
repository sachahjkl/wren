package layout

import "base:intrinsics"
import "wb:base"
import "wb:style"

// A computed style is about 1 KB (and the groups it sets: style.Group; the inherited properties are a group most
// elements share with their parent, read through one pointer) and most elements have their own, made on the style threads: a large document's styles are far bigger than the caches, and each step of layout reads a few fields
// of each style, scattered over a dozen cache lines. Read one after the other, those misses are most of the time a pass takes. Each step therefore starts
// fetching the lines it will read of the styles of the boxes coming next, while it works on the current one.

// What box tree construction reads (box_flags_from_style, stacking_effect, contains_fixed, font_info, child_frame,
// generated content, list markers).
@(private)
BUILD_FIELDS :: [?]uintptr{
	offset_of(style.Computed, display), offset_of(style.Computed, z_auto), offset_of(style.Computed, opacity),
	offset_of(style.Computed, inherited_group), offset_of(style.Computed, transform_group), offset_of(style.Computed, rare_group),
	offset_of(style.Computed, before),
}

// What box tree construction still reads when the styles are summed up (style_sum.odin): a font the element does not
// inherit, white space and text-transform of text.
@(private)
FONT_FIELDS :: [?]uintptr{offset_of(style.Computed, inherited_group)}

// What the block layout reads (resolve_box_model, block_width, specified heights).
@(private)
LAYOUT_FIELDS :: [?]uintptr{
	offset_of(style.Computed, display), offset_of(style.Computed, width), offset_of(style.Computed, max_width),
	offset_of(style.Computed, margin), offset_of(style.Computed, padding), offset_of(style.Computed, border_width),
	offset_of(style.Computed, aspect_ratio),
}

// What the display list reads (emit_box, emit_lines).
@(private)
PAINT_FIELDS :: [?]uintptr{
	offset_of(style.Computed, display), offset_of(style.Computed, z_index), offset_of(style.Computed, background_color),
	offset_of(style.Computed, background_group), offset_of(style.Computed, box_shadow), offset_of(style.Computed, outline_width),
}

@(private)
prefetch_fields :: #force_inline proc(cs: rawptr, $fields: [$N]uintptr) {
	if cs == nil { return }
	offs := fields
	#unroll for i in 0 ..< N { intrinsics.prefetch_read_data(rawptr(uintptr(cs) + offs[i]), 3) }
}

// The style of a node, without reading it (nil: none, or not known).
@(private)
style_addr :: #force_inline proc(st: ^style.Styled, h: base.Handle) -> rawptr {
	i := int(base.handle_index(h))
	if i >= len(st.by_node) { return nil }
	return rawptr(st.by_node[i])
}
