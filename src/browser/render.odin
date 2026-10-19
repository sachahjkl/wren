// Document painter: draws the display list of package layout with toolkit:draw. Layout decides what goes where and in
// which order (CSS 2.1 Appendix E), under which clip, scroll offset, sticky shift, transform and opacity group; the
// effects section below maps those onto draw's transform / clip / layer stacks; the rest of this file turns each item
// into rectangles and glyphs: backgrounds (colors, linear gradients), borders of every style with rounded corners,
// box shadows, outlines, text with decorations, spacing and shadows, list markers, scroll bars, and the content of form
// controls and replaced elements (through a hook other parts of the browser install).
package browser

import "core:math"
import "core:strings"
import "core:unicode/utf8"
import "toolkit:draw"
import "toolkit:font"
import "wb:base"
import "wb:config"
import "wb:css"
import "wb:dom"
import lay "wb:layout"
import "wb:style"

Layout :: lay.Layout

// Paints the content area of a form control or a replaced element (image, canvas...). Returns false to let the default
// painter draw it. `content` and `border` are in physical pixels of the window.
Content_Painter :: proc(user: rawptr, dc: ^draw.Context, doc: ^dom.Document, node: base.Handle, kind: lay.Item_Kind,
	content, border: draw.Rect, cs: ^style.Computed, font_id: font.Font_Id, font_size: f32) -> bool

Page_Render :: struct {
	fonts:      Page_Fonts,
	settings:   lay.Settings,
	content:    Content_Painter,
	content_user: rawptr,
	bare:       proc(user: rawptr, doc: ^dom.Document, node: base.Handle) -> bool,   // controls drawn entirely by `content` (no box)
	replaced:   lay.Replaced_Api,   // natural sizes of images / videos, from whoever decodes them
	gradients:  map[string]^Gradient,
	watch_layout, watch_font: int,
}

page_render: Page_Render

// Shell start-up: the fonts of pages and the layout preferences.
page_render_init :: proc(app: ^App) {
	page_fonts_init(&page_render.fonts, &app.fonts, app.ui_font)
	page_render.settings = lay.settings_from_prefs(&app.prefs)
	page_render.gradients = make(map[string]^Gradient)
	render_settings_init(app)
	effects_init(app)
	page_render.watch_layout = config.watch(&app.prefs, "layout.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		page_render.settings = lay.settings_from_prefs(p)
		for t in (^App)(user).tabs { t.layout.valid = false }
	}, app)
	page_render.watch_font = config.watch(&app.prefs, "font.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		page_fonts_forget(&page_render.fonts)
	}, app)
}

page_render_destroy :: proc() {
	page_fonts_destroy(&page_render.fonts)
	for k, g in page_render.gradients { delete(k); delete(g.stops); free(g) }
	delete(page_render.gradients)
}

// Installs the painter of form controls / replaced content (forms, images).
set_content_painter :: proc(fn: Content_Painter, user: rawptr) {
	page_render.content, page_render.content_user = fn, user
}

// Installs the source of natural sizes of replaced content (decoded images...). A change of size needs a new layout:
// set `layout.valid = false` on the tabs concerned.
set_replaced_sizes :: proc(api: lay.Replaced_Api) { page_render.replaced = api }

register_layout_prefs :: proc(p: ^config.Prefs) { lay.register_prefs(p) }

layout_reset :: proc(l: ^Layout) { lay.reset(l) }
layout_destroy :: proc(l: ^Layout) { lay.destroy(l) }

// `viewport`: size of the page area in physical pixels; `scale`: physical pixels per CSS px. `images_gen` /
// `fonts_gen`: change counters of the natural sizes of images and of the page's web fonts (lay.Input).
layout_document :: proc(l: ^Layout, d: ^dom.Document, styled: ^style.Styled, measure: ^Measure, style_settings: ^style.Settings, viewport: draw.Vec2, scale, band_h: f32, images_gen: u64 = 0, fonts_gen: u64 = 0) {
	lay.run(l, lay.Input{
		doc = d, styled = styled, settings = &page_render.settings,
		text = page_text_api(&page_render.fonts, measure, style_settings),
		replaced = page_render.replaced,
		viewport = viewport, scale = scale, band_h = band_h,
		images_generation = images_gen, fonts_generation = fonts_gen,
	})
}

layout_stale :: proc(l: ^Layout, d: ^dom.Document, styled: ^style.Styled, viewport: draw.Vec2, scale: f32, images_gen: u64 = 0, fonts_gen: u64 = 0) -> bool {
	return !l.valid || l.mutations != d.mutations || l.serial != styled.serial || l.viewport != viewport || l.scale != scale ||
		l.inc.images_gen != images_gen || l.inc.fonts_gen != fonts_gen
}

// Element under a point of the page area (`p` relative to its top-left corner).
hit_test :: proc(l: ^Layout, p, viewport: draw.Vec2, scroll: f32) -> base.Handle {
	return lay.hit_test(l, p, viewport, scroll).node
}

// Wheel over the page: scroll containers under the pointer first. false: the page itself should scroll.
page_wheel :: proc(l: ^Layout, p, delta, viewport: draw.Vec2, scroll: f32) -> bool {
	if !l.valid { return false }
	return lay.scroll_wheel(l, p, delta, viewport, scroll)
}

