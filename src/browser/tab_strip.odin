package browser

// The row of tabs (the window's title bar when it is integrated: window_chrome.odin), as in Chrome and Edge:
//   * each tab: the site's icon (favicon.odin) or a loading indicator, its title cut with an ellipsis, a close button
//     (on every tab when they are wide enough, else on the current one and the one under the pointer);
//   * tabs share the strip's width between browser.tabs.min_width_em and max_width_em; past the minimum the strip
//     scrolls (mouse wheel over it) and follows the current tab;
//   * a press selects (Chrome selects on the press, so a drag starts from the current tab); a middle click closes; a
//     drag along the strip reorders, the other tabs sliding out of the way; right click: the tab's menu;
//   * "+" right after the last tab.
// The loading indicator turns only while the tab loads (spinner_wake: one timed wake per turn); nothing animates at
// rest, so an idle browser draws no frame.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"

Tab_Strip :: struct {
	offset:       f32,    // scroll of the tabs when they do not fit (physical pixels)
	follow_id:    u64,    // the current tab the offset was last brought to (a new current tab is scrolled into view)
	follow_n:     int,
	drag_id:      u64,    // the tab under a drag (0: none)
	drag_active:  bool,   // ... and it moved past the threshold
	drag_grab:    f32,    // pointer x minus the dragged tab's left edge
	area_key:     ui.Key, // the box holding the tabs (their keys derive from it)
}

// The tab that has the keyboard, -1 when none (by key: works before the strip is built).
focused_tab_index :: proc(app: ^App) -> int {
	k := ui.focus_key()
	if k == 0 || strip.area_key == 0 { return -1 }
	for t, i in app.tabs {
		if ui.key_from_string(strip.area_key, fmt.tprintf("###tab_%d", t.id)) == k { return i }
	}
	return -1
}

strip: Tab_Strip

////////////////////////////////
// Geometry (pure: tab_strip_test.odin)

// Width of each tab: an equal share of `avail`, between `min_w` and `max_w`.
tab_width :: proc(avail: f32, n: int, min_w, max_w: f32) -> f32 {
	if n <= 0 { return max_w }
	return clamp(avail / f32(n), min(min_w, max_w), max_w)
}

// Offset that keeps the scroll in range and, when `follow` (the current tab changed), shows tab `current` whole.
strip_offset :: proc(offset: f32, n: int, w, avail: f32, current: int, follow: bool) -> f32 {
	limit := max(f32(n) * w - avail, 0)
	o := offset
	if follow && current >= 0 && current < n {
		left := f32(current) * w
		if left < o { o = left }
		if left + w > o + avail { o = left + w - avail }
	}
	return clamp(o, 0, limit)
}

// Slot a dragged tab whose left edge is at `left` (strip coordinates, scroll included) belongs in: the one its
// middle is over.
drag_slot :: proc(left, w: f32, n: int) -> int {
	if n <= 0 || w <= 0 { return 0 }
	return clamp(int(math.floor((left + w * 0.5) / w)), 0, n - 1)
}

// Moves the element at `from` to `to`, shifting those between; returns where the element at `current` went.
list_move :: proc(list: []$T, from, to, current: int) -> int {
	if from == to || from < 0 || to < 0 || from >= len(list) || to >= len(list) { return current }
	v := list[from]
	if from < to { copy(list[from:to], list[from + 1:to + 1]) } else { copy(list[to + 1:from + 1], list[to:from]) }
	list[to] = v
	switch {
	case current == from: return to
	case from < current && current <= to: return current - 1
	case to <= current && current < from: return current + 1
	}
	return current
}

////////////////////////////////
// Loading state

