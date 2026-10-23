package canvas2d

import "core:math"
import "core:strconv"
import "core:strings"

// The `filter` property of the context (CSS Filter Effects): a list of blur(), brightness(), contrast(), grayscale(),
// hue-rotate(), invert(), opacity(), saturate(), sepia() and drop-shadow(), applied in order to what each drawing
// operation puts down, before its shadow and its compositing. url() filters (SVG) are not supported: such a value is
// ignored, like any value that does not parse.

Filter_Kind :: enum u8 { Blur, Brightness, Contrast, Grayscale, Hue_Rotate, Invert, Opacity, Saturate, Sepia, Drop_Shadow }

Filter_Op :: struct {
	kind:   Filter_Kind,
	amount: f64,        // blur: standard deviation in px; hue-rotate: degrees; the others: 0..n as a factor
	ox, oy: f64,        // drop-shadow
	color:  [4]f32,     // drop-shadow (straight); alpha 0 with `has_color` false: the element's color (black)
	has_color: bool,
}

// Parses a filter list into `out`. false: not valid (nothing is appended). "none" is valid and empty.
filter_parse :: proc(c: ^Context, text: string, out: ^[dynamic]Filter_Op) -> bool {
	s := strings.trim_space(text)
	if s == "" { return false }
	if strings.equal_fold(s, "none") { return true }
	start := len(out)
	i := 0
	for i < len(s) {
		for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') { i += 1 }
		if i >= len(s) { break }
		name_start := i
		for i < len(s) && s[i] != '(' && s[i] != ' ' { i += 1 }
		if i >= len(s) || s[i] != '(' { resize(out, start); return false }
		name := strings.to_lower(s[name_start:i], context.temp_allocator)
		depth := 0
		arg_start := i + 1
		for i < len(s) {
			if s[i] == '(' { depth += 1 } else if s[i] == ')' { depth -= 1; if depth == 0 { break } }
			i += 1
		}
		if i >= len(s) { resize(out, start); return false }
		args := strings.trim_space(s[arg_start:i])
		i += 1
		op, ok := filter_function(c, name, args)
		if !ok { resize(out, start); return false }
		append(out, op)
	}
	return len(out) > start
}

@(private)
filter_function :: proc(c: ^Context, name, args: string) -> (op: Filter_Op, ok: bool) {
	// <number> or <percentage> (a factor), defaulting to 1
	factor :: proc(args: string, def: f64) -> (f64, bool) {
		if args == "" { return def, true }
		v, unit, vok := parse_number_unit(args)
		if !vok || v < 0 { return 0, false }
		switch unit {
		case "": return v, true
		case "%": return v / 100, true
		}
		return 0, false
	}
	switch name {
	case "blur":
		if args == "" { return Filter_Op{kind = .Blur}, true }
		v, vok := parse_length(args, c.inherit.font_size)
		if !vok || v < 0 { return }
		return Filter_Op{kind = .Blur, amount = v}, true
	case "brightness", "contrast", "saturate", "grayscale", "invert", "opacity", "sepia":
		v, vok := factor(args, 1)
		if !vok { return }
		kind: Filter_Kind
		switch name {
		case "brightness": kind = .Brightness
		case "contrast": kind = .Contrast
		case "saturate": kind = .Saturate
		case "grayscale": kind = .Grayscale
		case "invert": kind = .Invert
		case "opacity": kind = .Opacity
		case "sepia": kind = .Sepia
		}
		if kind == .Grayscale || kind == .Invert || kind == .Opacity || kind == .Sepia { v = min(v, 1) }
		return Filter_Op{kind = kind, amount = v}, true
	case "hue-rotate":
		if args == "" { return Filter_Op{kind = .Hue_Rotate}, true }
		v, unit, vok := parse_number_unit(args)
		if !vok { return }
		deg: f64
		switch strings.to_lower(unit, context.temp_allocator) {
		case "deg", "": deg = v   // (a bare 0 is allowed)
		case "rad": deg = v * 180 / math.PI
		case "grad": deg = v * 0.9
		case "turn": deg = v * 360
		case: return
		}
		return Filter_Op{kind = .Hue_Rotate, amount = deg}, true
	case "drop-shadow":
		// <length>{2,3} and a color, in either order
		parts := make([dynamic]string, context.temp_allocator)
		cur := 0
		depth := 0
		for k in 0 ..= len(args) {
			if k == len(args) || (depth == 0 && (args[k] == ' ' || args[k] == '\t')) {
				if k > cur { append(&parts, args[cur:k]) }
				cur = k + 1
			} else if args[k] == '(' { depth += 1 } else if args[k] == ')' { depth -= 1 }
		}
		lens := make([dynamic]f64, context.temp_allocator)
		op.kind = .Drop_Shadow
		op.color = c.inherit.color
		for part in parts {
			if v, lok := parse_length(part, c.inherit.font_size); lok && (part[0] == '-' || part[0] == '.' || part[0] == '+' || (part[0] >= '0' && part[0] <= '9')) {
				append(&lens, v)
			} else if c.host.color != nil {
				col, cok := c.host.color(c.host.user, part)
				if !cok { return }
				op.color, op.has_color = col, true
			} else { return }
		}
		if len(lens) < 2 || len(lens) > 3 { return }
		op.ox, op.oy = lens[0], lens[1]
		if len(lens) == 3 {
			if lens[2] < 0 { return }
			op.amount = lens[2]
		}
		return op, true
	}
	return
}

