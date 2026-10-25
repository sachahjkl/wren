package browser

import "core:testing"
import "toolkit:ui"

@(private = "file")
fake_tabs :: proc(urls: ..string) -> [dynamic]^Tab {
	l := make([dynamic]^Tab)
	for u in urls {
		t := new(Tab)
		t.url = u
		append(&l, t)
	}
	return l
}

@(private = "file")
free_tabs :: proc(l: ^[dynamic]^Tab) {
	for t in l { free(t) }
	delete(l^)
}

@(test)
tab_list_take_keeps_the_current_tab_right :: proc(t: ^testing.T) {
	l := fake_tabs("a", "b", "c", "d")
	defer free_tabs(&l)
	keep := l[:]
	_ = keep
	// before the current one: the current index follows its tab
	x := l[0]
	cur := tab_list_take(&l, 2, 0)
	testing.expect_value(t, cur, 1)
	testing.expect_value(t, l[cur].url, "c")
	free(x)
	// the current one: the tab that took its place, else the last
	x = l[1]
	cur = tab_list_take(&l, 1, 1)
	testing.expect_value(t, cur, 1)
	testing.expect_value(t, l[cur].url, "d")
	free(x)
	x = l[1]
	cur = tab_list_take(&l, 1, 1)
	testing.expect_value(t, cur, 0)
	free(x)
	// after it: unchanged; the only one: an empty list
	x = l[0]
	cur = tab_list_take(&l, 0, 0)
	testing.expect_value(t, cur, 0)
	testing.expect_value(t, len(l), 0)
	free(x)
	// an index out of the list changes nothing
	testing.expect_value(t, tab_list_take(&l, 3, 7), 3)
}

@(test)
tab_list_put_places_and_selects :: proc(t: ^testing.T) {
	l := fake_tabs("a", "b", "c")
	defer free_tabs(&l)
	n := new(Tab)
	n.url = "n"
	cur, at := tab_list_put(&l, 1, 1, n, true)
	testing.expect_value(t, cur, 1)
	testing.expect_value(t, at, 1)
	testing.expect_value(t, l[1].url, "n")
	testing.expect_value(t, len(l), 4)
	// not selected, put before the current one: the current tab keeps its tab
	m := new(Tab)
	m.url = "m"
	cur, at = tab_list_put(&l, 2, 0, m, false)
	testing.expect_value(t, cur, 3)
	testing.expect_value(t, l[cur].url, "b")
	// at the end (negative), and far past the end
	e := new(Tab)
	cur, at = tab_list_put(&l, 0, -1, e, false)
	testing.expect_value(t, at, len(l) - 1)
	testing.expect_value(t, cur, 0)
	f := new(Tab)
	_, at = tab_list_put(&l, 0, 99, f, false)
	testing.expect_value(t, at, len(l) - 1)
}

@(private = "file")
two_windows :: proc() -> (app: ^App, a, b: ^Browser_Window) {
	app = new(App)
	a, b = new(Browser_Window), new(Browser_Window)
	a.id, b.id = 1, 2
	append(&app.windows, a, b)
	return
}

@(private = "file")
free_windows :: proc(app: ^App, a, b: ^Browser_Window) {
	for w in ([]^Browser_Window{a, b}) {
		free_tabs(&w.ctx.tabs)
		ui.field_destroy(&w.ctx.address)
		free(w)
	}
	delete(app.windows)
	free(app)
}

@(test)
tab_moves_between_windows :: proc(t: ^testing.T) {
	app, a, b := two_windows()
	defer free_windows(app, a, b)
	a.ctx.tabs, a.ctx.current = fake_tabs("a1", "a2", "a3"), 1
	b.ctx.tabs, b.ctx.current = fake_tabs("b1"), 0
	moved := a.ctx.tabs[1]
	testing.expect(t, tab_move(app, moved, b, 0))
	testing.expect_value(t, len(a.ctx.tabs), 2)
	testing.expect_value(t, a.ctx.current, 1)
	testing.expect_value(t, a.ctx.tabs[a.ctx.current].url, "a3")   // the tab that took its place is shown
	testing.expect_value(t, ui.field_string(&a.ctx.address), "a3")
	testing.expect_value(t, len(b.ctx.tabs), 2)
	testing.expect(t, b.ctx.tabs[0] == moved)   // the same Tab: its page was not touched
	testing.expect_value(t, b.ctx.current, 0)   // and it is the one shown
	testing.expect_value(t, ui.field_string(&b.ctx.address), "a2")
	testing.expect(t, !a.closing && !b.closing)
	w, i := window_of_tab(app, moved)
	testing.expect(t, w == b && i == 0)
}

@(test)
the_window_that_loses_its_last_tab_closes :: proc(t: ^testing.T) {
	app, a, b := two_windows()
	defer free_windows(app, a, b)
	a.ctx.tabs, a.ctx.current = fake_tabs("only"), 0
	b.ctx.tabs, b.ctx.current = fake_tabs("b1", "b2"), 1
	testing.expect(t, tab_move(app, a.ctx.tabs[0], b))
	testing.expect(t, a.closing)
	testing.expect_value(t, len(a.ctx.tabs), 0)
	testing.expect_value(t, len(b.ctx.tabs), 3)
	testing.expect_value(t, b.ctx.current, 2)   // at the end, and shown
	// an unknown tab or window: nothing
	stray := new(Tab)
	defer free(stray)
	testing.expect(t, !tab_move(app, stray, b))
	testing.expect(t, !tab_move(app, b.ctx.tabs[0], nil))
}

@(test)
a_tab_moves_within_its_window :: proc(t: ^testing.T) {
	app, a, b := two_windows()
	defer free_windows(app, a, b)
	a.ctx.tabs, a.ctx.current = fake_tabs("1", "2", "3", "4"), 0
	b.ctx.tabs = fake_tabs("x")
	first := a.ctx.tabs[0]
	testing.expect(t, tab_move(app, first, a, 2))
	testing.expect_value(t, a.ctx.tabs[2].url, "1")
	testing.expect_value(t, a.ctx.current, 2)   // the current tab went with it
	testing.expect(t, tab_move(app, first, a))   // no place: the end
	testing.expect_value(t, a.ctx.tabs[3].url, "1")
}

@(test)
every_tab_of_every_window_is_listed_once :: proc(t: ^testing.T) {
	app, a, b := two_windows()
	defer free_windows(app, a, b)
	a.ctx.tabs = fake_tabs("a1", "a2")
	b.ctx.tabs = fake_tabs("b1")
	a.ctx.tabs[0].id, a.ctx.tabs[1].id, b.ctx.tabs[0].id = 1, 2, 3
	app.front = b
	all := tabs_all(app)
	testing.expect_value(t, len(all), 3)
	testing.expect_value(t, all[0].url, "b1")   // the front window's first
	testing.expect(t, tab_by_id(app, 2) == a.ctx.tabs[1])
	testing.expect(t, tab_by_id(app, 9) == nil)
}
