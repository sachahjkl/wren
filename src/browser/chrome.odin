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

address_row :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	can_back := t != nil && t.hist > 0
	can_forward := t != nil && t.hist + 1 < len(t.history)

	ui.spacer(ui.px(em * 0.5))
	// a right click or a long press lists the entries that way (history_ui.odin)
	nav_history_button(app, t, "###nav_back", GLYPH_BACK, "Back (Alt+Left); right click: history", can_back, -1)
	nav_history_button(app, t, "###nav_forward", GLYPH_FORWARD, "Forward (Alt+Right); right click: history", can_forward, +1)
	if nav_button("###nav_reload", GLYPH_RELOAD, "Reload (F5)", t != nil && t.url != "") { reload(app, t) }
	ui.spacer(ui.px(em * 0.4))

	// One bar: the field fills it, the security chip sits inside on its left (the field's text starts after it, and its
	// focus ring goes around the whole bar). The chip's width is last frame's: it changes only with its label.
	h := ui.dense(em * 2)
	inset := max(math.round(ui.scale()), 1)   // the field's border: the chip is the bar's left segment, inside it
	chip_w := security_of(t).label != "" ? security_chip_width : 0
	res: ui.Edit_Result
	ui.next({width = ui.fill(), height = ui.px(h)})
	if ui.row(.Center, {}, "###address_bar") {
		// rounded like the popovers and menus of the chrome (popups: em * 0.5)
		field := ui.Style_Mod{width = ui.pct(1), height = ui.pct(1), radius = em * 0.5}
		if chip_w > 0 { field.text_pad = chip_w + inset + em * 0.5 }
		// not being edited: the address shows from its start (scheme and host), as in Chrome, not scrolled to its end
		// (by key: the focused box's name is last frame's, its text may be gone with that frame's memory)
		address_key = ui.key_from_string(ui.parent_box().key, "###address")
		urlbar_keys(app, t)   // the suggestions' keys, before the field sees them (urlbar.odin)
		if ui.focus_key() != address_key {
			app.address.cursor, app.address.mark, app.address.scroll_x = 0, 0, 0
		}
		ui.next(field)
		res = ui.line_edit("###address", &app.address, "Search or enter an address")
		field_radius := res.box != nil ? res.box.radius : em * 0.5
		security_chip(app, t, inset, h - 2 * inset, max(field_radius - inset, 0))
	}
	if app.focus_address {
		app.focus_address = false
		if b := res.box; b != nil {   // the field's own box: it sits in the address bar's container
			ui.set_focus(b.key)
			ui.field_select_all(&app.address)
			forms_page_blur()
		}
	}
	if res.focused { forms_page_blur() }
	if urlbar_edited(app, t, res) {
		res.committed = false   // Enter opened the chosen suggestion
	}
	urlbar_popup(app, t, res.box)
	if res.committed && t != nil {
		address := strings.clone(strings.trim_space(ui.field_string(&app.address)), context.temp_allocator)
		if address != "" {
			navigate(app, t, address_or_search(address))
			ui.set_focus(0)
			forms_focus_from_chrome(app, t, 1)   // the page has the keyboard after a navigation from the address bar
		}
	}
	if res.cancelled && t != nil { ui.field_set(&app.address, t.url) }   // Escape restores the address of the page
	if res.right_clicked { address_context_menu(app, ui.mouse_pos()) }
	if res.focused && (ui.key_press(.Menu) || ui.key_press(.F10, {.Shift})) {
		address_context_menu(app, {res.box.rect.min.x + em, res.box.rect.max.y}, keyboard = true)
	}

	// page zoom, when not 100 %: click to reset
	if t != nil && zoom_percent(t) != 100 {
		ui.spacer(ui.px(em * 0.3))
		ui.next({width = ui.text_size(em * 0.4), height = ui.px(ui.dense(em * 1.8)), radius = em * CHROME_BUTTON_RADIUS})
		if ui.tags("ghost_button") {
			z := ui.button(fmt.aprintf("%d %%###zoom_chip", zoom_percent(t), allocator = ui.frame_allocator()))
			tip(z, "Page zoom: click to reset (Ctrl+0)")
			if z.clicked { zoom_set(app, t, 1) }
		}
	}
	webauthn_chip(app, t)   // a passkey dialog is open for the page (webauthn_shell.odin)

	ui.spacer(ui.px(em * 0.4))
	main_menu_button(app, t)
	ui.spacer(ui.px(em * 0.5))
}

// Makes tab `i` the current one.
tab_select :: proc(app: ^App, i: int) {
	if i < 0 || i >= len(app.tabs) || i == app.current { return }
	app.current = i
	ui.field_set(&app.address, app.tabs[i].url)
	app.frames_requested = max(app.frames_requested, 2)
}

// The page area is a Tab stop of the chrome: Tab from the address bar gives the page the keyboard (its first focusable
// element, or its last one with Shift+Tab); Shift+Tab past the page's first element comes back to the chrome.
page_area_focus :: proc(app: ^App, t: ^Tab, pb: ^ui.Box) {
	if page_focus_leave_backward {
		page_focus_leave_backward = false
		ui.focus_step(&app.ui_state, pb.key, -1)
		return
	}
	if ui.focus_key() != pb.key { return }
	ui.set_focus(0)
	forms_focus_from_chrome(app, t, ui.tab_direction(&app.ui_state) < 0 ? -1 : 1)
}

// Set by the page's context menu: open the page information popup of the security chip.
page_info_request: bool

// Key of the address field (set when it is built): whether it has the keyboard is asked by key, never by
// ui.focused_name(), which reads the name of a box of the last frame (freed when the build starts).
address_key: ui.Key