// CSS colors are sRGB; draw takes linear colors and mixes them in the renderer's blend space (render.blend_space).
to_draw :: proc(c: css.Color) -> draw.Color { return draw.srgb(c.r, c.g, c.b, c.a) }

// Two CSS colors interpolated as CSS does by default (Color 4 §12, Images 4 §3.5): premultiplied, on sRGB values.
mix_css :: proc(a, b: css.Color, t: f32) -> draw.Color {
	alpha := a.a + (b.a - a.a) * t
	if alpha <= 0 { return {0, 0, 0, 0} }
	pa, pb := [3]f32{a.r, a.g, a.b} * a.a, [3]f32{b.r, b.g, b.b} * b.a
	c := (pa + (pb - pa) * t) / alpha
	return to_draw(css.Color{c.r, c.g, c.b, alpha})
}

@(private = "file")
dr :: #force_inline proc(r: lay.Rect) -> draw.Rect { return draw.Rect{r.min, r.max} }

////////////////////////////////
// Painting

paint :: proc(l: ^Layout, dc: ^draw.Context, d: ^dom.Document, origin, size: draw.Vec2, scroll: f32, clip: draw.Rect) {
	if !l.valid { return }
	v := lay.view_make(l, size, scroll)
	// CSS border-radius draws circular arcs, not the squircle of the browser's own UI
	circular := draw.set_circular_corners(dc, true)
	defer draw.set_circular_corners(dc, circular)
	// gradients interpolate on sRGB values whatever the blend space (CSS: `in srgb` is the default)
	interp := draw.set_interpolation(dc, .Srgb)
	defer draw.set_interpolation(dc, interp)
	fx := effects_make(l, &v, dc, origin)
	for idx in v.visible {
		it := &l.items[idx]
		if !effects_for(&fx, it) { continue }
		off := v.offsets[it.space] + origin
		r := draw.rect_shift(dr(it.rect), off)
		selection_paint_under(l, dc, it, r)
		defer selection_paint_over(l, dc, it, r)
		switch it.kind {
		case .Box:
			if page_render.bare != nil && page_render.bare(page_render.content_user, d, it.node) { continue }
			paint_box(l, dc, it, r)
		case .Inline_Box: paint_inline_box(l, dc, it, r)
		case .Text: paint_text(l, dc, it, r, off)
		case .Marker: paint_marker(l, dc, it, r, off)
		case .Replaced, .Control: paint_content(l, dc, d, it, r, off)
		case .Outline: paint_outline(l, dc, it, r)
		case .Scrollbar:
			track := r
			if page_render.settings.scrollbar_track.a > 0 { draw.rect(dc, track, to_draw(page_render.settings.scrollbar_track), min(track.max.x - track.min.x, track.max.y - track.min.y) * 0.5) }
			th := draw.rect_shift(dr(lay.scrollbar_thumb(l, &v, it)), origin)
			draw.rect(dc, th, to_draw(page_render.settings.scrollbar_thumb), min(th.max.x - th.min.x, th.max.y - th.min.y) * 0.5)
		}
	}
	effects_end(&fx)
	if track, thumb, ok := lay.doc_scrollbar(l, size, scroll); ok {
		if page_render.settings.scrollbar_track.a > 0 { draw.rect(dc, draw.rect_shift(dr(track), origin), to_draw(page_render.settings.scrollbar_track), (track.max.x - track.min.x) * 0.5) }
		draw.rect(dc, draw.rect_shift(dr(thumb), origin), to_draw(page_render.settings.scrollbar_thumb), (thumb.max.x - thumb.min.x) * 0.5)
	}
}

// Corner radii (draw order: top-left, bottom-left, top-right, bottom-right), reduced so adjacent ones fit (CSS
// Backgrounds §5.5).
@(private = "file")
corner_radii :: proc(cs: ^style.Computed, r: draw.Rect, scale: f32) -> [4]f32 {
	return lay.border_radii(cs, r.max.x - r.min.x, r.max.y - r.min.y, scale)
}

@(private = "file")
no_radius :: proc(r: [4]f32) -> bool { return r == {0, 0, 0, 0} }

@(private = "file")
paint_shadows :: proc(dc: ^draw.Context, cs: ^style.Computed, r: draw.Rect, radii: [4]f32, scale: f32, inset: bool) {
	for i := len(cs.box_shadow) - 1; i >= 0; i -= 1 {
		s := cs.box_shadow[i]
		if s.inset != inset || s.color.a <= 0 { continue }
		col := to_draw(s.color)
		blur := s.blur * scale
		spread := s.spread * scale
		off := draw.Vec2{s.x, s.y} * scale
		rad := max(radii[0], radii[1], radii[2], radii[3])
		if !inset {
			sr := draw.rect_shift(draw.rect_pad(r, spread), off)
			if blur > 2 {
				draw.rect(dc, draw.rect_pad(sr, blur * 0.5), col, rad + spread + blur * 0.5, 0, blur * 0.5)
			} else {
				draw.rect_corners(dc, sr, {col, col, col, col}, radii + spread, 0)
			}
		} else if effects_settings.exact_shadows {
			paint_inset_shadow(dc, col, r, radii, off, spread, blur)
		} else {
			// inside the padding edge: a soft ring (approximation of the inner shadow's falloff)
			w := max(spread + blur * 0.5, 1)
			ir := draw.rect_shift(r, off)
			draw.rect(dc, ir, col, rad, w)
		}
	}
}

