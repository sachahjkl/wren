package style

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:css"
import "wb:dom"

// HTML's presentational hints (HTML §15 Rendering): attributes such as align, valign, bgcolor, width / height,
// cellpadding, cellspacing, border, <font size color face>, hspace / vspace, <hr size noshade>, list types... map to CSS
// declarations. They take part in the cascade as author declarations of specificity zero that come before every author
// stylesheet and below every cascade layer (CSS Cascade 5 §6.1): the page's own CSS always wins over them, while they win
// over the browser's stylesheet. The declarations are generated as CSS text and compiled like a style attribute, so the
// values go through the same parsing as everything else.
//
// Documents in quirks mode (no doctype or an old one) also get the quirks of the rendering section and of other browsers
// that are style rules: tables do not inherit fonts, forms have a bottom margin, floated images a 3px margin.

// The specificity of hints (zero): a shared, read-only selector record for the entry that carries them.
@(private)
hint_complex: css.Complex

// Appends to `p.lists[0]` the entry holding the presentational hints of element `n`, if it has some.
@(private)
add_hint_entry :: proc(p: ^Pass, h: base.Handle, n: ^dom.Node) {
	if !p.e.settings.presentational_hints || !p.e.settings.author_stylesheets { return }
	text := hint_text(p.mc.doc, h, n, p.e.settings.quirks_rules)
	if text == "" { return }
	decls := css.parse_declarations(text, p.opt, context.temp_allocator)
	pre, customs := compile_declarations(p.e, decls, p.alloc, &p.stats)
	if len(pre) == 0 { return }
	r := new(Rule, context.temp_allocator)
	r^ = Rule{decls = pre, customs = customs, origin = .Author, layer = 0, order = 0, hint = true}
	append(&p.lists[0], Entry{rule = r, complex = &hint_complex})
}

// Attributes that are presentational hints of some element; `subtree`: a change to it on this element also changes the
// hints of its descendants (a table's cellpadding and border reach its cells, the body's link colors its links).
hint_attribute :: proc(element, name: string) -> (hint: bool, subtree: bool) {
	switch name {
	case "align", "valign", "bgcolor", "background", "width", "height", "nowrap", "hspace", "vspace", "border", "color",
	     "face", "size", "clear", "type", "noshade", "text", "marginwidth", "marginheight", "leftmargin", "rightmargin",
	     "topmargin", "bottommargin", "frameborder", "wrap", "bordercolor":
		hint = true
	case "cellspacing":
		hint = element == "table"
	}
	switch element {
	case "table":
		switch name {
		case "cellpadding", "border", "rules", "frame", "bordercolor": return true, true
		}
	case "body":
		switch name {
		case "link", "vlink", "alink": return true, true
		}
	}
	return
}

