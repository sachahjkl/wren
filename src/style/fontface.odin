package style

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "wb:css"

// @font-face (CSS Fonts 4 §4): the descriptors of every rule in force, parsed on each rebuild. Loading the files is the
// page's business (page/fonts.odin, through fetch with destination font and CORS); decoding them is package webfont's.

Font_Face_Ref :: struct {
	rule:     ^css.Rule,
	base_url: string,     // the sheet's URL: relative src URLs resolve against it
	origin:   Origin,
}

Font_Source_Kind :: enum u8 { Url, Local }
Font_Format :: enum u8 { Unspecified, Woff, Woff2, Truetype, Opentype, Collection, Embedded_Opentype, Svg, Other }

Font_Source :: struct {
	kind:      Font_Source_Kind,
	url:       string,          // Url: as written
	name:      string,          // Local: the full font name
	format:    Font_Format,     // Unspecified: the downloaded bytes say
	supported: bool,            // a format this browser can decode (TrueType/OpenType, WOFF, WOFF2, collections)
}

Font_Display :: enum u8 { Auto, Block, Swap, Fallback, Optional }

Font_Face :: struct {
	family:        string,
	sources:       []Font_Source,
	weight:        [2]u16,      // range, inclusive
	style:         Font_Style,
	oblique:       [2]f32,      // Oblique: angle range in degrees
	stretch:       [2]f32,      // percentages
	unicode_range: [][2]u32,    // inclusive ranges; empty = all of Unicode
	display:       Font_Display,
	base_url:      string,
	key:           string,      // the same face across rebuilds has the same key (the loader's cache key)
}

// The @font-face rules of the document, in cascade order (a later one wins for the same family and descriptors).
engine_font_faces :: proc(e: ^Engine) -> []Font_Face {
	return e.faces[:]
}

@(private)
parse_font_faces :: proc(e: ^Engine) {
	clear(&e.faces)
	for ref in e.font_faces {
		if f, ok := parse_font_face(e, ref); ok { append(&e.faces, f) }
	}
}

@(private)
FONT_STRETCH_KW := [?]struct { name: string, v: f32 }{
	{"normal", 100}, {"ultra-condensed", 50}, {"extra-condensed", 62.5}, {"condensed", 75}, {"semi-condensed", 87.5},
	{"semi-expanded", 112.5}, {"expanded", 125}, {"extra-expanded", 150}, {"ultra-expanded", 200},
}

parse_font_face :: proc(e: ^Engine, ref: Font_Face_Ref) -> (f: Font_Face, ok: bool) {
	a := e.alloc
	f.weight = {400, 400}
	f.stretch = {100, 100}
	f.base_url = strings.clone(ref.base_url, a)
	have_family, have_src := false, false
	for d in ref.rule.declarations {
		vs := css.trim_values(d.value)
		switch d.name {
		case "font-family":
			if fam, good := face_family(vs, a); good { f.family, have_family = fam, true }
		case "src":
			if srcs, good := face_sources(vs, a); good { f.sources, have_src = srcs, true }
		case "font-weight":
			if w, good := face_weight(vs); good { f.weight = w }
		case "font-style":
			items := split_items(vs)
			if len(items) == 0 { continue }
			switch ident_lower(items[0]) {
			case "auto", "normal": if len(items) == 1 { f.style = .Normal }
			case "italic": if len(items) == 1 { f.style = .Italic }
			case "oblique":
				f.style, f.oblique = .Oblique, {14, 14}
				if len(items) >= 2 {
					a0, g0 := parse_angle(items[1], true)
					if !g0 { continue }
					f.oblique = {a0 * 180 / math.PI, a0 * 180 / math.PI}
					if len(items) == 3 {
						if a1, g1 := parse_angle(items[2], true); g1 { f.oblique[1] = a1 * 180 / math.PI }
					}
				}
			}
		case "font-stretch", "font-width":
			items := split_items(vs)
			if len(items) == 0 || len(items) > 2 { continue }
			r: [2]f32
			good := true
			for it, i in items {
				v: f32
				found := false
				if tok_is(it, .Percentage) && it.tok.num >= 0 { v, found = f32(it.tok.num), true }
				for k in FONT_STRETCH_KW { if k.name == ident_lower(it) { v, found = k.v, true } }
				if ident_lower(it) == "auto" && len(items) == 1 { v, found = 100, true }
				if !found { good = false; break }
				r[i] = v
			}
			if !good { continue }
			if len(items) == 1 { r[1] = r[0] }
			f.stretch = {min(r[0], r[1]), max(r[0], r[1])}
		case "unicode-range":
			if ranges, good := parse_unicode_range(d.raw, a); good { f.unicode_range = ranges }
		case "font-display":
			o := css.trim_values(d.value)
			if dv, good := parse_enum(o, Font_Display); good { f.display = dv }
		}
	}
	if !have_family || !have_src { return {}, false }
	sb := strings.builder_make(a)
	fmt.sbprintf(&sb, "%s|%d-%d|%v|%g-%g", f.family, f.weight[0], f.weight[1], f.style, f.stretch[0], f.stretch[1])
	for s in f.sources { fmt.sbprintf(&sb, "|%s%s", s.url, s.name) }
	for r in f.unicode_range { fmt.sbprintf(&sb, "|%x-%x", r[0], r[1]) }
	f.key = strings.to_string(sb)
	return f, true
}

