package css

import "core:math"
import "core:strings"

// CSS Color 4 and 5: every color space of color() and the color functions, color-mix() in any space with hue
// interpolation methods and missing components, and relative colors (`oklch(from var(--x) l c h / 50%)`). Colors are
// converted through CIE XYZ (D65) with the matrices of the specification's sample code, and clipped to sRGB at the end
// (the surface the browser paints on is sRGB).

Color_Space :: enum u8 { Srgb, Srgb_Linear, Display_P3, A98_Rgb, Prophoto_Rgb, Rec2020, Xyz_D50, Xyz_D65, Lab, Lch, Oklab, Oklch, Hsl, Hwb }

// A color in one space, channels in the space's reference ranges: rgb-like 0..1, xyz 0..1, lab L 0..100, oklab L 0..1,
// hues in degrees, hsl s/l and hwb w/b 0..100. `none` marks missing components (alpha is index 3).
Space_Color :: struct {
	space: Color_Space,
	ch:    [3]f64,
	alpha: f64,
	none:  [4]bool,
}

Hue_Interpolation :: enum u8 { Shorter, Longer, Increasing, Decreasing }

color_space_of_name :: proc(name: string) -> (Color_Space, bool) {
	switch strings.to_lower(name, context.temp_allocator) {
	case "srgb": return .Srgb, true
	case "srgb-linear": return .Srgb_Linear, true
	case "display-p3": return .Display_P3, true
	case "a98-rgb": return .A98_Rgb, true
	case "prophoto-rgb": return .Prophoto_Rgb, true
	case "rec2020": return .Rec2020, true
	case "xyz", "xyz-d65": return .Xyz_D65, true
	case "xyz-d50": return .Xyz_D50, true
	case "lab": return .Lab, true
	case "lch": return .Lch, true
	case "oklab": return .Oklab, true
	case "oklch": return .Oklch, true
	case "hsl": return .Hsl, true
	case "hwb": return .Hwb, true
	}
	return .Srgb, false
}

@(private)
hue_index :: proc(s: Color_Space) -> int {
	#partial switch s {
	case .Hsl, .Hwb: return 0
	case .Lch, .Oklch: return 2
	}
	return -1
}

////////////////////////////////
// Conversions

@(private) Mat3 :: [3][3]f64

@(private)
mul3 :: proc(m: Mat3, v: [3]f64) -> [3]f64 {
	return {
		m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
		m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
		m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
	}
}

