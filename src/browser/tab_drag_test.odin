package browser

import "core:strings"
import "core:testing"
import "core:time"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"

@(private = "file")
row_zone :: proc(n: int, offset: f32 = 0) -> Drop_Zone {
	return {rect = {{100, 0}, {500, 36}}, pitch = 100, n = n, offset = offset, valid = true}
}

@(test)
drop_index_is_the_gap_nearest_the_pointer :: proc(t: ^testing.T) {
	test_app(t)
	z := row_zone(3)
	at, inside := drop_index(z, {120, 10})   // in the first tab's left half: before it
	testing.expect(t, inside)
	testing.expect_value(t, at, 0)
	at, _ = drop_index(z, {180, 10})   // in its right half: after it
	testing.expect_value(t, at, 1)
	at, _ = drop_index(z, {400, 10})   // beyond the last tab: at the end
	testing.expect_value(t, at, 3)
}

@(test)
drop_index_follows_the_scroll_and_the_axis :: proc(t: ^testing.T) {
	test_app(t)
	z := row_zone(10, 250)   // scrolled by two tabs and a half
	at, _ := drop_index(z, {100, 5})
	testing.expect_value(t, at, 3)   // 250 / 100 + 0.5 = 3
	v := Drop_Zone{rect = {{0, 40}, {200, 440}}, vertical = true, pitch = 40, n = 4, valid = true}
	at, _ = drop_index(v, {50, 100})   // (100 - 40) / 40 + 0.5 = 2
	testing.expect_value(t, at, 2)
}

@(test)
drop_outside_the_tabs_is_no_drop :: proc(t: ^testing.T) {
	test_app(t)
	z := row_zone(3)
	_, inside := drop_index(z, {120, 80})   // under the row
	testing.expect(t, !inside)
	_, inside = drop_index(z, {50, 10})   // left of it
	testing.expect(t, !inside)
	z.valid = false   // a window that has not laid its tabs out (full screen, hidden bar)
	_, inside = drop_index(z, {120, 10})
	testing.expect(t, !inside)
	z = row_zone(3)
	z.pitch = 0
	_, inside = drop_index(z, {120, 10})
	testing.expect(t, !inside)
}

@(test)
pick_drop_finds_the_window_under_the_pointer :: proc(t: ^testing.T) {
	test_app(t)
	origins := []draw.Vec2{{0, 0}, {1000, 0}, {1000, 500}}
	zones := []Drop_Zone{row_zone(2), row_zone(2), row_zone(5)}
	w, at, ok := pick_drop(origins, zones, -1, {1180, 10})   // window 1's row: its first tab's right half
	testing.expect(t, ok)
	testing.expect_value(t, w, 1)
	testing.expect_value(t, at, 1)
	w, _, ok = pick_drop(origins, zones, -1, {1300, 510})
	testing.expect_value(t, w, 2)
	// the window being carried is skipped, even when the pointer is over its own bar
	_, _, ok = pick_drop(origins, zones, 1, {1180, 10})
	testing.expect(t, !ok)
	// nowhere
	_, _, ok = pick_drop(origins, zones, 0, {5000, 5000})
	testing.expect(t, !ok)
	// a window above (first in the list) that covers the pointer away from its own tabs hides the tabs of the one below
	covers := []draw.Rect{{{1000, 0}, {1600, 400}}, {{1000, 0}, {1600, 400}}, {}}
	zones2 := []Drop_Zone{row_zone(2), row_zone(2), row_zone(5)}
	origins2 := []draw.Vec2{{1000, -100}, {1000, 0}, {0, 0}}   // window 0's row is 100 px higher than window 1's
	_, _, ok = pick_drop(origins2, zones2, -1, {1180, 10}, covers)
	testing.expect(t, !ok, "covered: no drop on the window below")
	w, _, ok = pick_drop(origins2, zones2, -1, {1180, 10})
	testing.expect(t, ok && w == 1, "(without what they cover: the first one whose tabs are there)")
}

