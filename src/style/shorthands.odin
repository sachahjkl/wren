package style

import "base:runtime"
import "core:reflect"
import "core:strings"
import "core:sync"
import "wb:css"
import "wb:base"

// Property names and shorthand expansion. Shorthands are split into longhands when a stylesheet is compiled, so the cascade
// only ever compares longhands.

Longhand :: struct {
	prop: Prop,
	vals: []css.Value,
}

@(private) tables_ready: bool
@(private) prop_by_name: map[string]Prop
@(private) short_by_name: map[string]Short
@(private) alias_by_name: map[string]string
@(private) prop_names: [Prop]string

@(private) INITIAL_KW := [1]css.Value{{kind = .Token, tok = {kind = .Ident, text = "initial"}}}
@(private) WS_VALUE := css.Value{kind = .Token, tok = {kind = .Whitespace}}

dashed :: proc(enum_name: string) -> string {
	b := make([]u8, len(enum_name))
	for i in 0 ..< len(enum_name) {
		ch := enum_name[i]
		if ch >= 'A' && ch <= 'Z' { ch += 32 }
		if ch == '_' { ch = '-' }
		b[i] = ch
	}
	return string(b)
}

@(private) tables_once: sync.Once

// Builds the name tables. Safe to call repeatedly and from several threads; they live for the whole process.
tables_init :: proc() {
	props_init()
	sync.once_do(&tables_once, tables_build)
}

@(private)
tables_build :: proc() {
	context.allocator = base.process_allocator()
	tables_ready = true
	prop_by_name = make(map[string]Prop)
	short_by_name = make(map[string]Short)
	alias_by_name = make(map[string]string)
	for p in Prop {
		n := dashed(reflect.enum_string(p))
		prop_names[p] = n
		prop_by_name[n] = p
	}
	for s in Short {
		if s == .None { continue }
		short_by_name[dashed(reflect.enum_string(s))] = s
	}
	alias_by_name["word-wrap"] = "overflow-wrap"
	alias_by_name["grid-gap"] = "gap"
	alias_by_name["grid-row-gap"] = "row-gap"
	alias_by_name["grid-column-gap"] = "column-gap"
	alias_by_name["-webkit-box-shadow"] = "box-shadow"
	alias_by_name["-webkit-user-select"] = "user-select"
	alias_by_name["-moz-user-select"] = "user-select"
	alias_by_name["-webkit-box-sizing"] = "box-sizing"
	alias_by_name["-moz-box-sizing"] = "box-sizing"
	alias_by_name["-webkit-border-radius"] = "border-radius"
	alias_by_name["-moz-tab-size"] = "tab-size"
	for name in ([?]string{
		"transition", "transition-property", "transition-duration", "transition-timing-function", "transition-delay",
		"animation", "animation-name", "animation-duration", "animation-timing-function", "animation-delay",
		"animation-iteration-count", "animation-direction", "animation-fill-mode", "animation-play-state",
		"transform", "transform-origin", "transform-style", "backface-visibility", "perspective", "perspective-origin",
		"filter", "backdrop-filter", "appearance", "clip-path", "hyphens", "text-decoration-style", "text-decoration-color",
		"text-decoration-line", "text-decoration-thickness", "text-underline-offset", "font-variant-caps", "background-clip",
		"background-origin", "user-select", "column-count", "column-width", "columns", "column-gap", "text-decoration",
	}) {
		alias_by_name[strings.concatenate({"-webkit-", name})] = name
		alias_by_name[strings.concatenate({"-moz-", name})] = name
	}
	// logical properties, mapped for horizontal left-to-right text (writing modes are not supported)
	for pair in ([?][2]string{
		{"margin-block-start", "margin-top"}, {"margin-block-end", "margin-bottom"}, {"margin-inline-start", "margin-left"}, {"margin-inline-end", "margin-right"},
		{"padding-block-start", "padding-top"}, {"padding-block-end", "padding-bottom"}, {"padding-inline-start", "padding-left"}, {"padding-inline-end", "padding-right"},
		{"inset-block-start", "top"}, {"inset-block-end", "bottom"}, {"inset-inline-start", "left"}, {"inset-inline-end", "right"},
		{"inline-size", "width"}, {"block-size", "height"}, {"min-inline-size", "min-width"}, {"min-block-size", "min-height"},
		{"max-inline-size", "max-width"}, {"max-block-size", "max-height"},
		{"border-block-start-width", "border-top-width"}, {"border-block-end-width", "border-bottom-width"},
		{"border-inline-start-width", "border-left-width"}, {"border-inline-end-width", "border-right-width"},
		{"border-block-start-style", "border-top-style"}, {"border-block-end-style", "border-bottom-style"},
		{"border-inline-start-style", "border-left-style"}, {"border-inline-end-style", "border-right-style"},
		{"border-block-start-color", "border-top-color"}, {"border-block-end-color", "border-bottom-color"},
		{"border-inline-start-color", "border-left-color"}, {"border-inline-end-color", "border-right-color"},
		{"border-start-start-radius", "border-top-left-radius"}, {"border-start-end-radius", "border-top-right-radius"},
		{"border-end-end-radius", "border-bottom-right-radius"}, {"border-end-start-radius", "border-bottom-left-radius"},
		{"border-block-start", "border-top"}, {"border-block-end", "border-bottom"}, {"border-inline-start", "border-left"}, {"border-inline-end", "border-right"},
	}) { alias_by_name[pair[0]] = pair[1] }
	mask_names()
}

