package style

import "base:runtime"
import "core:math"
import "core:mem"
import "core:reflect"
import "core:strings"
import "wb:css"

// Per-element context while specified values become computed values.
Cx :: struct {
	settings: ^Settings,
	lc:       css.Length_Context,   // em / rem / viewport bases; font_size follows the element's own font-size once it is known
	parent:   ^Computed,            // nil for the root
	initial:  ^Computed,            // initial values (for `unset` / `initial`)
	c:        ^Computed,
	alloc:    runtime.Allocator,    // owns everything the computed style points to
	cenv:     css.Color_Env,
	explicit: Prop_Set,             // color-valued properties that were given a concrete color
}

Len_Flag :: enum u8 { Auto, None, Normal, Percent, Negative, Intrinsic }
Len_Flags :: bit_set[Len_Flag; u8]

////////////////////////////////
// Keywords

@(private)
names_equal :: proc(ident, enum_name: string) -> bool {
	if len(ident) != len(enum_name) { return false }
	for i in 0 ..< len(ident) {
		a, b := ident[i], enum_name[i]
		if a >= 'A' && a <= 'Z' { a += 32 }
		if b >= 'A' && b <= 'Z' { b += 32 }
		if b == '_' { b = '-' }
		if a != b { return false }
	}
	return true
}

// The identifier keyword of a single-value declaration (original case), if it is one.
ident_raw :: proc(input: []css.Value) -> (string, bool) {
	vs := css.trim_values(input)
	if len(vs) == 1 && vs[0].kind == .Token && vs[0].tok.kind == .Ident { return vs[0].tok.text, true }
	return "", false
}

// Enum parsing by name: `Space_Between` is written `space-between`. Every enum parsed this way has contiguous values from 0.
parse_enum :: proc(input: []css.Value, $E: typeid) -> (E, bool) {
	id, ok := ident_raw(input)
	if !ok { return {}, false }
	names := reflect.enum_field_names(E)
	for n, i in names { if names_equal(id, n) { return E(i), true } }
	return {}, false
}

@(private)
set_enum :: proc(vs: []css.Value, dst: ^$E) -> bool {
	v, ok := parse_enum(vs, E)
	if ok { dst^ = v }
	return ok
}

////////////////////////////////
// Lengths

@(private)
calc_has_percent :: proc(n: ^css.Calc) -> bool {
	if n == nil { return false }
	if n.op == .Dimension && n.unit == .Percent { return true }
	return calc_has_percent(n.a) || calc_has_percent(n.b) || calc_has_percent(n.c)
}

// Replaces every relative unit by px. Percent leaves stay (they depend on the box the value is used on).
@(private)
calc_resolve_units :: proc(n: ^css.Calc, lc: css.Length_Context) {
	if n == nil { return }
	if n.op == .Dimension && n.unit != .Px && n.unit != .Percent {
		n.num = css.resolve_unit(n.num, n.unit, lc)
		n.unit = .Px
	}
	calc_resolve_units(n.a, lc); calc_resolve_units(n.b, lc); calc_resolve_units(n.c, lc)
}

parse_length :: proc(cx: ^Cx, input: []css.Value, flags: Len_Flags) -> (Length, bool) {
	vs := css.trim_values(input)
	if len(vs) != 1 { return {}, false }
	v := vs[0]
	switch v.kind {
	case .Token:
		t := v.tok
		#partial switch t.kind {
		case .Number:
			if t.num == 0 { return px(0), true }
		case .Dimension:
			if t.num < 0 && .Negative not_in flags { return {}, false }
			if p, ok := css.length_unit_to_px(t.num, t.text, 0); ok { return px(f32(p)), true }
			if u, ok := css.relative_unit(t.text); ok { return px(f32(css.resolve_unit(t.num, u, cx.lc))), true }
		case .Percentage:
			if .Percent in flags && (t.num >= 0 || .Negative in flags) { return Length{kind = .Percent, v = f32(t.num)}, true }
		case .Ident:
			id := strings.to_lower(t.text, context.temp_allocator)
			switch id {
			case "auto": if .Auto in flags { return Length{kind = .Auto}, true }
			case "none": if .None in flags { return Length{kind = .None}, true }
			case "normal": if .Normal in flags { return Length{kind = .Normal}, true }
			case "min-content": if .Intrinsic in flags { return Length{kind = .Min_Content}, true }
			case "max-content": if .Intrinsic in flags { return Length{kind = .Max_Content}, true }
			case "fit-content": if .Intrinsic in flags { return Length{kind = .Fit_Content}, true }
			}
		}
	case .Function:
		tree := css.parse_calc(v, cx.alloc)
		if tree == nil { return {}, false }
		calc_resolve_units(tree, cx.lc)
		if !calc_has_percent(tree) || .Percent not_in flags {
			if calc_has_percent(tree) { return {}, false }
			r := css.eval_calc(tree, cx.lc)
			if r < 0 && .Negative not_in flags { r = 0 }
			return px(f32(r)), true
		}
		return Length{kind = .Calc, calc = tree}, true
	case .Block:
	}
	return {}, false
}

// Splits a value list at whitespace into its top-level items (each item is one component value).
split_items :: proc(input: []css.Value, allocator := context.temp_allocator) -> []css.Value {
	out := make([dynamic]css.Value, allocator)
	for v in input { if !css.is_ws_value(v) { append(&out, v) } }
	return out[:]
}

parse_color :: proc(cx: ^Cx, vs: []css.Value) -> (css.Color, bool) {
	cv, ok := css.parse_color(vs, &cx.cenv)
	if !ok { return {}, false }
	if cv.kind == .Current_Color { return cx.c.color, true }
	return cv.rgba, true
}

