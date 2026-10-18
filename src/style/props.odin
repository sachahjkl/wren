package style

import "base:runtime"
import "core:mem"
import "core:sync"

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

Field_Info :: struct {
	offset: uintptr,
	size:   int,
	ti:     ^runtime.Type_Info,
	plain:  bool,     // no pointers and no padding: equal exactly when the bytes are
}

@(private) computed_fields: [dynamic]Field_Info

// Where each property lives in a Computed: one or two (offset, size) pairs, so copying needs no dispatch.
@(private)
Prop_Slot :: struct { off: [2]uintptr, size: [2]int, ti: [2]^runtime.Type_Info }
@(private) prop_slots: [Prop]Prop_Slot

@(private)
props_init :: proc() {
	sync.once_do(&props_once, proc() {
		probe: Computed
		for p in Prop {
			a, b := prop_fields(&probe, p)
			sl := &prop_slots[p]
			sl.off[0], sl.size[0], sl.ti[0] = uintptr(a.data) - uintptr(&probe), type_info_of(a.id).size, type_info_of(a.id)
			if b.data != nil { sl.off[1], sl.size[1], sl.ti[1] = uintptr(b.data) - uintptr(&probe), type_info_of(b.id).size, type_info_of(b.id) }
		}
		for p, i in INHERITED_PROPS {
			inherited_table[p] = true
			ps_add(&inherited_set, p)
			inherited_list[i] = p
		}
		ti := runtime.type_info_base(type_info_of(Computed))
		st := ti.variant.(runtime.Type_Info_Struct)
		computed_fields = make([dynamic]Field_Info, runtime.heap_allocator())
		for i in 0 ..< int(st.field_count) {
			ft := st.types[i]
			append(&computed_fields, Field_Info{offset = st.offsets[i], size = ft.size, ti = ft, plain = is_plain(ft)})
		}
	})
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
	case .Font_Size: return fa(&c.font_size), NO_FIELD
	case .Color: return fa(&c.color), NO_FIELD
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
	case .Aspect_Ratio: return fa(&c.aspect_ratio), NO_FIELD
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
	case .Cursor: return fa(&c.cursor), NO_FIELD
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
	case .Content_Visibility: return fa(&c.content_visibility), NO_FIELD
	case .Scroll_Behavior: return fa(&c.scroll_behavior), NO_FIELD
	case .Overscroll_Behavior_X: return fa(&c.overscroll_x), NO_FIELD
	case .Overscroll_Behavior_Y: return fa(&c.overscroll_y), NO_FIELD
	case .Caret_Color: return fa(&c.caret_color), NO_FIELD
	case .Accent_Color: return fa(&c.accent_color), NO_FIELD
	case .Appearance: return fa(&c.appearance), NO_FIELD
	case .Resize: return fa(&c.resize), NO_FIELD
	case .Column_Count: return fa(&c.column_count), NO_FIELD
	case .Column_Width: return fa(&c.column_width), NO_FIELD
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
	}
	return NO_FIELD, NO_FIELD
}

@(private)
field_size :: #force_inline proc(a: any) -> int { return type_info_of(a.id).size }

// Copies one property from `src` into `dst` (inherit, initial, unset and inheritance itself all use it). Shallow: pointers
// are shared, which is right inside one `Styled` arena.
copy_prop :: proc(dst, src: ^Computed, p: Prop) {
	sl := &prop_slots[p]
	mem.copy(rawptr(uintptr(dst) + sl.off[0]), rawptr(uintptr(src) + sl.off[0]), sl.size[0])
	if sl.size[1] > 0 { mem.copy(rawptr(uintptr(dst) + sl.off[1]), rawptr(uintptr(src) + sl.off[1]), sl.size[1]) }
}

// Value equality of one property.
prop_equal :: proc(a, b: ^Computed, p: Prop) -> bool {
	sl := &prop_slots[p]
	for k in 0 ..< 2 {
		if sl.size[k] == 0 { continue }
		if !deep_equal(rawptr(uintptr(a) + sl.off[k]), rawptr(uintptr(b) + sl.off[k]), sl.ti[k]) { return false }
	}
	return true
}

// Copies one property and everything it points to into `alloc`, so the value outlives the source's arena.
clone_prop :: proc(dst, src: ^Computed, p: Prop, alloc: runtime.Allocator) {
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

