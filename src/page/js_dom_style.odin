package page

// CSSOM for JavaScript (api/js_dom_style.widl).
//
// element.style: a declaration block over the `style` attribute. Each call reads the attribute, parses it with the
// style engine's parser (css.parse_declarations), expands and validates it as the cascade does
// (style.compile_declarations: unknown properties and invalid values are dropped, shorthands become their longhands),
// changes the block and writes it back serialized; the attribute change restyles the element like any other.
//
// getComputedStyle: the computed values of the style engine (style.Computed), serialized as CSSOM's "resolved
// values": colors as rgb() / rgba(), lengths in px, keywords; the box sizes are the used values of the layout when the
// element has a box.

import "core:fmt"
import "core:math"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:style"

@(private)
Style_Decl :: struct {
	name:      string,   // a longhand, a custom property, or a shorthand whose value has var() (not expanded)
	value:     string,
	important: bool,
}

// Collapses runs of whitespace (CSS serialization of component values).
@(private)
css_text_of :: proc(vs: []css.Value) -> string {
	s := css.serialize_values(vs, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	space := false
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '\f' { space = strings.builder_len(b) > 0; continue }
		if space { strings.write_byte(&b, ' '); space = false }
		strings.write_byte(&b, ch)
	}
	return strings.to_string(b)
}

// Adds or replaces a declaration (in place: CSSOM "set a CSS declaration").
@(private)
block_set :: proc(block: ^[dynamic]Style_Decl, d: Style_Decl) {
	for &x in block { if x.name == d.name { x.value, x.important = d.value, d.important; return } }
	append(block, d)
}

// The declarations of CSS text, expanded and validated.
@(private)
parse_block :: proc(p: ^Page, text: string) -> [dynamic]Style_Decl {
	out := make([dynamic]Style_Decl, 0, 8, context.temp_allocator)
	if strings.trim_space(text) == "" { return out }
	opt := style.parse_options(&p.settings.style)
	decls := css.parse_declarations(text, opt, context.temp_allocator)
	for d in decls { add_declaration(p, &out, d) }
	return out
}

// One parsed declaration into the block: its longhands, or itself (custom property, shorthand with var()). False when
// the style engine refuses it.
@(private)
add_declaration :: proc(p: ^Page, block: ^[dynamic]Style_Decl, d: css.Declaration) -> bool {
	one := [1]css.Declaration{d}
	pre, customs := style.compile_declarations(p.engine, one[:], context.temp_allocator)
	for cd in customs { block_set(block, Style_Decl{name = cd.name, value = css_text_of(cd.value), important = cd.important}) }
	short_done := false
	for pd in pre {
		if pd.short != .None {
			if !short_done { block_set(block, Style_Decl{name = d.name, value = css_text_of(d.value), important = d.important}); short_done = true }
			continue
		}
		block_set(block, Style_Decl{name = style.prop_name(pd.prop), value = css_text_of(pd.value), important = pd.important})
	}
	return len(pre) > 0 || len(customs) > 0
}

// Parsed declarations kept by text (javascript.dom.style_cache_entries each): the declarations of style attributes,
// so that reading or changing element.style in a loop does not parse the attribute again, and the validated
// declarations of setProperty(name, value) pairs. The key is the text alone (the parse depends on nothing else), shared
// by every element that has it; an entry not read for a while makes room (CLOCK eviction).
@(private)
Decl_Cache :: struct {
	entries: [dynamic]Decl_Entry,
	index:   map[string]int,   // text -> entry
	hand:    int,              // the clock's hand: the next entry looked at for eviction
}

@(private)
Decl_Entry :: struct {
	text:  string,          // owned
	decls: []Style_Decl,    // owned, with their strings
	used:  bool,            // read since the hand last passed (CLOCK, a second chance: an approximate LRU in O(1))
}

@(private)
decl_entry_free :: proc(e: ^Decl_Entry) {
	for d in e.decls { delete(d.name); delete(d.value) }
	delete(e.decls)
	delete(e.text)
}

@(private)
decl_cache_destroy :: proc(dc: ^Decl_Cache) {
	for &e in dc.entries { decl_entry_free(&e) }
	delete(dc.entries)
	delete(dc.index)
}