@(private)
face_family :: proc(vs: []css.Value, a := context.allocator) -> (string, bool) {
	if len(vs) == 1 && tok_is(vs[0], .String) { return strings.clone(vs[0].tok.text, a), vs[0].tok.text != "" }
	sb := strings.builder_make(a)
	for v in vs {
		if css.is_ws_value(v) { continue }
		if !tok_is(v, .Ident) { return "", false }
		if strings.builder_len(sb) > 0 { strings.write_byte(&sb, ' ') }
		strings.write_string(&sb, v.tok.text)
	}
	name := strings.to_string(sb)
	switch css.lower_temp(name) {
	case "", "serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui", "inherit", "initial", "default": return "", false
	}
	return name, true
}

face_format :: proc(name: string) -> Font_Format {
	switch css.lower_temp(name) {
	case "woff", "woff-variations": return .Woff
	case "woff2", "woff2-variations": return .Woff2
	case "truetype", "ttf", "truetype-variations": return .Truetype
	case "opentype", "otf", "opentype-variations": return .Opentype
	case "collection": return .Collection
	case "embedded-opentype": return .Embedded_Opentype
	case "svg": return .Svg
	}
	return .Other
}

@(private)
face_sources :: proc(vs: []css.Value, a := context.allocator) -> ([]Font_Source, bool) {
	out := make([dynamic]Font_Source, a)
	for part in css.split_commas(vs, context.temp_allocator) {
		items := split_items(part)
		if len(items) == 0 { continue }
		src: Font_Source
		head := items[0]
		switch {
		case tok_is(head, .Url): src = Font_Source{kind = .Url, url = strings.clone(head.tok.text, a)}
		case head.kind == .Function && strings.equal_fold(head.tok.text, "url"):
			for x in head.children { if tok_is(x, .String) { src = Font_Source{kind = .Url, url = strings.clone(x.tok.text, a)} } }
			if src.url == "" { continue }
		case head.kind == .Function && strings.equal_fold(head.tok.text, "local"):
			name, ok := face_family(css.trim_values(head.children), a)
			if !ok { continue }
			src = Font_Source{kind = .Local, name = name}
		case: continue   // an invalid source is skipped, the others stay (CSS Fonts 4 §4.3)
		}
		valid := true
		for it in items[1:] {
			if it.kind != .Function { valid = false; break }
			switch css.lower_temp(it.tok.text) {
			case "format":
				args := split_items(it.children)
				if len(args) != 1 { valid = false; break }
				name := tok_is(args[0], .String) ? args[0].tok.text : (tok_is(args[0], .Ident) ? args[0].tok.text : "")
				src.format = face_format(name)
			case "tech":
				for t in split_items(it.children) {
					if tok_is(t, .Comma) { continue }
					// color fonts, graphite...: a technology this browser does not render
					if !font_tech_supported(ident_lower(t)) { valid = false }
				}
			case: valid = false
			}
		}
		if !valid { continue }
		src.supported = font_format_supported(src.format)
		if src.kind == .Local { src.supported = true }
		append(&out, src)
	}
	if len(out) == 0 { return nil, false }
	return out[:], true
}