@(private = "file")
paint_box :: proc(l: ^Layout, dc: ^draw.Context, it: ^lay.Display_Item, r: draw.Rect) {
	cs := it.cs
	if cs == nil { return }
	b := &l.boxes[it.box]
	radii := corner_radii(cs, r, l.scale)
	if len(cs.box_shadow) > 0 { paint_shadows(dc, cs, r, radii, l.scale, false) }
	if .No_Background not_in it.flags {
		if cs.background_color.a > 0 {
			col := to_draw(cs.background_color)
			draw.rect_corners(dc, r, {col, col, col, col}, radii)
		}
		if cs.background_image.kind == .Gradient { paint_gradient(dc, cs.background_image.gradient, r, radii, l.scale) }
		images_paint_backgrounds(dc, cs, r, b.border, b.padding, radii, l.scale)
	}
	if len(cs.box_shadow) > 0 {
		pr := draw.Rect{r.min + {b.border[3], b.border[0]}, r.max - {b.border[1], b.border[2]}}
		paint_shadows(dc, cs, pr, padding_radii(radii, b.border), l.scale, true)
	}
	widths := [4]f32{b.border[0], b.border[1], b.border[2], b.border[3]}
	if widths != {} { paint_borders(dc, r, widths, cs.border_style, cs.border_color, radii) }
}

@(private = "file")
paint_inline_box :: proc(l: ^Layout, dc: ^draw.Context, it: ^lay.Display_Item, r: draw.Rect) {
	cs := it.cs
	if cs == nil { return }
	b := &l.boxes[it.box]
	radii := corner_radii(cs, r, l.scale)
	// a box split over lines keeps its rounded corners only where it starts and ends
	if .Left_Edge not_in it.flags { radii[0], radii[1] = 0, 0 }
	if .Right_Edge not_in it.flags { radii[2], radii[3] = 0, 0 }
	if len(cs.box_shadow) > 0 { paint_shadows(dc, cs, r, radii, l.scale, false) }
	if cs.background_color.a > 0 {
		col := to_draw(cs.background_color)
		draw.rect_corners(dc, r, {col, col, col, col}, radii)
	}
	if cs.background_image.kind == .Gradient { paint_gradient(dc, cs.background_image.gradient, r, radii, l.scale) }
	widths := [4]f32{b.border[0], .Right_Edge in it.flags ? b.border[1] : 0, b.border[2], .Left_Edge in it.flags ? b.border[3] : 0}
	if widths != {} { paint_borders(dc, r, widths, cs.border_style, cs.border_color, radii) }
}

@(private = "file")
shade :: proc(c: css.Color, f: f32) -> draw.Color {
	if f < 1 { return to_draw(css.Color{c.r * f, c.g * f, c.b * f, c.a}) }
	t := f - 1
	return to_draw(css.Color{c.r + (1 - c.r) * t, c.g + (1 - c.g) * t, c.b + (1 - c.b) * t, c.a})
}

