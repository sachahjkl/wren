package browser

// The toolbar buttons of extensions (docs/extensions.md, section 3.10): one per enabled extension with an `action`, after
// the content blocker's shield. A button shows the action's icon for the tab (action.setIcon with a path, else the
// manifest's), its badge (action.setBadgeText, at most 4 characters, on its background colour) and its title as a
// tooltip. A click opens the popup under it (ext_popup.odin), or fires action.onClicked when no popup is set.
//
// The icon is fetched like any file of the extension (chrome-extension://, read on the blocking pool), decoded on the
// image threads and kept as a texture by URL: a frame only draws it. Until it is ready, and when it fails, the button
// shows the extension's initial, as Chrome does. Past browser.extensions.toolbar.max_buttons, the others are left out
// of the toolbar (about:extensions lists them; an overflow menu comes later).

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:extensions"
import "wb:fetch"
import "wb:host"
import "wb:images"
import "wb:page"

EXT_ICON_MAX_BYTES :: 1 << 20   // an icon larger than this is not an icon: the initial shows instead

Ext_Icon_State :: enum u8 { Loading, Decoding, Ready, Failed }

Ext_Icon :: struct {
	app:   ^App,
	url:   string,          // owned (the key)
	state: Ext_Icon_State,
	task:  base.Handle,
	job:   images.Job_Id,
	blob:  ^images.Blob,
	tex:   render.Texture,
}

Ext_Toolbar :: struct {
	icons: map[string]^Ext_Icon,
	port:  images.Port_Id,
}

ext_toolbar_destroy :: proc(app: ^App) {
	tb := &app.ext.toolbar
	if tb.port != 0 { images.port_close(tb.port) }
	for _, ic in tb.icons {
		if ic.task != base.NIL_HANDLE { fetch.cancel(&app.loader, ic.task) }
		images.job_cancel(ic.job)
		if ic.tex != 0 { render.destroy_texture(&app.r, ic.tex) }
		if ic.blob != nil { images.blob_release(ic.blob) }
		delete(ic.url)
		free(ic)
	}
	delete(tb.icons)
	tb^ = {}
}

// The icon's texture once decoded; its load starts the first time it is asked for.
@(private = "file")
ext_icon_texture :: proc(app: ^App, address: string) -> (render.Texture, bool) {
	tb := &app.ext.toolbar
	if ic := tb.icons[address]; ic != nil { return ic.tex, ic.state == .Ready }
	ic := new(Ext_Icon)
	ic.app = app
	ic.url = strings.clone(address)
	tb.icons[ic.url] = ic
	// (no initiator: the browser itself asks, which the scheme lets read any file of the extension)
	ic.task = fetch.start(&app.loader, {
		request = {url = address, mode = .No_Cors, credentials = .Omit, redirect = .Error, destination = .Image, max_body = EXT_ICON_MAX_BYTES},
		on_event = ext_icon_event, user = ic, collect = true,
	})
	return 0, false
}

@(private = "file")
ext_icon_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	ic := (^Ext_Icon)(user)
	app := ic.app
	#partial switch ev.kind {
	case .Done:
		ic.task = base.NIL_HANDLE
		if len(ev.data) == 0 { ic.state = .Failed; return }
		if !images.decoder_running() {
			s := &app.page_settings.images
			n := s.decode_threads
			if n < 0 { n = clamp(host.processor_count() / 2, 1, 4) }
			images.decoder_start(n, s.decode_stack_bytes > 0 ? s.decode_stack_bytes : images.DECODER_STACK_DEFAULT, s.decode_idle_ms)
		}
		tb := &app.ext.toolbar
		if tb.port == 0 { tb.port = images.port_open(&app.loop, ext_icon_decoded, nil) }
		if tb.port == 0 { ic.state = .Failed; return }
		bytes := make([]byte, len(ev.data))
		copy(bytes, ev.data)
		ic.blob = images.blob_make(bytes)
		px := int(32 * ui_scale_of(app) + 0.5)
		lim := app.page_settings.images.limits
		lim.max_dimension = min(lim.max_dimension, 1024)
		lim.max_pixels = min(lim.max_pixels, 1024 * 1024)
		lim.max_encoded_bytes = min(lim.max_encoded_bytes, EXT_ICON_MAX_BYTES)
		opts := images.Decode_Options{limits = lim, target_w = px, target_h = px, downscale_below = 0.99, first_frame_only = true}
		ic.state = .Decoding
		ic.job = images.submit(tb.port, images.job_make(.Decode, ic.blob, opts, user = ic))
		if ic.job == 0 { ic.state = .Failed }
	case .Failed:
		ic.task = base.NIL_HANDLE
		ic.state = .Failed
	}
}

@(private = "file")
ext_icon_decoded :: proc(user: rawptr, j: ^images.Job) {
	defer images.job_free(j)
	ic := (^Ext_Icon)(j.user)
	app := ic.app
	ic.job = 0
	img := j.image
	if j.err != .None || img == nil || len(img.frames) == 0 || img.width <= 0 || img.height <= 0 { ic.state = .Failed; return }
	ic.tex = render.create_texture_rgba(&app.r, img.width, img.height)
	render.update_texture_rgba(&app.r, ic.tex, 0, 0, img.width, img.height, img.frames[0].pixels, img.stride)
	ic.state = .Ready
	request_frames(app, 2)
}

////////////////////////////////
// The buttons

@(private = "file")
Ext_Button_Draw :: struct {
	app:      ^App,
	tex:      render.Texture,
	has_tex:  bool,
	letter:   string,
	badge:    string,
	badge_bg: draw.Color,
	ink:      draw.Color,
	dim:      bool,     // the action is disabled
	radius:   f32,
	focus:    draw.Color,
}

