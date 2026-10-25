package style

import "core:math"
import "core:strings"
import "wb:css"

// Computing the properties added after the first style engine: positions, background layers, gradients, generated
// content, effects and the rest of `apply_prop_more`. Transforms, easing, animation lists and grid have their own files.

////////////////////////////////
// Small value readers

@(private)
tok_is :: #force_inline proc(v: css.Value, k: css.Token_Kind) -> bool { return v.kind == .Token && v.tok.kind == k }

@(private)
ident_lower :: proc(v: css.Value) -> string {
	if v.kind == .Token && v.tok.kind == .Ident { return css.lower_temp(v.tok.text) }
	return ""
}

@(private)
single :: #force_inline proc(v: css.Value) -> [1]css.Value { return [1]css.Value{v} }

// <time> in milliseconds (also calc() of times).
parse_time :: proc(v: css.Value, allow_negative := true) -> (f32, bool) {
	ms: f64
	#partial switch v.kind {
	case .Token:
		if v.tok.kind != .Dimension { return 0, false }
		ok: bool
		ms, ok = css.time_unit_to_ms(v.tok.num, v.tok.text)
		if !ok { return 0, false }
	case .Function:
		tree := css.parse_calc(v, context.temp_allocator)
		if tree == nil || !calc_only_unit(tree, .Ms) { return 0, false }
		ms = css.eval_calc(tree, {})
	case: return 0, false
	}
	if ms < 0 && !allow_negative { return 0, false }
	if math.is_nan(ms) || math.is_inf(ms) { return 0, false }
	return f32(ms), true
}

// <angle> in radians. A plain 0 is accepted where `allow_zero` (transform functions, gradients).
parse_angle :: proc(v: css.Value, allow_zero := true) -> (f32, bool) {
	deg: f64
	#partial switch v.kind {
	case .Token:
		#partial switch v.tok.kind {
		case .Dimension:
			ok: bool
			deg, ok = css.angle_unit_to_deg(v.tok.num, v.tok.text)
			if !ok { return 0, false }
		case .Number:
			if !allow_zero || v.tok.num != 0 { return 0, false }
		case: return 0, false
		}
	case .Function:
		tree := css.parse_calc(v, context.temp_allocator)
		if tree == nil || !calc_only_unit(tree, .Deg) { return 0, false }
		deg = css.eval_calc(tree, {})
	case: return 0, false
	}
	if math.is_nan(deg) || math.is_inf(deg) { return 0, false }
	return f32(deg * math.PI / 180), true
}

// Every dimension leaf of the tree has unit `u` (numbers are allowed as factors).
@(private)
calc_only_unit :: proc(n: ^css.Calc, u: css.Unit) -> bool {
	if n == nil { return true }
	if n.op == .Dimension && n.unit != u { return false }
	return calc_only_unit(n.a, u) && calc_only_unit(n.b, u) && calc_only_unit(n.c, u)
}

@(private)
number_of :: proc(v: css.Value) -> (f64, bool) {
	o := single(v)
	return css.parse_number(o[:])
}

// A number or a percentage as a factor (50% = 0.5).
@(private)
factor_of :: proc(v: css.Value) -> (f32, bool) {
	if tok_is(v, .Percentage) { return f32(v.tok.num / 100), true }
	n, ok := number_of(v)
	return f32(n), ok
}

@(private)
length_of :: proc(cx: ^Cx, v: css.Value, flags: Len_Flags) -> (Length, bool) {
	o := single(v)
	return parse_length(cx, o[:], flags)
}

// A Length as a calc() leaf or tree (allocated in `a`).
length_to_calc :: proc(l: Length, a := context.allocator) -> ^css.Calc {
	if l.kind == .Calc && l.calc != nil { return l.calc }
	n := new(css.Calc, a)
	switch l.kind {
	case .Percent: n^ = css.Calc{op = .Dimension, num = f64(l.v), unit = .Percent}
	case .Px, .Calc, .Auto, .None, .Normal, .Min_Content, .Max_Content, .Fit_Content: n^ = css.Calc{op = .Dimension, num = f64(l.v), unit = .Px}
	}
	return n
}

// 100% - l: an offset from the far edge.
@(private)
from_far_edge :: proc(cx: ^Cx, l: Length) -> Length {
	if l.kind == .Percent { return Length{kind = .Percent, v = 100 - l.v} }
	hundred := new(css.Calc, cx.alloc)
	hundred^ = css.Calc{op = .Dimension, num = 100, unit = .Percent}
	n := new(css.Calc, cx.alloc)
	n^ = css.Calc{op = .Sub, a = hundred, b = length_to_calc(l, cx.alloc)}
	return Length{kind = .Calc, calc = n}
}

////////////////////////////////
// <position> (CSS Values 4 / Backgrounds 3: one to four values)

@(private)
pct :: #force_inline proc(v: f32) -> Length { return Length{kind = .Percent, v = v} }

parse_position :: proc(cx: ^Cx, input: []css.Value) -> (pos: [2]Length, ok: bool) {
	items := split_items(input)
	if len(items) < 1 || len(items) > 4 { return {}, false }
	Axis :: enum { X, Y, Either }
	kw :: proc(v: css.Value) -> (val: f32, axis: Axis, far: bool, is_kw: bool) {
		switch ident_lower(v) {
		case "left": return 0, .X, false, true
		case "right": return 100, .X, true, true
		case "top": return 0, .Y, false, true
		case "bottom": return 100, .Y, true, true
		case "center": return 50, .Either, false, true
		}
		return 0, .Either, false, false
	}
	if len(items) <= 2 {
		vals: [2]Length
		axes: [2]Axis
		for it, i in items {
			if v, ax, _, is := kw(it); is {
				vals[i], axes[i] = pct(v), ax
			} else {
				l, good := length_of(cx, it, {.Percent, .Negative})
				if !good { return {}, false }
				vals[i], axes[i] = l, .Either
				if len(items) == 2 { axes[i] = i == 0 ? .X : .Y }   // a length fixes the axis by its place
			}
		}
		if len(items) == 1 {
			if axes[0] == .Y { return {pct(50), vals[0]}, true }
			return {vals[0], pct(50)}, true
		}
		swap := axes[0] == .Y || axes[1] == .X
		if swap {
			if axes[0] == .X || axes[1] == .Y { return {}, false }
			return {vals[1], vals[0]}, true
		}
		return {vals[0], vals[1]}, true
	}
	// three or four values: keyword [offset] groups
	Group :: struct { axis: Axis, base: f32, far: bool, off: Length, has_off: bool }
	groups: [2]Group
	n := 0
	i := 0
	for i < len(items) {
		v, ax, far, is := kw(items[i])
		if !is || n >= 2 { return {}, false }
		g := Group{axis = ax, base = v, far = far}
		i += 1
		if i < len(items) {
			if _, _, _, next_kw := kw(items[i]); !next_kw {
				if ax == .Either { return {}, false }   // center takes no offset
				l, good := length_of(cx, items[i], {.Percent, .Negative})
				if !good { return {}, false }
				g.off, g.has_off = l, true
				i += 1
			}
		}
		groups[n] = g
		n += 1
	}
	if n != 2 { return {}, false }
	if groups[0].axis == groups[1].axis && groups[0].axis != .Either { return {}, false }
	if groups[0].axis == .Y || groups[1].axis == .X { groups[0], groups[1] = groups[1], groups[0] }
	for g, k in groups {
		if !g.has_off { pos[k] = pct(g.base); continue }
		pos[k] = g.far ? from_far_edge(cx, g.off) : g.off
	}
	return pos, true
}

