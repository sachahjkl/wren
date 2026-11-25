package browser

import "core:testing"
import "toolkit:font"
import "toolkit:ui"

// Tabs with no page in a list of their own (in no window): the App frees them (app_free).
@(private = "file")
fake_list :: proc(app: ^App, urls: ..string) -> [dynamic]^Tab {
	l := make([dynamic]^Tab)
	for u in urls { append(&l, tab_new_bare(app, nil, u)) }
	return l
}

// Tabs with no page at the end of a window's strip.
@(private = "file")
fake_tabs :: proc(app: ^App, w: ^Browser_Window, urls: ..string) {
	for u in urls { tab_new_bare(app, w, u) }
}

@(test)
tab_list_take_keeps_the_current_tab_right :: proc(t: ^testing.T) {
	app := test_app(t)   // (the tabs go with it)
	l := fake_list(app, "a", "b", "c", "d")
	defer delete(l)
	// before the current one: the current index follows its tab
	cur := tab_list_take(&l, 2, 0)
	testing.expect_value(t, cur, 1)
	testing.expect_value(t, l[cur].url, "c")
	// the current one: the tab that took its place, else the last
	cur = tab_list_take(&l, 1, 1)
	testing.expect_value(t, cur, 1)
	testing.expect_value(t, l[cur].url, "d")
	cur = tab_list_take(&l, 1, 1)
	testing.expect_value(t, cur, 0)
	// after it: unchanged; the only one: an empty list
	cur = tab_list_take(&l, 0, 0)
	testing.expect_value(t, cur, 0)
	testing.expect_value(t, len(l), 0)
	// an index out of the list changes nothing
	testing.expect_value(t, tab_list_take(&l, 3, 7), 3)
}

@(test)
tab_list_put_places_and_selects :: proc(t: ^testing.T) {
	app := test_app(t)   // (the tabs go with it)
	l := fake_list(app, "a", "b", "c")
	defer delete(l)
	n := tab_new_bare(app, nil, "n")
	cur, at := tab_list_put(&l, 1, 1, n, true)
	testing.expect_value(t, cur, 1)
	testing.expect_value(t, at, 1)
	testing.expect_value(t, l[1].url, "n")
	testing.expect_value(t, len(l), 4)
	// not selected, put before the current one: the current tab keeps its tab
	m := tab_new_bare(app, nil, "m")
	cur, at = tab_list_put(&l, 2, 0, m, false)
	testing.expect_value(t, cur, 3)
	testing.expect_value(t, l[cur].url, "b")
	// at the end (negative), and far past the end
	e := tab_new_bare(app, nil)
	cur, at = tab_list_put(&l, 0, -1, e, false)
	testing.expect_value(t, at, len(l) - 1)
	testing.expect_value(t, cur, 0)
	f := tab_new_bare(app, nil)
	_, at = tab_list_put(&l, 0, 99, f, false)
	testing.expect_value(t, at, len(l) - 1)
}

// Two windows with no native window in the test's App (test_app): their tabs go with the App.
@(private = "file")
two_windows :: proc(t: ^testing.T) -> (app: ^App, a, b: ^Browser_Window) {
	app = test_app(t)
	a, b = new(Browser_Window), new(Browser_Window)
	a.id, b.id = 1, 2
	append(&app.windows, a, b)
	return
}

@(private = "file")
free_windows :: proc(app: ^App, a, b: ^Browser_Window) {
	for w in ([]^Browser_Window{a, b}) {
		delete(w.ctx.tabs)
		ui.line_edit_destroy(&w.ctx.address)
		free(w)
	}
	delete(app.windows)
	app.windows = nil   // (app_free takes the tabs out of the strips it finds)
}

