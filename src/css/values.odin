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
	// the value of currentcolor where it is known (computed values): color-mix() and relative colors resolve it
	current:     Color,
	has_current: bool,
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
	sc, cur, good := parse_color_function_sc(f, env)
	if !good { return {}, false }
	if cur { return Color_Value{kind = .Current_Color}, true }
	return Color_Value{rgba = color_to_srgb(sc)}, true
}

////////////////////////////////
// Lengths, numbers and calc()

Unit :: enum u8 { Px, Em, Rem, Ex, Ch, Lh, Vw, Vh, Vmin, Vmax, Percent, Ms, Deg, Rlh, Cap, Ic, Rex, Rch, Ric, Rcap, Cqw, Cqh, Cqmin, Cqmax }   // Ms, Deg: canonical time and angle

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
	case "rlh": return .Rlh, true
	case "cap": return .Cap, true
	case "ic": return .Ic, true
	case "rex": return .Rex, true
	case "rch": return .Rch, true
	case "ric": return .Ric, true
	case "rcap": return .Rcap, true
	// the viewport never has collapsing browser bars here: small, large and dynamic viewports are the same
	case "vw", "svw", "lvw", "dvw", "vi", "svi", "lvi", "dvi": return .Vw, true
	case "vh", "svh", "lvh", "dvh", "vb", "svb", "lvb", "dvb": return .Vh, true
	case "vmin", "svmin", "lvmin", "dvmin": return .Vmin, true
	case "vmax", "svmax", "lvmax", "dvmax": return .Vmax, true
	// container query units (horizontal writing: inline = width)
	case "cqw", "cqi": return .Cqw, true
	case "cqh", "cqb": return .Cqh, true
	case "cqmin": return .Cqmin, true
	case "cqmax": return .Cqmax, true
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
	root_line_height: f64,   // rlh
	vw, vh:      f64,    // viewport size in px
	percent_base: f64,   // what 100% means here
	// the query container's content box for cq units (CSS Contain 3 §6.1); without one, the small viewport
	cq_w, cq_h:  f64,
	has_cq_w, has_cq_h: bool,
}

// Font-relative units this engine resolves without the font's metrics, as fractions of the em (CSS Values 4 gives these
// as the fallbacks when a metric is unavailable: ex and ch 0.5em, cap the ascent ~0.7em, ic 1em).
X_HEIGHT_EM :: 0.5
CH_EM :: 0.5
CAP_EM :: 0.7

resolve_unit :: proc(n: f64, u: Unit, c: Length_Context) -> f64 {
	switch u {
	case .Px: return n
	case .Em: return n * c.font_size
	case .Rem: return n * c.root_font_size
	case .Ex: return n * c.x_height
	case .Ch: return n * c.ch
	case .Lh: return n * (c.line_height > 0 ? c.line_height : c.font_size * 1.2)
	case .Rlh: return n * (c.root_line_height > 0 ? c.root_line_height : c.root_font_size * 1.2)
	case .Cap: return n * c.font_size * CAP_EM
	case .Ic: return n * c.font_size
	case .Rex: return n * c.root_font_size * X_HEIGHT_EM
	case .Rch: return n * c.root_font_size * CH_EM
	case .Ric: return n * c.root_font_size
	case .Rcap: return n * c.root_font_size * CAP_EM
	case .Cqw: return n * (c.has_cq_w ? c.cq_w : c.vw) / 100
	case .Cqh: return n * (c.has_cq_h ? c.cq_h : c.vh) / 100
	case .Cqmin: return n * min(c.has_cq_w ? c.cq_w : c.vw, c.has_cq_h ? c.cq_h : c.vh) / 100
	case .Cqmax: return n * max(c.has_cq_w ? c.cq_w : c.vw, c.has_cq_h ? c.cq_h : c.vh) / 100
	case .Vw: return n * c.vw / 100
	case .Vh: return n * c.vh / 100
	case .Vmin: return n * min(c.vw, c.vh) / 100
	case .Vmax: return n * max(c.vw, c.vh) / 100
	case .Percent: return n * c.percent_base / 100
	case .Ms, .Deg: return n
	}
	return n
}

Calc_Op :: enum u8 {
	Number, Dimension, Add, Sub, Mul, Div, Min, Max, Clamp, Abs, Neg,
	// CSS Values 4 math functions
	Round, Mod, Rem, Sign, Pow, Sqrt, Hypot, Log, Exp, Sin, Cos, Tan, Asin, Acos, Atan, Atan2,
}

Round_Strategy :: enum u8 { Nearest, Up, Down, To_Zero }