@(private) SRGB_TO_XYZ :: Mat3{{506752.0 / 1228815, 87881.0 / 245763, 12673.0 / 70218}, {87098.0 / 409605, 175762.0 / 245763, 12673.0 / 175545}, {7918.0 / 409605, 87881.0 / 737289, 1001167.0 / 1053270}}
@(private) XYZ_TO_SRGB :: Mat3{{12831.0 / 3959, -329.0 / 214, -1974.0 / 3959}, {-851781.0 / 878810, 1648619.0 / 878810, 36519.0 / 878810}, {705.0 / 12673, -2585.0 / 12673, 705.0 / 667}}
@(private) P3_TO_XYZ :: Mat3{{608311.0 / 1250200, 189793.0 / 714400, 198249.0 / 1000160}, {35783.0 / 156275, 247089.0 / 357200, 198249.0 / 2500400}, {0, 32229.0 / 714400, 5220557.0 / 5000800}}
@(private) XYZ_TO_P3 :: Mat3{{446124.0 / 178915, -333277.0 / 357830, -72051.0 / 178915}, {-14852.0 / 17905, 63121.0 / 35810, 423.0 / 17905}, {11844.0 / 330415, -50337.0 / 660830, 316169.0 / 330415}}
@(private) A98_TO_XYZ :: Mat3{{573536.0 / 994567, 263643.0 / 1420810, 187206.0 / 994567}, {591459.0 / 1989134, 6239551.0 / 9945670, 374412.0 / 4972835}, {53769.0 / 1989134, 351524.0 / 4972835, 4929758.0 / 4972835}}
@(private) XYZ_TO_A98 :: Mat3{{1829569.0 / 896150, -506331.0 / 896150, -308931.0 / 896150}, {-851781.0 / 878810, 1648619.0 / 878810, 36519.0 / 878810}, {16779.0 / 1248040, -147721.0 / 1248040, 1266979.0 / 1248040}}
@(private) PROPHOTO_TO_XYZ50 :: Mat3{{0.79776664490064230, 0.13518129740053308, 0.03134773412839220}, {0.28807482881940130, 0.71183523424187300, 0.00008993693872564}, {0, 0, 0.82510460251046020}}
@(private) XYZ50_TO_PROPHOTO :: Mat3{{1.34578688164715830, -0.25557208737979464, -0.05110186497554526}, {-0.54463070512490190, 1.50824774284514680, 0.02052744743642139}, {0, 0, 1.21196754563894520}}
@(private) REC2020_TO_XYZ :: Mat3{{63426534.0 / 99577255, 20160776.0 / 139408157, 47086771.0 / 278816314}, {26158966.0 / 99577255, 472592308.0 / 697040785, 8267143.0 / 139408157}, {0, 19567812.0 / 697040785, 295819943.0 / 278816314}}
@(private) XYZ_TO_REC2020 :: Mat3{{30757411.0 / 17917100, -6372589.0 / 17917100, -4539589.0 / 17917100}, {-19765991.0 / 29648200, 47925759.0 / 29648200, 467509.0 / 29648200}, {792561.0 / 44930125, -1921689.0 / 44930125, 42328811.0 / 44930125}}
@(private) D65_TO_D50 :: Mat3{{1.0479297925449969, 0.022946870601609652, -0.05019226628920524}, {0.02962780877005599, 0.9904344267538799, -0.017073799063418826}, {-0.009243040646204504, 0.015055191490298152, 0.7518742814281371}}
@(private) D50_TO_D65 :: Mat3{{0.955473421488075, -0.02309845494876471, 0.06325924320057072}, {-0.0283697093338637, 1.0099953980813041, 0.021041441191917323}, {0.012314014864481998, -0.020507649298898964, 1.330365926242124}}
@(private) XYZ_TO_LMS :: Mat3{{0.8190224379967030, 0.3619062600528904, -0.1288737815209879}, {0.0329836539323885, 0.9292868615863434, 0.0361446663506424}, {0.0481771893596242, 0.2642395317527308, 0.6335478284694309}}
@(private) LMS_TO_OKLAB :: Mat3{{0.2104542683093140, 0.7936177747023054, -0.0040720430116193}, {1.9779985324311684, -2.4285922420485799, 0.4505937096174110}, {0.0259040424655478, 0.7827717124575296, -0.8086757549230774}}
@(private) LMS_TO_XYZ :: Mat3{{1.2268798758459243, -0.5578149944602171, 0.2813910456659647}, {-0.0405757452148008, 1.1122868032803170, -0.0717110580655164}, {-0.0763729366746601, -0.4214933324022432, 1.5869240198367816}}
@(private) OKLAB_TO_LMS :: Mat3{{1, 0.3963377773761749, 0.2158037573099136}, {1, -0.1055613458156586, -0.0638541728258133}, {1, -0.0894841775298119, -1.2914855480194092}}
@(private) D50_WHITE :: [3]f64{0.3457 / 0.3585, 1, (1 - 0.3457 - 0.3585) / 0.3585}

