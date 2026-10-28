package browser

// The shell's part of the 2D canvas: the text engine package canvas2d draws text through. Fonts are the ones the
// page's text uses (resolve_request, with the tab's web fonts), shaping is the toolkit's (DirectWrite, with bidi and
// fallback), and a glyph is drawn from its outline (the Slug outline provider: quadratic curves in em units), so canvas
// text takes the transform, gradients, shadows and stroke like any shape. The painting of the bitmap is in
// images_shell.odin (paint_canvas), next to the other replaced content.

import "toolkit:font"
import "wb:canvas2d"
import lay "wb:layout"
import "wb:page"

@(private = "file")
outline_cache: map[u64]^canvas2d.Path

// A rasterized color glyph (emoji) kept so the canvas does not re-rasterize and the GPU does not re-upload it each
// frame. Keyed by (face, gid, quantized size, text color): a glyph with foreground layers takes the fill color, so the
// color is part of the key; palette glyphs ignore it but still hit (the key just carries the same color). `uid` has
// CANVAS_COLOR_GLYPH_BIT so it never collides with the uids bitmap_create hands out.
@(private = "file")
Color_Glyph_Key :: struct {
	face:  u64,
	gid:   u16,
	size:  u32,   // size quantized to 1/16 px
	color: u32,   // 0xRRGGBB (alpha is applied by the compositor, not baked)
}

@(private = "file")
Color_Glyph_Entry :: struct {
	px:     []u8,
	w, h:   int,
	ox, oy: f32,
	uid:    u64,
	ok:     bool,
}

@(private = "file")
color_glyph_cache: map[Color_Glyph_Key]^Color_Glyph_Entry

@(private = "file")
color_glyph_next_uid: u64

// A bit high enough that it never meets canvas2d's next_bitmap_uid (a running counter from 1).
CANVAS_COLOR_GLYPH_BIT :: u64(1) << 60

