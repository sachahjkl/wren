package browser

// The building blocks of the developer tools' interface, in the density of a developer tool: 12 px text, rows of 20
// px, toolbar buttons of 22 px that are only an icon (no frame until the pointer is on them), one-pixel separators.
// Everything is sized from `dtm` (made once per frame by dt_begin, from the panel's font size and density) and colored
// from `dtc` (the theme's colors, light or dark), so the panel follows the chrome. The lists are virtual with row
// heights of our own, and the rows are single boxes that paint all their cells, so a list of 100 000 rows costs what
// is on screen.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:text/regex"
import "core:unicode/utf8"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:platform"
import "toolkit:ui"

Dt_Density :: enum u8 { Compact, Comfortable }

Dt_Metrics :: struct {
	sc:       f32,            // the interface's scale (DPI x zoom)
	fs:       f32,            // text of the interface (physical px)
	mono_fs:  f32,
	ui_font:  font.Font_Id,
	mono:     font.Font_Id,
	row:      f32,            // a list row
	bar:      f32,            // a toolbar
	tab:      f32,            // the tab strip
	btn:      f32,            // a toolbar button
	line:     f32,            // one pixel (at least)
	pad:      f32,            // a small gap: 4 logical px
	icon:     f32,            // an icon inside a button
	radius:   f32,
}

Dt_Colors :: struct {
	dark:        bool,
	bg, bar, text, weak, faint, border, border_soft, accent, accent_text: draw.Color,
	hover, press, sel, sel_weak, zebra, input:    draw.Color,
	good, warn, bad:                              draw.Color,
	bad_bg, warn_bg, accent_bg, good_bg:          draw.Color,
}

dtm: Dt_Metrics
dtc: Dt_Colors

// Logical pixels to physical, rounded.
dt_px :: proc(v: f32) -> f32 { return math.round(v * dtm.sc) }

// Makes the metrics and colors of this frame; the panel calls it before building anything.
dt_begin :: proc(app: ^App) {
	hud_mono(app)
	sc := ui.scale()
	pt := math.clamp(dev.font_pt, 8, 24)
	comfy := dev.density == .Comfortable
	k := pt / 12
	dtm = {
		sc = sc, fs = math.round(pt * sc), mono_fs = math.round(pt * sc), ui_font = app.ui_font, mono = ui.mono_font(),
		row = math.round((comfy ? 24 : 20) * k * sc), bar = math.round((comfy ? 30 : 26) * k * sc), tab = math.round((comfy ? 30 : 26) * k * sc),
		btn = math.round((comfy ? 26 : 22) * k * sc), line = max(math.round(sc), 1), pad = math.round(4 * sc), icon = math.round(14 * k * sc),
		radius = math.round(3 * sc),
	}
	c := &dtc
	c.bg = ui.color("background")
	c.text = ui.color("text")
	c.border = ui.color("border")
	c.accent = ui.color("accent")
	c.sel = ui.color("selection")
	if ui.tags("zebra") { c.zebra = ui.color("background") }
	if ui.tags("weak") { c.weak = ui.color("text") }
	if ui.tags("bar") { c.bar = ui.color("background") }
	if ui.tags("input") { c.input = ui.color("background") }
	if ui.tags("accent_button") { c.accent_text = ui.color("text") }
	if ui.tags("good") { c.good = ui.color("text") }
	if ui.tags("warn") { c.warn = ui.color("text") }
	if ui.tags("bad") { c.bad = ui.color("text") }
	lum := 0.2126 * c.bg.r + 0.7152 * c.bg.g + 0.0722 * c.bg.b
	c.dark = lum < 0.35
	ink := c.dark ? draw.Color{1, 1, 1, 1} : draw.Color{0, 0, 0, 1}
	c.hover, c.press = ink, ink
	c.hover.a, c.press.a = 0.07, 0.13
	c.faint = c.text
	c.faint.a = 0.38
	c.border_soft = c.border
	c.border_soft.a = c.border.a * 0.55
	c.sel_weak = c.accent
	c.sel_weak.a = 0.16
	c.bad_bg, c.warn_bg, c.accent_bg, c.good_bg = c.bad, c.warn, c.accent, c.good
	c.bad_bg.a, c.warn_bg.a, c.accent_bg.a, c.good_bg.a = 0.10, 0.07, 0.14, 0.08
	c.hover, c.press, c.sel_weak, c.bad_bg, c.warn_bg, c.accent_bg, c.good_bg = ui.tuned(c.hover), ui.tuned(c.press), ui.tuned(c.sel_weak), ui.tuned(c.bad_bg), ui.tuned(c.warn_bg), ui.tuned(c.accent_bg), ui.tuned(c.good_bg)
}

with_alpha :: proc(c: draw.Color, a: f32) -> draw.Color { r := c; r.a = a; return r }

////////////////////////////////
// Text