////////////////////////////////
// Background layers

parse_bg_repeat :: proc(input: []css.Value) -> ([2]Repeat, bool) {
	items := split_items(input)
	if len(items) == 1 {
		switch ident_lower(items[0]) {
		case "repeat-x": return {.Repeat, .No_Repeat}, true
		case "repeat-y": return {.No_Repeat, .Repeat}, true
		}
	}
	if len(items) < 1 || len(items) > 2 { return {}, false }
	r: [2]Repeat
	for it, i in items {
		o := single(it)
		if !set_enum(o[:], &r[i]) { return {}, false }
		if r[i] == .Repeat_X || r[i] == .Repeat_Y { return {}, false }
	}
	if len(items) == 1 { r[1] = r[0] }
	return r, true
}

parse_bg_size :: proc(cx: ^Cx, input: []css.Value) -> (Bg_Size, bool) {
	items := split_items(input)
	if len(items) < 1 || len(items) > 2 { return {}, false }
	if len(items) == 1 {
		switch ident_lower(items[0]) {
		case "cover": return Bg_Size{kind = .Cover}, true
		case "contain": return Bg_Size{kind = .Contain}, true
		case "auto": return Bg_Size{}, true
		}
	}
	w, ok := length_of(cx, items[0], {.Auto, .Percent})
	if !ok { return {}, false }
	h := auto_length
	if len(items) == 2 {
		h, ok = length_of(cx, items[1], {.Auto, .Percent})
		if !ok { return {}, false }
	}
	return Bg_Size{kind = .Length, w = w, h = h}, true
}

@(private)
parse_box_list :: proc(cx: ^Cx, vs: []css.Value, allow_text: bool) -> ([]Box_Area, bool) {
	parts := css.split_commas(css.trim_values(vs), context.temp_allocator)
	out := make([]Box_Area, len(parts), cx.alloc)
	for part, i in parts {
		b, ok := parse_enum(part, Box_Area)
		if !ok || (b == .Text && !allow_text) { return nil, false }
		out[i] = b
	}
	return out, true
}

// Every background layer of `c`, with the repetition rules of CSS Backgrounds 3 §2 applied: the number of layers is the
// number of images; shorter lists repeat, longer ones are cut. Layer 0 is on top.
background_layers :: proc(c: ^Computed, allocator := context.temp_allocator) -> []Bg_Layer {
	n := max(len(c.background_images), 1)
	out := make([]Bg_Layer, n, allocator)
	pick :: proc(list: []$T, i: int, fallback: T) -> T { return len(list) == 0 ? fallback : list[i % len(list)] }
	for i in 0 ..< n {
		out[i] = Bg_Layer{
			image = pick(c.background_images, i, Image{}),
			repeat = pick(c.background_repeats, i, [2]Repeat{.Repeat, .Repeat}),
			position = pick(c.background_positions, i, [2]Length{pct(0), pct(0)}),
			size = pick(c.background_sizes, i, Bg_Size{}),
			origin = pick(c.background_origins, i, Box_Area.Padding_Box),
			clip = pick(c.background_clips, i, Box_Area.Border_Box),
			attachment = pick(c.background_attachments, i, Bg_Attachment.Scroll),
		}
	}
	return out
}

////////////////////////////////
// Images and gradients

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
	if v.kind != .Function { return {}, false }
	name := css.lower_temp(v.tok.text)
	switch name {
	case "url", "src":
		for a in v.children { if tok_is(a, .String) { return Image{kind = .Url, url = strings.clone(a.tok.text, cx.alloc)}, true } }
	case "image", "image-set", "-webkit-image-set":
		// the first usable image: url, string or gradient (resolution selection is the loader's business)
		for part in css.split_commas(v.children, context.temp_allocator) {
			items := split_items(part)
			if len(items) == 0 { continue }
			if tok_is(items[0], .String) { return Image{kind = .Url, url = strings.clone(items[0].tok.text, cx.alloc)}, true }
			o := single(items[0])
			if img, ok := parse_image(cx, o[:]); ok && img.kind != .None { return img, true }
		}
	case:
		if g, ok := parse_gradient(cx, v); ok {
			return Image{kind = .Gradient, gradient = css.serialize_values(vs, cx.alloc), grad = g}, true
		}
	}
	return {}, false
}

@(private)
parse_color_space :: proc(items: []css.Value, i: ^int, hue: ^Hue_Method = nil) -> (Color_Space, bool) {
	// `in <space> [<hue-method> hue]?`
	if i^ >= len(items) || ident_lower(items[i^]) != "in" { return .Default, true }
	i^ += 1
	if i^ >= len(items) { return .Default, false }
	o := single(items[i^])
	sp, ok := parse_enum(o[:], Color_Space)
	if !ok || sp == .Default {
		switch ident_lower(items[i^]) {
		case "xyz-d50", "xyz-d65": sp, ok = .Xyz, true
		case "display-p3", "a98-rgb", "prophoto-rgb", "rec2020": sp, ok = .Srgb, true
		case: return .Default, false
		}
	}
	i^ += 1
	if i^ + 1 < len(items) && ident_lower(items[i^ + 1]) == "hue" {
		m: Hue_Method
		known := true
		switch ident_lower(items[i^]) {
		case "shorter": m = .Shorter
		case "longer": m = .Longer
		case "increasing": m = .Increasing
		case "decreasing": m = .Decreasing
		case: known = false
		}
		if known {
			i^ += 2
			if hue != nil { hue^ = m }
		}
	}
	return sp, true
}

