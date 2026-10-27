package browser

// The window chrome around the page: navigation buttons, the security chip with its page-information popup, and the
// main menu at the end of the address bar. Built with the toolkit like the rest of the interface.

import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:cookies"
import "wb:fetch"
import "wb:i18n"
import "wb:url"

// Icon-font glyphs used by the chrome (the toolkit's icon font maps them to ASCII letters).
GLYPH_BACK     :: "<"
GLYPH_FORWARD  :: ">"
GLYPH_RELOAD   :: "u"
GLYPH_LOCK     :: "K"
GLYPH_UNLOCK   :: "k"
GLYPH_INFO     :: "i"
GLYPH_FILE     :: "F"
GLYPH_GEAR     :: "G"
GLYPH_COOKIE   :: "E"
GLYPH_COPY     :: "a"
GLYPH_CLOSE    :: "x"
GLYPH_ADD      :: "+"
GLYPH_HOME     :: ""

Tone :: enum u8 { Weak, Good, Warn, Bad }

tone_tag :: proc(t: Tone) -> string {
	switch t {
	case .Weak: return "weak"
	case .Good: return "good"
	case .Warn: return "warn"
	case .Bad:  return "bad"
	}
	return "weak"
}

Security :: struct {
	glyph:    string,
	label:    string,   // shown in the chip
	tone:     Tone,
	headline: string,   // first line of the popup
	detail:   string,
}

security_of :: proc(t: ^Tab) -> Security {
	if t == nil { return {GLYPH_INFO, "", .Weak, "", ""} }
	if t.kind == .Config { return {GLYPH_GEAR, "Settings", .Weak, "Browser settings", "This page edits the preferences of the browser itself. It has no network connection."} }
	if t.kind == .Blocker { return {GLYPH_GEAR, "Blocker", .Weak, "Content blocker", "This page shows and edits the content blocker of the browser. It has no network connection."} }
	if t.page == nil {
		// no response yet: nothing is known about the connection, so claim nothing
		if t.load != nil { return {GLYPH_INFO, "Loading", .Weak, "Loading", "The connection is being established."} }
		return {GLYPH_INFO, "", .Weak, "", ""}
	}
	if t.load != nil {
		// an error page is a page of the browser at the address that failed: claim nothing of a connection that
		// failed, except that a failed secure one is not secure
		switch t.load.failed {
		case .Tls: return {GLYPH_UNLOCK, "Not secure", .Bad, "Connection is not secure", "The secure connection failed: Windows did not accept the certificate or the encryption of this site. Nothing was sent to it."}
		case .Other: return {GLYPH_INFO, "", .Weak, "", ""}
		case .None:
		}
	}
	e := &t.page.env
	switch {
	case e.location.scheme == "about":
		return {GLYPH_INFO, APP_NAME, .Weak, "Built-in page", fmt.tprintf("This page is part of %s. It has no network connection.", APP_NAME)}
	case e.location.scheme == "file":
		return {GLYPH_FILE, "File", .Weak, "Local file", "Loaded from this computer. Scripts of the page can only read files in its own folder."}
	case e.location.scheme == "https":
		return {GLYPH_LOCK, "Secure", .Good, "Connection is secure", "Data exchanged with this site is encrypted with TLS and the certificate was accepted by Windows."}
	case e.secure_context && e.location.scheme == "http":
		return {GLYPH_INFO, "Local", .Weak, "Local connection", "Not encrypted, but the data never leaves this computer."}
	case e.location.scheme == "http":
		return {GLYPH_UNLOCK, "Not secure", .Warn, "Connection is not secure", "Data exchanged with this site is not encrypted. Do not enter passwords or payment details."}
	}
	return {GLYPH_INFO, "Page", .Weak, "Page", ""}
}

////////////////////////////////
// Small helpers

// Tooltip after the pointer rested on `sig` for a moment.
tip :: proc(sig: ui.Signal, text: string) {
	chrome_tip_a11y(sig.box, text)   // (a glyph button's name for screen readers: a11y_chrome.odin)
	if ui.hovered_for(sig, 0.45) {
		if ui.tooltip() {
			em := ui.font_size()
			ui.next({width = ui.text_size(em * 0.7), height = ui.px(ui.dense(em * 2))})
			ui.label(fmt.aprintf("%s###tip", text, allocator = ui.frame_allocator()))
		}
	}
}

@(private)
Burger_Draw :: struct { color: draw.Color }

