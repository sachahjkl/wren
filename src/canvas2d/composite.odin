package canvas2d

import "core:math"

// globalCompositeOperation: the Porter-Duff operators and the blend modes of Compositing and Blending Level 1.
Composite_Op :: enum u8 {
	Source_Over, Source_In, Source_Out, Source_Atop,
	Destination_Over, Destination_In, Destination_Out, Destination_Atop,
	Lighter, Copy, Xor,
	Multiply, Screen, Overlay, Darken, Lighten, Color_Dodge, Color_Burn, Hard_Light, Soft_Light, Difference, Exclusion,
	Hue, Saturation, Color, Luminosity,
}

OP_NAMES := [Composite_Op]string{
	.Source_Over = "source-over", .Source_In = "source-in", .Source_Out = "source-out", .Source_Atop = "source-atop",
	.Destination_Over = "destination-over", .Destination_In = "destination-in", .Destination_Out = "destination-out",
	.Destination_Atop = "destination-atop", .Lighter = "lighter", .Copy = "copy", .Xor = "xor",
	.Multiply = "multiply", .Screen = "screen", .Overlay = "overlay", .Darken = "darken", .Lighten = "lighten",
	.Color_Dodge = "color-dodge", .Color_Burn = "color-burn", .Hard_Light = "hard-light", .Soft_Light = "soft-light",
	.Difference = "difference", .Exclusion = "exclusion", .Hue = "hue", .Saturation = "saturation", .Color = "color",
	.Luminosity = "luminosity",
}

op_from_name :: proc(s: string) -> (Composite_Op, bool) {
	for n, op in OP_NAMES { if n == s { return op, true } }
	return .Source_Over, false
}

// Operators whose result depends on pixels the shape does not cover: the whole clip region is composited (source-in
// clears everything outside the shape).
op_is_unbounded :: proc "contextless" (op: Composite_Op) -> bool {
	#partial switch op {
	case .Source_In, .Source_Out, .Destination_In, .Destination_Atop, .Copy: return true
	}
	return false
}

// Both colors premultiplied. The result is premultiplied.
blend :: proc(op: Composite_Op, s, d: [4]f32) -> [4]f32 {
	sa, da := s.a, d.a
	switch op {
	case .Source_Over: return s + d * (1 - sa)
	case .Source_In: return s * da
	case .Source_Out: return s * (1 - da)
	case .Source_Atop: return s * da + d * (1 - sa)
	case .Destination_Over: return d + s * (1 - da)
	case .Destination_In: return d * sa
	case .Destination_Out: return d * (1 - sa)
	case .Destination_Atop: return d * sa + s * (1 - da)
	case .Lighter: return {min(s.r + d.r, 1), min(s.g + d.g, 1), min(s.b + d.b, 1), min(sa + da, 1)}
	case .Copy: return s
	case .Xor: return s * (1 - da) + d * (1 - sa)
	case .Multiply, .Screen, .Overlay, .Darken, .Lighten, .Color_Dodge, .Color_Burn, .Hard_Light, .Soft_Light, .Difference, .Exclusion,
	     .Hue, .Saturation, .Color, .Luminosity:
		// W3C: Co = Cs (1 - ab) + Cb (1 - as) + as ab B(Cb, Cs), on premultiplied terms; alpha is source-over's
		cs: [3]f32 = sa > 0 ? [3]f32{s.r, s.g, s.b} / sa : [3]f32{}
		cb: [3]f32 = da > 0 ? [3]f32{d.r, d.g, d.b} / da : [3]f32{}
		b: [3]f32
		#partial switch op {
		case .Hue: b = set_lum(set_sat(cs, sat(cb)), lum(cb))
		case .Saturation: b = set_lum(set_sat(cb, sat(cs)), lum(cb))
		case .Color: b = set_lum(cs, lum(cb))
		case .Luminosity: b = set_lum(cb, lum(cs))
		case: for i in 0 ..< 3 { b[i] = blend_channel(op, cb[i], cs[i]) }
		}
		k := sa * da
		return {
			s.r * (1 - da) + d.r * (1 - sa) + k * b[0],
			s.g * (1 - da) + d.g * (1 - sa) + k * b[1],
			s.b * (1 - da) + d.b * (1 - sa) + k * b[2],
			sa + da - k,
		}
	}
	return s + d * (1 - sa)
}

@(private)
blend_channel :: proc(op: Composite_Op, cb, cs: f32) -> f32 {
	#partial switch op {
	case .Multiply: return cb * cs
	case .Screen: return cb + cs - cb * cs
	case .Overlay: return blend_channel(.Hard_Light, cs, cb)
	case .Darken: return min(cb, cs)
	case .Lighten: return max(cb, cs)
	case .Color_Dodge:
		if cb == 0 { return 0 }
		if cs >= 1 { return 1 }
		return min(1, cb / (1 - cs))
	case .Color_Burn:
		if cb >= 1 { return 1 }
		if cs <= 0 { return 0 }
		return 1 - min(1, (1 - cb) / cs)
	case .Hard_Light:
		if cs <= 0.5 { return cb * 2 * cs }
		t := 2 * cs - 1
		return cb + t - cb * t
	case .Soft_Light:
		if cs <= 0.5 { return cb - (1 - 2 * cs) * cb * (1 - cb) }
		dd: f32 = cb <= 0.25 ? ((16 * cb - 12) * cb + 4) * cb : math.sqrt(cb)
		return cb + (2 * cs - 1) * (dd - cb)
	case .Difference: return abs(cb - cs)
	case .Exclusion: return cb + cs - 2 * cb * cs
	}
	return cs
}

@(private)
lum :: proc "contextless" (c: [3]f32) -> f32 { return 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2] }

@(private)
sat :: proc "contextless" (c: [3]f32) -> f32 { return max(c[0], c[1], c[2]) - min(c[0], c[1], c[2]) }

@(private)
clip_color :: proc "contextless" (c: [3]f32) -> [3]f32 {
	l, n, x := lum(c), min(c[0], c[1], c[2]), max(c[0], c[1], c[2])
	r := c
	if n < 0 { for i in 0 ..< 3 { r[i] = l + (r[i] - l) * l / (l - n) } }
	if x > 1 { for i in 0 ..< 3 { r[i] = l + (r[i] - l) * (1 - l) / (x - l) } }
	return r
}

@(private)
set_lum :: proc "contextless" (c: [3]f32, l: f32) -> [3]f32 {
	d := l - lum(c)
	return clip_color({c[0] + d, c[1] + d, c[2] + d})
}

@(private)
set_sat :: proc "contextless" (c: [3]f32, s: f32) -> [3]f32 {
	r := c
	mx, mn := 0, 0
	for i in 1 ..< 3 {
		if r[i] > r[mx] { mx = i }
		if r[i] < r[mn] { mn = i }
	}
	if mx == mn { return {} }
	mid := 3 - mx - mn
	out: [3]f32
	if r[mx] > r[mn] {
		out[mid] = (r[mid] - r[mn]) * s / (r[mx] - r[mn])
		out[mx] = s
	}
	return out
}