// Keeps a copy of the declarations of `text`.
@(private)
decl_cache_put :: proc(dc: ^Decl_Cache, cap: int, text: string, block: []Style_Decl) {
	if cap <= 0 { return }
	if _, has := dc.index[text]; has { return }
	e := Decl_Entry{text = strings.clone(text), decls = make([]Style_Decl, len(block))}
	for d, i in block { e.decls[i] = Style_Decl{name = strings.clone(d.name), value = strings.clone(d.value), important = d.important} }
	if len(dc.entries) < cap {
		append(&dc.entries, e)
		dc.index[e.text] = len(dc.entries) - 1
		return
	}
	// the first entry not read since the hand last passed goes (a full turn at most)
	for dc.entries[dc.hand % len(dc.entries)].used {
		dc.entries[dc.hand % len(dc.entries)].used = false
		dc.hand += 1
	}
	victim := dc.hand % len(dc.entries)
	dc.hand += 1
	delete_key(&dc.index, dc.entries[victim].text)
	decl_entry_free(&dc.entries[victim])
	dc.entries[victim] = e
	dc.index[e.text] = victim
}

// The declarations kept for `text`, as a temporary copy the caller may change.
@(private)
decl_cache_get :: proc(dc: ^Decl_Cache, text: string) -> (out: [dynamic]Style_Decl, hit: bool) {
	i := dc.index[text] or_return
	e := &dc.entries[i]
	e.used = true
	out = make([dynamic]Style_Decl, len(e.decls), max(len(e.decls) + 1, 8), context.temp_allocator)
	for d, k in e.decls { out[k] = Style_Decl{name = strings.clone(d.name, context.temp_allocator), value = strings.clone(d.value, context.temp_allocator), important = d.important} }
	return out, true
}

@(private)
style_cache_put :: proc(p: ^Page, text: string, block: []Style_Decl) {
	decl_cache_put(&js_dom_state(p).style_blocks, p.settings.dom.style_cache_entries, text, block)
}

// The declarations of the element's style attribute (a temporary copy the caller may change).
@(private)
inline_block :: proc(c: ^Call, element: Api_Element) -> [dynamic]Style_Decl {
	v, _ := dom.get_attribute(c.page.doc, H(element.handle), "style")
	if out, hit := decl_cache_get(&js_dom_state(c.page).style_blocks, v); hit { return out }
	block := parse_block(c.page, v)
	style_cache_put(c.page, v, block[:])
	return block
}

// The value of `name` in a block: a declared longhand or custom property, or a shorthand rebuilt from its longhands
// ("" when some are missing or their priorities differ).
@(private)
block_value :: proc(block: []Style_Decl, name: string) -> (value: string, important: bool) {
	for d in block { if d.name == name { return d.value, d.important } }
	if strings.has_prefix(name, "--") { return "", false }
	_, sh, known := style.lookup_property(strings.to_lower(name, context.temp_allocator))
	if !known || sh == .None { return "", false }
	longs := style.short_longhands(sh)
	vals := make([dynamic]string, 0, len(longs), context.temp_allocator)
	imp := false
	for lp, i in longs {
		v, im := block_value(block, style.prop_name(lp))
		if v == "" { return "", false }
		if i > 0 && im != imp { return "", false }
		imp = im
		append(&vals, v)
	}
	// four sides: the shortest form (margin: 1px 2px)
	if len(vals) == 4 && (sh == .Margin || sh == .Padding || sh == .Border_Width || sh == .Border_Style || sh == .Border_Color || sh == .Inset) {
		t, r, b, l := vals[0], vals[1], vals[2], vals[3]
		switch {
		case t == r && r == b && b == l: return t, imp
		case t == b && r == l: return strings.concatenate({t, " ", r}, context.temp_allocator), imp
		case r == l: return strings.join({t, r, b}, " ", context.temp_allocator), imp
		}
		return strings.join(vals[:], " ", context.temp_allocator), imp
	}
	// border: the same width, style and color on every side
	if sh == .Border && len(vals) == 12 {
		for k in 0 ..< 3 {
			for s in 1 ..< 4 { if vals[k * 4 + s] != vals[k * 4] { return "", false } }
		}
		return strings.join({vals[0], vals[4], vals[8]}, " ", context.temp_allocator), imp
	}
	return strings.join(vals[:], " ", context.temp_allocator), imp
}