@(private)
burger_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Burger_Draw)(user)
	r := b.rect
	c := draw.rect_center(r)
	w := (r.max.y - r.min.y) * 0.46
	bar := max(2, (r.max.y - r.min.y) * 0.075)
	gap := w * 0.3
	for i in -1 ..= 1 {
		y := c.y + f32(i) * gap
		draw.rect(dc, {{c.x - w * 0.5, y - bar * 0.5}, {c.x + w * 0.5, y + bar * 0.5}}, d.color, bar * 0.5)
	}
}

// Corner radius of the chrome's buttons (back, forward, reload, the zoom chip, the menu), in em: one shape for all
CHROME_BUTTON_RADIUS :: 0.4

nav_button :: proc(id, glyph, tooltip: string, enabled: bool) -> bool {
	em := ui.font_size()
	clicked := false
	ui.next({width = ui.px(em * 2.1), height = ui.px(ui.dense(em * 2)), radius = em * CHROME_BUTTON_RADIUS})
	if ui.disabled(!enabled) {
		sig := ui.icon_button(id, glyph)
		clicked = sig.clicked
		tip(sig, tooltip)
	}
	return clicked
}

////////////////////////////////
// The address row

// The toolbar's row: navigation, the address bar, its chips, the blocker's shield and the menu. With the tabs in a sidebar
// and an integrated title bar, the same parts are the title bar (sidebar_titlebar, tab_sidebar.odin).
address_row :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	ui.spacer(ui.px(em * 0.5))
	nav_back_button(app, t)
	nav_forward_button(app, t)
	nav_reload_button(app, t)
	ui.spacer(ui.px(em * 0.4))
	address_bar(app, t)
	address_chips(app, t)
	ui.spacer(ui.px(em * 0.4))
	blocker_button(app, t)   // blocker_ui.odin: the content blocker's icon and panel
	ui.spacer(ui.px(em * 0.2))
	main_menu_button(app, t)
	ui.spacer(ui.px(em * 0.5))
}

// (a right click or a long press lists the entries that way: history_ui.odin)
nav_back_button :: proc(app: ^App, t: ^Tab) {
	nav_history_button(app, t, "###nav_back", GLYPH_BACK, i18n.tr("Back (Alt+Left); right click: history"), t != nil && t.hist > 0, -1)
}

nav_forward_button :: proc(app: ^App, t: ^Tab) {
	nav_history_button(app, t, "###nav_forward", GLYPH_FORWARD, i18n.tr("Forward (Alt+Right); right click: history"), t != nil && t.hist + 1 < len(t.history), +1)
}

nav_reload_button :: proc(app: ^App, t: ^Tab) {
	if nav_button("###nav_reload", GLYPH_RELOAD, i18n.tr("Reload (F5)"), t != nil && t.url != "") { reload(app, t) }
}

