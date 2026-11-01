package style

import "core:strings"
import "core:sync"
import "wb:base"
import "wb:css"

// Writing modes (CSS Writing Modes 4) and multi-column values (CSS Multicol 1, CSS Fragmentation 3).
//
// Flow-relative properties (margin-inline-start, block-size...) are compiled under their horizontal left-to-right
// name, marked `Pre_Decl.logical`. An element that is horizontal left to right takes them as they are, which is what
// nearly every element is: the cascade pays one flag per declaration. Another element considers its declarations
// again with a map from those names to the physical properties they mean for it (`element_flow_map`), so that a flow-relative
// declaration and a physical one fight over the same value, in the order of the cascade (CSS Logical 1 §4).

COLUMN_RULE_MEDIUM_PX :: 3
ORPHANS_WIDOWS_INITIAL :: 2
ORPHANS_WIDOWS_MAX :: 1 << 16

Column_Span :: enum u8 { None, All }
Column_Fill :: enum u8 { Balance, Auto }
Break_Value :: enum u8 { Auto, Avoid, Avoid_Column, Avoid_Page, Column, Page, Left, Right, Recto, Verso, Always, All }
Break_Inside :: enum u8 { Auto, Avoid, Avoid_Column, Avoid_Page }
Writing_Mode :: enum u8 { Horizontal_Tb, Vertical_Rl, Vertical_Lr, Sideways_Rl, Sideways_Lr }
Text_Orientation :: enum u8 { Mixed, Upright, Sideways }
Text_Combine_Upright :: enum u8 { None, All }

// The block axis is horizontal: the inline axis, what lines follow, is vertical.
is_vertical_mode :: #force_inline proc "contextless" (w: Writing_Mode) -> bool { return w != .Horizontal_Tb }

@(private)
parse_writing_mode :: proc(vs: []css.Value) -> (Writing_Mode, bool) {
	id, ok := ident_raw(vs)
	if !ok { return {}, false }
	// SVG 1.1's names (CSS Writing Modes 4 §3.1)
	switch strings.to_lower(id, context.temp_allocator) {
	case "lr", "lr-tb", "rl", "rl-tb": return .Horizontal_Tb, true
	case "tb", "tb-rl": return .Vertical_Rl, true
	}
	return parse_enum(vs, Writing_Mode)
}

// `always` and `page`, `left`... force a break of any fragmentation context; in a multi-column one, what they all do
// is end the column (CSS Fragmentation 3 §3.1).
@(private)
parse_break_value :: proc(vs: []css.Value) -> (Break_Value, bool) {
	return parse_enum(vs, Break_Value)
}

// A forced break between columns.
break_is_forced :: proc(v: Break_Value) -> bool {
	#partial switch v {
	case .Auto, .Avoid, .Avoid_Column, .Avoid_Page: return false
	}
	return true
}

break_is_avoid :: proc(v: Break_Value) -> bool { return v == .Avoid || v == .Avoid_Column }
break_inside_avoid :: proc(v: Break_Inside) -> bool { return v == .Avoid || v == .Avoid_Column }

@(private)
is_border_style_value :: proc(v: css.Value) -> bool {
	if v.kind != .Token || v.tok.kind != .Ident { return false }
	one := [1]css.Value{v}
	_, ok := parse_enum(one[:], Border_Style)
	return ok
}

@(private)
is_line_width_value :: proc(v: css.Value) -> bool {
	if v.kind == .Token {
		#partial switch v.tok.kind {
		case .Dimension, .Number: return true
		case .Ident: return is_ident(v, "thin") || is_ident(v, "medium") || is_ident(v, "thick")
		}
		return false
	}
	return v.kind == .Function && (strings.equal_fold(v.tok.text, "calc") || strings.equal_fold(v.tok.text, "min") || strings.equal_fold(v.tok.text, "max") || strings.equal_fold(v.tok.text, "clamp"))
}

@(private)
is_logical_name :: proc(name: string) -> bool {
	_, ok := logical_names[name]
	return ok
}

////////////////////////////////
// Flow-relative to physical

// What a flow-relative side is, for a writing mode and a direction: physical side of block-start, inline-end, block-end,
// inline-start (the order of Side: what top, right, bottom and left mean when horizontal left to right).
flow_sides :: proc "contextless" (w: Writing_Mode, rtl: bool) -> [Side]Side {
	bs, be, is_, ie: Side
	switch w {
	case .Horizontal_Tb:
		bs, be = .Top, .Bottom
		is_, ie = .Left, .Right
	case .Vertical_Rl, .Sideways_Rl:
		bs, be = .Right, .Left
		is_, ie = .Top, .Bottom
	case .Vertical_Lr:
		bs, be = .Left, .Right
		is_, ie = .Top, .Bottom
	case .Sideways_Lr:
		bs, be = .Left, .Right
		is_, ie = .Bottom, .Top
	}
	if rtl { is_, ie = ie, is_ }
	return {.Top = bs, .Right = ie, .Bottom = be, .Left = is_}
}

