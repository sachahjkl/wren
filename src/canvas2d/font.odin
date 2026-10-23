package canvas2d

import "core:strconv"
import "core:strings"

// A parsed `font` of the 2D context (the CSS font shorthand, HTML §4.12.5.1.10): what the text engine needs to pick a
// face. Strings are owned by the spec (`font_spec_destroy`).
Font_Spec :: struct {
	families:   []string,
	size:       f64,       // CSS pixels
	weight:     u16,
	italic:     bool,      // italic or oblique
	stretch:    f32,       // percentage, 100 = normal
	small_caps: bool,
	text:       string,    // the serialization the `font` getter returns
}

DEFAULT_FONT_TEXT :: "10px sans-serif"

font_spec_default :: proc() -> Font_Spec {
	f := Font_Spec{size = 10, weight = 400, stretch = 100}
	f.families = make([]string, 1)
	f.families[0] = strings.clone("sans-serif")
	f.text = strings.clone(DEFAULT_FONT_TEXT)
	return f
}

font_spec_destroy :: proc(f: ^Font_Spec) {
	for s in f.families { delete(s) }
	delete(f.families)
	delete(f.text)
	f^ = {}
}

font_spec_clone :: proc(f: ^Font_Spec) -> Font_Spec {
	r := f^
	r.families = make([]string, len(f.families))
	for s, i in f.families { r.families[i] = strings.clone(s) }
	r.text = strings.clone(f.text)
	return r
}

// Parses a CSS font shorthand: [style | variant | weight | stretch]* size[/line-height] family[, family]*. `base_size`
// is what em and percentages are relative to (the canvas element's font size; 10 when it has none). false: not a valid
// font (the API then leaves the font alone). System font keywords (menu, caption...) are not accepted: they would need
// the element's styles.
font_parse :: proc(input: string, base_size: f64) -> (f: Font_Spec, ok: bool) {
	s := strings.trim_space(input)
	if s == "" { return }
	toks := split_font(s)
	defer delete(toks)
	if len(toks) < 2 { return }
	f = Font_Spec{size = 10, weight = 400, stretch = 100}
	style_seen, variant_seen, weight_seen, stretch_seen := false, false, false, false
	i := 0
	for i < len(toks) {
		t := toks[i]
		lower := strings.to_lower(t, context.temp_allocator)
		switch {
		case lower == "normal":
			// stands for any of the four optional keywords: nothing to record
		case lower == "italic" || lower == "oblique":
			if style_seen { return }
			style_seen, f.italic = true, true
			// oblique may carry an angle
			if lower == "oblique" && i + 1 < len(toks) && is_angle(toks[i + 1]) { i += 1 }
		case lower == "small-caps":
			if variant_seen { return }
			variant_seen, f.small_caps = true, true
		case is_weight(lower) || is_weight_number(lower):
			if weight_seen { return }
			weight_seen = true
			f.weight = weight_of(lower)
		case stretch_of(lower) > 0:
			if stretch_seen { return }
			stretch_seen = true
			f.stretch = stretch_of(lower)
		case:
			// the size (with an optional /line-height), then the families
			size_tok := t
			if slash := strings.index_byte(t, '/'); slash >= 0 { size_tok = t[:slash] }
			size, size_ok := font_size_of(size_tok, base_size)
			if !size_ok { return }
			f.size = size
			// the line-height is ignored: "16px/1.5" in one token, "16px/ 1.5", "16px /1.5" or "16px / 1.5"
			rest_start := i + 1
			if slash := strings.index_byte(t, '/'); slash >= 0 {
				if slash == len(t) - 1 { rest_start += 1 }
			} else if rest_start < len(toks) && toks[rest_start][0] == '/' {
				rest_start += toks[rest_start] == "/" ? 2 : 1
			}
			if rest_start >= len(toks) { return }
			fams, fok := parse_families(toks[rest_start:])
			if !fok { return }
			f.families = fams
			f.text = serialize_font(&f)
			return f, true
		}
		i += 1
	}
	return
}