// Borders (CSS Backgrounds §4): one rounded ring when all sides agree, otherwise side by side, each in its style.
// Rounded corners with sides that differ are drawn square.
@(private = "file")
paint_borders :: proc(dc: ^draw.Context, r: draw.Rect, w: [4]f32, styles: [style.Side]style.Border_Style, colors: [style.Side]css.Color, radii: [4]f32) {
	sides := [4]style.Side{.Top, .Right, .Bottom, .Left}
	uniform := true
	for s, i in sides {
		if w[i] != w[0] || styles[s] != styles[.Top] || colors[s] != colors[.Top] { uniform = false }
	}
	if uniform && styles[.Top] == .Solid && w[0] > 0 {
		col := to_draw(colors[.Top])
		draw.rect_corners(dc, r, {col, col, col, col}, radii, w[0])
		return
	}
	if uniform && styles[.Top] == .Double && w[0] >= 3 {
		col := to_draw(colors[.Top])
		t := w[0] / 3
		draw.rect_corners(dc, r, {col, col, col, col}, radii, t)
		inner := draw.rect_pad(r, -2 * t)
		draw.rect_corners(dc, inner, {col, col, col, col}, {max(radii[0] - 2 * t, 0), max(radii[1] - 2 * t, 0), max(radii[2] - 2 * t, 0), max(radii[3] - 2 * t, 0)}, t)
		return
	}
	if !no_radius(radii) && solid_sides(w, styles) {
		paint_rounded_sides(dc, r, w, styles, colors, radii)
		return
	}
	for s, i in sides {
		bw := w[i]
		if bw <= 0 { continue }
		st := styles[s]
		if st == .None || st == .Hidden { continue }
		c := colors[s]
		if c.a <= 0 { continue }
		// the strip of this side; top and bottom own the corners
		strip: draw.Rect
		switch s {
		case .Top: strip = {r.min, {r.max.x, r.min.y + bw}}
		case .Bottom: strip = {{r.min.x, r.max.y - bw}, r.max}
		case .Left: strip = {{r.min.x, r.min.y + w[0]}, {r.min.x + bw, r.max.y - w[2]}}
		case .Right: strip = {{r.max.x - bw, r.min.y + w[0]}, {r.max.x, r.max.y - w[2]}}
		}
		horizontal := s == .Top || s == .Bottom
		outer_first := s == .Top || s == .Left   // the outer half of the strip comes first along its thickness
		switch st {
		case .None, .Hidden:
		case .Solid: draw.rect(dc, strip, to_draw(c))
		case .Dashed, .Dotted:
			dot := st == .Dotted
			seg := dot ? bw : max(bw * 3, 2)
			gap := dot ? bw : max(bw * 2, 2)
			length := horizontal ? strip.max.x - strip.min.x : strip.max.y - strip.min.y
			n := max(int((length + gap) / (seg + gap)), 1)
			// stretch the gaps so the pattern ends on a dash
			g := n > 1 ? (length - f32(n) * seg) / f32(n - 1) : 0
			col := to_draw(c)
			for k in 0 ..< n {
				p := f32(k) * (seg + g)
				piece := horizontal ? draw.Rect{{strip.min.x + p, strip.min.y}, {min(strip.min.x + p + seg, strip.max.x), strip.max.y}} : draw.Rect{{strip.min.x, strip.min.y + p}, {strip.max.x, min(strip.min.y + p + seg, strip.max.y)}}
				draw.rect(dc, piece, col, dot ? bw * 0.5 : 0)
			}
		case .Double:
			t := max(bw / 3, 1)
			col := to_draw(c)
			if horizontal {
				draw.rect(dc, {strip.min, {strip.max.x, strip.min.y + t}}, col)
				draw.rect(dc, {{strip.min.x, strip.max.y - t}, strip.max}, col)
			} else {
				draw.rect(dc, {strip.min, {strip.min.x + t, strip.max.y}}, col)
				draw.rect(dc, {{strip.max.x - t, strip.min.y}, strip.max}, col)
			}
		case .Groove, .Ridge:
			dark, light := shade(c, 0.55), shade(c, 1.35)
			a, b := dark, light
			if st == .Ridge { a, b = light, dark }
			if !outer_first { a, b = b, a }
			if horizontal {
				mid := (strip.min.y + strip.max.y) * 0.5
				draw.rect(dc, {strip.min, {strip.max.x, mid}}, a)
				draw.rect(dc, {{strip.min.x, mid}, strip.max}, b)
			} else {
				mid := (strip.min.x + strip.max.x) * 0.5
				draw.rect(dc, {strip.min, {mid, strip.max.y}}, a)
				draw.rect(dc, {{mid, strip.min.y}, strip.max}, b)
			}
		case .Inset, .Outset:
			dark := (st == .Inset) == outer_first
			draw.rect(dc, strip, dark ? shade(c, 0.55) : shade(c, 1.2))
		}
	}
}

@(private = "file")
solid_sides :: proc(w: [4]f32, styles: [style.Side]style.Border_Style) -> bool {
	sides := [4]style.Side{.Top, .Right, .Bottom, .Left}
	for s, i in sides {
		if w[i] > 0 && styles[s] != .Solid && styles[s] != .None && styles[s] != .Hidden { return false }
	}
	return true
}

// Rounded solid borders whose sides differ (a spinner: one colored side): each side is the rounded ring in its own
// color and width, cut to its wedge. Sides meet on the line from each outer corner to the inner one (CSS Backgrounds
// §4.4), made of two half-plane clips per side (rotated rect clips, exact and antialiased in draw).
@(private = "file")
paint_rounded_sides :: proc(dc: ^draw.Context, r: draw.Rect, w: [4]f32, styles: [style.Side]style.Border_Style, colors: [style.Side]css.Color, radii: [4]f32) {
	sides := [4]style.Side{.Top, .Right, .Bottom, .Left}
	big := max(r.max.x - r.min.x, r.max.y - r.min.y) * 2 + 16
	// the four corner lines: outer corner -> inner corner (top-left, top-right, bottom-right, bottom-left)
	outer := [4]draw.Vec2{r.min, {r.max.x, r.min.y}, r.max, {r.min.x, r.max.y}}
	inner := [4]draw.Vec2{r.min + {w[3], w[0]}, {r.max.x - w[1], r.min.y + w[0]}, r.max - {w[1], w[2]}, {r.min.x + w[3], r.max.y - w[2]}}
	// keeps the side of the line from outer[k] to inner[k] where cross(d, p - a) has sign `sign`
	half_plane :: proc(dc: ^draw.Context, a, b: draw.Vec2, sign: f32, big: f32) {
		d := b - a
		n := math.sqrt(d.x * d.x + d.y * d.y)
		d = n > 1e-6 ? d / n : draw.Vec2{1, 0}
		// frame: x along d, y along (-d.y, d.x): local y = cross(d, p - a)
		draw.push_transform(dc, draw.Affine{d.x, d.y, -d.y, d.x, a.x, a.y})
		// each wedge reaches 0.75 px past its line: two antialiased edges meeting exactly would let the background
		// show through the seam
		draw.push_clip(dc, sign < 0 ? draw.Rect{{-big, -big}, {big, 0.75}} : draw.Rect{{-big, -0.75}, {big, big}})
		draw.pop_transform(dc)
	}
	for s, i in sides {
		if w[i] <= 0 || styles[s] != .Solid || colors[s].a <= 0 { continue }
		// side i lies between corner lines i and i + 1 (top: top-left and top-right, right: top-right and bottom-right...)
		k0, k1 := i, (i + 1) % 4
		half_plane(dc, outer[k0], inner[k0], -1, big)
		half_plane(dc, outer[k1], inner[k1], 1, big)
		col := to_draw(colors[s])
		draw.rect_corners(dc, r, {col, col, col, col}, radii, w[i])
		draw.pop_clip(dc)
		draw.pop_clip(dc)
	}
}