// The width of `s` in font `f` at `size`.
dt_w :: proc(f: font.Font_Id, size: f32, s: string) -> f32 { return font.text_width(&the_app.fonts, f, size, s) }

// `s` cut with an ellipsis so that it fits in `avail` pixels; the width it takes. Temp memory when it was cut.
dt_fit :: proc(f: font.Font_Id, size: f32, s: string, avail: f32) -> (out: string, w: f32) {
	if avail <= 0 || s == "" { return "", 0 }
	w = dt_w(f, size, s)
	if w <= avail { return s, w }
	ell := "\u2026"
	ew := dt_w(f, size, ell)
	x := ew
	end := 0
	for r, i in s {
		a := font.glyph(&the_app.fonts, f, size, r).advance
		if x + a > avail { break }
		x += a
		end = i + utf8.rune_size(r)
	}
	if end == 0 { return "", 0 }
	return strings.concatenate({s[:end], ell}, context.temp_allocator), x
}

// Baseline for text of font `f` at `size` centered on `cy`.
dt_baseline :: proc(f: font.Font_Id, size: f32, cy: f32) -> f32 {
	m := font.metrics(&the_app.fonts, f, size)
	return math.round(cy + (m.ascent - m.descent) * 0.5)
}

// Text clipped to [x, x + maxw], centered on `cy`; returns the width drawn. `maxw` < 0: no limit, no ellipsis.
dt_text :: proc(dc: ^draw.Context, f: font.Font_Id, size: f32, x, cy: f32, col: draw.Color, s: string, maxw: f32 = -1) -> f32 {
	if s == "" { return 0 }
	t, w := s, f32(0)
	if maxw >= 0 { t, w = dt_fit(f, size, s, maxw) } else { w = dt_w(f, size, s) }
	if t == "" { return 0 }
	draw.text(dc, f, size, {math.round(x), dt_baseline(f, size, cy)}, col, t)
	return w
}

// Text right-aligned to `right`.
dt_text_r :: proc(dc: ^draw.Context, f: font.Font_Id, size: f32, right, cy: f32, col: draw.Color, s: string, maxw: f32 = -1) {
	t, w := s, f32(0)
	if maxw >= 0 { t, w = dt_fit(f, size, s, maxw) } else { w = dt_w(f, size, s) }
	if t == "" { return }
	draw.text(dc, f, size, {math.round(right - w), dt_baseline(f, size, cy)}, col, t)
}

// A span of colored text (syntax highlighting, selectors, values).
Dt_Run :: struct { text: string, col: draw.Color }

// Runs one after the other from `x`, cut at `limit` (an ellipsis closes the last one); returns the x after them.
dt_runs :: proc(dc: ^draw.Context, f: font.Font_Id, size: f32, x, cy: f32, runs: []Dt_Run, limit: f32) -> f32 {
	at := x
	base := dt_baseline(f, size, cy)
	for r in runs {
		if r.text == "" { continue }
		room := limit - at
		if room <= 0 { break }
		t, w := dt_fit(f, size, r.text, room)
		if t == "" { break }
		draw.text(dc, f, size, {math.round(at), base}, r.col, t)
		at += w
		if w < dt_w(f, size, r.text) - 0.5 { break }
	}
	return at
}

// A line for a label: one line, cut at max_runes, with nothing in it the toolkit reads as an id ("###").
dev_line :: proc(s: string, max_runes := 500) -> string {
	out := s
	if strings.contains(out, "###") { out, _ = strings.replace_all(out, "###", "#\u200b##", context.temp_allocator) }
	if strings.contains_any(out, "\r\n\t") {
		out, _ = strings.replace_all(out, "\r\n", " \u00b6 ", context.temp_allocator)
		out, _ = strings.replace_all(out, "\n", " \u00b6 ", context.temp_allocator)
		out, _ = strings.replace_all(out, "\r", " ", context.temp_allocator)
		out, _ = strings.replace_all(out, "\t", "  ", context.temp_allocator)
	}
	n := 0
	for _, i in out {
		if n == max_runes { return strings.concatenate({out[:i], "\u2026"}, context.temp_allocator) }
		n += 1
	}
	return out
}

// A string copied into this frame's memory (what a box's custom drawing holds).
dt_frame_str :: proc(s: string) -> string { return strings.clone(s, ui.frame_allocator()) }

////////////////////////////////
// Layout bits

dt_gap :: proc(logical: f32) { ui.spacer(ui.px(dt_px(logical))) }

// A one-pixel vertical rule between groups of a toolbar.
dt_vsep :: proc(id: string) {
	h := dtm.btn * 0.62
	ui.next({width = ui.px(dtm.line), height = ui.px(h), bg = dtc.border})
	ui.build_box({.Draw_Background}, id)
}

// A one-pixel horizontal rule.
dt_hsep :: proc(id: string, col: Maybe(draw.Color) = nil) {
	ui.next({width = ui.fill(), height = ui.px(dtm.line), bg = col.? or_else dtc.border})
	ui.build_box({.Draw_Background}, id)
}