// The address bar: it fills what its row leaves it.
address_bar :: proc(app: ^App, t: ^Tab) {
	wnd := active_window(app)
	em := ui.font_size()
	// One bar: the field fills it, the security chip sits inside on its left (the field's text starts after it, and its
	// focus ring goes around the whole bar). The chip's width is measured from its parts now (security_chip_measure).
	h := ui.dense(em * 2)
	inset := max(math.round(ui.scale()), 1)   // the field's border: the chip is the bar's left segment, inside it
	chip_w := security_chip_measure(app, t)
	window_own(app).security_chip_width = chip_w
	res: ui.Edit_Result
	ui.next({width = ui.fill(), height = ui.px(h)})
	if ui.row(.Center, {}, "###address_bar") {
		// rounded like the popovers and menus of the chrome (popups: em * 0.5)
		field := ui.Style_Mod{width = ui.pct(1), height = ui.pct(1), radius = em * 0.5}
		if classic_on() {
			// the bar draws the field's frame (white, hollow, outlined: toolbar_draw's neighbour) and the field only its text
			cf := ui.frame_new(Classic_Field)
			cf^ = {c = classic_colors_frame(app), radius = em * CHROME_BUTTON_RADIUS}
			bar := ui.parent_box()
			bar.custom, bar.custom_user = field_frame_draw, cf
			field.radius = cf.radius
			field.bg, field.border = draw.Color{}, draw.Color{}
		}
		if chip_w > 0 { field.text_pad = chip_w + inset + em * 0.5 }
		// not being edited: the address shows from its start (scheme and host), as in Chrome, not scrolled to its end
		// (by key: the focused box's name is last frame's, its text may be gone with that frame's memory)
		window_own(app).address_key = ui.key_from_string(ui.parent_box().key, "###address")
		urlbar_keys(app, t)   // the suggestions' keys, before the field sees them (urlbar.odin)
		if ui.focus_key() != window_own(app).address_key {
			wnd.address.cursor, wnd.address.mark, wnd.address.scroll_x = 0, 0, 0
		}
		ui.next(field)
		ui.a11y({name = i18n.tr("Address and search bar"), shortcut = "Ctrl+L"})
		res = ui.line_edit("###address", &wnd.address, i18n.tr("Search or enter an address"))
		field_radius := res.box != nil ? res.box.radius : em * 0.5
		// The focus ring (the toolkit draws it 1.5 scale units wide, over the field's border) is wider than the border: a chip
		// that starts one border in repaints the inner half of the ring where it covers, so the ring goes from two pixels to
		// one and back at the chip's divider (a double border). The focused bar's chip starts where the ring ends.
		seg_inset := inset
		if ui.focus_key() == window_own(app).address_key { seg_inset = max(math.ceil(1.5 * ui.scale()), inset) }
		security_chip(app, t, seg_inset, h - 2 * seg_inset, max(field_radius - seg_inset, 0))
		zoom_overlay(app, t, res.box, h)
	}
	if bw := active_window(app); bw.focus_address {
		bw.focus_address = false
		if b := res.box; b != nil {   // the field's own box: it sits in the address bar's container
			ui.set_focus(b.key)
			ui.field_select_all(&wnd.address)
			forms_page_blur(app)
		}
	}
	if res.focused { forms_page_blur(app) }
	if urlbar_edited(app, t, res) {
		res.committed = false   // Enter opened the chosen suggestion
	}
	urlbar_popup(app, t, res.box)
	if res.committed && t != nil {
		address := strings.clone(strings.trim_space(ui.field_string(&wnd.address)), context.temp_allocator)
		if address != "" {
			navigate(app, t, address_or_search(address), origin = .User)
			ui.set_focus(0)
			forms_focus_from_chrome(app, t, 1)   // the page has the keyboard after a navigation from the address bar
		}
	}
	if res.cancelled && t != nil { ui.field_set(&wnd.address, t.url) }   // Escape restores the address of the page
	if res.right_clicked { address_context_menu(app, ui.mouse_pos()) }
	if res.focused && (ui.key_press(.Menu) || ui.key_press(.F10, {.Shift})) {
		address_context_menu(app, {res.box.rect.min.x + em, res.box.rect.max.y}, keyboard = true)
	}
}

// What follows the address bar only while it applies: a passkey dialog.
address_chips :: proc(app: ^App, t: ^Tab) {
	webauthn_chip(app, t)   // a passkey dialog is open for the page (webauthn_shell.odin)
}

// The page zoom, when it is not 100 %: a translucent pill over the end of the address field (it pushes nothing, the text
// shows through), "-" 110 % "+" ; the number resets the zoom (Ctrl+0). `field` is the address field (its width is last
// frame's: the pill follows a resize one frame late).
zoom_overlay :: proc(app: ^App, t: ^Tab, field: ^ui.Box, bar_h: f32) {
	if t == nil || zoom_percent(t) == 100 || field == nil { return }
	em := ui.font_size()
	btn, label := em * 1.5, em * 3.1
	pw, ph := 2 * btn + label, em * 1.5
	field_w := field.rect.max.x - field.rect.min.x
	if field_w < pw + em * 6 { return }   // a bar too narrow to leave room for the address
	bg := ui.color("background")
	bd := ui.color("border")
	ui.next({
		fixed_x = field_w - pw - em * 0.45, fixed_y = (bar_h - ph) * 0.5, width = ui.px(pw), height = ui.px(ph), radius = ph * 0.5,
		bg = ui.tuned(draw.Color{bg.r, bg.g, bg.b, 0.82}), border = ui.tuned(draw.Color{bd.r, bd.g, bd.b, 0.7}),
	})
	if ui.row(.Center, {.Draw_Background, .Draw_Border}, "###zoom_pill") {
		ui.next({width = ui.px(btn), height = ui.pct(1), radius = ph * 0.5, text_pad = 0})
		if ui.tags("ghost_button") {
			out := ui.button("−###zoom_out")
			tip(out, "Zoom out (Ctrl+-)")
			if out.clicked { zoom_step(app, t, -1) }
		}
		ui.next({width = ui.px(label), height = ui.pct(1), radius = ph * 0.5, text_pad = 0})
		if ui.tags("ghost_button") {
			z := ui.button(fmt.aprintf("%d %%###zoom_chip", zoom_percent(t), allocator = ui.frame_allocator()))
			tip(z, "Page zoom: click to reset (Ctrl+0)")
			if z.clicked { zoom_set(app, t, 1) }
		}
		ui.next({width = ui.px(btn), height = ui.pct(1), radius = ph * 0.5, text_pad = 0})
		if ui.tags("ghost_button") {
			in_ := ui.button("+###zoom_in")
			tip(in_, "Zoom in (Ctrl++)")
			if in_.clicked { zoom_step(app, t, 1) }
		}
	}
}

