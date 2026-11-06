package style

import "base:runtime"
import "core:strings"
import "wb:base"
import "wb:css"

// CSS Text Decoration 4 beyond the line itself: where an underline goes and what it leaves out, what is at the ends of a decorated line, emphasis marks, and
// -webkit-text-stroke. The painter is src/browser/text_decoration.odin. What no browser has of the draft's text-decoration-skip family is not here: -skip-self, -skip-box
// and the shorthand text-decoration-skip.

Text_Decoration_Skip_Ink :: enum u8 { Auto, None, All }

// text-decoration-skip-spaces: `all` covers the spaces inside a line too.
Skip_Space :: enum u8 { Start, End, All }
Skip_Spaces :: bit_set[Skip_Space; u8]

// text-underline-position: from-font and under, then the side of a vertical line.
Underline_Place :: enum u8 { Auto, From_Font, Under }
Underline_Side :: enum u8 { Auto, Left, Right }
Text_Underline_Position :: struct { place: Underline_Place, side: Underline_Side }

// text-emphasis-style: Auto: `filled` or `open` alone, a shape by the writing mode. String: a mark of the page's.
Emphasis_Shape :: enum u8 { None, Auto, Dot, Circle, Double_Circle, Triangle, Sesame, String }
Text_Emphasis_Style :: struct {
	shape: Emphasis_Shape,
	open:  bool,
	text:  string,
}

// `auto`: over the line, under it in Chinese; right of a column.
Text_Emphasis_Position :: struct { auto, under, left: bool }

Emphasis_Skip :: enum u8 { Spaces, Punctuation, Symbols, Narrow }
Emphasis_Skips :: bit_set[Emphasis_Skip; u8]

// What `thin`, `medium` and `thick` are (CSS Backgrounds 3).
LINE_WIDTH_THIN :: 1
LINE_WIDTH_MEDIUM :: 3
LINE_WIDTH_THICK :: 5

// A <line-width> keyword.
line_width_keyword :: proc(id: string) -> (f32, bool) {
	switch base.ascii_lower(id) {
	case "thin": return LINE_WIDTH_THIN, true
	case "medium": return LINE_WIDTH_MEDIUM, true
	case "thick": return LINE_WIDTH_THICK, true
	}
	return 0, false
}

// The color of text marks and strokes (`auto`: currentcolor).
auto_color_parse :: proc(cx: ^Cx, vs: []css.Value, dst: ^Auto_Color) -> bool {
	if id, ok := ident_raw(vs); ok && base.ascii_equal_fold(id, "currentcolor") { dst^ = Auto_Color{auto = true}; return true }
	col, ok := parse_color(cx, vs)
	if !ok { return false }
	dst^ = Auto_Color{color = col}
	return true
}

@(private = "file")
parse_skip_spaces :: proc(vs: []css.Value, dst: ^Skip_Spaces) -> bool {
	set: Skip_Spaces
	items := split_items(vs)
	for it in items {
		if !tok_is(it, .Ident) { return false }
		switch base.ascii_lower(it.tok.text) {
		case "none", "all":
			if len(items) != 1 { return false }
			if base.ascii_equal_fold(it.tok.text, "all") { set = {.All} }
		case "start":
			if .Start in set { return false }
			set += {.Start}
		case "end":
			if .End in set { return false }
			set += {.End}
		case: return false
		}
	}
	dst^ = set
	return len(items) > 0
}

@(private = "file")
parse_underline_position :: proc(vs: []css.Value, dst: ^Text_Underline_Position) -> bool {
	pos: Text_Underline_Position
	items := split_items(vs)
	if len(items) == 0 || len(items) > 2 { return false }
	for it in items {
		if !tok_is(it, .Ident) { return false }
		switch base.ascii_lower(it.tok.text) {
		case "auto": if len(items) != 1 { return false }
		case "from-font", "under":
			if pos.place != .Auto { return false }
			pos.place = base.ascii_equal_fold(it.tok.text, "under") ? .Under : .From_Font
		case "left", "right":
			if pos.side != .Auto { return false }
			pos.side = base.ascii_equal_fold(it.tok.text, "left") ? .Left : .Right
		case: return false
		}
	}
	dst^ = pos
	return true
}