// The hint declarations of element `h` as CSS text (temp allocator), "" when it has none.
hint_text :: proc(doc: ^dom.Document, h: base.Handle, n: ^dom.Node, quirks_rules := true) -> string {
	if n == nil || n.kind != .Element { return "" }
	quirks := quirks_rules && doc.mode == .Quirks
	sb := strings.builder_make(context.temp_allocator)
	w := &sb
	switch n.name {
	case "body":
		hint_color(w, n, "bgcolor", "background-color")
		hint_color(w, n, "text", "color")
		hint_background(w, n)
		hint_dimension(w, n, "marginwidth", "margin-left", false)
		hint_dimension(w, n, "marginwidth", "margin-right", false)
		hint_dimension(w, n, "marginheight", "margin-top", false)
		hint_dimension(w, n, "marginheight", "margin-bottom", false)
		hint_dimension(w, n, "leftmargin", "margin-left", false)
		hint_dimension(w, n, "rightmargin", "margin-right", false)
		hint_dimension(w, n, "topmargin", "margin-top", false)
		hint_dimension(w, n, "bottommargin", "margin-bottom", false)
	case "table":
		hint_color(w, n, "bgcolor", "background-color")
		hint_background(w, n)
		hint_dimension(w, n, "width", "width", true)
		hint_dimension(w, n, "height", "height", false)
		if v, ok := attr(n, "cellspacing"); ok {
			if px, ok2 := parse_nonneg_int(v); ok2 { fmt.sbprintf(w, "border-spacing:%dpx;", px) }
		}
		if v, ok := attr(n, "align"); ok {
			switch {
			case strings.equal_fold(v, "left"): strings.write_string(w, "float:left;")
			case strings.equal_fold(v, "right"): strings.write_string(w, "float:right;")
			case strings.equal_fold(v, "center"), strings.equal_fold(v, "middle"): strings.write_string(w, "margin-left:auto;margin-right:auto;")
			}
		}
		table_border_hints(w, n)
		if quirks {
			// HTML §15.3.8 (quirks): tables reset the inherited text properties (font-family is kept)
			strings.write_string(w, "font-weight:initial;font-style:initial;font-variant:initial;font-size:initial;line-height:initial;white-space:initial;text-align:initial;")
		}
	case "caption":
		if v, ok := attr(n, "align"); ok {
			switch {
			case strings.equal_fold(v, "left"): strings.write_string(w, "text-align:left;")
			case strings.equal_fold(v, "right"): strings.write_string(w, "text-align:right;")
			case strings.equal_fold(v, "center"): strings.write_string(w, "text-align:center;")
			}
		}
	case "thead", "tbody", "tfoot", "tr":
		hint_cell_align(w, n)
		hint_valign(w, n)
		hint_color(w, n, "bgcolor", "background-color")
		hint_background(w, n)
		if n.name == "tr" { hint_dimension(w, n, "height", "height", false) }
		if table := owning_table(doc, n); table != nil { group_border_hints(w, n, table) }
	case "td", "th":
		hint_cell_align(w, n)
		hint_valign(w, n)
		hint_color(w, n, "bgcolor", "background-color")
		hint_background(w, n)
		hint_dimension(w, n, "width", "width", true)
		hint_dimension(w, n, "height", "height", true)
		if _, ok := attr(n, "nowrap"); ok { strings.write_string(w, "white-space:nowrap;") }
		if table := owning_table(doc, n); table != nil {
			if v, ok := attr(table, "cellpadding"); ok {
				if px, ok2 := parse_nonneg_int(v); ok2 { fmt.sbprintf(w, "padding:%dpx;", px) }
			}
			cell_border_hints(w, table)
		}
	case "col", "colgroup":
		hint_dimension(w, n, "width", "width", false)
	case "div":
		hint_cell_align(w, n)
	case "p", "h1", "h2", "h3", "h4", "h5", "h6":
		if v, ok := attr(n, "align"); ok {
			for k in ([?]string{"left", "right", "center", "justify"}) {
				if strings.equal_fold(v, k) { fmt.sbprintf(w, "text-align:%s;", k) }
			}
		}
	case "pre", "listing", "xmp":
		if _, ok := attr(n, "wrap"); ok { strings.write_string(w, "white-space:pre-wrap;") }
	case "font":
		hint_color(w, n, "color", "color")
		if v, ok := attr(n, "face"); ok { hint_font_face(w, v) }
		if v, ok := attr(n, "size"); ok {
			if kw, ok2 := legacy_font_size(v); ok2 { fmt.sbprintf(w, "font-size:%s;", kw) }
		}
	case "br":
		if v, ok := attr(n, "clear"); ok {
			switch {
			case strings.equal_fold(v, "left"): strings.write_string(w, "clear:left;")
			case strings.equal_fold(v, "right"): strings.write_string(w, "clear:right;")
			case strings.equal_fold(v, "all"), strings.equal_fold(v, "both"): strings.write_string(w, "clear:both;")
			}
		}
	case "img":
		embedded_hints(w, n, true, true)
		if quirks {
			if v, ok := attr(n, "align"); ok {
				if strings.equal_fold(v, "left") { strings.write_string(w, "margin-right:3px;") }
				if strings.equal_fold(v, "right") { strings.write_string(w, "margin-left:3px;") }
			}
		}
	case "input":
		if t, ok := attr(n, "type"); ok && strings.equal_fold(strings.trim_space(t), "image") {
			embedded_hints(w, n, true, true)
		} else if quirks {
			strings.write_string(w, "box-sizing:border-box;")
		}
	case "textarea":
		if quirks { strings.write_string(w, "box-sizing:border-box;") }
	case "object":
		embedded_hints(w, n, true, false)
	case "embed":
		embedded_hints(w, n, false, false)
	case "iframe":
		embedded_hints(w, n, false, false)
		if v, ok := attr(n, "frameborder"); ok {
			if px, ok2 := parse_nonneg_int(v); ok2 && px == 0 { strings.write_string(w, "border:none;") }
		}
	case "video":
		hint_dimension(w, n, "width", "width", false)
		hint_dimension(w, n, "height", "height", false)
		hint_aspect_ratio(w, n)
	case "hr":
		hr_hints(w, n)
	case "ol":
		if v, ok := attr(n, "type"); ok { if t := ordered_type(v); t != "" { fmt.sbprintf(w, "list-style-type:%s;", t) } }
	case "ul":
		if v, ok := attr(n, "type"); ok { if t := unordered_type(v); t != "" { fmt.sbprintf(w, "list-style-type:%s;", t) } }
	case "li":
		if v, ok := attr(n, "type"); ok {
			t := ordered_type(v)
			if t == "" { t = unordered_type(v) }
			if t != "" { fmt.sbprintf(w, "list-style-type:%s;", t) }
		}
	case "form":
		if quirks { strings.write_string(w, "margin-block-end:1em;") }
	}
	// links take the body's link color (HTML §15.3.4: body[link]); a page's own a:link rule still wins
	if n.name == "a" || n.name == "area" {
		if _, ok := attr(n, "href"); ok {
			if body := document_body(doc); body != nil { hint_color(w, body, "link", "color") }
		}
	}
	return strings.to_string(sb)
}