// cssText of a block: shorthands put back together where all their longhands are there (margin, padding, the border
// sides), the rest one by one.
@(private)
block_text :: proc(block: []Style_Decl) -> string {
	b := strings.builder_make(context.temp_allocator)
	done := make(map[string]bool, len(block), context.temp_allocator)
	SHORTS :: [?]string{"margin", "padding", "border-width", "border-style", "border-color", "inset"}
	for d in block {
		if d.name in done { continue }
		name, value, imp := d.name, d.value, d.important
		// only the longhands of those shorthands start so (a cheap test before looking them up)
		maybe_member := strings.has_prefix(d.name, "margin-") || strings.has_prefix(d.name, "padding-") || strings.has_prefix(d.name, "border-") ||
			d.name == "top" || d.name == "right" || d.name == "bottom" || d.name == "left"
		for sn in SHORTS {
			if !maybe_member { break }
			_, sh, _ := style.lookup_property(sn)
			longs := style.short_longhands(sh)
			member := false
			for lp in longs { if style.prop_name(lp) == d.name { member = true; break } }
			if !member { continue }
			if v, im := block_value(block, sn); v != "" {
				name, value, imp = sn, v, im
				for lp in longs { done[style.prop_name(lp)] = true }
			}
			break
		}
		done[d.name] = true
		if strings.builder_len(b) > 0 { strings.write_byte(&b, ' ') }
		strings.write_string(&b, name)
		strings.write_string(&b, ": ")
		strings.write_string(&b, value)
		if imp { strings.write_string(&b, " !important") }
		strings.write_byte(&b, ';')
	}
	return strings.to_string(b)
}

@(private)
write_block :: proc(c: ^Call, element: Api_Element, block: []Style_Decl) -> Api_Error {
	text := block_text(block)
	if err := dom_error(dom.set_attribute(c.page.doc, H(element.handle), "style", text)); err != .None { return err }
	// kept when the text parses back to this very block: no longhands put together into a shorthand (which parse again
	// in their own order)
	if strings.count(text, ";") == len(block) { style_cache_put(c.page, text, block) }
	return .None
}

InlineStyle_getProperty :: proc(c: ^Call, element: Api_Element, name: string) -> string {
	block := inline_block(c, element)
	n := strings.has_prefix(name, "--") ? name : strings.to_lower(name, context.temp_allocator)
	v, _ := block_value(block[:], n)
	return v
}

InlineStyle_priority :: proc(c: ^Call, element: Api_Element, name: string) -> string {
	block := inline_block(c, element)
	n := strings.has_prefix(name, "--") ? name : strings.to_lower(name, context.temp_allocator)
	v, imp := block_value(block[:], n)
	return v != "" && imp ? "important" : ""
}

InlineStyle_setProperty :: proc(c: ^Call, element: Api_Element, name: string, value: string, priority: string) -> Api_Error {
	if value == "" { _, err := InlineStyle_removeProperty(c, element, name); return err }
	custom := strings.has_prefix(name, "--")
	n := custom ? name : strings.to_lower(name, context.temp_allocator)
	if !custom {
		if _, _, known := style.lookup_property(n); !known { return .None }
	}
	important := false
	switch {
	case priority == "":
	case strings.equal_fold(priority, "important"): important = true
	case: return .None
	}
	// the value alone, as one declaration (a ';' or '!important' inside makes it invalid), validated alone first: an
	// invalid value changes nothing (kept by name and value: an invalid one as no declarations)
	s := js_dom_state(c.page)
	key := strings.concatenate({n, "\x00", value}, context.temp_allocator)
	probe, known := decl_cache_get(&s.style_probes, key)
	if !known {
		probe = make([dynamic]Style_Decl, 0, 4, context.temp_allocator)
		opt := style.parse_options(&c.page.settings.style)
		decls := css.parse_declarations(strings.concatenate({n, ":", value}, context.temp_allocator), opt, context.temp_allocator)
		if len(decls) == 1 && !decls[0].important && decls[0].name == n { add_declaration(c.page, &probe, decls[0]) }
		decl_cache_put(&s.style_probes, c.page.settings.dom.style_cache_entries, key, probe[:])
	}
	if len(probe) == 0 { return .None }
	for &x in probe { x.important = important }
	block := inline_block(c, element)
	// a shorthand replaces whatever said its longhands before: expanded, its longhands take their place (CSSOM "set a
	// CSS declaration": in place, or at the end); kept whole because of var(), it replaces them
	if !custom {
		if _, sh, _ := style.lookup_property(n); sh != .None {
			whole := len(probe) == 1 && probe[0].name == n
			if whole {
				for lp in style.short_longhands(sh) { remove_named(&block, style.prop_name(lp)) }
			} else {
				remove_named(&block, n)
			}
		}
	}
	for x in probe { block_set(&block, x) }
	return write_block(c, element, block[:])
}