// A bar: a full-width row of `h` pixels on the bar color with a rule below it (the last one of the panel's tool rows).
@(deferred_none = ui.pop_parent)
dt_bar :: proc(id: string, h: f32 = 0, rule := true) -> bool {
	hh := h > 0 ? h : dtm.bar
	flags := ui.Box_Flags{.Draw_Background}
	if rule { flags += {.Draw_Side_Bottom} }
	ui.next({width = ui.fill(), height = ui.px(hh), axis = .X, cross = .Center, bg = dtc.bar, border = dtc.border})
	b := ui.build_box(flags, id)
	ui.push_parent(b)
	return true
}

////////////////////////////////
// Buttons

Dt_Btn_Draw :: struct {
	icon:    Dt_Icon,
	label:   string,
	hot, down, on, focus: bool,
	badge:   string,
	badge_col: draw.Color,
	caret:   bool,
	col:     draw.Color,
	on_col:  draw.Color,
	label_w: f32,
	flat:    bool,           // no frame ever (a tab's close, an inline button)
	accent:  bool,           // a call to action (filled)
}

@(private = "file")
btn_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Dt_Btn_Draw)(user)
	r := b.rect
	rad := dtm.radius
	if d.accent {
		draw.rect(dc, r, d.down ? draw.mix(dtc.accent, dtc.text, 0.15) : (d.hot ? draw.mix(dtc.accent, dtc.text, 0.08) : dtc.accent), rad)
	} else if d.on {
		draw.rect(dc, r, dtc.accent_bg, rad)
		if d.down { draw.rect(dc, r, dtc.press, rad) } else if d.hot { draw.rect(dc, r, dtc.hover, rad) }
	} else if d.down {
		draw.rect(dc, r, dtc.press, rad)
	} else if d.hot {
		draw.rect(dc, r, dtc.hover, rad)
	}
	col := d.col
	if d.on { col = d.on_col }
	if d.accent { col = dtc.accent_text }
	cy := (r.min.y + r.max.y) * 0.5
	x := r.min.x
	hasText := d.label != ""
	pad := dt_px(hasText ? 6 : 0)
	total := (d.icon != .None ? dtm.icon : 0) + (d.icon != .None && hasText ? dt_px(4) : 0) + d.label_w + (d.caret ? dtm.icon * 0.7 + (hasText || d.icon != .None ? dt_px(2) : 0) : 0)
	bw := r.max.x - r.min.x
	if !hasText && !d.caret { x = r.min.x + (bw - total) * 0.5 } else { x = r.min.x + pad }
	if d.icon != .None {
		dt_icon(dc, d.icon, {math.round(x + dtm.icon * 0.5), cy}, dtm.icon, col, dtm.sc)
		x += dtm.icon + (hasText ? dt_px(4) : 0)
	}
	if hasText {
		dt_text(dc, dtm.ui_font, dtm.fs, x, cy, col, d.label)
		x += d.label_w
	}
	if d.badge != "" {
		bx := r.max.x - dt_px(2) - (d.caret ? dtm.icon * 0.7 + dt_px(2) : 0)
		pw := dt_w(dtm.ui_font, dtm.fs * 0.82, d.badge) + dt_px(6)
		bh := dtm.fs * 1.12
		draw.rect(dc, {{bx - pw, cy - bh * 0.5 - dt_px(5)}, {bx, cy + bh * 0.5 - dt_px(5)}}, d.badge_col, bh * 0.5)
		dt_text(dc, dtm.ui_font, dtm.fs * 0.82, bx - pw + dt_px(3), cy - dt_px(5), draw.Color{1, 1, 1, 1}, d.badge)
	}
	if d.caret {
		dt_icon(dc, .Chevron_Down, {math.round(r.max.x - dt_px(4) - dtm.icon * 0.35), cy}, dtm.icon * 0.7, with_alpha(col, col.a * 0.8), dtm.sc)
	}
}

// A toolbar button: an icon (and maybe a label, a badge, a drop-down chevron) with no frame until the pointer is on it;
// `on` shows it switched on (a toggle), `enabled` false mutes it. The tooltip shows its name and shortcut.
dt_btn :: proc(id: string, icon: Dt_Icon, label := "", tooltip := "", shortcut := "", on := false, enabled := true,
               badge := "", badge_col := draw.Color{}, caret := false, accent := false, w: f32 = 0, tone := draw.Color{}) -> ui.Signal {
	label_w := label != "" ? dt_w(dtm.ui_font, dtm.fs, label) : 0
	width := w
	if width <= 0 {
		if label == "" && !caret { width = dtm.btn } else {
			width = dt_px(6) * 2 + (icon != .None ? dtm.icon : 0) + (icon != .None && label != "" ? dt_px(4) : 0) + label_w + (caret ? dtm.icon * 0.7 + dt_px(label != "" || icon != .None ? 2 : 0) : 0)
		}
	}
	sig: ui.Signal
	if ui.disabled(!enabled) {
		ui.next({width = ui.px(math.round(width)), height = ui.px(dtm.btn), cursor = .Arrow})
		b := ui.build_box({.Clickable, .Focusable}, id)
		sig = ui.signal(b)
		d := ui.frame_new(Dt_Btn_Draw)
		d.icon, d.label, d.on, d.hot, d.down = icon, dt_frame_str(label), on, sig.hovering, sig.dragging && sig.hovering
		d.badge, d.badge_col, d.caret, d.label_w, d.accent = dt_frame_str(badge), badge_col, caret, label_w, accent
		d.col = tone.a > 0 ? tone : (sig.hovering ? dtc.text : dtc.weak)
		d.on_col = tone.a > 0 ? tone : dtc.accent
		b.custom, b.custom_user = btn_draw, d
	}
	if tooltip != "" { dt_tip(sig, tooltip, shortcut) }
	return sig
}

