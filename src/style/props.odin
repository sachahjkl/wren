package style

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "wb:base"

// Generic access to the computed value of one longhand: `prop_fields` maps a property to the field(s) of `Computed` that
// hold it, and reflection over the field types gives copying, comparing and deep cloning (and, in interpolate.odin,
// animation) without one hand-written switch per operation. A property occupies one field, or two when a legacy field is
// kept next to a richer one (`list_style_type` + `list_style`, the first background layer + the layer list, z-index's
// auto flag + value).

////////////////////////////////
// Property sets

ps_has :: #force_inline proc "contextless" (s: Prop_Set, p: Prop) -> bool { return s.bits[int(p) >> 6] & (u64(1) << (uint(p) & 63)) != 0 }
ps_add :: #force_inline proc "contextless" (s: ^Prop_Set, p: Prop) { s.bits[int(p) >> 6] |= u64(1) << (uint(p) & 63) }
ps_remove :: #force_inline proc "contextless" (s: ^Prop_Set, p: Prop) { s.bits[int(p) >> 6] &~= u64(1) << (uint(p) & 63) }

ps_union :: proc "contextless" (a, b: Prop_Set) -> (r: Prop_Set) {
	for i in 0 ..< len(a.bits) { r.bits[i] = a.bits[i] | b.bits[i] }
	return
}

ps_intersect :: proc "contextless" (a, b: Prop_Set) -> (r: Prop_Set) {
	for i in 0 ..< len(a.bits) { r.bits[i] = a.bits[i] & b.bits[i] }
	return
}

ps_empty :: proc "contextless" (s: Prop_Set) -> bool {
	for w in s.bits { if w != 0 { return false } }
	return true
}

ps_of :: proc "contextless" (props: ..Prop) -> (r: Prop_Set) {
	for p in props { ps_add(&r, p) }
	return
}

////////////////////////////////
// Static tables

@(private) props_once: sync.Once
@(private) inherited_table: [Prop]bool
@(private) inherited_set: Prop_Set
@(private) inherited_list: [len(INHERITED_PROPS)]Prop

// A field of a Computed: in the struct itself (group Main) or in one of its groups, at `offset` from the group's start.
Field_Info :: struct {
	group:  Group,
	offset: uintptr,
	size:   int,
	ti:     ^runtime.Type_Info,
	plain:  bool,     // no pointers and no padding: equal exactly when the bytes are
	name:   string,
}

// Every field, group by group (the group pointers themselves left out); `group_fields[g]` is the run of group g.
@(private) computed_fields: [dynamic]Field_Info
@(private) group_fields: [Group][]Field_Info

// Where each property lives in a Computed: its group, and one or two (offset, size) pairs in it, so copying needs no
// dispatch.
@(private)
Prop_Slot :: struct { group: Group, off: [2]uintptr, size: [2]int, ti: [2]^runtime.Type_Info }
@(private) prop_slots: [Prop]Prop_Slot

// The groups of the initial values, shared by every style that sets none of a group's properties: read-only pages, so
// that a write into a group a style does not own faults at once instead of changing the initial values of a process.
@(private) initial_groups: [Group]rawptr

@(private)
props_init :: proc() {
	sync.once_do(&props_once, proc() {
		// a probe whose groups are its own: a field's address says which group it is in
		probe: Computed
		probe_groups: [Group][GROUP_MAX_BYTES]u8
		for g in Group { if g != .Main { group_slot(&probe, g)^ = &probe_groups[g] } }
		group_of :: proc(probe: ^Computed, groups: ^[Group][GROUP_MAX_BYTES]u8, addr: rawptr) -> (Group, uintptr) {
			for g in Group {
				lo := g == .Main ? uintptr(probe) : uintptr(&groups[g])
				if uintptr(addr) >= lo && uintptr(addr) < lo + uintptr(group_size(g)) { return g, uintptr(addr) - lo }
			}
			panic("a property outside its computed style")
		}
		for p in Prop {
			a, b := prop_fields(&probe, p)
			sl := &prop_slots[p]
			sl.group, sl.off[0] = group_of(&probe, &probe_groups, a.data)
			sl.size[0], sl.ti[0] = type_info_of(a.id).size, type_info_of(a.id)
			if b.data != nil {
				g: Group
				g, sl.off[1] = group_of(&probe, &probe_groups, b.data)
				assert(g == sl.group, "the two fields of a property in two groups")
				sl.size[1], sl.ti[1] = type_info_of(b.id).size, type_info_of(b.id)
			}
		}
		for p, i in INHERITED_PROPS {
			inherited_table[p] = true
			ps_add(&inherited_set, p)
			inherited_list[i] = p
		}
		for p in Prop { assert((prop_slots[p].group == .Inherited) == inherited_table[p], "an inherited property outside the inherited group, or the reverse") }
		computed_fields = make([dynamic]Field_Info, base.permanent_allocator())
		starts: [Group]int
		for g in Group {
			starts[g] = len(computed_fields)
			st := runtime.type_info_base(group_type(g)).variant.(runtime.Type_Info_Struct)
			for i in 0 ..< int(st.field_count) {
				if st.usings[i] { continue }   // (Main: the group pointers)
				ft := st.types[i]
				append(&computed_fields, Field_Info{group = g, offset = st.offsets[i], size = ft.size, ti = ft, plain = is_plain(ft), name = st.names[i]})
			}
		}
		for g in Group { group_fields[g] = computed_fields[starts[g]:g == max(Group) ? len(computed_fields) : starts[Group(int(g) + 1)]] }
		initial_groups_build()
	})
}