////////////////////////////////
// Initial values and copying

initial_computed :: proc(s: ^Settings) -> Computed {
	c: Computed
	mem.zero_item(&c)   // padding bytes included: computed styles are compared as raw memory
	c.display = .Inline
	c.z_auto = true
	c.max_width = Length{kind = .None}
	c.max_height = Length{kind = .None}
	c.width, c.height = auto_length, auto_length
	for side in Side {
		c.inset[side] = auto_length
		c.margin[side] = px(0)
		c.padding[side] = px(0)
		c.border_width[side] = 3
		c.border_color[side] = s.text_color
	}
	c.opacity = 1
	c.flex_shrink = 1
	c.flex_basis = auto_length
	c.align_self = .Auto
	c.row_gap, c.column_gap = Length{kind = .Normal}, Length{kind = .Normal}
	c.color = s.text_color
	c.font_size = s.default_font_size
	c.font_weight = 400
	c.line_height = Line_Height{kind = .Normal}
	c.text_decoration_color = s.text_color
	c.text_indent = px(0)
	c.tab_size = 8
	c.pointer_events = true
	c.background_color = {0, 0, 0, 0}
	c.background_position = {Length{kind = .Percent, v = 0}, Length{kind = .Percent, v = 0}}
	c.outline_width = 3
	c.outline_color = s.text_color
	c.list_style_type = .Disc
	c.border_collapse = false
	c.content = Content{kind = .Normal}
	return c
}

// Copies one property from `src` into `dst` (inherit, initial, unset and inheritance itself all use it).
copy_prop :: proc(dst, src: ^Computed, p: Prop) {
	switch p {
	case .Font_Size: dst.font_size = src.font_size
	case .Color: dst.color = src.color
	case .Font_Family: dst.font_family = src.font_family
	case .Font_Weight: dst.font_weight = src.font_weight
	case .Font_Style: dst.font_style = src.font_style
	case .Line_Height: dst.line_height = src.line_height
	case .Letter_Spacing: dst.letter_spacing = src.letter_spacing
	case .Word_Spacing: dst.word_spacing = src.word_spacing
	case .Text_Align: dst.text_align = src.text_align
	case .Text_Decoration_Line: dst.text_decoration = src.text_decoration
	case .Text_Decoration_Color: dst.text_decoration_color = src.text_decoration_color
	case .Text_Transform: dst.text_transform = src.text_transform
	case .Text_Indent: dst.text_indent = src.text_indent
	case .Text_Overflow: dst.text_ellipsis = src.text_ellipsis
	case .White_Space: dst.white_space = src.white_space
	case .Word_Break: dst.word_break = src.word_break
	case .Overflow_Wrap: dst.overflow_wrap = src.overflow_wrap
	case .Tab_Size: dst.tab_size = src.tab_size
	case .Direction: dst.direction = src.direction
	case .Text_Shadow: dst.text_shadow = src.text_shadow
	case .Display: dst.display = src.display
	case .Position: dst.position = src.position
	case .Float: dst.float = src.float
	case .Clear: dst.clear = src.clear
	case .Top: dst.inset[.Top] = src.inset[.Top]
	case .Right: dst.inset[.Right] = src.inset[.Right]
	case .Bottom: dst.inset[.Bottom] = src.inset[.Bottom]
	case .Left: dst.inset[.Left] = src.inset[.Left]
	case .Z_Index: dst.z_auto, dst.z_index = src.z_auto, src.z_index
	case .Box_Sizing: dst.box_sizing = src.box_sizing
	case .Width: dst.width = src.width
	case .Height: dst.height = src.height
	case .Min_Width: dst.min_width = src.min_width
	case .Min_Height: dst.min_height = src.min_height
	case .Max_Width: dst.max_width = src.max_width
	case .Max_Height: dst.max_height = src.max_height
	case .Margin_Top: dst.margin[.Top] = src.margin[.Top]
	case .Margin_Right: dst.margin[.Right] = src.margin[.Right]
	case .Margin_Bottom: dst.margin[.Bottom] = src.margin[.Bottom]
	case .Margin_Left: dst.margin[.Left] = src.margin[.Left]
	case .Padding_Top: dst.padding[.Top] = src.padding[.Top]
	case .Padding_Right: dst.padding[.Right] = src.padding[.Right]
	case .Padding_Bottom: dst.padding[.Bottom] = src.padding[.Bottom]
	case .Padding_Left: dst.padding[.Left] = src.padding[.Left]
	case .Border_Top_Style: dst.border_style[.Top] = src.border_style[.Top]
	case .Border_Right_Style: dst.border_style[.Right] = src.border_style[.Right]
	case .Border_Bottom_Style: dst.border_style[.Bottom] = src.border_style[.Bottom]
	case .Border_Left_Style: dst.border_style[.Left] = src.border_style[.Left]
	case .Border_Top_Width: dst.border_width[.Top] = src.border_width[.Top]
	case .Border_Right_Width: dst.border_width[.Right] = src.border_width[.Right]
	case .Border_Bottom_Width: dst.border_width[.Bottom] = src.border_width[.Bottom]
	case .Border_Left_Width: dst.border_width[.Left] = src.border_width[.Left]
	case .Border_Top_Color: dst.border_color[.Top] = src.border_color[.Top]
	case .Border_Right_Color: dst.border_color[.Right] = src.border_color[.Right]
	case .Border_Bottom_Color: dst.border_color[.Bottom] = src.border_color[.Bottom]
	case .Border_Left_Color: dst.border_color[.Left] = src.border_color[.Left]
	case .Border_Top_Left_Radius: dst.radius[.Top_Left] = src.radius[.Top_Left]
	case .Border_Top_Right_Radius: dst.radius[.Top_Right] = src.radius[.Top_Right]
	case .Border_Bottom_Right_Radius: dst.radius[.Bottom_Right] = src.radius[.Bottom_Right]
	case .Border_Bottom_Left_Radius: dst.radius[.Bottom_Left] = src.radius[.Bottom_Left]
	case .Overflow_X: dst.overflow_x = src.overflow_x
	case .Overflow_Y: dst.overflow_y = src.overflow_y
	case .Visibility: dst.visibility = src.visibility
	case .Opacity: dst.opacity = src.opacity
	case .Vertical_Align: dst.vertical_align = src.vertical_align
	case .Aspect_Ratio: dst.aspect_ratio = src.aspect_ratio
	case .Object_Fit: dst.object_fit = src.object_fit
	case .Flex_Direction: dst.flex_direction = src.flex_direction
	case .Flex_Wrap: dst.flex_wrap = src.flex_wrap
	case .Flex_Grow: dst.flex_grow = src.flex_grow
	case .Flex_Shrink: dst.flex_shrink = src.flex_shrink
	case .Flex_Basis: dst.flex_basis = src.flex_basis
	case .Justify_Content: dst.justify_content = src.justify_content
	case .Align_Items: dst.align_items = src.align_items
	case .Align_Self: dst.align_self = src.align_self
	case .Align_Content: dst.align_content = src.align_content
	case .Order: dst.order = src.order
	case .Row_Gap: dst.row_gap = src.row_gap
	case .Column_Gap: dst.column_gap = src.column_gap
	case .Background_Color: dst.background_color = src.background_color
	case .Background_Image: dst.background_image = src.background_image
	case .Background_Repeat: dst.background_repeat = src.background_repeat
	case .Background_Position: dst.background_position = src.background_position
	case .Background_Size: dst.background_size = src.background_size
	case .Box_Shadow: dst.box_shadow = src.box_shadow
	case .List_Style_Type: dst.list_style_type = src.list_style_type
	case .List_Style_Position: dst.list_style_position = src.list_style_position
	case .Cursor: dst.cursor = src.cursor
	case .Pointer_Events: dst.pointer_events = src.pointer_events
	case .User_Select: dst.user_select = src.user_select
	case .Content: dst.content = src.content
	case .Outline_Width: dst.outline_width = src.outline_width
	case .Outline_Style: dst.outline_style = src.outline_style
	case .Outline_Color: dst.outline_color = src.outline_color
	case .Outline_Offset: dst.outline_offset = src.outline_offset
	case .Border_Collapse: dst.border_collapse = src.border_collapse
	case .Border_Spacing: dst.border_spacing = src.border_spacing
	}
}

