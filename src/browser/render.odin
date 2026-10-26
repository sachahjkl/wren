// Document painter: draws the display list of package layout with toolkit:draw. Layout decides what goes where and in
// which order (CSS 2.1 Appendix E), under which clip, scroll offset, sticky shift, transform and opacity group; the
// effects section below maps those onto draw's transform / clip / layer stacks; the rest of this file turns each item
// into rectangles and glyphs: backgrounds and box shadows (paint_backgrounds.odin), borders of every style with rounded
// corners, outlines, text with decorations, spacing and shadows, list markers, scroll bars, and the content of form
// controls and replaced elements (through a hook other parts of the browser install).
package browser

import "core:math"
import "core:strings"
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
	watch_layout, watch_font: int,
}

page_render: Page_Render

// Shell start-up: the fonts of pages and the layout preferences.
page_render_init :: proc(app: ^App) {
	page_fonts_init(&page_render.fonts, &app.fonts, app.ui_font)
	page_render.settings = lay.settings_from_prefs(&app.prefs)
	render_settings_init(app)
	font_settings_init(app)
	effects_init(app)
	page_render.watch_layout = config.watch(&app.prefs, "layout.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		page_render.settings = lay.settings_from_prefs(p)
		for t in active_window((^App)(user)).tabs { t.layout.valid = false }
	}, app)
	page_render.watch_font = config.watch(&app.prefs, "font.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		page_fonts_forget(&page_render.fonts)
	}, app)
}

page_render_destroy :: proc() {
	page_fonts_destroy(&page_render.fonts)
}

// Installs the painter of form controls / replaced content (forms, images).
set_content_painter :: proc(fn: Content_Painter, user: rawptr) {
	page_render.content, page_render.content_user = fn, user
}

// Installs the source of natural sizes of replaced content (decoded images...). A change of size needs a new layout:
// set `layout.valid = false` on the tabs concerned.
set_replaced_sizes :: proc(api: lay.Replaced_Api) { page_render.replaced = api }

register_layout_prefs :: proc(p: ^config.Prefs) { lay.register_prefs(p) }

layout_reset :: proc(l: ^Layout) { composite_forget(l); text_clip_forget(l); lay.reset(l) }
layout_destroy :: proc(l: ^Layout) { composite_forget(l); text_clip_forget(l); lay.destroy(l) }

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
	page_world_check("hit_test: a layout read in a chrome frame, or during a page thread pass")
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

// Paints the page: through the compositor (retained pictures replayed, render.compositor.enabled) or item by item.
// The page origin and the scroll offset are snapped to device pixels, as browsers do: text stays on the pixel grid and
// a retained picture lands exactly where direct drawing would.
// `doc_scrollbar` false: no bar for the document (a frame with scrolling="no").
paint :: proc(l: ^Layout, dc: ^draw.Context, d: ^dom.Document, page_origin, size: draw.Vec2, page_scroll: f32, clip: draw.Rect, doc_scrollbar := true) {
	if !l.valid { return }
	origin := draw.Vec2{math.round(page_origin.x), math.round(page_origin.y)}
	scroll := math.round(page_scroll)
	// CSS border-radius draws circular arcs, not the squircle of the browser's own UI
	circular := draw.set_circular_corners(dc, true)
	defer draw.set_circular_corners(dc, circular)
	// corner colors interpolate on sRGB values whatever the blend space (CSS: `in srgb` is the default)
	interp := draw.set_interpolation(dc, .Srgb)
	defer draw.set_interpolation(dc, interp)
	paint_canvas_images(l, dc, origin, size, scroll)
	if !(compositor_settings.enabled && composite_paint(l, dc, d, origin, size, scroll)) {
		v := lay.view_make(l, size, scroll)
		fx := effects_make(l, &v, dc, origin, size)
		for idx in v.visible {
			it := &l.items[idx]
			if !effects_for(&fx, it) { continue }
			off := v.offsets[it.space] + fx.origin
			paint_item(l, dc, d, &v, it, draw.rect_shift(dr(it.rect), off), off, fx.origin)
		}
		effects_end(&fx)
	}
	if track, thumb, ok := lay.doc_scrollbar(l, size, scroll); ok && doc_scrollbar {
		root := l.styled != nil ? (^style.Styled)(l.styled).root_scheme : style.Scheme.Light   // alive while the layout is painted
		thumb_c, track_c := scrollbar_colors(root, page_render.settings.scrollbar_thumb, page_render.settings.scrollbar_track)
		// the viewport's bar follows the root element's scrollbar-color
		if ri := l.canvas_items[0]; ri >= 0 && int(ri) < len(l.items) { thumb_c, track_c = scrollbar_colors_of(l.items[ri].cs, thumb_c, track_c) }
		if track_c.a > 0 { draw.rect(dc, draw.rect_shift(dr(track), origin), to_draw(track_c), (track.max.x - track.min.x) * 0.5) }
		draw.rect(dc, draw.rect_shift(dr(thumb), origin), to_draw(thumb_c), (thumb.max.x - thumb.min.x) * 0.5)
	}
}

