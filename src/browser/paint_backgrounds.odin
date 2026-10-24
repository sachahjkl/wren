package browser

import "core:math"
import "wb:dom"
import "toolkit:draw"
import "wb:style"

////////////////////////////////
// Backgrounds (CSS Backgrounds 3 §3) and box shadows (§7).
//
// Every layer of background-image is painted, bottom layer first, each with its own origin, clip, size, position and
// repeat. Gradients (CSS Images 4) are one primitive each, evaluated by the toolkit's shader: linear, radial and conic,
// repeating or not, stop positions and transition hints, the interpolation color space (`in oklch longer hue`...),
// tiled over the clip area and cut to its rounded corners. url() layers are painted by the image code. Shadows are the
// toolkit's analytic gaussian of the shadow shape (exact), outer ones cut out of the border box.

// The three boxes of a box and their corner radii (draw order: top-left, bottom-left, top-right, bottom-right).
Bg_Boxes :: struct {
	border, padding, content: draw.Rect,
	border_radii, padding_radii, content_radii: [4]f32,
}

// `widths` and `pad`: top, right, bottom, left (device px).
bg_boxes :: proc(border: draw.Rect, radii: [4]f32, widths, pad: [4]f32) -> Bg_Boxes {
	b := Bg_Boxes{border = border, border_radii = radii}
	b.padding = draw.Rect{border.min + {widths[3], widths[0]}, border.max - {widths[1], widths[2]}}
	b.content = draw.Rect{b.padding.min + {pad[3], pad[0]}, b.padding.max - {pad[1], pad[2]}}
	b.padding_radii = padding_radii(radii, widths)
	b.content_radii = padding_radii(b.padding_radii, pad)
	return b
}

@(private)
area_of :: proc(b: ^Bg_Boxes, a: style.Box_Area) -> (draw.Rect, [4]f32) {
	switch a {
	case .Border_Box: return b.border, b.border_radii
	case .Padding_Box: return b.padding, b.padding_radii
	case .Content_Box, .Text: return b.content, b.content_radii
	}
	return b.border, b.border_radii
}

// Gradients dither (against banding) unless render.gradients.dither is off.
gradient_dither := true

// Background color and every background-image layer of `cs`, bottom first. The color is clipped like the bottom layer
// (CSS Backgrounds §3.10).
paint_backgrounds :: proc(dc: ^draw.Context, cs: ^style.Computed, b: ^Bg_Boxes, scale: f32, doc: ^dom.Document = nil) {
	layers := style.background_layers(cs)
	if cs.background_color.a > 0 {
		clip, radii := area_of(b, layers[len(layers) - 1].clip)
		col := to_draw(cs.background_color)
		draw.rect_corners(dc, clip, {col, col, col, col}, radii)
	}
	for i := len(layers) - 1; i >= 0; i -= 1 {
		layer := &layers[i]
		pos_area, _ := area_of(b, layer.origin)
		clip, radii := area_of(b, layer.clip)
		paint_image_layer(dc, layer, pos_area, clip, radii, scale)
	}
	// -wren-shader (built-in pages): over the CSS background, which is also what shows where the shader cannot be had
	if cs.wren_shader.name != "" {
		clip, radii := area_of(b, layers[len(layers) - 1].clip)
		paint_wren_shader(dc, cs, clip, radii, scale, doc)
	}
}

// One image layer (a background layer, or a mask layer as one) in its positioning area, painted inside `clip`
// (rounded by `radii`).
paint_image_layer :: proc(dc: ^draw.Context, layer: ^style.Bg_Layer, pos_area, clip: draw.Rect, radii: [4]f32, scale: f32) {
	switch layer.image.kind {
	case .None:
	case .Gradient: paint_gradient_layer(dc, layer, pos_area, clip, radii, scale)
	case .Url: images_paint_background_layer(dc, layer, pos_area, clip, radii, scale)
	}
}

// Whether a box paints a background-image layer the compositor cannot record (an image, which may be animated or
// still decoding).
background_has_url :: proc(cs: ^style.Computed) -> bool {
	for im in cs.background_images { if im.kind == .Url { return true } }
	return false
}

// Tile size of an image without intrinsic size (a gradient) in a positioning area of w x h (CSS Backgrounds §3.9).
@(private = "file")
gradient_tile_size :: proc(sz: style.Bg_Size, w, h, scale: f32) -> draw.Vec2 {
	switch sz.kind {
	case .Auto, .Cover, .Contain: return {w, h}
	case .Length:
		tw := sz.w.kind == .Auto ? w : style.resolve(sz.w, w / scale) * scale
		th := sz.h.kind == .Auto ? h : style.resolve(sz.h, h / scale) * scale
		return {tw, th}
	}
	return {w, h}
}