@(private)
remove_named :: proc(block: ^[dynamic]Style_Decl, name: string) -> bool {
	for d, i in block { if d.name == name { ordered_remove(block, i); return true } }
	return false
}

InlineStyle_removeProperty :: proc(c: ^Call, element: Api_Element, name: string) -> (string, Api_Error) {
	block := inline_block(c, element)
	custom := strings.has_prefix(name, "--")
	n := custom ? name : strings.to_lower(name, context.temp_allocator)
	old, _ := block_value(block[:], n)
	old = strings.clone(old, context.temp_allocator)
	removed := remove_named(&block, n)
	if !custom {
		if _, sh, known := style.lookup_property(n); known && sh != .None {
			for lp in style.short_longhands(sh) { if remove_named(&block, style.prop_name(lp)) { removed = true } }
		}
	}
	if !removed { return old, .None }
	return old, write_block(c, element, block[:])
}

InlineStyle_cssText :: proc(c: ^Call, element: Api_Element) -> string {
	block := inline_block(c, element)
	return block_text(block[:])
}

InlineStyle_setCssText :: proc(c: ^Call, element: Api_Element, text: string) -> Api_Error {
	block := parse_block(c.page, text)
	if len(block) == 0 {
		dom.remove_attribute(c.page.doc, H(element.handle), "style")
		return dom_error(dom.set_attribute(c.page.doc, H(element.handle), "style", ""))
	}
	return write_block(c, element, block[:])
}

InlineStyle_length :: proc(c: ^Call, element: Api_Element) -> u32 { return u32(len(inline_block(c, element))) }

InlineStyle_item :: proc(c: ^Call, element: Api_Element, index: u32) -> string {
	block := inline_block(c, element)
	return int(index) < len(block) ? block[index].name : ""
}

////////////////////////////////
// getComputedStyle

// The properties getComputedStyle lists, in alphabetical order as browsers do.
@(private)
COMPUTED_PROPERTIES :: [?]string{
	"align-content", "align-items", "align-self", "aspect-ratio", "background-attachment", "background-clip", "background-color",
	"background-image", "background-origin", "background-position", "background-repeat", "background-size",
	"border-bottom-color", "border-bottom-left-radius", "border-bottom-right-radius", "border-bottom-style", "border-bottom-width",
	"border-collapse", "border-left-color", "border-left-style", "border-left-width", "border-right-color", "border-right-style",
	"border-right-width", "border-spacing", "border-top-color", "border-top-left-radius", "border-top-right-radius",
	"border-top-style", "border-top-width", "bottom", "box-shadow", "box-sizing", "clear", "color", "column-gap", "content",
	"cursor", "direction", "display", "flex-basis", "flex-direction", "flex-grow", "flex-shrink", "flex-wrap", "float",
	"font-family", "font-size", "font-stretch", "font-style", "font-weight", "height", "justify-content", "left",
	"letter-spacing", "line-height", "list-style-position", "list-style-type", "margin-bottom", "margin-left", "margin-right",
	"margin-top", "max-height", "max-width", "min-height", "min-width", "object-fit", "opacity", "order", "outline-color",
	"outline-offset", "outline-style", "outline-width", "overflow-wrap", "overflow-x", "overflow-y", "padding-bottom",
	"padding-left", "padding-right", "padding-top", "pointer-events", "position", "right", "row-gap", "text-align",
	"text-decoration-color", "text-decoration-line", "text-decoration-style", "text-indent", "text-overflow", "text-shadow",
	"text-transform", "top", "transform", "transform-origin", "user-select", "vertical-align", "visibility",
	"white-space", "width", "word-break", "word-spacing", "z-index",
}

