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
import "core:strconv"
import "core:strings"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:render"
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
	device_generation: u64,          // render.Renderer.device_generation the textures were made on
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
	set_replaced_sizes(lay.Replaced_Api{user = app, intrinsic = shell_intrinsic, ratio = shell_ratio})
	video_shell_init(app)
}

// The natural ratio of a replaced element that has no natural size (an SVG image or inline <svg> with only a viewBox).
@(private = "file")
shell_ratio :: proc(user: rawptr, node: base.Handle) -> f32 {
	p := shell.page
	if p == nil { return 0 }
	if n := dom.get(p.doc, node); n != nil && n.name == "svg" { return page.inline_svg_ratio(p, node) }
	v := page.image_view(p, node)
	return v.state == .Ready && v.ratio_only ? v.ratio : 0
}

// The natural size of an image element (CSS px), as decoded: its width / height attributes are presentational hints
// (style, hints.odin: CSS width / height and aspect-ratio: auto w / h), not a natural size; a broken image without them
// is as large as its icon and alt text. ok = false: nothing known (layout uses its placeholder size).
@(private = "file")
shell_intrinsic :: proc(user: rawptr, node: base.Handle) -> (w, h: f32, ok: bool) {
	p := shell.page
	if p == nil { return 0, 0, false }
	d := p.doc
	if n := dom.get(d, node); n != nil && n.name == "svg" { return page.inline_svg_intrinsic(p, node) }
	if n := dom.get(d, node); n != nil && n.name == "video" { return page.media_intrinsic(p, node) }
	attr :: proc(d: ^dom.Document, h: base.Handle, name: string) -> (f32, bool) {
		v, ok := dom.get_attribute(d, h, name)
		if !ok { return 0, false }
		t := strings.trim_space(v)
		end := 0
		for end < len(t) && ((t[end] >= '0' && t[end] <= '9') || t[end] == '.') { end += 1 }
		if end == 0 || (end < len(t) && t[end] == '%') { return 0, false }
		n, nok := strconv.parse_f32(t[:end])
		return n, nok && n >= 0
	}
	_, has_w := attr(d, node, "width")
	_, has_h := attr(d, node, "height")
	v := page.image_view(p, node)
	if v.state == .Ready {
		// an SVG with a ratio and no size: the layout stretches it to its containing block (shell_ratio)
		if v.ratio_only { return 0, 0, false }
		return v.natural[0], v.natural[1], true
	}
	if v.state != .Broken || has_w || has_h { return 0, 0, false }
	// broken, no dimensions: the icon, then the alt text (alt="" means the image is decoration: nothing at all)
	alt, has_alt := dom.get_attribute(d, node, "alt")
	if has_alt && alt == "" { return 0, 0, true }
	icon := f32(the_app != nil ? the_app.page_settings.images.broken_icon_px : 16)
	if !has_alt { return icon + 4, icon + 4, true }
	cs: ^style.Computed
	if i := int(base.handle_index(node)); p.styled != nil && i < len(p.styled.by_node) { cs = p.styled.by_node[i] }
	if cs == nil || the_app == nil { return icon + 4, icon + 4, true }
	text := page_text_api(&page_render.fonts, &the_app.measure, &the_app.page_settings.style)
	f := text.font(text.user, cs.font_family, cs.font_weight, cs.font_style != .Normal)
	tw := text.width(text.user, f, cs.font_size, alt)
	return icon + 8 + tw, max(icon + 4, cs.font_size * 1.25), true
}

// Connects the renderer's textures (see the top of this file). Textures made by the previous API are released.
images_set_texture_api :: proc(api: Texture_Api) {
	release_all_textures()
	shell.api = api
}

images_shell_destroy :: proc(app: ^App) {
	video_shell_destroy(app)
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

// The document whose images layout and painting read now (a frame's while it is laid out or painted: frames_shell.odin);
// returns the one before.
images_shell_page_swap :: proc(p: ^page.Page) -> ^page.Page {
	old := shell.page
	shell.page = p
	return old
}

// Before the layout of `t`: natural sizes come from its page, and a size that became known makes the layout stale.
images_before_layout :: proc(t: ^Tab) {
	shell.page = t.page
	page.images_sync(t.page)
	// a new generation makes the layout check the natural sizes it used (layout_stale / layout_document)
	t.image_sizes = page.images_sizes_generation(t.page)
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
	// the GPU device was recreated (render.recover): texture contents are gone, decoded frames are uploaded again
	if app.r.device_generation != shell.device_generation {
		shell.device_generation = app.r.device_generation
		release_all_textures()
	}
	page.images_paint_begin()
	video_shell_begin_frame(app)
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
			a.frames_requested = max(a.frames_requested, 2)
		}, app)
	}
	enforce_texture_budget(app)
	video_shell_after_paint(app)
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
	}
	s := kind == .Broken ? min(w, h) : min(w, h, 64) * 0.6
	if s < 6 { return }
	c := draw.rect_center(r)
	icon := draw.Rect{c - s * 0.5, c + s * 0.5}

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