@(private = "file")
paint_gradient_layer :: proc(dc: ^draw.Context, layer: ^style.Bg_Layer, area, clip: draw.Rect, radii: [4]f32, scale: f32) {
	g := layer.image.grad
	if g == nil || len(g.stops) == 0 { return }
	aw, ah := area.max.x - area.min.x, area.max.y - area.min.y
	if aw <= 0 || ah <= 0 || clip.max.x <= clip.min.x || clip.max.y <= clip.min.y { return }
	ts := gradient_tile_size(layer.size, aw, ah, scale)
	rx, ry := layer.repeat[0], layer.repeat[1]
	if rx == .Round && ts.x > 0 { ts.x = aw / max(math.round(aw / ts.x), 1) }
	if ry == .Round && ts.y > 0 { ts.y = ah / max(math.round(ah / ts.y), 1) }
	if ts.x < 0.5 || ts.y < 0.5 { return }
	ox := area.min.x + style.resolve(layer.position[0], (aw - ts.x) / scale) * scale
	oy := area.min.y + style.resolve(layer.position[1], (ah - ts.y) / scale) * scale
	spacing: draw.Vec2
	if rx == .Space {
		n := math.floor(aw / ts.x)
		if n >= 2 { spacing.x = (aw - n * ts.x) / (n - 1); ox = area.min.x } else { rx = .No_Repeat }
	}
	if ry == .Space {
		n := math.floor(ah / ts.y)
		if n >= 2 { spacing.y = (ah - n * ts.y) / (n - 1); oy = area.min.y } else { ry = .No_Repeat }
	}
	dg := gradient_geometry(g, ts, scale)
	dg.tile = draw.Rect{{ox, oy}, {ox + ts.x, oy + ts.y}}
	dg.repeat = {rx != .No_Repeat, ry != .No_Repeat}
	dg.spacing = spacing
	dg.dither = gradient_dither
	draw.gradient(dc, clip, dg, radii)
}

// A CSS gradient as the toolkit draws it, for a gradient box (tile) of `size` device px: geometry relative to the
// tile, stops along the gradient line (linear), the ray (radial) or the turn (conic).
gradient_geometry :: proc(g: ^style.Gradient, size: draw.Vec2, scale: f32) -> draw.Gradient {
	w, h := size.x, size.y
	out := draw.Gradient{repeating = g.repeating, hue = draw.Hue_Method(g.hue)}
	switch g.space {
	case .Default, .Srgb: out.space = .Srgb
	case .Srgb_Linear, .Xyz: out.space = .Linear   // XYZ is a linear map of linear sRGB: the same interpolation
	case .Oklab: out.space = .Oklab
	case .Oklch: out.space = .Oklch
	case .Lab: out.space = .Lab
	case .Lch: out.space = .Lch
	case .Hsl: out.space = .Hsl
	case .Hwb: out.space = .Hwb
	}
	line: f32   // CSS px along which stop lengths are resolved
	switch g.kind {
	case .Linear:
		out.kind = .Linear
		a := style.gradient_angle(g, w, h)
		length := style.gradient_line_length(a, w, h)
		dir := draw.Vec2{math.sin(a), -math.cos(a)}
		c := draw.Vec2{w, h} * 0.5
		out.start, out.end = c - dir * length * 0.5, c + dir * length * 0.5
		line = length / scale
	case .Radial:
		out.kind = .Radial
		c := draw.Vec2{style.resolve(g.position[0], w / scale) * scale, style.resolve(g.position[1], h / scale) * scale}
		out.center = c
		sx_near, sy_near := min(c.x, w - c.x), min(c.y, h - c.y)
		sx_far, sy_far := max(c.x, w - c.x), max(c.y, h - c.y)
		r: draw.Vec2
		circle := g.shape == .Circle
		switch g.extent {
		case .Closest_Side: r = circle ? draw.Vec2{min(sx_near, sy_near), min(sx_near, sy_near)} : draw.Vec2{sx_near, sy_near}
		case .Farthest_Side: r = circle ? draw.Vec2{max(sx_far, sy_far), max(sx_far, sy_far)} : draw.Vec2{sx_far, sy_far}
		case .Closest_Corner:
			// the closest corner; an ellipse keeps the aspect ratio of closest-side
			d := math.sqrt(sx_near * sx_near + sy_near * sy_near)
			r = circle ? draw.Vec2{d, d} : draw.Vec2{sx_near, sy_near} * math.SQRT_TWO
		case .Farthest_Corner:
			d := math.sqrt(sx_far * sx_far + sy_far * sy_far)
			r = circle ? draw.Vec2{d, d} : draw.Vec2{sx_far, sy_far} * math.SQRT_TWO
		case .Explicit:
			if circle {
				v := style.resolve(g.radius[0], w / scale) * scale
				r = {v, v}
			} else {
				r = {style.resolve(g.radius[0], w / scale) * scale, style.resolve(g.radius[1], h / scale) * scale}
			}
		}
		// a degenerate ending shape is drawn as a very thin one (CSS Images 3 §3.2.1)
		r = {max(r.x, 0.001), max(r.y, 0.001)}
		out.radii = r
		line = r.x / scale
	case .Conic:
		out.kind = .Conic
		out.center = {style.resolve(g.position[0], w / scale) * scale, style.resolve(g.position[1], h / scale) * scale}
		out.angle = g.angle
		line = 1   // stop positions are fractions of a turn
	}
	if line <= 0 { line = 0.001 }
	rs := style.gradient_stops(g, line, context.temp_allocator)
	stops := make([dynamic]draw.Gradient_Stop, 0, len(rs), context.temp_allocator)
	for s, i in rs {
		if s.hint {
			// a transition hint: where the two colors around it mix half and half, as a fraction of their interval
			if len(stops) == 0 || i + 1 >= len(rs) { continue }
			prev := &stops[len(stops) - 1]
			a, bpos := prev.pos * line, rs[i + 1].pos
			span := bpos - a
			prev.has_hint = true
			prev.hint = span > 0 ? clamp((s.pos - a) / span, 0, 1) : 0.5
			continue
		}
		append(&stops, draw.Gradient_Stop{color = to_draw(s.color), pos = s.pos / line})
	}
	out.stops = stops[:]
	return out
}

