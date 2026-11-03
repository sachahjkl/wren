package style

import "core:mem"
import "core:sync"
import "wb:base"

// What a change of computed values costs downstream. Most properties feed layout; a few are read only when painting
// (colors, backgrounds, shadows, radii, transforms, opacity...) or by nobody downstream of the cascade (the transition
// and animation lists). When everything that changed between two styles is paint-only, layout can keep its boxes and
// display list and only re-read the styles (layout's refresh path): `layout_equal` tells, and `Styled.layout_serial`
// records the last change that was not paint-only.
//
// A paint-only property can still change the structure of the box tree at a threshold: transform none <-> some value
// (stacking context, containing block of fixed descendants), opacity 1 <-> below 1 (stacking context), filter none <->
// some (stacking context, containing block), backdrop-filter and clip-path none <-> some (stacking context, effect
// group). `structure_sig` summarizes those thresholds; a change of it is a layout change.

Prop_Tier :: enum u8 {
	Layout,   // box tree, sizes or positions may change
	Paint,    // the painter (or nothing downstream) reads it; geometry is unaffected
}

PAINT_PROPS :: [?]Prop{
	.Color_Scheme, .Color, .Text_Shadow, .Text_Decoration_Color, .Column_Rule_Color,
	.Border_Top_Color, .Border_Right_Color, .Border_Bottom_Color, .Border_Left_Color,
	.Border_Top_Left_Radius, .Border_Top_Right_Radius, .Border_Bottom_Right_Radius, .Border_Bottom_Left_Radius,
	.Opacity,
	.Background_Color, .Background_Image, .Background_Repeat, .Background_Position, .Background_Size,
	.Background_Origin, .Background_Clip, .Background_Attachment, .Box_Shadow,
	.Cursor, .User_Select, .Outline_Style, .Outline_Color, .Outline_Offset,
	.Transform, .Transform_Origin, .Transform_Box, .Transform_Style, .Translate, .Rotate, .Scale, .Perspective,
	.Perspective_Origin, .Backface_Visibility,
	.Transition_Property, .Transition_Duration, .Transition_Timing_Function, .Transition_Delay, .Transition_Behavior,
	.Animation_Name, .Animation_Duration, .Animation_Timing_Function, .Animation_Delay, .Animation_Iteration_Count,
	.Animation_Direction, .Animation_Fill_Mode, .Animation_Play_State, .Animation_Composition,
	.Object_Position, .Filter, .Backdrop_Filter, .Clip_Path,
	.Scroll_Behavior, .Overflow_Anchor, .Overscroll_Behavior_X, .Overscroll_Behavior_Y, .Caret_Color, .Accent_Color,
	.Mask_Image, .Mask_Mode, .Mask_Repeat, .Mask_Position, .Mask_Size, .Mask_Origin, .Mask_Clip, .Mask_Composite,
	.Text_Fill_Color, .Wren_Shader,
}

@(private) tiers_once: sync.Once
@(private) tier_table: [Prop]Prop_Tier
@(private) paint_set: Prop_Set
// Fields of Computed compared by layout_equal: every field except those of paint-only properties and bookkeeping
// that layout never reads (the inherited-from-parent set, custom properties: their effect is in the other values).
@(private) layout_fields: [dynamic]Field_Info

@(private)
tiers_init :: proc() {
	props_init()
	sync.once_do(&tiers_once, proc() {
		for p in PAINT_PROPS {
			tier_table[p] = .Paint
			ps_add(&paint_set, p)
		}
		skip := make(map[Field_Key]bool, 64, context.temp_allocator)
		for p in PAINT_PROPS {
			sl := &prop_slots[p]
			for k in 0 ..< 2 { if sl.size[k] > 0 { skip[{sl.group, sl.off[k]}] = true } }
		}
		skip[{.Main, offset_of(Computed, inherits)}] = true
		skip[{.Main, offset_of(Computed, custom)}] = true
		// (painted only: their colors, the placeholder's font)
		skip[{.Main, offset_of(Computed, selection)}] = true
		skip[{.Main, offset_of(Computed, placeholder)}] = true
		layout_fields = make([dynamic]Field_Info, 0, len(computed_fields), base.permanent_allocator())
		for f in computed_fields { if !skip[{f.group, f.offset}] { append(&layout_fields, f) } }
	})
}

// A field of a Computed, its group and offset (the tables built once above and in layout_change.odin).
@(private) Field_Key :: struct { group: Group, offset: uintptr }

prop_tier :: proc(p: Prop) -> Prop_Tier {
	tiers_init()
	return tier_table[p]
}

// The paint-only properties as a set.
paint_props :: proc() -> Prop_Set {
	tiers_init()
	return paint_set
}

// Every property of `s` is paint-only.
paint_only :: proc(s: Prop_Set) -> bool {
	tiers_init()
	for w, i in s.bits { if w & ~paint_set.bits[i] != 0 { return false } }
	return true
}

// Thresholds of paint-only properties that change the box tree (see the package comment above).
structure_sig :: proc(c: ^Computed) -> u8 {
	if c == nil { return 0xff }
	sig: u8
	if has_transform(c) { sig |= 1 }
	if c.opacity < 1 { sig |= 2 }
	if len(c.filter) > 0 { sig |= 4 }
	if len(c.backdrop_filter) > 0 { sig |= 8 }
	if c.clip_path != nil { sig |= 16 }
	if has_mask(c) { sig |= 32 }
	if transform_is_3d(c) || c.transform_style == .Preserve_3d { sig |= 64 }   // a plane (layout/plane.odin)
	if c.backface_visibility == .Hidden { sig |= 128 }
	return sig
}

// The two styles lay out the same: they differ at most in paint-only properties, and on the same side of every
// structural threshold. Generated boxes (::before / ::after) are compared the same way.
layout_equal :: proc(a, b: ^Computed) -> bool {
	if a == b { return true }
	if a == nil || b == nil { return false }
	tiers_init()
	if structure_sig(a) != structure_sig(b) { return false }
	for f in layout_fields {
		ba, bb := group_base(a, f.group), group_base(b, f.group)
		if ba == bb && f.group != .Main { continue }   // a group the two share
		pa, pb := rawptr(ba + f.offset), rawptr(bb + f.offset)
		if is_pseudo_field(f) {
			if !layout_equal((^^Computed)(pa)^, (^^Computed)(pb)^) { return false }
			continue
		}
		if f.plain {
			if mem.compare_ptrs(pa, pb, f.size) != 0 { return false }
		} else if !deep_equal(pa, pb, f.ti) {
			return false
		}
	}
	return true
}

// A new serial for paint-only changes: layout notices that styles changed, and that it may refresh instead of laying out.
styled_touch_paint :: proc(s: ^Styled) {
	styled_serial += 1
	s.serial = styled_serial
	journal_stamp(s)
}