////////////////////////////////
// Parsing of attribute values (HTML §2.3.4 microsyntaxes)

// Rules for parsing non-negative integers (HTML §2.3.4.2).
parse_nonneg_int :: proc(s: string) -> (int, bool) {
	i := 0
	for i < len(s) && is_html_space(s[i]) { i += 1 }
	if i < len(s) && s[i] == '+' { i += 1 }
	start := i
	v := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		v = min(v * 10 + int(s[i] - '0'), 1 << 30)
		i += 1
	}
	return v, i > start
}

// Rules for parsing dimension values (HTML §2.3.4.4): a length in px, or a percentage.
parse_dimension :: proc(s: string) -> (value: f64, percent: bool, ok: bool) {
	i := 0
	for i < len(s) && is_html_space(s[i]) { i += 1 }
	if i >= len(s) || s[i] < '0' || s[i] > '9' { return }
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		value = min(value * 10 + f64(s[i] - '0'), 1e9)
		i += 1
	}
	ok = true
	if i < len(s) && s[i] == '.' {
		i += 1
		div := 1.0
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			div *= 10
			value += f64(s[i] - '0') / div
			i += 1
		}
	}
	percent = i < len(s) && s[i] == '%'
	return
}

// Rules for parsing a legacy colour value (HTML §2.3.6.4). Returns 0xRRGGBB.
parse_legacy_color :: proc(input: string) -> (rgb: u32, ok: bool) {
	s := strings.trim(input, " \t\n\f\r")
	if s == "" || strings.equal_fold(s, "transparent") { return 0, false }
	lower := strings.to_lower(s, context.temp_allocator)
	for e in css.NAMED_COLORS { if e.name == lower { return e.rgb, true } }
	hexv :: proc(c: u8) -> (u32, bool) {
		switch c {
		case '0' ..= '9': return u32(c - '0'), true
		case 'a' ..= 'f': return u32(c - 'a' + 10), true
		case 'A' ..= 'F': return u32(c - 'A' + 10), true
		}
		return 0, false
	}
	if len(s) == 4 && s[0] == '#' {
		r, a := hexv(s[1]); g, b := hexv(s[2]); bl, c := hexv(s[3])
		if a && b && c { return (r * 17) << 16 | (g * 17) << 8 | bl * 17, true }
	}
	// code points above U+FFFF count as "00"; anything that is not a hex digit becomes 0
	digits := make([dynamic]u8, 0, len(s) + 2, context.temp_allocator)
	for r in s {
		if r > 0xFFFF { append(&digits, '0', '0'); continue }
		if r < 0x80 {
			if _, is_hex := hexv(u8(r)); is_hex { append(&digits, u8(r)); continue }
		}
		append(&digits, '0')
	}
	if len(digits) > 128 { resize(&digits, 128) }
	d := digits[:]
	if len(d) > 0 && s[0] == '#' { d = d[1:] }
	buf := make([dynamic]u8, 0, len(d) + 3, context.temp_allocator)
	append(&buf, ..d)
	for len(buf) == 0 || len(buf) % 3 != 0 { append(&buf, '0') }
	n := len(buf) / 3
	comp := [3][]u8{buf[:n], buf[n:2 * n], buf[2 * n:]}
	if n > 8 { for &c in comp { c = c[len(c) - 8:] } }
	for len(comp[0]) > 2 && comp[0][0] == '0' && comp[1][0] == '0' && comp[2][0] == '0' {
		for &c in comp { c = c[1:] }
	}
	if len(comp[0]) > 2 { for &c in comp { c = c[:2] } }
	for c, i in comp {
		v: u32
		for ch in c { x, _ := hexv(ch); v = v * 16 + x }
		rgb |= v << u32(16 - 8 * i)
	}
	return rgb, true
}