@(private = "file")
paint_outline :: proc(l: ^Layout, dc: ^draw.Context, it: ^lay.Display_Item, r: draw.Rect) {
	cs := it.cs
	if cs == nil || cs.outline_width <= 0 { return }
	w := max(1, math.floor(cs.outline_width * l.scale + 0.001))
	o := draw.rect_pad(r, cs.outline_offset * l.scale + w)
	st := cs.outline_style
	if st == .None || st == .Hidden { return }
	styles := [style.Side]style.Border_Style{.Top = st, .Right = st, .Bottom = st, .Left = st}
	colors := [style.Side]css.Color{.Top = cs.outline_color, .Right = cs.outline_color, .Bottom = cs.outline_color, .Left = cs.outline_color}
	radii := corner_radii(cs, r, l.scale)
	if !no_radius(radii) { radii += w + cs.outline_offset * l.scale }
	paint_borders(dc, o, {w, w, w, w}, styles, colors, radii)
}

////////////////////////////////
// Text

@(private = "file")
draw_run :: proc(l: ^Layout, dc: ^draw.Context, fid: font.Font_Id, size: f32, pos: draw.Vec2, col: draw.Color, text: string, ls, ws, extra: f32) {
	if ls == 0 && ws == 0 && extra == 0 {
		draw.text(dc, fid, size, pos, col, text)
		return
	}
	// spacing: glyph by glyph (letter-spacing), space by space (word-spacing, justification)
	pen := pos.x
	if ls == 0 {
		rest := text
		for len(rest) > 0 {
			i := strings.index_byte(rest, ' ')
			piece := i < 0 ? rest : rest[:i + 1]
			pen += draw.text(dc, fid, size, {pen, pos.y}, col, piece)
			if i < 0 { break }
			pen += ws + extra
			rest = rest[i + 1:]
		}
		return
	}
	for i := 0; i < len(text); {
		_, n := utf8.decode_rune_in_string(text[i:])
		piece := text[i:i + n]
		pen += draw.text(dc, fid, size, {pen, pos.y}, col, piece) + ls
		if piece == " " { pen += ws + extra }
		i += n
	}
}

@(private = "file")
paint_text :: proc(l: ^Layout, dc: ^draw.Context, it: ^lay.Display_Item, r: draw.Rect, off: draw.Vec2) {
	cs := it.cs
	fi := lay.item_font(l, it)
	if cs == nil || fi == nil || it.text == "" { return }
	fid := font.Font_Id(fi.font)
	baseline := it.baseline + off.y
	ls := cs.letter_spacing * l.scale
	ws := cs.word_spacing * l.scale
	for i := len(cs.text_shadow) - 1; i >= 0; i -= 1 {
		s := cs.text_shadow[i]
		if s.color.a <= 0 { continue }
		col := to_draw(s.color)
		pos := draw.Vec2{r.min.x + s.x * l.scale, baseline + s.y * l.scale}
		if s.blur > 0 && effects_settings.exact_shadows {
			// a gaussian of half the blur radius (CSS Backgrounds §7.2), through a layer
			ink := draw.rect_pad(draw.rect_shift(r, {s.x, s.y} * l.scale), fi.size * 0.5)
			draw.push_effects(dc, ink, draw.Layer_Effects{alpha = 1, filters = {draw.filter_blur(s.blur * 0.5 * l.scale)}})
			draw_run(l, dc, fid, fi.size, pos, col, it.text, ls, ws, it.extra)
			draw.pop_layer(dc)
			continue
		}
		if s.blur > 0 { col.a *= 0.6 }
		draw_run(l, dc, fid, fi.size, pos, col, it.text, ls, ws, it.extra)
	}
	col := to_draw(cs.color)
	draw_run(l, dc, fid, fi.size, {r.min.x, baseline}, col, it.text, ls, ws, it.extra)
	if it.deco != {} {
		dcol := to_draw(it.deco_color)
		if it.deco_color.a == 0 { dcol = col }
		t := max(1, math.round(fi.size / 15))
		if .Underline in it.deco {
			y := math.round(baseline + max(fi.descent * 0.35, 1))
			draw.rect(dc, {{r.min.x, y}, {r.max.x, y + t}}, dcol)
		}
		if .Overline in it.deco {
			y := math.round(baseline - fi.ascent)
			draw.rect(dc, {{r.min.x, y}, {r.max.x, y + t}}, dcol)
		}
		if .Line_Through in it.deco {
			y := math.round(baseline - fi.x_height * 0.5 - t * 0.5)
			draw.rect(dc, {{r.min.x, y}, {r.max.x, y + t}}, dcol)
		}
	}
}

@(private = "file")
paint_marker :: proc(l: ^Layout, dc: ^draw.Context, it: ^lay.Display_Item, r: draw.Rect, off: draw.Vec2) {
	cs := it.cs
	fi := lay.item_font(l, it)
	if cs == nil || fi == nil { return }
	col := to_draw(cs.color)
	baseline := it.baseline + off.y
	if it.text != "" {
		draw.text(dc, font.Font_Id(fi.font), fi.size, {r.min.x, baseline}, col, it.text)
		return
	}
	s := r.max.x - r.min.x
	cy := baseline - fi.x_height * 0.5
	sq := draw.Rect{{r.min.x, cy - s * 0.5}, {r.min.x + s, cy + s * 0.5}}
	#partial switch cs.list_style_type {
	case .Disc: draw.rect(dc, sq, col, s * 0.5)
	case .Circle: draw.rect(dc, sq, col, s * 0.5, max(1, s * 0.18))
	case .Square: draw.rect(dc, sq, col)
	}
}

