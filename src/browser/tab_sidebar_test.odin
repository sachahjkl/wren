package browser

import "core:math"
import "core:testing"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:platform"
import "toolkit:ui"
import "wb:config"

@(test)
tabs_position_names :: proc(t: ^testing.T) {
	for pos in Tabs_Position { testing.expect_value(t, tabs_position_of(TABS_POSITION_NAMES[pos]), pos) }
	testing.expect_value(t, tabs_position_of(""), Tabs_Position.Top)
	testing.expect_value(t, tabs_position_of("bottom"), Tabs_Position.Top)   // not a position: the row of tabs
}

// The held handle's width follows the pointer of the frame (no frame behind it), toward the page on either side, bounded.
@(test)
sidebar_handle_width_follows_the_pointer :: proc(t: ^testing.T) {
	testing.expect_value(t, sidebar_drag_width(240, 238, 338, 1, .Left), 340)
	testing.expect_value(t, sidebar_drag_width(240, 238, 338, 2, .Left), 290)      // 100 px at 200 %: 50 CSS px
	testing.expect_value(t, sidebar_drag_width(240, 1000, 900, 1, .Right), 340)    // on the right, it grows leftward
	testing.expect_value(t, sidebar_drag_width(240, 238, -500, 1, .Left), SIDEBAR_MIN_CSS)
	testing.expect_value(t, sidebar_drag_width(240, 238, 5000, 1, .Left), SIDEBAR_MAX_CSS)
}

// A tab's glyph icon (a file, the settings) fits the icon's square: the icon font's document is taller than its size.
@(test)
tab_glyph_icon_fits_its_square :: proc(t: ^testing.T) {
	testing.expect_value(t, icon_glyph_fit(16, {14, 15}), 16)          // fits: as asked
	testing.expect_value(t, icon_glyph_fit(16, {14, 17}), 16 * 16.0 / 17)
	testing.expect_value(t, icon_glyph_fit(24, {30, 20}), 24 * 24.0 / 30)
	testing.expect_value(t, icon_glyph_fit(16, {}), 16)                // no ink known
}

// The preference takes the three positions and nothing else, at once; the widths are bounded.
@(test)
tabs_position_preferences :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_all_prefs(&p)
	s := tab_settings_from_prefs(&p)
	testing.expect_value(t, s.position, Tabs_Position.Top)   // the default
	testing.expect_value(t, s.side_w, 240)
	testing.expect_value(t, s.side_collapsed_w, 48)
	testing.expect(t, !s.side_collapsed)
	for pos in Tabs_Position {
		testing.expect_value(t, config.set_from_string(&p, "browser.tabs.position", TABS_POSITION_NAMES[pos], .User), config.Set_Error.None)
		testing.expect_value(t, tab_settings_from_prefs(&p).position, pos)
	}
	testing.expect(t, config.set_from_string(&p, "browser.tabs.position", "bottom", .User) != config.Set_Error.None)
	testing.expect_value(t, tab_settings_from_prefs(&p).position, Tabs_Position.Right)   // a refused value changes nothing

	testing.expect(t, config.set_from_string(&p, "browser.tabs.sidebar_width", "50", .User) != config.Set_Error.None)
	testing.expect(t, config.set_from_string(&p, "browser.tabs.sidebar_width", "5000", .User) != config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "browser.tabs.sidebar_width", "300", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "browser.tabs.sidebar_collapsed", "true", .User), config.Set_Error.None)
	s = tab_settings_from_prefs(&p)
	testing.expect_value(t, s.side_w, 300)
	testing.expect(t, s.side_collapsed)
	testing.expect(t, config.set_from_string(&p, "browser.tabs.sidebar_collapsed_width", "10", .User) != config.Set_Error.None)
	testing.expect(t, config.set_from_string(&p, "browser.tabs.sidebar_row_em", "0.5", .User) != config.Set_Error.None)
}

// The sidebar is as wide as asked, between its minimum and half of the window; icons only: its own narrow width.
@(test)
sidebar_extents :: proc(t: ^testing.T) {
	testing.expect_value(t, sidebar_extent(1280, 240, 1, false, 48), 240)
	testing.expect_value(t, sidebar_extent(1280, 240, 1.5, false, 48), 360)    // times the display's scale
	testing.expect_value(t, sidebar_extent(1280, 40, 1, false, 48), 120)       // never narrower than the minimum
	testing.expect_value(t, sidebar_extent(1000, 600, 1, false, 48), 500)      // never more than half of the window
	testing.expect_value(t, sidebar_extent(200, 240, 1, false, 48), 120)       // a window narrower than twice the minimum: the minimum
	testing.expect_value(t, sidebar_extent(1280, 240, 1, true, 48), 48)
	testing.expect_value(t, sidebar_extent(1280, 240, 2, true, 48), 96)
	testing.expect_value(t, sidebar_extent(60, 240, 1, true, 48), 30)          // (the room of a tiny window comes first)
}