@(test)
tab_moves_between_windows :: proc(t: ^testing.T) {
	app, a, b := two_windows(t)
	defer free_windows(app, a, b)
	fake_tabs(app, a, "a1", "a2", "a3")
	fake_tabs(app, b, "b1")
	a.ctx.current, b.ctx.current = 1, 0
	moved := a.ctx.tabs[1]
	testing.expect(t, tab_move(app, moved, b, 0))
	testing.expect_value(t, len(a.ctx.tabs), 2)
	testing.expect_value(t, a.ctx.current, 1)
	testing.expect_value(t, a.ctx.tabs[a.ctx.current].url, "a3")   // the tab that took its place is shown
	testing.expect_value(t, len(b.ctx.tabs), 2)
	testing.expect(t, b.ctx.tabs[0] == moved)   // the same Tab: its page was not touched
	testing.expect_value(t, b.ctx.current, 0)   // and it is the one shown
	testing.expect(t, !a.closing && !b.closing)
	w, i := window_of_tab(app, moved)
	testing.expect(t, w == b && i == 0)
}

@(test)
the_window_that_loses_its_last_tab_closes :: proc(t: ^testing.T) {
	app, a, b := two_windows(t)
	defer free_windows(app, a, b)
	fake_tabs(app, a, "only")
	fake_tabs(app, b, "b1", "b2")
	a.ctx.current, b.ctx.current = 0, 1
	testing.expect(t, tab_move(app, a.ctx.tabs[0], b))
	testing.expect(t, a.closing)
	testing.expect_value(t, len(a.ctx.tabs), 0)
	testing.expect_value(t, len(b.ctx.tabs), 3)
	testing.expect_value(t, b.ctx.current, 2)   // at the end, and shown
	// a tab of no window, or no window: nothing
	stray := tab_new_bare(app, nil)
	testing.expect(t, !tab_move(app, stray, b))
	testing.expect(t, !tab_move(app, b.ctx.tabs[0], nil))
}

@(test)
a_tab_moves_within_its_window :: proc(t: ^testing.T) {
	app, a, b := two_windows(t)
	defer free_windows(app, a, b)
	fake_tabs(app, a, "1", "2", "3", "4")
	fake_tabs(app, b, "x")
	a.ctx.current = 0
	first := a.ctx.tabs[0]
	testing.expect(t, tab_move(app, first, a, 2))
	testing.expect_value(t, a.ctx.tabs[2].url, "1")
	testing.expect_value(t, a.ctx.current, 2)   // the current tab went with it
	testing.expect(t, tab_move(app, first, a))   // no place: the end
	testing.expect_value(t, a.ctx.tabs[3].url, "1")
}

@(test)
every_tab_of_every_window_is_listed_once :: proc(t: ^testing.T) {
	app, a, b := two_windows(t)
	defer free_windows(app, a, b)
	fake_tabs(app, a, "a1", "a2")
	fake_tabs(app, b, "b1")
	app.front = b
	all := tabs_all(app)
	testing.expect_value(t, len(all), 3)
	testing.expect_value(t, all[0].url, "b1")   // the front window's first
	testing.expect(t, tab_by_id(app, a.ctx.tabs[1].id) == a.ctx.tabs[1])
	testing.expect(t, tab_by_id(app, 0) == nil)   // (ids start at 1)
}

@(test)
window_invalidate_records_causes_and_drains_to_rest :: proc(t: ^testing.T) {
	app := test_app(t)
	w := active_window(app)
	testing.expect(t, window_at_rest(w), "fresh window starts at rest")
	testing.expect(t, !window_has_request(w), "fresh window has no pending request")
	testing.expect_value(t, window_frames_pending(w), 0)

	// Invalidate records typed causes and caller location.
	window_invalidate(w, .Chrome)
	app_invalidate(app, .Remote)
	testing.expect_value(t, w.causes, Frame_Causes{.Chrome, .Remote})
	testing.expect(t, w.asked_by.line > 0, "caller location recorded")
	testing.expect(t, window_has_request(w), "invalidated window has request")
	testing.expect_value(t, window_frames_pending(w), 1)
	testing.expect(t, !window_at_rest(w), "invalidated window is not at rest")

	// Frame begin snapshots causes into frame_causes and clears pending causes.
	window_frame_begin(w, {.Asked})
	testing.expect_value(t, w.frame_causes, Frame_Causes{.Chrome, .Remote})
	testing.expect_value(t, w.causes, Frame_Causes{})
	testing.expect(t, !window_is_errand(w), "Chrome + Remote is not an errand frame")
	testing.expect(t, window_at_rest(w), "window is at rest once causes drain")

	// Invalidation during a frame queues for the next frame without disturbing frame_causes.
	window_invalidate(w, .Page)
	testing.expect_value(t, w.frame_causes, Frame_Causes{.Chrome, .Remote})
	testing.expect_value(t, w.causes, Frame_Causes{.Page})
	testing.expect(t, !window_at_rest(w), "in-frame invalidation keeps next frame scheduled")
	window_frame_begin(w, {.Asked})
	testing.expect_value(t, w.frame_causes, Frame_Causes{.Page})
	testing.expect(t, window_at_rest(w), "next frame drains queued cause to rest")

	// Nil safety.
	window_invalidate(nil, .Chrome)
	app_invalidate(nil, .Chrome)
	testing.expect(t, window_at_rest(nil), "nil window is at rest")
}