// Makes tab `i` the current one.
tab_select :: proc(app: ^App, i: int) {
	wnd := active_window(app)
	if i < 0 || i >= len(wnd.tabs) || i == wnd.current { return }
	wnd.current = i
	ui.field_set(&wnd.address, wnd.tabs[i].url)
	request_frames(app, 2)
	recovery_touch(app)
}

// The page area is a Tab stop of the chrome: Tab from the address bar gives the page the keyboard (its first focusable
// element, or its last one with Shift+Tab); Shift+Tab past the page's first element comes back to the chrome.
page_area_focus :: proc(app: ^App, t: ^Tab, pb: ^ui.Box) {
	if page_focus_leave_backward {
		page_focus_leave_backward = false
		ui.focus_step(active_window(app).ui, pb.key, -1)
		return
	}
	if ui.focus_key() != pb.key { return }
	ui.set_focus(0)
	forms_focus_from_chrome(app, t, ui.tab_direction(active_window(app).ui) < 0 ? -1 : 1)
}

// (Window_Own.page_info_request, set by the page's context menu, opens the page information popup of the security chip;
// Window_Own.main_menu_request, set by Alt+F / Alt+E, the main menu.)

// The key of the window's address field (set when it is built): whether it has the keyboard is asked by key, never by
// ui.focused_name(), which reads the name of a box of the last frame (freed when the build starts).
address_key :: proc(app: ^App) -> ui.Key { return window_own(app).address_key }

// Moves the current tab one place left or right (Ctrl+Shift+Page Up / Page Down).
tab_move_current :: proc(app: ^App, delta: int) {
	wnd := active_window(app)
	to := wnd.current + delta
	if to < 0 || to >= len(wnd.tabs) { return }
	t := wnd.tabs[wnd.current]
	if wnd.tabs[to].pinned != t.pinned { return }   // (pinned tabs stay among themselves: tab_groups.odin)
	if !t.pinned { t.group = wnd.tabs[to].group }   // into the group it moves into, out of its own past its ends
	wnd.current = list_move(wnd.tabs[:], wnd.current, to, wnd.current)
	tabs_fix(app, wnd)
}

////////////////////////////////
// Security chip and page information

// (The width of the security chip, which the address field leaves it, is the window's: Window_Own.security_chip_width,
// set by address_bar from security_chip_measure.)

// `inset` >= 0: placed inside the address field, `inset` from its top-left corner, `height` tall.
Chip_Segment :: struct { color, divider, under: draw.Color, radius: f32, state: string }
Chip_Icon :: struct { glyph: string, color: draw.Color }

// The chip as the address bar's left segment: its tint up to a divider, rounded on the left like the bar.
@(private = "file")
chip_segment_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	s := (^Chip_Segment)(user)
	r := b.rect
	// opaque: the field's text, scrolled to its end while edited, never shows through the chip
	draw.rect_corners(dc, r, {s.under, s.under, s.under, s.under}, {s.radius, s.radius, 0, 0})
	if s.color.a > 0 { draw.rect_corners(dc, r, {s.color, s.color, s.color, s.color}, {s.radius, s.radius, 0, 0}) }
	if s.state != "" {
		f := ui.state_fill(b, s.state, s.under)
		draw.rect_corners(dc, r, {f, f, f, f}, {s.radius, s.radius, 0, 0})
	}
	w := max(math.round(ui.scale()), 1)
	draw.rect(dc, {{r.max.x - w, r.min.y}, {r.max.x, r.max.y}}, s.divider)
}