@(private)
parse_gradient :: proc(cx: ^Cx, f: css.Value) -> (^Gradient, bool) {
	name := css.lower_temp(f.tok.text)
	legacy := false
	if strings.has_prefix(name, "-webkit-") || strings.has_prefix(name, "-moz-") || strings.has_prefix(name, "-o-") {
		name = name[strings.index_byte(name[1:], '-') + 2:]
		legacy = true
	}
	g := new(Gradient, cx.alloc)
	if strings.has_prefix(name, "repeating-") { g.repeating = true; name = name[len("repeating-"):] }
	switch name {
	case "linear-gradient": g.kind = .Linear
	case "radial-gradient": g.kind = .Radial
	case "conic-gradient": g.kind = .Conic
	case: return nil, false
	}
	g.angle = g.kind == .Linear ? math.PI : 0   // default: to bottom
	g.position = {pct(50), pct(50)}
	parts := css.split_commas(f.children, context.temp_allocator)
	if len(parts) == 0 { return nil, false }
	first := 0
	if is_head, ok := parse_gradient_head(cx, g, split_items(parts[0]), legacy); !ok {
		return nil, false
	} else if is_head {
		first = 1
	}
	stops := make([dynamic]Color_Stop, cx.alloc)
	angular := g.kind == .Conic
	for part in parts[first:] {
		items := split_items(part)
		if len(items) == 0 || len(items) > 3 { return nil, false }
		col: css.Color
		have_col := false
		positions := make([dynamic]Length, context.temp_allocator)
		for it in items {
			if p, ok := stop_position(cx, it, angular); ok { append(&positions, p); continue }
			o := single(it)
			c, ok := parse_color(cx, o[:])
			if !ok || have_col { return nil, false }
			col, have_col = c, true
		}
		if !have_col {
			// a color hint: one position, between two color stops
			if len(positions) != 1 || len(stops) == 0 || stops[len(stops) - 1].hint { return nil, false }
			append(&stops, Color_Stop{pos = positions[0], hint = true})
			continue
		}
		if len(positions) > 2 { return nil, false }
		if len(positions) == 0 { append(&stops, Color_Stop{color = col, pos = auto_length}) }
		for p in positions { append(&stops, Color_Stop{color = col, pos = p}) }
	}
	if len(stops) == 0 || stops[len(stops) - 1].hint { return nil, false }
	if len(stops) == 1 { append(&stops, stops[0]) }   // one stop paints a solid color
	g.stops = stops[:]
	return g, true
}

@(private)
stop_position :: proc(cx: ^Cx, v: css.Value, angular: bool) -> (Length, bool) {
	if angular {
		if a, ok := parse_angle(v, true); ok && !tok_is(v, .Percentage) { return pct(a / (2 * math.PI) * 100), true }
		if tok_is(v, .Percentage) { return pct(f32(v.tok.num)), true }
		return {}, false
	}
	if v.kind == .Token && v.tok.kind == .Ident { return {}, false }
	if v.kind == .Function {
		// calc() is a position; any other function (rgb()...) is a color
		switch css.lower_temp(v.tok.text) {
		case "calc", "min", "max", "clamp", "-webkit-calc": 
		case: return {}, false
		}
	}
	return length_of(cx, v, {.Percent, .Negative})
}

// The part before the first comma, when it is not a color stop (is_head = false: it is the first stop).
@(private)
parse_gradient_head :: proc(cx: ^Cx, g: ^Gradient, items: []css.Value, legacy: bool) -> (is_head: bool, ok: bool) {
	if len(items) == 0 { return false, false }
	i := 0
	switch g.kind {
	case .Linear:
		if !tok_is(items[0], .Number) {
			if a, good := parse_angle(items[0], false); good {
				g.angle = legacy ? math.PI / 2 - a : a   // prefixed syntax: 0deg points right, counter-clockwise
				i = 1
			}
		}
		if i == 0 && (ident_lower(items[0]) == "to" || (legacy && side_of(items[0]) != {})) {
			if !legacy { i = 1 }
			x, y: i8
			for i < len(items) {
				s := side_of(items[i])
				if s == {} { break }
				if s.x != 0 { if x != 0 { return false, false }; x = s.x }
				if s.y != 0 { if y != 0 { return false, false }; y = s.y }
				i += 1
			}
			if x == 0 && y == 0 { return false, false }
			if legacy { x, y = -x, -y }   // -webkit-linear-gradient(top, ...) starts at the top
			if x != 0 && y != 0 {
				g.to_corner, g.corner = true, {x, y}
				g.angle = gradient_angle(g, 1, 1)
			} else {
				switch {
				case y < 0: g.angle = 0
				case x > 0: g.angle = math.PI / 2
				case y > 0: g.angle = math.PI
				case: g.angle = 3 * math.PI / 2
				}
			}
		}
	case .Radial:
		shape_given, extent_given := false, false
		lens := 0
		scan: for i < len(items) {
			id := ident_lower(items[i])
			switch id {
			case "circle", "ellipse":
				if shape_given { return false, false }
				g.shape, shape_given = id == "circle" ? .Circle : .Ellipse, true
			case "closest-side", "contain": g.extent, extent_given = .Closest_Side, true
			case "closest-corner": g.extent, extent_given = .Closest_Corner, true
			case "farthest-side": g.extent, extent_given = .Farthest_Side, true
			case "farthest-corner", "cover": g.extent, extent_given = .Farthest_Corner, true
			case "":
				l, good := length_of(cx, items[i], {.Percent})
				if !good { break scan }
				if lens >= 2 { return false, false }
				g.radius[lens] = l
				lens += 1
			case: break scan
			}
			i += 1
		}
		if lens > 0 {
			if extent_given { return false, false }
			g.extent = .Explicit
			if lens == 1 {
				if (shape_given && g.shape == .Ellipse) || g.radius[0].kind == .Percent { return false, false }
				g.shape = .Circle
			} else {
				if shape_given && g.shape == .Circle { return false, false }
				g.shape = .Ellipse
			}
		}
	case .Conic:
		if ident_lower(items[0]) == "from" {
			if len(items) < 2 { return false, false }
			a, good := parse_angle(items[1], true)
			if !good { return false, false }
			g.angle = a
			i = 2
		}
	}
	if i < len(items) && ident_lower(items[i]) == "at" && g.kind != .Linear {
		j := i + 1
		k := j
		for k < len(items) && ident_lower(items[k]) != "in" { k += 1 }
		pos, good := parse_position(cx, items[j:k])
		if !good { return false, false }
		g.position = pos
		i = k
	}
	sp, good := parse_color_space(items, &i, &g.hue)
	if !good { return false, false }
	g.space = sp
	if i == 0 { return false, true }   // nothing recognised: the first part is a color stop
	if i != len(items) { return false, false }
	return true, true
}