@(private) srgb_lin :: proc(x: f64) -> f64 { a := abs(x); return a <= 0.04045 ? x / 12.92 : math.sign(x) * math.pow((a + 0.055) / 1.055, 2.4) }
@(private) srgb_gam :: proc(x: f64) -> f64 { a := abs(x); return a <= 0.0031308 ? 12.92 * x : math.sign(x) * (1.055 * math.pow(a, 1 / 2.4) - 0.055) }
@(private) a98_lin :: proc(x: f64) -> f64 { return math.sign(x) * math.pow(abs(x), 563.0 / 256) }
@(private) a98_gam :: proc(x: f64) -> f64 { return math.sign(x) * math.pow(abs(x), 256.0 / 563) }
@(private) pp_lin :: proc(x: f64) -> f64 { a := abs(x); return a <= 16.0 / 512 ? x / 16 : math.sign(x) * math.pow(a, 1.8) }
@(private) pp_gam :: proc(x: f64) -> f64 { a := abs(x); return a >= 1.0 / 512 ? math.sign(x) * math.pow(a, 1 / 1.8) : 16 * x }
@(private) R2020_A :: 1.09929682680944
@(private) R2020_B :: 0.018053968510807
@(private) r2020_lin :: proc(x: f64) -> f64 { a := abs(x); return a < R2020_B * 4.5 ? x / 4.5 : math.sign(x) * math.pow((a + R2020_A - 1) / R2020_A, 1 / 0.45) }
@(private) r2020_gam :: proc(x: f64) -> f64 { a := abs(x); return a > R2020_B ? math.sign(x) * (R2020_A * math.pow(a, 0.45) - (R2020_A - 1)) : 4.5 * x }

@(private)
map3 :: proc(v: [3]f64, f: proc(f64) -> f64) -> [3]f64 { return {f(v[0]), f(v[1]), f(v[2])} }

@(private)
lab_to_xyz50 :: proc(l, a, b: f64) -> [3]f64 {
	k :: 24389.0 / 27
	e :: 216.0 / 24389
	f1 := (l + 16) / 116
	f0 := a / 500 + f1
	f2 := f1 - b / 200
	x := f0 * f0 * f0 > e ? f0 * f0 * f0 : (116 * f0 - 16) / k
	y := l > k * e ? math.pow((l + 16) / 116, 3) : l / k
	z := f2 * f2 * f2 > e ? f2 * f2 * f2 : (116 * f2 - 16) / k
	return {x * D50_WHITE[0], y * D50_WHITE[1], z * D50_WHITE[2]}
}

@(private)
xyz50_to_lab :: proc(xyz: [3]f64) -> [3]f64 {
	k :: 24389.0 / 27
	e :: 216.0 / 24389
	f: [3]f64
	white := D50_WHITE
	for i in 0 ..< 3 {
		v := xyz[i] / white[i]
		f[i] = v > e ? math.cbrt(v) : (k * v + 16) / 116
	}
	return {116 * f[1] - 16, 500 * (f[0] - f[1]), 200 * (f[1] - f[2])}
}

@(private)
polar_to_rect :: proc(l, c, h: f64) -> [3]f64 {
	r := h * math.PI / 180
	return {l, c * math.cos(r), c * math.sin(r)}
}

@(private)
rect_to_polar :: proc(l, a, b: f64, eps: f64) -> (out: [3]f64, hue_none: bool) {
	c := math.sqrt(a * a + b * b)
	h := math.atan2(b, a) * 180 / math.PI
	if h < 0 { h += 360 }
	return {l, c, h}, c <= eps   // an achromatic color has a powerless hue
}

@(private)
hsl_to_srgb :: proc(h, s, l: f64) -> [3]f64 {
	sat, lig := s / 100, l / 100
	f :: proc(n, h, s, l: f64) -> f64 {
		k := math.mod(n + h / 30, 12)
		if k < 0 { k += 12 }
		a := s * min(l, 1 - l)
		return l - a * max(-1, min(k - 3, min(9 - k, 1)))
	}
	return {f(0, h, sat, lig), f(8, h, sat, lig), f(4, h, sat, lig)}
}