////////////////////////////////
// Replaced content and form controls

@(private = "file")
paint_content :: proc(l: ^Layout, dc: ^draw.Context, d: ^dom.Document, it: ^lay.Display_Item, r: draw.Rect, off: draw.Vec2) {
	b := &l.boxes[it.box]
	border := draw.rect_shift(draw.Rect{b.abs, b.abs + b.size}, off)
	fi := lay.item_font(l, it)
	fid := fi != nil ? font.Font_Id(fi.font) : font.Font_Id(0)
	size := fi != nil ? fi.size : 13
	if it.kind == .Replaced && images_paint_content(dc, d, it.node, r, border, it.cs, fid, size, l.scale) { return }
	if page_render.content != nil {
		if page_render.content(page_render.content_user, dc, d, it.node, it.kind, r, border, it.cs, fid, size) { return }
	}
	if it.kind != .Control || fi == nil || d == nil { return }
	default_control(l, dc, d, it, r, fi)
}

// What a control shows until the forms code paints it: its value, placeholder, checked state, selected option.
@(private = "file")
default_control :: proc(l: ^Layout, dc: ^draw.Context, d: ^dom.Document, it: ^lay.Display_Item, r: draw.Rect, fi: ^lay.Font_Info) {
	n := dom.get(d, it.node)
	if n == nil { return }
	cs := it.cs
	col := to_draw(cs.color)
	fid := font.Font_Id(fi.font)
	mid_base := (r.min.y + r.max.y) * 0.5 + (fi.ascent - fi.descent) * 0.5
	text_in :: proc(dc: ^draw.Context, fid: font.Font_Id, size: f32, r: draw.Rect, base: f32, col: draw.Color, s: string, center: bool, fonts: ^font.State) {
		if s == "" { return }
		x := r.min.x
		if center { x = (r.min.x + r.max.x - font.text_width(fonts, fid, size, s)) * 0.5 }
		draw.push_clip(dc, r)
		draw.text(dc, fid, size, {x, base}, col, s)
		draw.pop_clip(dc)
	}
	fonts := page_render.fonts.state
	switch n.name {
	case "input":
		t, _ := dom.get_attribute(d, it.node, "type")
		t = strings.to_lower(t, context.temp_allocator)
		_, checked := dom.get_attribute(d, it.node, "checked")
		switch t {
		case "checkbox":
			if checked { draw.rect(dc, draw.rect_pad(r, -max((r.max.x - r.min.x) * 0.22, 1)), col, 1) }
		case "radio":
			if checked { draw.rect(dc, draw.rect_pad(r, -max((r.max.x - r.min.x) * 0.28, 1)), col, (r.max.x - r.min.x) * 0.5) }
		case "button", "submit", "reset":
			label, ok := dom.get_attribute(d, it.node, "value")
			if !ok { label = t == "submit" ? "Submit" : (t == "reset" ? "Reset" : "") }
			text_in(dc, fid, fi.size, r, mid_base, col, label, true, fonts)
		case "range":
			track := draw.Rect{{r.min.x, (r.min.y + r.max.y) * 0.5 - 2}, {r.max.x, (r.min.y + r.max.y) * 0.5 + 2}}
			draw.rect(dc, track, draw.mix(col, {1, 1, 1, col.a}, 0.6), 2)
		case "color":
			v, _ := dom.get_attribute(d, it.node, "value")
			c := css.Color{0, 0, 0, 1}
			toks := css.tokenize(v, context.temp_allocator)
			vals := make([dynamic]css.Value, context.temp_allocator)
			for tk in toks { append(&vals, css.Value{kind = .Token, tok = tk}) }
			if cv, ok := css.parse_color(vals[:], nil); ok && cv.kind == .Rgba { c = cv.rgba }
			draw.rect(dc, draw.rect_pad(r, -2), to_draw(c))
		case:
			v, has := dom.get_attribute(d, it.node, "value")
			if t == "password" && has { v = strings.repeat("\u2022", strings.rune_count(v), context.temp_allocator) }
			if !has || v == "" {
				p, _ := dom.get_attribute(d, it.node, "placeholder")
				text_in(dc, fid, fi.size, r, mid_base, draw.mix(col, {0.5, 0.5, 0.5, col.a}, 0.6), p, false, fonts)
			} else {
				text_in(dc, fid, fi.size, r, mid_base, col, v, false, fonts)
			}
		}
	case "textarea":
		v := dom.text_content(d, it.node)
		y := r.min.y + (fi.line_h - (fi.ascent + fi.descent)) * 0.5 + fi.ascent
		draw.push_clip(dc, r)
		rest := v
		for line in strings.split_lines_iterator(&rest) {
			draw.text(dc, fid, fi.size, {r.min.x, y}, col, line)
			y += fi.line_h
			if y - fi.ascent > r.max.y { break }
		}
		draw.pop_clip(dc)
	case "select":
		label := ""
		first := ""
		stack := make([dynamic]base.Handle, 0, 8, context.temp_allocator)
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).prev { append(&stack, ch) }
		for len(stack) > 0 {
			x := pop(&stack)
			xn := dom.get(d, x)
			if xn == nil || xn.kind != .Element { continue }
			if xn.name == "optgroup" { for ch := xn.last_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).prev { append(&stack, ch) }; continue }
			if xn.name != "option" { continue }
			s := strings.trim_space(dom.text_content(d, x))
			if first == "" { first = s }
			if _, sel := dom.get_attribute(d, x, "selected"); sel && label == "" { label = s }
		}
		if label == "" { label = first }
		arrow := page_render.settings.select_arrow * l.scale
		text_in(dc, fid, fi.size, {r.min, {r.max.x - arrow, r.max.y}}, mid_base, col, label, false, fonts)
		// the arrow: a small chevron drawn with two strokes
		cx, cy := r.max.x - arrow * 0.5, (r.min.y + r.max.y) * 0.5
		a := max(arrow * 0.18, 2)
		draw.rect(dc, {{cx - a, cy - a * 0.35}, {cx + a, cy + a * 0.35}}, col, a * 0.35)
	case "meter", "progress":
		draw.rect(dc, r, draw.mix(col, {1, 1, 1, col.a}, 0.8), (r.max.y - r.min.y) * 0.5)
	}
}