security_chip :: proc(app: ^App, t: ^Tab, inset: f32 = -1, height: f32 = 0, radius: f32 = 0) {
	em := ui.font_size()
	sec := security_of(t)
	if sec.label == "" { return }
	own := window_own(app)
	chip_segment, chip_icon := &own.chip_segment, &own.chip_icon

	var_tone: draw.Color
	if ui.tags(tone_tag(sec.tone)) { var_tone = ui.color("text") }

	next := ui.Style_Mod{width = ui.children_sum(), height = ui.px(ui.dense(em * 2)), radius = em * 0.5}
	embedded := inset >= 0
	flags := ui.Box_Flags{.Clickable, .Draw_Background, .Draw_Border, .Draw_Hot_Effects}
	if embedded {
		// the bar's left segment: no frame of its own, its tint is drawn by chip_segment_draw (left corners only)
		next.fixed_x, next.fixed_y, next.height, next.width = inset, inset, ui.px(height), ui.px(own.security_chip_width)
		flags = {.Clickable}
		base := sec.tone != .Weak ? var_tone : ui.color("text")
		a: f32 = sec.tone != .Weak ? 0.14 : 0
		chip_segment^ = {color = a > 0 ? ui.tuned(draw.Color{base.r, base.g, base.b, a}) : {}, radius = radius}
		window_bg := ui.color("background")
		window_bg.a = 1
		if ui.tags("input") {
			chip_segment.divider = ui.color("border")
			f := ui.color("background")   // a translucent field: what shows is the field over the window
			chip_segment.under = draw.mix(window_bg, draw.Color{f.r, f.g, f.b, 1}, f.a)
			if classic_on() {
				cc := classic_colors_frame(app)
				chip_segment.divider = cc.field_edge
				chip_segment.under = ui.srgb_step(cc.field_top, cc.field, 0.5)
			}
		}
		ui.next({fixed_x = inset, fixed_y = inset, width = ui.px(own.security_chip_width), height = ui.px(height)})
		ui.custom("###sec_segment", chip_segment_draw, chip_segment)
	} else if sec.tone != .Weak {
		// tints tuned for linear light: ui.tuned keeps their look in an sRGB frame (render.blend_space)
		next.bg = ui.tuned(draw.Color{var_tone.r, var_tone.g, var_tone.b, 0.14})
		next.border = ui.tuned(draw.Color{var_tone.r, var_tone.g, var_tone.b, 0.45})
	}
	ui.next(next)
	b: ^ui.Box
	if ui.row(.Center, flags, "###sec_chip") {
		b = ui.parent_box()
		sig := ui.signal(b)
		// under the pointer / pressed: the theme's step over the segment's tint, as on the chrome's other buttons (the
		// segment is drawn after the build: this frame's state)
		if embedded && sig.hovering { chip_segment.state = sig.dragging ? "press_fill" : "hover_fill" }
		ui.spacer(ui.px(em * 0.5))
		if ui.tags(tone_tag(sec.tone)) {
			chip_icon.glyph = sec.glyph
			chip_icon.color = sec.tone != .Weak ? var_tone : ui.color("text")
			// the icon box is exactly the glyph's ink, centred on the label's capitals (chip_icon_draw); the label has
			// no side padding: the gap between them is the spacer alone
			ink := chip_icon_ink(app, ui.font_size(), sec.glyph)
			ui.next({width = ui.px(ink), height = ui.pct(1)})
			ui.custom("###sec_icon", chip_icon_draw, app)
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.text_size(0), height = ui.pct(1), text_pad = 0})
			ui.label(fmt.aprintf("%s###sec_label", sec.label, allocator = ui.frame_allocator()))
		}
		ui.spacer(ui.px(em * 0.65))
		if own.page_info_request { own.page_info_request = false; sig.clicked = !ui.ctx_menu_is_open(ui.key_from_string(ui.parent_box().parent.key, "###page_info")) }
		if sig.clicked {
			key := ui.key_from_string(ui.parent_box().parent.key, "###page_info")
			if ui.ctx_menu_is_open(key) { ui.ctx_menu_close() } else {
				ui.ctx_menu_open(key, {b.rect.min.x, b.rect.max.y + 6}, b.key)
			}
		}
		tip(sig, "Page information")
	}
	if b != nil { page_info_popup(app, t, sec, b) }
}

// Width of the ink of the chip's icon glyph at this text size (physical pixels).
@(private = "file")
chip_icon_ink :: proc(app: ^App, size: f32, glyph: string) -> f32 {
	if glyph == "" { return 0 }
	g := font.glyph(&app.fonts, app.icons, size, rune(glyph[0]))
	return g.size.x > 0 ? g.size.x : g.advance
}

// The chip's width worked out from its glyph and label while building (the same parts as security_chip), not read back
// from the last layout: on the frame a chip appears (about:config opened from a page without one) the field's text would
// start at 0, under the chip, and with nothing else to draw that frame stays on screen.
@(private = "file")
security_chip_measure :: proc(app: ^App, t: ^Tab) -> f32 {
	sec := security_of(t)
	if sec.label == "" { return 0 }
	em := ui.font_size()
	return em * (0.5 + 0.4 + 0.65) + chip_icon_ink(app, em, sec.glyph) + ui.text_width(ui.top_style().font, em, sec.label)
}