// The box whose background is the canvas's (CSS Backgrounds §2.11.2): the root element's, or the body's when the root
// has neither a background color nor an image. Its color fills the canvas (the shell paints Styled.canvas), its images
// are painted over the whole canvas (paint_canvas_images), and the box itself paints no background. NONE: neither.
canvas_source_box :: proc(l: ^Layout) -> i32 {
	paints :: proc(cs: ^style.Computed) -> bool {
		if cs == nil { return false }
		if cs.background_color.a > 0 { return true }
		for im in cs.background_images { if im.kind != .None { return true } }
		return false
	}
	for k in 0 ..< 2 {
		i := l.canvas_items[k]
		if i < 0 || int(i) >= len(l.items) { continue }
		it := &l.items[i]
		if paints(it.cs) { return it.box }
	}
	return lay.NONE
}

// The background images of the canvas source, positioned against the root element's box (its origin box) and painted
// over the whole viewport.
@(private = "file")
paint_canvas_images :: proc(l: ^Layout, dc: ^draw.Context, origin, size: draw.Vec2, scroll: f32) {
	src := canvas_source_box(l)
	if src == lay.NONE { return }
	cs := l.boxes[src].cs
	has_image := false
	for im in cs.background_images { if im.kind != .None { has_image = true; break } }
	if !has_image { return }
	ri := l.canvas_items[0]
	if ri < 0 { ri = l.canvas_items[1] }
	if ri < 0 || int(ri) >= len(l.items) { return }
	root := &l.items[ri]
	rb := &l.boxes[root.box]
	v := lay.view_make(l, size, scroll, cull = false)
	off := v.offsets[root.space] + origin
	border := draw.rect_shift(dr(root.rect), off)
	boxes := bg_boxes(border, {}, {rb.border[0], rb.border[1], rb.border[2], rb.border[3]}, rb.padding)
	viewport := draw.Rect{origin, origin + size}
	layers := style.background_layers(cs)
	for i := len(layers) - 1; i >= 0; i -= 1 {
		layer := &layers[i]
		pos_area, _ := area_of(&boxes, layer.origin)
		paint_image_layer(dc, layer, pos_area, viewport, {}, l.scale)
	}
}

// One display item at `r` (its rect moved by `off`, the offset of its space plus the page origin; both zero when a
// picture is recorded in layout coordinates).
paint_item :: proc(l: ^Layout, dc: ^draw.Context, d: ^dom.Document, v: ^lay.View, it: ^lay.Display_Item, r: draw.Rect, off, origin: draw.Vec2) {
	selection_paint_under(l, dc, it, r)
	defer selection_paint_over(l, dc, it, r)
	switch it.kind {
	case .Box:
		if page_render.bare != nil && page_render.bare(page_render.content_user, d, it.node) { return }
		paint_box(l, dc, d, v, it, r, origin)
	case .Inline_Box: paint_inline_box(l, dc, v, it, r, origin)
	case .Text: paint_text(l, dc, it, r, off)
	case .Marker: paint_marker(l, dc, it, r, off)
	case .Replaced, .Control: paint_content(l, dc, d, it, r, off)
	case .Outline: paint_outline(l, dc, it, r)
	case .Scrollbar:
		track := r
		thumb_c, track_c := scrollbar_colors(it.cs != nil ? it.cs.used_scheme : .Light, page_render.settings.scrollbar_thumb, page_render.settings.scrollbar_track)
		thumb_c, track_c = scrollbar_colors_of(it.cs, thumb_c, track_c)
		if track_c.a > 0 { draw.rect(dc, track, to_draw(track_c), min(track.max.x - track.min.x, track.max.y - track.min.y) * 0.5) }
		th := draw.rect_shift(dr(lay.scrollbar_thumb(l, v, it)), origin)
		draw.rect(dc, th, to_draw(thumb_c), min(th.max.x - th.min.x, th.max.y - th.min.y) * 0.5)
	}
}