// The largest group (the probe's room for each).
@(private) GROUP_MAX_BYTES :: 1024

@(private)
group_type :: proc(g: Group) -> ^runtime.Type_Info {
	switch g {
	case .Main: return type_info_of(Computed)
	case .Inherited: return type_info_of(Inherited_Group)
	case .Background: return type_info_of(Background_Group)
	case .Transform: return type_info_of(Transform_Group)
	case .Motion: return type_info_of(Motion_Group)
	case .Grid: return type_info_of(Grid_Group)
	case .Mask: return type_info_of(Mask_Group)
	case .Rare: return type_info_of(Rare_Group)
	}
	return nil
}

@(private)
group_size :: #force_inline proc(g: Group) -> int { return group_type(g).size }

#assert(size_of(Inherited_Group) <= GROUP_MAX_BYTES && size_of(Background_Group) <= GROUP_MAX_BYTES && size_of(Transform_Group) <= GROUP_MAX_BYTES && size_of(Motion_Group) <= GROUP_MAX_BYTES &&
	size_of(Grid_Group) <= GROUP_MAX_BYTES && size_of(Mask_Group) <= GROUP_MAX_BYTES && size_of(Rare_Group) <= GROUP_MAX_BYTES)

// The pointer to group `g` in `c` (not Main).
@(private)
group_slot :: #force_inline proc "contextless" (c: ^Computed, g: Group) -> ^rawptr {
	switch g {
	case .Main:
	case .Inherited: return (^rawptr)(&c.inherited_group)
	case .Background: return (^rawptr)(&c.background_group)
	case .Transform: return (^rawptr)(&c.transform_group)
	case .Motion: return (^rawptr)(&c.motion_group)
	case .Grid: return (^rawptr)(&c.grid_group)
	case .Mask: return (^rawptr)(&c.mask_group)
	case .Rare: return (^rawptr)(&c.rare_group)
	}
	return nil
}

// Where the fields of group `g` of `c` start.
@(private)
group_base :: #force_inline proc "contextless" (c: ^Computed, g: Group) -> uintptr {
	return g == .Main ? uintptr(c) : uintptr(group_slot(c, g)^)
}

// `c` gets a copy of its group `g` of its own, in `alloc` (zeroed when it had none: a blank Computed), which it may
// then write. The cascade takes each group once per element (cx_take); this copies every time.
group_take :: proc(c: ^Computed, g: Group, alloc: runtime.Allocator) {
	if g == .Main { return }
	slot := group_slot(c, g)
	ti := group_type(g)
	if slot^ == nil { slot^, _ = mem.alloc(ti.size, ti.align, alloc); return }
	data, _ := mem.alloc_bytes_non_zeroed(ti.size, ti.align, alloc)   // (overwritten whole)
	mem.copy(raw_data(data), slot^, ti.size)
	slot^ = raw_data(data)
}

// `c` may write property `p` (group_take of its group).
prop_take :: #force_inline proc(c: ^Computed, p: Prop, alloc: runtime.Allocator) { group_take(c, prop_slots[p].group, alloc) }

// The cascade's element owns the group of property `p` of the style it builds: copied from what it shared on the first write.
@(private)
cx_take :: #force_inline proc(cx: ^Cx, p: Prop) { cx_own(cx, prop_slots[p].group) }

// ... group `g`.
@(private)
cx_own :: #force_inline proc(cx: ^Cx, g: Group) {
	if g == .Main || g in cx.owned { return }
	group_take(cx.c, g, cx.alloc)
	cx.owned += {g}
}