// A <length> in px, em, ... (also what letter-spacing and word-spacing take).
parse_length :: proc(s: string, base_size: f64) -> (px: f64, ok: bool) {
	t := strings.trim_space(s)
	if t == "" { return }
	lower := strings.to_lower(t, context.temp_allocator)
	v, unit, vok := parse_number_unit(lower)
	if !vok { return }
	if unit == "" { return v, v == 0 }
	switch unit {
	case "px": return v, true
	case "pt": return v * 4 / 3, true
	case "pc": return v * 16, true
	case "in": return v * 96, true
	case "cm": return v * 96 / 2.54, true
	case "mm": return v * 96 / 25.4, true
	case "q": return v * 96 / 101.6, true
	case "em": return v * base_size, true
	case "rem": return v * 16, true
	case "ex", "ch": return v * base_size * 0.5, true
	}
	return
}

// filter = value: ignored when it does not parse. (The page's color parser serves drop-shadow's color.)
ctx_set_filter :: proc(c: ^Context, value: string) {
	ops := make([dynamic]Filter_Op, context.temp_allocator)
	if !filter_parse(c, value, &ops) { return }
	delete(c.state.filter)
	delete(c.state.filter_text)
	c.state.filter = nil
	c.state.filter_text = ""
	if len(ops) > 0 {
		c.state.filter = make([]Filter_Op, len(ops))
		copy(c.state.filter, ops[:])
		c.state.filter_text = strings.clone(strings.trim_space(value))
	}
}

// How far a filter list spreads a shape's pixels outward (device pixels), for the layer it is applied in.
filter_reach :: proc(c: ^Context) -> int {
	reach := 0
	scale, _ := matrix_scales(c.state.ctm)
	for op in c.state.filter {
		#partial switch op.kind {
		case .Blur: reach += int(math.ceil(op.amount * scale * 3)) + 1
		case .Drop_Shadow:
			reach += int(math.ceil(op.amount * scale * 3)) + int(math.ceil(max(abs(op.ox), abs(op.oy)) * scale)) + 1
		}
	}
	return reach
}

filter_active :: proc "contextless" (c: ^Context) -> bool { return c.opts.filters && len(c.state.filter) > 0 }

// Applies the filter list to a layer (premultiplied). The layer was made wide enough for blurs.
filter_apply :: proc(c: ^Context, layer: ^Bitmap) {
	scale, _ := matrix_scales(c.state.ctm)
	for op in c.state.filter {
		switch op.kind {
		case .Blur: layer_blur(layer, op.amount * scale)
		case .Drop_Shadow:
			sigma := op.amount * scale
			plane := make([]f32, layer.w * layer.h)
			for i in 0 ..< layer.w * layer.h { plane[i] = f32(layer.pix[i * 4 + 3]) * (1.0 / 255.0) }
			if sigma > 0 { gaussian_blur(plane, layer.w, layer.h, sigma) }
			ox, oy := int(math.round(op.ox * scale)), int(math.round(op.oy * scale))
			col := premultiply(op.color)
			out := make([]u8, len(layer.pix))
			for y in 0 ..< layer.h {
				for x in 0 ..< layer.w {
					a := f32(0)
					if sx, sy := x - ox, y - oy; sx >= 0 && sx < layer.w && sy >= 0 && sy < layer.h { a = plane[sy * layer.w + sx] }
					s := col * a
					d := load_px(layer, x, y)
					// the shape over its shadow
					store_f(out, (y * layer.w + x) * 4, d + s * (1 - d.a))
				}
			}
			copy(layer.pix, out)
			delete(plane)
			delete(out)
		case .Brightness, .Contrast, .Grayscale, .Hue_Rotate, .Invert, .Opacity, .Saturate, .Sepia:
			color_filter(layer, op)
		}
	}
}

@(private)
store_f :: proc(out: []u8, i: int, v: [4]f32) {
	a := clamp(v.a, 0, 1)
	out[i + 3] = u8(a * 255 + 0.5)
	out[i] = u8(min(clamp(v.r, 0, 1), a) * 255 + 0.5)
	out[i + 1] = u8(min(clamp(v.g, 0, 1), a) * 255 + 0.5)
	out[i + 2] = u8(min(clamp(v.b, 0, 1), a) * 255 + 0.5)
}

