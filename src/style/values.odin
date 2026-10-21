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

@(private)
calc_has_unit :: proc(n: ^css.Calc, u: css.Unit) -> bool {
	if n == nil { return false }
	if n.op == .Dimension && n.unit == u { return true }
	return calc_has_unit(n.a, u) || calc_has_unit(n.b, u) || calc_has_unit(n.c, u)
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
			id := css.lower_temp(t.text)
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
		#partial switch css.calc_type(tree) {
		case .Length, .Length_Percent:
		case .Percent: if .Percent not_in flags { return {}, false }
		case: return {}, false   // a number, an angle, a time, or types that do not combine
		}
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
	cx.cenv.current, cx.cenv.has_current = cx.c.color, true   // currentcolor inside color-mix(), relative colors
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
		c.border_color[side] = s.colors[.Light][.Canvas_Text]
	}
	c.opacity = 1
	c.flex_shrink = 1
	c.flex_basis = auto_length
	c.align_self = .Auto
	c.justify_self = .Auto
	c.row_gap, c.column_gap = Length{kind = .Normal}, Length{kind = .Normal}
	// the initial color is CanvasText, of the element's own scheme (see scheme_settle)
	c.color_pair = Scheme_Color{s.colors[.Light][.Canvas_Text], s.colors[.Dark][.Canvas_Text]}
	c.color = c.color_pair.light
	c.font_size = s.default_font_size
	c.font_size_src = {keyword = 3}   // medium
	c.font_weight = 400
	c.line_height = Line_Height{kind = .Normal}
	c.text_decoration_color = c.color
	c.text_indent = px(0)
	c.tab_size, c.tab_spaces = 8, true
	c.pointer_events = true
	c.background_color = {0, 0, 0, 0}
	c.background_position = {Length{kind = .Percent, v = 0}, Length{kind = .Percent, v = 0}}
	c.outline_width = 3
	c.outline_color = c.color
	c.list_style_type = .Disc
	c.list_style = List_Marker_Style{style = .Disc}
	c.border_collapse = false
	c.content = Content{kind = .Normal}
	c.font_stretch = 100
	c.text_decoration_thickness = auto_length
	c.text_underline_offset = auto_length
	c.transform_origin = {Length{kind = .Percent, v = 50}, Length{kind = .Percent, v = 50}}
	c.perspective_origin = {Length{kind = .Percent, v = 50}, Length{kind = .Percent, v = 50}}
	c.object_position = {Length{kind = .Percent, v = 50}, Length{kind = .Percent, v = 50}}
	c.caret_color = Auto_Color{auto = true}
	c.accent_color = Auto_Color{auto = true}
	c.scrollbar_color = Scrollbar_Colors{auto = true}
	c.column_width = auto_length
	c.transform_box = .View_Box
	// the list-valued properties keep their initial value as a one-element list, so that a missing list is never an
	// ambiguous "empty": these are shared, read-only, process-wide constants
	c.transition_property = INITIAL_TRANSITION_PROPERTY[:]
	c.transition_duration = ZERO_TIMES[:]
	c.transition_delay = ZERO_TIMES[:]
	c.transition_timing = EASE_LIST[:]
	c.transition_behavior = FALSE_LIST[:]
	c.animation_name = NONE_NAMES[:]
	c.animation_duration = ZERO_TIMES[:]
	c.animation_delay = ZERO_TIMES[:]
	c.animation_timing = EASE_LIST[:]
	c.animation_iterations = ONE_LIST[:]
	c.animation_direction = NORMAL_DIRECTION[:]
	c.animation_fill_mode = NO_FILL[:]
	c.animation_play_state = RUNNING[:]
	c.animation_composition = REPLACE[:]
	c.background_images = NO_IMAGES[:]
	c.background_repeats = REPEATS[:]
	c.background_positions = ORIGIN_POSITIONS[:]
	c.background_sizes = AUTO_SIZES[:]
	c.background_origins = PADDING_BOX[:]
	c.background_clips = BORDER_BOX[:]
	c.background_attachments = SCROLL[:]
	c.grid_auto_columns = AUTO_TRACKS[:]
	c.grid_auto_rows = AUTO_TRACKS[:]
	masks_initial(&c)
	return c
}