// A tab carried over a row of tabs: pinned ones first, then two groups (1: tabs 2-3, 2: tab 5) and tabs in none.
@(test)
drop_slot_in_a_row_follows_pins_and_groups :: proc(t: ^testing.T) {
	test_app(t)
	ts: [7]Tab
	ts[0].pinned, ts[1].pinned = true, true
	ts[2].group, ts[3].group, ts[5].group = 1, 1, 2
	tabs: [7]^Tab
	for _, i in ts { tabs[i] = &ts[i] }
	s := drop_slot_row(tabs[:], 100, 30, false)   // over the first pinned tab: after the pinned ones
	testing.expect(t, s.index == 2 && s.group == 0 && !s.pinned && s.mark == 200, "a tab that is not pinned goes after the pinned ones, the mark there")
	s = drop_slot_row(tabs[:], 100, 330, false)   // between the two tabs of group 1
	testing.expect(t, s.index == 3 && s.group == 1 && s.mark == 300, "between two tabs of a group it joins it")
	s = drop_slot_row(tabs[:], 100, 420, false)   // after group 1, before a tab in none
	testing.expect(t, s.index == 4 && s.group == 0, "at a group's edge it stays out")
	s = drop_slot_row(tabs[:], 100, 640, false)   // after group 2's only tab
	testing.expect(t, s.index == 6 && s.group == 0, "after a group's last tab: out of it")
	s = drop_slot_row(tabs[:], 100, 5000, false)
	testing.expect(t, s.index == 7 && s.mark == 700, "beyond the last tab: at the end")
	s = drop_slot_row(tabs[:], 100, 640, true)   // a pinned tab carried over the others
	testing.expect(t, s.index == 2 && s.pinned && s.group == 0 && s.mark == 200, "a pinned tab goes at the end of the pinned ones")
}

// A tab carried over the sidebar's list: rows of tabs and a header before each group, a collapsed group's tabs left out.
@(test)
drop_slot_in_the_list_follows_headers_and_groups :: proc(t: ^testing.T) {
	test_app(t)
	ts: [6]Tab
	ts[0].pinned = true
	ts[2].group, ts[3].group, ts[5].group = 7, 7, 8
	tabs: [6]^Tab
	for _, i in ts { tabs[i] = &ts[i] }
	groups := []Tab_Group{{id = 7}, {id = 8, collapsed = true}}
	items: [dynamic]Side_Item
	defer delete(items)
	total := side_list_layout(tabs[:], groups, 40, 30, &items)
	// rows: tab 1 (0-40), header 7 (40-70), tab 2 (70-110), tab 3 (110-150), tab 4 (150-190), header 8 (190-220), collapsed
	testing.expect_value(t, total, f32(220))
	s := drop_slot_list(items[:], tabs[:], groups, 10)
	testing.expect(t, s.index == 1 && s.group == 0 && s.mark == 0 && !s.pinned, "the upper half of the first row: before it (after the pinned tab)")
	s = drop_slot_list(items[:], tabs[:], groups, 50)
	testing.expect(t, s.index == 2 && s.group == 0 && s.mark == 40, "a header's upper half: before its group, out of it")
	s = drop_slot_list(items[:], tabs[:], groups, 65)
	testing.expect(t, s.index == 2 && s.group == 7 && s.mark == 70, "its lower half: the start of the group, in it")
	s = drop_slot_list(items[:], tabs[:], groups, 140)
	testing.expect(t, s.index == 4 && s.group == 7 && s.mark == 150, "the lower half of a group's last tab: at its end, in it")
	s = drop_slot_list(items[:], tabs[:], groups, 160)
	testing.expect(t, s.index == 4 && s.group == 0 && s.mark == 150, "the upper half of the next tab, in no group: the same place, out of it")
	s = drop_slot_list(items[:], tabs[:], groups, 215)
	testing.expect(t, s.index == 6 && s.group == 0 && s.mark == 220, "a collapsed group's header, lower half: after the group, out of it")
	s = drop_slot_list(items[:], tabs[:], groups, 1000)
	testing.expect(t, s.index == 6 && s.mark == 220, "below the last row: at the end")
}