@(private)
srgb_to_hsl :: proc(rgb: [3]f64) -> (out: [3]f64, hue_none: bool) {
	r, g, b := rgb[0], rgb[1], rgb[2]
	mx := max(r, g, b)
	mn := min(r, g, b)
	l := (mx + mn) / 2
	d := mx - mn
	h, s: f64
	if d != 0 {
		s = (l == 0 || l == 1) ? 0 : (mx - l) / min(l, 1 - l)
		switch mx {
		case r: h = (g - b) / d + (g < b ? 6 : 0)
		case g: h = (b - r) / d + 2
		case: h = (r - g) / d + 4
		}
		h *= 60
	}
	if s < 0 { h += 180; s = -s }   // out-of-gamut input
	if h >= 360 { h -= 360 }
	return {h, s * 100, l * 100}, d == 0
}

@(private)
hwb_to_srgb :: proc(h, w, b: f64) -> [3]f64 {
	wh, bl := w / 100, b / 100
	if wh + bl >= 1 { g := wh / (wh + bl); return {g, g, g} }
	rgb := hsl_to_srgb(h, 100, 50)
	for k in 0 ..< 3 { rgb[k] = rgb[k] * (1 - wh - bl) + wh }
	return rgb
}

@(private)
srgb_to_hwb :: proc(rgb: [3]f64) -> (out: [3]f64, hue_none: bool) {
	hsl, none := srgb_to_hsl(rgb)
	w := min(rgb[0], rgb[1], rgb[2])
	bk := 1 - max(rgb[0], rgb[1], rgb[2])
	return {hsl[0], w * 100, bk * 100}, none || w + bk >= 1
}

// CIE XYZ (D65) of a color.
color_to_xyz :: proc(c: Space_Color) -> [3]f64 {
	ch := c.ch
	for i in 0 ..< 3 { if c.none[i] { ch[i] = 0 } }
	switch c.space {
	case .Srgb: return mul3(SRGB_TO_XYZ, map3(ch, srgb_lin))
	case .Srgb_Linear: return mul3(SRGB_TO_XYZ, ch)
	case .Display_P3: return mul3(P3_TO_XYZ, map3(ch, srgb_lin))
	case .A98_Rgb: return mul3(A98_TO_XYZ, map3(ch, a98_lin))
	case .Prophoto_Rgb: return mul3(D50_TO_D65, mul3(PROPHOTO_TO_XYZ50, map3(ch, pp_lin)))
	case .Rec2020: return mul3(REC2020_TO_XYZ, map3(ch, r2020_lin))
	case .Xyz_D65: return ch
	case .Xyz_D50: return mul3(D50_TO_D65, ch)
	case .Lab: return mul3(D50_TO_D65, lab_to_xyz50(ch[0], ch[1], ch[2]))
	case .Lch:
		lab := polar_to_rect(ch[0], ch[1], ch[2])
		return mul3(D50_TO_D65, lab_to_xyz50(lab[0], lab[1], lab[2]))
	case .Oklab, .Oklch:
		lab := c.space == .Oklch ? polar_to_rect(ch[0], ch[1], ch[2]) : ch
		lms := mul3(OKLAB_TO_LMS, lab)
		return mul3(LMS_TO_XYZ, {lms[0] * lms[0] * lms[0], lms[1] * lms[1] * lms[1], lms[2] * lms[2] * lms[2]})
	case .Hsl: return mul3(SRGB_TO_XYZ, map3(hsl_to_srgb(ch[0], ch[1], ch[2]), srgb_lin))
	case .Hwb: return mul3(SRGB_TO_XYZ, map3(hwb_to_srgb(ch[0], ch[1], ch[2]), srgb_lin))
	}
	return {}
}