// The icon font's metrics are not the text font's: centring both boxes by their own metrics leaves the glyph off the
// text. The glyph's ink is centred on the middle of the label's capital letters instead (the label is drawn from the
// same box height and the UI font's metrics: draw_ui text_origin).
@(private = "file")
chip_icon_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	app := (^App)(user)
	chip_icon := &window_own(app).chip_icon
	if chip_icon.glyph == "" { return }
	size := b.font_size
	m := font.metrics(&app.fonts, app.ui_font, size)
	cy := (b.rect.min.y + b.rect.max.y) * 0.5
	baseline := math.round(cy + (m.ascent - m.descent) * 0.5)
	cap := font.glyph(&app.fonts, app.ui_font, size, 'H')
	mid := baseline + cap.offset.y + cap.size.y * 0.5
	g := font.glyph(&app.fonts, app.icons, size, rune(chip_icon.glyph[0]))
	pen := draw.Vec2{b.rect.min.x - g.offset.x, math.round(mid - (g.offset.y + g.size.y * 0.5))}
	draw.text(dc, app.icons, size, pen, chip_icon.color, chip_icon.glyph)
}

// Greedy word wrap on character count (the popup uses a proportional font, so this is an estimate that errs short).
wrap_text :: proc(text: string, max_chars: int) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	cur := strings.builder_make(context.temp_allocator)
	for word in strings.split(text, " ", context.temp_allocator) {
		if strings.builder_len(cur) > 0 && strings.builder_len(cur) + 1 + len(word) > max_chars {
			append(&lines, strings.clone(strings.to_string(cur), context.temp_allocator))
			strings.builder_reset(&cur)
		}
		if strings.builder_len(cur) > 0 { strings.write_byte(&cur, ' ') }
		strings.write_string(&cur, word)
	}
	if strings.builder_len(cur) > 0 { append(&lines, strings.clone(strings.to_string(cur), context.temp_allocator)) }
	return lines[:]
}

