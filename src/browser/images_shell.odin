package browser

// Images in the shell: natural sizes for layout, the content of <img> / <input type=image>, CSS background images, a
// texture per decoded image, animation wake-ups, lazy loading distances.
//
// Textures go through `Texture_Api`, four procedures the renderer provides (and a fifth for repeated backgrounds). Until
// it is connected, `PLACEHOLDER_TEXTURES` draws a grey placeholder with a picture icon where each image goes, so layout
// and the whole pipeline (download, decode, cache, animation timing) can be seen working. To connect the real
// renderer, after `images_shell_init`:
//
//	images_set_texture_api(Texture_Api{
//		user     = app,
//		create   = proc(u: rawptr, w, h: int) -> Image_Texture { return Image_Texture(render.create_texture_rgba(&(^App)(u).r, w, h)) },
//		update   = proc(u: rawptr, t: Image_Texture, x, y, w, h: int, px: []u8, stride: int) { render.update_texture_rgba(&(^App)(u).r, render.Texture(t), x, y, w, h, px, stride) },
//		destroy  = proc(u: rawptr, t: Image_Texture) { render.destroy_texture(&(^App)(u).r, render.Texture(t)) },
//		draw     = proc(u: rawptr, dc: ^draw.Context, t: Image_Texture, dst, src: draw.Rect, tint: draw.Color, radii: [4]f32) { draw.image_corners(dc, render.Texture(t), dst, src, tint, radii) },
//		draw_tiled = proc(u: rawptr, dc: ^draw.Context, t: Image_Texture, dst, tile: draw.Rect, tint: draw.Color, radii: [4]f32) { draw.image_tiled(dc, render.Texture(t), dst, tile, tint, radii) },
//		max_size = proc(u: rawptr) -> int { return render.max_texture_size(&(^App)(u).r) },
//	})
//
// Pixels handed to `update` are RGBA8, straight alpha, sRGB, `stride` bytes per row (package images).

import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:font"
import "wb:base"
import "wb:dom"
import "wb:host"
import lay "wb:layout"
import "wb:page"
import "wb:style"

Image_Texture :: distinct int   // the renderer's texture handle; 0 = none

@(private = "file")
WHITE_TINT :: draw.Color{1, 1, 1, 1}

Texture_Api :: struct {
	user:       rawptr,
	create:     proc(user: rawptr, w, h: int) -> Image_Texture,
	update:     proc(user: rawptr, tex: Image_Texture, x, y, w, h: int, pixels: []u8, stride: int),
	destroy:    proc(user: rawptr, tex: Image_Texture),
	draw:       proc(user: rawptr, dc: ^draw.Context, tex: Image_Texture, dst, src: draw.Rect, tint: draw.Color, radii: [4]f32),
	draw_tiled: proc(user: rawptr, dc: ^draw.Context, tex: Image_Texture, dst, tile: draw.Rect, tint: draw.Color, radii: [4]f32),   // optional
	max_size:   proc(user: rawptr) -> int,   // optional: largest texture side
	placeholder: bool,                        // draws placeholders, not pixels
}

@(private = "file")
Shell_Texture :: struct {
	tex:        Image_Texture,
	w, h:       int,
	generation: u64,
	frame:      int,
	bytes:      int,
	epoch:      u64,
}

@(private = "file")
Images_Shell :: struct {
	api:        Texture_Api,
	textures:   map[u64]^Shell_Texture,
	bytes:      int,
	epoch:      u64,
	page:       ^page.Page,          // the page being laid out / painted
	wake:       base.Handle,         // timer of the next animation frame
	next_ms:    f64,                 // earliest frame change among the images drawn this frame (< 0 = none)
	now_ms:     f64,
	evicted:    [dynamic]u64,
	fake_next:  Image_Texture,
}

@(private = "file")
shell: Images_Shell

// The fallback: textures that remember nothing and draw a placeholder of the image's box.
PLACEHOLDER_TEXTURES :: Texture_Api{
	placeholder = true,
	create = proc(user: rawptr, w, h: int) -> Image_Texture { shell.fake_next += 1; return shell.fake_next },
	update = proc(user: rawptr, tex: Image_Texture, x, y, w, h: int, pixels: []u8, stride: int) {},
	destroy = proc(user: rawptr, tex: Image_Texture) {},
	draw = proc(user: rawptr, dc: ^draw.Context, tex: Image_Texture, dst, src: draw.Rect, tint: draw.Color, radii: [4]f32) { draw_placeholder(dc, dst, .Ready) },
}

