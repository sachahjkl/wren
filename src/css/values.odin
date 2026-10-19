package css

import "core:fmt"
import "core:math"
import "core:strings"

// CSS Values and Units, Color Level 4 (the commonly used parts, complete for what pages use): numbers, lengths,
// percentages, calc() and friends, and every color syntax: named, hex, rgb(), hsl(), hwb(), lab(), lch(), oklab(),
// oklch(), color(), color-mix(), light-dark(), currentcolor and system colors.

Color :: [4]f32   // sRGB, components 0..1, alpha last

Color_Kind :: enum u8 { Rgba, Current_Color }

Color_Value :: struct {
	kind: Color_Kind,
	rgba: Color,
}

// What color parsing needs from the style system. `dark` is the used color scheme of the element the value is for (CSS
// Color Adjust 1): it picks the branch of light-dark() and the set of system colors.
Color_Env :: struct {
	dark:   bool,
	system: proc(user: rawptr, name: string, dark: bool) -> (Color, bool),   // CanvasText, LinkText... (`name` lowercase)
	user:   rawptr,
}

////////////////////////////////
// Colors

NAMED_COLORS := [?]struct { name: string, rgb: u32 }{
	{"aliceblue", 0xf0f8ff}, {"antiquewhite", 0xfaebd7}, {"aqua", 0x00ffff}, {"aquamarine", 0x7fffd4}, {"azure", 0xf0ffff},
	{"beige", 0xf5f5dc}, {"bisque", 0xffe4c4}, {"black", 0x000000}, {"blanchedalmond", 0xffebcd}, {"blue", 0x0000ff},
	{"blueviolet", 0x8a2be2}, {"brown", 0xa52a2a}, {"burlywood", 0xdeb887}, {"cadetblue", 0x5f9ea0}, {"chartreuse", 0x7fff00},
	{"chocolate", 0xd2691e}, {"coral", 0xff7f50}, {"cornflowerblue", 0x6495ed}, {"cornsilk", 0xfff8dc}, {"crimson", 0xdc143c},
	{"cyan", 0x00ffff}, {"darkblue", 0x00008b}, {"darkcyan", 0x008b8b}, {"darkgoldenrod", 0xb8860b}, {"darkgray", 0xa9a9a9},
	{"darkgreen", 0x006400}, {"darkgrey", 0xa9a9a9}, {"darkkhaki", 0xbdb76b}, {"darkmagenta", 0x8b008b}, {"darkolivegreen", 0x556b2f},
	{"darkorange", 0xff8c00}, {"darkorchid", 0x9932cc}, {"darkred", 0x8b0000}, {"darksalmon", 0xe9967a}, {"darkseagreen", 0x8fbc8f},
	{"darkslateblue", 0x483d8b}, {"darkslategray", 0x2f4f4f}, {"darkslategrey", 0x2f4f4f}, {"darkturquoise", 0x00ced1},
	{"darkviolet", 0x9400d3}, {"deeppink", 0xff1493}, {"deepskyblue", 0x00bfff}, {"dimgray", 0x696969}, {"dimgrey", 0x696969},
	{"dodgerblue", 0x1e90ff}, {"firebrick", 0xb22222}, {"floralwhite", 0xfffaf0}, {"forestgreen", 0x228b22}, {"fuchsia", 0xff00ff},
	{"gainsboro", 0xdcdcdc}, {"ghostwhite", 0xf8f8ff}, {"gold", 0xffd700}, {"goldenrod", 0xdaa520}, {"gray", 0x808080},
	{"green", 0x008000}, {"greenyellow", 0xadff2f}, {"grey", 0x808080}, {"honeydew", 0xf0fff0}, {"hotpink", 0xff69b4},
	{"indianred", 0xcd5c5c}, {"indigo", 0x4b0082}, {"ivory", 0xfffff0}, {"khaki", 0xf0e68c}, {"lavender", 0xe6e6fa},
	{"lavenderblush", 0xfff0f5}, {"lawngreen", 0x7cfc00}, {"lemonchiffon", 0xfffacd}, {"lightblue", 0xadd8e6}, {"lightcoral", 0xf08080},
	{"lightcyan", 0xe0ffff}, {"lightgoldenrodyellow", 0xfafad2}, {"lightgray", 0xd3d3d3}, {"lightgreen", 0x90ee90}, {"lightgrey", 0xd3d3d3},
	{"lightpink", 0xffb6c1}, {"lightsalmon", 0xffa07a}, {"lightseagreen", 0x20b2aa}, {"lightskyblue", 0x87cefa}, {"lightslategray", 0x778899},
	{"lightslategrey", 0x778899}, {"lightsteelblue", 0xb0c4de}, {"lightyellow", 0xffffe0}, {"lime", 0x00ff00}, {"limegreen", 0x32cd32},
	{"linen", 0xfaf0e6}, {"magenta", 0xff00ff}, {"maroon", 0x800000}, {"mediumaquamarine", 0x66cdaa}, {"mediumblue", 0x0000cd},
	{"mediumorchid", 0xba55d3}, {"mediumpurple", 0x9370db}, {"mediumseagreen", 0x3cb371}, {"mediumslateblue", 0x7b68ee},
	{"mediumspringgreen", 0x00fa9a}, {"mediumturquoise", 0x48d1cc}, {"mediumvioletred", 0xc71585}, {"midnightblue", 0x191970},
	{"mintcream", 0xf5fffa}, {"mistyrose", 0xffe4e1}, {"moccasin", 0xffe4b5}, {"navajowhite", 0xffdead}, {"navy", 0x000080},
	{"oldlace", 0xfdf5e6}, {"olive", 0x808000}, {"olivedrab", 0x6b8e23}, {"orange", 0xffa500}, {"orangered", 0xff4500},
	{"orchid", 0xda70d6}, {"palegoldenrod", 0xeee8aa}, {"palegreen", 0x98fb98}, {"paleturquoise", 0xafeeee}, {"palevioletred", 0xdb7093},
	{"papayawhip", 0xffefd5}, {"peachpuff", 0xffdab9}, {"peru", 0xcd853f}, {"pink", 0xffc0cb}, {"plum", 0xdda0dd},
	{"powderblue", 0xb0e0e6}, {"purple", 0x800080}, {"rebeccapurple", 0x663399}, {"red", 0xff0000}, {"rosybrown", 0xbc8f8f},
	{"royalblue", 0x4169e1}, {"saddlebrown", 0x8b4513}, {"salmon", 0xfa8072}, {"sandybrown", 0xf4a460}, {"seagreen", 0x2e8b57},
	{"seashell", 0xfff5ee}, {"sienna", 0xa0522d}, {"silver", 0xc0c0c0}, {"skyblue", 0x87ceeb}, {"slateblue", 0x6a5acd},
	{"slategray", 0x708090}, {"slategrey", 0x708090}, {"snow", 0xfffafa}, {"springgreen", 0x00ff7f}, {"steelblue", 0x4682b4},
	{"tan", 0xd2b48c}, {"teal", 0x008080}, {"thistle", 0xd8bfd8}, {"tomato", 0xff6347}, {"turquoise", 0x40e0d0},
	{"violet", 0xee82ee}, {"wheat", 0xf5deb3}, {"white", 0xffffff}, {"whitesmoke", 0xf5f5f5}, {"yellow", 0xffff00}, {"yellowgreen", 0x9acd32},
}