@(test)
window_layout_check_schedules_followup_on_bounds_change_and_rests :: proc(t: ^testing.T) {
	app := test_app(t)
	app_fonts_init(app)
	ui_font, ok := font.load_embedded(&app.fonts, font.FALLBACK_UI_DATA)
	if !testing.expect(t, ok, "embedded UI font") { return }

	state := new(ui.State)
	theme: ui.Theme
	defer {
		ui.destroy(state)
		free(state)
		ui.theme_destroy(&theme)
		free_all(context.temp_allocator)
	}
	ui.init(state, &app.fonts, &theme)

	w: Browser_Window
	w.ui = state

	step :: proc(w: ^Browser_Window, f: font.Font_Id, box_w, scroll_child_h: f32) -> bool {
		window_frame_begin(w, {.Asked})
		base := ui.Style{pref = {.X = ui.px(100), .Y = ui.px(32)}, font = f, font_size = 14}
		ui.begin_build(w.ui, {window_size = {800, 600}, dt = 1.0 / 60, animations = false, dpi_scale = 1, base = base})
		ui.next({width = ui.px(box_w), height = ui.px(40)})
		_ = ui.build_box({}, "###panel")
		ui.next({width = ui.px(200), height = ui.px(120), axis = .Y})
		if ui.scroll_y("###list") {
			ui.next({width = ui.px(180), height = ui.px(scroll_child_h)})
			_ = ui.build_box({}, "###content")
		}
		ui.end_build()
		return window_layout_check(w)
	}

	// Build 1: establishes initial layout -> schedules automatic .Layout follow-up.
	window_invalidate(&w, .Chrome)
	testing.expect(t, step(&w, ui_font, 120, 400), "first build schedules .Layout settle")
	testing.expect(t, .Layout in w.causes, ".Layout cause recorded")
	testing.expect(t, !window_at_rest(&w), "not at rest while .Layout follow-up pending")

	// Build 2: identical rects and scroll bounds -> no follow-up, window rests.
	testing.expect(t, !step(&w, ui_font, 120, 400), "unchanged layout schedules no follow-up")
	testing.expect(t, window_at_rest(&w), "window rests after layout settles")

	// Build 3: box width changes -> automatic .Layout follow-up scheduled.
	window_invalidate(&w, .Chrome)
	testing.expect(t, step(&w, ui_font, 240, 400), "box resize schedules .Layout follow-up")
	testing.expect(t, .Layout in w.causes, ".Layout cause recorded on box resize")

	// Build 4: settles again.
	testing.expect(t, !step(&w, ui_font, 240, 400), "settled resize schedules no follow-up")
	testing.expect(t, window_at_rest(&w), "window rests after resize settles")

	// Build 5: scroll container content height grows (outer rect unchanged, view_bounds changed) -> .Layout follow-up.
	window_invalidate(&w, .Page)
	testing.expect(t, step(&w, ui_font, 240, 900), "scroll bounds change schedules .Layout follow-up")
	testing.expect(t, .Layout in w.causes, ".Layout cause recorded on scroll bounds change")

	// Build 6: settles again.
	testing.expect(t, !step(&w, ui_font, 240, 900), "settled scroll bounds schedules no follow-up")
	testing.expect(t, window_at_rest(&w), "window rests after scroll bounds settle")
}