@(private)
split_font :: proc(s: string) -> [dynamic]string {
	out := make([dynamic]string)
	i := 0
	for i < len(s) {
		for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r' || s[i] == '\f') { i += 1 }
		if i >= len(s) { break }
		start := i
		if s[i] == '"' || s[i] == '\'' {
			q := s[i]
			i += 1
			for i < len(s) && s[i] != q { if s[i] == '\\' { i += 1 }; i += 1 }
			i = min(i + 1, len(s))
			// a quoted family may be followed by "," glued on
			if i < len(s) && s[i] == ',' { i += 1 }
		} else {
			for i < len(s) && !(s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r' || s[i] == '\f') { i += 1 }
		}
		append(&out, s[start:i])
	}
	return out
}

@(private)
is_weight :: proc(s: string) -> bool { return s == "bold" || s == "bolder" || s == "lighter" }

@(private)
is_weight_number :: proc(s: string) -> bool {
	v, ok := strconv.parse_f64(s)
	return ok && v >= 1 && v <= 1000 && !strings.contains_any(s, "eE")
}

@(private)
weight_of :: proc(s: string) -> u16 {
	switch s {
	case "bold": return 700
	case "bolder": return 700   // relative to the parent (normal): 700
	case "lighter": return 100
	}
	v, _ := strconv.parse_f64(s)
	return u16(clamp(v, 1, 1000))
}

@(private)
stretch_of :: proc(s: string) -> f32 {
	switch s {
	case "ultra-condensed": return 50
	case "extra-condensed": return 62.5
	case "condensed": return 75
	case "semi-condensed": return 87.5
	case "semi-expanded": return 112.5
	case "expanded": return 125
	case "extra-expanded": return 150
	case "ultra-expanded": return 200
	}
	return 0
}

@(private)
is_angle :: proc(s: string) -> bool {
	for u in ([]string{"deg", "grad", "rad", "turn"}) {
		if strings.has_suffix(s, u) {
			_, ok := strconv.parse_f64(s[:len(s) - len(u)])
			return ok
		}
	}
	return false
}

@(private)
parse_number_unit :: proc(s: string) -> (v: f64, unit: string, ok: bool) {
	end := 0
	for end < len(s) {
		c := s[end]
		if (c >= '0' && c <= '9') || c == '.' || ((c == '-' || c == '+') && end == 0) { end += 1 } else if (c == 'e' || c == 'E') && end > 0 && end + 1 < len(s) && ((s[end + 1] >= '0' && s[end + 1] <= '9') || s[end + 1] == '-' || s[end + 1] == '+') {
			end += 2
		} else { break }
	}
	if end == 0 { return }
	v, ok = strconv.parse_f64(s[:end])
	return v, s[end:], ok
}

@(private)
font_size_of :: proc(s: string, base: f64) -> (px: f64, ok: bool) {
	lower := strings.to_lower(s, context.temp_allocator)
	switch lower {
	case "xx-small": return 9, true
	case "x-small": return 10, true
	case "small": return 13, true
	case "medium": return 16, true
	case "large": return 18, true
	case "x-large": return 24, true
	case "xx-large": return 32, true
	case "xxx-large": return 48, true
	case "smaller": return base / 1.2, true
	case "larger": return base * 1.2, true
	}
	v, unit, vok := parse_number_unit(lower)
	if !vok || v < 0 { return }
	switch unit {
	case "px": return v, true
	case "pt": return v * 4 / 3, true
	case "pc": return v * 16, true
	case "in": return v * 96, true
	case "cm": return v * 96 / 2.54, true
	case "mm": return v * 96 / 25.4, true
	case "q": return v * 96 / 101.6, true
	case "em": return v * base, true
	case "rem": return v * 16, true
	case "ex": return v * base * 0.5, true
	case "ch": return v * base * 0.5, true
	case "%": return v * base / 100, true
	case "vw", "vh": return 0, false
	}
	return
}

@(private)
parse_families :: proc(toks: []string) -> (out: []string, ok: bool) {
	if len(toks) == 0 { return }
	list := make([dynamic]string)
	cur := strings.builder_make(context.temp_allocator)
	flush :: proc(list: ^[dynamic]string, cur: ^strings.Builder) -> bool {
		s := strings.to_string(cur^)
		if s == "" { return false }
		append(list, strings.clone(s))
		strings.builder_reset(cur)
		return true
	}
	fail :: proc(list: ^[dynamic]string) {
		for s in list { delete(s) }
		delete(list^)
	}
	for t in toks {
		// a token may hold several families ("a,b"), a quoted name, or a word of a multi-word name
		i := 0
		for i < len(t) {
			c := t[i]
			switch {
			case c == ',':
				if !flush(&list, &cur) { fail(&list); return }
				i += 1
			case c == '"' || c == '\'':
				if strings.builder_len(cur) > 0 { fail(&list); return }
				j := i + 1
				for j < len(t) && t[j] != c { if t[j] == '\\' && j + 1 < len(t) { j += 1 }; strings.write_byte(&cur, t[j]); j += 1 }
				if j >= len(t) { fail(&list); return }   // unterminated
				if strings.builder_len(cur) == 0 { fail(&list); return }
				i = j + 1
			case:
				j := i
				for j < len(t) && t[j] != ',' && t[j] != '"' && t[j] != '\'' { j += 1 }
				if strings.builder_len(cur) > 0 { strings.write_byte(&cur, ' ') }
				strings.write_string(&cur, t[i:j])
				i = j
			}
		}
		// a space between two words of an unquoted name is written when the next word comes
	}
	if !flush(&list, &cur) { fail(&list); return }
	return list[:], true
}

@(private)
serialize_font :: proc(f: ^Font_Spec) -> string {
	b := strings.builder_make()
	if f.italic { strings.write_string(&b, "italic ") }
	if f.small_caps { strings.write_string(&b, "small-caps ") }
	if f.weight != 400 { strings.write_int(&b, int(f.weight)); strings.write_byte(&b, ' ') }
	if f.stretch != 100 {
		names := [?]string{"ultra-condensed", "extra-condensed", "condensed", "semi-condensed", "", "semi-expanded", "expanded", "extra-expanded", "ultra-expanded"}
		vals := [?]f32{50, 62.5, 75, 87.5, 100, 112.5, 125, 150, 200}
		for v, i in vals { if v == f.stretch && names[i] != "" { strings.write_string(&b, names[i]); strings.write_byte(&b, ' ') } }
	}
	buf: [32]u8
	strings.write_string(&b, strings.trim_prefix(strconv.write_float(buf[:], f.size, 'f', -1, 64), "+"))
	strings.write_string(&b, "px ")
	for fam, i in f.families {
		if i > 0 { strings.write_string(&b, ", ") }
		generic := fam == "serif" || fam == "sans-serif" || fam == "monospace" || fam == "cursive" || fam == "fantasy" || fam == "system-ui"
		simple := !strings.contains_any(fam, " \"',")
		if generic || simple { strings.write_string(&b, fam) } else {
			strings.write_byte(&b, '"')
			strings.write_string(&b, fam)
			strings.write_byte(&b, '"')
		}
	}
	return strings.to_string(b)
}