images_shell_init :: proc(app: ^App) {
	shell.api = PLACEHOLDER_TEXTURES
	shell.textures = make(map[u64]^Shell_Texture)
	shell.evicted = make([dynamic]u64)
	shell.next_ms = -1
	set_replaced_sizes(lay.Replaced_Api{intrinsic = proc(user: rawptr, node: base.Handle) -> (w, h: f32, ok: bool) {
		if shell.page == nil { return 0, 0, false }
		return page.image_intrinsic(shell.page, node)
	}})
}

// Connects the renderer's textures (see the top of this file). Textures made by the previous API are released.
images_set_texture_api :: proc(api: Texture_Api) {
	release_all_textures()
	shell.api = api
}

images_shell_destroy :: proc(app: ^App) {
	release_all_textures()
	delete(shell.textures)
	delete(shell.evicted)
	if shell.wake != base.NIL_HANDLE { host.clear_timer(&app.loop, shell.wake) }
	shell = {}
}

@(private = "file")
release_all_textures :: proc() {
	for _, st in shell.textures {
		if shell.api.destroy != nil { shell.api.destroy(shell.api.user, st.tex) }
		free(st)
	}
	clear(&shell.textures)
	shell.bytes = 0
}

@(private = "file")
release_texture :: proc(id: u64) {
	st, ok := shell.textures[id]
	if !ok { return }
	shell.api.destroy(shell.api.user, st.tex)
	shell.bytes -= st.bytes
	delete_key(&shell.textures, id)
	free(st)
}

// Once per frame, after the loop ran: every tab's images follow its document (downloads start in background tabs too),
// textures of evicted images go.
images_shell_frame :: proc(app: ^App) {
	for tab in app.tabs { if tab.page != nil && tab.kind == .Web { page.images_sync(tab.page) } }
	clear(&shell.evicted)
	page.images_drain_evicted(&shell.evicted)
	for id in shell.evicted { release_texture(id) }
}

// Before the layout of `t`: natural sizes come from its page, and a size that became known makes the layout stale.
images_before_layout :: proc(t: ^Tab) {
	shell.page = t.page
	page.images_sync(t.page)
	if g := page.images_sizes_generation(t.page); g != t.image_sizes {
		t.image_sizes = g
		t.layout.valid = false
	}
}

// After the layout: distances to the viewport of the images still waiting (loading=lazy, queued downloads).
images_after_layout :: proc(t: ^Tab, size: draw.Vec2, scale: f32) {
	watched := page.images_watched(t.page)
	if len(watched) == 0 { return }
	l := &t.layout
	if !l.valid { return }
	v := lay.view_make(l, size, t.scroll, cull = false)
	for node in watched {
		bi := lay.box_index(l, node)
		if bi == lay.NONE { page.images_set_distance(t.page, node, max(f32)); continue }
		b := &l.boxes[bi]
		r := lay.rect_shift(lay.Rect{b.abs, b.abs + b.size}, v.offsets[b.space])
		dx := max(0, r.min.x - size.x, -r.max.x)
		dy := max(0, r.min.y - size.y, -r.max.y)
		page.images_set_distance(t.page, node, max(dx, dy) / max(scale, 0.01))
	}
}

// Before painting a page: a new epoch for the cache and the texture budget, and the clock of animations.
images_paint_begin_frame :: proc(app: ^App) {
	page.images_paint_begin()
	shell.epoch += 1
	shell.now_ms = f64(host.now_ns(&app.loop)) / 1e6
	shell.next_ms = -1
}

// After painting: the next animation frame of what was drawn wakes the loop (nothing animates off screen: no timer).
images_after_paint :: proc(app: ^App) {
	if shell.wake != base.NIL_HANDLE { host.clear_timer(&app.loop, shell.wake); shell.wake = base.NIL_HANDLE }
	if shell.next_ms >= 0 {
		delay := max(shell.next_ms - shell.now_ms, 1)
		shell.wake = host.set_timer(&app.loop, delay, 0, proc(data: rawptr) {
			shell.wake = base.NIL_HANDLE
			a := (^App)(data)
			a.frames_requested = max(a.frames_requested, 1)
		}, app)
	}
	enforce_texture_budget(app)
}