color_from_u32 :: proc(rgb: u32) -> Color {
	return {f32((rgb >> 16) & 0xff) / 255, f32((rgb >> 8) & 0xff) / 255, f32(rgb & 0xff) / 255, 1}
}

@(private)
clamp01 :: proc(x: f32) -> f32 { return clamp(x, 0, 1) }

@(private)
hex_digit :: proc(c: u8) -> int {
	switch {
	case c >= '0' && c <= '9': return int(c - '0')
	case c >= 'a' && c <= 'f': return int(c - 'a') + 10
	case c >= 'A' && c <= 'F': return int(c - 'A') + 10
	}
	return -1
}

parse_hex_color :: proc(s: string) -> (c: Color, ok: bool) {
	for ch in transmute([]u8)s { if hex_digit(ch) < 0 { return {}, false } }
	switch len(s) {
	case 3, 4:
		c = {f32(hex_digit(s[0]) * 17) / 255, f32(hex_digit(s[1]) * 17) / 255, f32(hex_digit(s[2]) * 17) / 255, 1}
		if len(s) == 4 { c.a = f32(hex_digit(s[3]) * 17) / 255 }
		return c, true
	case 6, 8:
		b :: proc(s: string, i: int) -> f32 { return f32(hex_digit(s[i]) * 16 + hex_digit(s[i + 1])) / 255 }
		c = {b(s, 0), b(s, 2), b(s, 4), 1}
		if len(s) == 8 { c.a = b(s, 6) }
		return c, true
	}
	return {}, false
}

// Components of a color function: numbers, percentages (relative to `pct_scale`), `none`, separated by spaces, commas
// and an optional `/ alpha`.
@(private)
Components :: struct {
	vals:    [4]f64,
	is_pct:  [4]bool,
	is_none: [4]bool,
	has_unit: [4]string,      // dimension unit of the component (deg, rad, turn...)
	n:       int,
	alpha:   f64,
	alpha_given: bool,
}