// copy_prop into the style the cascade builds (nothing to do while it shares the very group of `src`: an inherited value
// taken from a parent whose group it shares).
@(private)
cx_copy_prop :: proc(cx: ^Cx, src: ^Computed, p: Prop) {
	g := prop_slots[p].group
	if g != .Main && group_base(cx.c, g) == group_base(src, g) { return }
	cx_take(cx, p)
	copy_prop(cx.c, src, p)
}

// The groups of the initial values, once (props_init): read-only from then on. Not the inherited one, whose initial
// values follow the preferences (initial_computed).
@(private)
initial_groups_build :: proc() {
	total := 0
	for g in Group { if g != .Main && g != .Inherited { total += mem.align_forward_int(group_size(g), GROUP_ALIGN) } }
	block, err := virtual.reserve_and_commit(uint(total))
	assert(err == nil, "no memory for the initial values")
	probe: Computed
	at := 0
	for g in Group {
		if g == .Main || g == .Inherited { continue }
		initial_groups[g] = &block[at]
		group_slot(&probe, g)^ = initial_groups[g]
		at += mem.align_forward_int(group_size(g), GROUP_ALIGN)
	}
	initial_groups_fill(&probe)
	ok := virtual.protect(raw_data(block), uint(total), {.Read})
	assert(ok, "the initial values cannot be made read-only")
}

@(private) GROUP_ALIGN :: 16

// A style whose groups are those of the initial values (the inherited one aside: `inh`, filled by the caller).
@(private)
groups_initial :: proc(c: ^Computed, inh: ^Inherited_Group) {
	props_init()
	for g in Group { if g != .Main && g != .Inherited { group_slot(c, g)^ = initial_groups[g] } }
	c.inherited_group = inh
}

// The properties that are not inherited take their initial values (an anonymous box's style): `initial`'s groups,
// and its values of the others; `dst` keeps its inherited group.
reset_noninherited :: proc(dst, initial: ^Computed) {
	props_init()
	for g in Group { if g != .Main && g != .Inherited { group_slot(dst, g)^ = group_slot(initial, g)^ } }
	for p in Prop { if prop_slots[p].group == .Main { copy_prop(dst, initial, p) } }
}

is_inherited :: #force_inline proc(p: Prop) -> bool { return inherited_table[p] }

// No pointer anywhere inside, and no padding: byte comparison is value comparison.
@(private)
is_plain :: proc(ti: ^runtime.Type_Info) -> bool {
	t := runtime.type_info_base(ti)
	#partial switch v in t.variant {
	case runtime.Type_Info_Integer, runtime.Type_Info_Enum, runtime.Type_Info_Boolean, runtime.Type_Info_Bit_Set, runtime.Type_Info_Rune:
		return true
	case runtime.Type_Info_Float:
		return false   // -0 == 0
	case runtime.Type_Info_Array:
		return is_plain(v.elem)
	case runtime.Type_Info_Enumerated_Array:
		return is_plain(v.elem)
	case runtime.Type_Info_Struct:
		sum := 0
		for i in 0 ..< int(v.field_count) {
			if !is_plain(v.types[i]) { return false }
			sum += v.types[i].size
		}
		return sum == t.size
	}
	return false
}

////////////////////////////////
// Field access

@(private)
fa :: #force_inline proc(p: ^$T) -> any { return transmute(any)runtime.Raw_Any{data = p, id = T} }