ComputedStyle_count :: proc(c: ^Call) -> u32 { return len(COMPUTED_PROPERTIES) }

ComputedStyle_name :: proc(c: ^Call, index: u32) -> string {
	names := COMPUTED_PROPERTIES
	return int(index) < len(names) ? names[index] : ""
}

// A number as CSS serializes it: no exponent, at most 6 decimals, no trailing zeros.
@(private)
css_num :: proc(v: f32) -> string {
	x := f64(v)
	if math.is_nan(x) || math.is_inf(x) { return "0" }
	if x == math.round(x) && abs(x) < 1e15 { return fmt.tprintf("%d", i64(x)) }
	buf: [64]u8
	s := strconv.write_float(buf[:], x, 'f', 6, 64)
	if len(s) > 0 && s[0] == '+' { s = s[1:] }
	for strings.contains(s, ".") && (s[len(s) - 1] == '0' || s[len(s) - 1] == '.') {
		last := s[len(s) - 1]
		s = s[:len(s) - 1]
		if last == '.' { break }
	}
	return strings.clone(s, context.temp_allocator)
}

@(private)
css_px :: proc(v: f32) -> string { return strings.concatenate({css_num(v), "px"}, context.temp_allocator) }

@(private)
css_color :: proc(col: css.Color) -> string {
	ch :: proc(v: f32) -> int { return int(math.round(clamp(v, 0, 1) * 255)) }
	if col.a >= 1 { return fmt.tprintf("rgb(%d, %d, %d)", ch(col.r), ch(col.g), ch(col.b)) }
	return fmt.tprintf("rgba(%d, %d, %d, %s)", ch(col.r), ch(col.g), ch(col.b), css_num(f32(math.round(f64(col.a) * 1000) / 1000)))
}

@(private)
css_keyword :: proc(v: any) -> string {
	name, ok := reflect.enum_name_from_value_any(v)
	if !ok { return "" }
	return style.dashed(name)   // heap: kept by the caller's temp copy below
}

@(private)
kw :: proc(v: any) -> string {
	s := css_keyword(v)
	out := strings.clone(s, context.temp_allocator)
	delete(s)
	return out
}

@(private)
css_length :: proc(l: style.Length) -> string {
	switch l.kind {
	case .Auto: return "auto"
	case .None: return "none"
	case .Normal: return "normal"
	case .Px: return css_px(l.v)
	case .Percent: return strings.concatenate({css_num(l.v), "%"}, context.temp_allocator)
	case .Calc: return "calc(0px)"
	case .Min_Content: return "min-content"
	case .Max_Content: return "max-content"
	case .Fit_Content: return "fit-content"
	}
	return ""
}

@(private)
css_shadows :: proc(list: []style.Shadow) -> string {
	if len(list) == 0 { return "none" }
	parts := make([dynamic]string, 0, len(list), context.temp_allocator)
	for s in list {
		t := fmt.tprintf("%s %s %s %s", css_color(s.color), css_px(s.x), css_px(s.y), css_px(s.blur))
		if s.spread != 0 { t = fmt.tprintf("%s %s", t, css_px(s.spread)) }
		if s.inset { t = strings.concatenate({t, " inset"}, context.temp_allocator) }
		append(&parts, t)
	}
	return strings.join(parts[:], ", ", context.temp_allocator)
}

@(private)
css_align :: proc(a: style.Content_Align) -> string {
	#partial switch a {
	case .Flex_Start: return "flex-start"
	case .Flex_End: return "flex-end"
	case .Space_Between: return "space-between"
	case .Space_Around: return "space-around"
	case .Space_Evenly: return "space-evenly"
	}
	return kw(a)
}

@(private)
GENERIC_FAMILIES :: [?]string{"serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui", "math", "emoji", "ui-serif", "ui-sans-serif", "ui-monospace", "ui-rounded"}