// A color converted to `space`; a hue that becomes powerless is marked missing.
color_convert :: proc(c: Space_Color, space: Color_Space) -> Space_Color {
	if c.space == space { return c }
	out := Space_Color{space = space, alpha = c.alpha}
	out.none[3] = c.none[3]
	xyz := color_to_xyz(c)
	switch space {
	case .Srgb: out.ch = map3(mul3(XYZ_TO_SRGB, xyz), srgb_gam)
	case .Srgb_Linear: out.ch = mul3(XYZ_TO_SRGB, xyz)
	case .Display_P3: out.ch = map3(mul3(XYZ_TO_P3, xyz), srgb_gam)
	case .A98_Rgb: out.ch = map3(mul3(XYZ_TO_A98, xyz), a98_gam)
	case .Prophoto_Rgb: out.ch = map3(mul3(XYZ50_TO_PROPHOTO, mul3(D65_TO_D50, xyz)), pp_gam)
	case .Rec2020: out.ch = map3(mul3(XYZ_TO_REC2020, xyz), r2020_gam)
	case .Xyz_D65: out.ch = xyz
	case .Xyz_D50: out.ch = mul3(D65_TO_D50, xyz)
	case .Lab: out.ch = xyz50_to_lab(mul3(D65_TO_D50, xyz))
	case .Lch:
		lab := xyz50_to_lab(mul3(D65_TO_D50, xyz))
		out.ch, out.none[2] = rect_to_polar(lab[0], lab[1], lab[2], 0.0015)
	case .Oklab, .Oklch:
		lms := mul3(XYZ_TO_LMS, xyz)
		lab := mul3(LMS_TO_OKLAB, {math.cbrt(lms[0]), math.cbrt(lms[1]), math.cbrt(lms[2])})
		if space == .Oklab { out.ch = lab } else { out.ch, out.none[2] = rect_to_polar(lab[0], lab[1], lab[2], 0.000004) }
	case .Hsl: out.ch, out.none[0] = srgb_to_hsl(map3(mul3(XYZ_TO_SRGB, xyz), srgb_gam))
	case .Hwb: out.ch, out.none[0] = srgb_to_hwb(map3(mul3(XYZ_TO_SRGB, xyz), srgb_gam))
	}
	return out
}

// The sRGB color to paint (out-of-gamut channels clipped).
color_to_srgb :: proc(c: Space_Color) -> Color {
	rgb: [3]f64
	if c.space == .Srgb {
		rgb = c.ch
		for i in 0 ..< 3 { if c.none[i] { rgb[i] = 0 } }
	} else {
		rgb = color_convert(c, .Srgb).ch
	}
	a := c.none[3] ? 0 : c.alpha
	return {clamp01(f32(rgb[0])), clamp01(f32(rgb[1])), clamp01(f32(rgb[2])), clamp01(f32(a))}
}

srgb_space_color :: proc(c: Color) -> Space_Color {
	return Space_Color{space = .Srgb, ch = {f64(c.r), f64(c.g), f64(c.b)}, alpha = f64(c.a)}
}

////////////////////////////////
// Parsing

// The color of one value in its own space (named, hex, currentcolor when the environment knows it, any function).
// `current` is set for a bare currentcolor the caller resolves itself.
parse_space_color :: proc(input: []Value, env: ^Color_Env) -> (sc: Space_Color, current: bool, ok: bool) {
	vs := trim_values(input)
	if len(vs) != 1 { return {}, false, false }
	v := vs[0]
	if v.kind == .Function { return parse_color_function_sc(v, env) }
	cv, good := parse_color(vs, env)
	if !good { return {}, false, false }
	if cv.kind == .Current_Color {
		if env != nil && env.has_current { return srgb_space_color(env.current), false, true }
		return {}, true, true
	}
	return srgb_space_color(cv.rgba), false, true
}

// Channel keywords of relative colors, with their values for the origin color.
@(private)
Channels :: struct { names: [4]string, vals: [4]f64 }

@(private)
replace_channels :: proc(vs: []Value, chans: ^Channels, a := context.temp_allocator) -> []Value {
	out := make([]Value, len(vs), a)
	for v, i in vs {
		out[i] = v
		switch v.kind {
		case .Token:
			if v.tok.kind != .Ident { continue }
			for name, k in chans.names {
				if name != "" && strings.equal_fold(v.tok.text, name) {
					out[i].tok = Token{kind = .Number, num = chans.vals[k]}
					break
				}
			}
		case .Function, .Block:
			out[i].children = replace_channels(v.children, chans, a)
		}
	}
	return out
}