// Set by Alt+F / Alt+E: open the main menu.
main_menu_request: bool

// Moves the current tab one place left or right (Ctrl+Shift+Page Up / Page Down).
tab_move_current :: proc(app: ^App, delta: int) {
	to := app.current + delta
	if to < 0 || to >= len(app.tabs) { return }
	app.current = list_move(app.tabs[:], app.current, to, app.current)
	app.frames_requested = max(app.frames_requested, 2)
}

////////////////////////////////
// Security chip and page information

// Width of the security chip at the last layout (the address field leaves it that much room).
@(private = "file")
security_chip_width: f32


// `inset` >= 0: placed inside the address field, `inset` from its top-left corner, `height` tall.
Chip_Segment :: struct { color, divider, under: draw.Color, radius: f32, state: string }

@(private = "file")
chip_segment: Chip_Segment

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

	var_tone: draw.Color
	if ui.tags(tone_tag(sec.tone)) { var_tone = ui.color("text") }

	next := ui.Style_Mod{width = ui.children_sum(), height = ui.px(ui.dense(em * 2)), radius = em * 0.5}
	embedded := inset >= 0
	flags := ui.Box_Flags{.Clickable, .Draw_Background, .Draw_Border, .Draw_Hot_Effects}
	if embedded {
		// the bar's left segment: no frame of its own, its tint is drawn by chip_segment_draw (left corners only)
		next.fixed_x, next.fixed_y, next.height = inset, inset, ui.px(height)
		flags = {.Clickable}
		base := sec.tone != .Weak ? var_tone : ui.color("text")
		a: f32 = sec.tone != .Weak ? 0.14 : 0
		chip_segment = {color = a > 0 ? ui.tuned(draw.Color{base.r, base.g, base.b, a}) : {}, radius = radius}
		window_bg := ui.color("background")
		window_bg.a = 1
		if ui.tags("input") {
			chip_segment.divider = ui.color("border")
			f := ui.color("background")   // a translucent field: what shows is the field over the window
			chip_segment.under = draw.mix(window_bg, draw.Color{f.r, f.g, f.b, 1}, f.a)
		}
		ui.next({fixed_x = inset, fixed_y = inset, width = ui.px(security_chip_width), height = ui.px(height)})
		ui.custom("###sec_segment", chip_segment_draw, &chip_segment)
	} else if sec.tone != .Weak {
		// tints tuned for linear light: ui.tuned keeps their look in an sRGB frame (render.blend_space)
		next.bg = ui.tuned(draw.Color{var_tone.r, var_tone.g, var_tone.b, 0.14})
		next.border = ui.tuned(draw.Color{var_tone.r, var_tone.g, var_tone.b, 0.45})
	}
	ui.next(next)
	b: ^ui.Box
	if ui.row(.Center, flags, "###sec_chip") {
		b = ui.parent_box()
		security_chip_width = b.rect.max.x - b.rect.min.x
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
			ink := chip_icon_ink(app, ui.font_size())
			ui.next({width = ui.px(ink), height = ui.pct(1)})
			ui.custom("###sec_icon", chip_icon_draw, app)
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.text_size(0), height = ui.pct(1), text_pad = 0})
			ui.label(fmt.aprintf("%s###sec_label", sec.label, allocator = ui.frame_allocator()))
		}
		ui.spacer(ui.px(em * 0.65))
		if page_info_request { page_info_request = false; sig.clicked = !ui.ctx_menu_is_open(ui.key_from_string(ui.parent_box().parent.key, "###page_info")) }
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

@(private = "file")
chip_icon: struct { glyph: string, color: draw.Color }

// Width of the ink of the chip's icon glyph at this text size (physical pixels).
@(private = "file")
chip_icon_ink :: proc(app: ^App, size: f32) -> f32 {
	if chip_icon.glyph == "" { return 0 }
	g := font.glyph(&app.fonts, app.icons, size, rune(chip_icon.glyph[0]))
	return g.size.x > 0 ? g.size.x : g.advance
}

// The icon font's metrics are not the text font's: centring both boxes by their own metrics leaves the glyph off the
// text. The glyph's ink is centred on the middle of the label's capital letters instead (the label is drawn from the
// same box height and the UI font's metrics: draw_ui text_origin).
@(private = "file")
chip_icon_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	app := (^App)(user)
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
				if action_button("Clear cookies", "pi_clear", em * 10) {
					n := cookies.delete_for_host(&app.profile.jar, host)
					tab_log(t, .Log, fmt.tprintf("cleared %d cookie(s) for %s", n, host))
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
	if main_menu_request {
		// Alt+F / Alt+E: opened from the keyboard, its first item active
		main_menu_request = false
		if !ui.ctx_menu_is_open(key) { ui.ctx_menu_open_rect(key, b.rect, b.key, from_keyboard = true) }
	}
	if sig.clicked {
		if ui.ctx_menu_is_open(key) { ui.ctx_menu_close() } else {
			ui.ctx_menu_open_rect(key, b.rect, b.key)
		}
	}
	tip(sig, "Menu")

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
			menu_command(app, t, "view.frame_statistics")
			menu_command(app, t, "view.title_statistics")
			menu_command(app, t, "view.console")
			menu_command(app, t, "view.full_screen")
			menu_command(app, t, "view.tabs_in_title_bar")
		}
		menu_command(app, t, "browser.command_palette")
		menu_command(app, t, "browser.settings")
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
	// the open command palette has the keyboard (palette.odin)
	if palette_open() { return }
	t := current_tab(app)
	n := len(app.tabs)
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
	app.frames_requested = max(app.frames_requested, 2)
}