@(private = "file")
parse_emphasis_style :: proc(cx: ^Cx, vs: []css.Value, dst: ^Text_Emphasis_Style) -> bool {
	st: Text_Emphasis_Style
	items := split_items(vs)
	if len(items) == 1 && tok_is(items[0], .String) {
		dst^ = {shape = .String, text = strings.clone(items[0].tok.text, cx.alloc)}
		return true
	}
	if len(items) == 0 || len(items) > 2 { return false }
	filled := false
	for it in items {
		if !tok_is(it, .Ident) { return false }
		switch base.ascii_lower(it.tok.text) {
		case "none":
			if len(items) != 1 { return false }
			dst^ = {}
			return true
		case "filled", "open":
			if filled || st.open { return false }
			if base.ascii_equal_fold(it.tok.text, "open") { st.open = true } else { filled = true }
		case:
			shape: Emphasis_Shape
			switch base.ascii_lower(it.tok.text) {
			case "dot": shape = .Dot
			case "circle": shape = .Circle
			case "double-circle": shape = .Double_Circle
			case "triangle": shape = .Triangle
			case "sesame": shape = .Sesame
			case: return false
			}
			if st.shape != .None { return false }
			st.shape = shape
		}
	}
	if st.shape == .None { st.shape = .Auto }
	dst^ = st
	return true
}

@(private = "file")
parse_emphasis_position :: proc(vs: []css.Value, dst: ^Text_Emphasis_Position) -> bool {
	pos: Text_Emphasis_Position
	over_under, side := false, false
	if id, ok := ident_raw(vs); ok && base.ascii_equal_fold(id, "auto") {
		dst^ = {auto = true}
		return true
	}
	items := split_items(vs)
	if len(items) == 0 || len(items) > 2 { return false }
	for it in items {
		if !tok_is(it, .Ident) { return false }
		switch base.ascii_lower(it.tok.text) {
		case "over", "under":
			if over_under { return false }
			over_under, pos.under = true, base.ascii_equal_fold(it.tok.text, "under")
		case "left", "right":
			if side { return false }
			side, pos.left = true, base.ascii_equal_fold(it.tok.text, "left")
		case: return false
		}
	}
	if !over_under { return false }
	dst^ = pos
	return true
}

@(private = "file")
parse_emphasis_skip :: proc(vs: []css.Value, dst: ^Emphasis_Skips) -> bool {
	set: Emphasis_Skips
	items := split_items(vs)
	for it in items {
		if !tok_is(it, .Ident) { return false }
		one: Emphasis_Skip
		switch base.ascii_lower(it.tok.text) {
		case "spaces": one = .Spaces
		case "punctuation": one = .Punctuation
		case "symbols": one = .Symbols
		case "narrow": one = .Narrow
		case: return false
		}
		if one in set { return false }
		set += {one}
	}
	dst^ = set
	return len(items) > 0
}

// text-decoration-inset: auto, or the start's and the end's (one value: both).
@(private = "file")
parse_inset :: proc(cx: ^Cx, vs: []css.Value, dst: ^[2]Length) -> bool {
	if id, ok := ident_raw(vs); ok {
		if !base.ascii_equal_fold(id, "auto") { return false }
		dst^ = {auto_length, auto_length}
		return true
	}
	items := split_items(vs)
	if len(items) == 0 || len(items) > 2 { return false }
	a, ok := parse_length(cx, items[:1], {.Percent, .Negative})
	if !ok { return false }
	b := a
	if len(items) == 2 {
		b, ok = parse_length(cx, items[1:], {.Percent, .Negative})
		if !ok { return false }
	}
	dst^ = {a, b}
	return true
}

apply_text_decor_prop :: proc(cx: ^Cx, p: Prop, vs: []css.Value) -> bool {
	c := cx.c
	#partial switch p {
	case .Text_Decoration_Skip_Ink: return set_enum(vs, &c.text_decoration_skip_ink)
	case .Text_Decoration_Skip_Spaces: return parse_skip_spaces(vs, &c.text_decoration_skip_spaces)
	case .Text_Decoration_Inset: return parse_inset(cx, vs, &c.text_decoration_inset)
	case .Text_Underline_Position: return parse_underline_position(vs, &c.text_underline_position)
	case .Text_Emphasis_Style: return parse_emphasis_style(cx, vs, &c.text_emphasis_style)
	case .Text_Emphasis_Color: return auto_color_parse(cx, vs, &c.text_emphasis_color)
	case .Text_Emphasis_Position: return parse_emphasis_position(vs, &c.text_emphasis_position)
	case .Text_Emphasis_Skip: return parse_emphasis_skip(vs, &c.text_emphasis_skip)
	case .Text_Stroke_Color: return auto_color_parse(cx, vs, &c.text_stroke_color)
	case .Text_Stroke_Width:
		if id, ok := ident_raw(vs); ok {
			w, known := line_width_keyword(id)
			if known { c.text_stroke_width = w }
			return known
		}
		l, ok := parse_length(cx, vs, {})
		if !ok || l.kind != .Px { return false }
		c.text_stroke_width = l.v
		return true
	}
	return false
}