// Opening and closing the sidebar: its width, the icon of a row and the header's buttons go from one end to the other
// without a jump (each step of `open` moves them by a step's share), the ends being the closed and the open layouts as
// they were built before the animation; the titles show nothing while the rows are narrow.
@(test)
sidebar_opens_without_a_jump :: proc(t: ^testing.T) {
	testing.expect_value(t, sidebar_open_extent(48, 240, 0), 48)
	testing.expect_value(t, sidebar_open_extent(48, 240, 1), 240)
	testing.expect_value(t, sidebar_open_extent(48, 240, 0.5), 144)
	testing.expect_value(t, sidebar_open_extent(48, 240, 2), 240)   // (an overshoot is held)
	testing.expect_value(t, side_title_alpha(0), 0)
	testing.expect_value(t, side_title_alpha(0.2), 0)
	testing.expect_value(t, side_title_alpha(1), 1)
	testing.expect_value(t, side_icon_x(40, 16, 10, 0), 12)   // centred in the narrow row
	testing.expect_value(t, side_icon_x(200, 16, 10, 1), 10)  // at the padding of the open row
	bw, bh, inset: f32 = 38, 35, 6
	closed := side_header_layout(48, bw, bh, inset, 0)
	opened := side_header_layout(240, bw, bh, inset, 1)
	testing.expect_value(t, closed.h, inset * 3 + bh * 2)      // one above the other
	testing.expect_value(t, closed.toggle, [2]f32{5, inset})
	testing.expect_value(t, closed.add, [2]f32{5, inset * 2 + bh})
	testing.expect_value(t, opened.h, bh + inset * 2)          // side by side
	testing.expect_value(t, opened.toggle, [2]f32{inset * 2, inset})
	testing.expect_value(t, opened.add, [2]f32{240 - inset * 2 - bw, inset})
	steps :: 60
	prev_e := sidebar_open_extent(48, 240, 0)
	prev := closed
	prev_a: f32
	for k in 1 ..= steps {
		o := f32(k) / steps
		e := sidebar_open_extent(48, 240, o)
		l := side_header_layout(e, bw, bh, inset, o)
		testing.expect(t, e >= prev_e && e - prev_e <= (240 - 48) / f32(steps) + 1)
		testing.expect(t, abs(l.h - prev.h) <= bh / f32(steps) + 1)
		testing.expect(t, abs(l.add.x - prev.add.x) <= 240 / f32(steps) + 1 && abs(l.add.y - prev.add.y) <= (inset + bh) / f32(steps) + 1)
		testing.expect(t, abs(l.toggle.x - prev.toggle.x) <= 240 / f32(steps) + 1)
		a := side_title_alpha(o)
		testing.expect(t, a >= prev_a)
		prev_e, prev, prev_a = e, l, a
	}
	testing.expect(t, sidebar_open_rate(0) > 1e6)                  // at once
	testing.expect(t, abs(1 - math.pow(2, -sidebar_open_rate(180) * 0.18) - 0.95) < 0.001)   // 95 % of the way in 180 ms
}

// The page and the sidebar share the body without overlapping, whatever the position: the sidebar's width and the page's
// make the window's width, and a page at the top has it all.
@(test)
page_and_sidebar_share_the_window :: proc(t: ^testing.T) {
	win := draw.Vec2{1280, 800}
	toolbar_h: f32 = 88   // the title bar and the address row above the body
	body := draw.Rect{{0, toolbar_h}, win}
	for pos in Tabs_Position {
		for extent in ([?]f32{0, 48, 240, 640, 5000}) {
			bar, page := sidebar_split(body, pos, extent)
			if pos == .Top {
				testing.expect_value(t, page, body)
				testing.expect_value(t, bar, draw.Rect{})
				continue
			}
			e := clamp(extent, 0, win.x)
			testing.expect_value(t, bar.max.x - bar.min.x, e)
			testing.expect_value(t, (bar.max.x - bar.min.x) + (page.max.x - page.min.x), win.x)
			testing.expect_value(t, bar.min.y, toolbar_h)
			testing.expect_value(t, page.min.y, toolbar_h)
			testing.expect_value(t, bar.max.y, win.y)
			testing.expect_value(t, page.max.y, win.y)
			// they touch and do not overlap: one ends where the other starts
			if pos == .Left {
				testing.expect_value(t, bar.min.x, 0)
				testing.expect_value(t, bar.max.x, page.min.x)
				testing.expect_value(t, page.max.x, win.x)
			} else {
				testing.expect_value(t, page.min.x, 0)
				testing.expect_value(t, page.max.x, bar.min.x)
				testing.expect_value(t, bar.max.x, win.x)
			}
		}
	}
}