// A calc() expression tree. Leaves are numbers or dimensions (a value and a unit); percentages are `.Percent`.
// Round: `strategy` says how; trigonometric functions take radians (an angle argument is converted when parsed) and
// the inverse ones give degrees.
Calc :: struct {
	op:   Calc_Op,
	num:  f64,
	unit: Unit,
	strategy: Round_Strategy,
	a, b, c: ^Calc,
}

// The CSS name and arguments of a math function node (serialisation).
calc_function_of :: proc(n: ^Calc) -> (name: string, args: [3]^Calc, count: int) {
	args = {n.a, n.b, n.c}
	for x in args { if x != nil { count += 1 } }
	#partial switch n.op {
	case .Min: name = "min"
	case .Max: name = "max"
	case .Clamp: name = "clamp"
	case .Abs: name = "abs"
	case .Round: name = "round"
	case .Mod: name = "mod"
	case .Rem: name = "rem"
	case .Sign: name = "sign"
	case .Pow: name = "pow"
	case .Sqrt: name = "sqrt"
	case .Hypot: name = "hypot"
	case .Log: name = "log"
	case .Exp: name = "exp"
	case .Sin: name = "sin"
	case .Cos: name = "cos"
	case .Tan: name = "tan"
	case .Asin: name = "asin"
	case .Acos: name = "acos"
	case .Atan: name = "atan"
	case .Atan2: name = "atan2"
	case: name = "calc"
	}
	return
}

@(private)
calc_node :: proc(alloc: Arena_Alloc, op: Calc_Op, a: ^Calc, b: ^Calc = nil, c: ^Calc = nil) -> ^Calc {
	n := new(Calc, alloc)
	n.op, n.a, n.b, n.c = op, a, b, c
	return n
}

// Some leaf of the tree is an angle.
@(private)
calc_has_angle :: proc(n: ^Calc) -> bool {
	if n == nil { return false }
	if n.op == .Dimension && n.unit == .Deg { return true }
	#partial switch n.op {
	case .Asin, .Acos, .Atan, .Atan2: return true   // their result is an angle
	case .Sin, .Cos, .Tan: return false             // their result is a number
	}
	return calc_has_angle(n.a) || calc_has_angle(n.b) || calc_has_angle(n.c)
}

// A function that parse_calc reads (a <length>, <number>... written as a math function).
is_math_function :: proc(name: string) -> bool {
	switch strings.to_lower(name, context.temp_allocator) {
	case "calc", "-webkit-calc", "-moz-calc", "min", "max", "clamp", "abs", "sign", "round", "mod", "rem", "pow", "sqrt",
	     "hypot", "log", "exp", "sin", "cos", "tan", "asin", "acos", "atan", "atan2":
		return true
	}
	return false
}