// The corner radii of the content box of a replaced element (draw corner order), from its border-radius.
content_radii :: proc(cs: ^style.Computed, border, content: draw.Rect, scale: f32) -> [4]f32 {
	if cs == nil { return {} }
	outer := lay.border_radii(cs, border.max.x - border.min.x, border.max.y - border.min.y, scale)
	if outer == {} { return {} }
	// insets top, right, bottom, left: the border and the padding together
	return padding_radii(outer, {content.min.y - border.min.y, border.max.x - content.max.x, border.max.y - content.max.y, content.min.x - border.min.x})
}

// The content of an image element; false for other replaced elements (the next painter takes them).
images_paint_content :: proc(dc: ^draw.Context, d: ^dom.Document, node: base.Handle, content, border: draw.Rect, cs: ^style.Computed, fid: font.Font_Id, font_size, scale: f32) -> bool {
	p := shell.page
	if p == nil || d == nil || p.doc != d { return false }
	n := dom.get(d, node)
	if n == nil || n.kind != .Element { return false }
	if n.name == "svg" {
		paint_inline_svg(dc, node, content, scale)
		return true
	}
	if n.name == "video" { return video_paint_content(dc, p, node, content, border, cs, scale) }   // (video_shell.odin)
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
		paint_broken(dc, d, node, content, cs, fid, font_size, scale)
	case .Ready:
		dst := fit_rect(content, v.natural, cs, scale)
		ww, wh := want_size(dst)
		fp := page.frame_pixels(v.id, shell.now_ms, ww, wh, 1000)   // on screen: before anything prefetched
		if !fp.ok { draw_placeholder(dc, content, .Loading); return true }
		note_next(fp)
		tex, ok := texture_for(fp.texture, fp)
		if !ok { draw_placeholder(dc, content, .Broken); return true }
		// border-radius rounds the picture with the content box (CSS Backgrounds §5.3: the inner radii); object-fit may
		// put it past the box, which then clips it
		radii := content_radii(cs, border, content, scale)
		clip := dst.min.x < content.min.x || dst.min.y < content.min.y || dst.max.x > content.max.x || dst.max.y > content.max.y || radii != {}
		if clip { draw.push_clip_rounded(dc, content, radii) }
		shell.api.draw(shell.api.user, dc, tex, dst, {}, WHITE_TINT, {})
		if clip { draw.pop_clip(dc) }
	}
	return true
}

// An inline <svg>: its markup rendered at the content box's device size (nothing while it is being rendered, nothing
// when it cannot be: an inline SVG has no broken-image icon).
@(private = "file")
paint_inline_svg :: proc(dc: ^draw.Context, node: base.Handle, content: draw.Rect, scale: f32) {
	s := max(scale, 0.01)
	cw, ch := content.max.x - content.min.x, content.max.y - content.min.y
	if cw < 0.5 || ch < 0.5 { return }
	v := page.inline_svg_view(shell.page, node, cw / s, ch / s)
	if v.state != .Ready { return }
	ww, wh := want_size(content)
	fp := page.frame_pixels(v.id, shell.now_ms, ww, wh, 1000)
	if !fp.ok { return }
	tex, ok := texture_for(fp.texture, fp)
	if !ok { return }
	shell.api.draw(shell.api.user, dc, tex, content, {}, WHITE_TINT, {})
}