@(test)
a_tab_leaves_the_bar_only_far_enough :: proc(t: ^testing.T) {
	test_app(t)
	row := draw.Rect{{100, 0}, {500, 36}}
	testing.expect(t, !detach_wanted(row, {300, 50}, false, 40))   // below the row, but not by 40
	testing.expect(t, detach_wanted(row, {300, 80}, false, 40))
	testing.expect(t, detach_wanted(row, {300, -50}, false, 40))   // above it (a window at the top of the screen)
	testing.expect(t, !detach_wanted(row, {900, 10}, false, 40))   // along the row is the reorder's
	side := draw.Rect{{0, 40}, {240, 600}}
	testing.expect(t, !detach_wanted(side, {200, 900}, true, 40))   // along the sidebar is the reorder's
	testing.expect(t, detach_wanted(side, {300, 100}, true, 40))
	testing.expect(t, detach_wanted(side, {-60, 100}, true, 40))
}


// Where the system keeps positions from the app (Wayland), the tab leaves as a drag of the system; elsewhere its window
// follows the pointer.
@(test)
the_path_of_a_tab_drag_follows_what_the_system_tells :: proc(t: ^testing.T) {
	testing.expect_value(t, tab_drag_path(true), Tab_Drag_Path.Carry)
	testing.expect_value(t, tab_drag_path(false), Tab_Drag_Path.System)
}

// A drag of the system that no window took (released over nothing, over another application, given up) detaches the
// tab; one a window took leaves the move to that window.
@(test)
a_tab_drag_with_no_target_detaches :: proc(t: ^testing.T) {
	testing.expect_value(t, tab_drop_end(nil), Tab_Drop_End.Detach)
	testing.expect_value(t, tab_drop_end(platform.Drop_Effect.Move), Tab_Drop_End.Taken)
	testing.expect_value(t, tab_drop_end(platform.Drop_Effect.Copy), Tab_Drop_End.Taken)
	// the window is made at the end unless the drag can carry it
	testing.expect_value(t, tab_window_when(false), Tab_Window_When.End)
	testing.expect_value(t, tab_window_when(true), Tab_Window_When.Start)
}

@(test)
a_tab_drag_carries_its_id_in_its_own_type :: proc(t: ^testing.T) {
	d: platform.Drag_Data
	defer delete(d.custom)
	_, ok := tab_drag_id_of(&d)
	testing.expect(t, !ok, "no entry: no tab")
	append(&d.custom, platform.Drag_Entry{"text/x-other", "12"}, platform.Drag_Entry{TAB_MIME, tab_drag_payload(4242)})
	id, ok2 := tab_drag_id_of(&d)
	testing.expect(t, ok2 && id == 4242, "the tab's id from its type, other entries aside")
	d.custom[1].data = "not a number"
	_, ok = tab_drag_id_of(&d)
	testing.expect(t, !ok)
	_, ok = tab_drag_id_of(nil)
	testing.expect(t, !ok)
}

// A drop's position is the window's own (no screen position on Wayland): on its tabs it is window_drop_slot's slot.
@(test)
a_drop_on_a_window_bar_takes_the_slot_from_its_own_position :: proc(t: ^testing.T) {
	test_app(t)
	ts: [3]Tab
	ts[1].group, ts[2].group = 5, 5
	w: Browser_Window
	defer delete(w.tabs)
	for _, i in ts { append(&w.tabs, &ts[i]) }
	w.zone = row_zone(3)
	carried: Tab
	slot, on_bar := tab_drop_at(&w, {340, 10}, &carried)   // the gap between the two tabs of group 5
	testing.expect(t, on_bar)
	testing.expect_value(t, slot, window_drop_slot(&w, {340, 10}, &carried))
	testing.expect(t, slot.index == 2 && slot.group == 5)
	_, on_bar = tab_drop_at(&w, {340, 200}, &carried)   // on the page: a new window
	testing.expect(t, !on_bar)
}

