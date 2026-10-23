package browser

import "core:testing"
import "wb:base"
import "wb:fetch"

@(test)
console_lines_carry_their_level :: proc(t: ^testing.T) {
	l, text := con_split("error: boom")
	testing.expect_value(t, l, Con_Level.Error)
	testing.expect_value(t, text, "boom")
	l, text = con_split("warn: careful")
	testing.expect_value(t, l, Con_Level.Warn)
	testing.expect_value(t, text, "careful")
	l, text = con_split("> 1 + 1")
	testing.expect_value(t, l, Con_Level.Log)
	testing.expect_value(t, text, "> 1 + 1")
}

@(test)
console_line_numbers_do_not_move_when_old_lines_go :: proc(t: ^testing.T) {
	tab := Tab{console_added = 10}
	append(&tab.console, "a", "b", "c")   // lines 7, 8, 9
	defer delete(tab.console)
	testing.expect_value(t, con_abs(&tab, 0), 7)
	testing.expect_value(t, con_abs(&tab, 2), 9)
}

@(test)
labels_never_hold_an_id_marker_or_a_line_break :: proc(t: ^testing.T) {
	testing.expect(t, !contains(dev_line("a###b"), "###"), "### is broken")
	testing.expect_value(t, dev_line("a\nb"), "a \u00b6 b")
	testing.expect_value(t, dev_line("a\r\nb\tc"), "a \u00b6 b  c")
	testing.expect_value(t, dev_line("abcdef", 3), "abc\u2026")
}

@(private = "file")
contains :: proc(s, sub: string) -> bool {
	for i in 0 ..= len(s) - len(sub) { if s[i:i + len(sub)] == sub { return true } }
	return false
}

// The loader's observer turns requests into the rows of the tab whose scope they run in; a new navigation starts the
// list over; an answer and its end update the row.
@(test)
requests_are_logged_in_the_tab_they_run_in :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	tab := new(Tab)
	tab.scope = base.scope_make("tab")
	append(&app.tabs, tab)
	defer { delete(app.tabs); net_log_destroy(&tab.net); base.scope_close(tab.scope); free(tab); net_destroy_owner() }

	nav1 := base.scope_make("navigation", tab.scope)
	page1 := base.scope_make("page", nav1)
	net_observe(app, &fetch.Observed{kind = .Started, id = 1, scope = nav1, method = "GET", url = "https://x.test/", destination = .Document})
	net_observe(app, &fetch.Observed{kind = .Started, id = 2, scope = page1, method = "POST", url = "https://x.test/api"})
	net_observe(app, &fetch.Observed{kind = .Response, id = 1, url = "https://x.test/index", status = 200, mime = "text/html", headers = "Content-Length: 1234\r\nServer: t", status_text = "OK"})
	net_observe(app, &fetch.Observed{kind = .Done, id = 1, bytes = 1234})
	net_observe(app, &fetch.Observed{kind = .Failed, id = 2, error = .Transport, detail = "connection reset"})
	testing.expect_value(t, len(tab.net.entries), 2)
	e := tab.net.entries[0]
	testing.expect_value(t, e.url, "https://x.test/index")   // the URL after redirects
	testing.expect_value(t, e.status, 200)
	testing.expect_value(t, e.status_text, "OK")
	testing.expect_value(t, e.bytes, 1234)
	testing.expect_value(t, e.transfer, 1234)
	testing.expect(t, e.ms >= 0, "it ended")
	testing.expect_value(t, e.type, Net_Type.Doc)
	testing.expect(t, tab.net.entries[1].failed && tab.net.entries[1].error == "connection reset", "the failure is kept")
	testing.expect_value(t, tab.net.bytes, i64(1234))

	// a request of no tab is not logged
	other := base.scope_make("elsewhere")
	net_observe(app, &fetch.Observed{kind = .Started, id = 3, scope = other, method = "GET", url = "https://y.test/"})
	testing.expect_value(t, len(tab.net.entries), 2)
	base.scope_close(other)

	// a new navigation: the list starts over
	base.scope_close(nav1)
	nav2 := base.scope_make("navigation", tab.scope)
	net_observe(app, &fetch.Observed{kind = .Started, id = 4, scope = nav2, method = "GET", url = "https://x.test/next"})
	testing.expect_value(t, len(tab.net.entries), 1)
	base.scope_close(nav2)
}
