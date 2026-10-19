package css

import "core:strings"

// Media Queries Level 4: parsing and evaluation. The environment is supplied by the style system (viewport, color
// scheme and the user's preferences), so nothing here is hard-wired.

Media_Type :: enum u8 { All, Screen, Print, Other }

Media_Feature :: enum u8 {
	Unknown,
	Width, Height, Aspect_Ratio, Orientation, Resolution,
	Color, Monochrome,
	Prefers_Color_Scheme, Prefers_Reduced_Motion, Prefers_Contrast, Prefers_Reduced_Data,
	Hover, Any_Hover, Pointer, Any_Pointer,
	Display_Mode, Scripting, Update, Forced_Colors,
	Color_Gamut, Inverted_Colors, Dynamic_Range, Prefers_Reduced_Transparency, Grid, Overflow_Block, Overflow_Inline,
	Device_Width, Device_Height, Device_Aspect_Ratio,
	Inline_Size, Block_Size,   // container queries only (unknown in a media query)
}

Compare :: enum u8 { Equal, Less, Less_Eq, Greater, Greater_Eq }

// One condition: a feature compared with a value, or just present ("(color)").
Media_Condition :: struct {
	feature:  Media_Feature,
	boolean:  bool,          // (feature): true when the feature is "on" (non-zero / not none)
	compare:  Compare,
	value:    f64,           // numbers and lengths in CSS px, ratios as w/h, resolution in dppx
	ident:    string,        // keyword value (orientation: landscape)
	min_max:  i8,            // -1: min-feature, +1: max-feature, 0: plain
	// range syntax: lo <op> feature <op> hi
	has_range: bool,
	lo, hi:    f64,
	lo_cmp, hi_cmp: Compare,
	has_lo, has_hi: bool,
	// nested
	kind:     enum u8 { Feature, And, Or, Not },
	children: []Media_Condition,
	unknown:  bool,          // a feature we do not know: the query is false (and its negation is not true)
}

Media_Query :: struct {
	negated:   bool,
	type:      Media_Type,
	condition: Maybe(Media_Condition),
}

Media_Query_List :: []Media_Query

// What the document is rendered into.
Media_Env :: struct {
	type:                 Media_Type,
	width, height:        f64,     // viewport, CSS px
	dppx:                 f64,     // device pixels per CSS pixel
	prefers_dark:         bool,
	prefers_reduced_motion: bool,
	prefers_more_contrast: bool,
	prefers_reduced_data: bool,
	hover:                bool,    // the primary input can hover
	pointer_fine:         bool,
	color_bits:           int,
}

parse_media_query_list :: proc(list: []Value, a: Arena_Alloc) -> Media_Query_List {
	vs := trim_values(list)
	if len(vs) == 0 { return nil }   // an empty list is "all"
	out := make([dynamic]Media_Query, a)
	for item in split_commas(vs, a) {
		q, ok := parse_media_query(trim_values(item), a)
		if ok { append(&out, q) } else { append(&out, Media_Query{negated = true, type = .All}) }   // invalid: "not all"
	}
	return out[:]
}

@(private)
parse_media_query :: proc(vs: []Value, a: Arena_Alloc) -> (q: Media_Query, ok: bool) {
	if len(vs) == 0 { return {}, false }
	i := 0
	q.type = .All
	// [not|only]? type [and condition]? | condition
	if vs[0].kind == .Token && vs[0].tok.kind == .Ident {
		w := strings.to_lower(vs[0].tok.text, context.temp_allocator)
		if w == "not" || w == "only" {
			// `not` before a media type negates the query; before "(" it is a condition (three-valued) and is left to the condition parser
			j := 1
			for j < len(vs) && is_ws_value(vs[j]) { j += 1 }
			if j < len(vs) && vs[j].kind == .Token && vs[j].tok.kind == .Ident { q.negated = w == "not"; i = j }
		}
		if i < len(vs) && vs[i].kind == .Token && vs[i].tok.kind == .Ident && !(i == 0 && strings.equal_fold(vs[i].tok.text, "not")) {
			t := strings.to_lower(vs[i].tok.text, context.temp_allocator)
			switch t {
			case "all": q.type = .All
			case "screen": q.type = .Screen
			case "print": q.type = .Print
			case: q.type = .Other
			}
			i += 1
			for i < len(vs) && is_ws_value(vs[i]) { i += 1 }
			if i >= len(vs) { return q, true }
			if vs[i].kind == .Token && vs[i].tok.kind == .Ident && strings.equal_fold(vs[i].tok.text, "and") {
				i += 1
				for i < len(vs) && is_ws_value(vs[i]) { i += 1 }
				c, good := parse_media_condition(vs[i:], a)
				if !good { return {}, false }
				q.condition = c
				return q, true
			}
			return {}, false
		}
	}
	c, good := parse_media_condition(vs[i:], a)
	if !good { return {}, false }
	q.condition = c
	return q, true
}