@(private)
read_components :: proc(args: []Value, c: ^Components) -> bool {
	slash := false
	for v in args {
		if v.kind == .Token {
			t := v.tok
			#partial switch t.kind {
			case .Whitespace, .Comma: continue
			case .Delim:
				if t.text == "/" { slash = true; continue }
				return false
			case .Number, .Percentage, .Dimension, .Ident:
				idx := slash ? 3 : c.n
				if idx > 3 { return false }
				if !slash && c.n == 3 { idx = 3; slash = true }   // legacy comma syntax: rgba(r, g, b, a)
				if idx == 3 && c.alpha_given { return false }
				#partial switch t.kind {
				case .Number: c.vals[idx] = t.num
				case .Percentage: c.vals[idx], c.is_pct[idx] = t.num, true
				case .Dimension: c.vals[idx], c.has_unit[idx] = t.num, t.text
				case .Ident:
					if strings.equal_fold(t.text, "none") { c.is_none[idx] = true } else { return false }
				}
				if slash { c.alpha_given = true } else { c.n += 1 }
			case: return false
			}
		} else if v.kind == .Function {
			// calc() inside a color component
			n, ok := eval_simple_calc(v)
			if !ok { return false }
			idx := slash ? 3 : c.n
			if idx > 3 { return false }
			if !slash && c.n == 3 { idx = 3; slash = true }
			if idx == 3 && c.alpha_given { return false }
			c.vals[idx] = n
			if slash { c.alpha_given = true } else { c.n += 1 }
		} else { return false }
	}
	return c.n == 3
}

@(private)
alpha_of :: proc(c: Components) -> f32 {
	if !c.alpha_given { return 1 }
	if c.is_none[3] { return 0 }
	return clamp01(f32(c.is_pct[3] ? c.vals[3] / 100 : c.vals[3]))
}

@(private)
hue_degrees :: proc(v: f64, unit: string) -> f64 {
	d := v
	switch strings.to_lower(unit, context.temp_allocator) {
	case "rad": d = v * 180 / math.PI
	case "grad": d = v * 0.9
	case "turn": d = v * 360
	}
	d = math.mod(d, 360)
	if d < 0 { d += 360 }
	return d
}

@(private)
hsl_to_rgb :: proc(h, s, l: f64) -> [3]f32 {
	f :: proc(n, h, s, l: f64) -> f64 {
		k := math.mod(n + h / 30, 12)
		a := s * min(l, 1 - l)
		return l - a * max(-1, min(k - 3, min(9 - k, 1)))
	}
	return {f32(f(0, h, s, l)), f32(f(8, h, s, l)), f32(f(4, h, s, l))}
}

@(private)
srgb_encode :: proc(x: f64) -> f32 {
	a := math.abs(x)
	v: f64
	if a <= 0.0031308 { v = 12.92 * a } else { v = 1.055 * math.pow(a, 1 / 2.4) - 0.055 }
	return clamp01(f32(math.sign(x) * v))
}

@(private)
srgb_decode :: proc(x: f32) -> f64 {
	a := math.abs(f64(x))
	v: f64
	if a <= 0.04045 { v = a / 12.92 } else { v = math.pow((a + 0.055) / 1.055, 2.4) }
	return math.sign(f64(x)) * v
}

@(private)
xyz_d50_to_srgb :: proc(x, y, z: f64) -> Color {
	// XYZ D50 -> linear sRGB (Bradford-adapted matrix)
	r := 3.1338561 * x - 1.6168667 * y - 0.4906146 * z
	g := -0.9787684 * x + 1.9161415 * y + 0.0334540 * z
	b := 0.0719453 * x - 0.2289914 * y + 1.4052427 * z
	return {srgb_encode(r), srgb_encode(g), srgb_encode(b), 1}
}

@(private)
lab_to_srgb :: proc(l, a, b: f64) -> Color {
	fy := (l + 16) / 116
	fx := a / 500 + fy
	fz := fy - b / 200
	e := 216.0 / 24389.0
	k := 24389.0 / 27.0
	xr := fx * fx * fx > e ? fx * fx * fx : (116 * fx - 16) / k
	yr := l > k * e ? math.pow((l + 16) / 116, 3) : l / k
	zr := fz * fz * fz > e ? fz * fz * fz : (116 * fz - 16) / k
	return xyz_d50_to_srgb(xr * 0.3457 / 0.3585, yr, zr * (1 - 0.3457 - 0.3585) / 0.3585)
}