// Rules for parsing a legacy font size (HTML §15.3.4, <font size>): the keyword it maps to.
legacy_font_size :: proc(s: string) -> (string, bool) {
	i := 0
	for i < len(s) && is_html_space(s[i]) { i += 1 }
	if i >= len(s) { return "", false }
	mode := 0
	if s[i] == '+' { mode = 1; i += 1 } else if s[i] == '-' { mode = -1; i += 1 }
	start := i
	v := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' { v = min(v * 10 + int(s[i] - '0'), 100); i += 1 }
	if i == start { return "", false }
	if mode == 1 { v = 3 + v } else if mode == -1 { v = 3 - v }
	v = clamp(v, 1, 7)
	KEYWORDS := [8]string{"", "x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large"}
	return KEYWORDS[v], true
}

@(private)
is_html_space :: proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\f' || c == '\r' }

////////////////////////////////
// Writers

@(private)
hint_color :: proc(w: ^strings.Builder, n: ^dom.Node, name, prop: string) {
	v, ok := attr(n, name)
	if !ok { return }
	rgb, cok := parse_legacy_color(v)
	if !cok { return }
	fmt.sbprintf(w, "%s:#%06x;", prop, rgb)
}

@(private)
hint_background :: proc(w: ^strings.Builder, n: ^dom.Node) {
	v, ok := attr(n, "background")
	if !ok { return }
	v = strings.trim_space(v)
	if v == "" { return }
	strings.write_string(w, "background-image:url(\"")
	for r in v {
		switch r {
		case '"', '\\': strings.write_byte(w, '\\'); strings.write_rune(w, r)
		case '\n', '\r', '\f': // (not part of a URL)
		case: strings.write_rune(w, r)
		}
	}
	strings.write_string(w, "\");")
}