// The field(s) holding property `p` in `c`.
prop_fields :: proc(c: ^Computed, p: Prop) -> (a: any, b: any) {
	switch p {
	case .Color_Scheme: return fa(&c.color_scheme), fa(&c.used_scheme)
	case .Font_Size: return fa(&c.font_size), fa(&c.font_size_src)
	case .Color: return fa(&c.color), fa(&c.color_pair)
	case .Font_Family: return fa(&c.font_family), nil
	case .Font_Weight: return fa(&c.font_weight), nil
	case .Font_Style: return fa(&c.font_style), nil
	case .Font_Stretch: return fa(&c.font_stretch), nil
	case .Font_Variant_Caps: return fa(&c.font_variant_caps), nil
	case .Line_Height: return fa(&c.line_height), nil
	case .Letter_Spacing: return fa(&c.letter_spacing), nil
	case .Word_Spacing: return fa(&c.word_spacing), nil
	case .Text_Align: return fa(&c.text_align), nil
	case .Text_Decoration_Line: return fa(&c.text_decoration), nil
	case .Text_Decoration_Color: return fa(&c.text_decoration_color), nil
	case .Text_Decoration_Style: return fa(&c.text_decoration_style), nil
	case .Text_Decoration_Thickness: return fa(&c.text_decoration_thickness), nil
	case .Text_Underline_Offset: return fa(&c.text_underline_offset), nil
	case .Text_Underline_Position: return fa(&c.text_underline_position), nil
	case .Text_Decoration_Skip_Ink: return fa(&c.text_decoration_skip_ink), nil
	case .Text_Decoration_Skip_Spaces: return fa(&c.text_decoration_skip_spaces), nil
	case .Text_Decoration_Inset: return fa(&c.text_decoration_inset), nil
	case .Text_Emphasis_Style: return fa(&c.text_emphasis_style), nil
	case .Text_Emphasis_Color: return fa(&c.text_emphasis_color), nil
	case .Text_Emphasis_Position: return fa(&c.text_emphasis_position), nil
	case .Text_Emphasis_Skip: return fa(&c.text_emphasis_skip), nil
	case .Text_Stroke_Width: return fa(&c.text_stroke_width), nil
	case .Text_Stroke_Color: return fa(&c.text_stroke_color), nil
	case .Text_Transform: return fa(&c.text_transform), nil
	case .Text_Indent: return fa(&c.text_indent), nil
	case .Text_Overflow: return fa(&c.text_ellipsis), nil
	case .White_Space_Collapse: return fa(&c.white_space_collapse), nil
	case .Text_Wrap_Mode: return fa(&c.text_wrap_mode), nil
	case .Text_Wrap_Style: return fa(&c.text_wrap_style), nil
	case .Word_Break: return fa(&c.word_break), nil
	case .Overflow_Wrap: return fa(&c.overflow_wrap), nil
	case .Hyphens: return fa(&c.hyphens), nil
	case .Tab_Size: return fa(&c.tab_size), fa(&c.tab_spaces)
	case .Direction: return fa(&c.direction), nil
	case .Text_Shadow: return fa(&c.text_shadow), nil
	case .Font_Feature_Settings: return fa(&c.font_feature_settings), nil
	case .Font_Variation_Settings: return fa(&c.font_variation_settings), nil
	case .Font_Kerning: return fa(&c.font_kerning), nil
	case .Font_Variant_Ligatures: return fa(&c.font_variant_ligatures), nil
	case .Font_Variant_Numeric: return fa(&c.font_variant_numeric), nil
	case .Font_Variant_East_Asian: return fa(&c.font_variant_east_asian), nil
	case .Font_Variant_Position: return fa(&c.font_variant_position), nil
	case .Font_Optical_Sizing: return fa(&c.font_optical_sizing), nil
	case .Text_Rendering: return fa(&c.text_rendering), nil
	case .Unicode_Bidi: return fa(&c.unicode_bidi), nil
	case .Display: return fa(&c.display), nil
	case .Position: return fa(&c.position), nil
	case .Float: return fa(&c.float), nil
	case .Clear: return fa(&c.clear), nil
	case .Top: return fa(&c.inset[.Top]), nil
	case .Right: return fa(&c.inset[.Right]), nil
	case .Bottom: return fa(&c.inset[.Bottom]), nil
	case .Left: return fa(&c.inset[.Left]), nil
	case .Z_Index: return fa(&c.z_auto), fa(&c.z_index)
	case .Box_Sizing: return fa(&c.box_sizing), nil
	case .Width: return fa(&c.width), nil
	case .Height: return fa(&c.height), nil
	case .Min_Width: return fa(&c.min_width), nil
	case .Min_Height: return fa(&c.min_height), nil
	case .Max_Width: return fa(&c.max_width), nil
	case .Max_Height: return fa(&c.max_height), nil
	case .Margin_Top: return fa(&c.margin[.Top]), nil
	case .Margin_Right: return fa(&c.margin[.Right]), nil
	case .Margin_Bottom: return fa(&c.margin[.Bottom]), nil
	case .Margin_Left: return fa(&c.margin[.Left]), nil
	case .Padding_Top: return fa(&c.padding[.Top]), nil
	case .Padding_Right: return fa(&c.padding[.Right]), nil
	case .Padding_Bottom: return fa(&c.padding[.Bottom]), nil
	case .Padding_Left: return fa(&c.padding[.Left]), nil
	case .Border_Top_Style: return fa(&c.border_style[.Top]), nil
	case .Border_Right_Style: return fa(&c.border_style[.Right]), nil
	case .Border_Bottom_Style: return fa(&c.border_style[.Bottom]), nil
	case .Border_Left_Style: return fa(&c.border_style[.Left]), nil
	case .Border_Top_Width: return fa(&c.border_width[.Top]), nil
	case .Border_Right_Width: return fa(&c.border_width[.Right]), nil
	case .Border_Bottom_Width: return fa(&c.border_width[.Bottom]), nil
	case .Border_Left_Width: return fa(&c.border_width[.Left]), nil
	case .Border_Top_Color: return fa(&c.border_color[.Top]), nil
	case .Border_Right_Color: return fa(&c.border_color[.Right]), nil
	case .Border_Bottom_Color: return fa(&c.border_color[.Bottom]), nil
	case .Border_Left_Color: return fa(&c.border_color[.Left]), nil
	case .Border_Top_Left_Radius: return fa(&c.radius[.Top_Left]), nil
	case .Border_Top_Right_Radius: return fa(&c.radius[.Top_Right]), nil
	case .Border_Bottom_Right_Radius: return fa(&c.radius[.Bottom_Right]), nil
	case .Border_Bottom_Left_Radius: return fa(&c.radius[.Bottom_Left]), nil
	case .Overflow_X: return fa(&c.overflow_x), nil
	case .Overflow_Y: return fa(&c.overflow_y), nil
	case .Visibility: return fa(&c.visibility), nil
	case .Opacity: return fa(&c.opacity), nil
	case .Vertical_Align: return fa(&c.vertical_align), nil
	case .Aspect_Ratio: return fa(&c.aspect_ratio), fa(&c.aspect_ratio_auto)
	case .Object_Fit: return fa(&c.object_fit), nil
	case .Flex_Direction: return fa(&c.flex_direction), nil
	case .Flex_Wrap: return fa(&c.flex_wrap), nil
	case .Flex_Grow: return fa(&c.flex_grow), nil
	case .Flex_Shrink: return fa(&c.flex_shrink), nil
	case .Flex_Basis: return fa(&c.flex_basis), nil
	case .Justify_Content: return fa(&c.justify_content), nil
	case .Align_Items: return fa(&c.align_items), nil
	case .Align_Self: return fa(&c.align_self), nil
	case .Align_Content: return fa(&c.align_content), nil
	case .Order: return fa(&c.order), nil
	case .Row_Gap: return fa(&c.row_gap), nil
	case .Column_Gap: return fa(&c.column_gap), nil
	case .Background_Color: return fa(&c.background_color), nil
	case .Background_Image: return fa(&c.background_image), fa(&c.background_images)
	case .Background_Repeat: return fa(&c.background_repeat), fa(&c.background_repeats)
	case .Background_Position: return fa(&c.background_position), fa(&c.background_positions)
	case .Background_Size: return fa(&c.background_size), fa(&c.background_sizes)
	case .Background_Origin: return fa(&c.background_origins), nil
	case .Background_Clip: return fa(&c.background_clips), nil
	case .Background_Attachment: return fa(&c.background_attachments), nil
	case .Box_Shadow: return fa(&c.box_shadow), nil
	case .List_Style_Type: return fa(&c.list_style_type), fa(&c.list_style)
	case .List_Style_Position: return fa(&c.list_style_position), nil
	case .Cursor: return fa(&c.cursor), fa(&c.cursor_images)
	case .Pointer_Events: return fa(&c.pointer_events), nil
	case .User_Select: return fa(&c.user_select), nil
	case .Content: return fa(&c.content), nil
	case .Outline_Width: return fa(&c.outline_width), nil
	case .Outline_Style: return fa(&c.outline_style), nil
	case .Outline_Color: return fa(&c.outline_color), nil
	case .Outline_Offset: return fa(&c.outline_offset), nil
	case .Border_Collapse: return fa(&c.border_collapse), nil
	case .Border_Spacing: return fa(&c.border_spacing), nil
	case .Transform: return fa(&c.transform), nil
	case .Transform_Origin: return fa(&c.transform_origin), nil
	case .Transform_Box: return fa(&c.transform_box), nil
	case .Transform_Style: return fa(&c.transform_style), nil
	case .Translate: return fa(&c.translate), nil
	case .Rotate: return fa(&c.rotate), nil
	case .Scale: return fa(&c.scale), nil
	case .Perspective: return fa(&c.perspective), nil
	case .Perspective_Origin: return fa(&c.perspective_origin), nil
	case .Backface_Visibility: return fa(&c.backface_visibility), nil
	case .Transition_Property: return fa(&c.transition_property), nil
	case .Transition_Duration: return fa(&c.transition_duration), nil
	case .Transition_Timing_Function: return fa(&c.transition_timing), nil
	case .Transition_Delay: return fa(&c.transition_delay), nil
	case .Transition_Behavior: return fa(&c.transition_behavior), nil
	case .Animation_Name: return fa(&c.animation_name), nil
	case .Animation_Duration: return fa(&c.animation_duration), nil
	case .Animation_Timing_Function: return fa(&c.animation_timing), nil
	case .Animation_Delay: return fa(&c.animation_delay), nil
	case .Animation_Iteration_Count: return fa(&c.animation_iterations), nil
	case .Animation_Direction: return fa(&c.animation_direction), nil
	case .Animation_Fill_Mode: return fa(&c.animation_fill_mode), nil
	case .Animation_Play_State: return fa(&c.animation_play_state), nil
	case .Animation_Composition: return fa(&c.animation_composition), nil
	case .Animation_Timeline: return fa(&c.animation_timeline), nil
	case .Animation_Range_Start: return fa(&c.animation_range_start), nil
	case .Animation_Range_End: return fa(&c.animation_range_end), nil
	case .Scroll_Timeline_Name: return fa(&c.scroll_timeline_name), nil
	case .Scroll_Timeline_Axis: return fa(&c.scroll_timeline_axis), nil
	case .View_Timeline_Name: return fa(&c.view_timeline_name), nil
	case .View_Timeline_Axis: return fa(&c.view_timeline_axis), nil
	case .View_Timeline_Inset: return fa(&c.view_timeline_inset), nil
	case .Timeline_Scope: return fa(&c.timeline_scope), nil
	case .Counter_Reset: return fa(&c.counter_reset), nil
	case .Counter_Increment: return fa(&c.counter_increment), nil
	case .Counter_Set: return fa(&c.counter_set), nil
	case .Quotes: return fa(&c.quotes), nil
	case .Object_Position: return fa(&c.object_position), nil
	case .Filter: return fa(&c.filter), nil
	case .Backdrop_Filter: return fa(&c.backdrop_filter), nil
	case .Clip_Path: return fa(&c.clip_path), nil
	case .Clip: return fa(&c.clip), nil
	case .Isolation: return fa(&c.isolation), nil
	case .Mix_Blend_Mode: return fa(&c.mix_blend_mode), nil
	case .Will_Change: return fa(&c.will_change), nil
	case .Contain: return fa(&c.contain), nil
	case .Touch_Action: return fa(&c.touch_action), nil
	case .Content_Visibility: return fa(&c.content_visibility), nil
	case .Scroll_Behavior: return fa(&c.scroll_behavior), nil
	case .Overflow_Anchor: return fa(&c.overflow_anchor), nil
	case .Overscroll_Behavior_X: return fa(&c.overscroll_x), nil
	case .Overscroll_Behavior_Y: return fa(&c.overscroll_y), nil
	case .Caret_Color: return fa(&c.caret_color), nil
	case .Accent_Color: return fa(&c.accent_color), nil
	case .Appearance: return fa(&c.appearance), nil
	case .Resize: return fa(&c.resize), nil
	case .Table_Layout: return fa(&c.table_layout), nil
	case .Column_Count: return fa(&c.column_count), nil
	case .Column_Width: return fa(&c.column_width), nil
	case .Column_Span: return fa(&c.column_span), nil
	case .Column_Fill: return fa(&c.column_fill), nil
	case .Column_Rule_Width: return fa(&c.column_rule_width), nil
	case .Column_Rule_Style: return fa(&c.column_rule_style), nil
	case .Column_Rule_Color: return fa(&c.column_rule_color), nil
	case .Break_Before: return fa(&c.break_before), nil
	case .Break_After: return fa(&c.break_after), nil
	case .Break_Inside: return fa(&c.break_inside), nil
	case .Orphans: return fa(&c.orphans), nil
	case .Widows: return fa(&c.widows), nil
	case .Writing_Mode: return fa(&c.writing_mode), nil
	case .Text_Orientation: return fa(&c.text_orientation), nil
	case .Text_Combine_Upright: return fa(&c.text_combine_upright), nil
	case .Grid_Template_Columns: return fa(&c.grid_template_columns), nil
	case .Grid_Template_Rows: return fa(&c.grid_template_rows), nil
	case .Grid_Template_Areas: return fa(&c.grid_template_areas), nil
	case .Grid_Auto_Columns: return fa(&c.grid_auto_columns), nil
	case .Grid_Auto_Rows: return fa(&c.grid_auto_rows), nil
	case .Grid_Auto_Flow: return fa(&c.grid_auto_flow), nil
	case .Grid_Row_Start: return fa(&c.grid_row_start), nil
	case .Grid_Row_End: return fa(&c.grid_row_end), nil
	case .Grid_Column_Start: return fa(&c.grid_column_start), nil
	case .Grid_Column_End: return fa(&c.grid_column_end), nil
	case .Justify_Items: return fa(&c.justify_items), nil
	case .Justify_Self: return fa(&c.justify_self), nil
	case .Container_Type: return fa(&c.container_type), nil
	case .Container_Name: return fa(&c.container_name), nil
	case .Scrollbar_Width: return fa(&c.scrollbar_width), nil
	case .Scrollbar_Color: return fa(&c.scrollbar_color), nil
	case .Scrollbar_Gutter: return fa(&c.scrollbar_gutter), nil
	case .Mask_Image: return fa(&c.mask_images), nil
	case .Mask_Mode: return fa(&c.mask_modes), nil
	case .Mask_Repeat: return fa(&c.mask_repeats), nil
	case .Mask_Position: return fa(&c.mask_positions), nil
	case .Mask_Size: return fa(&c.mask_sizes), nil
	case .Mask_Origin: return fa(&c.mask_origins), nil
	case .Mask_Clip: return fa(&c.mask_clips), nil
	case .Mask_Composite: return fa(&c.mask_composites), nil
	case .Text_Fill_Color: return fa(&c.text_fill_color), nil
	case .Fill: return fa(&c.svg_fill), nil
	case .Stroke: return fa(&c.svg_stroke), nil
	case .Stroke_Width: return fa(&c.stroke_width), nil
	case .Stroke_Linecap: return fa(&c.stroke_linecap), nil
	case .Stroke_Linejoin: return fa(&c.stroke_linejoin), nil
	case .Wren_Shader: return fa(&c.wren_shader), nil
	case .Anchor_Name: return fa(&c.anchor_name), nil
	case .Anchor_Scope: return fa(&c.anchor_scope), nil
	case .Position_Anchor: return fa(&c.position_anchor), nil
	case .Position_Area: return fa(&c.position_area), nil
	case .Position_Try_Fallbacks: return fa(&c.position_try_fallbacks), nil
	case .Position_Try_Order: return fa(&c.position_try_order), nil
	case .Position_Visibility: return fa(&c.position_visibility), nil
	}
	return nil, nil
}

