package style

import "wb:base"
import "wb:css"

// Declared values compiled once into typed specified values (compile_declarations): the cascade applies them to every
// element without reading their tokens again. Most declarations of a page are a keyword, a length or a color: these
// families are typed here. A value whose result does not depend on the element is computed when it is compiled, on the
// probe (the result is read back from it, so it is what apply_prop gives by construction); a length in a relative unit
// keeps its number and unit, which the element resolves. Every other value (a function, calc(), var()...) keeps kind
// None and is applied from its tokens.

Spec_Kind :: enum u8 {
	None,
	Keyword,    // `keyword`: the value of the property's field (an enum, or a bool as 0 and 1)
	Length,     // `keyword` is the Length_Kind, `num` the value (px or percent): the same for every element
	Relative,   // `num` in `unit` (em, rem, vw...): px once the element resolves it
	Color,      // `color`: a color the same for every element (hex, a named color, transparent)
}

Specified :: struct {
	kind:    Spec_Kind,
	keyword: u8,
	unit:    css.Unit,
	num:     f64,        // (a Length's f32 value is exact in an f64)
	color:   css.Color,
}

// What `vs`, valid for `p` and just applied to the probe `cx` (apply_prop returned true), compiles to.
@(private)
specify :: proc(cx: ^Cx, p: Prop, vs: []css.Value) -> Specified {
	one := css.trim_values(vs)
	if len(one) != 1 || one[0].kind != .Token { return {} }
	t := one[0].tok
	switch {
	case is_keyword_prop(p):
		// the keywords whose value follows the element
		if t.kind == .Ident {
			#partial switch p {
			case .Float: if base.ascii_equal_fold(t.text, "inline-start") || base.ascii_equal_fold(t.text, "inline-end") { return {} }
			case .Text_Align: if base.ascii_equal_fold(t.text, "-internal-th-center") { return {} }
			}
		}
		k, ok := keyword_get(cx.c, p)
		if !ok { return {} }
		return Specified{kind = .Keyword, keyword = k}
	case is_length_prop(p):
		#partial switch t.kind {
		case .Dimension:
			du := css.token_dim_unit(t)
			if _, absolute := css.dim_unit_to_px(t.num, du); !absolute {
				u, rel := css.dim_unit_relative(du)
				if !rel { return {} }
				return Specified{kind = .Relative, unit = u, num = t.num}
			}
		case .Number, .Percentage, .Ident:
		case: return {}
		}
		l, ok := length_get(cx.c, p)
		if !ok || l.calc != nil { return {} }
		return Specified{kind = .Length, keyword = u8(l.kind), num = f64(l.v)}
	case is_color_prop_typed(p):
		if t.kind != .Hash && t.kind != .Ident { return {} }
		// without an environment, system colors are not known and currentcolor is told apart: what parses is the same
		// for every element
		cv, ok := css.parse_color(one, nil)
		if !ok || cv.kind != .Rgba { return {} }
		return Specified{kind = .Color, color = cv.rgba}
	}
	return {}
}

// Applies `spec` (not kind None) to `p`, as apply_prop applies the value it was compiled from.
@(private)
apply_specified :: proc(cx: ^Cx, p: Prop, spec: Specified) {
	cx_take(cx, p)
	c := cx.c
	switch spec.kind {
	case .None:
	case .Keyword: keyword_set(c, p, spec.keyword)
	case .Length: length_set(c, p, Length{kind = Length_Kind(spec.keyword), v = f32(spec.num)})
	case .Relative: length_set(c, p, px(f32(css.resolve_unit(spec.num, spec.unit, cx.lc))))
	case .Color:
		if p == .Color {
			// (apply_color: a color the same in both schemes)
			c.color_pair = Scheme_Color{spec.color, spec.color}
			c.color = scheme_pick(c.color_pair, c.used_scheme)
			return
		}
		cx.cenv.current, cx.cenv.has_current = c.color, true   // (what parse_color leaves for the values after it)
		#partial switch p {
		case .Background_Color: c.background_color = spec.color; return
		case .Border_Top_Color, .Border_Right_Color, .Border_Bottom_Color, .Border_Left_Color:
			c.border_color[Side(int(p) - int(Prop.Border_Top_Color))] = spec.color
		case .Outline_Color: c.outline_color = spec.color
		case .Text_Decoration_Color: c.text_decoration_color = spec.color
		}
		ps_add(&cx.explicit, p)
	}
}