Dt_Chip_Draw :: struct { label: string, on, hot, down: bool, w: f32, count: string }

@(private = "file")
chip_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Dt_Chip_Draw)(user)
	r := b.rect
	rad := dtm.radius
	if d.on {
		draw.rect(dc, r, dtc.accent_bg, rad)
		draw.rect(dc, r, with_alpha(dtc.accent, 0.5), rad, dtm.line)
	} else if d.down { draw.rect(dc, r, dtc.press, rad) } else if d.hot { draw.rect(dc, r, dtc.hover, rad) }
	cy := (r.min.y + r.max.y) * 0.5
	col := d.on ? dtc.accent : (d.hot ? dtc.text : dtc.weak)
	x := r.min.x + dt_px(7)
	x += dt_text(dc, dtm.ui_font, dtm.fs, x, cy, col, d.label)
	if d.count != "" { dt_text(dc, dtm.ui_font, dtm.fs * 0.88, x + dt_px(4), cy, with_alpha(col, 0.7), d.count) }
}

// A text chip that is on or off (filter by type, a quick switch). Returns its signal; `count` is shown beside the label.
dt_chip :: proc(id, label: string, on: bool, tooltip := "", count := "") -> ui.Signal {
	w := dt_w(dtm.ui_font, dtm.fs, label) + dt_px(14) + (count != "" ? dt_w(dtm.ui_font, dtm.fs * 0.88, count) + dt_px(4) : 0)
	ui.next({width = ui.px(math.round(w)), height = ui.px(dtm.btn - dt_px(4)), cursor = .Arrow})
	b := ui.build_box({.Clickable, .Focusable}, id)
	sig := ui.signal(b)
	d := ui.frame_new(Dt_Chip_Draw)
	d.label, d.on, d.hot, d.down, d.count = dt_frame_str(label), on, sig.hovering, sig.dragging && sig.hovering, dt_frame_str(count)
	b.custom, b.custom_user = chip_draw, d
	if tooltip != "" { dt_tip(sig, tooltip) }
	return sig
}

// A compact tooltip: the name, and the shortcut in a weaker color.
dt_tip :: proc(sig: ui.Signal, text: string, shortcut := "") {
	if ui.hovered_for(sig, 0.4) {
		if ui.tooltip() {
			w := dt_w(dtm.ui_font, dtm.fs, text) + dt_px(14) + (shortcut != "" ? dt_w(dtm.ui_font, dtm.fs, shortcut) + dt_px(12) : 0)
			ui.next({width = ui.px(math.round(w)), height = ui.px(dt_px(22)), axis = .X, cross = .Center})
			if ui.row(.Center, {}, "###dt_tip_row") {
				ui.next({width = ui.text_size(dt_px(7)), height = ui.pct(1)})
				ui.label(fmt.aprintf("%s###dt_tip", text, allocator = ui.frame_allocator()))
				if shortcut != "" {
					if ui.tags("weak") {
						ui.next({width = ui.text_size(dt_px(2)), height = ui.pct(1)})
						ui.label(fmt.aprintf("%s###dt_tip_key", shortcut, allocator = ui.frame_allocator()))
					}
				}
			}
		}
	}
}

// A button that opens a menu below it: the caller builds the menu's items under `if ui.ctx_menu(key, width)`.
dt_menu_btn :: proc(id: string, icon: Dt_Icon, label := "", tooltip := "", shortcut := "", badge := "", badge_col := draw.Color{}, on := false, caret := true) -> ui.Key {
	key := ui.key_from_u64(ui.key_from_string(ui.parent_box().key, id), 0xd0d0)
	open := ui.ctx_menu_is_open(key)
	sig := dt_btn(id, icon, label, open ? "" : tooltip, shortcut, on = on || open, badge = badge, badge_col = badge_col, caret = caret)
	if sig.clicked {
		if open { ui.ctx_menu_close() } else { ui.ctx_menu_open_rect(key, sig.box.rect, sig.box.key) }
	}
	return key
}

////////////////////////////////
// The search / filter field