@(private) flow_maps_once: sync.Once
@(private) flow_maps: [len(Writing_Mode) * 2][Prop]Prop

@(private)
flow_maps_build :: proc() {
	// groups of four properties in the order of Side
	groups := [?]Prop{.Margin_Top, .Padding_Top, .Border_Top_Style, .Border_Top_Width, .Border_Top_Color, .Top}
	for w in Writing_Mode {
		for r in 0 ..< 2 {
			m := &flow_maps[int(w) * 2 + r]
			for p in Prop { m[p] = p }
			sides := flow_sides(w, r == 1)
			// the four sides of each group, in the order of Side
			for g in groups {
				for s in Side { m[Prop(int(g) + int(s))] = Prop(int(g) + int(sides[s])) }
			}
			if is_vertical_mode(w) {
				m[.Width], m[.Height] = .Height, .Width
				m[.Min_Width], m[.Min_Height] = .Min_Height, .Min_Width
				m[.Max_Width], m[.Max_Height] = .Max_Height, .Max_Width
			}
			// corners: start-start is written as top left, start-end top right, end-end bottom right, end-start bottom left
			corner :: proc "contextless" (block, inline: Side) -> Prop {
				top := block == .Top || inline == .Top
				left := block == .Left || inline == .Left
				if top { return left ? .Border_Top_Left_Radius : .Border_Top_Right_Radius }
				return left ? .Border_Bottom_Left_Radius : .Border_Bottom_Right_Radius
			}
			m[.Border_Top_Left_Radius] = corner(sides[.Top], sides[.Left])
			m[.Border_Top_Right_Radius] = corner(sides[.Top], sides[.Right])
			m[.Border_Bottom_Right_Radius] = corner(sides[.Bottom], sides[.Right])
			m[.Border_Bottom_Left_Radius] = corner(sides[.Bottom], sides[.Left])
		}
	}
}

// The map of flow-relative names for a writing mode and a direction (nil: horizontal left to right, the names as they are).
flow_map_for :: proc(w: Writing_Mode, rtl: bool) -> ^[Prop]Prop {
	if w == .Horizontal_Tb && !rtl { return nil }
	sync.once_do(&flow_maps_once, flow_maps_build)
	return &flow_maps[int(w) * 2 + (rtl ? 1 : 0)]
}

// The value a candidate gives a keyword property of this element, reading only what the cascade has found: an element
// whose `writing-mode` or `direction` comes from var() is taken as inheriting (the element's style needs the mapping
// before var() can be substituted).
@(private)
element_flow_map :: proc(p: ^Pass, parent: ^Computed) -> ^[Prop]Prop {
	w := parent != nil ? parent.writing_mode : Writing_Mode.Horizontal_Tb
	rtl := parent != nil && parent.direction == .Rtl
	if cand := &p.ws[.Writing_Mode]; cand.valid && !cand.decl.has_var {
		switch css_wide_keyword(cand.decl.value) {
		case "initial": w = .Horizontal_Tb
		case "inherit", "unset", "revert", "revert-layer":
		case:
			if v, ok := parse_writing_mode(cand.decl.value); ok { w = v }
		}
	}
	if cand := &p.ws[.Direction]; cand.valid && !cand.decl.has_var {
		switch css_wide_keyword(cand.decl.value) {
		case "initial": rtl = false
		case "inherit", "unset", "revert", "revert-layer":
		case:
			if v, ok := parse_enum(cand.decl.value, Direction); ok { rtl = v == .Rtl }
		}
	}
	return flow_map_for(w, rtl)
}

// The physical longhand a flow-relative property name means on an element of this style, for what scripts read
// (getComputedStyle): `name` as is when it is not flow-relative.
physical_property_name :: proc(cs: ^Computed, name: string) -> string {
	tables_init()
	if !is_logical_name(name) { return name }
	p, sh, known := lookup_property(name)
	if !known || sh != .None { return name }
	m := flow_map_for(cs.writing_mode, cs.direction == .Rtl)
	if m == nil { return prop_name(p) }
	return prop_name(m[p])
}

////////////////////////////////
// What a writing mode does to the rest of the style

// A table's row groups and rows take the writing mode of their table (CSS Writing Modes 4 §2.1: writing-mode does not apply
// to them); an inline box in another writing mode than its parent becomes an inline-block, as in other browsers.
@(private)
writing_mode_fixup :: proc(cx: ^Cx) {
	c := cx.c
	if c.text_combine_upright != .None && !is_vertical_mode(c.writing_mode) { c.text_combine_upright = .None }
	parent := cx.parent
	if parent != nil && parent.writing_mode != c.writing_mode {
		#partial switch c.display {
		case .Inline: c.display = .Inline_Block
		case .Table_Row_Group, .Table_Header_Group, .Table_Footer_Group, .Table_Row, .Table_Column, .Table_Column_Group:
			c.writing_mode = parent.writing_mode
		}
	}
	c.frames = c.writing_mode != .Horizontal_Tb || c.column_count != 0 || c.column_width.kind != .Auto || c.column_span != .None
}

_ :: base.NIL_HANDLE