@(private)
info_row :: proc(label, value, id: string, width: f32) {
	em := ui.font_size()
	ui.next({width = ui.px(width), height = ui.px(ui.dense(em * 1.7))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		if ui.tags("weak") {
			ui.next({width = ui.px(em * 8.5), height = ui.pct(1)})
			ui.label(fmt.aprintf("%s###il_%s", label, id, allocator = ui.frame_allocator()))
		}
		ui.next({width = ui.fill(), height = ui.pct(1)})
		ui.label(fmt.aprintf("%s###iv_%s", value, id, allocator = ui.frame_allocator()))
		ui.spacer(ui.px(em * 0.9))
	}
}

@(private)
action_button :: proc(text, id: string, width: f32) -> bool {
	em := ui.font_size()
	ui.next({width = ui.px(width), height = ui.px(ui.dense(em * 2.1))})
	return ui.button(fmt.aprintf("%s###%s", text, id, allocator = ui.frame_allocator())).clicked
}

enum_label :: proc(v: any) -> string {
	s := fmt.tprintf("%v", v)
	out, _ := strings.replace_all(strings.to_lower(s, context.temp_allocator), "_", "-", context.temp_allocator)
	return out
}

page_info_popup :: proc(app: ^App, t: ^Tab, sec: Security, chip: ^ui.Box) {
	em := ui.font_size()
	key := ui.key_from_string(chip.parent.key, "###page_info")
	w := em * 25
	if ui.ctx_menu(key, w) {
		// header: what the connection is, in the tone of the chip
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 2.4))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.9))
			if ui.tags(tone_tag(sec.tone)) {
				fg: Maybe(draw.Color)
				if sec.tone != .Weak { fg = ui.color("text") }
				ui.icon(sec.glyph, em * 1.6, fg)
				ui.next({width = ui.fill(), height = ui.pct(1)})
				ui.label(fmt.aprintf("%s###pi_head", sec.headline, allocator = ui.frame_allocator()))
			}
		}
		if sec.detail != "" {
			lines := wrap_text(sec.detail, 44)
			ui.next({width = ui.px(w), height = ui.px(ui.dense(em * (1.55 * f32(len(lines)) + 0.3)))})
			if ui.row(.Start) {
				ui.spacer(ui.px(em * 0.9))
				ui.next({width = ui.px(w - em * 1.8), height = ui.pct(1)})
				if ui.column() {
					if ui.tags("weak") {
						for line, i in lines {
							ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.55))})
							ui.label(fmt.aprintf("%s###pi_detail%d", line, i, allocator = ui.frame_allocator()))
						}
					}
				}
			}
		}
		ui.hline(ui.px(w))
		ui.spacer(ui.px(em * 0.3))

		if t != nil && t.page != nil {
			p := t.page
			e := &p.env
			shown := t.url
			if len(shown) > 38 { shown = strings.concatenate({shown[:35], "…"}, context.temp_allocator) }
			info_row("Address", shown, "addr", w)
			if e.location.scheme != "about" {
				info_row("Origin", url.origin_serialize(e.origin, context.temp_allocator), "origin", w)
				info_row("Secure context", e.secure_context ? "yes" : "no", "ctx", w)
				host := e.location.host
				if host != "" {
					n := cookies.count_for_host(&app.profile.jar, host)
					third := app.profile.settings.third_party_cookies == .Block ? "third-party blocked" : "third-party allowed"
					info_row("Cookies", fmt.tprintf("%d (%s)", n, third), "cookies", w)
				}
				info_row("Content policy", len(e.policies.policies) > 0 ? fmt.tprintf("%d polic%s", len(e.policies.policies), len(e.policies.policies) == 1 ? "y" : "ies") : "none", "csp", w)
				info_row("Referrer", e.referrer_policy == .Default ? enum_label(app.profile.settings.referrer_policy) : enum_label(e.referrer_policy), "ref", w)
			}
			info_row("WebAssembly", fmt.tprintf("%d module%s running", len(p.instances), len(p.instances) == 1 ? "" : "s"), "wasm", w)
			info_row("Page size", fmt.tprintf("%d DOM nodes", p.doc.nodes.count), "dom", w)
		}

		ui.spacer(ui.px(em * 0.4))
		ui.hline(ui.px(w))
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 2.2))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.9))
			if action_button("Copy address", "pi_copy", em * 10) && t != nil { clip_set(t.url); ui.ctx_menu_close() }
			ui.spacer(ui.px(em * 0.5))
			host := t != nil && t.page != nil ? t.page.env.location.host : ""
			if ui.disabled(host == "") {
				if action_button("Clear site data", "pi_clear", em * 10) {
					// cookies, localStorage, sessionStorage, IndexedDB and the HTTP cache of the site (about:sites lists them)
					tab_log(t, .Log, clear_site(app, host, CLEAR_ALL))
					ui.ctx_menu_close()
				}
			}
		}
		ui.spacer(ui.px(em * 0.6))
	}
}

////////////////////////////////
// Main menu