@(private)
field_size :: #force_inline proc(a: any) -> int { return type_info_of(a.id).size }

// Copies one property from `src` into `dst` (inherit, initial, unset and inheritance itself all use it). Shallow: pointers
// are shared, which is right inside one `Styled` arena. A property of a group: `dst` owns its group (cx_take,
// prop_take), or shares the very group of `src` (nothing to copy).
copy_prop :: proc(dst, src: ^Computed, p: Prop) {
	sl := &prop_slots[p]
	d, s := group_base(dst, sl.group), group_base(src, sl.group)
	if d == s { return }
	mem.copy(rawptr(d + sl.off[0]), rawptr(s + sl.off[0]), sl.size[0])
	if sl.size[1] > 0 { mem.copy(rawptr(d + sl.off[1]), rawptr(s + sl.off[1]), sl.size[1]) }
}

// Value equality of one property.
prop_equal :: proc(a, b: ^Computed, p: Prop) -> bool {
	sl := &prop_slots[p]
	ba, bb := group_base(a, sl.group), group_base(b, sl.group)
	if ba == bb { return true }
	for k in 0 ..< 2 {
		if sl.size[k] == 0 { continue }
		if !deep_equal(rawptr(ba + sl.off[k]), rawptr(bb + sl.off[k]), sl.ti[k]) { return false }
	}
	return true
}