@(private)
Side_Dir :: struct { x, y: i8 }

@(private)
side_of :: proc(v: css.Value) -> Side_Dir {
	switch ident_lower(v) {
	case "left": return {-1, 0}
	case "right": return {1, 0}
	case "top": return {0, -1}
	case "bottom": return {0, 1}
	}
	return {}
}

// The direction of a linear gradient for a box of w x h, in radians (CSS Images 3 §3.1: a corner is reached by the
// angle that makes the 50% line pass through the two other corners).
gradient_angle :: proc(g: ^Gradient, w, h: f32) -> f32 {
	if g == nil || !g.to_corner { return g != nil ? g.angle : 0 }
	a := math.atan2(w, h)   // angle of the box diagonal from vertical
	x, y := g.corner.x, g.corner.y
	switch {
	case x > 0 && y < 0: return math.PI / 2 - a
	case x > 0 && y > 0: return math.PI / 2 + a
	case x < 0 && y > 0: return 3 * math.PI / 2 - a
	}
	return 3 * math.PI / 2 + a
}

// The length of the gradient line of a linear gradient at `angle` in a w x h box.
gradient_line_length :: proc(angle, w, h: f32) -> f32 {
	return abs(w * math.sin(angle)) + abs(h * math.cos(angle))
}

Resolved_Stop :: struct {
	color: css.Color,
	pos:   f32,     // px along the gradient line (or ray)
	hint:  bool,
}

// Stop positions in px along a gradient line of `line` px, with the fix-up of CSS Images 3 §3.5.3: missing first/last
// positions are 0% / 100%, a position smaller than an earlier one is raised to it, runs of missing positions are spread
// evenly. Hints stay as positions between their neighbours.
gradient_stops :: proc(g: ^Gradient, line: f32, allocator := context.temp_allocator) -> []Resolved_Stop {
	if g == nil { return nil }
	out := make([]Resolved_Stop, len(g.stops), allocator)
	known := make([]bool, len(g.stops), context.temp_allocator)
	for s, i in g.stops {
		out[i] = Resolved_Stop{color = s.color, hint = s.hint}
		if s.pos.kind != .Auto { out[i].pos = resolve(s.pos, line); known[i] = true }
	}
	n := len(out)
	if n == 0 { return out }
	if !known[0] { out[0].pos = 0; known[0] = true }
	if !known[n - 1] { out[n - 1].pos = line; known[n - 1] = true }
	highest := out[0].pos
	for i in 0 ..< n {
		if !known[i] { continue }
		if out[i].pos < highest { out[i].pos = highest }
		highest = out[i].pos
	}
	i := 0
	for i < n {
		if known[i] { i += 1; continue }
		j := i
		for !known[j] { j += 1 }
		a, b := out[i - 1].pos, out[j].pos
		for k in i ..< j { out[k].pos = a + (b - a) * f32(k - i + 1) / f32(j - i + 1) }
		i = j
	}
	return out
}

////////////////////////////////
// Generated content

parse_content :: proc(cx: ^Cx, input: []css.Value) -> (Content, bool) {
	vs := css.trim_values(input)
	if id, ok := ident_raw(vs); ok {
		switch css.lower_temp(id) {
		case "normal": return Content{kind = .Normal}, true
		case "none": return Content{kind = .None}, true
		}
	}
	parts := make([dynamic]Content_Part, cx.alloc)
	for it in split_items(vs) {
		switch it.kind {
		case .Token:
			#partial switch it.tok.kind {
			case .String: append(&parts, Content_Part{kind = .Text, text = strings.clone(it.tok.text, cx.alloc)})
			case .Url: append(&parts, Content_Part{kind = .Url, text = strings.clone(it.tok.text, cx.alloc)})
			case .Ident:
				switch css.lower_temp(it.tok.text) {
				case "open-quote": append(&parts, Content_Part{kind = .Open_Quote})
				case "close-quote": append(&parts, Content_Part{kind = .Close_Quote})
				case "no-open-quote": append(&parts, Content_Part{kind = .No_Open_Quote})
				case "no-close-quote": append(&parts, Content_Part{kind = .No_Close_Quote})
				case: return {}, false
				}
			case .Delim:
				if it.tok.text == "/" { return finish_content(parts) }   // alternative text follows: not displayed
				return {}, false
			case: return {}, false
			}
		case .Function:
			args := css.split_commas(it.children, context.temp_allocator)
			switch css.lower_temp(it.tok.text) {
			case "attr":
				if len(args) < 1 { return {}, false }
				head := split_items(args[0])
				if len(head) < 1 || !tok_is(head[0], .Ident) { return {}, false }
				part := Content_Part{kind = .Attr, text = strings.to_lower(head[0].tok.text, cx.alloc)}
				if len(args) > 1 {
					fb := split_items(args[1])
					if len(fb) == 1 && tok_is(fb[0], .String) { part.sep = strings.clone(fb[0].tok.text, cx.alloc) }
				}
				append(&parts, part)
			case "counter":
				if len(args) < 1 || len(args) > 2 { return {}, false }
				name := split_items(args[0])
				if len(name) != 1 || !tok_is(name[0], .Ident) { return {}, false }
				part := Content_Part{kind = .Counter, text = strings.clone(name[0].tok.text, cx.alloc), style = {style = .Decimal}}
				if len(args) == 2 {
					st, ok := parse_list_marker_style(cx, args[1])
					if !ok { return {}, false }
					part.style = st
				}
				append(&parts, part)
			case "counters":
				if len(args) < 2 || len(args) > 3 { return {}, false }
				name := split_items(args[0])
				sep := split_items(args[1])
				if len(name) != 1 || !tok_is(name[0], .Ident) || len(sep) != 1 || !tok_is(sep[0], .String) { return {}, false }
				part := Content_Part{kind = .Counters, text = strings.clone(name[0].tok.text, cx.alloc), sep = strings.clone(sep[0].tok.text, cx.alloc), style = {style = .Decimal}}
				if len(args) == 3 {
					st, ok := parse_list_marker_style(cx, args[2])
					if !ok { return {}, false }
					part.style = st
				}
				append(&parts, part)
			case "url":
				for a in it.children { if tok_is(a, .String) { append(&parts, Content_Part{kind = .Url, text = strings.clone(a.tok.text, cx.alloc)}); break } }
			case: return {}, false
			}
		case .Block: return {}, false
		}
	}
	return finish_content(parts)
}