// A property name as written in CSS: a longhand, a shorthand or neither.
lookup_property :: proc(name: string) -> (p: Prop, s: Short, known: bool) {
	n := name
	if a, ok := alias_by_name[n]; ok { n = a }
	if pr, ok := prop_by_name[n]; ok { return pr, .None, true }
	if sh, ok := short_by_name[n]; ok { return {}, sh, true }
	return {}, .None, false
}

prop_name :: proc(p: Prop) -> string { return prop_names[p] }

short_longhands :: proc(s: Short) -> []Prop {
	@(static) margin := [?]Prop{.Margin_Top, .Margin_Right, .Margin_Bottom, .Margin_Left}
	@(static) padding := [?]Prop{.Padding_Top, .Padding_Right, .Padding_Bottom, .Padding_Left}
	@(static) border_all := [?]Prop{
		.Border_Top_Width, .Border_Right_Width, .Border_Bottom_Width, .Border_Left_Width,
		.Border_Top_Style, .Border_Right_Style, .Border_Bottom_Style, .Border_Left_Style,
		.Border_Top_Color, .Border_Right_Color, .Border_Bottom_Color, .Border_Left_Color,
	}
	@(static) border_width := [?]Prop{.Border_Top_Width, .Border_Right_Width, .Border_Bottom_Width, .Border_Left_Width}
	@(static) border_style := [?]Prop{.Border_Top_Style, .Border_Right_Style, .Border_Bottom_Style, .Border_Left_Style}
	@(static) border_color := [?]Prop{.Border_Top_Color, .Border_Right_Color, .Border_Bottom_Color, .Border_Left_Color}
	@(static) b_top := [?]Prop{.Border_Top_Width, .Border_Top_Style, .Border_Top_Color}
	@(static) b_right := [?]Prop{.Border_Right_Width, .Border_Right_Style, .Border_Right_Color}
	@(static) b_bottom := [?]Prop{.Border_Bottom_Width, .Border_Bottom_Style, .Border_Bottom_Color}
	@(static) b_left := [?]Prop{.Border_Left_Width, .Border_Left_Style, .Border_Left_Color}
	@(static) radius := [?]Prop{.Border_Top_Left_Radius, .Border_Top_Right_Radius, .Border_Bottom_Right_Radius, .Border_Bottom_Left_Radius}
	@(static) background := [?]Prop{.Background_Color, .Background_Image, .Background_Repeat, .Background_Position, .Background_Size, .Background_Origin, .Background_Clip, .Background_Attachment}
	@(static) font := [?]Prop{.Font_Style, .Font_Variant_Caps, .Font_Weight, .Font_Stretch, .Font_Size, .Line_Height, .Font_Family,
		.Font_Variant_Ligatures, .Font_Variant_Numeric, .Font_Variant_East_Asian, .Font_Variant_Position, .Font_Kerning,
		.Font_Feature_Settings, .Font_Variation_Settings}
	@(static) white_space := [?]Prop{.White_Space_Collapse, .Text_Wrap_Mode}
	@(static) text_wrap := [?]Prop{.Text_Wrap_Mode, .Text_Wrap_Style}
	@(static) font_variant := [?]Prop{.Font_Variant_Ligatures, .Font_Variant_Caps, .Font_Variant_Numeric, .Font_Variant_East_Asian, .Font_Variant_Position}
	@(static) transition := [?]Prop{.Transition_Property, .Transition_Duration, .Transition_Timing_Function, .Transition_Delay, .Transition_Behavior}
	@(static) animation := [?]Prop{.Animation_Name, .Animation_Duration, .Animation_Timing_Function, .Animation_Delay, .Animation_Iteration_Count, .Animation_Direction, .Animation_Fill_Mode, .Animation_Play_State, .Animation_Composition}
	@(static) overscroll := [?]Prop{.Overscroll_Behavior_X, .Overscroll_Behavior_Y}
	@(static) columns := [?]Prop{.Column_Width, .Column_Count}
	@(static) grid_template := [?]Prop{.Grid_Template_Rows, .Grid_Template_Columns, .Grid_Template_Areas}
	@(static) grid := [?]Prop{.Grid_Template_Rows, .Grid_Template_Columns, .Grid_Template_Areas, .Grid_Auto_Rows, .Grid_Auto_Columns, .Grid_Auto_Flow}
	@(static) grid_row := [?]Prop{.Grid_Row_Start, .Grid_Row_End}
	@(static) grid_column := [?]Prop{.Grid_Column_Start, .Grid_Column_End}
	@(static) grid_area := [?]Prop{.Grid_Row_Start, .Grid_Column_Start, .Grid_Row_End, .Grid_Column_End}
	@(static) flex := [?]Prop{.Flex_Grow, .Flex_Shrink, .Flex_Basis}
	@(static) flex_flow := [?]Prop{.Flex_Direction, .Flex_Wrap}
	@(static) gap := [?]Prop{.Row_Gap, .Column_Gap}
	@(static) overflow := [?]Prop{.Overflow_X, .Overflow_Y}
	@(static) inset := [?]Prop{.Top, .Right, .Bottom, .Left}
	@(static) list_style := [?]Prop{.List_Style_Type, .List_Style_Position}
	@(static) text_decoration := [?]Prop{.Text_Decoration_Line, .Text_Decoration_Color, .Text_Decoration_Style, .Text_Decoration_Thickness}
	@(static) outline := [?]Prop{.Outline_Width, .Outline_Style, .Outline_Color}
	@(static) place_content := [?]Prop{.Align_Content, .Justify_Content}
	@(static) place_items := [?]Prop{.Align_Items, .Justify_Items}
	@(static) place_self := [?]Prop{.Align_Self, .Justify_Self}
	@(static) margin_block := [?]Prop{.Margin_Top, .Margin_Bottom}
	@(static) margin_inline := [?]Prop{.Margin_Left, .Margin_Right}
	@(static) padding_block := [?]Prop{.Padding_Top, .Padding_Bottom}
	@(static) padding_inline := [?]Prop{.Padding_Left, .Padding_Right}
	@(static) inset_block := [?]Prop{.Top, .Bottom}
	@(static) inset_inline := [?]Prop{.Left, .Right}
	@(static) container := [?]Prop{.Container_Name, .Container_Type}
	@(static) border_block := [?]Prop{.Border_Top_Width, .Border_Bottom_Width, .Border_Top_Style, .Border_Bottom_Style, .Border_Top_Color, .Border_Bottom_Color}
	@(static) border_inline := [?]Prop{.Border_Left_Width, .Border_Right_Width, .Border_Left_Style, .Border_Right_Style, .Border_Left_Color, .Border_Right_Color}
	@(static) bb_width := [?]Prop{.Border_Top_Width, .Border_Bottom_Width}
	@(static) bb_style := [?]Prop{.Border_Top_Style, .Border_Bottom_Style}
	@(static) bb_color := [?]Prop{.Border_Top_Color, .Border_Bottom_Color}
	@(static) bi_width := [?]Prop{.Border_Left_Width, .Border_Right_Width}
	@(static) bi_style := [?]Prop{.Border_Left_Style, .Border_Right_Style}
	@(static) bi_color := [?]Prop{.Border_Left_Color, .Border_Right_Color}
	@(static) mask := [?]Prop{.Mask_Image, .Mask_Mode, .Mask_Repeat, .Mask_Position, .Mask_Size, .Mask_Origin, .Mask_Clip, .Mask_Composite}
	switch s {
	case .Mask: return mask[:]
	case .Container: return container[:]
	case .Border_Block: return border_block[:]
	case .Border_Inline: return border_inline[:]
	case .Border_Block_Width: return bb_width[:]
	case .Border_Block_Style: return bb_style[:]
	case .Border_Block_Color: return bb_color[:]
	case .Border_Inline_Width: return bi_width[:]
	case .Border_Inline_Style: return bi_style[:]
	case .Border_Inline_Color: return bi_color[:]
	case .None: return nil
	case .Margin: return margin[:]
	case .Padding: return padding[:]
	case .Border: return border_all[:]
	case .Border_Width: return border_width[:]
	case .Border_Style: return border_style[:]
	case .Border_Color: return border_color[:]
	case .Border_Top: return b_top[:]
	case .Border_Right: return b_right[:]
	case .Border_Bottom: return b_bottom[:]
	case .Border_Left: return b_left[:]
	case .Border_Radius: return radius[:]
	case .Background: return background[:]
	case .Font: return font[:]
	case .Flex: return flex[:]
	case .Flex_Flow: return flex_flow[:]
	case .Gap: return gap[:]
	case .Overflow: return overflow[:]
	case .Inset: return inset[:]
	case .List_Style: return list_style[:]
	case .Text_Decoration: return text_decoration[:]
	case .Outline: return outline[:]
	case .Place_Content: return place_content[:]
	case .Place_Items: return place_items[:]
	case .Place_Self: return place_self[:]
	case .Margin_Block: return margin_block[:]
	case .Margin_Inline: return margin_inline[:]
	case .Padding_Block: return padding_block[:]
	case .Padding_Inline: return padding_inline[:]
	case .Inset_Block: return inset_block[:]
	case .Inset_Inline: return inset_inline[:]
	case .White_Space: return white_space[:]
	case .Text_Wrap: return text_wrap[:]
	case .Font_Variant: return font_variant[:]
	case .Transition: return transition[:]
	case .Animation: return animation[:]
	case .Overscroll_Behavior: return overscroll[:]
	case .Columns: return columns[:]
	case .Grid_Template: return grid_template[:]
	case .Grid: return grid[:]
	case .Grid_Row: return grid_row[:]
	case .Grid_Column: return grid_column[:]
	case .Grid_Area: return grid_area[:]
	}
	return nil
}