// Only the Drop_* events of the drag's time are the tab drag's (they were queued while drag_start blocked).
@(test)
queued_drop_events_belong_to_the_tab_drag_by_their_time :: proc(t: ^testing.T) {
	a := time.Tick{_nsec = 100}
	b := time.Tick{_nsec = 200}
	testing.expect(t, !tab_drop_in_span({}, {_nsec = 150}), "no drag ran")
	testing.expect(t, tab_drop_in_span({a, b}, {_nsec = 150}))
	testing.expect(t, tab_drop_in_span({a, b}, b))
	testing.expect(t, !tab_drop_in_span({a, b}, {_nsec = 50}), "before it")
	testing.expect(t, !tab_drop_in_span({a, b}, {_nsec = 250}), "a later drag of another application")
}

// Wayland xdg-toplevel-drag-v1 carry mode selection, DPI-scaled grab point, and Drag_Carry setup.
@(test)
wayland_carry_mode_grab_and_descriptor :: proc(t: ^testing.T) {
	app := test_app(t)
	// Fallback when compositor does not advertise xdg-toplevel-drag-v1.
	testing.expect_value(t, tab_carry_mode(false, 0), Tab_Carry_Mode.None)
	testing.expect_value(t, tab_carry_mode(false, 1), Tab_Carry_Mode.None)
	testing.expect_value(t, tab_carry_mode(false, 3), Tab_Carry_Mode.None)
	// Supported: empty -> None, single-tab -> Self (no tab_detach), multi-tab -> Detach.
	testing.expect_value(t, tab_carry_mode(true, 0), Tab_Carry_Mode.None)
	testing.expect_value(t, tab_carry_mode(true, 1), Tab_Carry_Mode.Self)
	testing.expect_value(t, tab_carry_mode(true, 2), Tab_Carry_Mode.Detach)

	// Grab scales with DPI and clamps low/zero scales to 0.5.
	testing.expect_value(t, tab_drag_grab(0.0), [2]int{30, 8})
	testing.expect_value(t, tab_drag_grab(1.0), [2]int{60, 16})
	testing.expect_value(t, tab_drag_grab(1.5), [2]int{90, 24})
	testing.expect_value(t, tab_drag_grab(2.0), [2]int{120, 32})

	// Descriptor rejects nil inputs and wires window, scaled grab, frame callback, and user pointer.
	testing.expect_value(t, tab_drag_carry_for(nil, nil), platform.Drag_Carry{})
	empty_w: Browser_Window
	testing.expect_value(t, tab_drag_carry_for(app, &empty_w), platform.Drag_Carry{})

	pw := platform.Window{dpi_scale = 2.0}
	src := Browser_Window{id = 21, win = &pw}
	carry := tab_drag_carry_for(app, &src)
	testing.expect(t, carry.window == &pw, "single-tab self-carry attaches source window")
	testing.expect_value(t, carry.grab, [2]int{120, 32})
	testing.expect(t, carry.frame != nil, "carry.frame callback is wired")
	testing.expect(t, carry.user == app, "carry.user points to App")
}