@(private)
finish_content :: proc(parts: [dynamic]Content_Part) -> (Content, bool) {
	if len(parts) == 0 { return Content{kind = .None}, true }
	return Content{kind = .Items, parts = parts[:]}, true
}

parse_list_marker_style :: proc(cx: ^Cx, input: []css.Value) -> (List_Marker_Style, bool) {
	vs := css.trim_values(input)
	if len(vs) != 1 { return {}, false }
	v := vs[0]
	if tok_is(v, .String) { return List_Marker_Style{style = .String, text = strings.clone(v.tok.text, cx.alloc)}, true }
	if v.kind == .Function && strings.equal_fold(v.tok.text, "symbols") { return List_Marker_Style{style = .Decimal}, true }
	if !tok_is(v, .Ident) { return {}, false }
	id := css.lower_temp(v.tok.text)
	switch id {
	case "lower-latin": return {style = .Lower_Alpha}, true
	case "upper-latin": return {style = .Upper_Alpha}, true
	case "armenian": return {style = .Upper_Armenian}, true
	case "cjk-ideographic": return {style = .Trad_Chinese_Informal}, true
	case "inherit", "initial", "unset", "default", "revert", "revert-layer": return {}, false
	case "string": return {}, false
	}
	o := single(v)
	if st, ok := parse_enum(o[:], Counter_Style); ok && st != .String { return {style = st}, true }
	// a name no predefined style has: a @counter-style this engine does not implement; CSS says such a name falls back
	// to decimal
	return {style = .Decimal}, true
}

// The legacy `list_style_type` value nearest to a counter style.
legacy_list_style :: proc(s: Counter_Style) -> List_Style_Type {
	#partial switch s {
	case .None: return .None
	case .Disc, .Disclosure_Open, .Disclosure_Closed, .String: return .Disc
	case .Circle: return .Circle
	case .Square: return .Square
	case .Decimal_Leading_Zero: return .Decimal_Leading_Zero
	case .Lower_Roman: return .Lower_Roman
	case .Upper_Roman: return .Upper_Roman
	case .Lower_Greek: return .Lower_Greek
	case .Lower_Alpha: return .Lower_Alpha
	case .Upper_Alpha: return .Upper_Alpha
	}
	return .Decimal
}

@(private)
parse_counter_ops :: proc(cx: ^Cx, vs: []css.Value, default_value: i32, allow_reversed: bool) -> ([]Counter_Op, bool) {
	items := split_items(css.trim_values(vs))
	if len(items) == 1 && ident_lower(items[0]) == "none" { return nil, true }
	out := make([dynamic]Counter_Op, cx.alloc)
	i := 0
	for i < len(items) {
		it := items[i]
		op: Counter_Op
		if it.kind == .Function && strings.equal_fold(it.tok.text, "reversed") && allow_reversed {
			inner := split_items(it.children)
			if len(inner) != 1 || !tok_is(inner[0], .Ident) { return nil, false }
			op.name, op.reversed = strings.clone(inner[0].tok.text, cx.alloc), true
		} else if tok_is(it, .Ident) {
			switch ident_lower(it) { case "none", "initial", "inherit", "unset", "default": return nil, false }
			op.name = strings.clone(it.tok.text, cx.alloc)
		} else { return nil, false }
		i += 1
		op.value = default_value
		if i < len(items) && tok_is(items[i], .Number) {
			if !items[i].tok.is_int { return nil, false }
			op.value = i32(clamp(items[i].tok.num, -2_000_000_000, 2_000_000_000))
			op.has_value = true
			i += 1
		}
		append(&out, op)
		// a hostile list of thousands of names, on every element, made every counter operation scan them all
		if len(out) > cx.settings.counters_max_ops { return nil, false }
	}
	if len(out) == 0 { return nil, false }
	return out[:], true
}

////////////////////////////////
// Effects

@(private)
parse_filters :: proc(cx: ^Cx, vs: []css.Value) -> ([]Filter_Op, bool) {
	items := split_items(css.trim_values(vs))
	if len(items) == 1 && ident_lower(items[0]) == "none" { return nil, true }
	out := make([dynamic]Filter_Op, cx.alloc)
	for it in items {
		if tok_is(it, .Url) { append(&out, Filter_Op{kind = .Url, url = strings.clone(it.tok.text, cx.alloc)}); continue }
		if it.kind != .Function { return nil, false }
		name := css.lower_temp(it.tok.text)
		args := split_items(it.children)
		op: Filter_Op
		switch name {
		case "url":
			if len(args) != 1 || !tok_is(args[0], .String) { return nil, false }
			op = Filter_Op{kind = .Url, url = strings.clone(args[0].tok.text, cx.alloc)}
		case "blur":
			op.kind = .Blur
			if len(args) > 1 { return nil, false }
			if len(args) == 1 {
				l, ok := length_of(cx, args[0], {})
				if !ok || l.kind != .Px { return nil, false }
				op.v = l.v
			}
		case "hue-rotate":
			op.kind = .Hue_Rotate
			if len(args) > 1 { return nil, false }
			if len(args) == 1 {
				a, ok := parse_angle(args[0], true)
				if !ok { return nil, false }
				op.v = a
			}
		case "drop-shadow":
			op.kind = .Drop_Shadow
			sh, ok := parse_shadows(cx, it.children)
			if !ok || len(sh) != 1 || sh[0].inset { return nil, false }
			op.shadow = sh[0]
		case "brightness", "contrast", "grayscale", "invert", "opacity", "saturate", "sepia":
			switch name {
			case "brightness": op.kind = .Brightness
			case "contrast": op.kind = .Contrast
			case "grayscale": op.kind = .Grayscale
			case "invert": op.kind = .Invert
			case "opacity": op.kind = .Opacity
			case "saturate": op.kind = .Saturate
			case "sepia": op.kind = .Sepia
			}
			op.v = 1
			if len(args) > 1 { return nil, false }
			if len(args) == 1 {
				f, ok := factor_of(args[0])
				if !ok || f < 0 { return nil, false }
				op.v = f
			}
			#partial switch op.kind {
			case .Grayscale, .Invert, .Opacity, .Sepia: op.v = min(op.v, 1)
			}
		case: return nil, false
		}
		append(&out, op)
		// a hostile list of thousands of names, on every element, made every counter operation scan them all
		if len(out) > cx.settings.counters_max_ops { return nil, false }
	}
	if len(out) == 0 { return nil, false }
	return out[:], true
}