////////////////////////////////
// Keywords

@(private)
is_keyword_prop :: proc(p: Prop) -> bool {
	#partial switch p {
	case .Stroke_Linecap, .Stroke_Linejoin, .Font_Style, .Text_Align, .Text_Transform, .Text_Overflow, .Word_Break,
	     .Overflow_Wrap, .Direction, .Display, .Position, .Float, .Clear, .Box_Sizing,
	     .Border_Top_Style, .Border_Right_Style, .Border_Bottom_Style, .Border_Left_Style, .Overflow_X, .Overflow_Y,
	     .Visibility, .Object_Fit, .Flex_Direction, .Flex_Wrap, .Justify_Content, .Align_Items, .Align_Self,
	     .Align_Content, .List_Style_Position, .Pointer_Events, .User_Select, .Outline_Style, .Border_Collapse:
		return true
	}
	return false
}

// The field of keyword property `p` in `c`.
@(private)
keyword_get :: proc(c: ^Computed, p: Prop) -> (u8, bool) {
	#partial switch p {
	case .Stroke_Linecap: return u8(c.stroke_linecap), true
	case .Stroke_Linejoin: return u8(c.stroke_linejoin), true
	case .Font_Style: return u8(c.font_style), true
	case .Text_Align: return u8(c.text_align), true
	case .Text_Transform: return u8(c.text_transform), true
	case .Text_Overflow: return c.text_ellipsis ? 1 : 0, true
	case .Word_Break: return u8(c.word_break), true
	case .Overflow_Wrap: return u8(c.overflow_wrap), true
	case .Direction: return u8(c.direction), true
	case .Display: return u8(c.display), true
	case .Position: return u8(c.position), true
	case .Float: return u8(c.float), true
	case .Clear: return u8(c.clear), true
	case .Box_Sizing: return u8(c.box_sizing), true
	case .Border_Top_Style, .Border_Right_Style, .Border_Bottom_Style, .Border_Left_Style:
		return u8(c.border_style[Side(int(p) - int(Prop.Border_Top_Style))]), true
	case .Overflow_X: return u8(c.overflow_x), true
	case .Overflow_Y: return u8(c.overflow_y), true
	case .Visibility: return u8(c.visibility), true
	case .Object_Fit: return u8(c.object_fit), true
	case .Flex_Direction: return u8(c.flex_direction), true
	case .Flex_Wrap: return u8(c.flex_wrap), true
	case .Justify_Content: return u8(c.justify_content), true
	case .Align_Items: return u8(c.align_items), true
	case .Align_Self: return u8(c.align_self), true
	case .Align_Content: return u8(c.align_content), true
	case .List_Style_Position: return u8(c.list_style_position), true
	case .Pointer_Events: return c.pointer_events ? 1 : 0, true
	case .User_Select: return u8(c.user_select), true
	case .Outline_Style: return u8(c.outline_style), true
	case .Border_Collapse: return c.border_collapse ? 1 : 0, true
	}
	return 0, false
}