@(private)
oklab_to_srgb :: proc(l, a, b: f64) -> Color {
	l_ := l + 0.3963377774 * a + 0.2158037573 * b
	m_ := l - 0.1055613458 * a - 0.0638541728 * b
	s_ := l - 0.0894841775 * a - 1.2914855480 * b
	l3, m3, s3 := l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_
	r := 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
	g := -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
	bb := -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
	return {srgb_encode(r), srgb_encode(g), srgb_encode(bb), 1}
}

@(private)
srgb_to_oklab :: proc(c: Color) -> [3]f64 {
	r, g, b := srgb_decode(c.r), srgb_decode(c.g), srgb_decode(c.b)
	l := math.pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1.0 / 3.0)
	m := math.pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1.0 / 3.0)
	s := math.pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1.0 / 3.0)
	return {0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s, 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s}
}

parse_color :: proc(input: []Value, env: ^Color_Env) -> (cv: Color_Value, ok: bool) {
	vs := trim_values(input)
	if len(vs) != 1 { return {}, false }
	v := vs[0]
	switch v.kind {
	case .Token:
		t := v.tok
		#partial switch t.kind {
		case .Hash:
			c, good := parse_hex_color(t.text)
			return Color_Value{rgba = c}, good
		case .Ident:
			n := strings.to_lower(t.text, context.temp_allocator)
			switch n {
			case "currentcolor": return Color_Value{kind = .Current_Color}, true
			case "transparent": return Color_Value{rgba = {0, 0, 0, 0}}, true
			}
			for e in NAMED_COLORS { if e.name == n { return Color_Value{rgba = color_from_u32(e.rgb)}, true } }
			if env != nil && env.system != nil {
				if c, good := env.system(env.user, n, env.dark); good { return Color_Value{rgba = c}, true }
			}
		}
		return {}, false
	case .Function:
		return parse_color_function(v, env)
	case .Block:
	}
	return {}, false
}

@(private)
parse_color_function :: proc(f: Value, env: ^Color_Env) -> (cv: Color_Value, ok: bool) {
	name := strings.to_lower(f.tok.text, context.temp_allocator)
	args := f.children
	switch name {
	case "light-dark":
		parts := split_commas(args, context.temp_allocator)
		if len(parts) != 2 { return {}, false }
		pick := (env != nil && env.dark) ? parts[1] : parts[0]
		return parse_color(pick, env)
	case "color-mix":
		return parse_color_mix(args, env)
	}
	c: Components
	if !read_components(args, &c) { return {}, false }
	alpha := alpha_of(c)
	val :: proc(c: Components, i: int, pct_100: f64) -> f64 {
		if c.is_none[i] { return 0 }
		return c.is_pct[i] ? c.vals[i] / 100 * pct_100 : c.vals[i]
	}
	switch name {
	case "rgb", "rgba":
		ch :: proc(c: Components, i: int) -> f32 { return clamp01(f32(val(c, i, 255) / 255)) }
		return Color_Value{rgba = {ch(c, 0), ch(c, 1), ch(c, 2), alpha}}, true
	case "hsl", "hsla":
		h := c.is_none[0] ? 0 : hue_degrees(c.vals[0], c.has_unit[0])
		s := clamp(val(c, 1, 100) / 100, 0, 1)
		l := clamp(val(c, 2, 100) / 100, 0, 1)
		rgb := hsl_to_rgb(h, s, l)
		return Color_Value{rgba = {rgb.r, rgb.g, rgb.b, alpha}}, true
	case "hwb":
		h := c.is_none[0] ? 0 : hue_degrees(c.vals[0], c.has_unit[0])
		w := clamp(val(c, 1, 100) / 100, 0, 1)
		b := clamp(val(c, 2, 100) / 100, 0, 1)
		if w + b >= 1 { g := f32(w / (w + b)); return Color_Value{rgba = {g, g, g, alpha}}, true }
		rgb := hsl_to_rgb(h, 1, 0.5)
		for k in 0 ..< 3 { rgb[k] = rgb[k] * f32(1 - w - b) + f32(w) }
		return Color_Value{rgba = {rgb.r, rgb.g, rgb.b, alpha}}, true
	case "lab":
		col := lab_to_srgb(val(c, 0, 100), val(c, 1, 125), val(c, 2, 125))
		col.a = alpha
		return Color_Value{rgba = col}, true
	case "lch":
		h := hue_degrees(c.vals[2], c.has_unit[2]) * math.PI / 180
		ch := val(c, 1, 150)
		col := lab_to_srgb(val(c, 0, 100), ch * math.cos(h), ch * math.sin(h))
		col.a = alpha
		return Color_Value{rgba = col}, true
	case "oklab":
		col := oklab_to_srgb(val(c, 0, 1), val(c, 1, 0.4), val(c, 2, 0.4))
		col.a = alpha
		return Color_Value{rgba = col}, true
	case "oklch":
		h := hue_degrees(c.vals[2], c.has_unit[2]) * math.PI / 180
		ch := val(c, 1, 0.4)
		col := oklab_to_srgb(val(c, 0, 1), ch * math.cos(h), ch * math.sin(h))
		col.a = alpha
		return Color_Value{rgba = col}, true
	}
	return {}, false
}