// Formats package webfont decodes (WOFF2 through the native library; a collection gives its first face).
font_format_supported :: proc(f: Font_Format) -> bool {
	switch f {
	case .Unspecified, .Woff, .Woff2, .Truetype, .Opentype, .Collection: return true
	case .Embedded_Opentype, .Svg, .Other: return false
	}
	return false
}

// Font technologies (CSS Fonts 4 §11.1, tech()) the font engine renders.
font_tech_supported :: proc(name: string) -> bool {
	switch css.lower_temp(name) {
	case "variations", "features-opentype", "features-aat", "palettes", "incremental": return true
	}
	return false
}

@(private)
face_weight :: proc(vs: []css.Value) -> ([2]u16, bool) {
	items := split_items(vs)
	if len(items) == 0 || len(items) > 2 { return {}, false }
	if len(items) == 1 && ident_lower(items[0]) == "auto" { return {1, 1000}, true }
	r: [2]u16
	for it, i in items {
		switch ident_lower(it) {
		case "normal": r[i] = 400
		case "bold": r[i] = 700
		case "":
			n, ok := number_of(it)
			if !ok || n < 1 || n > 1000 { return {}, false }
			r[i] = u16(n)
		case: return {}, false
		}
	}
	if len(items) == 1 { r[1] = r[0] }
	return {min(r[0], r[1]), max(r[0], r[1])}, true
}

// unicode-range from its source text: comma-separated U+hhhh, U+hhhh-hhhh, U+hh?? (CSS Fonts 4 §4.5, CSS Syntax 3 <urange>).
parse_unicode_range :: proc(raw: string, a := context.allocator) -> ([][2]u32, bool) {
	out := make([dynamic][2]u32, a)
	for part_raw in strings.split(raw, ",", context.temp_allocator) {
		part := strings.trim_space(part_raw)
		if len(part) < 3 || (part[0] != 'u' && part[0] != 'U') || part[1] != '+' { return nil, false }
		body := part[2:]
		dash := strings.index_byte(body, '-')
		if dash >= 0 {
			lo, ok1 := strconv.parse_u64_of_base(body[:dash], 16)
			hi, ok2 := strconv.parse_u64_of_base(body[dash + 1:], 16)
			if !ok1 || !ok2 || len(body[:dash]) > 6 || len(body[dash + 1:]) > 6 || lo > hi || hi > 0x10FFFF { return nil, false }
			append(&out, [2]u32{u32(lo), u32(hi)})
			continue
		}
		if len(body) == 0 || len(body) > 6 { return nil, false }
		q := strings.index_byte(body, '?')
		if q >= 0 {
			for k in q ..< len(body) { if body[k] != '?' { return nil, false } }
			prefix := body[:q]
			lo_s := strings.concatenate({prefix, strings.repeat("0", len(body) - q, context.temp_allocator)}, context.temp_allocator)
			hi_s := strings.concatenate({prefix, strings.repeat("F", len(body) - q, context.temp_allocator)}, context.temp_allocator)
			lo, ok1 := strconv.parse_u64_of_base(lo_s, 16)
			hi, ok2 := strconv.parse_u64_of_base(hi_s, 16)
			if !ok1 || !ok2 { return nil, false }
			append(&out, [2]u32{u32(lo), u32(min(hi, 0x10FFFF))})
			continue
		}
		v, ok := strconv.parse_u64_of_base(body, 16)
		if !ok || v > 0x10FFFF { return nil, false }
		append(&out, [2]u32{u32(v), u32(v)})
	}
	return out[:], true
}

// The face covers code point `r`.
face_covers :: proc(f: ^Font_Face, r: rune) -> bool {
	if len(f.unicode_range) == 0 { return true }
	for rg in f.unicode_range { if u32(r) >= rg[0] && u32(r) <= rg[1] { return true } }
	return false
}