Dt_Filter :: struct {
	field:  ui.Text_Field,
	use_re: bool,
	cased:  bool,
	invert: bool,
	re:     regex.Regular_Expression,
	re_src: string,        // owned: the pattern `re` was made from
	re_ok:  bool,
	re_bad: bool,          // the pattern is not valid
	terms:  [dynamic]Dt_Term,   // the words of a plain filter, made again when the text or the case switch changes
	terms_serial: u64,
}

Dt_Term :: struct { text: string, neg: bool }   // owned

dt_filter_destroy :: proc(f: ^Dt_Filter) {
	ui.field_destroy(&f.field)
	if f.re_ok { regex.destroy_regex(f.re) }
	delete(f.re_src)
	for t in f.terms { delete(t.text) }
	delete(f.terms)
	f^ = {}
}

// ASCII case-insensitive "contains" without allocating (`needle` is lower case already).
dt_contains_fold :: proc(hay, needle: string) -> bool {
	n := len(needle)
	if n == 0 { return true }
	if n > len(hay) { return false }
	for i in 0 ..= len(hay) - n {
		j := 0
		for j < n {
			c := hay[i + j]
			if c >= 'A' && c <= 'Z' { c += 32 }
			if c != needle[j] { break }
			j += 1
		}
		if j == n { return true }
	}
	return false
}

dt_filter_text :: proc(f: ^Dt_Filter) -> string { return strings.trim_space(ui.field_string(&f.field)) }

dt_filter_active :: proc(f: ^Dt_Filter) -> bool { return dt_filter_text(f) != "" }

// A stable value that changes when anything the matching depends on changed (to know when to filter again).
dt_filter_serial :: proc(f: ^Dt_Filter) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for c in transmute([]u8)ui.field_string(&f.field) { h = (h ~ u64(c)) * 0x100000001b3 }
	h = (h ~ u64(f.use_re ? 1 : 0) ~ u64(f.cased ? 2 : 0) ~ u64(f.invert ? 4 : 0)) * 0x100000001b3
	return h
}

// Gets the filter ready for a run of dt_filter_match calls (the words of a plain filter, the compiled pattern of a regular
// expression); returns its serial, which changes when what it matches changes.
dt_filter_prepare :: proc(f: ^Dt_Filter) -> u64 {
	ser := dt_filter_serial(f)
	if f.terms_serial == ser && (f.use_re || len(f.terms) > 0 || dt_filter_text(f) == "") { return ser }
	for t in f.terms { delete(t.text) }
	clear(&f.terms)
	f.terms_serial = ser
	q := dt_filter_text(f)
	if q == "" || f.use_re { return ser }
	it := q
	for term in strings.fields_iterator(&it) {
		neg := len(term) > 1 && term[0] == '-'
		t := neg ? term[1:] : term
		append(&f.terms, Dt_Term{text = f.cased ? strings.clone(t) : strings.to_lower(t), neg = neg})
	}
	return ser
}

// Whether `text` passes the filter: a substring (or a regular expression), case-insensitive unless asked,
// with `-word` terms excluding and the whole sense reversed by `invert` (dt_filter_prepare first).
dt_filter_match :: proc(f: ^Dt_Filter, text: string) -> bool {
	q := dt_filter_text(f)
	if q == "" { return true }
	ok := false
	if f.use_re {
		if f.re_src != q || (!f.re_ok && !f.re_bad) {
			if f.re_ok { regex.destroy_regex(f.re); f.re_ok = false }
			delete(f.re_src)
			f.re_src = strings.clone(q)
			flags := regex.Flags{}
			if !f.cased { flags += {.Case_Insensitive} }
			re, err := regex.create(q, flags)
			f.re_ok, f.re_bad = err == nil, err != nil
			if err == nil { f.re = re }
		}
		if f.re_ok {
			cap, found := regex.match(f.re, text)
			regex.destroy_capture(cap)
			ok = found
		} else { ok = true }   // an invalid pattern shows everything (and the field is marked)
	} else {
		ok = true
		for term in f.terms {
			has := f.cased ? strings.contains(text, term.text) : dt_contains_fold(text, term.text)
			if term.neg == has { ok = false; break }
		}
	}
	return f.invert ? !ok : ok
}