// color-mix(in srgb|oklab|srgb-linear, c1 [p1%], c2 [p2%])
@(private)
parse_color_mix :: proc(args: []Value, env: ^Color_Env) -> (cv: Color_Value, ok: bool) {
	parts := split_commas(args, context.temp_allocator)
	if len(parts) != 3 { return {}, false }
	space := ""
	for v in trim_values(parts[0]) { if v.kind == .Token && v.tok.kind == .Ident && !strings.equal_fold(v.tok.text, "in") { space = strings.to_lower(v.tok.text, context.temp_allocator) } }
	if space == "" { return {}, false }
	Side :: struct { c: Color, p: f64, has_p: bool }
	sides: [2]Side
	for i in 0 ..< 2 {
		vs := trim_values(parts[i + 1])
		rest := make([dynamic]Value, context.temp_allocator)
		for v in vs {
			if v.kind == .Token && v.tok.kind == .Percentage { sides[i].p, sides[i].has_p = v.tok.num / 100, true } else { append(&rest, v) }
		}
		col, good := parse_color(rest[:], env)
		if !good || col.kind == .Current_Color { return {}, false }
		sides[i].c = col.rgba
	}
	p1, p2 := sides[0].p, sides[1].p
	switch {
	case !sides[0].has_p && !sides[1].has_p: p1, p2 = 0.5, 0.5
	case !sides[0].has_p: p1 = 1 - p2
	case !sides[1].has_p: p2 = 1 - p1
	}
	total := p1 + p2
	if total <= 0 { return {}, false }
	alpha_mult := min(total, 1)
	p1, p2 = p1 / total, p2 / total
	a := sides[0].c; b := sides[1].c
	// premultiplied interpolation
	alpha := f32(f64(a.a) * p1 + f64(b.a) * p2)
	out: Color
	switch space {
	case "srgb":
		for k in 0 ..< 3 { out[k] = alpha > 0 ? f32((f64(a[k] * a.a) * p1 + f64(b[k] * b.a) * p2)) / alpha : 0 }
	case "srgb-linear":
		for k in 0 ..< 3 {
			l := (srgb_decode(a[k]) * f64(a.a) * p1 + srgb_decode(b[k]) * f64(b.a) * p2) / max(f64(alpha), 1e-9)
			out[k] = srgb_encode(l)
		}
	case "oklab", "oklch", "lab", "lch", "hsl", "hwb", "xyz", "display-p3":
		la, lb := srgb_to_oklab(a), srgb_to_oklab(b)   // other spaces are interpolated in OKLab: close for most inputs
		l := (la[0] * f64(a.a) * p1 + lb[0] * f64(b.a) * p2) / max(f64(alpha), 1e-9)
		aa := (la[1] * f64(a.a) * p1 + lb[1] * f64(b.a) * p2) / max(f64(alpha), 1e-9)
		bb := (la[2] * f64(a.a) * p1 + lb[2] * f64(b.a) * p2) / max(f64(alpha), 1e-9)
		out = oklab_to_srgb(l, aa, bb)
	case: return {}, false
	}
	out.a = alpha * f32(alpha_mult)
	for k in 0 ..< 3 { out[k] = clamp01(out[k]) }
	return Color_Value{rgba = out}, true
}

////////////////////////////////
// Lengths, numbers and calc()

Unit :: enum u8 { Px, Em, Rem, Ex, Ch, Lh, Vw, Vh, Vmin, Vmax, Percent, Ms, Deg }   // Ms, Deg: canonical time and angle

// <time> in milliseconds and <angle> in degrees, from a unit as written.
time_unit_to_ms :: proc(n: f64, unit: string) -> (f64, bool) {
	switch strings.to_lower(unit, context.temp_allocator) {
	case "s": return n * 1000, true
	case "ms": return n, true
	}
	return 0, false
}