@(private = "file")
enforce_texture_budget :: proc(app: ^App) {
	limit := app.page_settings.images.gpu_max_bytes
	if shell.bytes <= limit { return }
	ids := make([dynamic]u64, 0, len(shell.textures), context.temp_allocator)
	for id, st in shell.textures { if st.epoch != shell.epoch { append(&ids, id) } }
	// oldest first
	for i in 1 ..< len(ids) {
		for j := i; j > 0 && shell.textures[ids[j]].epoch < shell.textures[ids[j - 1]].epoch; j -= 1 { ids[j], ids[j - 1] = ids[j - 1], ids[j] }
	}
	for id in ids {
		if shell.bytes <= limit { break }
		release_texture(id)
	}
}

// The texture of entry `id` showing frame `fp`, made or refreshed as needed.
@(private = "file")
texture_for :: proc(id: u64, fp: page.Frame_Pixels) -> (Image_Texture, bool) {
	st := shell.textures[id]
	if st != nil && (st.w != fp.width || st.h != fp.height) { release_texture(id); st = nil }
	if st == nil {
		tex := shell.api.create(shell.api.user, fp.width, fp.height)
		if tex == 0 { return 0, false }
		st = new(Shell_Texture)
		st.tex, st.w, st.h = tex, fp.width, fp.height
		st.bytes = fp.width * fp.height * 4 * 4 / 3   // with mipmaps
		st.generation = ~u64(0)
		shell.bytes += st.bytes
		shell.textures[id] = st
	}
	if st.generation != fp.generation || st.frame != fp.frame {
		shell.api.update(shell.api.user, st.tex, 0, 0, fp.width, fp.height, fp.pixels, fp.stride)
		st.generation, st.frame = fp.generation, fp.frame
	}
	st.epoch = shell.epoch
	return st.tex, true
}

@(private = "file")
note_next :: proc(fp: page.Frame_Pixels) {
	if fp.next_ms >= 0 && (shell.next_ms < 0 || fp.next_ms < shell.next_ms) { shell.next_ms = fp.next_ms }
}

@(private = "file")
want_size :: proc(dst: draw.Rect) -> (int, int) {
	w := int(math.ceil(dst.max.x - dst.min.x))
	h := int(math.ceil(dst.max.y - dst.min.y))
	if shell.api.max_size != nil {
		m := shell.api.max_size(shell.api.user)
		if m > 0 { w, h = min(w, m), min(h, m) }
	}
	return max(w, 1), max(h, 1)
}

@(private = "file")
Placeholder_Kind :: enum u8 { Loading, Ready, Broken }

// Grey box with a picture icon (Ready), a pale box (Loading), or a frame with a crossed picture (Broken).
@(private = "file")
draw_placeholder :: proc(dc: ^draw.Context, r: draw.Rect, kind: Placeholder_Kind) {
	w, h := r.max.x - r.min.x, r.max.y - r.min.y
	if w <= 0 || h <= 0 { return }
	switch kind {
	case .Loading:
		draw.rect(dc, r, draw.srgb(0.93, 0.93, 0.93, 1))
		return
	case .Ready:
		draw.rect(dc, r, draw.srgb(0.78, 0.78, 0.78, 1))
		draw.rect(dc, r, draw.srgb(0.62, 0.62, 0.62, 1), 0, 1)
	case .Broken:
		draw.rect(dc, r, draw.srgb(0.96, 0.96, 0.96, 1))
		draw.rect(dc, r, draw.srgb(0.6, 0.6, 0.6, 1), 0, 1)
	}
	s := min(w, h, 64) * 0.6
	if s < 8 { return }
	c := draw.rect_center(r)
	icon := draw.Rect{c - s * 0.5, c + s * 0.5}
	if kind == .Broken { icon = draw.Rect{r.min + 4, r.min + 4 + s * 0.5}; s *= 0.5 }
	col := kind == .Broken ? draw.srgb(0.55, 0.55, 0.55, 1) : draw.srgb(0.45, 0.45, 0.45, 1)
	draw.rect(dc, icon, col, s * 0.08, max(1, s * 0.06))
	sun := s * 0.16
	draw.rect(dc, {{icon.max.x - s * 0.34, icon.min.y + s * 0.18}, {icon.max.x - s * 0.34 + sun, icon.min.y + s * 0.18 + sun}}, col, sun * 0.5)
	draw.rect(dc, {{icon.min.x + s * 0.14, icon.min.y + s * 0.55}, {icon.min.x + s * 0.5, icon.max.y - s * 0.14}}, col, s * 0.06)
	draw.rect(dc, {{icon.min.x + s * 0.42, icon.min.y + s * 0.42}, {icon.max.x - s * 0.14, icon.max.y - s * 0.14}}, col, s * 0.06)
	if kind == .Broken {
		red := draw.srgb(0.8, 0.2, 0.2, 1)
		n := 8
		for i in 0 ..< n {
			t := f32(i) / f32(n - 1)
			p := icon.min + (icon.max - icon.min) * t
			d := max(1, s * 0.07)
			draw.rect(dc, {p - d, p + d}, red, d)
		}
	}
}