@(private)
parse_clip_path :: proc(cx: ^Cx, vs: []css.Value) -> (Clip_Path, bool) {
	items := split_items(css.trim_values(vs))
	if len(items) == 1 && ident_lower(items[0]) == "none" { return Clip_Path{}, true }
	if len(items) == 1 && tok_is(items[0], .Url) { return Clip_Path{kind = .Url, url = strings.clone(items[0].tok.text, cx.alloc)}, true }
	cp: Clip_Path
	have_box, have_shape := false, false
	for it in items {
		if tok_is(it, .Ident) {
			o := single(it)
			b, ok := parse_enum(o[:], Geometry_Box)
			if !ok || have_box { return {}, false }
			cp.box, have_box = b, true
			continue
		}
		if it.kind != .Function || have_shape { return {}, false }
		have_shape = true
		args := split_items(it.children)
		switch css.lower_temp(it.tok.text) {
		case "url":
			if len(args) != 1 || !tok_is(args[0], .String) { return {}, false }
			return Clip_Path{kind = .Url, url = strings.clone(args[0].tok.text, cx.alloc)}, true
		case "inset":
			cp.kind = .Inset
			round := -1
			for a, k in args { if ident_lower(a) == "round" { round = k; break } }
			lens := round >= 0 ? args[:round] : args
			if len(lens) < 1 || len(lens) > 4 { return {}, false }
			vals: [4]Length
			for a, k in lens {
				l, ok := length_of(cx, a, {.Percent, .Negative})
				if !ok { return {}, false }
				vals[k] = l
			}
			switch len(lens) {
			case 1: vals[1], vals[2], vals[3] = vals[0], vals[0], vals[0]
			case 2: vals[2], vals[3] = vals[0], vals[1]
			case 3: vals[3] = vals[1]
			}
			cp.inset = {.Top = vals[0], .Right = vals[1], .Bottom = vals[2], .Left = vals[3]}
			if round >= 0 {
				rad := args[round + 1:]
				if len(rad) < 1 || len(rad) > 4 { return {}, false }
				r: [4]Length   // one to four radii, like border-radius without the slash
				for a, k in rad {
					l, ok := length_of(cx, a, {.Percent})
					if !ok { return {}, false }
					r[k] = l
				}
				switch len(rad) {
				case 1: r[1], r[2], r[3] = r[0], r[0], r[0]
				case 2: r[2], r[3] = r[0], r[1]
				case 3: r[3] = r[1]
				}
				for corner in Corner { cp.round[corner] = {r[int(corner)], r[int(corner)]} }
			}
		case "circle", "ellipse":
			is_circle := strings.equal_fold(it.tok.text, "circle")
			cp.kind = is_circle ? .Circle : .Ellipse
			cp.center = {pct(50), pct(50)}
			at := len(args)
			for a, k in args { if ident_lower(a) == "at" { at = k; break } }
			radii := args[:at]
			if len(radii) > (is_circle ? 1 : 2) { return {}, false }
			for a, k in radii {
				switch ident_lower(a) {
				case "closest-side": cp.extent[k] = .Closest_Side
				case "farthest-side": cp.extent[k] = .Farthest_Side
				case:
					l, ok := length_of(cx, a, {.Percent})
					if !ok { return {}, false }
					cp.radius[k], cp.extent[k] = l, .Explicit
				}
			}
			if len(radii) == 0 { cp.extent = {.Closest_Side, .Closest_Side} }
			if !is_circle && len(radii) == 1 { return {}, false }
			if at < len(args) {
				pos, ok := parse_position(cx, args[at + 1:])
				if !ok { return {}, false }
				cp.center = pos
			}
		case "polygon":
			cp.kind = .Polygon
			parts := css.split_commas(it.children, context.temp_allocator)
			pts := make([dynamic][2]Length, cx.alloc)
			for part, k in parts {
				xy := split_items(part)
				if k == 0 && len(xy) == 1 {
					switch ident_lower(xy[0]) {
					case "evenodd": cp.evenodd = true; continue
					case "nonzero": continue
					}
				}
				if len(xy) != 2 { return {}, false }
				x, ok1 := length_of(cx, xy[0], {.Percent, .Negative})
				y, ok2 := length_of(cx, xy[1], {.Percent, .Negative})
				if !ok1 || !ok2 { return {}, false }
				append(&pts, [2]Length{x, y})
			}
			if len(pts) < 1 { return {}, false }
			cp.points = pts[:]
		case: return {}, false
		}
	}
	if !have_shape && have_box { cp.kind = .Box }
	return cp, true
}

////////////////////////////////
// The longhands added after the first engine

@(private)
FONT_STRETCH := [?]struct { name: string, v: f32 }{
	{"normal", 100}, {"ultra-condensed", 50}, {"extra-condensed", 62.5}, {"condensed", 75}, {"semi-condensed", 87.5},
	{"semi-expanded", 112.5}, {"expanded", 125}, {"extra-expanded", 150}, {"ultra-expanded", 200},
}

@(private)
parse_auto_color :: proc(cx: ^Cx, vs: []css.Value) -> (Auto_Color, bool) {
	if id, ok := ident_raw(vs); ok && strings.equal_fold(id, "auto") { return Auto_Color{auto = true}, true }
	col, ok := parse_color(cx, vs)
	return Auto_Color{color = col}, ok
}

@(private)
parse_align :: proc(vs: []css.Value) -> (Content_Align, bool) {
	a: Content_Align
	if id, ok := ident_raw(vs); ok {
		switch css.lower_temp(id) {
		case "legacy": return .Normal, true   // justify-items: legacy is `normal` outside the legacy block layout
		case "left", "self-start", "start": return .Start, true
		case "right", "self-end", "end": return .End, true
		case "anchor-center": return .Center, true
		}
		if set_enum(vs, &a) { return a, true }
		return {}, false
	}
	items := split_items(vs)   // `first baseline`, `safe center`, `legacy left`
	if len(items) != 2 || items[1].kind != .Token { return {}, false }
	switch ident_lower(items[1]) {
	case "left", "start", "self-start": return .Start, true
	case "right", "end", "self-end": return .End, true
	}
	o := single(items[1])
	if !set_enum(o[:], &a) { return {}, false }
	return a, true
}