angle_unit_to_deg :: proc(n: f64, unit: string) -> (f64, bool) {
	switch strings.to_lower(unit, context.temp_allocator) {
	case "deg": return n, true
	case "rad": return n * 180 / math.PI, true
	case "grad": return n * 0.9, true
	case "turn": return n * 360, true
	}
	return 0, false
}

// Absolute units are converted when parsed; relative ones are resolved by the style system with its context.
length_unit_to_px :: proc(n: f64, unit: string, _: f64) -> (px: f64, ok: bool) {
	switch strings.to_lower(unit, context.temp_allocator) {
	case "px": return n, true
	case "cm": return n * 96 / 2.54, true
	case "mm": return n * 96 / 25.4, true
	case "q":  return n * 96 / 101.6, true
	case "in": return n * 96, true
	case "pt": return n * 96 / 72, true
	case "pc": return n * 16, true
	}
	return 0, false
}

relative_unit :: proc(unit: string) -> (Unit, bool) {
	switch strings.to_lower(unit, context.temp_allocator) {
	case "em": return .Em, true
	case "rem": return .Rem, true
	case "ex": return .Ex, true
	case "ch": return .Ch, true
	case "lh": return .Lh, true
	case "vw", "svw", "lvw", "dvw", "vi": return .Vw, true
	case "vh", "svh", "lvh", "dvh", "vb": return .Vh, true
	case "vmin", "svmin", "lvmin", "dvmin": return .Vmin, true
	case "vmax", "svmax", "lvmax", "dvmax": return .Vmax, true
	}
	return .Px, false
}

// The bases relative units resolve against.
Length_Context :: struct {
	font_size:   f64,    // em
	root_font_size: f64, // rem
	x_height:    f64,
	ch:          f64,
	line_height: f64,
	vw, vh:      f64,    // viewport size in px
	percent_base: f64,   // what 100% means here
}

resolve_unit :: proc(n: f64, u: Unit, c: Length_Context) -> f64 {
	switch u {
	case .Px: return n
	case .Em: return n * c.font_size
	case .Rem: return n * c.root_font_size
	case .Ex: return n * c.x_height
	case .Ch: return n * c.ch
	case .Lh: return n * c.line_height
	case .Vw: return n * c.vw / 100
	case .Vh: return n * c.vh / 100
	case .Vmin: return n * min(c.vw, c.vh) / 100
	case .Vmax: return n * max(c.vw, c.vh) / 100
	case .Percent: return n * c.percent_base / 100
	case .Ms, .Deg: return n
	}
	return n
}

Calc_Op :: enum u8 { Number, Dimension, Add, Sub, Mul, Div, Min, Max, Clamp, Abs, Neg }

// A calc() expression tree. Leaves are numbers or dimensions (a value and a unit); percentages are `.Percent`.
Calc :: struct {
	op:   Calc_Op,
	num:  f64,
	unit: Unit,
	a, b, c: ^Calc,
}

// Parses calc(), min(), max(), clamp(), abs() (and a bare parenthesised sum inside them).
parse_calc :: proc(f: Value, alloc: Arena_Alloc) -> ^Calc {
	if f.kind != .Function { return nil }
	name := strings.to_lower(f.tok.text, context.temp_allocator)
	switch name {
	case "calc", "-webkit-calc", "-moz-calc": return calc_sum(trim_values(f.children), alloc, 0)
	case "min", "max":
		args := split_commas(f.children, context.temp_allocator)
		if len(args) == 0 || len(args) > 64 { return nil }
		acc := calc_sum(trim_values(args[0]), alloc, 0)
		if acc == nil { return nil }
		for i in 1 ..< len(args) {
			rhs := calc_sum(trim_values(args[i]), alloc, 0)
			if rhs == nil { return nil }
			n := new(Calc, alloc); n.op = name == "min" ? .Min : .Max; n.a, n.b = acc, rhs
			acc = n
		}
		return acc
	case "clamp":
		args := split_commas(f.children, context.temp_allocator)
		if len(args) != 3 { return nil }
		a := calc_sum(trim_values(args[0]), alloc, 0)
		b := calc_sum(trim_values(args[1]), alloc, 0)
		c := calc_sum(trim_values(args[2]), alloc, 0)
		if a == nil || b == nil || c == nil { return nil }
		n := new(Calc, alloc); n.op, n.a, n.b, n.c = .Clamp, a, b, c
		return n
	case "abs":
		a := calc_sum(trim_values(f.children), alloc, 0)
		if a == nil { return nil }
		n := new(Calc, alloc); n.op, n.a = .Abs, a
		return n
	}
	return nil
}

@(private)
CALC_MAX_DEPTH :: 64   // a syntactic bound on nesting, independent of the sheet's own limit