////////////////////////////////
// Box shadows

// CSS Backgrounds 3 §7.1: a radius grows with the spread, less for corners smaller than it (so a square corner stays
// square); a negative spread shrinks it.
@(private = "file")
spread_radius :: proc(r, spread: f32) -> f32 {
	if spread >= 0 {
		if r <= 0 { return 0 }
		if r >= spread { return r + spread }
		k := r / spread - 1
		return r + spread * (1 + k * k * k)
	}
	return max(r + spread, 0)
}

// The outer (inset = false) or inset box shadows of `cs`, bottom first. `r` is the border box, `radii` its radii;
// `pad` / `pad_radii` the padding box (inset shadows).
paint_box_shadows :: proc(dc: ^draw.Context, cs: ^style.Computed, r: draw.Rect, radii: [4]f32, pad: draw.Rect, pad_radii: [4]f32, scale: f32, inset: bool) {
	for i := len(cs.box_shadow) - 1; i >= 0; i -= 1 {
		s := cs.box_shadow[i]
		if s.inset != inset || s.color.a <= 0 { continue }
		col := to_draw(s.color)
		sigma := s.blur * 0.5 * scale   // CSS: the blur radius is twice the standard deviation
		spread := s.spread * scale
		off := draw.Vec2{s.x, s.y} * scale
		if !inset {
			shape := draw.rect_shift(draw.rect_pad(r, spread), off)
			if shape.max.x <= shape.min.x || shape.max.y <= shape.min.y { continue }
			sr: [4]f32
			for k in 0 ..< 4 { sr[k] = spread_radius(radii[k], spread) }
			draw.box_shadow(dc, shape, sr, sigma, col, r, radii)
		} else {
			hole := draw.rect_shift(draw.rect_pad(pad, -spread), off)
			hole.max = {max(hole.max.x, hole.min.x), max(hole.max.y, hole.min.y)}
			hr: [4]f32
			for k in 0 ..< 4 { hr[k] = spread_radius(pad_radii[k], -spread) }
			if hole.max.x <= hole.min.x || hole.max.y <= hole.min.y {
				// the hole closed: the whole padding box is in shadow
				draw.rect_corners(dc, pad, {col, col, col, col}, pad_radii)
				continue
			}
			draw.inset_shadow(dc, pad, pad_radii, hole, hr, sigma, col)
		}
	}
}