// The longhand of `text-emphasis` an item of it belongs to: a style's keyword or string, else a color. And `-webkit-text-stroke`'s.
is_emphasis_style_item :: proc(it: css.Value) -> bool {
	if tok_is(it, .String) { return true }
	if !tok_is(it, .Ident) { return false }
	switch base.ascii_lower(it.tok.text) {
	case "none", "filled", "open", "dot", "circle", "double-circle", "triangle", "sesame": return true
	}
	return false
}

is_line_width_item :: proc(it: css.Value) -> bool {
	if tok_is(it, .Ident) {
		_, known := line_width_keyword(it.tok.text)
		return known
	}
	return tok_is(it, .Dimension) || tok_is(it, .Number) || is_calc_function(it)
}

// The text of a used emphasis mark (CSS Text Decoration 3 §3.1), `vertical`: of a vertical line.
emphasis_mark :: proc(st: Text_Emphasis_Style, vertical: bool) -> string {
	shape := st.shape
	if shape == .Auto { shape = vertical ? .Sesame : .Circle }
	switch shape {
	case .None, .Auto: return ""
	case .Dot: return st.open ? "◦" : "•"
	case .Circle: return st.open ? "○" : "●"
	case .Double_Circle: return st.open ? "◎" : "◉"
	case .Triangle: return st.open ? "△" : "▲"
	case .Sesame: return st.open ? "﹆" : "﹅"
	case .String: return st.text
	}
	return ""
}

// -webkit-text-fill-color's neighbours: the used colors of marks and strokes.
emphasis_color :: #force_inline proc(c: ^Computed) -> css.Color { return c.text_emphasis_color.auto ? c.color : c.text_emphasis_color.color }
stroke_color :: #force_inline proc(c: ^Computed) -> css.Color { return c.text_stroke_color.auto ? c.color : c.text_stroke_color.color }

// The text of `text` is a decorated line's own to leave out at its ends: spaces of Zs but U+202F.
is_spacer :: proc(r: rune) -> bool {
	switch r {
	case 0x20, 0xA0, 0x1680, 0x2000 ..= 0x200A, 0x205F, 0x3000: return true
	}
	return false
}

// The canonical text of a declared value of these properties (element.style): "" when it has none of its own.
text_decor_canonical :: proc(p: Prop, vs: []css.Value, alloc: runtime.Allocator) -> string {
	items := split_items(css.trim_values(vs))
	has :: proc(items: []css.Value, word: string) -> bool {
		for it in items { if tok_is(it, .Ident) && base.ascii_equal_fold(it.tok.text, word) { return true } }
		return false
	}
	join :: proc(items: []css.Value, words: []string, alloc: runtime.Allocator) -> string {
		b := strings.builder_make(alloc)
		for w in words {
			if !has(items, w) { continue }
			if strings.builder_len(b) > 0 { strings.write_byte(&b, ' ') }
			strings.write_string(&b, w)
		}
		return strings.to_string(b)
	}
	#partial switch p {
	case .Text_Decoration_Line:
		if len(items) > 1 { return join(items, {"underline", "overline", "line-through", "blink"}, alloc) }
	case .Text_Decoration_Skip_Spaces:
		if len(items) > 1 { return join(items, {"start", "end"}, alloc) }
	case .Text_Underline_Position:
		if len(items) > 1 { return join(items, {"from-font", "under", "left", "right"}, alloc) }
	case .Text_Emphasis_Position:
		if len(items) >= 1 && !has(items, "auto") { return join(items, {"over", "under", "left"}, alloc) }
	case .Text_Decoration_Inset:
		// (a zero is a length; two the same are one)
		if len(items) == 0 || len(items) > 2 { return "" }
		texts: [2]string
		for _, i in items {
			texts[i] = css.serialize_values(items[i:i + 1], context.temp_allocator)
			if texts[i] == "0" { texts[i] = "0px" }
		}
		if len(items) == 1 || texts[0] == texts[1] { return strings.clone(texts[0], alloc) }
		return strings.concatenate({texts[0], " ", texts[1]}, alloc)
	}
	return ""
}

// The value of `text-decoration` as written by its longhands: the shortest that says it.
text_decoration_canonical :: proc(line, color, line_style, thickness: string, alloc: runtime.Allocator) -> string {
	initial :: proc(v, kw: string) -> bool { return v == "initial" || base.ascii_equal_fold(v, kw) }
	parts := make([dynamic]string, 0, 4, context.temp_allocator)
	if !initial(line, "none") { append(&parts, line) }
	if !initial(thickness, "auto") { append(&parts, thickness) }
	if !initial(line_style, "solid") { append(&parts, line_style) }
	if !initial(color, "currentcolor") { append(&parts, color) }
	return len(parts) == 0 ? "none" : strings.join(parts[:], " ", alloc)
}