// Properties whose "color" is `currentcolor` unless the page says otherwise.
COLOR_PROPS :: Prop_Set{.Border_Top_Color, .Border_Right_Color, .Border_Bottom_Color, .Border_Left_Color, .Outline_Color, .Text_Decoration_Color}

////////////////////////////////
// Applying one longhand

@(private)
ABSOLUTE_SIZES := [?]struct { name: string, factor: f32 }{
	{"xx-small", 3.0 / 5}, {"x-small", 3.0 / 4}, {"small", 8.0 / 9}, {"medium", 1}, {"large", 6.0 / 5},
	{"x-large", 3.0 / 2}, {"xx-large", 2}, {"xxx-large", 3},
}

@(private)
parse_font_family :: proc(cx: ^Cx, input: []css.Value) -> ([]string, bool) {
	out := make([dynamic]string, cx.alloc)
	for part in css.split_commas(css.trim_values(input), context.temp_allocator) {
		items := css.trim_values(part)
		if len(items) == 0 { return nil, false }
		if len(items) == 1 && items[0].kind == .Token && items[0].tok.kind == .String {
			append(&out, strings.clone(items[0].tok.text, cx.alloc))
			continue
		}
		sb := strings.builder_make(context.temp_allocator)
		generic := false
		n := 0
		for it in items {
			if css.is_ws_value(it) { continue }
			if it.kind != .Token || it.tok.kind != .Ident { return nil, false }
			if n > 0 { strings.write_byte(&sb, ' ') }
			strings.write_string(&sb, it.tok.text)
			n += 1
		}
		name := strings.to_string(sb)
		switch strings.to_lower(name, context.temp_allocator) {
		case "serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui", "ui-sans-serif", "ui-serif", "ui-monospace", "ui-rounded", "emoji", "math", "fangsong":
			generic = true
		}
		append(&out, generic ? strings.to_lower(name, cx.alloc) : strings.clone(name, cx.alloc))
	}
	if len(out) == 0 { return nil, false }
	return out[:], true
}

@(private)
parse_shadows :: proc(cx: ^Cx, input: []css.Value) -> ([]Shadow, bool) {
	vs := css.trim_values(input)
	if id, ok := ident_raw(vs); ok && strings.equal_fold(id, "none") { return nil, true }
	out := make([dynamic]Shadow, cx.alloc)
	for part in css.split_commas(vs, context.temp_allocator) {
		s := Shadow{color = cx.c.color}
		nums := 0
		lens: [4]f32
		for it in split_items(part) {
			if it.kind == .Token && it.tok.kind == .Ident && strings.equal_fold(it.tok.text, "inset") { s.inset = true; continue }
			one := [1]css.Value{it}
			if l, ok := parse_length(cx, one[:], {.Negative}); ok && l.kind == .Px {
				if nums >= 4 { return nil, false }
				lens[nums] = l.v; nums += 1
				continue
			}
			if col, ok := parse_color(cx, one[:]); ok { s.color = col; continue }
			return nil, false
		}
		if nums < 2 { return nil, false }
		s.x, s.y, s.blur, s.spread = lens[0], lens[1], max(lens[2], 0), lens[3]
		append(&out, s)
	}
	return out[:], true
}