@(test)
window_layout_followup_is_bounded_and_preserves_errands :: proc(t: ^testing.T) {
	app, a, b := two_windows(t)
	defer free_windows(app, a, b)

	// Consecutive oscillating signatures stop after MAX_LAYOUT_FOLLOWUPS so the loop cannot spin.
	window_invalidate(a, .Chrome)
	window_frame_begin(a, {.Asked})
	for i in 0 ..< MAX_LAYOUT_FOLLOWUPS {
		testing.expectf(t, window_note_layout(a, u64(100 + i)), "follow-up %d allowed", i + 1)
		testing.expect(t, .Layout in a.causes, "follow-up records .Layout")
		window_frame_begin(a, {.Asked})
	}
	testing.expect(t, !window_note_layout(a, 999), "oscillating layout stops after MAX_LAYOUT_FOLLOWUPS")
	testing.expect(t, window_at_rest(a), "window rests once layout follow-up budget is spent")

	// A non-Layout cause resets the follow-up budget.
	window_invalidate(a, .Style)
	window_frame_begin(a, {.Asked})
	testing.expect(t, window_note_layout(a, 1000), "new non-Layout cause restores budget")
	testing.expect(t, .Layout in a.causes, ".Layout scheduled again")

	// An errand-only Status_Bar frame records its updated layout signature without scheduling an extra follow-up frame.
	window_invalidate(b, .Status_Bar)
	window_frame_begin(b, {.Asked})
	testing.expect(t, window_is_errand(b, {.Status_Bar}), "Status_Bar frame is errand-only")
	testing.expect(t, !window_note_layout(b, 42), "errand-only frame does not schedule automatic layout follow-up")
	testing.expect_value(t, b.layout_sig, u64(42))
	testing.expect(t, b.layout_settled, "errand-only frame records settled layout signature")
	testing.expect(t, window_at_rest(b), "errand-only frame rests after drawing once")

	// windows_spill_causes skips active and minimized windows.
	app.active = a
	b.minimized = false
	windows_spill_causes(app, {.Chrome})
	testing.expect_value(t, a.causes, Frame_Causes{.Layout})
	testing.expect_value(t, b.causes, Frame_Causes{.Chrome})
	b.causes = {}
	b.minimized = true
	windows_spill_causes(app, {.Remote})
	testing.expect_value(t, b.causes, Frame_Causes{})
	app.active = nil
}

@(test)
tab_stable_ignores_errand_and_continuous_causes_but_waits_for_active_work :: proc(t: ^testing.T) {
	app := test_app(t)
	state := new(ui.State)
	theme: ui.Theme
	defer {
		ui.destroy(state)
		free(state)
		ui.theme_destroy(&theme)
	}
	ui.init(state, &app.fonts, &theme)
	w := active_window(app)
	w.ui = state
	defer { w.ui = nil }

	tab := tab_new_bare(app, w, "https://example.test/")
	testing.expect(t, tab_stable(app, tab), "quiet loaded tab is stable")

	// Errands and continuous motion (.Animation, .Media) do not block tab_stable.
	for c in ([]Frame_Cause{.Caret, .Status_Bar, .Reader, .Animation, .Media}) {
		w.causes = {c}
		testing.expectf(t, tab_stable(app, tab), "tab_stable ignores cause %v", c)
	}
	w.causes = FRAME_ERRAND_CAUSES + FRAME_CONTINUOUS_CAUSES
	testing.expect(t, tab_stable(app, tab), "tab_stable ignores combined errand and continuous causes")

	// Active unsettled work blocks tab_stable.
	for c in ([]Frame_Cause{.Input, .Layout, .Style, .Page, .Chrome, .Remote}) {
		w.causes = {c}
		testing.expectf(t, !tab_stable(app, tab), "tab_stable waits for active cause %v", c)
	}
	w.causes = {}
}