// <media-condition>: (not <in-parens>) | <in-parens> [and <in-parens>]* | <in-parens> [or <in-parens>]*
@(private)
parse_media_condition :: proc(cond: []Value, a: Arena_Alloc) -> (c: Media_Condition, ok: bool) {
	vs := trim_values(cond)
	if len(vs) == 0 { return {}, false }
	if vs[0].kind == .Token && vs[0].tok.kind == .Ident && strings.equal_fold(vs[0].tok.text, "not") {
		inner, good := parse_media_in_parens(trim_values(vs[1:]), a)
		if !good { return {}, false }
		kids := make([]Media_Condition, 1, a)
		kids[0] = inner
		return Media_Condition{kind = .Not, children = kids}, true
	}
	kids := make([dynamic]Media_Condition, a)
	op := Media_Condition{kind = .And}
	i := 0
	for i < len(vs) {
		for i < len(vs) && is_ws_value(vs[i]) { i += 1 }
		if i >= len(vs) { break }
		// an in-parens group is one Block / Function value
		inner, good := parse_media_in_parens(vs[i:i + 1], a)
		if !good { return {}, false }
		append(&kids, inner)
		i += 1
		for i < len(vs) && is_ws_value(vs[i]) { i += 1 }
		if i < len(vs) {
			if vs[i].kind != .Token || vs[i].tok.kind != .Ident { return {}, false }
			w := strings.to_lower(vs[i].tok.text, context.temp_allocator)
			if w == "and" { op.kind = .And } else if w == "or" { op.kind = .Or } else { return {}, false }
			i += 1
		}
	}
	if len(kids) == 1 { return kids[0], true }
	op.children = kids[:]
	return op, true
}

@(private)
parse_media_in_parens :: proc(vs: []Value, a: Arena_Alloc) -> (c: Media_Condition, ok: bool) {
	if len(vs) != 1 { return {}, false }
	v := vs[0]
	if v.kind == .Function {
		return Media_Condition{unknown = true}, true   // <general-enclosed>: unknown, evaluates to unknown
	}
	if v.kind != .Block || v.tok.kind != .Open_Paren { return {}, false }
	inner := trim_values(v.children)
	if len(inner) == 0 { return {}, false }
	// a nested condition?
	if inner[0].kind == .Block || (inner[0].kind == .Token && inner[0].tok.kind == .Ident && strings.equal_fold(inner[0].tok.text, "not") && len(inner) > 1 && !has_colon(inner)) {
		if cond, good := parse_media_condition(inner, a); good { return cond, true }
	}
	return parse_media_feature(inner, a)
}

@(private)
has_colon :: proc(vs: []Value) -> bool {
	for v in vs { if v.kind == .Token && v.tok.kind == .Colon { return true } }
	return false
}