main_menu_button :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	ui.next({width = ui.px(em * 2.3), height = ui.px(ui.dense(em * 2)), radius = em * CHROME_BUTTON_RADIUS})
	tone := ui.color("text")
	d := ui.frame_new(Burger_Draw)
	d.color = tone
	ui.push_tags("icon_button")   // (the chrome's other icon buttons' hover and press)
	b := ui.custom("###burger", burger_draw, d, {.Clickable, .Draw_Background, .Draw_Hot_Effects})
	ui.pop_tags()
	sig := ui.signal(b)
	key := ui.key_from_string(b.parent.key, "###main_menu")
	if own := window_own(app); own.main_menu_request {
		// Alt+F / Alt+E: opened from the keyboard, its first item active
		own.main_menu_request = false
		if !ui.ctx_menu_is_open(key) { ui.ctx_menu_open_rect(key, b.rect, b.key, from_keyboard = true) }
	}
	if sig.clicked {
		if ui.ctx_menu_is_open(key) { ui.ctx_menu_close() } else {
			ui.ctx_menu_open_rect(key, b.rect, b.key)
		}
	}
	tip(sig, i18n.tr("Menu"))
	ui.a11y_set(b, {popup = .Menu, expanded = ui.ctx_menu_is_open(key), shortcut = "Alt+F"})

	if ui.ctx_menu(key) {
		// the items are commands of the registry (commands.odin): same titles, shortcuts and conditions as elsewhere
		web := t != nil && t.kind == .Web
		if menu_command(app, t, "tab.new") { return }
		if menu_command(app, t, "tab.reopen_closed") { return }
		if menu_command(app, t, "tab.close") { return }
		ui.menu_separator()
		menu_command(app, t, "nav.back")
		menu_command(app, t, "nav.forward")
		menu_command(app, t, "nav.reload")
		menu_command(app, t, "nav.home")
		menu_command(app, t, "browser.history")
		menu_command(app, t, "browser.history_tree")
		ui.menu_separator()
		if ui.menu_submenu(fmt.tprintf("Zoom (%d %%)###zoom_sub", zoom_percent(t)), enabled = web) {
			menu_command(app, t, "page.zoom_in")
			menu_command(app, t, "page.zoom_out")
			menu_command(app, t, "page.zoom_reset")
		}
		menu_command(app, t, "page.find", force_disabled = !web)
		menu_command(app, t, "page.save")
		menu_command(app, t, "page.view_source")
		menu_command(app, t, "page.print", force_disabled = true)   // not available (print.odin)
		downloads_menu(app)   // download.odin
		ui.menu_separator()
		if ui.menu_submenu("View###view_sub") {
			menu_command(app, t, "view.status_bar")
			menu_command(app, t, "view.smooth_scrolling")
			menu_command(app, t, "view.frame_statistics")
			menu_command(app, t, "view.title_statistics")
			menu_command(app, t, "view.devtools")
			menu_command(app, t, "view.console")
			menu_command(app, t, "view.full_screen")
			menu_command(app, t, "view.tabs_in_title_bar")
			menu_command(app, t, "view.tabs_position.top")
			menu_command(app, t, "view.tabs_position.left")
			menu_command(app, t, "view.tabs_position.right")
			menu_command(app, t, "view.tabs_sidebar_collapse")
			menu_command(app, t, "view.chrome_style.classic")
			menu_command(app, t, "view.chrome_style.modern")
		}
		menu_command(app, t, "browser.command_palette")
		menu_command(app, t, "browser.settings")
		menu_command(app, t, "browser.setup")
		menu_command(app, t, "browser.check_updates")
		menu_command(app, t, "browser.about")
		ui.menu_separator()
		ui.next({width = ui.px(em * 14), height = ui.px(ui.dense(em * 1.8))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.9))
			if ui.tags("weak") { ui.label(fmt.aprintf("%s###about", app_identity(), allocator = ui.frame_allocator())) }
		}
	}
}

////////////////////////////////
// Keyboard shortcuts of the chrome

// The keys the page did not use (forms_shell.odin routes them to the page first; the browser's own shortcuts are never
// the page's: route_key lets them through).
chrome_shortcuts :: proc(app: ^App) {
	// the open command palette has the keyboard (palette.odin), and so has the Setup dialog (setup_ui.odin)
	if palette_open() || setup_is_open() { return }
	t := current_tab(app)
	n := len(active_window(app).tabs)
	ctrl := platform.Modifiers{.Ctrl}
	switch {
	case commands_dispatch(app):   // the registry's shortcuts (commands.odin)
	case t != nil && t.load != nil && t.load.task != base.NIL_HANDLE && ui.focus_key() == 0 && ui.key_press(.Escape):
		// stops a load in progress (the document's request, and the modules still downloading)
		stop_loading(app, t)
	case hud.panel_open && ui.focus_key() == 0 && ui.key_press(.Escape): hud.panel_open = false
	case ui.key_press(.Menu), ui.key_press(.F10, {.Shift}):
		// the menu of what has the keyboard: a tab of the strip, else the page (the address bar handles its own)
		// (by key: before the build, the focused box's name is last frame's, gone with that frame's memory)
		if index := focused_tab_index(app); index >= 0 {
			if b := ui.box_from_key(ui.focus_key()); b != nil {
				tab_context_menu(app, index, {b.rect.min.x, b.rect.max.y}, keyboard = true)
			}
		} else if t != nil && t.kind == .Web && page_has_keyboard(app) {
			page_context_menu_keyboard(app, t)
		}
	}
	for k in platform.Key.N1 ..= platform.Key.N8 {
		if ui.key_press(k, ctrl) { tab_select(app, min(int(k) - int(platform.Key.N1), n - 1)) }
	}
	if ui.key_press(.N9, ctrl) { tab_select(app, n - 1) }
}

// Escape while loading: the requests of the document stop (what arrived stays).
stop_loading :: proc(app: ^App, t: ^Tab) {
	load := t.load
	if load == nil { return }
	stopped := false
	if load.task != base.NIL_HANDLE { fetch.cancel(&app.loader, load.task); load.task = base.NIL_HANDLE; stopped = true }
	for s in load.slots { if s.state == .Pending { s.state = .Failed; stopped = true } }
	if stopped { set_status(t, "Stopped"); load.stopped = true }
	if load.page == nil { t.load = nil }   // nothing arrived: the tab is no longer loading (the scope still owns the load)
	request_frames(app, 2)
}