@(private)
css_font_family :: proc(list: []string) -> string {
	parts := make([dynamic]string, 0, len(list), context.temp_allocator)
	for f in list {
		generic := false
		for g in GENERIC_FAMILIES { if g == f { generic = true; break } }
		if !generic && strings.contains(f, " ") { append(&parts, fmt.tprintf("\"%s\"", f)) } else { append(&parts, f) }
	}
	return strings.join(parts[:], ", ", context.temp_allocator)
}

// The used size of a box side (the layout's), when the element has a box.
@(private)
Used_Box :: struct {
	ok:              bool,
	width, height:   f32,       // content box, CSS px
	margin, padding: [4]f32,    // top right bottom left
}

// The resolved value of property `name` for computed style `cs` (CSSOM §9 "resolved value"), "" when not known.
computed_value :: proc(cs: ^style.Computed, name: string, used: Used_Box) -> string {
	side :: proc(name: string) -> int {
		switch {
		case strings.contains(name, "top"): return 0
		case strings.contains(name, "right"): return 1
		case strings.contains(name, "bottom"): return 2
		}
		return 3
	}
	switch name {
	case "display": return cs.display == .Inline_Block ? "inline-block" : cs.display == .List_Item ? "list-item" : kw(cs.display)
	case "position": return kw(cs.position)
	case "float": return kw(cs.float)
	case "clear": return kw(cs.clear)
	case "box-sizing": return kw(cs.box_sizing)
	case "visibility": return kw(cs.visibility)
	case "overflow-x": return kw(cs.overflow_x)
	case "overflow-y": return kw(cs.overflow_y)
	case "overflow":
		x, y := kw(cs.overflow_x), kw(cs.overflow_y)
		return x == y ? x : strings.concatenate({x, " ", y}, context.temp_allocator)
	case "top", "right", "bottom", "left": return css_length(cs.inset[style.Side(side(name))])
	case "z-index": return cs.z_auto ? "auto" : fmt.tprintf("%d", cs.z_index)
	case "width": if used.ok && cs.display != .Inline { return css_px(used.width) }; return css_length(cs.width)
	case "height": if used.ok && cs.display != .Inline { return css_px(used.height) }; return css_length(cs.height)
	case "min-width": return cs.min_width.kind == .Auto ? "auto" : css_length(cs.min_width)
	case "min-height": return cs.min_height.kind == .Auto ? "auto" : css_length(cs.min_height)
	case "max-width": return css_length(cs.max_width)
	case "max-height": return css_length(cs.max_height)
	case "margin-top", "margin-right", "margin-bottom", "margin-left":
		s := side(name)
		if used.ok { return css_px(used.margin[s]) }
		return css_length(cs.margin[style.Side(s)])
	case "padding-top", "padding-right", "padding-bottom", "padding-left":
		s := side(name)
		if used.ok { return css_px(used.padding[s]) }
		return css_length(cs.padding[style.Side(s)])
	case "margin", "padding":
		parts: [4]string
		sides := [4]string{"top", "right", "bottom", "left"}
		for s in 0 ..< 4 { parts[s] = computed_value(cs, fmt.tprintf("%s-%s", name, sides[s]), used) }
		return strings.join(parts[:], " ", context.temp_allocator)
	case "border-top-width", "border-right-width", "border-bottom-width", "border-left-width":
		s := style.Side(side(name))
		w := cs.border_style[s] == .None || cs.border_style[s] == .Hidden ? 0 : cs.border_width[s]
		return css_px(w)
	case "border-top-style", "border-right-style", "border-bottom-style", "border-left-style": return kw(cs.border_style[style.Side(side(name))])
	case "border-top-color", "border-right-color", "border-bottom-color", "border-left-color": return css_color(cs.border_color[style.Side(side(name))])
	case "border-top-left-radius": return css_length(cs.radius[.Top_Left].h)
	case "border-top-right-radius": return css_length(cs.radius[.Top_Right].h)
	case "border-bottom-right-radius": return css_length(cs.radius[.Bottom_Right].h)
	case "border-bottom-left-radius": return css_length(cs.radius[.Bottom_Left].h)
	case "border-collapse": return cs.border_collapse ? "collapse" : "separate"
	case "border-spacing": return fmt.tprintf("%s %s", css_px(cs.border_spacing[0]), css_px(cs.border_spacing[1]))
	case "opacity": return css_num(cs.opacity)
	case "vertical-align":
		if cs.vertical_align.kind == .Length { return css_length(cs.vertical_align.amount) }
		return kw(cs.vertical_align.kind)
	case "aspect-ratio": return cs.aspect_ratio == 0 ? "auto" : fmt.tprintf("%s / 1", css_num(cs.aspect_ratio))
	case "object-fit": return kw(cs.object_fit)
	case "flex-direction": return kw(cs.flex_direction)
	case "flex-wrap": return kw(cs.flex_wrap)
	case "flex-grow": return css_num(cs.flex_grow)
	case "flex-shrink": return css_num(cs.flex_shrink)
	case "flex-basis": return css_length(cs.flex_basis)
	case "justify-content": return css_align(cs.justify_content)
	case "align-items": return css_align(cs.align_items)
	case "align-self": return css_align(cs.align_self)
	case "align-content": return css_align(cs.align_content)
	case "order": return fmt.tprintf("%d", cs.order)
	case "row-gap": return css_length(cs.row_gap)
	case "column-gap": return css_length(cs.column_gap)
	case "color": return css_color(cs.color)
	case "font-family": return css_font_family(cs.font_family)
	case "font-size": return css_px(cs.font_size)
	case "font-weight": return fmt.tprintf("%d", cs.font_weight)
	case "font-style": return kw(cs.font_style)
	case "font-stretch": return strings.concatenate({css_num(cs.font_stretch), "%"}, context.temp_allocator)
	case "line-height":
		switch cs.line_height.kind {
		case .Normal: return "normal"
		case .Number: return css_px(cs.line_height.v * cs.font_size)
		case .Length: return css_px(cs.line_height.v)
		}
	case "letter-spacing": return cs.letter_spacing == 0 ? "normal" : css_px(cs.letter_spacing)
	case "word-spacing": return css_px(cs.word_spacing)
	case "text-align":
		#partial switch cs.text_align {
		case .Legacy_Left: return "-webkit-left"
		case .Legacy_Right: return "-webkit-right"
		case .Legacy_Center: return "-webkit-center"
		}
		return kw(cs.text_align)
	case "text-decoration-line":
		if cs.text_decoration == {} { return "none" }
		parts := make([dynamic]string, 0, 3, context.temp_allocator)
		if .Underline in cs.text_decoration { append(&parts, "underline") }
		if .Overline in cs.text_decoration { append(&parts, "overline") }
		if .Line_Through in cs.text_decoration { append(&parts, "line-through") }
		return strings.join(parts[:], " ", context.temp_allocator)
	case "text-decoration-color": return css_color(cs.text_decoration_color)
	case "text-decoration-style": return kw(cs.text_decoration_style)
	case "text-transform": return kw(cs.text_transform)
	case "text-indent": return css_length(cs.text_indent)
	case "text-overflow": return cs.text_ellipsis ? "ellipsis" : "clip"
	case "text-shadow": return css_shadows(cs.text_shadow)
	case "white-space": return cs.white_space == .Pre_Wrap ? "pre-wrap" : cs.white_space == .Pre_Line ? "pre-line" : kw(cs.white_space)
	case "word-break": return kw(cs.word_break)
	case "overflow-wrap": return kw(cs.overflow_wrap)
	case "direction": return kw(cs.direction)
	case "background-color": return css_color(cs.background_color)
	case "background-image":
		#partial switch cs.background_image.kind {
		case .Url: return fmt.tprintf("url(\"%s\")", cs.background_image.url)
		case .Gradient: return cs.background_image.gradient
		}
		return "none"
	case "background-repeat":
		r := cs.background_repeat
		if r[0] == .Repeat && r[1] == .Repeat { return "repeat" }
		if r[0] == .No_Repeat && r[1] == .No_Repeat { return "no-repeat" }
		if r[0] == .Repeat && r[1] == .No_Repeat { return "repeat-x" }
		if r[0] == .No_Repeat && r[1] == .Repeat { return "repeat-y" }
		return strings.concatenate({kw(r[0]), " ", kw(r[1])}, context.temp_allocator)
	case "background-position": return strings.concatenate({css_length(cs.background_position[0]), " ", css_length(cs.background_position[1])}, context.temp_allocator)
	case "background-size":
		switch cs.background_size.kind {
		case .Auto: return "auto"
		case .Cover: return "cover"
		case .Contain: return "contain"
		case .Length: return strings.concatenate({css_length(cs.background_size.w), " ", css_length(cs.background_size.h)}, context.temp_allocator)
		}
	case "background-attachment": return len(cs.background_attachments) > 0 ? kw(cs.background_attachments[0]) : "scroll"
	case "background-origin": return len(cs.background_origins) > 0 ? kw(cs.background_origins[0]) : "padding-box"
	case "background-clip": return len(cs.background_clips) > 0 ? kw(cs.background_clips[0]) : "border-box"
	case "box-shadow": return css_shadows(cs.box_shadow)
	case "list-style-type": return cs.list_style_type == .Decimal_Leading_Zero ? "decimal-leading-zero" : kw(cs.list_style_type)
	case "list-style-position": return kw(cs.list_style_position)
	case "cursor": return kw(cs.cursor)
	case "pointer-events": return cs.pointer_events ? "auto" : "none"
	case "user-select": return kw(cs.user_select)
	case "content":
		#partial switch cs.content.kind {
		case .None: return "none"
		case .Items:
			b := strings.builder_make(context.temp_allocator)
			for it in cs.content.items { if it.kind == .Text { fmt.sbprintf(&b, "\"%s\"", it.text) } }
			return strings.to_string(b)
		}
		return "normal"
	case "outline-width": return css_px(cs.outline_style == .None ? 0 : cs.outline_width)
	case "outline-style": return kw(cs.outline_style)
	case "outline-color": return css_color(cs.outline_color)
	case "outline-offset": return css_px(cs.outline_offset)
	case "transform":
		if len(cs.transform) == 0 { return "none" }
		return "matrix(1, 0, 0, 1, 0, 0)"
	case "transform-origin": return strings.concatenate({css_length(cs.transform_origin[0]), " ", css_length(cs.transform_origin[1])}, context.temp_allocator)
	}
	if strings.has_prefix(name, "--") && cs.custom != nil {
		if v, ok := cs.custom.values[name]; ok { return v }
	}
	return ""
}