// A dimension attribute; `non_zero`: zero is ignored (the "non-zero dimension" rules).
@(private)
hint_dimension :: proc(w: ^strings.Builder, n: ^dom.Node, name, prop: string, non_zero: bool) {
	v, ok := attr(n, name)
	if !ok { return }
	d, pct, dok := parse_dimension(v)
	if !dok || (non_zero && d == 0) { return }
	strings.write_string(w, prop)
	strings.write_byte(w, ':')
	write_num(w, d, pct ? "%;" : "px;")
}

// width / height attributes of an image or video also give it a preferred ratio until its own is known.
@(private)
hint_aspect_ratio :: proc(w: ^strings.Builder, n: ^dom.Node) {
	wv, wok := attr(n, "width")
	hv, hok := attr(n, "height")
	if !wok || !hok { return }
	ww, wp, w_ok := parse_dimension(wv)
	hh, hp, h_ok := parse_dimension(hv)
	if !w_ok || !h_ok || wp || hp || ww <= 0 || hh <= 0 { return }
	strings.write_string(w, "aspect-ratio:auto ")
	write_num(w, ww, " / ")
	write_num(w, hh, ";")
}

// align on div, tr, td, th, thead / tbody / tfoot: aligns the text and the narrower blocks inside (-webkit-*)
@(private)
hint_cell_align :: proc(w: ^strings.Builder, n: ^dom.Node) {
	v, ok := attr(n, "align")
	if !ok { return }
	v = strings.trim_space(v)
	switch {
	case strings.equal_fold(v, "left"): strings.write_string(w, "text-align:-webkit-left;")
	case strings.equal_fold(v, "right"): strings.write_string(w, "text-align:-webkit-right;")
	case strings.equal_fold(v, "center"), strings.equal_fold(v, "middle"): strings.write_string(w, "text-align:-webkit-center;")
	case strings.equal_fold(v, "justify"): strings.write_string(w, "text-align:justify;")
	}
}

@(private)
hint_valign :: proc(w: ^strings.Builder, n: ^dom.Node) {
	v, ok := attr(n, "valign")
	if !ok { return }
	v = strings.trim_space(v)
	for k in ([?]string{"top", "middle", "bottom", "baseline"}) {
		if strings.equal_fold(v, k) { fmt.sbprintf(w, "vertical-align:%s;", k) }
	}
}

// <font face="A, B">: each name quoted (generic families stay keywords)
@(private)
hint_font_face :: proc(w: ^strings.Builder, v: string) {
	rest := v
	first := true
	for part in strings.split_iterator(&rest, ",") {
		name := strings.trim(part, " \t\n\f\r\"'")
		if name == "" { continue }
		strings.write_string(w, first ? "font-family:" : ",")
		first = false
		switch strings.to_lower(name, context.temp_allocator) {
		case "serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui":
			strings.write_string(w, name)
		case:
			strings.write_byte(w, '"')
			for r in name {
				if r == '"' || r == '\\' { strings.write_byte(w, '\\') }
				strings.write_rune(w, r)
			}
			strings.write_byte(w, '"')
		}
	}
	if !first { strings.write_byte(w, ';') }
}