////////////////////////////////
// Helpers

@(private)
is_ident :: proc(v: css.Value, name: string) -> bool {
	return v.kind == .Token && v.tok.kind == .Ident && strings.equal_fold(v.tok.text, name)
}

@(private)
is_delim :: proc(v: css.Value, d: string) -> bool { return v.kind == .Token && v.tok.kind == .Delim && v.tok.text == d }

@(private)
join_items :: proc(items: []css.Value, a: runtime.Allocator) -> []css.Value {
	out := make([dynamic]css.Value, a)
	for it, i in items {
		if i > 0 { append(&out, WS_VALUE) }
		append(&out, it)
	}
	return out[:]
}

// 1 to 4 items -> top, right, bottom, left.
@(private)
box4 :: proc(items: []css.Value, a: runtime.Allocator) -> (out: [4][]css.Value, ok: bool) {
	n := len(items)
	if n < 1 || n > 4 { return {}, false }
	sl := make([]css.Value, n, a)
	copy(sl, items)
	t := sl[0:1]
	r, b, l := t, t, t
	if n >= 2 { r = sl[1:2]; l = r }
	if n >= 3 { b = sl[2:3] }
	if n >= 4 { l = sl[3:4] }
	return {t, r, b, l}, true
}

@(private)
is_width_item :: proc(v: css.Value) -> bool {
	#partial switch v.kind {
	case .Token:
		#partial switch v.tok.kind {
		case .Dimension, .Number: return true
		case .Ident: switch css.lower_temp(v.tok.text) { case "thin", "medium", "thick": return true }
		}
	case .Function:
		return css.is_math_function(v.tok.text)
	}
	return false
}