@(private)
parse_color_function_sc :: proc(f: Value, env: ^Color_Env) -> (sc: Space_Color, current: bool, ok: bool) {
	name := strings.to_lower(f.tok.text, context.temp_allocator)
	args := trim_values(f.children)
	switch name {
	case "light-dark":
		parts := split_commas(args, context.temp_allocator)
		if len(parts) != 2 { return {}, false, false }
		return parse_space_color((env != nil && env.dark) ? parts[1] : parts[0], env)
	case "color-mix":
		return parse_color_mix_sc(args, env)
	}
	space: Color_Space
	legacy_rgb := false
	switch name {
	case "rgb", "rgba": space, legacy_rgb = .Srgb, true
	case "hsl", "hsla": space = .Hsl
	case "hwb": space = .Hwb
	case "lab": space = .Lab
	case "lch": space = .Lch
	case "oklab": space = .Oklab
	case "oklch": space = .Oklch
	case "color":
	case: return {}, false, false
	}
	// relative color: `from <color>` first
	rest := args
	origin: Maybe(Space_Color)
	if len(rest) > 0 && rest[0].kind == .Token && rest[0].tok.kind == .Ident && strings.equal_fold(rest[0].tok.text, "from") {
		i := 1
		for i < len(rest) && is_ws_value(rest[i]) { i += 1 }
		if i >= len(rest) { return {}, false, false }
		o, cur, good := parse_space_color(rest[i:i + 1], env)
		if !good || cur { return {}, false, false }   // currentcolor without a known value: not computable here
		origin = o
		rest = trim_values(rest[i + 1:])
	}
	if name == "color" {
		if len(rest) == 0 || rest[0].kind != .Token || rest[0].tok.kind != .Ident { return {}, false, false }
		s, good := color_space_of_name(rest[0].tok.text)
		if !good || s == .Lab || s == .Lch || s == .Oklab || s == .Oklch || s == .Hsl || s == .Hwb { return {}, false, false }
		space = s
		rest = trim_values(rest[1:])
	}
	if o, has := origin.?; has {
		conv := color_convert(o, space)
		chans: Channels
		chans.names[3], chans.vals[3] = "alpha", conv.none[3] ? 0 : conv.alpha
		for k in 0 ..< 3 { chans.vals[k] = conv.none[k] ? 0 : conv.ch[k] }
		switch space {
		case .Srgb:
			if legacy_rgb {
				chans.names[0], chans.names[1], chans.names[2] = "r", "g", "b"
				for k in 0 ..< 3 { chans.vals[k] *= 255 }
			} else {
				chans.names[0], chans.names[1], chans.names[2] = "r", "g", "b"
			}
		case .Srgb_Linear, .Display_P3, .A98_Rgb, .Prophoto_Rgb, .Rec2020: chans.names[0], chans.names[1], chans.names[2] = "r", "g", "b"
		case .Xyz_D50, .Xyz_D65: chans.names[0], chans.names[1], chans.names[2] = "x", "y", "z"
		case .Lab, .Oklab: chans.names[0], chans.names[1], chans.names[2] = "l", "a", "b"
		case .Lch, .Oklch: chans.names[0], chans.names[1], chans.names[2] = "l", "c", "h"
		case .Hsl: chans.names[0], chans.names[1], chans.names[2] = "h", "s", "l"
		case .Hwb: chans.names[0], chans.names[1], chans.names[2] = "h", "w", "b"
		}
		rest = replace_channels(rest, &chans)
		comps: Components
		if !read_components(rest, &comps) { return {}, false, false }
		sc = components_to_space(comps, space, legacy_rgb)
		if !comps.alpha_given { sc.alpha, sc.none[3] = conv.alpha, conv.none[3] }
		return sc, false, true
	}
	comps: Components
	if !read_components(rest, &comps) { return {}, false, false }
	return components_to_space(comps, space, legacy_rgb), false, true
}