// img, object, embed, iframe, input type=image: size, spacing, border and alignment
@(private)
embedded_hints :: proc(w: ^strings.Builder, n: ^dom.Node, border, ratio: bool) {
	hint_dimension(w, n, "width", "width", false)
	hint_dimension(w, n, "height", "height", false)
	if ratio { hint_aspect_ratio(w, n) }
	hint_dimension(w, n, "hspace", "margin-left", false)
	hint_dimension(w, n, "hspace", "margin-right", false)
	hint_dimension(w, n, "vspace", "margin-top", false)
	hint_dimension(w, n, "vspace", "margin-bottom", false)
	if border {
		if v, ok := attr(n, "border"); ok {
			if px, ok2 := parse_nonneg_int(v); ok2 { fmt.sbprintf(w, "border-width:%dpx;border-style:solid;", px) }
		}
	}
	if v, ok := attr(n, "align"); ok {
		v = strings.trim_space(v)
		// as Blink maps them (the HTML Standard lists the same keywords)
		switch {
		case strings.equal_fold(v, "left"): strings.write_string(w, "float:left;")
		case strings.equal_fold(v, "right"): strings.write_string(w, "float:right;")
		case strings.equal_fold(v, "top"): strings.write_string(w, "vertical-align:top;")
		case strings.equal_fold(v, "texttop"): strings.write_string(w, "vertical-align:text-top;")
		case strings.equal_fold(v, "middle"), strings.equal_fold(v, "absmiddle"), strings.equal_fold(v, "center"): strings.write_string(w, "vertical-align:middle;")
		case strings.equal_fold(v, "bottom"), strings.equal_fold(v, "baseline"): strings.write_string(w, "vertical-align:baseline;")
		case strings.equal_fold(v, "absbottom"): strings.write_string(w, "vertical-align:bottom;")
		}
	}
}

@(private)
hr_hints :: proc(w: ^strings.Builder, n: ^dom.Node) {
	if v, ok := attr(n, "align"); ok {
		switch {
		case strings.equal_fold(v, "left"): strings.write_string(w, "margin-left:0;margin-right:auto;")
		case strings.equal_fold(v, "right"): strings.write_string(w, "margin-left:auto;margin-right:0;")
		case strings.equal_fold(v, "center"): strings.write_string(w, "margin-left:auto;margin-right:auto;")
		}
	}
	hint_dimension(w, n, "width", "width", true)
	if v, ok := attr(n, "color"); ok {
		if rgb, cok := parse_legacy_color(v); cok {
			fmt.sbprintf(w, "border-style:solid;border-color:#%06x;background-color:#%06x;", rgb, rgb)
		}
	} else if _, shade := attr(n, "noshade"); shade {
		strings.write_string(w, "border-style:solid;border-color:gray;background-color:gray;")
	}
	if v, ok := attr(n, "size"); ok {
		if px, ok2 := parse_nonneg_int(v); ok2 && px > 0 {
			if px <= 1 { strings.write_string(w, "border-bottom-width:0;") } else { fmt.sbprintf(w, "height:%dpx;", px - 2) }
		}
	}
}

@(private)
ordered_type :: proc(v: string) -> string {
	switch strings.trim_space(v) {   // case-sensitive: a and A differ
	case "1": return "decimal"
	case "a": return "lower-alpha"
	case "A": return "upper-alpha"
	case "i": return "lower-roman"
	case "I": return "upper-roman"
	}
	return ""
}

@(private)
unordered_type :: proc(v: string) -> string {
	t := strings.trim_space(v)
	for k in ([?]string{"none", "disc", "circle", "square"}) { if strings.equal_fold(t, k) { return k } }
	return ""
}

////////////////////////////////
// Tables: border, frame and rules (HTML §15.3.8)

// The table a row, row group or cell belongs to (through rows and row groups), or nil.
@(private)
owning_table :: proc(doc: ^dom.Document, n: ^dom.Node) -> ^dom.Node {
	cur := n
	for _ in 0 ..< 3 {
		p := dom.get(doc, cur.parent)
		if p == nil || p.kind != .Element { return nil }
		switch p.name {
		case "table": return p
		case "tr", "thead", "tbody", "tfoot":
			cur = p
		case: return nil
		}
	}
	return nil
}

// The table's border attribute in px: 0 = none; an empty or unreadable value means 1 (what browsers do).
@(private)
table_border :: proc(table: ^dom.Node) -> (px: int, present: bool) {
	v, ok := attr(table, "border")
	if !ok { return 0, false }
	if b, bok := parse_nonneg_int(v); bok { return b, true }
	return 1, true
}