// Copies one property and everything it points to into `alloc`, so the value outlives the source's arena. `dst` gets
// its own copy of the property's group.
clone_prop :: proc(dst, src: ^Computed, p: Prop, alloc: runtime.Allocator) {
	prop_take(dst, p, alloc)
	copy_prop(dst, src, p)
	da, db := prop_fields(dst, p)
	deep_clone(da.data, type_info_of(da.id), alloc)
	if db.data != nil { deep_clone(db.data, type_info_of(db.id), alloc) }
}

////////////////////////////////
// Reflection helpers

// Structural equality: slices and strings by content, pointers by what they point to (computed styles and custom
// properties by their own comparisons), floats by value.
deep_equal :: proc(a, b: rawptr, ti: ^runtime.Type_Info) -> bool {
	if a == b { return true }
	t := runtime.type_info_base(ti)
	#partial switch v in t.variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			off := v.offsets[i]
			if !deep_equal(rawptr(uintptr(a) + off), rawptr(uintptr(b) + off), v.types[i]) { return false }
		}
		return true
	case runtime.Type_Info_Array:
		if is_plain(v.elem) { return mem.compare_ptrs(a, b, t.size) == 0 }
		for i in 0 ..< v.count {
			off := uintptr(i * v.elem_size)
			if !deep_equal(rawptr(uintptr(a) + off), rawptr(uintptr(b) + off), v.elem) { return false }
		}
		return true
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< v.count {
			off := uintptr(i * v.elem_size)
			if !deep_equal(rawptr(uintptr(a) + off), rawptr(uintptr(b) + off), v.elem) { return false }
		}
		return true
	case runtime.Type_Info_Slice:
		sa, sb := (^runtime.Raw_Slice)(a), (^runtime.Raw_Slice)(b)
		if sa.len != sb.len { return false }
		if sa.data == sb.data || sa.len == 0 { return true }
		for i in 0 ..< sa.len {
			off := uintptr(i * v.elem_size)
			if !deep_equal(rawptr(uintptr(sa.data) + off), rawptr(uintptr(sb.data) + off), v.elem) { return false }
		}
		return true
	case runtime.Type_Info_String:
		return (^string)(a)^ == (^string)(b)^
	case runtime.Type_Info_Pointer:
		pa, pb := (^rawptr)(a)^, (^rawptr)(b)^
		if pa == pb { return true }
		if pa == nil || pb == nil || v.elem == nil { return false }
		switch v.elem.id {
		case Computed: return computed_equal((^Computed)(pa), (^Computed)(pb))
		case Custom_Props: return custom_equal((^Custom_Props)(pa), (^Custom_Props)(pb))
		}
		return deep_equal(pa, pb, v.elem)
	case runtime.Type_Info_Float:
		switch t.size {
		case 4: return (^f32)(a)^ == (^f32)(b)^
		case 8: return (^f64)(a)^ == (^f64)(b)^
		}
	case runtime.Type_Info_Map, runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Union, runtime.Type_Info_Any:
		return false   // not used in computed values; conservative
	}
	return mem.compare_ptrs(a, b, t.size) == 0
}