// carry.frame guards: unpaintable, closed, empty, or missing windows are skipped cleanly without UAF.
@(test)
wayland_carry_paintable_and_frame_guards :: proc(t: ^testing.T) {
	app := test_app(t)
	testing.expect(t, !tab_drag_carry_paintable(nil))

	pw := platform.Window{size = {800, 600}}
	us: ui.State
	w := Browser_Window{id = 31, win = &pw, ui = &us}
	defer delete(w.tabs)
	testing.expect(t, !tab_drag_carry_paintable(&w), "window with no tabs is not paintable")

	tab_new_bare(app, &w, url = "https://example.com/")
	testing.expect(t, tab_drag_carry_paintable(&w), "open window with ui, tabs, and non-zero size is paintable")

	w.closing = true
	testing.expect(t, !tab_drag_carry_paintable(&w), "closing window is skipped")
	w.closing = false

	w.minimized = true
	testing.expect(t, !tab_drag_carry_paintable(&w), "minimized window is skipped")
	w.minimized = false

	pw.size = {}
	testing.expect(t, !tab_drag_carry_paintable(&w), "zero-size window is skipped")
	pw.size = {800, 600}

	w.ui = nil
	testing.expect(t, !tab_drag_carry_paintable(&w), "window without ui state is skipped")

	// carry.frame handles nil user, inactive drag, missing window ids, and unpaintable windows safely.
	tab_drag_carry_frame(nil)
	tab_drag_carry_frame(app)
	app.windows = make([dynamic]^Browser_Window)
	append(&app.windows, &w)
	defer {
		app.active = nil
		app.front = nil
		delete(app.windows)
		app.windows = nil
	}
	app.active = &w
	app.tab_drag = {active = true, tab = w.tabs[0].id, window = 9999, source = w.id}
	tab_drag_carry_frame(app)
	testing.expect(t, app.active == &w, "active window stays intact when carried window is missing or unpaintable")
	tab_drag_end(app)
	testing.expect(t, !app.tab_drag.active)
}

// Re-attaching a carried detached window onto the source window's tab bar via tab_drop_sync updates drop
// feedback, moves the tab back, marks the empty carried window closing, and clears state cleanly.
@(test)
wayland_carry_drop_sync_reattach_and_leave :: proc(t: ^testing.T) {
	app := test_app(t)
	pw_src := platform.Window{size = {800, 600}}
	pw_made := platform.Window{size = {800, 600}}
	src := Browser_Window{id = 41, win = &pw_src, zone = row_zone(2)}
	made := Browser_Window{id = 42, win = &pw_made, zone = row_zone(1)}
	defer {
		delete(src.tabs)
		delete(made.tabs)
	}
	tab_new_bare(app, &src, url = "https://one.example/")
	tab_new_bare(app, &src, url = "https://two.example/")
	carried_tab := tab_new_bare(app, &made, url = "https://three.example/")

	app.windows = make([dynamic]^Browser_Window)
	append(&app.windows, &src, &made)
	app.active = &src
	app.front = &src
	defer {
		app.active = nil
		app.front = nil
		delete(app.windows)
		app.windows = nil
	}

	app.tab_drag = {active = true, tab = carried_tab.id, window = made.id, source = src.id}

	// Hover over src's tab strip: accepts Move and arms drop ghost.
	eff := tab_drop_sync(app, &pw_src, {kind = .Drop_Enter, pos = {120, 10}})
	testing.expect_value(t, eff, Maybe(platform.Drop_Effect)(.Move))
	testing.expect(t, src.dropping && src.drop.index == 0)

	// Move off tab strip: refuses and clears drop ghost.
	eff = tab_drop_sync(app, &pw_src, {kind = .Drop_Over, pos = {120, 200}})
	testing.expect(t, eff == nil && !src.dropping)

	// Re-enter then Drop_Leave: clears drop ghost.
	_ = tab_drop_sync(app, &pw_src, {kind = .Drop_Over, pos = {280, 10}})
	testing.expect(t, src.dropping && src.drop.index == 2)
	eff = tab_drop_sync(app, &pw_src, {kind = .Drop_Leave, pos = {280, 10}})
	testing.expect(t, eff == nil && !src.dropping)

	// Drop on src's tab strip: re-attaches tab to src and marks carried window closing.
	eff = tab_drop_sync(app, &pw_src, {kind = .Drop, pos = {180, 10}})
	testing.expect_value(t, eff, Maybe(platform.Drop_Effect)(.Move))
	testing.expect(t, !src.dropping)
	testing.expect_value(t, len(src.tabs), 3)
	testing.expect(t, src.tabs[1] == carried_tab, "carried tab inserted at slot 1")
	testing.expect_value(t, len(made.tabs), 0)
	testing.expect(t, made.closing, "empty carried window closes after re-attach")
	testing.expect(t, app.front == &src)

	// tab_drag_end drops stray Tear_Off actions while keeping unrelated queued actions intact.
	defer {
		for a in app.chrome_frames.actions { delete(a.text) }
		delete(app.chrome_frames.actions)
		app.chrome_frames.actions = nil
	}
	append(&app.chrome_frames.actions,
		Shell_Action{kind = .Tear_Off, tab = carried_tab.id},
		Shell_Action{kind = .Reload, tab = carried_tab.id, text = strings.clone("keep")},
	)
	tab_drag_end(app)
	testing.expect(t, !app.tab_drag.active)
	testing.expect_value(t, len(app.chrome_frames.actions), 1)
	testing.expect_value(t, app.chrome_frames.actions[0].kind, Shell_Action_Kind.Reload)
}

