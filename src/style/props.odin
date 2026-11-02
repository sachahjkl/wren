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

@(private)
NO_FIELD :: any{}

// The field(s) holding property `p` in `c`.
prop_fields :: proc(c: ^Computed, p: Prop) -> (a: any, b: any) {
	switch p {
	case .Color_Scheme: return fa(&c.color_scheme), fa(&c.used_scheme)
	case .Font_Size: return fa(&c.font_size), fa(&c.font_size_src)
	case .Color: return fa(&c.color), fa(&c.color_pair)
	case .Font_Family: return fa(&c.font_family), NO_FIELD
	case .Font_Weight: return fa(&c.font_weight), NO_FIELD
	case .Font_Style: return fa(&c.font_style), NO_FIELD
	case .Font_Stretch: return fa(&c.font_stretch), NO_FIELD
	case .Font_Variant_Caps: return fa(&c.font_variant_caps), NO_FIELD
	case .Line_Height: return fa(&c.line_height), NO_FIELD
	case .Letter_Spacing: return fa(&c.letter_spacing), NO_FIELD
	case .Word_Spacing: return fa(&c.word_spacing), NO_FIELD
	case .Text_Align: return fa(&c.text_align), NO_FIELD
	case .Text_Decoration_Line: return fa(&c.text_decoration), NO_FIELD
	case .Text_Decoration_Color: return fa(&c.text_decoration_color), NO_FIELD
	case .Text_Decoration_Style: return fa(&c.text_decoration_style), NO_FIELD
	case .Text_Decoration_Thickness: return fa(&c.text_decoration_thickness), NO_FIELD
	case .Text_Underline_Offset: return fa(&c.text_underline_offset), NO_FIELD
	case .Text_Transform: return fa(&c.text_transform), NO_FIELD
	case .Text_Indent: return fa(&c.text_indent), NO_FIELD
	case .Text_Overflow: return fa(&c.text_ellipsis), NO_FIELD
	case .White_Space_Collapse: return fa(&c.white_space_collapse), NO_FIELD
	case .Text_Wrap_Mode: return fa(&c.text_wrap_mode), NO_FIELD
	case .Text_Wrap_Style: return fa(&c.text_wrap_style), NO_FIELD
	case .Word_Break: return fa(&c.word_break), NO_FIELD
	case .Overflow_Wrap: return fa(&c.overflow_wrap), NO_FIELD
	case .Hyphens: return fa(&c.hyphens), NO_FIELD
	case .Tab_Size: return fa(&c.tab_size), fa(&c.tab_spaces)
	case .Direction: return fa(&c.direction), NO_FIELD
	case .Text_Shadow: return fa(&c.text_shadow), NO_FIELD
	case .Font_Feature_Settings: return fa(&c.font_feature_settings), NO_FIELD
	case .Font_Variation_Settings: return fa(&c.font_variation_settings), NO_FIELD
	case .Font_Kerning: return fa(&c.font_kerning), NO_FIELD
	case .Font_Variant_Ligatures: return fa(&c.font_variant_ligatures), NO_FIELD
	case .Font_Variant_Numeric: return fa(&c.font_variant_numeric), NO_FIELD
	case .Font_Variant_East_Asian: return fa(&c.font_variant_east_asian), NO_FIELD
	case .Font_Variant_Position: return fa(&c.font_variant_position), NO_FIELD
	case .Font_Optical_Sizing: return fa(&c.font_optical_sizing), NO_FIELD
	case .Text_Rendering: return fa(&c.text_rendering), NO_FIELD
	case .Unicode_Bidi: return fa(&c.unicode_bidi), NO_FIELD
	case .Display: return fa(&c.display), NO_FIELD
	case .Position: return fa(&c.position), NO_FIELD
	case .Float: return fa(&c.float), NO_FIELD
	case .Clear: return fa(&c.clear), NO_FIELD
	case .Top: return fa(&c.inset[.Top]), NO_FIELD
	case .Right: return fa(&c.inset[.Right]), NO_FIELD
	case .Bottom: return fa(&c.inset[.Bottom]), NO_FIELD
	case .Left: return fa(&c.inset[.Left]), NO_FIELD
	case .Z_Index: return fa(&c.z_auto), fa(&c.z_index)
	case .Box_Sizing: return fa(&c.box_sizing), NO_FIELD
	case .Width: return fa(&c.width), NO_FIELD
	case .Height: return fa(&c.height), NO_FIELD
	case .Min_Width: return fa(&c.min_width), NO_FIELD
	case .Min_Height: return fa(&c.min_height), NO_FIELD
	case .Max_Width: return fa(&c.max_width), NO_FIELD
	case .Max_Height: return fa(&c.max_height), NO_FIELD
	case .Margin_Top: return fa(&c.margin[.Top]), NO_FIELD
	case .Margin_Right: return fa(&c.margin[.Right]), NO_FIELD
	case .Margin_Bottom: return fa(&c.margin[.Bottom]), NO_FIELD
	case .Margin_Left: return fa(&c.margin[.Left]), NO_FIELD
	case .Padding_Top: return fa(&c.padding[.Top]), NO_FIELD
	case .Padding_Right: return fa(&c.padding[.Right]), NO_FIELD
	case .Padding_Bottom: return fa(&c.padding[.Bottom]), NO_FIELD
	case .Padding_Left: return fa(&c.padding[.Left]), NO_FIELD
	case .Border_Top_Style: return fa(&c.border_style[.Top]), NO_FIELD
	case .Border_Right_Style: return fa(&c.border_style[.Right]), NO_FIELD
	case .Border_Bottom_Style: return fa(&c.border_style[.Bottom]), NO_FIELD
	case .Border_Left_Style: return fa(&c.border_style[.Left]), NO_FIELD
	case .Border_Top_Width: return fa(&c.border_width[.Top]), NO_FIELD
	case .Border_Right_Width: return fa(&c.border_width[.Right]), NO_FIELD
	case .Border_Bottom_Width: return fa(&c.border_width[.Bottom]), NO_FIELD
	case .Border_Left_Width: return fa(&c.border_width[.Left]), NO_FIELD
	case .Border_Top_Color: return fa(&c.border_color[.Top]), NO_FIELD
	case .Border_Right_Color: return fa(&c.border_color[.Right]), NO_FIELD
	case .Border_Bottom_Color: return fa(&c.border_color[.Bottom]), NO_FIELD
	case .Border_Left_Color: return fa(&c.border_color[.Left]), NO_FIELD
	case .Border_Top_Left_Radius: return fa(&c.radius[.Top_Left]), NO_FIELD
	case .Border_Top_Right_Radius: return fa(&c.radius[.Top_Right]), NO_FIELD
	case .Border_Bottom_Right_Radius: return fa(&c.radius[.Bottom_Right]), NO_FIELD
	case .Border_Bottom_Left_Radius: return fa(&c.radius[.Bottom_Left]), NO_FIELD
	case .Overflow_X: return fa(&c.overflow_x), NO_FIELD
	case .Overflow_Y: return fa(&c.overflow_y), NO_FIELD
	case .Visibility: return fa(&c.visibility), NO_FIELD
	case .Opacity: return fa(&c.opacity), NO_FIELD
	case .Vertical_Align: return fa(&c.vertical_align), NO_FIELD
	case .Aspect_Ratio: return fa(&c.aspect_ratio), fa(&c.aspect_ratio_auto)
	case .Object_Fit: return fa(&c.object_fit), NO_FIELD
	case .Flex_Direction: return fa(&c.flex_direction), NO_FIELD
	case .Flex_Wrap: return fa(&c.flex_wrap), NO_FIELD
	case .Flex_Grow: return fa(&c.flex_grow), NO_FIELD
	case .Flex_Shrink: return fa(&c.flex_shrink), NO_FIELD
	case .Flex_Basis: return fa(&c.flex_basis), NO_FIELD
	case .Justify_Content: return fa(&c.justify_content), NO_FIELD
	case .Align_Items: return fa(&c.align_items), NO_FIELD
	case .Align_Self: return fa(&c.align_self), NO_FIELD
	case .Align_Content: return fa(&c.align_content), NO_FIELD
	case .Order: return fa(&c.order), NO_FIELD
	case .Row_Gap: return fa(&c.row_gap), NO_FIELD
	case .Column_Gap: return fa(&c.column_gap), NO_FIELD
	case .Background_Color: return fa(&c.background_color), NO_FIELD
	case .Background_Image: return fa(&c.background_image), fa(&c.background_images)
	case .Background_Repeat: return fa(&c.background_repeat), fa(&c.background_repeats)
	case .Background_Position: return fa(&c.background_position), fa(&c.background_positions)
	case .Background_Size: return fa(&c.background_size), fa(&c.background_sizes)
	case .Background_Origin: return fa(&c.background_origins), NO_FIELD
	case .Background_Clip: return fa(&c.background_clips), NO_FIELD
	case .Background_Attachment: return fa(&c.background_attachments), NO_FIELD
	case .Box_Shadow: return fa(&c.box_shadow), NO_FIELD
	case .List_Style_Type: return fa(&c.list_style_type), fa(&c.list_style)
	case .List_Style_Position: return fa(&c.list_style_position), NO_FIELD
	case .Cursor: return fa(&c.cursor), fa(&c.cursor_images)
	case .Pointer_Events: return fa(&c.pointer_events), NO_FIELD
	case .User_Select: return fa(&c.user_select), NO_FIELD
	case .Content: return fa(&c.content), NO_FIELD
	case .Outline_Width: return fa(&c.outline_width), NO_FIELD
	case .Outline_Style: return fa(&c.outline_style), NO_FIELD
	case .Outline_Color: return fa(&c.outline_color), NO_FIELD
	case .Outline_Offset: return fa(&c.outline_offset), NO_FIELD
	case .Border_Collapse: return fa(&c.border_collapse), NO_FIELD
	case .Border_Spacing: return fa(&c.border_spacing), NO_FIELD
	case .Transform: return fa(&c.transform), NO_FIELD
	case .Transform_Origin: return fa(&c.transform_origin), NO_FIELD
	case .Transform_Box: return fa(&c.transform_box), NO_FIELD
	case .Transform_Style: return fa(&c.transform_style), NO_FIELD
	case .Translate: return fa(&c.translate), NO_FIELD
	case .Rotate: return fa(&c.rotate), NO_FIELD
	case .Scale: return fa(&c.scale), NO_FIELD
	case .Perspective: return fa(&c.perspective), NO_FIELD
	case .Perspective_Origin: return fa(&c.perspective_origin), NO_FIELD
	case .Backface_Visibility: return fa(&c.backface_visibility), NO_FIELD
	case .Transition_Property: return fa(&c.transition_property), NO_FIELD
	case .Transition_Duration: return fa(&c.transition_duration), NO_FIELD
	case .Transition_Timing_Function: return fa(&c.transition_timing), NO_FIELD
	case .Transition_Delay: return fa(&c.transition_delay), NO_FIELD
	case .Transition_Behavior: return fa(&c.transition_behavior), NO_FIELD
	case .Animation_Name: return fa(&c.animation_name), NO_FIELD
	case .Animation_Duration: return fa(&c.animation_duration), NO_FIELD
	case .Animation_Timing_Function: return fa(&c.animation_timing), NO_FIELD
	case .Animation_Delay: return fa(&c.animation_delay), NO_FIELD
	case .Animation_Iteration_Count: return fa(&c.animation_iterations), NO_FIELD
	case .Animation_Direction: return fa(&c.animation_direction), NO_FIELD
	case .Animation_Fill_Mode: return fa(&c.animation_fill_mode), NO_FIELD
	case .Animation_Play_State: return fa(&c.animation_play_state), NO_FIELD
	case .Animation_Composition: return fa(&c.animation_composition), NO_FIELD
	case .Counter_Reset: return fa(&c.counter_reset), NO_FIELD
	case .Counter_Increment: return fa(&c.counter_increment), NO_FIELD
	case .Counter_Set: return fa(&c.counter_set), NO_FIELD
	case .Quotes: return fa(&c.quotes), NO_FIELD
	case .Object_Position: return fa(&c.object_position), NO_FIELD
	case .Filter: return fa(&c.filter), NO_FIELD
	case .Backdrop_Filter: return fa(&c.backdrop_filter), NO_FIELD
	case .Clip_Path: return fa(&c.clip_path), NO_FIELD
	case .Isolation: return fa(&c.isolation), NO_FIELD
	case .Mix_Blend_Mode: return fa(&c.mix_blend_mode), NO_FIELD
	case .Will_Change: return fa(&c.will_change), NO_FIELD
	case .Contain: return fa(&c.contain), NO_FIELD
	case .Touch_Action: return fa(&c.touch_action), NO_FIELD
	case .Content_Visibility: return fa(&c.content_visibility), NO_FIELD
	case .Scroll_Behavior: return fa(&c.scroll_behavior), NO_FIELD
	case .Overscroll_Behavior_X: return fa(&c.overscroll_x), NO_FIELD
	case .Overscroll_Behavior_Y: return fa(&c.overscroll_y), NO_FIELD
	case .Caret_Color: return fa(&c.caret_color), NO_FIELD
	case .Accent_Color: return fa(&c.accent_color), NO_FIELD
	case .Appearance: return fa(&c.appearance), NO_FIELD
	case .Resize: return fa(&c.resize), NO_FIELD
	case .Table_Layout: return fa(&c.table_layout), NO_FIELD
	case .Column_Count: return fa(&c.column_count), NO_FIELD
	case .Column_Width: return fa(&c.column_width), NO_FIELD
	case .Column_Span: return fa(&c.column_span), NO_FIELD
	case .Column_Fill: return fa(&c.column_fill), NO_FIELD
	case .Column_Rule_Width: return fa(&c.column_rule_width), NO_FIELD
	case .Column_Rule_Style: return fa(&c.column_rule_style), NO_FIELD
	case .Column_Rule_Color: return fa(&c.column_rule_color), NO_FIELD
	case .Break_Before: return fa(&c.break_before), NO_FIELD
	case .Break_After: return fa(&c.break_after), NO_FIELD
	case .Break_Inside: return fa(&c.break_inside), NO_FIELD
	case .Orphans: return fa(&c.orphans), NO_FIELD
	case .Widows: return fa(&c.widows), NO_FIELD
	case .Writing_Mode: return fa(&c.writing_mode), NO_FIELD
	case .Text_Orientation: return fa(&c.text_orientation), NO_FIELD
	case .Text_Combine_Upright: return fa(&c.text_combine_upright), NO_FIELD
	case .Grid_Template_Columns: return fa(&c.grid_template_columns), NO_FIELD
	case .Grid_Template_Rows: return fa(&c.grid_template_rows), NO_FIELD
	case .Grid_Template_Areas: return fa(&c.grid_template_areas), NO_FIELD
	case .Grid_Auto_Columns: return fa(&c.grid_auto_columns), NO_FIELD
	case .Grid_Auto_Rows: return fa(&c.grid_auto_rows), NO_FIELD
	case .Grid_Auto_Flow: return fa(&c.grid_auto_flow), NO_FIELD
	case .Grid_Row_Start: return fa(&c.grid_row_start), NO_FIELD
	case .Grid_Row_End: return fa(&c.grid_row_end), NO_FIELD
	case .Grid_Column_Start: return fa(&c.grid_column_start), NO_FIELD
	case .Grid_Column_End: return fa(&c.grid_column_end), NO_FIELD
	case .Justify_Items: return fa(&c.justify_items), NO_FIELD
	case .Justify_Self: return fa(&c.justify_self), NO_FIELD
	case .Container_Type: return fa(&c.container_type), NO_FIELD
	case .Container_Name: return fa(&c.container_name), NO_FIELD
	case .Scrollbar_Width: return fa(&c.scrollbar_width), NO_FIELD
	case .Scrollbar_Color: return fa(&c.scrollbar_color), NO_FIELD
	case .Scrollbar_Gutter: return fa(&c.scrollbar_gutter), NO_FIELD
	case .Mask_Image: return fa(&c.mask_images), NO_FIELD
	case .Mask_Mode: return fa(&c.mask_modes), NO_FIELD
	case .Mask_Repeat: return fa(&c.mask_repeats), NO_FIELD
	case .Mask_Position: return fa(&c.mask_positions), NO_FIELD
	case .Mask_Size: return fa(&c.mask_sizes), NO_FIELD
	case .Mask_Origin: return fa(&c.mask_origins), NO_FIELD
	case .Mask_Clip: return fa(&c.mask_clips), NO_FIELD
	case .Mask_Composite: return fa(&c.mask_composites), NO_FIELD
	case .Text_Fill_Color: return fa(&c.text_fill_color), NO_FIELD
	case .Fill: return fa(&c.svg_fill), NO_FIELD
	case .Stroke: return fa(&c.svg_stroke), NO_FIELD
	case .Stroke_Width: return fa(&c.stroke_width), NO_FIELD
	case .Stroke_Linecap: return fa(&c.stroke_linecap), NO_FIELD
	case .Stroke_Linejoin: return fa(&c.stroke_linejoin), NO_FIELD
	case .Wren_Shader: return fa(&c.wren_shader), NO_FIELD
	case .Anchor_Name: return fa(&c.anchor_name), NO_FIELD
	case .Anchor_Scope: return fa(&c.anchor_scope), NO_FIELD
	case .Position_Anchor: return fa(&c.position_anchor), NO_FIELD
	case .Position_Area: return fa(&c.position_area), NO_FIELD
	case .Position_Try_Fallbacks: return fa(&c.position_try_fallbacks), NO_FIELD
	case .Position_Try_Order: return fa(&c.position_try_order), NO_FIELD
	case .Position_Visibility: return fa(&c.position_visibility), NO_FIELD
	}
	return NO_FIELD, NO_FIELD
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