@(private)
table_border_hints :: proc(w: ^strings.Builder, n: ^dom.Node) {
	b, has_b := table_border(n)
	frame, has_frame := attr(n, "frame")
	_, has_rules := attr(n, "rules")
	if c, ok := attr(n, "bordercolor"); ok {
		if rgb, cok := parse_legacy_color(c); cok { fmt.sbprintf(w, "border-color:#%06x;", rgb) }
	} else if has_frame || has_rules {
		strings.write_string(w, "border-color:black;")
	}
	if has_rules { strings.write_string(w, "border-collapse:collapse;") }
	if has_frame {
		// which sides the frame draws (top right bottom left)
		sides: [4]bool
		switch {
		case strings.equal_fold(frame, "void"):
		case strings.equal_fold(frame, "above"): sides = {true, false, false, false}
		case strings.equal_fold(frame, "below"): sides = {false, false, true, false}
		case strings.equal_fold(frame, "hsides"): sides = {true, false, true, false}
		case strings.equal_fold(frame, "lhs"): sides = {false, false, false, true}
		case strings.equal_fold(frame, "rhs"): sides = {false, true, false, false}
		case strings.equal_fold(frame, "vsides"): sides = {false, true, false, true}
		case strings.equal_fold(frame, "box"), strings.equal_fold(frame, "border"): sides = {true, true, true, true}
		case: has_frame = false
		}
		if has_frame {
			width := has_b && b > 0 ? b : 1
			NAMES := [4]string{"top", "right", "bottom", "left"}
			for s, i in sides {
				if s { fmt.sbprintf(w, "border-%s:%dpx solid;", NAMES[i], width) } else { fmt.sbprintf(w, "border-%s-style:hidden;", NAMES[i]) }
			}
			return
		}
	}
	if has_b && b > 0 {
		fmt.sbprintf(w, "border-width:%dpx;border-style:outset;", b)
	} else if has_rules {
		strings.write_string(w, "border-style:hidden;")
	}
}

// Row groups and rows of a table with rules=groups / rules=rows.
@(private)
group_border_hints :: proc(w: ^strings.Builder, n: ^dom.Node, table: ^dom.Node) {
	rules, ok := attr(table, "rules")
	if !ok { return }
	if (strings.equal_fold(rules, "groups") && n.name != "tr") || (strings.equal_fold(rules, "rows") && n.name == "tr") {
		strings.write_string(w, "border-top:1px solid;border-bottom:1px solid;")
	}
}

// Cells of a table with a border (inset 1px) or rules.
@(private)
cell_border_hints :: proc(w: ^strings.Builder, table: ^dom.Node) {
	if rules, ok := attr(table, "rules"); ok {
		switch {
		case strings.equal_fold(rules, "none"), strings.equal_fold(rules, "groups"): strings.write_string(w, "border-width:1px;border-style:none;")
		case strings.equal_fold(rules, "rows"): strings.write_string(w, "border-width:1px;border-style:solid none;")
		case strings.equal_fold(rules, "cols"): strings.write_string(w, "border-width:1px;border-style:none solid;")
		case strings.equal_fold(rules, "all"): strings.write_string(w, "border-width:1px;border-style:solid;")
		case: return
		}
		strings.write_string(w, "border-color:inherit;")
		return
	}
	if b, has := table_border(table); has && b > 0 {
		strings.write_string(w, "border-width:1px;border-style:inset;border-color:inherit;")
	}
}

// The document's body element (the first body or frameset child of the root element), or nil.
@(private)
document_body :: proc(doc: ^dom.Document) -> ^dom.Node {
	root := dom.get(doc, doc.root)
	if root == nil { return nil }
	for ch := root.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next {
		html := dom.get(doc, ch)
		if html.kind != .Element || html.name != "html" { continue }
		for b := html.first_child; b != base.NIL_HANDLE; b = dom.get(doc, b).next {
			bn := dom.get(doc, b)
			if bn.kind == .Element && bn.name == "body" { return bn }
		}
		return nil
	}
	return nil
}