// Replaces every pointer reachable from `p` by a copy in `alloc` (strings, slices, calc trees, gradients...). Computed
// styles and custom property maps are left shared: they are not part of a property value.
deep_clone :: proc(p: rawptr, ti: ^runtime.Type_Info, alloc: runtime.Allocator) {
	t := runtime.type_info_base(ti)
	#partial switch v in t.variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) { deep_clone(rawptr(uintptr(p) + v.offsets[i]), v.types[i], alloc) }
	case runtime.Type_Info_Array:
		if is_plain(v.elem) { return }
		for i in 0 ..< v.count { deep_clone(rawptr(uintptr(p) + uintptr(i * v.elem_size)), v.elem, alloc) }
	case runtime.Type_Info_Enumerated_Array:
		if is_plain(v.elem) { return }
		for i in 0 ..< v.count { deep_clone(rawptr(uintptr(p) + uintptr(i * v.elem_size)), v.elem, alloc) }
	case runtime.Type_Info_Slice:
		s := (^runtime.Raw_Slice)(p)
		if s.len == 0 || s.data == nil { s.data = nil; s.len = 0; return }
		n := s.len * v.elem_size
		data, _ := mem.alloc(n, v.elem.align, alloc)
		mem.copy(data, s.data, n)
		s.data = data
		for i in 0 ..< s.len { deep_clone(rawptr(uintptr(data) + uintptr(i * v.elem_size)), v.elem, alloc) }
	case runtime.Type_Info_String:
		s := (^string)(p)
		if len(s^) == 0 { s^ = ""; return }
		b := make([]u8, len(s^), alloc)
		copy(b, s^)
		s^ = string(b)
	case runtime.Type_Info_Pointer:
		pp := (^rawptr)(p)
		if pp^ == nil || v.elem == nil { return }
		switch v.elem.id {
		case Computed, Custom_Props: return
		}
		data, _ := mem.alloc(v.elem.size, v.elem.align, alloc)
		mem.copy(data, pp^, v.elem.size)
		pp^ = data
		deep_clone(data, v.elem, alloc)
	}
}