////////////////////////////////
// Gradients (CSS Images §3): linear gradients are drawn as quads with per-corner colors (exact along an axis or with two
// stops); radial and conic gradients, which draw cannot express, show the average of their stops.

Gradient_Kind :: enum u8 { Linear, Radial, Conic }

Gradient_Stop :: struct { color: css.Color, pos: f32, px: bool, auto: bool }

Gradient :: struct {
	kind:   Gradient_Kind,
	dir:    draw.Vec2,     // unit direction, when not a corner
	corner: draw.Vec2,     // "to top right": signs of the corner (0 = by angle)
	stops:  [dynamic]Gradient_Stop,
	ok:     bool,
}

@(private = "file")
gradient_of :: proc(text: string) -> ^Gradient {
	if g, ok := page_render.gradients[text]; ok { return g }
	if len(page_render.gradients) > 4096 {
		for k, g in page_render.gradients { delete(k); delete(g.stops); free(g) }
		clear(&page_render.gradients)
	}
	g := new(Gradient)
	g.dir = {0, 1}
	page_render.gradients[strings.clone(text)] = g
	decls := css.parse_declarations(strings.concatenate({"x:", text}, context.temp_allocator), css.Parse_Options{max_nesting_depth = 64, max_rules = 4}, context.temp_allocator)
	if len(decls) != 1 { return g }
	vs := css.trim_values(decls[0].value)
	if len(vs) != 1 || vs[0].kind != .Function { return g }
	name := strings.to_lower(vs[0].tok.text, context.temp_allocator)
	switch {
	case strings.contains(name, "radial"): g.kind = .Radial
	case strings.contains(name, "conic"): g.kind = .Conic
	}
	args := css.split_commas(vs[0].children, context.temp_allocator)
	first := 0
	if len(args) > 0 && g.kind == .Linear {
		a := css.trim_values(args[0])
		if len(a) > 0 && a[0].kind == .Token && a[0].tok.kind == .Ident && strings.equal_fold(a[0].tok.text, "to") {
			first = 1
			v: draw.Vec2
			for x in a[1:] {
				if x.kind != .Token || x.tok.kind != .Ident { continue }
				switch strings.to_lower(x.tok.text, context.temp_allocator) {
				case "top": v.y = -1
				case "bottom": v.y = 1
				case "left": v.x = -1
				case "right": v.x = 1
				}
			}
			if v.x != 0 && v.y != 0 { g.corner = v } else if v != {} { g.dir = v }
		} else if len(a) == 1 && a[0].kind == .Token && a[0].tok.kind == .Dimension {
			deg: f64
			switch strings.to_lower(a[0].tok.text, context.temp_allocator) {
			case "deg": deg = a[0].tok.num
			case "turn": deg = a[0].tok.num * 360
			case "rad": deg = a[0].tok.num * 180 / math.PI
			case "grad": deg = a[0].tok.num * 0.9
			}
			rad := f32(deg * math.PI / 180)
			g.dir = {math.sin(rad), -math.cos(rad)}
			first = 1
		}
	} else if g.kind != .Linear && len(args) > 0 {
		// the shape / position / angle prelude: skipped when it is not a color
		a := css.trim_values(args[0])
		if len(a) == 0 {
			first = 1
		} else if _, ok := css.parse_color(a[:1], nil); !ok {
			first = 1
		}
	}
	for arg in args[first:] {
		items := make([dynamic]css.Value, context.temp_allocator)
		for x in arg { if !css.is_ws_value(x) { append(&items, x) } }
		if len(items) == 0 { continue }
		cv, ok := css.parse_color(items[:1], nil)
		if !ok || cv.kind != .Rgba { continue }
		st := Gradient_Stop{color = cv.rgba, auto = true}
		if len(items) > 1 && items[1].kind == .Token {
			#partial switch items[1].tok.kind {
			case .Percentage: st.pos, st.auto = f32(items[1].tok.num / 100), false
			case .Dimension:
				if p, pok := css.length_unit_to_px(items[1].tok.num, items[1].tok.text, 0); pok { st.pos, st.px, st.auto = f32(p), true, false }
			case .Number: if items[1].tok.num == 0 { st.pos, st.auto = 0, false }
			}
		}
		append(&g.stops, st)
	}
	g.ok = len(g.stops) > 0
	return g
}

