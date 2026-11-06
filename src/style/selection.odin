package style

import "base:runtime"
import "core:strings"
import "wb:base"
import "wb:css"
import "wb:dom"

// The highlight pseudo-elements (CSS Pseudo 4 §3): ::selection, ::target-text, ::spelling-error, ::grammar-error, ::highlight(). What an element's rules say of each is kept
// on its style (Computed.highlights), with the properties they gave a value; what paints is worked out from it here, for the painter (src/browser/selection_shell.odin):
// a property with no such value on an element comes from the same highlight of its parent, whether the property inherits or not (§3.5).

// By their overlays, the lowest first (§3.6.1; CSS Custom Highlight API §4.2.4: custom highlights are under the others).
Highlight_Kind :: enum u8 { Custom, Grammar_Error, Spelling_Error, Target_Text, Selection }

// What the name of a built-in highlight is in a selector's parts (a custom highlight's cannot begin so).
HIGHLIGHT_NAME_TARGET_TEXT :: "::target-text"
HIGHLIGHT_NAME_SPELLING_ERROR :: "::spelling-error"
HIGHLIGHT_NAME_GRAMMAR_ERROR :: "::grammar-error"
// ::highlight(*): every custom highlight.
HIGHLIGHT_NAME_ANY :: "*"

Highlight_Style :: struct {
	kind:     Highlight_Kind,
	name:     string,     // of a custom highlight
	style:    ^Computed,
	declared: Prop_Set,   // what its rules gave a value (`inherit` and `unset` give none)
	current:  Prop_Set,   // what of it is currentcolor: the highlight's `color`, which for `color` is the layer's below
}

// The properties that apply to highlights (§3.2): others are left out of their styles, and em units are the originating element's.
@(private)
highlight_applies :: proc(p: Prop) -> bool {
	#partial switch p {
	case .Color, .Background_Color, .Text_Decoration_Line, .Text_Decoration_Color, .Text_Decoration_Style, .Text_Decoration_Thickness, .Text_Underline_Offset,
	     .Text_Underline_Position, .Text_Decoration_Skip_Ink, .Text_Shadow, .Text_Fill_Color, .Text_Stroke_Width, .Text_Stroke_Color, .Fill, .Stroke, .Stroke_Width:
		return true
	}
	return false
}

// What a highlight paints over an element's text. has_*: the page gives a value, else the layer below shows through.
Highlight_Paint :: struct {
	color:          css.Color,
	has_color:      bool,
	declared_color: bool,   // the page gave one, currentcolor included: the paired defaults are off (§3.3)
	background:     css.Color,
	has_background: bool,
	shadows:        []Shadow,
	lines:          Decorations,
	line_style:     Text_Decoration_Style,
	line_color:     css.Color,
	has_line_color: bool,
	thickness:      Length,
	offset:         Length,
	position:       Text_Underline_Position,
	skip_ink:       Text_Decoration_Skip_Ink,
	fill:           css.Color,
	has_fill:       bool,
	stroke:         css.Color,
	has_stroke:     bool,
	stroke_width:   f32,
	has_stroke_width: bool,
}

// What `c` says of a highlight: its name's, else what ::highlight(*) says.
@(private = "file")
highlight_style_at :: proc(c: ^Computed, kind: Highlight_Kind, name: string) -> ^Highlight_Style {
	every: ^Highlight_Style
	for &hs in c.highlights {
		if hs.kind != kind { continue }
		if kind != .Custom || hs.name == name { return &hs }
		if hs.name == HIGHLIGHT_NAME_ANY { every = &hs }
	}
	return every
}

