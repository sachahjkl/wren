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
import "wb:i18n"

// A window's row (or sidebar) of tabs from frame to frame (Window_Own.strip).
Tab_Strip :: struct {
	offset:       f32,    // scroll of the tabs when they do not fit (physical pixels)
	follow_id:    u64,    // the current tab the offset was last brought to (a new current tab is scrolled into view)
	follow_n:     int,
	drag:         ui.Reorder,   // a tab dragged along the strip or the sidebar (toolkit: ui/reorder.odin)
	area_key:     ui.Key,       // the box holding the tabs (their keys derive from it)
}

// The tab that has the keyboard, -1 when none (by key: works before the strip is built).
focused_tab_index :: proc(app: ^App) -> int {
	k := ui.focus_key()
	own := window_own(app)
	if k == 0 || own.strip.area_key == 0 { return -1 }
	for t, i in active_window(app).tabs {
		if ui.key_from_string(own.strip.area_key, fmt.tprintf("###tab_%d", t.id)) == k { return i }
	}
	return -1
}

////////////////////////////////
// Geometry: the toolkit's list of items reordered by dragging (ui/reorder.odin), under the names the shell and its
// tests use (tab_strip_test.odin)

tab_width :: ui.reorder_item_size   // each tab's width: an equal share between the minimum and the maximum
strip_offset :: ui.reorder_offset   // the scroll, in range, following the current tab when it changes
drag_slot :: ui.reorder_slot        // the slot a dragged tab's middle is over
list_move :: ui.list_move

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
	wnd := active_window(app)
	own := &wnd.own
	em := ui.font_size()
	dpi := ui_scale_of(app)
	h := ui.dense(em * 2.6)
	if integrated { h = max(h, math.round(32 * dpi)) }   // never lower than the system's title bar
	ui.reorder_frame(&own.strip.drag)   // the button went up (wherever): no drag
	favicon_frame()

	classic := classic_on()
	cg: Classic_Geom
	cc: ^Classic_Colors
	if classic {
		cg = classic_geom(em, dpi, h, chrome_cfg.slope_deg)
		cc = classic_colors_frame(app)
	}

	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
	bar := ui.build_box(integrated ? {.Window_Caption} : {}, "###tabstrip")
	if classic { bar.custom, bar.custom_user = strip_bar_draw, cc }
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
		// classic: each tab is `overlap` wider than its pitch (it covers the next one's left foot) and the strip keeps the
		// room of the feet's flare at both ends
		extra := classic ? cg.d.ext * 2 : 0
		// classic: the new-tab button is placed as a tab is, its left foot under the last tab's right one (`plus_pull`), not after a gap
		plus_w := new_w + extra * 0.5
		plus_pull: f32
		if classic { _, _, _, plus_pull = classic_plus_metrics(&cg, em, dpi, plus_w) }
		plus_room := classic ? plus_w - plus_pull : new_w + em * 0.3
		fixed := lead + plus_room + buttons + (integrated ? wchrome.cfg.min_drag_em * em : em * 0.4) + extra
		avail := max(f32(active_window(app).win.size.x) - fixed, em * 4)
		n := len(wnd.tabs)
		w := math.round(tab_width(avail - cg.overlap, n, favs.cfg.min_w_em * em, favs.cfg.max_w_em * em))
		vis := min(f32(n) * w + cg.overlap, avail)   // what the tabs show of the strip, flares apart
		view_w := vis - cg.overlap                   // (what strip_offset calls the width: the pitches' share)
		area_w := vis + extra
		cur_id := wnd.tabs[wnd.current].id
		follow := cur_id != own.strip.follow_id || n != own.strip.follow_n
		own.strip.follow_id, own.strip.follow_n = cur_id, n
		own.strip.offset = strip_offset(own.strip.offset, n, w, view_w, wnd.current, follow)

		// (classic: the area also holds the new-tab button, which reaches back under the last tab)
		ui.next({width = ui.px(classic ? area_w + plus_w - plus_pull : area_w), height = ui.pct(1), axis = .X})
		area := ui.build_box({.Clip, .Scroll_Self}, "###tabs_area")
		tab_list_a11y(area, false)
		add: ui.Signal
		own.strip.area_key = area.key
		if app.active != nil { app.active.zone = {rect = area.rect, offset = own.strip.offset, pitch = w, n = n, valid = true} }
		if s := ui.signal(area); s.scrolled != {} {
			// the wheel scrolls the strip by about a tab per notch
			own.strip.offset = strip_offset(own.strip.offset + (s.scrolled.y + s.scrolled.x) * w, n, w, view_w, wnd.current, false)
			request_frames(app, 2)
		}
		move_from, move_to := -1, -1
		if ui.parent(area) {
			if classic {
				// the button first: the tabs draw over its left foot as each draws over the one before it, and take the clicks;
				// the tabs themselves are clipped to their own part of the area (when they scroll they must not run under the button)
				add = classic_new_tab_button(app, &cg, cc, h, plus_w, area_w - plus_pull)
				ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(area_w), height = ui.pct(1), axis = .X})
				ui.push_parent(ui.build_box({.Clip}, "###tabs_clip"))
			}
			defer if classic { ui.pop_parent() }
			// the dragged tab is built last: it draws over the others (classic: the current one just before it, as it
			// is the one in front of the others, and the clicks go to what is drawn on top)
			dragged := -1
			for t, i in wnd.tabs {
				if ui.reorder_dragging(&own.strip.drag, t.id) { dragged = i; break }
			}
			if classic {
				order := make([dynamic]int, 0, n, context.temp_allocator)
				tab_stack_order(n, wnd.current, dragged, &order)
				for i in order {
					if tab_box(app, i, w, area, &move_from, &move_to, &cg, cc) == .Closed { return true }
				}
			} else {
				for _, i in wnd.tabs {
					if i == dragged { continue }
					r := tab_box(app, i, w, area, &move_from, &move_to, &cg, cc)
					if r == .Closed { return true }
				}
				if dragged >= 0 {
					if tab_box(app, dragged, w, area, &move_from, &move_to, &cg, cc) == .Closed { return true }
				}
			}
			if app.active != nil && app.active.drop_hint > 0 { drop_hint_mark(area, false, f32(app.active.drop_hint - 1) * w - own.strip.offset) }   // a tab carried over this bar
		}
		if move_from >= 0 {
			wnd.current = list_move(wnd.tabs[:], move_from, move_to, wnd.current)
			own.strip.follow_id = wnd.tabs[wnd.current].id   // no jump of the scroll while dragging
			request_frames(app, 2)
			recovery_touch(app)
		}
		any_turning := false
		for t in wnd.tabs {
			tab_refresh(app, t, tab_icon_px(app))
			any_turning ||= tab_busy(t) && spinner_turning(t)
		}
		if any_turning { spinner_wake(app) }

		if !classic {
			ui.spacer(ui.px(em * 0.3))
			ui.next({width = ui.px(new_w), height = ui.px(ui.dense(em * 2.2)), radius = em * CHROME_BUTTON_RADIUS})
			add = ui.icon_button("###newtab", GLYPH_ADD)
		}
		tip(add, i18n.tr("New tab (Ctrl+T)"))
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
tab_box :: proc(app: ^App, i: int, w: f32, area: ^ui.Box, move_from, move_to: ^int, cg: ^Classic_Geom, cc: ^Classic_Colors) -> Tab_Result {
	wnd := active_window(app)
	own := &wnd.own
	classic := cc != nil
	t := wnd.tabs[i]
	n := len(wnd.tabs)
	em := ui.font_size()
	dpi := ui_scale_of(app)
	on := i == wnd.current
	id := fmt.tprintf("###tab_%d", t.id)
	slot := f32(i) * w - own.strip.offset
	// (the release slides from where the pointer left it)
	x, dragging := ui.reorder_item_pos(&own.strip.drag, ui.key_from_string(area.key, fmt.tprintf("x%d", t.id)), t.id, slot,
		ui.mouse_pos().x - area.rect.min.x, -own.strip.offset, f32(n - 1) * w - own.strip.offset)
	if dragging { drag_probe_note(app, ui.mouse_pos().x, x + area.rect.min.x + own.strip.drag.grab) }
	prev := ui.prev_box(id)
	inside := prev != nil && ui.box_contains(prev, ui.mouse_pos()) && draw.rect_contains(area.rect, ui.mouse_pos())

	if !on { ui.push_tags("weak") }
	defer if !on { ui.pop_tags() }
	b: ^ui.Box
	paint: ^Classic_Tab
	if classic {
		// the box holds the whole trapezoid and the flare of its feet; its hit shape is the trapezoid (slant)
		m := cg.m
		m.w = w + cg.overlap
		d := tab_dims(m)
		ui.next({fixed_x = x, fixed_y = cg.margin, width = ui.px(d.box_w), height = ui.px(cg.h), axis = .X, cross = .Center})
		ui.push_tags("tab")
		b = ui.build_box({.Clickable, .Focusable, .Hot_Within}, id)
		ui.pop_tags()
		b.slant = tab_slant(d)
		paint = ui.frame_new(Classic_Tab)
		paint.m, paint.c, paint.box, paint.dragging = m, cc, b, dragging
		paint.selected = ui.anim(ui.key_from_string(b.key, "sel"), on ? 1 : 0, 34)
		paint.hover = ui.anim(ui.key_from_string(b.key, "hov"), inside && !on ? 1 : 0, 40)
		idle_top, idle_bot := ui.srgb_step(cc.idle_top, cc.hot_top, paint.hover), ui.srgb_step(cc.idle_bot, cc.hot_bot, paint.hover)
		paint.top = ui.srgb_step(idle_top, cc.lit_top, paint.selected)
		paint.bot = ui.srgb_step(idle_bot, cc.lit_mid, paint.selected)
		b.custom, b.custom_user = classic_tab_draw, paint
	} else {
		ui.next({fixed_x = x, fixed_y = 0, width = ui.px(w), height = ui.pct(1), axis = .X, cross = .Center, radius = em * 0.45})
		// lit under the pointer, also while it is on the tab's close button
		ui.push_tags("tab")
		b = ui.build_box({.Clickable, .Focusable, .Draw_Hot_Effects, .Hot_Within, .Clip}, id)
		ui.pop_tags()
		look := ui.frame_new(Tab_Look)
		look.selected = ui.anim(ui.key_from_string(b.key, "sel"), on ? 1 : 0, 34)
		look.accent = ui.color("accent")
		look.divider = ui.color("border")
		look.hot = inside
		next_on := i + 1 == wnd.current
		look.divide = !on && !next_on && !inside && i + 1 < n && !dragging
		b.custom, b.custom_user = tab_look_draw, look
	}
	b.cursor = .Arrow
	tab_a11y(b, t, i, n, on)
	closed := false
	if ui.parent(b) {
		// classic: the content stays clear of the sloped sides (half the lean is at the middle of the tab's height)
		side: f32
		if classic {
			// (the current tab, drawn on top, covers the left foot and the slope of the tab on its right by `overlap`: the icon starts clear
			// of it, as the end of the title stops before the next tab's slope, below)
			d := tab_dims(paint.m)
			side = d.ext + max(cg.overlap - d.run * 0.5, d.run * 0.5)
		}
		pad := classic ? side + math.round(em * 0.35) : math.round(em * 0.65)
		ui.spacer(ui.px(pad))
		isz := f32(tab_icon_px(app))
		ui.next({width = ui.px(isz), height = ui.pct(1)})
		ui.custom("###icon", tab_icon_draw, tab_icon_of(app, t, isz))
		ui.spacer(ui.px(math.round(em * 0.5)))
		title := t.title
		if strings.contains(title, "###") { title, _ = strings.replace_all(title, "###", "# # #", context.temp_allocator) }
		if classic {
			// the title is cut by its box (clip) and fades out into the tab's gradient instead of ending in dots
			ui.next({width = ui.fill(), height = ui.pct(1), axis = .X, cross = .Center})
			tb := ui.build_box({.Clip}, "###titlebox")
			if ui.parent(tb) {
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.a11y({ignore = true})   // (the tab's name)
				lb := ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.aprintf("%s###title", title, allocator = ui.frame_allocator()))
				fade := ui.frame_new(Title_Fade)
				fade^ = {tab = paint, width = em * 1.7}
				lb.custom, lb.custom_user = title_fade_draw, fade
			}
		} else {
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
			ui.a11y({ignore = true})   // (the tab's name)
			ui.build_box({.Draw_Text}, fmt.aprintf("%s###title", title, allocator = ui.frame_allocator()))
		}
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
				tip(c, i18n.tr("Close tab (Ctrl+W)"))
				if c.clicked { closed = true }
			}
		}
		// (classic: the next tab covers this one's right foot: the content stops before its slope)
		ui.spacer(ui.px(classic ? tab_dims(paint.m).ext + max(cg.overlap - tab_dims(paint.m).run * 0.5, tab_dims(paint.m).run * 0.5) + math.round(em * 0.2) : math.round(em * 0.35)))
	}
	if closed { tab_close(app, i); return .Closed }
	sig := ui.signal(b)
	if (sig.pressed || sig.clicked) && !on { tab_select(app, i) }   // the press selects; Enter / Space too
	if sig.right_clicked { tab_context_menu(app, i, ui.mouse_pos()) }
	if sig.middle_clicked && favs.cfg.middle_close { tab_close(app, i); return .Closed }
	if !(classic && own.strip.drag.active) { tip(sig, t.title) }   // (classic: the title's tip does not cover the tab being dragged)
	// drag to reorder (straight down starts a drag too: it may leave the bar)
	if sig.dragging && favs.cfg.drag_reorder && (n > 1 || favs.cfg.drag_detach) {
		ui.reorder_begin(&own.strip.drag, t.id, ui.reorder_moved(sig.drag_delta, .X, favs.cfg.drag_detach), favs.cfg.drag_threshold * dpi,
			ui.mouse_pos().x - sig.drag_delta.x - area.rect.min.x, slot)
		if ui.reorder_dragging(&own.strip.drag, t.id) {
			to := drag_slot(x + own.strip.offset, w, n)
			if to != i { move_from^, move_to^ = i, to }
			request_frames(app, 2)
			// far enough below (or above) the row: the tab leaves for a window of its own (tab_drag.odin)
			if favs.cfg.drag_detach && detach_wanted(area.rect, ui.mouse_pos(), false, favs.cfg.detach_distance_em * em) {
				own.strip.drag.active = false
				if tab_drag_begin(app, t, ui.mouse_pos()) && len(wnd.tabs) != n { return .Closed }
			}
		}
	}
	return .None
}

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
	case t.kind == .Config || t.kind == .Blocker: d.kind = .Gear
	case t.load != nil && t.load.failed != .None: d.kind = .Globe   // an error page is not the browser's own page
	case t.page != nil && t.page.env.location.scheme == "about": d.kind = wchrome.icon_px > 0 ? .App : .Globe; d.tex = wchrome.icon
	case t.page != nil && t.page.env.location.scheme == "file": d.kind = .File
	case t.icon.url != "":
		if tex, ok := favicon_texture(t.icon.url); ok { d.kind, d.tex = .Favicon, tex }
	}
	return d
}

// The font size that fits a glyph whose ink is `ink` at size `s` into an `s` square (the size itself when it fits).
icon_glyph_fit :: proc(s: f32, ink: [2]f32) -> f32 {
	big := max(ink.x, ink.y)
	return big > s ? s * s / big : s
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
		// the glyph's ink centred in the icon's square and no larger than it (the icon font's document is taller than its em:
		// at the size of the square it overflowed the row) (the pen is on the baseline: chrome.odin chip_icon_draw)
		glyph := d.kind == .File ? GLYPH_FILE : GLYPH_GEAR
		size := icon_glyph_fit(s, font.glyph(&app.fonts, app.icons, s, rune(glyph[0])).size)
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