@(private)
calc_sum :: proc(vs: []Value, alloc: Arena_Alloc, depth: int) -> ^Calc {
	if depth > CALC_MAX_DEPTH || len(vs) == 0 { return nil }
	// split into terms at top-level + and -  (they must be surrounded by whitespace; a sign glued to a number is part of it)
	terms := make([dynamic]^Calc, context.temp_allocator)
	signs := make([dynamic]bool, context.temp_allocator)   // true = subtract
	cur := make([dynamic]Value, context.temp_allocator)
	next_neg := false
	flush :: proc(cur: ^[dynamic]Value, terms: ^[dynamic]^Calc, signs: ^[dynamic]bool, neg: bool, alloc: Arena_Alloc, depth: int) -> bool {
		t := calc_product(trim_values(cur[:]), alloc, depth)
		clear(cur)
		if t == nil { return false }
		append(terms, t)
		append(signs, neg)
		return true
	}
	for v in vs {
		if v.kind == .Token && v.tok.kind == .Delim && (v.tok.text == "+" || v.tok.text == "-") && len(cur) > 0 {
			if !flush(&cur, &terms, &signs, next_neg, alloc, depth) { return nil }
			next_neg = v.tok.text == "-"
			continue
		}
		append(&cur, v)
	}
	if !flush(&cur, &terms, &signs, next_neg, alloc, depth) { return nil }
	acc := terms[0]
	if signs[0] { n := new(Calc, alloc); n.op, n.a = .Neg, acc; acc = n }
	for i in 1 ..< len(terms) {
		n := new(Calc, alloc)
		n.op = signs[i] ? .Sub : .Add
		n.a, n.b = acc, terms[i]
		acc = n
	}
	return acc
}

@(private)
calc_product :: proc(vs: []Value, alloc: Arena_Alloc, depth: int) -> ^Calc {
	if len(vs) == 0 { return nil }
	acc: ^Calc
	op := Calc_Op.Mul
	expect_operand := true   // operands and * / alternate; two operands in a row are invalid
	for v in vs {
		if is_ws_value(v) { continue }
		if v.kind == .Token && v.tok.kind == .Delim && (v.tok.text == "*" || v.tok.text == "/") {
			if expect_operand { return nil }
			op = v.tok.text == "*" ? .Mul : .Div
			expect_operand = true
			continue
		}
		if !expect_operand { return nil }
		leaf := calc_leaf(v, alloc, depth)
		if leaf == nil { return nil }
		expect_operand = false
		if acc == nil { acc = leaf; continue }
		n := new(Calc, alloc)
		n.op, n.a, n.b = op, acc, leaf
		acc = n
	}
	if expect_operand { return nil }   // a dangling operator
	return acc
}

@(private)
calc_leaf :: proc(v: Value, alloc: Arena_Alloc, depth: int) -> ^Calc {
	n := new(Calc, alloc)
	switch v.kind {
	case .Token:
		t := v.tok
		#partial switch t.kind {
		case .Number: n.op, n.num = .Number, t.num
		case .Percentage: n.op, n.num, n.unit = .Dimension, t.num, .Percent
		case .Dimension:
			if px, ok := length_unit_to_px(t.num, t.text, 0); ok { n.op, n.num, n.unit = .Dimension, px, .Px; break }
			if ms, ok := time_unit_to_ms(t.num, t.text); ok { n.op, n.num, n.unit = .Dimension, ms, .Ms; break }
			if deg, ok := angle_unit_to_deg(t.num, t.text); ok { n.op, n.num, n.unit = .Dimension, deg, .Deg; break }
			u, ok := relative_unit(t.text)
			if !ok { return nil }
			n.op, n.num, n.unit = .Dimension, t.num, u
		case .Ident:
			switch strings.to_lower(t.text, context.temp_allocator) {
			case "pi": n.op, n.num = .Number, math.PI
			case "e": n.op, n.num = .Number, math.E
			case: return nil
			}
		case: return nil
		}
	case .Block:
		if v.tok.kind != .Open_Paren { return nil }
		inner := calc_sum(trim_values(v.children), alloc, depth + 1)
		if inner == nil { return nil }
		return inner
	case .Function:
		inner := parse_calc(v, alloc)
		if inner == nil { return nil }
		return inner
	}
	return n
}