// The field: a magnifier, the text, "Aa" and ".*" switches and a clear button inside one bordered box. `w` 0: fills.
dt_search :: proc(id: string, f: ^Dt_Filter, placeholder: string, w: f32 = 0, flags := true) -> ui.Edit_Result {
	h := dtm.btn - dt_px(2)
	if w > 0 { ui.next({width = ui.px(w), height = ui.px(h), axis = .X, cross = .Center}) } else { ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center}) }
	holder := ui.build_box({}, id)
	res: ui.Edit_Result
	if ui.parent(holder) {
		right_pad := dt_px(6) + (flags ? dt_px(48) : 0)
		active := f.field.buf != nil && len(f.field.buf) > 0
		if active { right_pad += dt_px(20) }
		if f.re_bad { ui.push_tags("bad") }
		ui.next({width = ui.pct(1), height = ui.pct(1), radius = dtm.radius, text_pad = dt_px(24)})
		res = ui.line_edit("###f", &f.field, placeholder)
		if f.re_bad { ui.pop_tags() }
		width := holder.size.x
		// the magnifier
		ui.next({fixed_x = dt_px(5), fixed_y = (h - dtm.icon) * 0.5, width = ui.px(dtm.icon), height = ui.px(dtm.icon)})
		ui.custom("###mag", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			dt_icon(dc, .Search, draw.rect_center(b.rect), dtm.icon, dtc.faint, dtm.sc)
		}, nil)
		if width > 0 {
			x := width - dt_px(4)
			if active {
				x -= dt_px(18)
				ui.next({fixed_x = x, fixed_y = (h - dt_px(18)) * 0.5, width = ui.px(dt_px(18)), height = ui.px(dt_px(18))})
				cb := ui.build_box({.Clickable}, "###clr")
				cs := ui.signal(cb)
				d := ui.frame_new(Dt_Btn_Draw)
				d.icon, d.hot, d.down = .Close, cs.hovering, cs.dragging
				cb.custom, cb.custom_user = field_clear_draw, d
				if cs.clicked { ui.field_clear(&f.field); res.changed = true }
				dt_tip(cs, "Clear the filter")
			}
			if flags {
				for k in 0 ..< 2 {
					x -= dt_px(22)
					on := k == 0 ? f.cased : f.use_re
					ui.next({fixed_x = x, fixed_y = (h - dt_px(18)) * 0.5, width = ui.px(dt_px(21)), height = ui.px(dt_px(18))})
					tb := ui.build_box({.Clickable}, k == 0 ? "###case" : "###re")
					ts := ui.signal(tb)
					d := ui.frame_new(Dt_Btn_Draw)
					d.label, d.on, d.hot, d.down = k == 0 ? "Aa" : ".*", on, ts.hovering, ts.dragging
					tb.custom, tb.custom_user = field_toggle_draw, d
					if ts.clicked {
						if k == 0 { f.cased = !f.cased } else { f.use_re = !f.use_re }
						res.changed = true
					}
					dt_tip(ts, k == 0 ? "Match case" : "Use a regular expression")
				}
			}
		}
	}
	return res
}

@(private = "file")
field_clear_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Dt_Btn_Draw)(user)
	r := b.rect
	if d.hot { draw.rect(dc, r, dtc.hover, dtm.radius) }
	dt_icon(dc, .Close, draw.rect_center(r), dtm.icon * 0.8, d.hot ? dtc.text : dtc.weak, dtm.sc)
}

@(private = "file")
field_toggle_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Dt_Btn_Draw)(user)
	r := b.rect
	if d.on { draw.rect(dc, r, dtc.accent_bg, dtm.radius); draw.rect(dc, r, with_alpha(dtc.accent, 0.55), dtm.radius, dtm.line) } else if d.hot { draw.rect(dc, r, dtc.hover, dtm.radius) }
	cy := (r.min.y + r.max.y) * 0.5
	w := dt_w(dtm.mono, dtm.fs * 0.86, d.label)
	dt_text(dc, dtm.mono, dtm.fs * 0.86, (r.min.x + r.max.x) * 0.5 - w * 0.5, cy, d.on ? dtc.accent : dtc.weak, d.label)
}

////////////////////////////////
// A list of rows of known heights

// Scrolling state of a list. The rows are built by the caller between dt_list and its end; `offs` (n + 1 cumulative
// tops) is given when the heights differ, else every row is `row_h`.
Dt_List :: struct {
	key:       ui.Key,
	total:     f32,
	view:      f32,
	at_end:    bool,
	n_last:    int,
	sel:       int,        // active row (0: the first, until the user picks; -1: none)
	focused:   bool,
	reveal:    int,        // row to bring into view (-1: none)
}

Dt_Rows :: struct { first, last: int, l: ^Dt_List, n: int, row_h: f32, offs: []f32 }

dt_list_destroy :: proc(l: ^Dt_List) { l^ = {} }

// The row at content height `y`.
dt_row_at :: proc(offs: []f32, row_h: f32, n: int, y: f32) -> int {
	if n <= 0 { return 0 }
	if offs == nil { return clamp(int(y / max(row_h, 1)), 0, n - 1) }
	lo, hi := 0, n - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if offs[mid] <= y { lo = mid } else { hi = mid - 1 }
	}
	return lo
}

dt_row_top :: proc(r: Dt_Rows, i: int) -> f32 { return r.offs != nil ? r.offs[i] : f32(i) * r.row_h }
dt_row_height :: proc(r: Dt_Rows, i: int) -> f32 { return r.offs != nil ? r.offs[i + 1] - r.offs[i] : r.row_h }