@(private)
layer_blur :: proc(layer: ^Bitmap, sigma: f64) {
	if sigma <= 0 || layer.w == 0 || layer.h == 0 { return }
	n := layer.w * layer.h
	plane := make([]f32, n)
	defer delete(plane)
	for ch in 0 ..< 4 {
		for i in 0 ..< n { plane[i] = f32(layer.pix[i * 4 + ch]) }
		gaussian_blur(plane, layer.w, layer.h, sigma)
		for i in 0 ..< n { layer.pix[i * 4 + ch] = u8(clamp(plane[i], 0, 255) + 0.5) }
	}
	// the blurred channels of premultiplied pixels stay premultiplied (color <= alpha holds for averages)
	for i in 0 ..< n {
		a := layer.pix[i * 4 + 3]
		for ch in 0 ..< 3 { if layer.pix[i * 4 + ch] > a { layer.pix[i * 4 + ch] = a } }
	}
}

@(private)
color_filter :: proc(layer: ^Bitmap, op: Filter_Op) {
	v := f32(op.amount)
	for i in 0 ..< layer.w * layer.h {
		px := load_px(layer, i % layer.w, i / layer.w)
		if px.a <= 0 { continue }
		rgb := [3]f32{px.r, px.g, px.b} / px.a   // straight
		a := px.a
		lum := 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
		#partial switch op.kind {
		case .Brightness: rgb *= v
		case .Contrast: for k in 0 ..< 3 { rgb[k] = (rgb[k] - 0.5) * v + 0.5 }
		case .Invert: for k in 0 ..< 3 { rgb[k] = rgb[k] * (1 - v) + (1 - rgb[k]) * v }
		case .Opacity: a *= v
		case .Grayscale:
			m := 1 - v
			rgb = {
				(0.2126 + 0.7874 * m) * rgb[0] + (0.7152 - 0.7152 * m) * rgb[1] + (0.0722 - 0.0722 * m) * rgb[2],
				(0.2126 - 0.2126 * m) * rgb[0] + (0.7152 + 0.2848 * m) * rgb[1] + (0.0722 - 0.0722 * m) * rgb[2],
				(0.2126 - 0.2126 * m) * rgb[0] + (0.7152 - 0.7152 * m) * rgb[1] + (0.0722 + 0.9278 * m) * rgb[2],
			}
		case .Sepia:
			m := 1 - v
			rgb = {
				(0.393 + 0.607 * m) * rgb[0] + (0.769 - 0.769 * m) * rgb[1] + (0.189 - 0.189 * m) * rgb[2],
				(0.349 - 0.349 * m) * rgb[0] + (0.686 + 0.314 * m) * rgb[1] + (0.168 - 0.168 * m) * rgb[2],
				(0.272 - 0.272 * m) * rgb[0] + (0.534 - 0.534 * m) * rgb[1] + (0.131 + 0.869 * m) * rgb[2],
			}
		case .Saturate:
			rgb = {
				(0.213 + 0.787 * v) * rgb[0] + (0.715 - 0.715 * v) * rgb[1] + (0.072 - 0.072 * v) * rgb[2],
				(0.213 - 0.213 * v) * rgb[0] + (0.715 + 0.285 * v) * rgb[1] + (0.072 - 0.072 * v) * rgb[2],
				(0.213 - 0.213 * v) * rgb[0] + (0.715 - 0.715 * v) * rgb[1] + (0.072 + 0.928 * v) * rgb[2],
			}
		case .Hue_Rotate:
			ang := op.amount * math.PI / 180
			cs, sn := f32(math.cos(ang)), f32(math.sin(ang))
			rgb = {
				(0.213 + cs * 0.787 - sn * 0.213) * rgb[0] + (0.715 - cs * 0.715 - sn * 0.715) * rgb[1] + (0.072 - cs * 0.072 + sn * 0.928) * rgb[2],
				(0.213 - cs * 0.213 + sn * 0.143) * rgb[0] + (0.715 + cs * 0.285 + sn * 0.140) * rgb[1] + (0.072 - cs * 0.072 - sn * 0.283) * rgb[2],
				(0.213 - cs * 0.213 - sn * 0.787) * rgb[0] + (0.715 - cs * 0.715 + sn * 0.715) * rgb[1] + (0.072 + cs * 0.928 + sn * 0.072) * rgb[2],
			}
		}
		_ = lum
		for k in 0 ..< 3 { rgb[k] = clamp(rgb[k], 0, 1) }
		store_f(layer.pix, i * 4, {rgb[0] * a, rgb[1] * a, rgb[2] * a, a})
	}
}

_ :: strconv