@(private)
feature_of :: proc(name: string) -> (Media_Feature, i8) {
	n := strings.to_lower(name, context.temp_allocator)
	mm: i8
	webkit := strings.has_prefix(n, "-webkit-")
	if webkit { n = n[8:] }
	switch {
	case strings.has_prefix(n, "min-"): mm, n = -1, n[4:]
	case strings.has_prefix(n, "max-"): mm, n = 1, n[4:]
	}
	if webkit {   // only -webkit-device-pixel-ratio is a feature (Blink, WebKit, Gecko): the resolution in dppx
		return n == "device-pixel-ratio" ? .Resolution : .Unknown, mm
	}
	f: Media_Feature
	switch n {
	case "width": f = .Width
	case "height": f = .Height
	case "aspect-ratio": f = .Aspect_Ratio
	case "orientation": f = .Orientation
	case "resolution": f = .Resolution
	case "color": f = .Color
	case "monochrome": f = .Monochrome
	case "prefers-color-scheme": f = .Prefers_Color_Scheme
	case "prefers-reduced-motion": f = .Prefers_Reduced_Motion
	case "prefers-contrast": f = .Prefers_Contrast
	case "prefers-reduced-data": f = .Prefers_Reduced_Data
	case "hover": f = .Hover
	case "any-hover": f = .Any_Hover
	case "pointer": f = .Pointer
	case "any-pointer": f = .Any_Pointer
	case "display-mode": f = .Display_Mode
	case "scripting": f = .Scripting
	case "update": f = .Update
	case "forced-colors": f = .Forced_Colors
	case "color-gamut": f = .Color_Gamut
	case "inverted-colors": f = .Inverted_Colors
	case "dynamic-range", "video-dynamic-range": f = .Dynamic_Range
	case "prefers-reduced-transparency": f = .Prefers_Reduced_Transparency
	case "grid": f = .Grid
	case "overflow-block": f = .Overflow_Block
	case "overflow-inline": f = .Overflow_Inline
	case "device-width": f = .Device_Width
	case "device-height": f = .Device_Height
	case "device-aspect-ratio": f = .Device_Aspect_Ratio
	case "inline-size": f = .Inline_Size
	case "block-size": f = .Block_Size
	case "color-index": f = .Monochrome   // no palette: 0, like monochrome
	}
	return f, mm
}

@(private)
media_number :: proc(v: Value) -> (f64, bool) {
	if v.kind == .Function {
		// calc() of plain numbers/lengths: evaluate with the value grammar helper
		if n, ok := eval_simple_calc(v); ok { return n, true }
		return 0, false
	}
	if v.kind != .Token { return 0, false }
	t := v.tok
	#partial switch t.kind {
	case .Number: return t.num, true
	case .Dimension:
		if px, ok := length_unit_to_px(t.num, t.text, 16); ok { return px, true }
		// relative units in a media query are relative to the initial font size (16px)
		switch strings.to_lower(t.text, context.temp_allocator) {
		case "em", "rem": return t.num * 16, true
		case "ex", "ch": return t.num * 8, true
		}
		switch strings.to_lower(t.text, context.temp_allocator) {
		case "dppx", "x": return t.num, true
		case "dpi": return t.num / 96, true
		case "dpcm": return t.num * 2.54 / 96, true
		}
	}
	return 0, false
}