@(deferred_out = dt_list_end)
dt_list :: proc(id: string, l: ^Dt_List, n: int, row_h: f32, offs: []f32 = nil, w := ui.Size{.Percent, 1, 0}, h := ui.Size{.Percent, 1, 0}, follow := false) -> (rows: Dt_Rows, ok: bool) {
	ui.next({width = w, height = h, axis = .Y})
	b := ui.build_box({.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y, .Focusable, .Clickable, .Text_Input}, id)
	b.cursor = .Arrow
	sig := ui.signal(b)
	_ = sig.scrolled
	l.key = b.key
	l.focused = sig.focused
	total := offs != nil ? offs[n] : f32(n) * row_h
	view_h := b.size.y > 0 ? b.size.y : f32(600)
	limit := max(total - view_h, 0)
	// the view was at the end of the rows of last frame and rows came: it stays at the end (it leaves it when the user
	// scrolls up, and sticks again when they come back)
	prev_limit := max(l.total - view_h, 0)
	if follow && b.view_target.y >= prev_limit - 2 { b.view_target.y, b.view_off.y = limit, limit }
	if l.reveal >= 0 && l.reveal < n {
		top := offs != nil ? offs[l.reveal] : f32(l.reveal) * row_h
		bot := offs != nil ? offs[l.reveal + 1] : top + row_h
		if top < b.view_target.y { b.view_target.y = top }
		if bot > b.view_target.y + view_h { b.view_target.y = bot - view_h }
		l.reveal = -1
	}
	b.view_target.y = clamp(b.view_target.y, 0, limit)
	l.n_last, l.total, l.view, l.at_end = n, total, view_h, b.view_target.y >= limit - 2
	over := row_h * 2
	lo := min(b.view_off.y, b.view_target.y) - over
	hi := max(b.view_off.y, b.view_target.y) + view_h + over
	first := n > 0 ? dt_row_at(offs, row_h, n, max(lo, 0)) : 0
	last := first
	for last < n && (offs != nil ? offs[last] : f32(last) * row_h) < hi { last += 1 }
	ui.push_parent(b)
	top := first > 0 ? (offs != nil ? offs[first] : f32(first) * row_h) : 0
	ui.spacer(ui.px(top), exact = true)
	return {first, last, l, n, row_h, offs}, true
}

@(private = "file")
dt_list_end :: proc(rows: Dt_Rows, ok: bool) {
	n := rows.n
	end := rows.offs != nil ? rows.offs[rows.last] : f32(rows.last) * rows.row_h
	total := rows.offs != nil ? rows.offs[n] : f32(n) * rows.row_h
	ui.spacer(ui.px(max(total - end, 0)), exact = true)
	ui.pop_parent()
}

// The keys of a focused list over `n` rows: moves the active row; true when it changed.
dt_list_keys :: proc(l: ^Dt_List, n: int, page: int) -> bool {
	if !l.focused || n == 0 { return false }
	old := l.sel
	if ui.key_press(.Down) { l.sel = min(l.sel + 1, n - 1) }
	if ui.key_press(.Up) { l.sel = max(l.sel - 1, 0) }
	if ui.key_press(.Page_Down) { l.sel = min(l.sel + page, n - 1) }
	if ui.key_press(.Page_Up) { l.sel = max(l.sel - page, 0) }
	if ui.key_press(.Home, {.Ctrl}) || ui.key_press(.Home) { l.sel = 0 }
	if ui.key_press(.End, {.Ctrl}) || ui.key_press(.End) { l.sel = n - 1 }
	if l.sel < 0 { l.sel = 0 }
	if l.sel != old { l.reveal = l.sel; return true }
	return false
}

////////////////////////////////
// Rows

// A row of `h` pixels across the list, one box that paints itself.
dt_row :: proc(id: string, h: f32, draw_fn: ui.Custom_Draw, user: rawptr) -> ui.Signal {
	ui.next({width = ui.fill(), height = ui.px(h), cursor = .Arrow})
	b := ui.build_box({.Clickable}, id)
	sig := ui.signal(b)
	b.custom, b.custom_user = draw_fn, user
	return sig
}

// The background of a row: the zebra stripe, its selection, hover; true when it is the selected one.
dt_row_back :: proc(dc: ^draw.Context, r: draw.Rect, odd, selected, hot, focused: bool, tint := draw.Color{}) {
	if odd { draw.rect(dc, r, dtc.zebra) }
	if tint.a > 0 { draw.rect(dc, r, tint) }
	if selected {
		draw.rect(dc, r, focused ? dtc.sel : dtc.sel_weak)
		draw.rect(dc, {r.min, {r.min.x + dtm.line * 2, r.max.y}}, dtc.accent)
	} else if hot {
		draw.rect(dc, r, dtc.hover)
	}
}

// An empty state: an illustration (an icon in a ring), a title and a phrase that says what to do. Fills the room.
Dt_Empty :: struct { icon: Dt_Icon, title, hint: string }