// Evaluates to px (numbers stay numbers). `c.percent_base` is what 100% means.
eval_calc :: proc(n: ^Calc, c: Length_Context) -> f64 {
	if n == nil { return 0 }
	switch n.op {
	case .Number: return n.num
	case .Dimension: return resolve_unit(n.num, n.unit, c)
	case .Add: return eval_calc(n.a, c) + eval_calc(n.b, c)
	case .Sub: return eval_calc(n.a, c) - eval_calc(n.b, c)
	case .Mul: return eval_calc(n.a, c) * eval_calc(n.b, c)
	case .Div:
		d := eval_calc(n.b, c)
		return d == 0 ? 0 : eval_calc(n.a, c) / d
	case .Min: return min(eval_calc(n.a, c), eval_calc(n.b, c))
	case .Max: return max(eval_calc(n.a, c), eval_calc(n.b, c))
	case .Clamp: return max(eval_calc(n.a, c), min(eval_calc(n.b, c), eval_calc(n.c, c)))
	case .Abs: return math.abs(eval_calc(n.a, c))
	case .Neg: return -eval_calc(n.a, c)
	}
	return 0
}

// A calc() made only of numbers and absolute lengths (media queries, color components).
eval_simple_calc :: proc(f: Value) -> (f64, bool) {
	tmp := context.temp_allocator
	n := parse_calc(f, tmp)
	if n == nil { return 0, false }
	return eval_calc(n, Length_Context{font_size = 16, root_font_size = 16}), true
}

// A bare number token (also accepts calc() of numbers).
parse_number :: proc(input: []Value) -> (f64, bool) {
	vs := trim_values(input)
	if len(vs) != 1 { return 0, false }
	if vs[0].kind == .Token && vs[0].tok.kind == .Number { return vs[0].tok.num, true }
	if vs[0].kind == .Function { return eval_simple_calc(vs[0]) }
	return 0, false
}

parse_integer :: proc(input: []Value) -> (int, bool) {
	vs := trim_values(input)
	if len(vs) == 1 && vs[0].kind == .Token && vs[0].tok.kind == .Number && vs[0].tok.is_int { return int(vs[0].tok.num), true }
	return 0, false
}

// The text of an identifier value, lower-cased; "" when `vs` is not a single identifier.
ident_of :: proc(input: []Value) -> string {
	vs := trim_values(input)
	if len(vs) == 1 && vs[0].kind == .Token && vs[0].tok.kind == .Ident { return strings.to_lower(vs[0].tok.text, context.temp_allocator) }
	return ""
}

// Serialises component values back to CSS text (custom properties, var() fallbacks, diagnostics).
serialize_values :: proc(vs: []Value, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	write_values(&sb, vs)
	return strings.to_string(sb)
}

@(private)
write_values :: proc(sb: ^strings.Builder, vs: []Value) {
	for v in vs {
		switch v.kind {
		case .Token: write_token(sb, v.tok)
		case .Function:
			strings.write_string(sb, v.tok.text)
			strings.write_byte(sb, '(')
			write_values(sb, v.children)
			strings.write_byte(sb, ')')
		case .Block:
			open, close := byte('('), byte(')')
			#partial switch v.tok.kind {
			case .Open_Square: open, close = '[', ']'
			case .Open_Curly: open, close = '{', '}'
			}
			strings.write_byte(sb, open)
			write_values(sb, v.children)
			strings.write_byte(sb, close)
		}
	}
}

@(private)
write_token :: proc(sb: ^strings.Builder, t: Token) {
	fmt_num :: proc(sb: ^strings.Builder, t: Token) {
		if t.is_int { fmt.sbprintf(sb, "%d", int(t.num)) } else { fmt.sbprintf(sb, "%g", t.num) }
	}
	#partial switch t.kind {
	case .Ident: strings.write_string(sb, t.text)
	case .At_Keyword: strings.write_byte(sb, '@'); strings.write_string(sb, t.text)
	case .Hash: strings.write_byte(sb, '#'); strings.write_string(sb, t.text)
	case .String:
		strings.write_byte(sb, '"')
		for c in transmute([]u8)t.text { if c == '"' || c == '\\' { strings.write_byte(sb, '\\') }; strings.write_byte(sb, c) }
		strings.write_byte(sb, '"')
	case .Url: strings.write_string(sb, "url("); strings.write_string(sb, t.text); strings.write_byte(sb, ')')
	case .Delim: strings.write_string(sb, t.text)
	case .Number: fmt_num(sb, t)
	case .Percentage: fmt_num(sb, t); strings.write_byte(sb, '%')
	case .Dimension: fmt_num(sb, t); strings.write_string(sb, t.text)
	case .Whitespace: strings.write_byte(sb, ' ')
	case .Colon: strings.write_byte(sb, ':')
	case .Semicolon: strings.write_byte(sb, ';')
	case .Comma: strings.write_byte(sb, ',')
	}
}