// Computes one of the properties listed in apply_prop's last case.
apply_prop_more :: proc(cx: ^Cx, p: Prop, vs: []css.Value) -> bool {
	c := cx.c
	#partial switch p {
	case .Font_Stretch:
		if id, ok := ident_raw(vs); ok {
			lid := css.lower_temp(id)
			for k in FONT_STRETCH { if k.name == lid { c.font_stretch = k.v; return true } }
			return false
		}
		items := css.trim_values(vs)
		if len(items) != 1 || !tok_is(items[0], .Percentage) || items[0].tok.num < 0 { return false }
		c.font_stretch = f32(items[0].tok.num)
	case .Font_Variant_Caps: return set_enum(vs, &c.font_variant_caps)
	case .Text_Decoration_Style: return set_enum(vs, &c.text_decoration_style)
	case .Text_Decoration_Thickness, .Text_Underline_Offset:
		dst := p == .Text_Decoration_Thickness ? &c.text_decoration_thickness : &c.text_underline_offset
		if id, ok := ident_raw(vs); ok {
			switch css.lower_temp(id) {
			case "auto": dst^ = auto_length; return true
			case "from-font": if p == .Text_Decoration_Thickness { dst^ = Length{kind = .Normal}; return true }
			}
			return false
		}
		flags := Len_Flags{.Percent}
		if p == .Text_Underline_Offset { flags += {.Negative} }
		l, ok := parse_length(cx, vs, flags)
		if !ok { return false }
		dst^ = px(resolve(l, c.font_size))   // a percentage of 1em
	case .White_Space_Collapse: return set_enum(vs, &c.white_space_collapse)
	case .Text_Wrap_Mode: return set_enum(vs, &c.text_wrap_mode)
	case .Text_Wrap_Style: return set_enum(vs, &c.text_wrap_style)
	case .Hyphens: return set_enum(vs, &c.hyphens)
	case .Background_Origin:
		l, ok := parse_box_list(cx, vs, false)
		if !ok { return false }
		c.background_origins = l
	case .Background_Clip:
		// `text` only where the painter clips backgrounds to glyphs: a page that tests @supports (background-clip: text)
		// then keeps its readable fallback
		l, ok := parse_box_list(cx, vs, cx.settings.background_clip_text)
		if !ok { return false }
		c.background_clips = l
	case .Background_Attachment:
		parts := css.split_commas(css.trim_values(vs), context.temp_allocator)
		out := make([]Bg_Attachment, len(parts), cx.alloc)
		for part, i in parts { if !set_enum(part, &out[i]) { return false } }
		c.background_attachments = out
	case .Transform:
		ops, ok := parse_transform_list(cx, vs)
		if !ok { return false }
		c.transform = ops
	case .Transform_Origin:
		o, oz, ok := parse_transform_origin(cx, vs)
		if !ok { return false }
		c.transform_origin = o
		c.transform_origin_z = oz
	case .Perspective_Origin, .Object_Position:
		pos, ok := parse_position(cx, vs)
		if !ok { return false }
		if p == .Perspective_Origin { c.perspective_origin = pos } else { c.object_position = pos }
	case .Transform_Box: return set_enum(vs, &c.transform_box)
	case .Transform_Style: return set_enum(vs, &c.transform_style)
	case .Backface_Visibility: return set_enum(vs, &c.backface_visibility)
	case .Translate:
		t, ok := parse_translate(cx, vs)
		if !ok { return false }
		c.translate = t
	case .Rotate:
		r, ok := parse_rotate(vs)
		if !ok { return false }
		c.rotate = r
	case .Scale:
		s, ok := parse_scale(vs)
		if !ok { return false }
		c.scale = s
	case .Perspective:
		if id, ok := ident_raw(vs); ok && strings.equal_fold(id, "none") { c.perspective = 0; return true }
		l, ok := parse_length(cx, vs, {})
		if !ok || l.kind != .Px { return false }
		c.perspective = l.v
	case .Transition_Property, .Transition_Duration, .Transition_Timing_Function, .Transition_Delay, .Transition_Behavior,
	     .Animation_Name, .Animation_Duration, .Animation_Timing_Function, .Animation_Delay, .Animation_Iteration_Count,
	     .Animation_Direction, .Animation_Fill_Mode, .Animation_Play_State, .Animation_Composition:
		return apply_animation_list(cx, p, vs)
	case .Counter_Reset, .Counter_Increment, .Counter_Set:
		def := i32(p == .Counter_Increment ? 1 : 0)
		ops, ok := parse_counter_ops(cx, vs, def, p == .Counter_Reset)
		if !ok { return false }
		#partial switch p {
		case .Counter_Reset: c.counter_reset = ops
		case .Counter_Increment: c.counter_increment = ops
		case: c.counter_set = ops
		}
	case .Quotes:
		if id, ok := ident_raw(vs); ok {
			switch css.lower_temp(id) {
			case "none": c.quotes = Quotes{kind = .None}; return true
			case "auto": c.quotes = Quotes{kind = .Auto}; return true
			case "match-parent":
				c.quotes = cx.parent != nil ? cx.parent.quotes : Quotes{}
				return true
			}
			return false
		}
		items := split_items(css.trim_values(vs))
		if len(items) == 0 || len(items) % 2 != 0 { return false }
		pairs := make([][2]string, len(items) / 2, cx.alloc)
		for it, i in items {
			if !tok_is(it, .String) { return false }
			pairs[i / 2][i % 2] = strings.clone(it.tok.text, cx.alloc)
		}
		c.quotes = Quotes{kind = .List, pairs = pairs}
	case .Filter, .Backdrop_Filter:
		f, ok := parse_filters(cx, vs)
		if !ok { return false }
		if p == .Filter { c.filter = f } else { c.backdrop_filter = f }
	case .Clip_Path:
		cp, ok := parse_clip_path(cx, vs)
		if !ok { return false }
		if cp.kind == .None { c.clip_path = nil; return true }
		c.clip_path = new_clone(cp, cx.alloc)
	case .Isolation: return set_enum(vs, &c.isolation)
	case .Mix_Blend_Mode: return set_enum(vs, &c.mix_blend_mode)
	case .Will_Change:
		if id, ok := ident_raw(vs); ok && strings.equal_fold(id, "auto") { c.will_change = nil; return true }
		parts := css.split_commas(css.trim_values(vs), context.temp_allocator)
		out := make([]string, len(parts), cx.alloc)
		for part, i in parts {
			id, ok := ident_raw(part)
			if !ok { return false }
			lid := css.lower_temp(id)
			switch lid { case "auto", "will-change", "none", "all", "initial", "inherit", "unset", "default": return false }
			out[i] = strings.clone(lid, cx.alloc)
		}
		c.will_change = out
	case .Contain:
		items := split_items(css.trim_values(vs))
		set: Contain
		for it in items {
			switch ident_lower(it) {
			case "none": if len(items) != 1 { return false }
			case "strict": if len(items) != 1 { return false }; set = {.Size, .Layout, .Style, .Paint}
			case "content": if len(items) != 1 { return false }; set = {.Layout, .Style, .Paint}
			case "size": set += {.Size}
			case "inline-size": set += {.Inline_Size}
			case "layout": set += {.Layout}
			case "style": set += {.Style}
			case "paint": set += {.Paint}
			case: return false
			}
		}
		if .Size in set && .Inline_Size in set { return false }
		c.contain = set
	case .Touch_Action:
		items := split_items(css.trim_values(vs))
		if len(items) == 0 { return false }
		ALL :: Touch_Blocked{.Pan_Left, .Pan_Right, .Pan_Up, .Pan_Down, .Pinch_Zoom, .Double_Tap}
		// [pan-x | pan-left | pan-right] || [pan-y | pan-up | pan-down] || pinch-zoom: one of each group at most
		allowed: Touch_Blocked
		has_x, has_y, has_pinch: bool
		for it in items {
			id := ident_lower(it)
			switch id {
			case "auto": if len(items) != 1 { return false }; c.touch_action = {}; return true
			case "none": if len(items) != 1 { return false }; c.touch_action = ALL; return true
			case "manipulation": if len(items) != 1 { return false }; c.touch_action = {.Double_Tap}; return true
			case "pan-x", "pan-left", "pan-right":
				if has_x { return false }
				has_x = true
				allowed += id == "pan-x" ? Touch_Blocked{.Pan_Left, .Pan_Right} : (id == "pan-left" ? Touch_Blocked{.Pan_Left} : Touch_Blocked{.Pan_Right})
			case "pan-y", "pan-up", "pan-down":
				if has_y { return false }
				has_y = true
				allowed += id == "pan-y" ? Touch_Blocked{.Pan_Up, .Pan_Down} : (id == "pan-up" ? Touch_Blocked{.Pan_Up} : Touch_Blocked{.Pan_Down})
			case "pinch-zoom":
				if has_pinch { return false }
				has_pinch = true
				allowed += {.Pinch_Zoom}
			case: return false
			}
		}
		c.touch_action = ALL - allowed
	case .Content_Visibility: return set_enum(vs, &c.content_visibility)
	case .Scroll_Behavior: return set_enum(vs, &c.scroll_behavior)
	case .Overscroll_Behavior_X: return set_enum(vs, &c.overscroll_x)
	case .Overscroll_Behavior_Y: return set_enum(vs, &c.overscroll_y)
	case .Caret_Color, .Accent_Color:
		ac, ok := parse_auto_color(cx, vs)
		if !ok { return false }
		if p == .Caret_Color { c.caret_color = ac } else { c.accent_color = ac }
	case .Appearance:
		id, ok := ident_raw(vs)
		if !ok { return false }
		switch css.lower_temp(id) {
		case "button", "checkbox", "radio", "textarea", "searchfield", "menulist", "listbox", "meter", "progress-bar",
		     "push-button", "slider-horizontal", "square-button", "media-slider", "caret":
			c.appearance = .Auto
			return true
		}
		return set_enum(vs, &c.appearance)
	case .Resize: return set_enum(vs, &c.resize)
	case .Column_Count:
		if id, ok := ident_raw(vs); ok && strings.equal_fold(id, "auto") { c.column_count = 0; return true }
		n, ok := css.parse_integer(vs)
		if !ok || n < 1 { return false }
		c.column_count = i32(min(n, 100_000))
	case .Column_Width:
		l, ok := parse_length(cx, vs, {.Auto})
		if !ok || (l.kind != .Px && l.kind != .Auto) { return false }
		c.column_width = l
	case .Grid_Template_Columns, .Grid_Template_Rows:
		tpl, ok := parse_grid_template(cx, vs)
		if !ok { return false }
		if p == .Grid_Template_Columns { c.grid_template_columns = tpl } else { c.grid_template_rows = tpl }
	case .Grid_Template_Areas:
		ar, ok := parse_grid_areas(cx, vs)
		if !ok { return false }
		c.grid_template_areas = ar
	case .Grid_Auto_Columns, .Grid_Auto_Rows:
		tr, ok := parse_grid_auto_tracks(cx, vs)
		if !ok { return false }
		if p == .Grid_Auto_Columns { c.grid_auto_columns = tr } else { c.grid_auto_rows = tr }
	case .Grid_Auto_Flow:
		items := split_items(css.trim_values(vs))
		if len(items) < 1 || len(items) > 2 { return false }
		f: Grid_Auto_Flow
		seen_dir := false
		for it in items {
			switch ident_lower(it) {
			case "row": if seen_dir { return false }; seen_dir = true
			case "column": if seen_dir { return false }; seen_dir = true; f.column = true
			case "dense": if f.dense { return false }; f.dense = true
			case: return false
			}
		}
		c.grid_auto_flow = f
	case .Grid_Row_Start, .Grid_Row_End, .Grid_Column_Start, .Grid_Column_End:
		gl, ok := parse_grid_line(cx, vs)
		if !ok { return false }
		#partial switch p {
		case .Grid_Row_Start: c.grid_row_start = gl
		case .Grid_Row_End: c.grid_row_end = gl
		case .Grid_Column_Start: c.grid_column_start = gl
		case: c.grid_column_end = gl
		}
	case .Justify_Items, .Justify_Self:
		a, ok := parse_align(vs)
		if !ok { return false }
		if p == .Justify_Items { c.justify_items = a } else { c.justify_self = a }
	case: return false
	}
	return true
}