// The highlight `kind` (`name`: which custom one) over the text of `el`.
highlight_paint :: proc(s: ^Styled, d: ^dom.Document, el: base.Handle, kind: Highlight_Kind, name := "") -> (out: Highlight_Paint) {
	out.thickness, out.offset = auto_length, auto_length
	found: Prop_Set
	take :: proc(found: ^Prop_Set, hs: ^Highlight_Style, p: Prop) -> bool {
		if !ps_has(hs.declared, p) || ps_has(found^, p) { return false }
		ps_add(found, p)
		return true
	}
	background_current := false
	for cur := el; cur != base.NIL_HANDLE; cur = flat_parent_element(d, cur) {
		c := style_of(s, cur)
		if c == nil || len(c.highlights) == 0 { continue }
		hs := highlight_style_at(c, kind, name)
		if hs == nil { continue }
		st := hs.style
		if take(&found, hs, .Color) { out.color, out.has_color, out.declared_color = st.color, !ps_has(hs.current, .Color), true }
		if take(&found, hs, .Background_Color) {
			out.background, out.has_background = st.background_color, true
			background_current = ps_has(hs.current, .Background_Color)
		}
		if take(&found, hs, .Text_Shadow) { out.shadows = st.text_shadow }
		if take(&found, hs, .Text_Decoration_Line) { out.lines = st.text_decoration }
		if take(&found, hs, .Text_Decoration_Style) { out.line_style = st.text_decoration_style }
		if take(&found, hs, .Text_Decoration_Color) && !ps_has(hs.current, .Text_Decoration_Color) { out.line_color, out.has_line_color = st.text_decoration_color, true }
		if take(&found, hs, .Text_Decoration_Thickness) { out.thickness = st.text_decoration_thickness }
		if take(&found, hs, .Text_Underline_Offset) { out.offset = st.text_underline_offset }
		if take(&found, hs, .Text_Underline_Position) { out.position = st.text_underline_position }
		if take(&found, hs, .Text_Decoration_Skip_Ink) { out.skip_ink = st.text_decoration_skip_ink }
		if take(&found, hs, .Text_Fill_Color) && !st.text_fill_color.auto { out.fill, out.has_fill = st.text_fill_color.color, true }
		if take(&found, hs, .Fill) && st.svg_fill.kind == .Color && !out.has_fill { out.fill, out.has_fill = st.svg_fill.color, true }
		if take(&found, hs, .Text_Stroke_Color) && !st.text_stroke_color.auto { out.stroke, out.has_stroke = st.text_stroke_color.color, true }
		if take(&found, hs, .Stroke) && st.svg_stroke.kind == .Color && !out.has_stroke { out.stroke, out.has_stroke = st.svg_stroke.color, true }
		if take(&found, hs, .Text_Stroke_Width) { out.stroke_width, out.has_stroke_width = st.text_stroke_width, true }
		if take(&found, hs, .Stroke_Width) && !out.has_stroke_width { out.stroke_width, out.has_stroke_width = st.stroke_width, true }
	}
	if background_current && out.has_color { out.background = out.color }
	// :root::spelling-error { text-decoration: spelling-error } and the same for grammar (§3.3)
	if !ps_has(found, .Text_Decoration_Line) {
		#partial switch kind {
		case .Spelling_Error: out.lines = {.Spelling_Error}
		case .Grammar_Error: out.lines = {.Grammar_Error}
		}
	}
	return
}

// A pseudo-element's name in getComputedStyle: is it of a highlight, and a well-formed one?
highlight_pseudo_parse :: proc(pseudo: string) -> (kind: Highlight_Kind, name: string, is_highlight, valid: bool) {
	if !strings.has_prefix(pseudo, "::") { return }
	t := pseudo[2:]
	switch t {
	case "selection": return .Selection, "", true, true
	case "target-text": return .Target_Text, "", true, true
	case "spelling-error": return .Spelling_Error, "", true, true
	case "grammar-error": return .Grammar_Error, "", true, true
	}
	for word in ([?]string{":", "selection", "target-text", "spelling-error", "grammar-error", "search-text"}) {
		if strings.has_prefix(t, word) { return {}, "", true, false }
	}
	if !strings.has_prefix(t, "highlight") { return }
	t = t[len("highlight"):]
	if len(t) < 3 || t[0] != '(' || t[len(t) - 1] != ')' || strings.contains_any(t[1:len(t) - 1], " \t\n()") { return {}, "", true, false }
	return .Custom, t[1:len(t) - 1], true, true
}

// The style getComputedStyle answers for a highlight over `el`.
highlight_computed :: proc(s: ^Styled, d: ^dom.Document, el: base.Handle, kind: Highlight_Kind, name: string, alloc: runtime.Allocator) -> ^Computed {
	own := style_of(s, el)
	if own == nil { return nil }
	c := new_clone(own^, alloc)
	for g in Group { group_take(c, g, alloc) }
	p := highlight_paint(s, d, el, kind, name)
	if hs := highlight_style_at(own, kind, name); hs != nil { c.custom = hs.style.custom }
	if p.has_color { c.color = p.color }
	c.background_color = p.has_background ? p.background : {}
	c.text_shadow = p.shadows
	c.text_decoration = p.lines
	c.text_decoration_style = p.line_style
	c.text_decoration_color = p.has_line_color ? p.line_color : c.color
	c.text_decoration_thickness = p.thickness
	c.text_underline_offset = p.offset
	c.text_underline_position = p.position
	c.text_decoration_skip_ink = p.skip_ink
	if p.has_fill { c.text_fill_color = {color = p.fill} }
	if p.has_stroke { c.text_stroke_color = {color = p.stroke} }
	if p.has_stroke_width { c.text_stroke_width, c.stroke_width = p.stroke_width, p.stroke_width }
	return c
}