@(private = "file")
paint_gradient :: proc(dc: ^draw.Context, text: string, r: draw.Rect, radii: [4]f32, scale: f32) {
	g := gradient_of(text)
	if !g.ok { return }
	w, h := r.max.x - r.min.x, r.max.y - r.min.y
	if w <= 0 || h <= 0 { return }
	if g.kind != .Linear || len(g.stops) == 1 {
		// premultiplied average of the stops
		avg: css.Color
		for s in g.stops { avg += css.Color{s.color.r * s.color.a, s.color.g * s.color.a, s.color.b * s.color.a, s.color.a} }
		avg /= f32(len(g.stops))
		if avg.a > 0 { avg.r, avg.g, avg.b = avg.r / avg.a, avg.g / avg.a, avg.b / avg.a }
		col := to_draw(avg)
		draw.rect_corners(dc, r, {col, col, col, col}, radii)
		return
	}
	dir := g.dir
	if g.corner != {} {
		// "to top right": perpendicular to the diagonal through the two other corners
		dir = {g.corner.x * h, g.corner.y * w}
		n := math.sqrt(dir.x * dir.x + dir.y * dir.y)
		dir /= n
	}
	length := abs(w * dir.x) + abs(h * dir.y)
	if length <= 0 { return }
	// stop positions along the gradient line, 0..1, with auto positions spread and positions never going back
	n := len(g.stops)
	pos := make([]f32, n, context.temp_allocator)
	for s, i in g.stops {
		switch {
		case !s.auto: pos[i] = s.px ? s.pos * scale / length : s.pos
		case i == 0: pos[i] = 0
		case i == n - 1: pos[i] = 1
		case: pos[i] = -1
		}
	}
	for i := 1; i < n; i += 1 {
		if pos[i] >= 0 { continue }
		j := i
		for j < n && pos[j] < 0 { j += 1 }
		for k in i ..< j { pos[k] = pos[i - 1] + (pos[j] - pos[i - 1]) * f32(k - i + 1) / f32(j - i + 1) }
	}
	for i in 1 ..< n { pos[i] = max(pos[i], pos[i - 1]) }
	color_at :: proc(g: ^Gradient, pos: []f32, t: f32) -> draw.Color {
		n := len(g.stops)
		if t <= pos[0] { return to_draw(g.stops[0].color) }
		if t >= pos[n - 1] { return to_draw(g.stops[n - 1].color) }
		for i in 1 ..< n {
			if t <= pos[i] {
				span := pos[i] - pos[i - 1]
				f := span > 0 ? (t - pos[i - 1]) / span : 1
				return mix_css(g.stops[i - 1].color, g.stops[i].color, f)
			}
		}
		return to_draw(g.stops[n - 1].color)
	}
	axis := abs(dir.x) < 0.001 || abs(dir.y) < 0.001
	if !axis {
		c := (r.min + r.max) * 0.5
		t_of :: proc(p, c, dir: draw.Vec2, length: f32) -> f32 { return ((p.x - c.x) * dir.x + (p.y - c.y) * dir.y) / length + 0.5 }
		cols := [4]draw.Color{
			color_at(g, pos, t_of(r.min, c, dir, length)), color_at(g, pos, t_of({r.min.x, r.max.y}, c, dir, length)),
			color_at(g, pos, t_of({r.max.x, r.min.y}, c, dir, length)), color_at(g, pos, t_of(r.max, c, dir, length)),
		}
		draw.rect_corners(dc, r, cols, radii)
		return
	}
	// along an axis: one strip per stop interval (plus the flat ends)
	vertical := abs(dir.y) > abs(dir.x)
	reverse := vertical ? dir.y < 0 : dir.x < 0
	edges := make([dynamic]f32, 0, n + 2, context.temp_allocator)
	append(&edges, 0)
	for p in pos { if p > 0 && p < 1 { append(&edges, p) } }
	append(&edges, 1)
	for i in 0 ..< len(edges) - 1 {
		t0, t1 := edges[i], edges[i + 1]
		if t1 <= t0 { continue }
		c0, c1 := color_at(g, pos, t0 + 0.0001), color_at(g, pos, t1 - 0.0001)
		a0, a1 := t0, t1
		if reverse { a0, a1 = 1 - t1, 1 - t0; c0, c1 = c1, c0 }
		piece: draw.Rect
		cols: [4]draw.Color
		rad: [4]f32
		if vertical {
			piece = {{r.min.x, r.min.y + h * a0}, {r.max.x, r.min.y + h * a1}}
			cols = {c0, c1, c0, c1}
			if a0 <= 0 { rad[0], rad[2] = radii[0], radii[2] }
			if a1 >= 1 { rad[1], rad[3] = radii[1], radii[3] }
		} else {
			piece = {{r.min.x + w * a0, r.min.y}, {r.min.x + w * a1, r.max.y}}
			cols = {c0, c0, c1, c1}
			if a0 <= 0 { rad[0], rad[1] = radii[0], radii[1] }
			if a1 >= 1 { rad[2], rad[3] = radii[2], radii[3] }
		}
		draw.rect_corners(dc, piece, cols, rad)
	}
}