@(private) INITIAL_TRANSITION_PROPERTY := [1]Transition_Prop{{kind = .All}}
@(private) ZERO_TIMES := [1]f32{0}
@(private) EASE_LIST := [1]Easing{EASE}
@(private) FALSE_LIST := [1]bool{false}
@(private) NONE_NAMES := [1]string{""}
@(private) ONE_LIST := [1]f32{1}
@(private) NORMAL_DIRECTION := [1]Anim_Direction{.Normal}
@(private) NO_FILL := [1]Fill_Mode{.None}
@(private) RUNNING := [1]Play_State{.Running}
@(private) REPLACE := [1]Composition{.Replace}
@(private) NO_IMAGES := [1]Image{{}}
@(private) REPEATS := [1][2]Repeat{{.Repeat, .Repeat}}
@(private) ORIGIN_POSITIONS := [1][2]Length{{{kind = .Percent, v = 0}, {kind = .Percent, v = 0}}}
@(private) AUTO_SIZES := [1]Bg_Size{{}}
@(private) PADDING_BOX := [1]Box_Area{.Padding_Box}
@(private) BORDER_BOX := [1]Box_Area{.Border_Box}
@(private) SCROLL := [1]Bg_Attachment{.Scroll}
@(private) AUTO_TRACKS := [1]Grid_Track{{kind = .Breadth, min = {kind = .Auto}, max = {kind = .Auto}}}

////////////////////////////////
// Applying one longhand

@(private)
ABSOLUTE_SIZES := [?]struct { name: string, factor: f32 }{
	{"xx-small", 3.0 / 5}, {"x-small", 3.0 / 4}, {"small", 8.0 / 9}, {"medium", 1}, {"large", 6.0 / 5},
	{"x-large", 3.0 / 2}, {"xx-large", 2}, {"xxx-large", 3},
}

// Chromium's sizes of the absolute-size keywords for the default sizes of 16 px (the default) and 13 px (the
// monospace default), measured in Edge: not the factors of the table above (small is 13 px, not 14.2). Other defaults
// use the factors, as Chromium does outside its tables.
@(private)
KEYWORD_SIZES_16 := [8]f32{9, 10, 13, 16, 18, 24, 32, 48}
@(private)
KEYWORD_SIZES_13 := [8]f32{9, 10, 12, 13, 16, 20, 26, 39}

@(private)
keyword_font_size :: proc(s: ^Settings, i: int, mono: bool) -> f32 {
	medium := mono ? s.monospace_font_size : s.default_font_size
	if medium == 16 { return KEYWORD_SIZES_16[i] }
	if medium == 13 { return KEYWORD_SIZES_13[i] }
	return ABSOLUTE_SIZES[i].factor * medium
}

// The family list is the generic `monospace` alone (Chromium's FontDescription::IsMonospace: `Menlo, monospace` or
// `monospace, monospace` are not).
is_generic_monospace :: proc(families: []string) -> bool { return len(families) == 1 && families[0] == "monospace" }

// A font size relative to the parent's: em, ex, ch, a percentage.
@(private)
font_size_relative :: proc(vs: []css.Value) -> bool {
	v := css.trim_values(vs)
	if len(v) != 1 || v[0].kind != .Token { return false }
	#partial switch v[0].tok.kind {
	case .Percentage: return true
	case .Dimension:
		u := v[0].tok.text
		return strings.equal_fold(u, "em") || strings.equal_fold(u, "ex") || strings.equal_fold(u, "ch") || strings.equal_fold(u, "cap") || strings.equal_fold(u, "ic")
	}
	return false
}