canvas_shell_init :: proc(app: ^App) {
	page.canvas_text_engine = canvas2d.Text_Engine{
		font = proc(user: rawptr, spec: ^canvas2d.Font_Spec) -> u64 {
			app := the_app
			if app == nil { return 0 }
			p := (^page.Page)(user)
			pf := &page_render.fonts
			// the page's own web fonts, whichever tab is drawn now
			old := pf.scope
			for t in tabs_all(app) { if t.page == p { page_fonts_scope(pf, t); break } }
			defer page_fonts_scope(pf, old)
			req := lay.Font_Request{
				families = spec.families, weight = spec.weight, italic = spec.italic,
				style = spec.italic ? .Italic : .Normal, stretch = spec.stretch,
			}
			return u64(resolve_request(pf, &req, &app.page_settings.style))
		},
		shape = proc(user: rawptr, face: u64, size: f32, text: string, rtl: bool, letter_spacing, word_spacing: f32, glyphs: ^[dynamic]canvas2d.Placed_Glyph) -> f32 {
			sh := font.shape(page_render.fonts.state, font.Font_Id(face), size, text, font.Shape_Options{
				direction = rtl ? .Rtl : .Ltr, letter_spacing = letter_spacing, word_spacing = word_spacing,
			}, context.temp_allocator)
			for g in sh.glyphs { append(glyphs, canvas2d.Placed_Glyph{face = u64(g.face), gid = g.id, x = g.x, y = g.y}) }
			return sh.width
		},
		outline = proc(user: rawptr, face: u64, gid: u16) -> ^canvas2d.Path {
			key := face << 16 | u64(gid)
			if p, ok := outline_cache[key]; ok { return p }
			limit := the_app != nil ? the_app.page_settings.canvas.glyph_cache_entries : 4096
			if len(outline_cache) >= limit { canvas_outlines_clear() }
			o: font.Outline
			defer font.outline_destroy(&o)
			var_path: ^canvas2d.Path
			if font.glyph_outline(page_render.fonts.state, font.Font_Id(face), gid, 0.0005, &o) && len(o.quads) > 0 {
				var_path = new(canvas2d.Path)
				start := 0
				for end in o.ends {
					quads := o.quads[start:end]
					start = end
					if len(quads) == 0 { continue }
					canvas2d.path_move_to(var_path, canvas2d.IDENTITY, f64(quads[0].p[0].x), f64(quads[0].p[0].y))
					for q in quads {
						if q.p[1] == q.p[2] {
							canvas2d.path_line_to(var_path, canvas2d.IDENTITY, f64(q.p[2].x), f64(q.p[2].y))
						} else {
							canvas2d.path_quad_to(var_path, canvas2d.IDENTITY, f64(q.p[1].x), f64(q.p[1].y), f64(q.p[2].x), f64(q.p[2].y))
						}
					}
					canvas2d.path_close(var_path)
				}
			}
			if outline_cache == nil { outline_cache = make(map[u64]^canvas2d.Path) }
			outline_cache[key] = var_path   // (nil: a glyph with no outline, a space)
			return var_path
		},
		metrics = proc(user: rawptr, face: u64, size: f32) -> canvas2d.Font_Metrics {
			m := font.metrics(page_render.fonts.state, font.Font_Id(face), size)
			return canvas2d.Font_Metrics{ascent = m.ascent, descent = m.descent, x_height = m.x_height, em_ascent = m.ascent, em_descent = m.descent}
		},
		// Color glyphs (emoji, COLR / sbix / CBDT / SVG) drawn by the toolkit's color-glyph rasterizer (the same code
		// the chrome uses), as a straight-RGBA bitmap the canvas composites as an image. The text color is the fill
		// color: a glyph with foreground / text-color layers takes it.
		color_glyph = proc(user: rawptr, face: u64, gid: u16, size: f32, fg: [4]f32) -> (canvas2d.Color_Glyph, bool) {
			srgb := [3]u8{u8(clamp(fg[0], 0, 1) * 255 + 0.5), u8(clamp(fg[1], 0, 1) * 255 + 0.5), u8(clamp(fg[2], 0, 1) * 255 + 0.5)}
			key := Color_Glyph_Key{
				face  = face,
				gid   = gid,
				size  = u32(clamp(size, 0, 1 << 24) * 16 + 0.5),
				color = u32(srgb[0]) << 16 | u32(srgb[1]) << 8 | u32(srgb[2]),
			}
			if e := color_glyph_cache[key]; e != nil {
				if !e.ok { return {}, false }
				return canvas2d.Color_Glyph{px = e.px, w = e.w, h = e.h, ox = e.ox, oy = e.oy, uid = e.uid}, true
			}
			limit := the_app != nil ? the_app.page_settings.canvas.glyph_cache_entries : 4096
			if len(color_glyph_cache) >= limit { canvas_color_glyphs_clear() }
			cg, ok := font.color_glyph_rgba(page_render.fonts.state, font.Font_Id(face), gid, size, srgb)
			e := new(Color_Glyph_Entry)
			if ok {
				// own a copy of the pixels: the rasterizer's buffer is only valid until the next call
				e.px = make([]u8, len(cg.px))
				copy(e.px, cg.px)
				color_glyph_next_uid += 1
				e^ = Color_Glyph_Entry{px = e.px, w = cg.w, h = cg.h, ox = cg.ox, oy = cg.oy, uid = color_glyph_next_uid | CANVAS_COLOR_GLYPH_BIT, ok = true}
			}
			if color_glyph_cache == nil { color_glyph_cache = make(map[Color_Glyph_Key]^Color_Glyph_Entry) }
			color_glyph_cache[key] = e
			if !e.ok { return {}, false }
			return canvas2d.Color_Glyph{px = e.px, w = e.w, h = e.h, ox = e.ox, oy = e.oy, uid = e.uid}, true
		},
	}
}

// Outlines are keyed by font id: any change to the fonts (a web face registered or dropped) starts them over.
canvas_outlines_clear :: proc() {
	for _, p in outline_cache {
		if p != nil { canvas2d.path_destroy(p); free(p) }
	}
	clear(&outline_cache)
}

// Color-glyph bitmaps, cleared when the fonts change (same reason as outlines) or the cache is full. The GPU source
// cache still holds textures keyed by the entries' uids; those age out on their own once no list draws them.
canvas_color_glyphs_clear :: proc() {
	for _, e in color_glyph_cache {
		if e != nil {
			if e.px != nil { delete(e.px) }
			free(e)
		}
	}
	clear(&color_glyph_cache)
}

canvas_shell_destroy :: proc() {
	canvas_outlines_clear()
	delete(outline_cache)
	outline_cache = nil
	canvas_color_glyphs_clear()
	delete(color_glyph_cache)
	color_glyph_cache = nil
}