// Writes the field of keyword property `p` (keyword_get's).
@(private)
keyword_set :: proc(c: ^Computed, p: Prop, k: u8) {
	#partial switch p {
	case .Stroke_Linecap: c.stroke_linecap = Stroke_Linecap(k)
	case .Stroke_Linejoin: c.stroke_linejoin = Stroke_Linejoin(k)
	case .Font_Style: c.font_style = Font_Style(k)
	case .Text_Align: c.text_align = Text_Align(k)
	case .Text_Transform: c.text_transform = Text_Transform(k)
	case .Text_Overflow: c.text_ellipsis = k != 0
	case .Word_Break: c.word_break = Word_Break(k)
	case .Overflow_Wrap: c.overflow_wrap = Overflow_Wrap(k)
	case .Direction: c.direction = Direction(k)
	case .Display: c.display = Display(k)
	case .Position: c.position = Position(k)
	case .Float: c.float = Float(k)
	case .Clear: c.clear = Clear(k)
	case .Box_Sizing: c.box_sizing = Box_Sizing(k)
	case .Border_Top_Style, .Border_Right_Style, .Border_Bottom_Style, .Border_Left_Style:
		c.border_style[Side(int(p) - int(Prop.Border_Top_Style))] = Border_Style(k)
	case .Overflow_X: c.overflow_x = Overflow(k)
	case .Overflow_Y: c.overflow_y = Overflow(k)
	case .Visibility: c.visibility = Visibility(k)
	case .Object_Fit: c.object_fit = Object_Fit(k)
	case .Flex_Direction: c.flex_direction = Flex_Direction(k)
	case .Flex_Wrap: c.flex_wrap = Flex_Wrap(k)
	case .Justify_Content: c.justify_content = Content_Align(k)
	case .Align_Items: c.align_items = Content_Align(k)
	case .Align_Self: c.align_self = Content_Align(k)
	case .Align_Content: c.align_content = Content_Align(k)
	case .List_Style_Position: c.list_style_position = List_Style_Position(k)
	case .Pointer_Events: c.pointer_events = k != 0
	case .User_Select: c.user_select = User_Select(k)
	case .Outline_Style: c.outline_style = Border_Style(k)
	case .Border_Collapse: c.border_collapse = k != 0
	}
}

////////////////////////////////
// Lengths

// The properties apply_prop computes as parse_length gives them, nothing more.
@(private)
is_length_prop :: proc(p: Prop) -> bool {
	#partial switch p {
	case .Top, .Right, .Bottom, .Left, .Width, .Height, .Min_Width, .Min_Height, .Max_Width, .Max_Height,
	     .Margin_Top, .Margin_Right, .Margin_Bottom, .Margin_Left, .Padding_Top, .Padding_Right, .Padding_Bottom,
	     .Padding_Left, .Text_Indent, .Row_Gap, .Column_Gap, .Flex_Basis:
		return true
	}
	return false
}

@(private)
length_get :: proc(c: ^Computed, p: Prop) -> (Length, bool) {
	#partial switch p {
	case .Top, .Right, .Bottom, .Left: return c.inset[Side(int(p) - int(Prop.Top))], true
	case .Width: return c.width, true
	case .Height: return c.height, true
	case .Min_Width: return c.min_width, true
	case .Min_Height: return c.min_height, true
	case .Max_Width: return c.max_width, true
	case .Max_Height: return c.max_height, true
	case .Margin_Top, .Margin_Right, .Margin_Bottom, .Margin_Left: return c.margin[Side(int(p) - int(Prop.Margin_Top))], true
	case .Padding_Top, .Padding_Right, .Padding_Bottom, .Padding_Left: return c.padding[Side(int(p) - int(Prop.Padding_Top))], true
	case .Text_Indent: return c.text_indent, true
	case .Row_Gap: return c.row_gap, true
	case .Column_Gap: return c.column_gap, true
	case .Flex_Basis: return c.flex_basis, true
	}
	return {}, false
}

@(private)
length_set :: proc(c: ^Computed, p: Prop, l: Length) {
	#partial switch p {
	case .Top, .Right, .Bottom, .Left: c.inset[Side(int(p) - int(Prop.Top))] = l
	case .Width: c.width = l
	case .Height: c.height = l
	case .Min_Width: c.min_width = l
	case .Min_Height: c.min_height = l
	case .Max_Width: c.max_width = l
	case .Max_Height: c.max_height = l
	case .Margin_Top, .Margin_Right, .Margin_Bottom, .Margin_Left: c.margin[Side(int(p) - int(Prop.Margin_Top))] = l
	case .Padding_Top, .Padding_Right, .Padding_Bottom, .Padding_Left: c.padding[Side(int(p) - int(Prop.Padding_Top))] = l
	case .Text_Indent: c.text_indent = l
	case .Row_Gap: c.row_gap = l
	case .Column_Gap: c.column_gap = l
	case .Flex_Basis: c.flex_basis = l
	}
}

////////////////////////////////
// Colors

@(private)
is_color_prop_typed :: proc(p: Prop) -> bool {
	#partial switch p {
	case .Color, .Background_Color, .Border_Top_Color, .Border_Right_Color, .Border_Bottom_Color, .Border_Left_Color,
	     .Outline_Color, .Text_Decoration_Color:
		return true
	}
	return false
}