@(test)
window_layout_followup_stays_bounded_during_continuous_animation :: proc(t: ^testing.T) {
	app, a, b := two_windows(t)
	defer free_windows(app, a, b)

	// Continuous animation (.Animation + .Page loop cause) must not reset layout_followups on every frame.
	window_invalidate(a, .Animation)
	window_frame_begin(a, {.Asked, .Page})
	for i in 0 ..< MAX_LAYOUT_FOLLOWUPS {
		testing.expectf(t, window_note_layout(a, u64(200 + i)), "animated follow-up %d allowed", i + 1)
		window_invalidate(a, .Animation)
		window_frame_begin(a, {.Asked, .Page})
	}
	testing.expect(t, !window_note_layout(a, 300), "oscillating layout stops after MAX_LAYOUT_FOLLOWUPS even while animating")
	testing.expect(t, .Layout not_in a.causes, "no .Layout queued once budget is spent during animation")

	// Once the layout signature stops changing, the budget resets for future legitimate layout changes.
	window_invalidate(a, .Animation)
	window_frame_begin(a, {.Asked, .Page})
	testing.expect(t, !window_note_layout(a, 300), "unchanged signature schedules no follow-up")
	testing.expect_value(t, a.layout_followups, 0)
	testing.expect(t, window_note_layout(a, 301), "settled window gets a fresh follow-up budget")
	testing.expect(t, .Layout in a.causes, ".Layout queued after budget restored")
}

@(test)
centred_toolbar_converges_without_1px_oscillation :: proc(t: ^testing.T) {
	app := test_app(t)
	app_fonts_init(app)
	ui_font, ok := font.load_embedded(&app.fonts, font.FALLBACK_UI_DATA)
	if !testing.expect(t, ok, "embedded UI font") { return }

	state := new(ui.State)
	theme: ui.Theme
	defer {
		ui.destroy(state)
		free(state)
		ui.theme_destroy(&theme)
		free_all(context.temp_allocator)
	}
	ui.init(state, &app.fonts, &theme)

	w: Browser_Window
	w.ui = state

	// Reproduce a 900 px toolbar whose trailing children_sum box has a fractional width (118.4 px)
	// and a 672 px max address bar: using prev_box.size.x must settle cleanly with zero 1 px ping-pong.
	step :: proc(w: ^Browser_Window, f: font.Font_Id) -> bool {
		window_frame_begin(w, {.Asked})
		base := ui.Style{pref = {.X = ui.px(100), .Y = ui.px(32)}, font = f, font_size = 14}
		ui.begin_build(w.ui, {window_size = {900, 42}, dt = 1.0 / 60, animations = false, dpi_scale = 1, base = base})
		ui.next({width = ui.fill(), height = ui.px(42)})
		if ui.row(.Center, {}, "###toolbar") {
			lead: f32 = 109.6
			ui.spacer(ui.px(lead))
			trail: f32
			if end := ui.prev_box("###toolbar_end"); end != nil { trail = end.size.x }
			before, width := address_bar_span(900, lead, trail, ADDRESS_BAR_MAX_EM * 14)
			ui.spacer(ui.px(before))
			ui.next({width = ui.px(width), height = ui.px(30)})
			_ = ui.build_box({}, "###address_bar")
			ui.spacer(ui.fill())
			ui.next({width = ui.children_sum(), height = ui.pct(1), axis = .X, cross = .Center})
			if ui.parent(ui.build_box({}, "###toolbar_end")) {
				ui.spacer(ui.px(118.4))
			}
		}
		ui.end_build()
		return window_layout_check(w)
	}

	window_invalidate(&w, .Chrome)
	_ = step(&w, ui_font) // frame 1: prev_box absent, establishes ###toolbar_end size
	_ = step(&w, ui_font) // frame 2: applies ###toolbar_end size.x
	for i in 0 ..< 5 {
		testing.expectf(t, !step(&w, ui_font), "toolbar must stay settled on frame %d", i + 3)
	}
}