// The tab is loading: its document, its modules, or what delays its load event (stylesheets, images, fonts, scripts);
// not after Escape stopped it.
tab_busy :: proc(t: ^Tab) -> bool {
	if t == nil || t.kind != .Web { return false }
	if t.load != nil && t.load.stopped { return false }
	if tab_loading(t) { return true }   // first_paint.odin: no paint yet
	if t.load != nil {
		if t.load.task != base.NIL_HANDLE { return true }
		for s in t.load.slots { if s.state == .Pending { return true } }
	}
	if p := t.page; p != nil && t.load != nil && p.scripts != nil && p.scripts.started && !p.scripts.loaded { return true }
	return false
}

// The loading indicator still turns (browser.tabs.spinner_max_s after the navigation started, it stands still).
spinner_turning :: proc(t: ^Tab) -> bool {
	if favs.cfg.spinner_max_ms <= 0 { return true }
	return f64(time.duration_milliseconds(time.tick_since(t.hold.started))) < favs.cfg.spinner_max_ms
}

////////////////////////////////
// Building

// The row of tabs. Returns true when a tab closed (the build stops: the tab list changed under it).
tab_strip :: proc(app: ^App, integrated: bool) -> (closed: bool) {
	em := ui.font_size()
	dpi := ui_scale_of(app)
	h := ui.dense(em * 2.6)
	if integrated { h = max(h, math.round(32 * dpi)) }   // never lower than the system's title bar
	if ui.active_key() == 0 { strip.drag_id, strip.drag_active = 0, false }   // the button went up (wherever)
	favicon_frame()

	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
	bar := ui.build_box(integrated ? {.Window_Caption} : {}, "###tabstrip")
	if ui.parent(bar) {
		lead: f32
		if integrated {
			ui.spacer(ui.px(math.round(10 * dpi)))
			app_icon(app, math.round(16 * dpi))
			ui.spacer(ui.px(math.round(6 * dpi)))
			lead = math.round(32 * dpi)
		} else {
			lead = math.round(em * 0.4)
			ui.spacer(ui.px(lead))
		}
		// the tabs take what is left once the new-tab button, the window buttons and a free strip to drag the window
		// are counted
		new_w := math.round(em * 2.4)
		buttons := integrated ? 3 * math.round(ui.CAPTION_BUTTON_WIDTH * dpi) : 0
		fixed := lead + new_w + em * 0.3 + buttons + (integrated ? wchrome.cfg.min_drag_em * em : em * 0.4)
		avail := max(f32(app.win.size.x) - fixed, em * 4)
		n := len(app.tabs)
		w := math.round(tab_width(avail, n, favs.cfg.min_w_em * em, favs.cfg.max_w_em * em))
		area_w := min(f32(n) * w, avail)
		cur_id := app.tabs[app.current].id
		follow := cur_id != strip.follow_id || n != strip.follow_n
		strip.follow_id, strip.follow_n = cur_id, n
		strip.offset = strip_offset(strip.offset, n, w, area_w, app.current, follow)

		ui.next({width = ui.px(area_w), height = ui.pct(1), axis = .X})
		area := ui.build_box({.Clip, .Scroll_Self}, "###tabs_area")
		strip.area_key = area.key
		if s := ui.signal(area); s.scrolled != {} {
			// the wheel scrolls the strip by about a tab per notch
			strip.offset = strip_offset(strip.offset + (s.scrolled.y + s.scrolled.x) * w, n, w, area_w, app.current, false)
			app.frames_requested = max(app.frames_requested, 2)
		}
		move_from, move_to := -1, -1
		if ui.parent(area) {
			// the dragged tab is built last: it draws over the others
			dragged := -1
			for t, i in app.tabs {
				if strip.drag_active && t.id == strip.drag_id { dragged = i; continue }
				r := tab_box(app, i, w, area, &move_from, &move_to)
				if r == .Closed { return true }
			}
			if dragged >= 0 {
				if tab_box(app, dragged, w, area, &move_from, &move_to) == .Closed { return true }
			}
		}
		if move_from >= 0 {
			app.current = list_move(app.tabs[:], move_from, move_to, app.current)
			strip.follow_id = app.tabs[app.current].id   // no jump of the scroll while dragging
			app.frames_requested = max(app.frames_requested, 2)
		}
		any_turning := false
		for t in app.tabs {
			tab_refresh(app, t, tab_icon_px(app))
			any_turning ||= tab_busy(t) && spinner_turning(t)
		}
		if any_turning { spinner_wake(app) }

		ui.spacer(ui.px(em * 0.3))
		ui.next({width = ui.px(new_w), height = ui.px(ui.dense(em * 2.2)), radius = em * CHROME_BUTTON_RADIUS})
		add := ui.icon_button("###newtab", GLYPH_ADD)
		tip(add, "New tab (Ctrl+T)")
		if add.clicked { tab_open_new(app) }
		ui.spacer(ui.fill())   // drags the window
		if integrated { _, _ = ui.window_buttons() }
	}
	return false
}