dt_empty :: proc(id: string, icon: Dt_Icon, title, hint: string) {
	ui.next({width = ui.fill(), height = ui.fill()})
	b := ui.build_box({}, id)
	d := ui.frame_new(Dt_Empty)
	d^ = {icon, dt_frame_str(title), dt_frame_str(hint)}
	b.custom, b.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Dt_Empty)(user)
		r := b.rect
		cx := (r.min.x + r.max.x) * 0.5
		h := r.max.y - r.min.y
		big := dt_px(44)
		block := big + dt_px(10) + dtm.fs * 1.5 + dtm.fs * 1.4
		top := r.min.y + max((h - block) * 0.42, dt_px(6))
		if h < block { return }
		ring := draw.Rect{{cx - big * 0.5, top}, {cx + big * 0.5, top + big}}
		draw.rect(dc, ring, with_alpha(dtc.weak, 0.07), big * 0.5)
		draw.rect(dc, ring, with_alpha(dtc.weak, 0.25), big * 0.5, dtm.line)
		dt_icon(dc, d.icon, draw.rect_center(ring), big * 0.5, dtc.weak, dtm.sc)
		y := top + big + dt_px(10) + dtm.fs * 0.7
		tw := dt_w(dtm.ui_font, dtm.fs * 1.08, d.title)
		dt_text(dc, dtm.ui_font, dtm.fs * 1.08, cx - tw * 0.5, y, dtc.text, d.title)
		y += dtm.fs * 1.4
		t, w := dt_fit(dtm.ui_font, dtm.fs, d.hint, r.max.x - r.min.x - dt_px(24))
		dt_text(dc, dtm.ui_font, dtm.fs, cx - w * 0.5, y, dtc.weak, t)
	}, d
}

////////////////////////////////
// Dividers the user drags

// A one-pixel rule with a wider grab area, vertical (between side by side panes). Returns the drag delta in pixels while
// it is dragged (and whether it was pressed this frame).
dt_vsplit :: proc(id: string) -> (dx: f32, started, dragging: bool) {
	ui.next({width = ui.px(dt_px(5)), height = ui.fill(), cursor = .Resize_H})
	b := ui.build_box({.Clickable}, id)
	sig := ui.signal(b)
	d := ui.frame_new(Dt_Btn_Draw)
	d.hot, d.down = sig.hovering, sig.dragging
	b.custom, b.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Dt_Btn_Draw)(user)
		x := math.round((b.rect.min.x + b.rect.max.x) * 0.5)
		col := d.hot || d.down ? dtc.accent : dtc.border
		w := d.hot || d.down ? dtm.line * 2 : dtm.line
		draw.rect(dc, {{x - w * 0.5, b.rect.min.y}, {x + w * 0.5, b.rect.max.y}}, col)
	}, d
	return sig.drag_delta.x, sig.pressed, sig.dragging
}

// Same, horizontal (between stacked panes).
dt_hsplit :: proc(id: string) -> (dy: f32, started, dragging: bool) {
	ui.next({width = ui.fill(), height = ui.px(dt_px(5)), cursor = .Resize_V})
	b := ui.build_box({.Clickable}, id)
	sig := ui.signal(b)
	d := ui.frame_new(Dt_Btn_Draw)
	d.hot, d.down = sig.hovering, sig.dragging
	b.custom, b.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Dt_Btn_Draw)(user)
		y := math.round((b.rect.min.y + b.rect.max.y) * 0.5)
		col := d.hot || d.down ? dtc.accent : dtc.border
		w := d.hot || d.down ? dtm.line * 2 : dtm.line
		draw.rect(dc, {{b.rect.min.x, y - w * 0.5}, {b.rect.max.x, y + w * 0.5}}, col)
	}, d
	return sig.drag_delta.y, sig.pressed, sig.dragging
}

////////////////////////////////
// Text for the clipboard and for messages

// "1.5 kB" the way the panel writes sizes (powers of 1000, as the network panels of other browsers do).
dt_size_text :: proc(n: i64) -> string {
	switch {
	case n < 1000: return fmt.tprintf("%d B", n)
	case n < 1_000_000: return fmt.tprintf("%.1f kB", f64(n) / 1000)
	case n < 1_000_000_000: return fmt.tprintf("%.2f MB", f64(n) / 1_000_000)
	}
	return fmt.tprintf("%.2f GB", f64(n) / 1_000_000_000)
}

dt_ms_text :: proc(ms: f32) -> string {
	switch {
	case ms < 0: return "\u2026"
	case ms < 1: return fmt.tprintf("%.2f ms", ms)
	case ms < 10: return fmt.tprintf("%.1f ms", ms)
	case ms < 1000: return fmt.tprintf("%d ms", int(ms + 0.5))
	case ms < 60000: return fmt.tprintf("%.2f s", ms / 1000)
	}
	return fmt.tprintf("%d:%02d min", int(ms / 60000), int(ms / 1000) % 60)
}

_ :: platform