// After font-family: an element whose family becomes the generic monospace (or stops being it) gets the size that goes
// with it, as in Chromium (FontBuilder::CheckForGenericFamilyChange): <code> in default text is 13 px, in text of
// font-size: 14px it stays 14 px, in 1.2em text it is 13/16 of it, and `font-size: small` gives 12 px.
generic_family_adjust :: proc(cx: ^Cx) {
	c, p, s := cx.c, cx.parent, cx.settings
	if p == nil { return }
	mono := is_generic_monospace(c.font_family)
	if mono == is_generic_monospace(p.font_family) { return }
	src := c.font_size_src
	if src.keyword >= 0 && int(src.keyword) < len(ABSOLUTE_SIZES) {
		c.font_size = keyword_font_size(s, int(src.keyword), mono)
	} else if !src.absolute && s.default_font_size > 0 && s.monospace_font_size > 0 {
		k := s.monospace_font_size / s.default_font_size
		c.font_size = mono ? c.font_size * k : c.font_size / k
	} else {
		return
	}
	c.font_size = max(c.font_size, s.minimum_font_size)
	cx.lc.font_size = f64(c.font_size)
	cx.lc.x_height = f64(c.font_size) * 0.5
	cx.lc.ch = f64(c.font_size) * 0.5
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
		switch css.lower_temp(name) {
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
		parent_src := cx.parent != nil ? cx.parent.font_size_src : Font_Size_Src{keyword = 3}
		size: f32
		src := Font_Size_Src{keyword = -1, absolute = parent_src.absolute}
		if id, ok := ident_raw(vs); ok {
			lid := css.lower_temp(id)
			mono := is_generic_monospace(c.font_family)
			switch lid {
			// (relative, as em: no longer a keyword size, as in Chromium)
			case "larger": size = parent_fs * 1.2
			case "smaller": size = parent_fs / 1.2
			case:
				found := false
				for a, i in ABSOLUTE_SIZES {
					if a.name == lid { src = {keyword = i8(i)}; size = keyword_font_size(s, i, mono); found = true }
				}
				if !found { return false }
			}
		} else {
			// em, ex, ch and percentages follow the parent (absolute or not); other units are absolute
			src.absolute = !font_size_relative(vs) || parent_src.absolute
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
		c.font_size_src = src
		cx.lc.font_size = f64(c.font_size)
		cx.lc.x_height = f64(c.font_size) * 0.5
		cx.lc.ch = f64(c.font_size) * 0.5
	case .Color_Scheme:
		v, ok := parse_color_scheme(vs)
		if !ok { return false }
		c.color_scheme = v
	case .Color: return apply_color(cx, vs)
	case .Font_Family:
		fam, ok := parse_font_family(cx, vs)
		if !ok { return false }
		c.font_family = fam
	case .Font_Weight:
		if id, ok := ident_raw(vs); ok {
			parent_w := cx.parent != nil ? int(cx.parent.font_weight) : 400
			switch css.lower_temp(id) {
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
		if n, ok := css.parse_number(vs); ok {   // a number, also calc(1.75 / 1.25)
			if n < 0 { return false }
			c.line_height = Line_Height{kind = .Number, v = f32(n)}
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
			switch css.lower_temp(id) {
			case "-webkit-center": c.text_align = .Legacy_Center; return true
			case "-webkit-left": c.text_align = .Legacy_Left; return true
			case "-webkit-right": c.text_align = .Legacy_Right; return true
			case "justify-all": c.text_align = .Justify; return true
			case "match-parent": c.text_align = .Start; return true
			// the UA's th (HTML §15.3.8): centered only when its parent's text-align is the initial value, else that
			// value inherited (a table with text-align: left has left-aligned header cells)
			case "-internal-th-center":
				c.text_align = (cx.parent == nil || cx.parent.text_align == .Start) ? .Center : cx.parent.text_align
				return true
			case "legacy-center", "legacy-left", "legacy-right": return false   // (internal names, not CSS keywords)
			}
		}
		return set_enum(vs, &c.text_align)
	case .Text_Decoration_Line:
		if id, ok := ident_raw(vs); ok && strings.equal_fold(id, "none") { c.text_decoration = {}; return true }
		set: Decorations
		for it in split_items(vs) {
			if it.kind != .Token || it.tok.kind != .Ident { return false }
			switch css.lower_temp(it.tok.text) {
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
		ps_add(&cx.explicit, p)
	case .Text_Transform: return set_enum(vs, &c.text_transform)
	case .Text_Indent:
		l, ok := parse_length(cx, vs, {.Percent, .Negative})
		if !ok { return false }
		c.text_indent = l
	case .Text_Overflow:
		id, ok := ident_raw(vs)
		if !ok { return false }
		switch css.lower_temp(id) {
		case "clip": c.text_ellipsis = false
		case "ellipsis": c.text_ellipsis = true
		case: return false
		}
	case .Word_Break: return set_enum(vs, &c.word_break)
	case .Overflow_Wrap: return set_enum(vs, &c.overflow_wrap)
	case .Tab_Size:
		if n, ok := number_in(vs, 0, 1e6); ok { c.tab_size, c.tab_spaces = n, true; return true }   // layout multiplies by the advance of a space
		l, ok := parse_length(cx, vs, {})
		if !ok || l.kind != .Px { return false }
		c.tab_size, c.tab_spaces = l.v, false
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
			a := css.lower_temp(items[0].tok.text)
			b := css.lower_temp(items[1].tok.text)
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
		switch css.lower_temp(id) {
		case "-webkit-box": c.display = .Flex
		case "-webkit-inline-box": c.display = .Inline_Flex
		case "run-in": c.display = .Block
		case: return set_enum(vs, &c.display)
		}
	case .Position: return set_enum(vs, &c.position)
	case .Float:
		if id, ok := ident_raw(vs); ok {
			switch css.lower_temp(id) {
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
		case .Min_Width: c.min_width = l
		case .Min_Height: c.min_height = l
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
		ps_add(&cx.explicit, p)
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
			lid := css.lower_temp(id)
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
		have, auto := false, false
		i := 0
		for i < len(items) {
			it := items[i]
			if it.kind == .Token && it.tok.kind == .Ident {
				if !strings.equal_fold(it.tok.text, "auto") || auto { return false }
				auto = true
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
		// within 1e-6..1e6: a width divided by a subnormal ratio is infinite (and NaN further on)
		if have { ratio = clamp(ratio, 1e-6, 1e6) }
		c.aspect_ratio = ratio
		c.aspect_ratio_auto = auto && have
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
			switch css.lower_temp(id) {
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
		parts := css.split_commas(css.trim_values(vs), context.temp_allocator)
		list := make([]Image, len(parts), cx.alloc)
		for part, i in parts {
			img, ok := parse_image(cx, part)
			if !ok { return false }
			list[i] = img
		}
		c.background_images = list
		c.background_image = list[0]
	case .Background_Repeat:
		parts := css.split_commas(css.trim_values(vs), context.temp_allocator)
		list := make([][2]Repeat, len(parts), cx.alloc)
		for part, i in parts {
			r, ok := parse_bg_repeat(part)
			if !ok { return false }
			list[i] = r
		}
		c.background_repeats = list
		c.background_repeat = list[0]
	case .Background_Position:
		parts := css.split_commas(css.trim_values(vs), context.temp_allocator)
		list := make([][2]Length, len(parts), cx.alloc)
		for part, i in parts {
			pos, ok := parse_position(cx, part)
			if !ok { return false }
			list[i] = pos
		}
		c.background_positions = list
		c.background_position = list[0]
	case .Background_Size:
		parts := css.split_commas(css.trim_values(vs), context.temp_allocator)
		list := make([]Bg_Size, len(parts), cx.alloc)
		for part, i in parts {
			sz, ok := parse_bg_size(cx, part)
			if !ok { return false }
			list[i] = sz
		}
		c.background_sizes = list
		c.background_size = list[0]
	case .Box_Shadow:
		sh, ok := parse_shadows(cx, vs)
		if !ok { return false }
		c.box_shadow = sh
	case .List_Style_Type:
		st, ok := parse_list_marker_style(cx, vs)
		if !ok { return false }
		c.list_style = st
		c.list_style_type = legacy_list_style(st.style)
	case .List_Style_Position: return set_enum(vs, &c.list_style_position)
	case .Cursor: return parse_cursor(cx, vs, c)   // cursor.odin
	case .Pointer_Events:
		id, ok := ident_raw(vs)
		if !ok { return false }
		switch css.lower_temp(id) {
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
		ps_add(&cx.explicit, p)
	case .Outline_Offset:
		l, ok := parse_length(cx, vs, {.Negative})
		if !ok || l.kind != .Px { return false }
		c.outline_offset = l.v
	case .Border_Collapse:
		id, ok := ident_raw(vs)
		if !ok { return false }
		switch css.lower_temp(id) {
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
	case .Font_Feature_Settings, .Font_Variation_Settings, .Font_Kerning, .Font_Variant_Ligatures, .Font_Variant_Numeric,
	     .Font_Variant_East_Asian, .Font_Variant_Position, .Unicode_Bidi:
		return apply_font_feature_prop(cx, p, vs)
	case .Font_Stretch, .Font_Variant_Caps, .Text_Decoration_Style, .Text_Decoration_Thickness, .Text_Underline_Offset,
	     .White_Space_Collapse, .Text_Wrap_Mode, .Text_Wrap_Style, .Hyphens,
	     .Background_Origin, .Background_Clip, .Background_Attachment,
	     .Transform, .Transform_Origin, .Transform_Box, .Transform_Style, .Translate, .Rotate, .Scale, .Perspective,
	     .Perspective_Origin, .Backface_Visibility,
	     .Transition_Property, .Transition_Duration, .Transition_Timing_Function, .Transition_Delay, .Transition_Behavior,
	     .Animation_Name, .Animation_Duration, .Animation_Timing_Function, .Animation_Delay, .Animation_Iteration_Count,
	     .Animation_Direction, .Animation_Fill_Mode, .Animation_Play_State, .Animation_Composition,
	     .Counter_Reset, .Counter_Increment, .Counter_Set, .Quotes,
	     .Object_Position, .Filter, .Backdrop_Filter, .Clip_Path, .Isolation, .Mix_Blend_Mode,
	     .Will_Change, .Contain, .Content_Visibility, .Scroll_Behavior, .Overscroll_Behavior_X, .Overscroll_Behavior_Y,
	     .Caret_Color, .Accent_Color, .Appearance, .Resize, .Column_Count, .Column_Width,
	     .Grid_Template_Columns, .Grid_Template_Rows, .Grid_Template_Areas, .Grid_Auto_Columns, .Grid_Auto_Rows,
	     .Grid_Auto_Flow, .Grid_Row_Start, .Grid_Row_End, .Grid_Column_Start, .Grid_Column_End, .Justify_Items, .Justify_Self:
		return apply_prop_more(cx, p, vs)
	case .Container_Type, .Container_Name, .Scrollbar_Width, .Scrollbar_Color, .Scrollbar_Gutter:
		return apply_container_prop(cx, p, vs)
	case .Mask_Image, .Mask_Mode, .Mask_Repeat, .Mask_Position, .Mask_Size, .Mask_Origin, .Mask_Clip, .Mask_Composite, .Text_Fill_Color:
		return apply_mask_prop(cx, p, vs)
	}
	return true
}

parse_line_width :: proc(cx: ^Cx, vs: []css.Value) -> (f32, bool) {
	if id, ok := ident_raw(vs); ok {
		switch css.lower_temp(id) {
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