@(private = "file")
Tab_Result :: enum u8 { None, Closed }

@(private = "file")
Tab_Look :: struct {
	selected:  f32,          // 0..1, animated
	accent:    draw.Color,
	divider:   draw.Color,
	hover:     draw.Color,
	hot:       bool,
	divide:    bool,         // a divider on its right (between two tabs that are neither selected nor hovered)
}

// One tab. Positions are the slot's, animated when tabs move; a dragged tab follows the pointer.
@(private = "file")
tab_box :: proc(app: ^App, i: int, w: f32, area: ^ui.Box, move_from, move_to: ^int) -> Tab_Result {
	t := app.tabs[i]
	n := len(app.tabs)
	em := ui.font_size()
	dpi := ui_scale_of(app)
	on := i == app.current
	id := fmt.tprintf("###tab_%d", t.id)
	slot := f32(i) * w - strip.offset
	x: f32
	dragging := strip.drag_active && strip.drag_id == t.id
	if dragging {
		x = clamp(ui.mouse_pos().x - area.rect.min.x - strip.drag_grab, -strip.offset, f32(n - 1) * w - strip.offset)
		_ = ui.anim(ui.key_from_string(area.key, fmt.tprintf("x%d", t.id)), x, 30, x)   // the release slides from here
	} else {
		x = math.round(ui.anim(ui.key_from_string(area.key, fmt.tprintf("x%d", t.id)), slot, 30, slot))
	}
	prev := ui.prev_box(id)
	inside := prev != nil && draw.rect_contains(prev.rect, ui.mouse_pos()) && draw.rect_contains(area.rect, ui.mouse_pos())

	if !on { ui.push_tags("weak") }
	defer if !on { ui.pop_tags() }
	ui.next({fixed_x = x, fixed_y = 0, width = ui.px(w), height = ui.pct(1), axis = .X, cross = .Center, radius = em * 0.45})
	b := ui.build_box({.Clickable, .Focusable, .Draw_Hot_Effects, .Clip}, id)
	b.cursor = .Arrow
	look := ui.frame_new(Tab_Look)
	look.selected = ui.anim(ui.key_from_string(b.key, "sel"), on ? 1 : 0, 34)
	look.accent = ui.color("accent")
	look.divider = ui.color("border")
	look.hot = inside
	next_on := i + 1 == app.current
	look.divide = !on && !next_on && !inside && i + 1 < n && !dragging
	b.custom, b.custom_user = tab_look_draw, look
	closed := false
	if ui.parent(b) {
		pad := math.round(em * 0.65)
		ui.spacer(ui.px(pad))
		isz := f32(tab_icon_px(app))
		ui.next({width = ui.px(isz), height = ui.pct(1)})
		ui.custom("###icon", tab_icon_draw, tab_icon_of(app, t, isz))
		ui.spacer(ui.px(math.round(em * 0.5)))
		title := t.title
		if strings.contains(title, "###") { title, _ = strings.replace_all(title, "###", "# # #", context.temp_allocator) }
		ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
		ui.build_box({.Draw_Text}, fmt.aprintf("%s###title", title, allocator = ui.frame_allocator()))
		show_close := on || inside || w >= favs.cfg.close_min_em * em
		if show_close {
			cs := math.round(em * 1.45)
			if ui.tab_stops(false) {
				// a thin cross (the icon font's is a heavy one), round hover like Chrome's
				ui.next({width = ui.px(cs), height = ui.px(cs), radius = cs * 0.5})
				cb: ^ui.Box
				if ui.tags("icon_button") {
					cb = ui.build_box({.Clickable, .Draw_Background, .Draw_Hot_Effects}, "###close")
					cross := ui.frame_new(draw.Color)
					cross^ = ui.color("text")
					cb.custom, cb.custom_user = close_cross_draw, cross
				}
				c := ui.signal(cb)
				tip(c, "Close tab (Ctrl+W)")
				if c.clicked { closed = true }
			}
		}
		ui.spacer(ui.px(math.round(em * 0.35)))
	}
	if closed { tab_close(app, i); return .Closed }
	sig := ui.signal(b)
	if (sig.pressed || sig.clicked) && !on { tab_select(app, i) }   // the press selects; Enter / Space too
	if sig.right_clicked { tab_context_menu(app, i, ui.mouse_pos()) }
	if sig.middle_clicked && favs.cfg.middle_close { tab_close(app, i); return .Closed }
	tip(sig, t.title)
	// drag to reorder
	if sig.dragging && favs.cfg.drag_reorder && n > 1 {
		if !strip.drag_active && abs(sig.drag_delta.x) > favs.cfg.drag_threshold * dpi {
			strip.drag_active, strip.drag_id = true, t.id
			press_x := ui.mouse_pos().x - sig.drag_delta.x
			strip.drag_grab = press_x - area.rect.min.x - slot   // where the pointer holds the tab
		}
		if strip.drag_active && strip.drag_id == t.id {
			to := drag_slot(x + strip.offset, w, n)
			if to != i { move_from^, move_to^ = i, to }
			app.frames_requested = max(app.frames_requested, 2)
		}
	}
	return .None
}