@(private)
parse_media_feature :: proc(inner: []Value, a: Arena_Alloc) -> (c: Media_Condition, ok: bool) {
	c.kind = .Feature
	// (feature) | (feature: value) | range forms
	toks := make([dynamic]Value, context.temp_allocator)
	for v in inner { if !is_ws_value(v) { append(&toks, v) } }
	if len(toks) == 0 { return {}, false }

	if len(toks) == 1 && toks[0].kind == .Token && toks[0].tok.kind == .Ident {
		f, mm := feature_of(toks[0].tok.text)
		if f == .Unknown || mm != 0 { return Media_Condition{unknown = true}, true }
		c.feature, c.boolean = f, true
		return c, true
	}
	if len(toks) >= 3 && toks[0].kind == .Token && toks[0].tok.kind == .Ident && toks[1].kind == .Token && toks[1].tok.kind == .Colon {
		f, mm := feature_of(toks[0].tok.text)
		if f == .Unknown { return Media_Condition{unknown = true}, true }
		c.feature, c.min_max = f, mm
		val := toks[2]
		if val.kind == .Token && val.tok.kind == .Ident { c.ident = strings.to_lower(val.tok.text, a); return c, len(toks) == 3 }
		// ratio: 16 / 9
		if len(toks) == 5 && toks[3].kind == .Token && toks[3].tok.kind == .Delim && toks[3].tok.text == "/" {
			n1, g1 := media_number(toks[2]); n2, g2 := media_number(toks[4])
			if !g1 || !g2 || n2 == 0 { return {}, false }
			c.value = n1 / n2
			return c, true
		}
		if len(toks) != 3 { return {}, false }
		n, good := media_number(val)
		if !good { return {}, false }
		c.value = n
		return c, true
	}
	// range syntax: [value op] feature [op value]
	idx := -1
	for v, i in toks { if v.kind == .Token && v.tok.kind == .Ident { idx = i; break } }
	if idx < 0 { return {}, false }
	f, mm := feature_of(toks[idx].tok.text)
	if f == .Unknown || mm != 0 { return Media_Condition{unknown = true}, true }
	c.feature, c.has_range = f, true
	read_cmp :: proc(toks: []Value, i: int) -> (cmp: Compare, used: int, ok: bool) {
		if i >= len(toks) || toks[i].kind != .Token || toks[i].tok.kind != .Delim { return {}, 0, false }
		op := toks[i].tok.text
		eq := i + 1 < len(toks) && toks[i + 1].kind == .Token && toks[i + 1].tok.kind == .Delim && toks[i + 1].tok.text == "="
		switch {
		case op == "<" && eq: return .Less_Eq, 2, true
		case op == ">" && eq: return .Greater_Eq, 2, true
		case op == "<": return .Less, 1, true
		case op == ">": return .Greater, 1, true
		case op == "=": return .Equal, 1, true
		}
		return {}, 0, false
	}
	// the operator text on each side of the feature name, e.g. "<=" is two Delim tokens
	op_text :: proc(toks: []Value, from, to: int) -> string {
		sb := strings.builder_make(context.temp_allocator)
		for k in from ..< to { strings.write_string(&sb, toks[k].tok.text) }
		return strings.to_string(sb)
	}
	cmp_of :: proc(s: string) -> (Compare, bool) {
		switch s {
		case "<": return .Less, true
		case "<=": return .Less_Eq, true
		case ">": return .Greater, true
		case ">=": return .Greater_Eq, true
		case "=": return .Equal, true
		}
		return {}, false
	}
	is_delim :: proc(v: Value) -> bool { return v.kind == .Token && v.tok.kind == .Delim }
	if idx > 0 {   // value op feature
		j := idx - 1
		for j >= 0 && is_delim(toks[j]) { j -= 1 }
		if j != 0 { return {}, false }           // exactly one value before the operator
		cmp, good := cmp_of(op_text(toks[:], j + 1, idx))
		n, gn := media_number(toks[j])
		if !good || !gn { return {}, false }
		c.lo, c.has_lo, c.lo_cmp = n, true, cmp
	}
	if idx + 1 < len(toks) {   // feature op value
		k := idx + 1
		for k < len(toks) && is_delim(toks[k]) { k += 1 }
		if k != len(toks) - 1 { return {}, false }
		cmp, good := cmp_of(op_text(toks[:], idx + 1, k))
		n, gn := media_number(toks[k])
		if !good || !gn { return {}, false }
		c.hi, c.has_hi, c.hi_cmp = n, true, cmp
	}	return c, c.has_lo || c.has_hi
}

////////////////////////////////
// Evaluation. Three-valued logic: true, false, unknown (an unknown feature never matches, even negated).

Tri :: enum u8 { False, True, Unknown }

media_matches :: proc(list: Media_Query_List, env: Media_Env) -> bool {
	if len(list) == 0 { return true }
	for q in list { if query_matches(q, env) { return true } }
	return false
}

@(private)
query_matches :: proc(q: Media_Query, env: Media_Env) -> bool {
	type_ok := q.type == .All || q.type == env.type
	result := type_ok
	if result {
		if c, has := q.condition.?; has { result = eval(c, env) == .True }
	}
	return q.negated ? !result : result
}

@(private)
eval :: proc(c: Media_Condition, env: Media_Env) -> Tri {
	if c.unknown { return .Unknown }
	switch c.kind {
	case .Not:
		switch eval(c.children[0], env) { case .True: return .False; case .False: return .True; case .Unknown: return .Unknown }
	case .And:
		result := Tri.True
		for k in c.children {
			switch eval(k, env) { case .False: return .False; case .Unknown: result = .Unknown; case .True: }
		}
		return result
	case .Or:
		result := Tri.False
		for k in c.children {
			switch eval(k, env) { case .True: return .True; case .Unknown: result = .Unknown; case .False: }
		}
		return result
	case .Feature:
		return eval_feature(c, env)
	}
	return .Unknown
}