// The buttons of the extensions for tab `t` (address_row, chrome.odin).
ext_toolbar_buttons :: proc(app: ^App, t: ^Tab) {
	if !app.ext.started { return }
	reg := ext_reg(app)
	if !reg.settings.enabled { return }
	shown := 0
	for e in reg.list {
		if !e.enabled || e.image == nil || !e.image.ok || !e.image.manifest.has_action { continue }
		if shown >= reg.settings.toolbar_max_buttons { break }
		shown += 1
		ext_button(app, t, e)
		ui.spacer(ui.px(ui.font_size() * 0.2))
	}
}

@(private = "file")
ext_button :: proc(app: ^App, t: ^Tab, e: ^extensions.Extension) {
	em := ui.font_size()
	tab_id := t != nil ? t.id : 0
	title, popup, badge, color, icon := page.ext_action_view(e, tab_id)
	d := ui.frame_new(Ext_Button_Draw)
	d.app = app
	if icon != "" { d.tex, d.has_tex = ext_icon_texture(app, extensions.image_url(e.image, icon)) }
	name := e.image.manifest.short_name != "" ? e.image.manifest.short_name : e.image.manifest.name
	if r, size := utf8.decode_rune_in_string(name); size > 0 { d.letter = strings.to_upper(utf8.runes_to_string([]rune{r}, context.temp_allocator), ui.frame_allocator()) }
	// (four characters at most, as in Chrome: a longer text is cut)
	if n := utf8.rune_count_in_string(badge); n > 4 {
		cut := 0
		for _ in 0 ..< 4 { _, s := utf8.decode_rune_in_string(badge[cut:]); cut += s }
		badge = badge[:cut]
	}
	d.badge = strings.clone(badge, ui.frame_allocator())
	d.badge_bg = draw.Color{f32(color[0]) / 255, f32(color[1]) / 255, f32(color[2]) / 255, f32(color[3]) / 255}
	d.ink = ui.color("text")
	d.focus = ui.color("focus border")
	d.dim = !e.action.enabled
	d.radius = em * CHROME_BUTTON_RADIUS
	ui.next({width = ui.px(em * 2.3), height = ui.px(ui.dense(em * 2)), radius = d.radius})
	ui.push_tags("icon_button")
	b := ui.custom(fmt.aprintf("###ext_%s", e.id, allocator = ui.frame_allocator()), ext_button_draw, d, {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects})
	ui.pop_tags()
	sig := ui.signal(b)
	tip(sig, title != "" ? title : e.image.manifest.name)
	if ep := app.ext.popup; ep != nil && ep.ext == e.id { ext_popup_build(app, b.rect) }   // ext_popup.odin: its panel, under the button
	if sig.clicked && e.action.enabled {
		if popup != "" {
			ext_open_popup(app, e, popup)
		} else {
			// action.onClicked with the tab (its URL only when the extension may see it: page side decides on calls; here the id)
			page.ext_emit(e.id, "action.onClicked", fmt.tprintf(`[{{"id":%d}}]`, tab_id))
		}
	}
}

@(private = "file")
ext_button_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Ext_Button_Draw)(user)
	r := b.rect
	bh := r.max.y - r.min.y
	c := draw.rect_center(r)
	s := math.round(bh * 0.5)   // the icon's square: the size of the row's other glyphs
	sq := draw.Rect{{math.round(c.x - s * 0.5), math.round(c.y - s * 0.5)}, {}}
	sq.max = sq.min + {s, s}
	tint := draw.WHITE
	if d.dim { tint.a = 0.45 }
	if d.has_tex {
		draw.image(dc, d.tex, sq, {}, tint)
	} else {
		// the initial on a rounded square, as Chrome shows an extension without an icon
		bg := d.ink
		bg.a = d.dim ? 0.25 : 0.55
		draw.rect(dc, sq, bg, s * 0.25)
		size := s * 0.7
		tw := font.text_width(&d.app.fonts, d.app.ui_font, size, d.letter)
		ink := draw.Color{1, 1, 1, d.dim ? 0.6 : 1}
		draw.text(dc, d.app.ui_font, size, {math.round(c.x - tw * 0.5), math.round(c.y + size * 0.36)}, ink, d.letter)
	}
	if d.badge != "" {
		size := ui.font_size() * 0.57
		tw := font.text_width(&d.app.fonts, d.app.ui_font, size, d.badge)
		bhh := math.round(size * 1.22)
		bw := math.round(max(tw + size * 0.55, bhh))
		edge := max(1, math.round(ui.scale()))
		left := math.round(min(sq.max.x - bw * 0.5, r.max.x - bw - edge))
		top := math.round(sq.max.y - bhh * 0.75)
		top = min(top, r.max.y - bhh - edge)
		br := draw.Rect{{left, top}, {left + bw, top + bhh}}
		draw.rect(dc, {{br.min.x - edge, br.min.y - edge}, {br.max.x + edge, br.max.y + edge}}, ui.color("background"), bhh * 0.5 + edge)
		draw.rect(dc, br, d.badge_bg, bhh * 0.5)
		draw.text(dc, d.app.ui_font, size, {math.round(br.min.x + (bw - tw) * 0.5), math.round(br.min.y + bhh * 0.5 + size * 0.36)}, draw.Color{1, 1, 1, 1}, d.badge)
	}
	if ui.focus_key() == b.key {
		draw.rect(dc, {{r.min.x + 1, r.min.y + 1}, {r.max.x - 1, r.max.y - 1}}, d.focus, d.radius, max(2, ui.scale() * 1.5))
	}
}