// Parses calc() and the math functions: min(), max(), clamp(), abs(), sign(), round(), mod(), rem(), pow(), sqrt(),
// hypot(), log(), exp(), sin(), cos(), tan(), asin(), acos(), atan(), atan2() (and parenthesised sums inside them).
parse_calc :: proc(f: Value, alloc: Arena_Alloc) -> ^Calc {
	if f.kind != .Function { return nil }
	name := strings.to_lower(f.tok.text, context.temp_allocator)
	args :: proc(f: Value, alloc: Arena_Alloc, lo, hi: int) -> ([]^Calc, bool) {
		parts := split_commas(f.children, context.temp_allocator)
		if len(parts) < lo || len(parts) > hi { return nil, false }
		out := make([]^Calc, len(parts), context.temp_allocator)
		for p, i in parts {
			out[i] = calc_sum(trim_values(p), alloc, 0)
			if out[i] == nil { return nil, false }
		}
		return out, true
	}
	switch name {
	case "calc", "-webkit-calc", "-moz-calc": return calc_sum(trim_values(f.children), alloc, 0)
	case "min", "max", "hypot":
		xs, ok := args(f, alloc, 1, 64)
		if !ok { return nil }
		op: Calc_Op = name == "min" ? .Min : name == "max" ? .Max : .Hypot
		if op == .Hypot && len(xs) == 1 { return calc_node(alloc, .Abs, xs[0]) }
		acc := xs[0]
		for i in 1 ..< len(xs) { acc = calc_node(alloc, op, acc, xs[i]) }
		return acc
	case "clamp":
		xs, ok := args(f, alloc, 3, 3)
		if !ok { return nil }
		return calc_node(alloc, .Clamp, xs[0], xs[1], xs[2])
	case "abs", "sign", "sqrt", "exp":
		xs, ok := args(f, alloc, 1, 1)
		if !ok { return nil }
		op: Calc_Op = name == "abs" ? .Abs : name == "sign" ? .Sign : name == "sqrt" ? .Sqrt : .Exp
		return calc_node(alloc, op, xs[0])
	case "mod", "rem", "pow", "atan2":
		xs, ok := args(f, alloc, 2, 2)
		if !ok { return nil }
		op: Calc_Op = name == "mod" ? .Mod : name == "rem" ? .Rem : name == "pow" ? .Pow : .Atan2
		return calc_node(alloc, op, xs[0], xs[1])
	case "log":
		xs, ok := args(f, alloc, 1, 2)
		if !ok { return nil }
		return calc_node(alloc, .Log, xs[0], len(xs) == 2 ? xs[1] : nil)
	case "sin", "cos", "tan":
		xs, ok := args(f, alloc, 1, 1)
		if !ok { return nil }
		x := xs[0]
		if calc_has_angle(x) {   // degrees -> radians
			k := new(Calc, alloc); k.op, k.num = .Number, math.PI / 180
			x = calc_node(alloc, .Mul, x, k)
		}
		return calc_node(alloc, name == "sin" ? .Sin : name == "cos" ? .Cos : .Tan, x)
	case "asin", "acos", "atan":
		xs, ok := args(f, alloc, 1, 1)
		if !ok { return nil }
		return calc_node(alloc, name == "asin" ? .Asin : name == "acos" ? .Acos : .Atan, xs[0])
	case "round":
		// round([strategy,] A [, B])
		parts := split_commas(f.children, context.temp_allocator)
		strategy := Round_Strategy.Nearest
		if len(parts) > 0 {
			switch ident_of(parts[0]) {
			case "nearest": strategy = .Nearest; parts = parts[1:]
			case "up": strategy = .Up; parts = parts[1:]
			case "down": strategy = .Down; parts = parts[1:]
			case "to-zero": strategy = .To_Zero; parts = parts[1:]
			}
		}
		if len(parts) < 1 || len(parts) > 2 { return nil }
		a := calc_sum(trim_values(parts[0]), alloc, 0)
		if a == nil { return nil }
		b: ^Calc
		if len(parts) == 2 {
			b = calc_sum(trim_values(parts[1]), alloc, 0)
			if b == nil { return nil }
		} else {
			b = new(Calc, alloc); b.op, b.num = .Number, 1
		}
		n := calc_node(alloc, .Round, a, b)
		n.strategy = strategy
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
			case "infinity": n.op, n.num = .Number, CALC_INFINITY
			case "-infinity": n.op, n.num = .Number, -CALC_INFINITY
			case "nan": n.op, n.num = .Number, 0   // NaN in a property value is censored to 0 (CSS Values 4 §10.9)
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
	case .Sign:
		x := eval_calc(n.a, c)
		return x > 0 ? 1 : x < 0 ? -1 : 0
	case .Round:
		a, b := eval_calc(n.a, c), eval_calc(n.b, c)
		if b == 0 { return a }
		q := a / b
		r: f64
		switch n.strategy {
		case .Nearest: r = math.floor(q + 0.5)
		case .Up: r = math.ceil(q)
		case .Down: r = math.floor(q)
		case .To_Zero: r = math.trunc(q)
		}
		return r * b
	case .Mod:
		a, b := eval_calc(n.a, c), eval_calc(n.b, c)
		if b == 0 { return 0 }
		return a - b * math.floor(a / b)
	case .Rem:
		a, b := eval_calc(n.a, c), eval_calc(n.b, c)
		if b == 0 { return 0 }
		return a - b * math.trunc(a / b)
	case .Pow: return finite(math.pow(eval_calc(n.a, c), eval_calc(n.b, c)))
	case .Sqrt: return finite(math.sqrt(max(eval_calc(n.a, c), 0)))
	case .Hypot:
		a, b := eval_calc(n.a, c), eval_calc(n.b, c)
		return finite(math.sqrt(a * a + b * b))
	case .Log:
		x := eval_calc(n.a, c)
		if x <= 0 { return 0 }
		if n.b == nil { return math.ln(x) }
		base := eval_calc(n.b, c)
		if base <= 0 || base == 1 { return 0 }
		return math.ln(x) / math.ln(base)
	case .Exp: return finite(math.exp(eval_calc(n.a, c)))
	case .Sin: return math.sin(eval_calc(n.a, c))
	case .Cos: return math.cos(eval_calc(n.a, c))
	case .Tan: return finite(math.tan(eval_calc(n.a, c)))
	case .Asin: return math.asin(clamp(eval_calc(n.a, c), -1, 1)) * 180 / math.PI
	case .Acos: return math.acos(clamp(eval_calc(n.a, c), -1, 1)) * 180 / math.PI
	case .Atan: return math.atan(eval_calc(n.a, c)) * 180 / math.PI
	case .Atan2: return math.atan2(eval_calc(n.a, c), eval_calc(n.b, c)) * 180 / math.PI
	}
	return 0
}