////////////////////////////////
// <img> / <input type=image>

// object-fit / object-position (CSS Images 3 §5.5): where the picture goes in the content box.
@(private = "file")
fit_rect :: proc(content: draw.Rect, natural: [2]f32, cs: ^style.Computed, scale: f32) -> draw.Rect {
	cw, ch := content.max.x - content.min.x, content.max.y - content.min.y
	nw, nh := natural[0] * scale, natural[1] * scale
	if nw <= 0 || nh <= 0 || cs == nil { return content }
	w, h := cw, ch
	switch cs.object_fit {
	case .Fill:
	case .Contain, .Cover:
		k := cs.object_fit == .Contain ? min(cw / nw, ch / nh) : max(cw / nw, ch / nh)
		w, h = nw * k, nh * k
	case .None: w, h = nw, nh
	case .Scale_Down:
		k := min(cw / nw, ch / nh, 1)
		w, h = nw * k, nh * k
	}
	x := content.min.x + style.resolve(cs.object_position[0], (cw - w) / scale) * scale
	y := content.min.y + style.resolve(cs.object_position[1], (ch - h) / scale) * scale
	return {{x, y}, {x + w, y + h}}
}

// The content of an image element; false for other replaced elements (the next painter takes them).
images_paint_content :: proc(dc: ^draw.Context, d: ^dom.Document, node: base.Handle, content, border: draw.Rect, cs: ^style.Computed, fid: font.Font_Id, font_size, scale: f32) -> bool {
	p := shell.page
	if p == nil || d == nil || p.doc != d { return false }
	n := dom.get(d, node)
	if n == nil || n.kind != .Element { return false }
	if n.name != "img" {
		if n.name != "input" { return false }
		t, _ := dom.get_attribute(d, node, "type")
		if !strings.equal_fold(strings.trim_space(t), "image") { return false }
	}
	v := page.image_view(p, node)
	switch v.state {
	case .None:
		paint_alt(dc, d, node, content, cs, fid, font_size)
	case .Loading:
		draw_placeholder(dc, content, .Loading)
	case .Broken:
		draw_placeholder(dc, content, .Broken)
		paint_alt(dc, d, node, content, cs, fid, font_size)
	case .Ready:
		dst := fit_rect(content, v.natural, cs, scale)
		ww, wh := want_size(dst)
		fp := page.frame_pixels(v.id, shell.now_ms, ww, wh, 1000)   // on screen: before anything prefetched
		if !fp.ok { draw_placeholder(dc, content, .Loading); return true }
		note_next(fp)
		tex, ok := texture_for(v.id, fp)
		if !ok { draw_placeholder(dc, content, .Broken); return true }
		clip := dst.min.x < content.min.x || dst.min.y < content.min.y || dst.max.x > content.max.x || dst.max.y > content.max.y
		if clip { draw.push_clip(dc, content) }
		shell.api.draw(shell.api.user, dc, tex, dst, {}, WHITE_TINT, {})
		if clip { draw.pop_clip(dc) }
	}
	return true
}

@(private = "file")
paint_alt :: proc(dc: ^draw.Context, d: ^dom.Document, node: base.Handle, content: draw.Rect, cs: ^style.Computed, fid: font.Font_Id, font_size: f32) {
	alt, ok := dom.get_attribute(d, node, "alt")
	if !ok || alt == "" || cs == nil || fid == 0 { return }
	m := font.metrics(page_render.fonts.state, fid, font_size)
	draw.push_clip(dc, content)
	draw.text(dc, fid, font_size, {content.min.x + 2, content.min.y + m.ascent + 2}, to_draw(cs.color), alt)
	draw.pop_clip(dc)
}

////////////////////////////////
// CSS background images (CSS Backgrounds 3 §3)

