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
// (Digits_n: `digits <n>` is kept as a value; no layout combines digits, as Blink)
Text_Combine_Upright :: enum u8 { None, All, Digits_2, Digits_3, Digits_4 }

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

@(private)
parse_text_combine :: proc(vs: []css.Value) -> (Text_Combine_Upright, bool) {
	if v, ok := parse_enum(vs, Text_Combine_Upright); ok && v < .Digits_2 { return v, true }
	items := css.trim_values(vs)
	first: css.Value
	rest: []css.Value
	n := 0
	for it in items {
		if it.kind == .Token && it.tok.kind == .Whitespace { continue }
		if n == 0 { first = it } else if n == 1 { one := [1]css.Value{it}; rest = one[:]; d, ok := css.parse_integer(rest); if !ok || !is_ident(first, "digits") || d < 2 || d > 4 { return {}, false }; return d == 2 ? .Digits_2 : (d == 3 ? .Digits_3 : .Digits_4), true }
		n += 1
	}
	if n == 1 && is_ident(first, "digits") { return .Digits_2, true }
	return {}, false
}

// Whether the start of a physical axis, for a writing mode and direction, is at its high end (rtl-like).
axis_start_hi :: proc "contextless" (w: Writing_Mode, rtl, axis_x: bool) -> bool {
	sides := flow_sides(w, rtl)
	if is_vertical_mode(w) { return axis_x ? sides[.Top] == .Right : sides[.Left] == .Bottom }
	return axis_x && sides[.Left] == .Right
}

// A try tactic named by flow, as physical tactics for a containing block in this writing mode.
try_tactics_physical :: proc(t: Try_Tactic, w: Writing_Mode, out: ^[3]Try_Tactic) -> int {
	if !is_vertical_mode(w) { out[0] = t; return 1 }
	#partial switch t {
	case .Flip_Block: out[0] = .Flip_X; return 1
	case .Flip_Inline: out[0] = .Flip_Y; return 1
	case .Flip_Start:
		// the diagonal from the block-start inline-start corner: top left only in vertical-lr
		out[0] = .Flip_Start
		if w == .Vertical_Lr { return 1 }
		out[1], out[2] = .Flip_X, .Flip_Y
		return 3
	}
	out[0] = t
	return 1
}

// area_tracks with writing modes: the keywords that name a flow-relative side go to the physical axis they mean.
area_tracks_flow :: proc(area: Position_Area, cb_wm: Writing_Mode, cb_rtl: bool, self_wm: Writing_Mode, self_rtl: bool) -> (x, y: [2]i8) {
	if !is_vertical_mode(cb_wm) && !is_vertical_mode(self_wm) { return area_tracks(area, cb_rtl, self_rtl) }
	on_x :: proc(c: Area_Class, cbv, selfv: bool) -> bool {
		#partial switch c {
		case .Horizontal: return true
		case .Inline: return !cbv
		case .Block: return cbv
		case .Self_Inline: return !selfv
		case .Self_Block: return selfv
		}
		return false
	}
	on_y :: proc(c: Area_Class, cbv, selfv: bool) -> bool {
		#partial switch c {
		case .Vertical: return true
		case .Inline: return cbv
		case .Block: return !cbv
		case .Self_Inline: return selfv
		case .Self_Block: return !selfv
		}
		return false
	}
	cbv, selfv := is_vertical_mode(cb_wm), is_vertical_mode(self_wm)
	single :: proc(k: Area_Keyword) -> bool { c := area_class(k); return c == .Logical || c == .Self_Logical || k == .Center || k == .Span_All }
	ax, ay: Area_Keyword = .Span_All, .Span_All
	ca, cb := area_class(area.a), area_class(area.b)
	switch {
	case area.b == .None && single(area.a): ax, ay = area.a, area.a
	case on_x(ca, cbv, selfv) || on_y(cb, cbv, selfv):
		ax = area.a
		if area.b != .None { ay = area.b }
	case on_y(ca, cbv, selfv) || on_x(cb, cbv, selfv):
		ay = area.a
		if area.b != .None { ax = area.b }
	case:
		// a logical pair: block, inline
		if (ca == .Self_Logical ? selfv : cbv) {
			ax = area.a
			if area.b != .None { ay = area.b }
		} else {
			ay = area.a
			if area.b != .None { ax = area.b }
		}
	}
	x[0], x[1] = area_span(ax, axis_start_hi(cb_wm, cb_rtl, true), axis_start_hi(self_wm, self_rtl, true))
	y[0], y[1] = area_span(ay, axis_start_hi(cb_wm, cb_rtl, false), axis_start_hi(self_wm, self_rtl, false))
	return
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

// An inline box in another writing mode than its parent becomes an inline-block, as in other browsers. (A table's row groups and
// rows keep their computed value, which their cells inherit, but layout gives them their table's: writing-mode does not apply to them.)
@(private)
writing_mode_fixup :: proc(cx: ^Cx) {
	c := cx.c
	if c.text_combine_upright != .None && !is_vertical_mode(c.writing_mode) { c.text_combine_upright = .None }
	parent := cx.parent
	if parent != nil && parent.writing_mode != c.writing_mode {
		if c.display == .Inline { c.display = .Inline_Block }
	}
	c.frames = c.writing_mode != .Horizontal_Tb || c.column_count != 0 || c.column_width.kind != .Auto || c.column_span != .None
}

_ :: base.NIL_HANDLE