// scrollbar-color (CSS Scrollbars 1): the element's thumb and track colors, else the defaults given.
@(private = "file")
scrollbar_colors_of :: proc(cs: ^style.Computed, thumb, track: css.Color) -> (css.Color, css.Color) {
	if cs == nil || cs.scrollbar_color.auto { return thumb, track }
	return cs.scrollbar_color.thumb, cs.scrollbar_color.track
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
paint_box :: proc(l: ^Layout, dc: ^draw.Context, d: ^dom.Document, v: ^lay.View, it: ^lay.Display_Item, r: draw.Rect, origin: draw.Vec2) {
	cs := it.cs
	if cs == nil { return }
	b := &l.boxes[it.box]
	r := r
	// a fieldset with a rendered legend: the box starts at the border drawn through the legend's middle
	shift, gap, legend := lay.fieldset_border(l, it.box)
	if legend { r.min.y = min(r.min.y + shift, r.max.y) }
	radii := corner_radii(cs, r, l.scale)
	widths := [4]f32{b.border[0], b.border[1], b.border[2], b.border[3]}
	boxes := bg_boxes(r, radii, widths, b.padding)
	if len(cs.box_shadow) > 0 { paint_box_shadows(dc, cs, r, radii, boxes.padding, boxes.padding_radii, l.scale, false) }
	if .No_Background not_in it.flags && it.box != canvas_source_box(l) {
		if background_clips_text(cs) { paint_backgrounds_text(l, dc, v, it, &boxes, origin) } else { paint_backgrounds(dc, cs, &boxes, l.scale, d) }
	}
	if len(cs.box_shadow) > 0 { paint_box_shadows(dc, cs, r, radii, boxes.padding, boxes.padding_radii, l.scale, true) }
	if widths == {} { return }
	if !legend || widths[0] <= 0 {
		paint_borders(dc, r, widths, cs.border_style, cs.border_color, radii)
		return
	}
	// the border interrupted behind the legend's border box: three clips that do not overlap (left of the gap, right
	// of it, under the top border between them), so a translucent border is not drawn twice. The border runs through the
	// legend's middle, often at a fractional y: the scissor truncates the clip to whole pixels, so the one under the top
	// border starts a pixel lower, past the row the border's edge only partly covers (else a line through the legend).
	dx := r.min.x - it.rect.min.x
	g0, g1 := gap[0] + dx, gap[1] + dx
	big := draw.rect_pad(r, 4)
	parts := [3]draw.Rect{
		{big.min, {g0, big.max.y}},
		{{g1, big.min.y}, big.max},
		{{g0, r.min.y + widths[0] + 1}, {g1, big.max.y}},
	}
	for p in parts {
		if p.max.x <= p.min.x || p.max.y <= p.min.y { continue }
		draw.push_clip(dc, p)
		paint_borders(dc, r, widths, cs.border_style, cs.border_color, radii)
		draw.pop_clip(dc)
	}
}

@(private = "file")
paint_inline_box :: proc(l: ^Layout, dc: ^draw.Context, v: ^lay.View, it: ^lay.Display_Item, r: draw.Rect, origin: draw.Vec2) {
	cs := it.cs
	if cs == nil { return }
	b := &l.boxes[it.box]
	radii := corner_radii(cs, r, l.scale)
	// a box split over lines keeps its rounded corners only where it starts and ends
	if .Left_Edge not_in it.flags { radii[0], radii[1] = 0, 0 }
	if .Right_Edge not_in it.flags { radii[2], radii[3] = 0, 0 }
	widths := [4]f32{b.border[0], .Right_Edge in it.flags ? b.border[1] : 0, b.border[2], .Left_Edge in it.flags ? b.border[3] : 0}
	pad := [4]f32{b.padding[0], .Right_Edge in it.flags ? b.padding[1] : 0, b.padding[2], .Left_Edge in it.flags ? b.padding[3] : 0}
	boxes := bg_boxes(r, radii, widths, pad)
	if len(cs.box_shadow) > 0 { paint_box_shadows(dc, cs, r, radii, boxes.padding, boxes.padding_radii, l.scale, false) }
	if background_clips_text(cs) { paint_backgrounds_text(l, dc, v, it, &boxes, origin) } else { paint_backgrounds(dc, cs, &boxes, l.scale) }
	if len(cs.box_shadow) > 0 { paint_box_shadows(dc, cs, r, radii, boxes.padding, boxes.padding_radii, l.scale, true) }
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

// Shaping options of a text fragment: one directional run (layout resolved the bidi levels), spacing as layout measured
// it (letter-spacing after each character, word-spacing after each space and no-break space, justification after each
// space).
// The same as the carets and hit testing of selections use (fonts.odin run_shape_options).
text_shape_options :: proc(l: ^Layout, cs: ^style.Computed, level: u8, extra: f32) -> font.Shape_Options {
	return run_shape_options(lay.Text_Run{
		rtl = level & 1 == 1, letter_spacing = cs.letter_spacing * l.scale, word_spacing = cs.word_spacing * l.scale, justify = extra,
	})
}

// Draws one text fragment: shaped (cached by the toolkit) and drawn glyph by glyph from the atlas (draw.glyph_run).
@(private = "file")
draw_run :: proc(dc: ^draw.Context, fid: font.Font_Id, size: f32, pos: draw.Vec2, col: draw.Color, text: string, opts: font.Shape_Options) {
	sh := font.shape(dc.fonts, fid, size, text, opts, context.temp_allocator)
	draw.glyph_run(dc, size, pos, col, sh.glyphs)
}

@(private = "file")
paint_text :: proc(l: ^Layout, dc: ^draw.Context, it: ^lay.Display_Item, r: draw.Rect, off: draw.Vec2) {
	cs := it.cs
	fi := lay.item_font(l, it)
	if cs == nil || fi == nil || it.text == "" { return }
	if web_text_invisible(l, cs) { return }   // its web font is loading, in its block period (web_font_faces.odin)
	fid := font.Font_Id(fi.font)
	baseline := it.baseline + off.y
	opts := text_shape_options(l, cs, it.level, it.extra)
	for i := len(cs.text_shadow) - 1; i >= 0; i -= 1 {
		s := cs.text_shadow[i]
		if s.color.a <= 0 { continue }
		col := to_draw(s.color)
		pos := draw.Vec2{r.min.x + s.x * l.scale, baseline + s.y * l.scale}
		if s.blur > 0 && effects_settings.exact_shadows {
			// a gaussian of half the blur radius (CSS Backgrounds §7.2), through a layer
			ink := draw.rect_pad(draw.rect_shift(r, {s.x, s.y} * l.scale), fi.size * 0.5)
			id, key, anchor := fx_cache_text_shadow(it, i, fid, fi.size, col, pos, r, opts)   // kept from frame to frame
			if draw.push_effects(dc, ink, draw.Layer_Effects{alpha = 1, filters = {draw.filter_blur(s.blur * 0.5 * l.scale)}, cache_id = id, cache_key = key, cache_anchor = anchor}) {
				draw_run(dc, fid, fi.size, pos, col, it.text, opts)
			}
			draw.pop_layer(dc)
			continue
		}
		if s.blur > 0 { col.a *= 0.6 }
		draw_run(dc, fid, fi.size, pos, col, it.text, opts)
	}
	col := to_draw(cs.color)
	fill := to_draw(style.text_fill(cs))   // -webkit-text-fill-color (background-clip: text pages make it transparent)
	if fill.a > 0 { draw_run(dc, fid, fi.size, {r.min.x, baseline}, fill, it.text, opts) }
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
	if it.kind == .Replaced && frames_paint_content(the_app, dc, d, it.node, r, it.cs) { return }   // (frames_shell.odin)
	if page_render.content != nil {
		if page_render.content(page_render.content_user, dc, d, it.node, it.kind, r, border, it.cs, fid, size) { return }
	}
	if it.kind != .Control || fi == nil || d == nil { return }
	default_control(l, dc, d, it, r, border, fi)
}

// What a control shows until the forms code paints it: its value, placeholder, checked state, selected option.
@(private = "file")
default_control :: proc(l: ^Layout, dc: ^draw.Context, d: ^dom.Document, it: ^lay.Display_Item, r, border: draw.Rect, fi: ^lay.Font_Info) {
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
		// (as forms_shell.odin paint_control: the label after the start padding, the arrow centered in the arrow's room
		// at the right of the border box)
		arrow := page_render.settings.select_arrow * l.scale
		start := page_render.settings.select_start * l.scale
		text_in(dc, fid, fi.size, {{r.min.x + start, r.min.y}, {r.max.x - arrow, r.max.y}}, mid_base, col, label, false, fonts)
		cx, cy := border.max.x - arrow * 0.5, (border.min.y + border.max.y) * 0.5
		a := max(arrow * 0.25, 2)
		draw.rect(dc, {{cx - a, cy - a * 0.35}, {cx + a, cy + a * 0.35}}, col, a * 0.35)
	case "meter", "progress":
		draw.rect(dc, r, draw.mix(col, {1, 1, 1, col.a}, 0.8), (r.max.y - r.min.y) * 0.5)
	}
}