@(private)
parse_position_component :: proc(cx: ^Cx, v: css.Value) -> (l: Length, axis: int, ok: bool) {
	// axis: 0 = x only (left/right), 1 = y only (top/bottom), 2 = either (center, lengths)
	one := [1]css.Value{v}
	if v.kind == .Token && v.tok.kind == .Ident {
		switch strings.to_lower(v.tok.text, context.temp_allocator) {
		case "left": return Length{kind = .Percent, v = 0}, 0, true
		case "right": return Length{kind = .Percent, v = 100}, 0, true
		case "top": return Length{kind = .Percent, v = 0}, 1, true
		case "bottom": return Length{kind = .Percent, v = 100}, 1, true
		case "center": return Length{kind = .Percent, v = 50}, 2, true
		}
		return {}, 0, false
	}
	l, ok = parse_length(cx, one[:], {.Percent, .Negative})
	return l, 2, ok
}

@(private)
apply_background_position :: proc(cx: ^Cx, input: []css.Value) -> bool {
	items := split_items(input)
	if len(items) < 1 || len(items) > 2 { return false }
	x, y := Length{kind = .Percent, v = 50}, Length{kind = .Percent, v = 50}
	l0, a0, ok0 := parse_position_component(cx, items[0])
	if !ok0 { return false }
	if len(items) == 1 {
		if a0 == 1 { y = l0 } else { x = l0 }
	} else {
		l1, a1, ok1 := parse_position_component(cx, items[1])
		if !ok1 { return false }
		if a0 == 1 || a1 == 0 {   // "top left", "bottom right": vertical first
			if a0 == 0 || a1 == 1 { return false }
			x, y = l1, l0
		} else {
			if a1 == 0 && a0 == 0 { return false }
			x, y = l0, l1
		}
	}
	cx.c.background_position = {x, y}
	return true
}

@(private)
parse_image :: proc(cx: ^Cx, input: []css.Value) -> (Image, bool) {
	vs := css.trim_values(input)
	if len(vs) != 1 { return {}, false }
	v := vs[0]
	if v.kind == .Token {
		#partial switch v.tok.kind {
		case .Ident: if strings.equal_fold(v.tok.text, "none") { return Image{}, true }
		case .Url: return Image{kind = .Url, url = strings.clone(v.tok.text, cx.alloc)}, true
		}
		return {}, false
	}
	if v.kind == .Function {
		name := strings.to_lower(v.tok.text, context.temp_allocator)
		switch name {
		case "url", "image":
			for a in v.children { if a.kind == .Token && a.tok.kind == .String { return Image{kind = .Url, url = strings.clone(a.tok.text, cx.alloc)}, true } }
		case "linear-gradient", "radial-gradient", "conic-gradient", "repeating-linear-gradient", "repeating-radial-gradient", "repeating-conic-gradient":
			return Image{kind = .Gradient, gradient = css.serialize_values(vs, cx.alloc)}, true
		}
	}
	return {}, false
}

@(private)
parse_content :: proc(cx: ^Cx, input: []css.Value) -> (Content, bool) {
	vs := css.trim_values(input)
	if id, ok := ident_raw(vs); ok {
		switch strings.to_lower(id, context.temp_allocator) {
		case "normal": return Content{kind = .Normal}, true
		case "none": return Content{kind = .None}, true
		}
	}
	items := make([dynamic]Content_Item, cx.alloc)
	for it in split_items(vs) {
		switch it.kind {
		case .Token:
			#partial switch it.tok.kind {
			case .String: append(&items, Content_Item{kind = .Text, text = strings.clone(it.tok.text, cx.alloc)})
			case .Url: append(&items, Content_Item{kind = .Url, text = strings.clone(it.tok.text, cx.alloc)})
			case .Ident:
				switch strings.to_lower(it.tok.text, context.temp_allocator) {
				case "open-quote": append(&items, Content_Item{kind = .Open_Quote})
				case "close-quote": append(&items, Content_Item{kind = .Close_Quote})
				case "no-open-quote", "no-close-quote":
				case: return {}, false
				}
			case: return {}, false
			}
		case .Function:
			if strings.equal_fold(it.tok.text, "attr") {
				for a in it.children { if a.kind == .Token && a.tok.kind == .Ident { append(&items, Content_Item{kind = .Attr, text = strings.to_lower(a.tok.text, cx.alloc)}); break } }
			} else if strings.equal_fold(it.tok.text, "counter") || strings.equal_fold(it.tok.text, "counters") {
				// counters are not implemented: they produce nothing rather than invalidating the declaration
			} else { return {}, false }
		case .Block: return {}, false
		}
	}
	if len(items) == 0 { return Content{kind = .None}, true }
	return Content{kind = .Items, items = items[:]}, true
}

@(private)
number_in :: proc(vs: []css.Value, lo, hi: f64) -> (f32, bool) {
	n, ok := css.parse_number(vs)
	if !ok || n < lo || n > hi { return 0, false }
	return f32(n), true
}