// Only the rows in view and a margin around it are built; a long glide builds what the view shows and a little around.
@(test)
sidebar_builds_only_the_visible_rows :: proc(t: ^testing.T) {
	// 1000 tabs of 40 px in a 400 px view
	f, l := side_visible_rows(0, 0, 400, 40, 1000, 80)
	testing.expect_value(t, f, 0)
	testing.expect_value(t, l, 12)    // 0..400 and two rows below
	f, l = side_visible_rows(4000, 4000, 400, 40, 1000, 80)
	testing.expect_value(t, f, 98)    // 4000 - 80
	testing.expect_value(t, l, 112)   // 4400 + 80
	f, l = side_visible_rows(4000, 4200, 400, 40, 1000, 80)   // heading down by a few rows: they are built already
	testing.expect_value(t, f, 98)
	testing.expect_value(t, l, 117)
	f, l = side_visible_rows(0, 30000, 400, 40, 1000, 80)     // a jump far away: not what is on the way
	testing.expect_value(t, l, 12 + 20)                       // (target held to two views from the offset)
	f, l = side_visible_rows(39700, 39700, 400, 40, 1000, 80) // the end
	testing.expect_value(t, l, 1000)
	testing.expect(t, f > 0 && f < l)
	f, l = side_visible_rows(0, 0, 400, 40, 3, 80)            // few tabs: all of them
	testing.expect_value(t, f, 0)
	testing.expect_value(t, l, 3)
	f, l = side_visible_rows(0, 0, 400, 40, 0, 80)
	testing.expect_value(t, l, 0)
	testing.expect_value(t, f, 0)
}

// The geometry of the row of tabs, along Y: the row a dragged tab goes to, and the scroll that keeps the current tab in view.
@(test)
sidebar_rows_reorder_along_y :: proc(t: ^testing.T) {
	rh: f32 = 40
	// a row dragged by its top edge (content coordinates) belongs to the slot its middle is over
	testing.expect_value(t, drag_slot(0, rh, 8), 0)
	testing.expect_value(t, drag_slot(19, rh, 8), 0)
	testing.expect_value(t, drag_slot(20, rh, 8), 1)
	testing.expect_value(t, drag_slot(140, rh, 8), 4)
	testing.expect_value(t, drag_slot(-300, rh, 8), 0)     // held above the list: the first
	testing.expect_value(t, drag_slot(9000, rh, 8), 7)     // below it: the last
	// 30 tabs in a 400 px view scroll up to 800 px; the current tab is brought into view
	testing.expect_value(t, strip_offset(0, 30, rh, 400, 29, true), 800)
	testing.expect_value(t, strip_offset(800, 30, rh, 400, 0, true), 0)
	testing.expect_value(t, strip_offset(100, 30, rh, 400, 5, true), 100)    // in view already
	testing.expect_value(t, strip_offset(0, 5, rh, 400, 4, true), 0)         // everything fits
	// the order is the strip's: moving a row moves the tab, and the current tab goes along
	l := [5]int{0, 1, 2, 3, 4}
	cur := list_move(l[:], 0, drag_slot(3 * rh, rh, 5), 0)
	testing.expect_value(t, l, [5]int{1, 2, 3, 0, 4})
	testing.expect_value(t, cur, 3)
}

// Widths of a title bar at 100 % (titlebar_wants' order of size): the field's is its minimum, the drag strip's its wish.
@(private = "file")
TB_WANT :: [Titlebar_Part]f32{
	.Lead = 32, .Back = 29, .Forward = 29, .Reload = 29, .Gap_Before = 6, .Field = 140, .Chips = 0, .Gap_After = 6,
	.Shield = 35, .Menu = 32, .Drag = 42, .Buttons = 138,
}
@(private = "file")
TB_DRAG_MIN :: 7