// Channel values as written to the reference ranges of the space (percentages and the rgb() 0..255 scale).
@(private)
components_to_space :: proc(c: Components, space: Color_Space, legacy_rgb: bool) -> Space_Color {
	sc := Space_Color{space = space}
	pct :: proc(c: Components, i: int, hundred: f64) -> f64 { return c.is_pct[i] ? c.vals[i] / 100 * hundred : c.vals[i] }
	for i in 0 ..< 3 {
		sc.none[i] = c.is_none[i]
		switch space {
		case .Srgb:
			if legacy_rgb { sc.ch[i] = c.is_pct[i] ? c.vals[i] / 100 : c.vals[i] / 255 } else { sc.ch[i] = pct(c, i, 1) }
		case .Srgb_Linear, .Display_P3, .A98_Rgb, .Prophoto_Rgb, .Rec2020, .Xyz_D50, .Xyz_D65: sc.ch[i] = pct(c, i, 1)
		case .Lab: sc.ch[i] = pct(c, i, i == 0 ? 100 : 125)
		case .Oklab: sc.ch[i] = pct(c, i, i == 0 ? 1 : 0.4)
		case .Lch:
			switch i {
			case 0: sc.ch[i] = pct(c, i, 100)
			case 1: sc.ch[i] = max(pct(c, i, 150), 0)
			case 2: sc.ch[i] = hue_degrees(c.vals[i], c.has_unit[i])
			}
		case .Oklch:
			switch i {
			case 0: sc.ch[i] = pct(c, i, 1)
			case 1: sc.ch[i] = max(pct(c, i, 0.4), 0)
			case 2: sc.ch[i] = hue_degrees(c.vals[i], c.has_unit[i])
			}
		case .Hsl, .Hwb:
			sc.ch[i] = i == 0 ? hue_degrees(c.vals[i], c.has_unit[i]) : pct(c, i, 100)
		}
	}
	if space == .Hsl {   // saturation and lightness are clamped
		sc.ch[1] = clamp(sc.ch[1], 0, 100)
		sc.ch[2] = clamp(sc.ch[2], 0, 100)
	}
	if space == .Lab || space == .Lch { sc.ch[0] = clamp(sc.ch[0], 0, 100) }
	if space == .Oklab || space == .Oklch { sc.ch[0] = clamp(sc.ch[0], 0, 1) }
	sc.alpha = f64(alpha_of(c))
	sc.none[3] = c.alpha_given && c.is_none[3]
	return sc
}

