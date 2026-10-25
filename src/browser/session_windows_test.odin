package browser

import "core:strings"
import "core:testing"

@(private = "file")
win_tab :: proc(url: string) -> Session_Tab { return {url = url} }

@(test)
session_of_one_window_is_the_old_file :: proc(t: ^testing.T) {
	tabs := []Session_Tab{win_tab("https://a.test/"), win_tab("https://b.test/")}
	old := session_serialize_tabs(tabs, 1, 4096, 4096)
	one := session_serialize_windows([]Session_Window{{tabs = tabs, current = 1, has_rect = true, rect = {1, 2, 3, 4}}}, 4096, 4096)
	testing.expect_value(t, one, old)   // (no rectangle, no window line: version 2 as it always was)
	testing.expect(t, strings.has_prefix(old, SESSION_HEADER))
	ws, ok := session_parse_windows(old, 100, 4096)
	testing.expect(t, ok)
	testing.expect_value(t, len(ws), 1)
	testing.expect(t, !ws[0].has_rect)
	testing.expect_value(t, len(ws[0].tabs), 2)
	testing.expect_value(t, ws[0].current, 1)
}

@(test)
session_of_several_windows_round_trips :: proc(t: ^testing.T) {
	ws := []Session_Window{
		{has_rect = true, rect = {10, 20, 1280, 800}, tabs = {win_tab("https://a.test/"), win_tab("https://b.test/")}, current = 1},
		{has_rect = true, rect = {-1300, 40, 900, 700}, maximized = true, tabs = {win_tab("https://c.test/")}, current = 0},
		{tabs = {win_tab("about:config")}},
	}
	text := session_serialize_windows(ws, 4096, 4096)
	testing.expect(t, strings.has_prefix(text, SESSION_HEADER_V3))
	got, ok := session_parse_windows(text, 100, 4096)
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 3)
	testing.expect(t, got[0].has_rect && got[0].rect == [4]int{10, 20, 1280, 800} && !got[0].maximized)
	testing.expect_value(t, got[0].current, 1)
	testing.expect_value(t, len(got[0].tabs), 2)
	testing.expect(t, got[1].has_rect && got[1].rect == [4]int{-1300, 40, 900, 700} && got[1].maximized)   // (a window on a monitor at the left)
	testing.expect_value(t, got[1].tabs[0].url, "https://c.test/")
	testing.expect(t, !got[2].has_rect)   // none written: none read
	testing.expect_value(t, got[2].tabs[0].url, "about:config")
	// the tab reader sees them all, one after the other, with the first window's current tab
	tabs, cur, tok := session_parse_tabs(text, 100, 4096)
	testing.expect(t, tok)
	testing.expect_value(t, len(tabs), 4)
	testing.expect_value(t, cur, 1)
}

@(test)
session_caps_windows_and_tabs :: proc(t: ^testing.T) {
	ws := []Session_Window{
		{tabs = {win_tab("https://a.test/"), win_tab("https://b.test/")}},
		{tabs = {win_tab("https://c.test/")}},
		{tabs = {win_tab("https://d.test/")}},
	}
	text := session_serialize_windows(ws, 4096, 4096)
	got, _ := session_parse_windows(text, 100, 4096, max_windows = 2)
	testing.expect_value(t, len(got), 2)
	got, _ = session_parse_windows(text, 3, 4096)   // three tabs in all: the fourth is dropped
	n := 0
	for w in got { n += len(w.tabs) }
	testing.expect_value(t, n, 3)
}

@(test)
session_windows_reader_is_forgiving :: proc(t: ^testing.T) {
	// a rectangle that is no rectangle is no rectangle; a window line with garbage is still a window
	text := "wren-session 3\nwindow x y z\ncurrent 0\ntab https://a.test/\nwindow 0 0 -5 10 0\ntab https://b.test/\nwindow 1 2 300 200 1\ncurrent 9\ntab https://c.test/\n"
	got, ok := session_parse_windows(text, 100, 4096)
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 3)
	testing.expect(t, !got[0].has_rect && !got[1].has_rect)
	testing.expect(t, got[2].has_rect && got[2].maximized)
	testing.expect_value(t, got[2].current, 0)   // 9 is past the last tab: clamped
	// not a session file
	_, ok = session_parse_windows("hello\nwindow 1 2 3 4 0\n", 100, 4096)
	testing.expect(t, !ok)
	// an empty window stays a window (it restores one blank tab)
	got, ok = session_parse_windows("wren-session 3\nwindow 0 0 100 100 0\ncurrent 0\nwindow 5 5 200 200 0\ncurrent 0\ntab https://z.test/\n", 100, 4096)
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, len(got[0].tabs), 0)
}