@(private)
compare :: proc(x: f64, cmp: Compare, y: f64) -> bool {
	switch cmp {
	case .Equal: return x == y
	case .Less: return x < y
	case .Less_Eq: return x <= y
	case .Greater: return x > y
	case .Greater_Eq: return x >= y
	}
	return false
}

@(private)
eval_feature :: proc(c: Media_Condition, env: Media_Env) -> Tri {
	numeric: f64
	is_num := false
	switch c.feature {
	case .Width: numeric, is_num = env.width, true
	case .Height: numeric, is_num = env.height, true
	case .Aspect_Ratio: numeric, is_num = env.height > 0 ? env.width / env.height : 0, true
	case .Resolution: numeric, is_num = env.dppx, true
	case .Color: numeric, is_num = f64(env.color_bits / 3), true
	case .Monochrome: numeric, is_num = 0, true
	case .Orientation:
		cur := env.width >= env.height ? "landscape" : "portrait"
		if c.boolean { return .True }
		return c.ident == cur ? .True : .False
	case .Prefers_Color_Scheme:
		cur := env.prefers_dark ? "dark" : "light"
		if c.boolean { return .True }
		return c.ident == cur ? .True : .False
	case .Prefers_Reduced_Motion:
		cur := env.prefers_reduced_motion ? "reduce" : "no-preference"
		if c.boolean { return env.prefers_reduced_motion ? .True : .False }
		return c.ident == cur ? .True : .False
	case .Prefers_Contrast:
		cur := env.prefers_more_contrast ? "more" : "no-preference"
		if c.boolean { return env.prefers_more_contrast ? .True : .False }
		return c.ident == cur ? .True : .False
	case .Prefers_Reduced_Data:
		cur := env.prefers_reduced_data ? "reduce" : "no-preference"
		if c.boolean { return env.prefers_reduced_data ? .True : .False }
		return c.ident == cur ? .True : .False
	case .Hover, .Any_Hover:
		cur := env.hover ? "hover" : "none"
		if c.boolean { return env.hover ? .True : .False }
		return c.ident == cur ? .True : .False
	case .Pointer, .Any_Pointer:
		cur := env.pointer_fine ? "fine" : "coarse"
		if c.boolean { return .True }
		return c.ident == cur ? .True : .False
	case .Display_Mode:
		return c.boolean || c.ident == "browser" ? .True : .False
	case .Scripting:
		return c.ident == "none" ? .True : .False      // there is no scripting engine
	case .Update:
		return c.ident == "fast" || c.boolean ? .True : .False
	case .Forced_Colors:
		if c.boolean { return .False }   // no forced colors mode: (forced-colors) is false
		return c.ident == "none" ? .True : .False
	// the surface is an sRGB, standard dynamic range, non-inverted, bitmap, scrolling screen
	case .Color_Gamut:
		if c.boolean { return .True }
		return c.ident == "srgb" ? .True : .False
	case .Inverted_Colors:
		if c.boolean { return .False }
		return c.ident == "none" ? .True : .False
	case .Dynamic_Range:
		if c.boolean { return .True }
		return c.ident == "standard" ? .True : .False
	case .Prefers_Reduced_Transparency:
		if c.boolean { return .False }
		return c.ident == "no-preference" ? .True : .False
	case .Overflow_Block, .Overflow_Inline:
		if c.boolean { return .True }
		return c.ident == "scroll" ? .True : .False
	case .Grid: numeric, is_num = 0, true
	case .Device_Width: numeric, is_num = env.width, true      // the screen is not reported: the viewport stands for it
	case .Device_Height: numeric, is_num = env.height, true
	case .Device_Aspect_Ratio: numeric, is_num = env.height > 0 ? env.width / env.height : 0, true
	case .Inline_Size, .Block_Size, .Unknown:
		return .Unknown
	}
	if !is_num { return .Unknown }
	if c.boolean { return numeric != 0 ? .True : .False }
	if c.has_range {
		ok := true
		if c.has_lo { ok = ok && compare(c.lo, c.lo_cmp, numeric) }
		if c.has_hi { ok = ok && compare(numeric, c.hi_cmp, c.hi) }
		return ok ? .True : .False
	}
	switch c.min_max {
	case -1: return numeric >= c.value ? .True : .False
	case 1:  return numeric <= c.value ? .True : .False
	}
	return numeric == c.value ? .True : .False
}