ComputedStyle_get :: proc(c: ^Call, element: Api_Element, pseudo: string, name: string) -> string {
	p := c.page
	h := H(element.handle)
	st := js_dom_styled(p)
	if st == nil { return "" }
	cs := style.style_of(st, h)
	if cs == nil { return "" }
	used: Used_Box
	switch pseudo {
	case "::before", ":before": cs = cs.before
	case "::after", ":after": cs = cs.after
	case "":
		used = used_box(p, h)
	}
	if cs == nil { return "" }
	n := strings.has_prefix(name, "--") ? name : strings.to_lower(name, context.temp_allocator)
	if !strings.has_prefix(n, "--") {
		if _, _, known := style.lookup_property(n); known {
			// aliases (-webkit-*) and logical names read their standard property
			if canon, ok := property_canonical(n); ok { n = canon }
		}
	}
	return computed_value(cs, n, used)
}

// The standard name an alias stands for ("-webkit-box-shadow" -> "box-shadow", "margin-inline-start" -> "margin-left").
@(private)
property_canonical :: proc(name: string) -> (string, bool) {
	p, sh, known := style.lookup_property(name)
	if !known || sh != .None { return name, known }
	return style.prop_name(p), true
}

_ :: base

CSS_supportsDeclaration :: proc(c: ^Call, property, value: string) -> bool {
	p := c.page
	if p.engine == nil { return false }
	return style.supports_declaration(p.engine, property, value, style.parse_options(&p.settings.style))
}

CSS_supportsCondition :: proc(c: ^Call, condition: string) -> bool {
	p := c.page
	if p.engine == nil { return false }
	return style.supports_text(p.engine, condition, style.parse_options(&p.settings.style))
}