// Computes `p` from the specified value `vs`. Returns false when the value is invalid (the declaration then has no effect).
apply_prop :: proc(cx: ^Cx, p: Prop, vs: []css.Value) -> bool {
	c := cx.c
	s := cx.settings
	switch p {
	case .Font_Size:
		parent_fs := cx.parent != nil ? cx.parent.font_size : s.default_font_size
		size: f32
		if id, ok := ident_raw(vs); ok {
			lid := strings.to_lower(id, context.temp_allocator)
			switch lid {
			case "larger": size = parent_fs * 1.2
			case "smaller": size = parent_fs / 1.2
			case:
				found := false
				for a in ABSOLUTE_SIZES { if a.name == lid { size = a.factor * s.default_font_size; found = true } }
				if !found { return false }
			}
		} else {
			saved := cx.lc
			cx.lc.font_size = f64(parent_fs)
			l, ok2 := parse_length(cx, vs, {.Percent})
			cx.lc = saved
			if !ok2 { return false }
			#partial switch l.kind {
			case .Px: size = l.v
			case .Percent: size = parent_fs * l.v / 100
			case .Calc: size = f32(css.eval_calc(l.calc, css.Length_Context{percent_base = f64(parent_fs)}))
			case: return false
			}
		}
		c.font_size = max(size, s.minimum_font_size)
		cx.lc.font_size = f64(c.font_size)
		cx.lc.x_height = f64(c.font_size) * 0.5
		cx.lc.ch = f64(c.font_size) * 0.5
	case .Color:
		if id, ok := ident_raw(vs); ok && strings.equal_fold(id, "currentcolor") {
			c.color = cx.parent != nil ? cx.parent.color : s.text_color
			return true
		}
		col, ok := parse_color(cx, vs)
		if !ok { return false }
		c.color = col
	case .Font_Family:
		fam, ok := parse_font_family(cx, vs)
		if !ok { return false }
		c.font_family = fam
	case .Font_Weight:
		if id, ok := ident_raw(vs); ok {
			parent_w := cx.parent != nil ? int(cx.parent.font_weight) : 400
			switch strings.to_lower(id, context.temp_allocator) {
			case "normal": c.font_weight = 400
			case "bold": c.font_weight = 700
			case "bolder": c.font_weight = parent_w < 350 ? 400 : (parent_w < 550 ? 700 : 900)
			case "lighter": c.font_weight = parent_w >= 750 ? 700 : (parent_w >= 550 ? 400 : 100)
			case: return false
			}
		} else {
			n, ok2 := number_in(vs, 1, 1000)
			if !ok2 { return false }
			c.font_weight = u16(n)
		}
	case .Font_Style: return set_enum(vs, &c.font_style)
	case .Line_Height:
		if id, ok := ident_raw(vs); ok {
			if !strings.equal_fold(id, "normal") { return false }
			c.line_height = Line_Height{kind = .Normal}
			return true
		}
		items := css.trim_values(vs)
		if len(items) == 1 && items[0].kind == .Token && items[0].tok.kind == .Number {
			if items[0].tok.num < 0 { return false }
			c.line_height = Line_Height{kind = .Number, v = f32(items[0].tok.num)}
			return true
		}
		l, ok := parse_length(cx, vs, {.Percent})
		if !ok { return false }
		#partial switch l.kind {
		case .Px: c.line_height = Line_Height{kind = .Length, v = l.v}
		case .Percent: c.line_height = Line_Height{kind = .Length, v = c.font_size * l.v / 100}
		case .Calc: c.line_height = Line_Height{kind = .Length, v = f32(css.eval_calc(l.calc, css.Length_Context{percent_base = f64(c.font_size)}))}
		case: return false
		}
	case .Letter_Spacing, .Word_Spacing:
		if id, ok := ident_raw(vs); ok && strings.equal_fold(id, "normal") {
			if p == .Letter_Spacing { c.letter_spacing = 0 } else { c.word_spacing = 0 }
			return true
		}
		l, ok := parse_length(cx, vs, {.Negative})
		if !ok || l.kind != .Px { return false }
		if p == .Letter_Spacing { c.letter_spacing = l.v } else { c.word_spacing = l.v }
	case .Text_Align:
		if id, ok := ident_raw(vs); ok {
			switch strings.to_lower(id, context.temp_allocator) {
			case "-webkit-center": c.text_align = .Center; return true
			case "-webkit-left": c.text_align = .Left; return true
			case "-webkit-right": c.text_align = .Right; return true
			case "justify-all": c.text_align = .Justify; return true
			case "match-parent": c.text_align = .Start; return true
			}
		}
		return set_enum(vs, &c.text_align)
	case .Text_Decoration_Line:
		if id, ok := ident_raw(vs); ok && strings.equal_fold(id, "none") { c.text_decoration = {}; return true }
		set: Decorations
		for it in split_items(vs) {
			if it.kind != .Token || it.tok.kind != .Ident { return false }
			switch strings.to_lower(it.tok.text, context.temp_allocator) {
			case "underline": set += {.Underline}
			case "overline": set += {.Overline}
			case "line-through": set += {.Line_Through}
			case "blink":
			case: return false
			}
		}
		c.text_decoration = set
	case .Text_Decoration_Color:
		col, ok := parse_color(cx, vs)
		if !ok { return false }
		c.text_decoration_color = col
		cx.explicit += {p}
	case .Text_Transform: return set_enum(vs, &c.text_transform)
	case .Text_Indent:
		l, ok := parse_length(cx, vs, {.Percent, .Negative})
		if !ok { return false }
		c.text_indent = l
	case .Text_Overflow:
		id, ok := ident_raw(vs)
		if !ok { return false }
		switch strings.to_lower(id, context.temp_allocator) {
		case "clip": c.text_ellipsis = false
		case "ellipsis": c.text_ellipsis = true
		case: return false
		}
	case .White_Space:
		if id, ok := ident_raw(vs); ok && strings.equal_fold(id, "nowrap") { c.white_space = .Nowrap; return true }
		return set_enum(vs, &c.white_space)
	case .Word_Break: return set_enum(vs, &c.word_break)
	case .Overflow_Wrap: return set_enum(vs, &c.overflow_wrap)
	case .Tab_Size:
		if n, ok := number_in(vs, 0, 1e6); ok { c.tab_size = n * f32(c.font_size) * 0.5; return true }   // a tab stop counts space widths
		l, ok := parse_length(cx, vs, {})
		if !ok || l.kind != .Px { return false }
		c.tab_size = l.v
	case .Direction: return set_enum(vs, &c.direction)
	case .Text_Shadow:
		sh, ok := parse_shadows(cx, vs)
		if !ok { return false }
		c.text_shadow = sh
	case .Display:
		id, ok := ident_raw(vs)
		if !ok {
			// two-keyword syntax: `block flow`, `inline flow-root`, `block flex`...
			items := split_items(vs)
			if len(items) != 2 || items[0].kind != .Token || items[1].kind != .Token { return false }
			a := strings.to_lower(items[0].tok.text, context.temp_allocator)
			b := strings.to_lower(items[1].tok.text, context.temp_allocator)
			if a == "flow" { a, b = b, a }
			switch {
			case a == "block" && b == "flow": c.display = .Block
			case a == "inline" && b == "flow": c.display = .Inline
			case a == "block" && b == "flow-root": c.display = .Flow_Root
			case a == "inline" && b == "flow-root": c.display = .Inline_Block
			case a == "block" && b == "flex": c.display = .Flex
			case a == "inline" && b == "flex": c.display = .Inline_Flex
			case a == "block" && b == "grid": c.display = .Grid
			case a == "inline" && b == "grid": c.display = .Inline_Grid
			case a == "list-item" && b == "block", a == "block" && b == "list-item": c.display = .List_Item
			case: return false
			}
			return true
		}
		switch strings.to_lower(id, context.temp_allocator) {
		case "-webkit-box": c.display = .Flex
		case "-webkit-inline-box": c.display = .Inline_Flex
		case "run-in": c.display = .Block
		case: return set_enum(vs, &c.display)
		}
	case .Position: return set_enum(vs, &c.position)
	case .Float:
		if id, ok := ident_raw(vs); ok {
			switch strings.to_lower(id, context.temp_allocator) {
			case "inline-start": c.float = c.direction == .Ltr ? .Left : .Right; return true
			case "inline-end": c.float = c.direction == .Ltr ? .Right : .Left; return true
			}
		}
		return set_enum(vs, &c.float)
	case .Clear: return set_enum(vs, &c.clear)
	case .Top, .Right, .Bottom, .Left:
		l, ok := parse_length(cx, vs, {.Auto, .Percent, .Negative})
		if !ok { return false }
		c.inset[Side(int(p) - int(Prop.Top))] = l
	case .Z_Index:
		if id, ok := ident_raw(vs); ok && strings.equal_fold(id, "auto") { c.z_auto = true; return true }
		n, ok := css.parse_integer(vs)
		if !ok { return false }
		c.z_auto, c.z_index = false, i32(clamp(n, -2_000_000_000, 2_000_000_000))
	case .Box_Sizing: return set_enum(vs, &c.box_sizing)
	case .Width, .Height, .Min_Width, .Min_Height, .Max_Width, .Max_Height:
		flags := Len_Flags{.Percent, .Intrinsic}
		#partial switch p {
		case .Width, .Height: flags += {.Auto}
		case .Min_Width, .Min_Height: flags += {.Auto}
		case: flags += {.None}
		}
		l, ok := parse_length(cx, vs, flags)
		if !ok { return false }
		#partial switch p {
		case .Width: c.width = l
		case .Height: c.height = l
		case .Min_Width: c.min_width = l.kind == .Auto ? px(0) : l
		case .Min_Height: c.min_height = l.kind == .Auto ? px(0) : l
		case .Max_Width: c.max_width = l
		case .Max_Height: c.max_height = l
		}
	case .Margin_Top, .Margin_Right, .Margin_Bottom, .Margin_Left:
		l, ok := parse_length(cx, vs, {.Auto, .Percent, .Negative})
		if !ok { return false }
		c.margin[Side(int(p) - int(Prop.Margin_Top))] = l
	case .Padding_Top, .Padding_Right, .Padding_Bottom, .Padding_Left:
		l, ok := parse_length(cx, vs, {.Percent})
		if !ok { return false }
		c.padding[Side(int(p) - int(Prop.Padding_Top))] = l
	case .Border_Top_Style, .Border_Right_Style, .Border_Bottom_Style, .Border_Left_Style:
		return set_enum(vs, &c.border_style[Side(int(p) - int(Prop.Border_Top_Style))])
	case .Border_Top_Width, .Border_Right_Width, .Border_Bottom_Width, .Border_Left_Width:
		w, ok := parse_line_width(cx, vs)
		if !ok { return false }
		c.border_width[Side(int(p) - int(Prop.Border_Top_Width))] = w
	case .Border_Top_Color, .Border_Right_Color, .Border_Bottom_Color, .Border_Left_Color:
		col, ok := parse_color(cx, vs)
		if !ok { return false }
		c.border_color[Side(int(p) - int(Prop.Border_Top_Color))] = col
		cx.explicit += {p}
	case .Border_Top_Left_Radius, .Border_Top_Right_Radius, .Border_Bottom_Right_Radius, .Border_Bottom_Left_Radius:
		items := split_items(vs)
		if len(items) < 1 || len(items) > 2 { return false }
		one := [1]css.Value{items[0]}
		h, ok := parse_length(cx, one[:], {.Percent})
		if !ok { return false }
		v := h
		if len(items) == 2 {
			two := [1]css.Value{items[1]}
			v, ok = parse_length(cx, two[:], {.Percent})
			if !ok { return false }
		}
		c.radius[Corner(int(p) - int(Prop.Border_Top_Left_Radius))] = Corner_Radius{h, v}
	case .Overflow_X, .Overflow_Y:
		o: Overflow
		if id, ok := ident_raw(vs); ok && strings.equal_fold(id, "overlay") { o = .Auto } else if !set_enum(vs, &o) { return false }
		if p == .Overflow_X { c.overflow_x = o } else { c.overflow_y = o }
	case .Visibility: return set_enum(vs, &c.visibility)
	case .Opacity:
		items := css.trim_values(vs)
		if len(items) == 1 && items[0].kind == .Token && items[0].tok.kind == .Percentage { c.opacity = clamp(f32(items[0].tok.num) / 100, 0, 1); return true }
		n, ok := css.parse_number(vs)
		if !ok { return false }
		c.opacity = clamp(f32(n), 0, 1)
	case .Vertical_Align:
		if id, ok := ident_raw(vs); ok {
			lid := strings.to_lower(id, context.temp_allocator)
			k: Vertical_Align_Kind
			switch lid {
			case "baseline": k = .Baseline
			case "sub": k = .Sub
			case "super": k = .Super
			case "top": k = .Top
			case "text-top": k = .Text_Top
			case "middle": k = .Middle
			case "bottom": k = .Bottom
			case "text-bottom": k = .Text_Bottom
			case: return false
			}
			c.vertical_align = Vertical_Align{kind = k}
			return true
		}
		l, ok := parse_length(cx, vs, {.Percent, .Negative})
		if !ok { return false }
		c.vertical_align = Vertical_Align{kind = .Length, amount = l}
	case .Aspect_Ratio:
		items := split_items(vs)
		ratio := f32(0)
		have := false
		i := 0
		for i < len(items) {
			it := items[i]
			if it.kind == .Token && it.tok.kind == .Ident {
				if !strings.equal_fold(it.tok.text, "auto") { return false }
				i += 1
				continue
			}
			if it.kind == .Token && it.tok.kind == .Number && it.tok.num > 0 {
				num := f32(it.tok.num)
				den := f32(1)
				if i + 2 < len(items) && items[i + 1].kind == .Token && items[i + 1].tok.kind == .Delim && items[i + 1].tok.text == "/" {
					if items[i + 2].kind != .Token || items[i + 2].tok.kind != .Number || items[i + 2].tok.num <= 0 { return false }
					den = f32(items[i + 2].tok.num)
					i += 2
				}
				ratio, have = num / den, true
				i += 1
				continue
			}
			return false
		}
		if !have && len(items) != 1 { return false }
		c.aspect_ratio = ratio
	case .Object_Fit: return set_enum(vs, &c.object_fit)
	case .Flex_Direction: return set_enum(vs, &c.flex_direction)
	case .Flex_Wrap: return set_enum(vs, &c.flex_wrap)
	case .Flex_Grow, .Flex_Shrink:
		n, ok := number_in(vs, 0, 1e9)
		if !ok { return false }
		if p == .Flex_Grow { c.flex_grow = n } else { c.flex_shrink = n }
	case .Flex_Basis:
		if id, ok := ident_raw(vs); ok && strings.equal_fold(id, "content") { c.flex_basis = Length{kind = .Max_Content}; return true }
		l, ok := parse_length(cx, vs, {.Auto, .Percent, .Intrinsic})
		if !ok { return false }
		c.flex_basis = l
	case .Justify_Content, .Align_Items, .Align_Self, .Align_Content:
		a: Content_Align
		if id, ok := ident_raw(vs); ok {
			switch strings.to_lower(id, context.temp_allocator) {
			case "left", "self-start", "start": a = .Start
			case "right", "self-end", "end": a = .End
			case "safe", "unsafe": return false
			case: if !set_enum(vs, &a) { return false }
			}
		} else {
			items := split_items(vs)   // `first baseline`, `safe center`
			if len(items) != 2 || items[1].kind != .Token { return false }
			one := [1]css.Value{items[1]}
			if !set_enum(one[:], &a) { return false }
		}
		#partial switch p {
		case .Justify_Content: c.justify_content = a
		case .Align_Items: c.align_items = a
		case .Align_Self: c.align_self = a
		case .Align_Content: c.align_content = a
		}
	case .Order:
		n, ok := css.parse_integer(vs)
		if !ok { return false }
		c.order = i32(clamp(n, -2_000_000_000, 2_000_000_000))
	case .Row_Gap, .Column_Gap:
		l, ok := parse_length(cx, vs, {.Normal, .Percent})
		if !ok { return false }
		if p == .Row_Gap { c.row_gap = l } else { c.column_gap = l }
	case .Background_Color:
		col, ok := parse_color(cx, vs)
		if !ok { return false }
		c.background_color = col
	case .Background_Image:
		first := css.split_commas(css.trim_values(vs), context.temp_allocator)
		img, ok := parse_image(cx, first[0])
		if !ok { return false }
		for rest in first[1:] { if _, good := parse_image(cx, rest); !good { return false } }
		c.background_image = img
	case .Background_Repeat:
		items := split_items(css.split_commas(css.trim_values(vs), context.temp_allocator)[0])
		if len(items) == 1 && items[0].kind == .Token && items[0].tok.kind == .Ident {
			switch strings.to_lower(items[0].tok.text, context.temp_allocator) {
			case "repeat-x": c.background_repeat = {.Repeat, .No_Repeat}; return true
			case "repeat-y": c.background_repeat = {.No_Repeat, .Repeat}; return true
			}
		}
		if len(items) < 1 || len(items) > 2 { return false }
		r: [2]Repeat
		for it, i in items {
			one := [1]css.Value{it}
			if !set_enum(one[:], &r[i]) { return false }
			if r[i] == .Repeat_X || r[i] == .Repeat_Y { return false }
		}
		if len(items) == 1 { r[1] = r[0] }
		c.background_repeat = r
	case .Background_Position:
		return apply_background_position(cx, css.split_commas(css.trim_values(vs), context.temp_allocator)[0])
	case .Background_Size:
		items := split_items(css.split_commas(css.trim_values(vs), context.temp_allocator)[0])
		if len(items) < 1 || len(items) > 2 { return false }
		if len(items) == 1 {
			if id, ok := ident_raw(items); ok {
				switch strings.to_lower(id, context.temp_allocator) {
				case "cover": c.background_size = Bg_Size{kind = .Cover}; return true
				case "contain": c.background_size = Bg_Size{kind = .Contain}; return true
				}
			}
		}
		w, ok := parse_length(cx, items[:1], {.Auto, .Percent})
		if !ok { return false }
		h := auto_length
		if len(items) == 2 {
			h, ok = parse_length(cx, items[1:], {.Auto, .Percent})
			if !ok { return false }
		}
		c.background_size = Bg_Size{kind = .Length, w = w, h = h}
	case .Box_Shadow:
		sh, ok := parse_shadows(cx, vs)
		if !ok { return false }
		c.box_shadow = sh
	case .List_Style_Type:
		if id, ok := ident_raw(vs); ok {
			switch strings.to_lower(id, context.temp_allocator) {
			case "lower-latin": c.list_style_type = .Lower_Alpha; return true
			case "upper-latin": c.list_style_type = .Upper_Alpha; return true
			case "disclosure-open", "disclosure-closed": c.list_style_type = .Disc; return true
			}
		} else if items := css.trim_values(vs); len(items) == 1 && items[0].kind == .Token && items[0].tok.kind == .String {
			c.list_style_type = .Disc   // custom markers are not rendered: a bullet is the nearest honest answer
			return true
		}
		return set_enum(vs, &c.list_style_type)
	case .List_Style_Position: return set_enum(vs, &c.list_style_position)
	case .Cursor:
		found := false
		for part in css.split_commas(css.trim_values(vs), context.temp_allocator) {
			items := css.trim_values(part)
			if len(items) >= 1 && items[0].kind == .Token && items[0].tok.kind == .Ident {
				cur: Cursor
				if id, _ := ident_raw(items[:1]); strings.equal_fold(id, "all-scroll") {
					cur = .Move
				} else if !set_enum(items[:1], &cur) {
					cur = .Auto
				}
				c.cursor = cur
				found = true
			}
		}
		return found
	case .Pointer_Events:
		id, ok := ident_raw(vs)
		if !ok { return false }
		switch strings.to_lower(id, context.temp_allocator) {
		case "none": c.pointer_events = false
		case "auto", "all", "visible", "visiblepainted", "visiblefill", "visiblestroke", "painted", "fill", "stroke": c.pointer_events = true
		case: return false
		}
	case .User_Select: return set_enum(vs, &c.user_select)
	case .Content:
		ct, ok := parse_content(cx, vs)
		if !ok { return false }
		c.content = ct
	case .Outline_Width:
		w, ok := parse_line_width(cx, vs)
		if !ok { return false }
		c.outline_width = w
	case .Outline_Style:
		if id, ok := ident_raw(vs); ok && strings.equal_fold(id, "auto") { c.outline_style = .Solid; return true }
		return set_enum(vs, &c.outline_style)
	case .Outline_Color:
		col, ok := parse_color(cx, vs)
		if !ok { return false }
		c.outline_color = col
		cx.explicit += {p}
	case .Outline_Offset:
		l, ok := parse_length(cx, vs, {.Negative})
		if !ok || l.kind != .Px { return false }
		c.outline_offset = l.v
	case .Border_Collapse:
		id, ok := ident_raw(vs)
		if !ok { return false }
		switch strings.to_lower(id, context.temp_allocator) {
		case "collapse": c.border_collapse = true
		case "separate": c.border_collapse = false
		case: return false
		}
	case .Border_Spacing:
		items := split_items(vs)
		if len(items) < 1 || len(items) > 2 { return false }
		a, ok := parse_length(cx, items[:1], {})
		if !ok || a.kind != .Px { return false }
		b := a
		if len(items) == 2 {
			b, ok = parse_length(cx, items[1:], {})
			if !ok || b.kind != .Px { return false }
		}
		c.border_spacing = {a.v, b.v}
	}
	return true
}

parse_line_width :: proc(cx: ^Cx, vs: []css.Value) -> (f32, bool) {
	if id, ok := ident_raw(vs); ok {
		switch strings.to_lower(id, context.temp_allocator) {
		case "thin": return 1, true
		case "medium": return 3, true
		case "thick": return 5, true
		}
		return 0, false
	}
	l, ok := parse_length(cx, vs, {})
	if !ok || l.kind != .Px { return 0, false }
	if l.v > 0 && l.v < 1 { return 1, true }   // like other engines: a visible border is at least one pixel
	return math.floor(l.v), true
}