@(private)
is_line_style_item :: proc(v: css.Value) -> bool {
	if v.kind != .Token || v.tok.kind != .Ident { return false }
	one := [1]css.Value{v}
	_, ok := parse_enum(one[:], Border_Style)
	return ok || strings.equal_fold(v.tok.text, "auto")
}

// width / style / color in any order, each at most once (border, outline).
@(private)
line_parts :: proc(items: []css.Value) -> (w, st, col: []css.Value, ok: bool) {
	for it, i in items {
		switch {
		case is_width_item(it):
			if w != nil { return }
			w = items[i:i + 1]
		case is_line_style_item(it):
			if st != nil { return }
			st = items[i:i + 1]
		case:
			if col != nil { return }
			col = items[i:i + 1]
		}
	}
	return w, st, col, true
}

@(private)
or_initial :: proc(v: []css.Value) -> []css.Value { return v != nil ? v : INITIAL_KW[:] }

////////////////////////////////
// Expansion

// Splits a shorthand into longhand declarations. Values are slices of `vs` or of memory from `a`.
expand_shorthand :: proc(s: Short, vs: []css.Value, a: runtime.Allocator) -> ([]Longhand, bool) {
	res := make([dynamic]Longhand, a)
	items := split_items(vs, a)
	emit :: proc(res: ^[dynamic]Longhand, p: Prop, v: []css.Value) { append(res, Longhand{p, v}) }

	switch s {
	case .None: return nil, false
	case .Margin, .Padding, .Border_Width, .Border_Style, .Border_Color, .Inset:
		b, good := box4(items, a)
		if !good { return nil, false }
		props := short_longhands(s)
		for p, i in props { emit(&res, p, b[i]) }

	case .Border_Radius:
		slash := -1
		for it, i in items { if is_delim(it, "/") { slash = i; break } }
		hs := slash >= 0 ? items[:slash] : items
		hb, good := box4(hs, a)
		if !good { return nil, false }
		vb := hb
		if slash >= 0 {
			vb, good = box4(items[slash + 1:], a)
			if !good { return nil, false }
		}
		for p, i in short_longhands(.Border_Radius) {
			if slash >= 0 {
				pair := make([]css.Value, 3, a)
				pair[0], pair[1], pair[2] = hb[i][0], WS_VALUE, vb[i][0]
				emit(&res, p, pair)
			} else { emit(&res, p, hb[i]) }
		}

	case .Border, .Border_Top, .Border_Right, .Border_Bottom, .Border_Left:
		if len(items) == 0 { return nil, false }
		w, st, col, good := line_parts(items)
		if !good { return nil, false }
		if s == .Border {
			ws, ss, cs := [?]Prop{.Border_Top_Width, .Border_Right_Width, .Border_Bottom_Width, .Border_Left_Width}, [?]Prop{.Border_Top_Style, .Border_Right_Style, .Border_Bottom_Style, .Border_Left_Style}, [?]Prop{.Border_Top_Color, .Border_Right_Color, .Border_Bottom_Color, .Border_Left_Color}
			for i in 0 ..< 4 {
				emit(&res, ws[i], or_initial(w)); emit(&res, ss[i], or_initial(st)); emit(&res, cs[i], or_initial(col))
			}
		} else {
			props := short_longhands(s)
			emit(&res, props[0], or_initial(w)); emit(&res, props[1], or_initial(st)); emit(&res, props[2], or_initial(col))
		}

	case .Outline:
		if len(items) == 0 { return nil, false }
		w, st, col, good := line_parts(items)
		if !good { return nil, false }
		emit(&res, .Outline_Width, or_initial(w)); emit(&res, .Outline_Style, or_initial(st)); emit(&res, .Outline_Color, or_initial(col))

	case .Margin_Block, .Margin_Inline, .Padding_Block, .Padding_Inline, .Inset_Block, .Inset_Inline:
		if len(items) < 1 || len(items) > 2 { return nil, false }
		props: [2]Prop
		#partial switch s {
		case .Margin_Block: props = {.Margin_Top, .Margin_Bottom}
		case .Margin_Inline: props = {.Margin_Left, .Margin_Right}
		case .Padding_Block: props = {.Padding_Top, .Padding_Bottom}
		case .Padding_Inline: props = {.Padding_Left, .Padding_Right}
		case .Inset_Block: props = {.Top, .Bottom}
		case: props = {.Left, .Right}
		}
		emit(&res, props[0], items[0:1]); emit(&res, props[1], items[len(items) - 1:])

	case .Gap:
		if len(items) < 1 || len(items) > 2 { return nil, false }
		emit(&res, .Row_Gap, items[0:1])
		emit(&res, .Column_Gap, items[len(items) - 1:])

	case .Border_Block_Width, .Border_Block_Style, .Border_Block_Color, .Border_Inline_Width, .Border_Inline_Style, .Border_Inline_Color:
		// start and end (horizontal writing, left to right: block = top / bottom, inline = left / right)
		if len(items) < 1 || len(items) > 2 { return nil, false }
		props := short_longhands(s)
		emit(&res, props[0], items[0:1]); emit(&res, props[1], items[len(items) - 1:])

	case .Border_Block, .Border_Inline:
		if len(items) == 0 { return nil, false }
		w, st, col, good := line_parts(items)
		if !good { return nil, false }
		props := short_longhands(s)
		emit(&res, props[0], or_initial(w)); emit(&res, props[1], or_initial(w))
		emit(&res, props[2], or_initial(st)); emit(&res, props[3], or_initial(st))
		emit(&res, props[4], or_initial(col)); emit(&res, props[5], or_initial(col))

	case .Container:
		// <container-name> [ / <container-type> ]?
		slash := -1
		for it, i in items { if is_delim(it, "/") { slash = i; break } }
		names := slash >= 0 ? items[:slash] : items
		if len(names) == 0 { return nil, false }
		emit(&res, .Container_Name, join_items(names, a))
		if slash >= 0 {
			if slash + 1 >= len(items) { return nil, false }
			emit(&res, .Container_Type, join_items(items[slash + 1:], a))
		} else {
			emit(&res, .Container_Type, INITIAL_KW[:])
		}

	case .Overflow:
		if len(items) < 1 || len(items) > 2 { return nil, false }
		emit(&res, .Overflow_X, items[0:1])
		emit(&res, .Overflow_Y, items[len(items) - 1:])

	case .Place_Content:
		if len(items) < 1 || len(items) > 2 { return nil, false }
		emit(&res, .Align_Content, items[0:1])
		emit(&res, .Justify_Content, items[len(items) - 1:])
	case .Place_Items:
		if len(items) < 1 || len(items) > 2 { return nil, false }
		emit(&res, .Align_Items, items[0:1])
		emit(&res, .Justify_Items, items[len(items) - 1:])
	case .Place_Self:
		if len(items) < 1 || len(items) > 2 { return nil, false }
		emit(&res, .Align_Self, items[0:1])
		emit(&res, .Justify_Self, items[len(items) - 1:])

	case .Flex_Flow:
		if len(items) < 1 || len(items) > 2 { return nil, false }
		dir, wrap: []css.Value
		for it, i in items {
			one := [1]css.Value{it}
			if _, ok := parse_enum(one[:], Flex_Direction); ok { dir = items[i:i + 1] } else if _, ok2 := parse_enum(one[:], Flex_Wrap); ok2 { wrap = items[i:i + 1] } else { return nil, false }
		}
		emit(&res, .Flex_Direction, or_initial(dir)); emit(&res, .Flex_Wrap, or_initial(wrap))

	case .Flex:
		if len(items) == 1 && items[0].kind == .Token && items[0].tok.kind == .Ident {
			switch css.lower_temp(items[0].tok.text) {
			case "none":
				emit(&res, .Flex_Grow, zero_value(a)); emit(&res, .Flex_Shrink, zero_value(a)); emit(&res, .Flex_Basis, auto_value(a))
				return res[:], true
			case "auto":
				emit(&res, .Flex_Grow, one_value(a)); emit(&res, .Flex_Shrink, one_value(a)); emit(&res, .Flex_Basis, auto_value(a))
				return res[:], true
			case "initial":
				emit(&res, .Flex_Grow, zero_value(a)); emit(&res, .Flex_Shrink, one_value(a)); emit(&res, .Flex_Basis, auto_value(a))
				return res[:], true
			}
		}
		grow, shrink, basis: []css.Value
		for it, i in items {
			is_num := it.kind == .Token && it.tok.kind == .Number
			switch {
			case is_num && grow == nil: grow = items[i:i + 1]
			case is_num && shrink == nil && grow != nil: shrink = items[i:i + 1]
			// a unitless zero after the two factors is the basis (CSS Flexbox §7.2: `flex: 1 1 0`)
			case is_num && basis == nil && it.tok.num == 0: basis = items[i:i + 1]
			case !is_num && basis == nil: basis = items[i:i + 1]
			case: return nil, false
			}
		}
		if grow == nil && basis == nil { return nil, false }
		if grow == nil { grow = one_value(a) }       // flex: <basis> means 1 1 <basis>
		if shrink == nil { shrink = one_value(a) }
		if basis == nil { basis = zero_percent(a) }  // flex: <number> means <number> 1 0%
		emit(&res, .Flex_Grow, grow); emit(&res, .Flex_Shrink, shrink); emit(&res, .Flex_Basis, basis)

	case .List_Style:
		typ, pos: []css.Value
		for it, i in items {
			one := [1]css.Value{it}
			if _, ok := parse_enum(one[:], List_Style_Position); ok { pos = items[i:i + 1]; continue }
			if is_ident(it, "none") && typ == nil { typ = items[i:i + 1]; continue }
			if it.kind == .Token && it.tok.kind == .Url { continue }
			if it.kind == .Function && strings.equal_fold(it.tok.text, "url") { continue }
			if typ != nil { return nil, false }
			typ = items[i:i + 1]
		}
		emit(&res, .List_Style_Type, or_initial(typ)); emit(&res, .List_Style_Position, or_initial(pos))

	case .Text_Decoration:
		lines := make([dynamic]css.Value, a)
		col, style, thick: []css.Value
		for it, i in items {
			if it.kind == .Token && it.tok.kind == .Ident {
				switch css.lower_temp(it.tok.text) {
				case "none", "underline", "overline", "line-through", "blink": append(&lines, it); continue
				case "solid", "double", "dotted", "dashed", "wavy":
					if style != nil { return nil, false }
					style = items[i:i + 1]
					continue
				case "from-font", "auto":
					if thick != nil { return nil, false }
					thick = items[i:i + 1]
					continue
				}
			}
			if it.kind == .Token && (it.tok.kind == .Dimension || it.tok.kind == .Percentage || it.tok.kind == .Number) || is_calc_function(it) {
				if thick != nil { return nil, false }
				thick = items[i:i + 1]
				continue
			}
			if col != nil { return nil, false }
			col = items[i:i + 1]
		}
		emit(&res, .Text_Decoration_Line, len(lines) > 0 ? join_items(lines[:], a) : INITIAL_KW[:])
		emit(&res, .Text_Decoration_Color, or_initial(col))
		emit(&res, .Text_Decoration_Style, or_initial(style))
		emit(&res, .Text_Decoration_Thickness, or_initial(thick))

	case .Font:
		return expand_font(vs, a)

	case .Background:
		return expand_background(vs, a)

	case .Mask:
		return expand_mask(vs, a)

	case .White_Space, .Text_Wrap, .Font_Variant, .Transition, .Animation, .Overscroll_Behavior, .Columns,
	     .Grid_Template, .Grid, .Grid_Row, .Grid_Column, .Grid_Area:
		return expand_shorthand_more(s, vs, a)
	}
	return res[:], true
}

@(private)
is_calc_function :: proc(v: css.Value) -> bool {
	return v.kind == .Function && css.is_math_function(v.tok.text)
}

@(private)
number_value :: proc(n: f64, a: runtime.Allocator) -> []css.Value {
	v := make([]css.Value, 1, a)
	v[0] = css.Value{kind = .Token, tok = css.Token{kind = .Number, num = n, is_int = n == f64(int(n))}}
	return v
}
@(private) zero_value :: proc(a: runtime.Allocator) -> []css.Value { return number_value(0, a) }
@(private) one_value :: proc(a: runtime.Allocator) -> []css.Value { return number_value(1, a) }
@(private) auto_value :: proc(a: runtime.Allocator) -> []css.Value {
	v := make([]css.Value, 1, a)
	v[0] = css.Value{kind = .Token, tok = css.Token{kind = .Ident, text = "auto"}}
	return v
}
@(private) zero_percent :: proc(a: runtime.Allocator) -> []css.Value {
	v := make([]css.Value, 1, a)
	v[0] = css.Value{kind = .Token, tok = css.Token{kind = .Percentage, num = 0}}
	return v
}