// A broken image: a thin frame when the box is larger than the icon, the icon at the top left, the alt text after it.
@(private = "file")
paint_broken :: proc(dc: ^draw.Context, d: ^dom.Document, node: base.Handle, content: draw.Rect, cs: ^style.Computed, fid: font.Font_Id, font_size, scale: f32) {
	icon := f32(the_app != nil ? the_app.page_settings.images.broken_icon_px : 16) * scale
	w, h := content.max.x - content.min.x, content.max.y - content.min.y
	if w <= 0 || h <= 0 { return }
	if w > icon + 8 * scale || h > icon + 8 * scale { draw.rect(dc, content, draw.srgb(0.6, 0.6, 0.6, 1), 0, max(1, scale * 0.75)) }
	pad := 2 * scale
	box := draw.Rect{content.min + pad, content.min + pad + icon}
	draw.push_clip(dc, content)
	draw_placeholder(dc, box, .Broken)
	alt, ok := dom.get_attribute(d, node, "alt")
	if ok && alt != "" && cs != nil && fid != 0 {
		m := font.metrics(page_render.fonts.state, fid, font_size)
		y := box.min.y + (icon + m.ascent - m.descent) * 0.5
		draw.text(dc, fid, font_size, {box.max.x + 4 * scale, y}, to_draw(cs.color), alt)
	}
	draw.pop_clip(dc)
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

// Paints one url() layer of a box's background: `pos_area` is its positioning area (background-origin), `clip_area`
// and `clip_radii` its painting area (background-clip, rounded like the box).
images_paint_background_layer :: proc(dc: ^draw.Context, layer: ^style.Bg_Layer, pos_area, clip_area: draw.Rect, clip_radii: [4]f32, scale: f32) {
	p := shell.page
	if p == nil || layer.image.kind != .Url { return }
	max_tiles := the_app != nil ? the_app.page_settings.images.background_tiles : 4096
	{
		v := page.css_image_view(p, layer.image.url)
		if v.state != .Ready { return }
		aw, ah := pos_area.max.x - pos_area.min.x, pos_area.max.y - pos_area.min.y
		if aw <= 0 || ah <= 0 { return }
		// tile size
		nw, nh := v.natural[0] * scale, v.natural[1] * scale
		tw, th := nw, nh
		sz := layer.size
		switch sz.kind {
		case .Auto:
			// CSS Images 3 §5.2 default sizing: an SVG with a ratio and no size is contained in the area, one with
			// neither fills it
			if v.svg && v.ratio_only {
				k := min(aw / nw, ah / nh)
				tw, th = nw * k, nh * k
			} else if v.svg && !v.has_size[0] && !v.has_size[1] {
				tw, th = aw, ah
			}
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
		if tw < 0.5 || th < 0.5 { return }
		ox := pos_area.min.x + style.resolve(layer.position[0], (aw - tw) / scale) * scale
		oy := pos_area.min.y + style.resolve(layer.position[1], (ah - th) / scale) * scale
		tile := draw.Rect{{ox, oy}, {ox + tw, oy + th}}
		rep_x := rx != .No_Repeat
		rep_y := ry != .No_Repeat
		// what the tiles cover: the clip area, cut to one row / column on an axis that does not repeat
		dst := clip_area
		if !rep_x { dst.min.x, dst.max.x = max(dst.min.x, tile.min.x), min(dst.max.x, tile.max.x) }
		if !rep_y { dst.min.y, dst.max.y = max(dst.min.y, tile.min.y), min(dst.max.y, tile.max.y) }
		if dst.max.x <= dst.min.x || dst.max.y <= dst.min.y { return }
		ww, wh := want_size(tile)
		fp := page.frame_pixels(v.id, shell.now_ms, ww, wh, 500)
		if !fp.ok { return }
		note_next(fp)
		tex, ok := texture_for(fp.texture, fp)
		if !ok { return }
		// the painting area, with the box's rounded corners
		if clip_radii == {} { draw.push_clip(dc, clip_area) } else { draw.push_clip_rounded(dc, clip_area, clip_radii) }
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

// The renderer's RGBA textures (toolkit render / draw), connected at start-up.
renderer_texture_api :: proc(app: ^App) -> Texture_Api {
	return Texture_Api{
		user     = app,
		create   = proc(u: rawptr, w, h: int) -> Image_Texture { return Image_Texture(render.create_texture_rgba(&(^App)(u).r, w, h)) },
		update   = proc(u: rawptr, t: Image_Texture, x, y, w, h: int, px: []u8, stride: int) { render.update_texture_rgba(&(^App)(u).r, render.Texture(t), x, y, w, h, px, stride) },
		destroy  = proc(u: rawptr, t: Image_Texture) { render.destroy_texture(&(^App)(u).r, render.Texture(t)) },
		draw     = proc(u: rawptr, dc: ^draw.Context, t: Image_Texture, dst, src: draw.Rect, tint: draw.Color, radii: [4]f32) { draw.image_corners(dc, render.Texture(t), dst, src, tint, radii) },
		draw_tiled = proc(u: rawptr, dc: ^draw.Context, t: Image_Texture, dst, tile: draw.Rect, tint: draw.Color, radii: [4]f32) { draw.image_tiled(dc, render.Texture(t), dst, tile, tint, radii) },
		max_size = proc(u: rawptr) -> int { return render.max_texture_size(&(^App)(u).r) },
	}
}