// The toolbar in the title bar: its parts touch, in order, from the window's left edge to its right one; the field never
// goes under its minimum while something can still make room, and what makes room goes in its order.
@(test)
titlebar_parts_share_the_window :: proc(t: ^testing.T) {
	want := TB_WANT
	for w := f32(250); w <= 2000; w += 3 {
		l := titlebar_layout(w, want, TB_DRAG_MIN)
		x: f32
		for p in Titlebar_Part {
			testing.expect_value(t, l.x[p], x)                   // no gap, no overlap
			testing.expect(t, l.w[p] >= 0)
			if p != .Field && p != .Drag { testing.expect_value(t, l.w[p], p in l.shown ? want[p] : 0) }
			x += l.w[p]
		}
		testing.expect(t, abs(x - w) < 0.01)                     // the window's width, exactly
		testing.expect(t, l.w[.Drag] >= TB_DRAG_MIN && l.w[.Drag] <= want[.Drag])
		for p in ([?]Titlebar_Part{.Lead, .Back, .Field, .Gap_Before, .Gap_After, .Menu, .Drag, .Buttons}) { testing.expect(t, p in l.shown) }
		if .Reload in l.shown { testing.expect(t, l.w[.Field] >= want[.Field]) }   // under its minimum only once all made room
		if .Forward not_in l.shown { testing.expect(t, .Shield not_in l.shown) }   // the shield first, then forward, then reload
		if .Reload not_in l.shown { testing.expect(t, .Forward not_in l.shown) }
		if .Shield not_in l.shown { testing.expect(t, l.w[.Field] <= want[.Field] + 0.01) }   // nothing hidden for a wider field
		if l.w[.Drag] < want[.Drag] { testing.expect(t, l.w[.Field] <= want[.Field] + 0.01) }
	}
	// wide: everything, the field takes the rest
	l := titlebar_layout(1280, want, TB_DRAG_MIN)
	testing.expect_value(t, l.shown, ~bit_set[Titlebar_Part]{})
	testing.expect_value(t, l.w[.Drag], 42)
	testing.expect_value(t, l.w[.Field], 1280 - 378)
	// 500 px: the drag strip narrows, the field keeps its minimum
	l = titlebar_layout(500, want, TB_DRAG_MIN)
	testing.expect_value(t, l.shown, ~bit_set[Titlebar_Part]{})
	testing.expect_value(t, l.w[.Field], 140)
	testing.expect_value(t, l.w[.Drag], 24)
	// narrower: the shield goes (the drag strip gets back what it freed beyond the field), then forward, then reload
	l = titlebar_layout(480, want, TB_DRAG_MIN)
	testing.expect_value(t, l.shown, ~bit_set[Titlebar_Part]{} - {.Shield})
	testing.expect_value(t, l.w[.Field], 140)
	testing.expect_value(t, l.w[.Drag], 39)
	l = titlebar_layout(440, want, TB_DRAG_MIN)
	testing.expect_value(t, l.shown, ~bit_set[Titlebar_Part]{} - {.Shield, .Forward})
	testing.expect_value(t, l.w[.Drag], 28)
	l = titlebar_layout(380, want, TB_DRAG_MIN)
	testing.expect_value(t, l.shown, ~bit_set[Titlebar_Part]{} - {.Shield, .Forward, .Reload})
	testing.expect_value(t, l.w[.Field], 130)
	// no shield (the blocker is off): nothing to hide for it, forward goes first
	want[.Shield] = 0
	l = titlebar_layout(440, want, TB_DRAG_MIN)
	testing.expect(t, .Forward not_in l.shown)
	testing.expect(t, .Reload in l.shown)
}