// Post-drag teardown (tab_drag_system_finish) and cross-window queued drops for carried, single-tab, and fallback drags.
@(test)
wayland_carry_teardown_single_tab_and_fallback :: proc(t: ^testing.T) {
	app := test_app(t)
	pw_src := platform.Window{size = {800, 600}}
	pw_made := platform.Window{size = {800, 600}}
	pw_other := platform.Window{size = {800, 600}}
	src := Browser_Window{id = 51, win = &pw_src, zone = row_zone(1)}
	made := Browser_Window{id = 52, win = &pw_made, zone = row_zone(1)}
	other := Browser_Window{id = 53, win = &pw_other, zone = row_zone(1)}
	defer {
		delete(src.tabs)
		delete(made.tabs)
		delete(other.tabs)
	}
	t_src := tab_new_bare(app, &src, url = "https://src.example/")
	t_made := tab_new_bare(app, &made, url = "https://made.example/")
	tab_new_bare(app, &other, url = "https://other.example/")

	app.windows = make([dynamic]^Browser_Window)
	append(&app.windows, &src, &made, &other)
	app.active = &src
	app.front = &src
	defer {
		app.active = nil
		app.front = nil
		delete(app.windows)
		app.windows = nil
	}

	// 1. Multi-tab carried window dropped on desktop / cancelled -> focuses carried window, no extra detach.
	tab_drag_system_finish(app, t_made.id, made.id, nil, true)
	testing.expect(t, app.front == &made, "cancelled/desktop drop focuses carried window")
	testing.expect_value(t, len(app.windows), 3)

	// 2. Multi-tab carried window when drag_start failed (ok = false) -> focuses carried window, no double detach.
	app.front = &src
	tab_drag_system_finish(app, t_made.id, made.id, nil, false)
	testing.expect(t, app.front == &made)

	// 3. Multi-tab carried window taken by another window (effect = .Move) -> does not steal focus back to made.
	app.front = &other
	tab_drag_system_finish(app, t_made.id, made.id, .Move, true)
	testing.expect(t, app.front == &other, "taken drop leaves focus on target window")

	// 4. Carried window closed mid-drag (unknown made_id) -> no UAF, focus unchanged.
	app.front = &src
	tab_drag_system_finish(app, t_made.id, 99999, nil, true)
	testing.expect(t, app.front == &src)

	// 5. Single-tab self-carry cancelled/dropped on desktop -> never calls tab_detach.
	app.front = &src
	tab_drag_system_finish(app, t_src.id, 0, nil, true)
	testing.expect_value(t, len(app.windows), 3)
	testing.expect_value(t, len(src.tabs), 1)

	// 6. End-to-end fallback tab_drag_system via offscreen window + drag_script:
	// drag_carry_supported is false on offscreen; scripted drop on src's tab bar reorders cleanly with 0 leaks.
	off := platform.open_window_offscreen("tab_drag_script", {800, 600})
	if testing.expect(t, off != nil, "offscreen window opens") {
		defer platform.destroy_window(off)
		testing.expect(t, !platform.drag_carry_supported(off), "offscreen uses fallback path")
		w_off := Browser_Window{id = 54, win = off, zone = row_zone(2)}
		defer delete(w_off.tabs)
		ta := tab_new_bare(app, &w_off, url = "https://a.example/")
		tb := tab_new_bare(app, &w_off, url = "https://b.example/")
		append(&app.windows, &w_off)
		app.active = &w_off
		platform.drag_script(off, []platform.Drag_Step{{pos = {280, 10}}, {pos = {280, 10}}})
		tab_drag_system(app, &w_off, ta)
		testing.expect(t, !app.tab_drag.active, "tab_drag resets after scripted system drag")
		testing.expect(t, w_off.tabs[0] == tb && w_off.tabs[1] == ta, "scripted drop on own bar reorders tab")
		pop(&app.windows)
		app.active = &src
	}

	// 7. Cross-window queued drop of a carried window onto another window's page area vs tab bar:
	// On page area: carried window stays open and takes focus (no spurious tab_detach).
	// On tab bar: carried tab re-attaches into target window and empty carried window closes.
	off_other := platform.open_window_offscreen("tab_drag_other", {800, 600})
	if testing.expect(t, off_other != nil, "offscreen target window opens") {
		defer platform.destroy_window(off_other)
		other.win = off_other
		defer other.win = &pw_other
		app.active = &other
		app.front = &other
		t0 := time.Tick{_nsec = 1000}
		t1 := time.Tick{_nsec = 2000}
		app.tab_drop_span = {t0, t1}

		// Drop carried tab onto other's page area (outside tab bar).
		d1: platform.Drag_Data
		defer delete(d1.custom)
		append(&d1.custom, platform.Drag_Entry{TAB_MIME, tab_drag_payload(t_made.id)})
		testing.expect(t, platform.drop_inject(off_other, .Drop_Enter, {340, 200}, &d1))
		testing.expect(t, platform.drop_inject(off_other, .Drop, {340, 200}))
		evs1 := platform.poll_events(off_other, false)
		if testing.expect(t, len(evs1) > 0) {
			ev1 := evs1[len(evs1) - 1]
			ev1.stamp = time.Tick{_nsec = 1500}
			testing.expect(t, tab_drop_queued(app, ev1))
			testing.expect(t, !made.closing && len(made.tabs) == 1 && app.front == &made, "drop on other page keeps and focuses carried window")
		}

		// Drop carried tab onto other's tab bar.
		d2: platform.Drag_Data
		defer delete(d2.custom)
		append(&d2.custom, platform.Drag_Entry{TAB_MIME, tab_drag_payload(t_made.id)})
		testing.expect(t, platform.drop_inject(off_other, .Drop_Enter, {120, 10}, &d2))
		testing.expect(t, platform.drop_inject(off_other, .Drop, {120, 10}))
		evs2 := platform.poll_events(off_other, false)
		if testing.expect(t, len(evs2) > 0) {
			ev2 := evs2[len(evs2) - 1]
			ev2.stamp = time.Tick{_nsec = 1500}
			testing.expect(t, tab_drop_queued(app, ev2))
			testing.expect(t, made.closing && len(made.tabs) == 0, "empty carried window closes on cross-window tab bar drop")
			testing.expect(t, len(other.tabs) == 2 && other.tabs[0] == t_made && app.front == &other, "carried tab re-attached into other window")
		}
	}
}