@(private = "file")
close_cross_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	col := (^draw.Color)(user)^
	c := draw.rect_center(b.rect)
	arm := (b.rect.max.x - b.rect.min.x) * 0.22
	th := max(math.round(1.25 * ui.scale()), 1)
	for angle in ([2]f32{math.PI / 4, -math.PI / 4}) {
		draw.push_transform(dc, draw.affine_around(draw.affine_rotate(angle), c))
		draw.rect(dc, {{c.x - arm, c.y - th * 0.5}, {c.x + arm, c.y + th * 0.5}}, col, th * 0.5)
		draw.pop_transform(dc)
	}
}

@(private = "file")
tab_look_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	l := (^Tab_Look)(user)
	r := b.rect
	if l.divide {
		lw := max(math.round(ui.scale()), 1)
		inset := (r.max.y - r.min.y) * 0.3
		draw.rect(dc, {{r.max.x - lw, r.min.y + inset}, {r.max.x, r.max.y - inset}}, l.divider)
	}
	if l.selected < 0.01 { return }
	// the current tab: an accent underline growing from the middle
	w := (r.max.x - r.min.x - b.radius * 2) * l.selected
	cx := (r.min.x + r.max.x) * 0.5
	th := max(math.round(2.5 * ui.scale()), 2)
	draw.rect(dc, {{cx - w * 0.5, r.max.y - th}, {cx + w * 0.5, r.max.y}}, l.accent, th * 0.5)
}

////////////////////////////////
// The icon of a tab

@(private = "file")
Icon_Kind :: enum u8 { Globe, App, File, Gear, Favicon, Spinner, Waiting }

@(private = "file")
Tab_Icon_Draw :: struct {
	kind:   Icon_Kind,
	tex:    render.Texture,
	color:  draw.Color,
	phase:  f32,           // spinner: turns (0..1)
	size:   f32,
}