// The row built by titlebar_row_build: its empty parts drag the window, what is clickable in it is the browser's, the
// window buttons are the system's (Snap Layouts), and the top band still resizes.
@(test)
titlebar_row_regions :: proc(t: ^testing.T) {
	page_render_test_lock()
	defer page_render_test_unlock()
	fonts: font.State
	font.init(&fonts)
	defer font.destroy(&fonts)
	ui_font, ok := font.load_embedded(&fonts, font.FALLBACK_UI_DATA)
	if !testing.expect(t, ok) { return }
	theme: ui.Theme
	ui.apply_palette(&theme, ui.PALETTE_GRAPHITE)
	defer ui.theme_destroy(&theme)
	s := new(ui.State)
	defer free(s)
	ui.init(s, &fonts, &theme)
	defer ui.destroy(s)
	s.caption_font_tried = true   // (the glyphs of the window buttons as shapes: no system font is loaded)

	WIN :: [2]f32{1000, 600}
	H :: 32
	l := titlebar_layout(WIN.x, TB_WANT, TB_DRAG_MIN)
	part :: proc(p: Titlebar_Part, user: rawptr) {
		#partial switch p {
		case .Lead:
			ui.spacer(ui.px(10))
			ui.next({width = ui.px(16), height = ui.px(16)})
			_ = ui.build_box({.Clickable}, "###icon")
			ui.spacer(ui.px(6))
		case .Back, .Forward, .Reload, .Field, .Shield, .Menu:
			ui.next({width = ui.pct(1), height = ui.pct(1)})
			_ = ui.build_box({.Clickable}, "###hole")
		case .Buttons:
			_, _ = ui.window_buttons()
		}
	}
	for _ in 0 ..< 3 {
		ui.begin_build(s, {
			window_size = WIN, dt = 1.0 / 60, animations = false, dpi_scale = 1,
			base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = ui_font, font_size = 15, text_pad = 6},
		})
		_ = titlebar_row_build(l, H, part, nil)
		ui.end_build()
		free_all(context.temp_allocator)
	}
	c := ui.chrome_regions(s)
	if !testing.expect_value(t, len(c.caption), 1) { return }
	testing.expect_value(t, c.caption[0].min, [2]f32{0, 0})
	testing.expect_value(t, c.caption[0].max, [2]f32{WIN.x, H})
	testing.expect_value(t, len(c.holes), 7)   // the icon, back, forward, reload, the field, the shield, the menu
	testing.expect_value(t, c.buttons[.Close].max.x, WIN.x)
	testing.expect_value(t, c.buttons[.Minimize].min.x, l.x[.Buttons])
	// each hole is its part, where the layout put it
	found := 0
	for h in c.holes {
		for p in ([?]Titlebar_Part{.Back, .Forward, .Reload, .Field, .Shield, .Menu}) {
			if abs(h.min.x - l.x[p]) < 1 && abs(h.max.x - (l.x[p] + l.w[p])) < 1 { found += 1 }
		}
	}
	testing.expect_value(t, found, 6)

	hit :: proc(c: ^platform.Chrome_Regions, x, y: f32, sides: platform.Sides = {}) -> platform.Hit {
		return platform.hit_test_chrome(c, {x, y}, WIN, 8, 16, sides)
	}
	mid :: proc(l: Titlebar_Layout, p: Titlebar_Part) -> f32 { return math.floor(l.x[p] + l.w[p] * 0.5) }
	testing.expect_value(t, hit(c, 4, 16), platform.Hit.Caption)                         // before the icon
	testing.expect_value(t, hit(c, 18, 16), platform.Hit.Client)                         // the icon (the system menu)
	testing.expect_value(t, hit(c, l.x[.Lead] + l.w[.Lead] - 2, 16), platform.Hit.Caption)   // after it
	testing.expect_value(t, hit(c, mid(l, .Gap_Before), 16), platform.Hit.Caption)       // beside the field
	testing.expect_value(t, hit(c, mid(l, .Gap_After), 16), platform.Hit.Caption)
	testing.expect_value(t, hit(c, mid(l, .Drag), 16), platform.Hit.Caption)             // before the window buttons
	for p in ([?]Titlebar_Part{.Back, .Forward, .Reload, .Field, .Shield, .Menu}) {
		testing.expect_value(t, hit(c, mid(l, p), 16), platform.Hit.Client)
	}
	bx := l.x[.Buttons]
	testing.expect_value(t, hit(c, bx + 23, 16), platform.Hit.Minimize)
	testing.expect_value(t, hit(c, bx + 69, 16), platform.Hit.Maximize)                  // HTMAXBUTTON: Snap Layouts
	testing.expect_value(t, hit(c, bx + 115, 16), platform.Hit.Close)
	testing.expect_value(t, hit(c, mid(l, .Field), H + 10), platform.Hit.Client)         // below the row: the page's
	testing.expect_value(t, hit(c, mid(l, .Drag), 3, {.Top}), platform.Hit.Top)          // the top band resizes
	testing.expect_value(t, hit(c, mid(l, .Field), 3, {.Top}), platform.Hit.Top)
}