// Paints the url() layers of a box's background, bottom layer first. `border` is the border box, `widths` its border
// widths and `pad` its padding (top, right, bottom, left, device px); `radii` the border-box corner radii.
images_paint_backgrounds :: proc(dc: ^draw.Context, cs: ^style.Computed, border: draw.Rect, widths, pad: [4]f32, radii: [4]f32, scale: f32) {
	p := shell.page
	if p == nil || cs == nil || len(cs.background_images) == 0 { return }
	has_url := false
	for im in cs.background_images { if im.kind == .Url { has_url = true; break } }
	if !has_url { return }
	padding := draw.Rect{border.min + {widths[3], widths[0]}, border.max - {widths[1], widths[2]}}
	content := draw.Rect{padding.min + {pad[3], pad[0]}, padding.max - {pad[1], pad[2]}}
	area_of :: proc(a: style.Box_Area, border, padding, content: draw.Rect) -> draw.Rect {
		switch a {
		case .Border_Box: return border
		case .Padding_Box: return padding
		case .Content_Box, .Text: return content
		}
		return border
	}
	layers := style.background_layers(cs)
	max_tiles := the_app != nil ? the_app.page_settings.images.background_tiles : 4096
	for i := len(layers) - 1; i >= 0; i -= 1 {
		layer := layers[i]
		if layer.image.kind != .Url { continue }
		v := page.css_image_view(p, layer.image.url)
		if v.state != .Ready { continue }
		pos_area := area_of(layer.origin, border, padding, content)
		clip_area := area_of(layer.clip, border, padding, content)
		aw, ah := pos_area.max.x - pos_area.min.x, pos_area.max.y - pos_area.min.y
		if aw <= 0 || ah <= 0 { continue }
		// tile size
		nw, nh := v.natural[0] * scale, v.natural[1] * scale
		tw, th := nw, nh
		sz := layer.size
		switch sz.kind {
		case .Auto:
		case .Cover, .Contain:
			k := sz.kind == .Contain ? min(aw / nw, ah / nh) : max(aw / nw, ah / nh)
			tw, th = nw * k, nh * k
		case .Length:
			lw_auto, lh_auto := sz.w.kind == .Auto, sz.h.kind == .Auto
			if !lw_auto { tw = style.resolve(sz.w, aw / scale) * scale }
			if !lh_auto { th = style.resolve(sz.h, ah / scale) * scale }
			if lw_auto && !lh_auto { tw = nh > 0 ? th * nw / nh : tw }
			if lh_auto && !lw_auto { th = nw > 0 ? tw * nh / nw : th }
		}
		rx, ry := layer.repeat[0], layer.repeat[1]
		if rx == .Round && tw > 0 { tw = aw / max(math.round(aw / tw), 1) }
		if ry == .Round && th > 0 { th = ah / max(math.round(ah / th), 1) }
		if tw < 0.5 || th < 0.5 { continue }
		ox := pos_area.min.x + style.resolve(layer.position[0], (aw - tw) / scale) * scale
		oy := pos_area.min.y + style.resolve(layer.position[1], (ah - th) / scale) * scale
		tile := draw.Rect{{ox, oy}, {ox + tw, oy + th}}
		rep_x := rx != .No_Repeat
		rep_y := ry != .No_Repeat
		// what the tiles cover: the clip area, cut to one row / column on an axis that does not repeat
		dst := clip_area
		if !rep_x { dst.min.x, dst.max.x = max(dst.min.x, tile.min.x), min(dst.max.x, tile.max.x) }
		if !rep_y { dst.min.y, dst.max.y = max(dst.min.y, tile.min.y), min(dst.max.y, tile.max.y) }
		if dst.max.x <= dst.min.x || dst.max.y <= dst.min.y { continue }
		ww, wh := want_size(tile)
		fp := page.frame_pixels(v.id, shell.now_ms, ww, wh, 500)
		if !fp.ok { continue }
		note_next(fp)
		tex, ok := texture_for(v.id, fp)
		if !ok { continue }
		draw.push_clip(dc, clip_area)   // (rounded corners do not clip background images yet)
		if (rep_x || rep_y) && shell.api.draw_tiled != nil {
			shell.api.draw_tiled(shell.api.user, dc, tex, dst, tile, WHITE_TINT, {})
		} else {
			// one draw per tile, from the tile grid's cell at the area's corner
			x0 := rep_x ? tile.min.x - math.ceil((tile.min.x - dst.min.x) / tw) * tw : tile.min.x
			y0 := rep_y ? tile.min.y - math.ceil((tile.min.y - dst.min.y) / th) * th : tile.min.y
			count := 0
			for y := y0; y < dst.max.y && count < max_tiles; y += th {
				for x := x0; x < dst.max.x && count < max_tiles; x += tw {
					shell.api.draw(shell.api.user, dc, tex, {{x, y}, {x + tw, y + th}}, {}, WHITE_TINT, {})
					count += 1
					if !rep_x { break }
				}
				if !rep_y { break }
			}
		}
		draw.pop_clip(dc)
	}
}