// What `infinity` stands for: finite in every later f32 computation (radii scaled to their box, z-index clamped...), far
// beyond any real length. `border-radius: calc(infinity * 1px)` (a pill) is the common use.
CALC_INFINITY :: 1e15

// NaN becomes 0 and infinities the largest finite values, as CSS Values 4 §10.9 asks of a value that reaches a property.
@(private)
finite :: proc(x: f64) -> f64 {
	if math.is_nan(x) { return 0 }
	if math.is_inf(x, 1) { return CALC_INFINITY }
	if math.is_inf(x, -1) { return -CALC_INFINITY }
	return x
}

// The type of a calc() result (CSS Values 4 §10.8): numbers, lengths, percentages (that become lengths where the
// property takes <length-percentage>), angles, times. Invalid: mixed types that cannot combine (10px + 2, 1s * 2px).
Calc_Type :: enum u8 { Invalid, Number, Length, Percent, Length_Percent, Angle, Time }

calc_type :: proc(n: ^Calc) -> Calc_Type {
	if n == nil { return .Invalid }
	same :: proc(a, b: Calc_Type) -> Calc_Type {
		if a == .Invalid || b == .Invalid { return .Invalid }
		if a == b { return a }
		lp := proc(t: Calc_Type) -> bool { return t == .Length || t == .Percent || t == .Length_Percent }
		if lp(a) && lp(b) { return .Length_Percent }
		return .Invalid
	}
	switch n.op {
	case .Number: return .Number
	case .Dimension:
		#partial switch n.unit {
		case .Percent: return .Percent
		case .Ms: return .Time
		case .Deg: return .Angle
		}
		return .Length
	case .Add, .Sub, .Min, .Max, .Mod, .Rem, .Round, .Hypot: return same(calc_type(n.a), calc_type(n.b))
	case .Clamp: return same(same(calc_type(n.a), calc_type(n.b)), calc_type(n.c))
	case .Mul:
		a, b := calc_type(n.a), calc_type(n.b)
		if a == .Number { return b }
		if b == .Number { return a }
		return .Invalid
	case .Div:
		if calc_type(n.b) != .Number { return .Invalid }
		return calc_type(n.a)
	case .Abs, .Neg: return calc_type(n.a)
	case .Sign: return calc_type(n.a) == .Invalid ? .Invalid : .Number
	case .Pow, .Sqrt, .Exp, .Log:
		for x in ([3]^Calc{n.a, n.b, n.c}) { if x != nil && calc_type(x) != .Number { return .Invalid } }
		return .Number
	case .Sin, .Cos, .Tan:
		// an angle argument was multiplied by a number when parsed: angle or number in, number out
		t := calc_type(n.a)
		return t == .Number || t == .Angle ? .Number : .Invalid
	case .Asin, .Acos, .Atan: return calc_type(n.a) == .Number ? .Angle : .Invalid
	case .Atan2:
		t := same(calc_type(n.a), calc_type(n.b))
		return t == .Invalid ? .Invalid : .Angle
	}
	return .Invalid
}

// A calc() of numbers (color components, numbers). Lengths, times and angles are refused.
eval_number_calc :: proc(f: Value) -> (f64, bool) {
	n := parse_calc(f, context.temp_allocator)
	if n == nil || calc_type(n) != .Number { return 0, false }
	return eval_calc(n, Length_Context{font_size = 16, root_font_size = 16}), true
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
	if vs[0].kind == .Function { return eval_number_calc(vs[0]) }
	return 0, false
}

parse_integer :: proc(input: []Value) -> (int, bool) {
	vs := trim_values(input)
	if len(vs) == 1 && vs[0].kind == .Token && vs[0].tok.kind == .Number && vs[0].tok.is_int { return int(vs[0].tok.num), true }
	if len(vs) == 1 && vs[0].kind == .Function {   // calc() of numbers, rounded to the nearest integer
		n, ok := eval_number_calc(vs[0])
		if !ok { return 0, false }
		return int(clamp(math.round(n), -2_147_483_647, 2_147_483_647)), true
	}
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