tab_icon_of :: proc(app: ^App, t: ^Tab, size: f32) -> ^Tab_Icon_Draw {
	d := ui.frame_new(Tab_Icon_Draw)
	d.size = size
	d.color = ui.color("text")
	if tab_busy(t) {
		// the response has not come: a slower, muted turn (Chrome's "waiting"); then the accent one
		waiting := t.page == nil
		d.kind = waiting ? .Waiting : .Spinner
		if !waiting { d.color = ui.color("accent") }
		ms := time.duration_milliseconds(time.tick_since(t.hold.started))
		period: f64 = waiting ? 1600 : 900
		d.phase = spinner_turning(t) ? f32(math.mod(ms, period) / period) : 0
		return d
	}
	switch {
	case t.kind == .Config: d.kind = .Gear
	case t.load != nil && t.load.failed != .None: d.kind = .Globe   // an error page is not the browser's own page
	case t.page != nil && t.page.env.location.scheme == "about": d.kind = wchrome.icon_px > 0 ? .App : .Globe; d.tex = wchrome.icon
	case t.page != nil && t.page.env.location.scheme == "file": d.kind = .File
	case t.icon.url != "":
		if tex, ok := favicon_texture(t.icon.url); ok { d.kind, d.tex = .Favicon, tex }
	}
	return d
}

tab_icon_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Tab_Icon_Draw)(user)
	app := the_app
	c := draw.rect_center(b.rect)
	s := d.size
	r := draw.Rect{{math.round(c.x - s * 0.5), math.round(c.y - s * 0.5)}, {}}
	r.max = r.min + {s, s}
	switch d.kind {
	case .Favicon, .App:
		draw.image(dc, d.tex, r)
	case .File, .Gear:
		// the glyph's ink centred in the icon's square (the pen is on the baseline: chrome.odin chip_icon_draw)
		glyph := d.kind == .File ? GLYPH_FILE : GLYPH_GEAR
		size := s * 1.1
		g := font.glyph(&app.fonts, app.icons, size, rune(glyph[0]))
		w := g.size.x > 0 ? g.size.x : g.advance
		pen := draw.Vec2{math.round(c.x - w * 0.5 - g.offset.x), math.round(c.y - (g.offset.y + g.size.y * 0.5))}
		draw.text(dc, app.icons, size, pen, d.color, glyph)
	case .Globe:
		// a neutral globe: a ring, the equator and a meridian
		lw := max(s * 0.09, 1)
		col := d.color
		col.a *= 0.75
		draw.rect(dc, draw.rect_pad(r, -s * 0.06), col, s * 0.5, lw)
		draw.rect(dc, {{r.min.x + s * 0.1, c.y - lw * 0.5}, {r.max.x - s * 0.1, c.y + lw * 0.5}}, col)
		draw.rect(dc, {{c.x - s * 0.2, r.min.y + s * 0.06}, {c.x + s * 0.2, r.max.y - s * 0.06}}, col, s * 0.2, lw)
	case .Spinner, .Waiting:
		// an arc of three quarters turning; drawn as overlapping dots (no arc primitive)
		th := max(s * 0.13, 1.5)
		rad := s * 0.5 - th * 0.5 - s * 0.04
		start := f64(d.phase) * math.TAU
		if d.kind == .Waiting { start = -start }   // the waiting turn goes the other way, as in Chrome
		steps := max(int(rad * 4.7 * 0.75 / max(th * 0.35, 0.5)), 12)
		for k in 0 ..= steps {
			a := start + f64(k) / f64(steps) * math.TAU * 0.75
			p := c + {f32(math.cos(a)) * rad, f32(math.sin(a)) * rad}
			draw.rect(dc, {p - th * 0.5, p + th * 0.5}, d.color, th * 0.5)
		}
	}
}
