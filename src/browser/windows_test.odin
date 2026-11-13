package browser

import "core:testing"
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