// color-mix([in <space> [<hue> hue]]?, <color> [<p>]?, <color> [<p>]?)
@(private)
parse_color_mix_sc :: proc(args: []Value, env: ^Color_Env) -> (sc: Space_Color, current: bool, ok: bool) {
	parts := split_commas(args, context.temp_allocator)
	space := Color_Space.Oklab
	hue := Hue_Interpolation.Shorter
	colors := parts
	head := trim_values(parts[0]) if len(parts) > 0 else nil
	if len(head) > 0 && head[0].kind == .Token && head[0].tok.kind == .Ident && strings.equal_fold(head[0].tok.text, "in") {
		words := make([dynamic]string, context.temp_allocator)
		for v in head[1:] {
			if is_ws_value(v) { continue }
			if v.kind != .Token || v.tok.kind != .Ident { return {}, false, false }
			append(&words, strings.to_lower(v.tok.text, context.temp_allocator))
		}
		if len(words) == 0 { return {}, false, false }
		s, good := color_space_of_name(words[0])
		if !good { return {}, false, false }
		space = s
		switch len(words) {
		case 1:
		case 3:
			if hue_index(space) < 0 || words[2] != "hue" { return {}, false, false }
			switch words[1] {
			case "shorter": hue = .Shorter
			case "longer": hue = .Longer
			case "increasing": hue = .Increasing
			case "decreasing": hue = .Decreasing
			case: return {}, false, false
			}
		case: return {}, false, false
		}
		colors = parts[1:]
	}
	if len(colors) != 2 { return {}, false, false }
	Side :: struct { c: Space_Color, p: f64, has_p: bool }
	sides: [2]Side
	for i in 0 ..< 2 {
		rest := make([dynamic]Value, context.temp_allocator)
		for v in trim_values(colors[i]) {
			if v.kind == .Token && v.tok.kind == .Percentage {
				if sides[i].has_p || v.tok.num < 0 || v.tok.num > 100 { return {}, false, false }
				sides[i].p, sides[i].has_p = v.tok.num / 100, true
			} else if v.kind == .Function && strings.equal_fold(v.tok.text, "calc") {
				n, good := eval_simple_calc(v)
				if !good { append(&rest, v); continue }   // a color function named calc does not exist: keep for the color parser
				sides[i].p, sides[i].has_p = n / 100, true
			} else {
				append(&rest, v)
			}
		}
		c, cur, good := parse_space_color(rest[:], env)
		if !good || cur { return {}, false, false }
		sides[i].c = c
	}
	p1, p2 := sides[0].p, sides[1].p
	switch {
	case !sides[0].has_p && !sides[1].has_p: p1, p2 = 0.5, 0.5
	case !sides[0].has_p: p1 = 1 - p2
	case !sides[1].has_p: p2 = 1 - p1
	}
	total := p1 + p2
	if total <= 0 { return {}, false, false }
	alpha_mult := min(total, 1)
	p1, p2 = p1 / total, p2 / total
	return mix_colors(sides[0].c, sides[1].c, p2, space, hue, alpha_mult), false, true
}

// Interpolates `a` and `b` (t = weight of b) in `space` with premultiplied alpha and a hue interpolation method.
mix_colors :: proc(a_in, b_in: Space_Color, t: f64, space: Color_Space, hue: Hue_Interpolation, alpha_mult: f64 = 1) -> Space_Color {
	a := color_convert(a_in, space)
	b := color_convert(b_in, space)
	// missing components take the other color's value
	for i in 0 ..< 4 {
		va := i < 3 ? &a.ch[i] : &a.alpha
		vb := i < 3 ? &b.ch[i] : &b.alpha
		if a.none[i] && !b.none[i] { va^ = vb^; a.none[i] = false }
		if b.none[i] && !a.none[i] { vb^ = va^; b.none[i] = false }
	}
	out := Space_Color{space = space}
	alpha := a.alpha * (1 - t) + b.alpha * t
	out.none[3] = a.none[3] && b.none[3]
	hi := hue_index(space)
	for i in 0 ..< 3 {
		if a.none[i] && b.none[i] { out.none[i] = true; continue }
		if i == hi {
			h1, h2 := math.mod(a.ch[i], 360), math.mod(b.ch[i], 360)
			if h1 < 0 { h1 += 360 }
			if h2 < 0 { h2 += 360 }
			d := h2 - h1
			switch hue {
			case .Shorter:
				if d > 180 { h1 += 360 } else if d < -180 { h2 += 360 }
			case .Longer:
				if 0 < d && d < 180 { h1 += 360 } else if -180 < d && d <= 0 { h2 += 360 }
			case .Increasing:
				if d < 0 { h2 += 360 }
			case .Decreasing:
				if d > 0 { h1 += 360 }
			}
			h := h1 * (1 - t) + h2 * t
			out.ch[i] = math.mod(h, 360)
			continue
		}
		// premultiplied
		v := a.ch[i] * a.alpha * (1 - t) + b.ch[i] * b.alpha * t
		out.ch[i] = alpha > 0 ? v / alpha : 0
	}
	out.alpha = alpha * alpha_mult
	return out
}
