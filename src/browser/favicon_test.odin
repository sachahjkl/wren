package browser

import "core:testing"

// document.title: whitespace stripped and collapsed; a page without one shows its address like Chrome.
@(test)
tab_titles :: proc(t: ^testing.T) {
	testing.expect_value(t, collapse_title("  Hello \n\t  world  "), "Hello world")
	testing.expect_value(t, collapse_title("\n \t"), "")
	testing.expect_value(t, collapse_title("été  à   Paris"), "été à Paris")

	testing.expect_value(t, default_tab_title("https://example.com/"), "example.com")
	testing.expect_value(t, default_tab_title("https://example.com/a/b?q=1#top"), "example.com/a/b?q=1")
	testing.expect_value(t, default_tab_title("http://127.0.0.1:8765/status/404"), "127.0.0.1:8765/status/404")
	testing.expect_value(t, default_tab_title("file:///C:/dir/page%20one.html"), "page one.html")
	testing.expect_value(t, default_tab_title("file:///C:/dir/sub/"), "sub/")
	testing.expect_value(t, default_tab_title("file:///C:/"), "C:/")
	testing.expect_value(t, default_tab_title("about:blank"), "about:blank")
	testing.expect_value(t, default_tab_title("view-source:https://example.com/"), "view-source:https://example.com/")
}

// rel="icon" in any token list, any case.
@(test)
icon_rel_tokens :: proc(t: ^testing.T) {
	testing.expect(t, rel_is_icon("icon"))
	testing.expect(t, rel_is_icon("shortcut icon"))
	testing.expect(t, rel_is_icon("  ICON  "))
	testing.expect(t, !rel_is_icon("apple-touch-icon"))
	testing.expect(t, !rel_is_icon("stylesheet"))
	testing.expect(t, !rel_is_icon(""))
}

// The icon whose size fits the tab best; scalable first; links without sizes after those that fit, the last one.
@(test)
icon_choice :: proc(t: ^testing.T) {
	testing.expect_value(t, pick_icon(nil, 32), -1)
	testing.expect_value(t, pick_icon({{href = "a.ico"}}, 32), 0)
	testing.expect_value(t, pick_icon({{href = "a.ico"}, {href = "b.ico"}}, 32), 1)   // the last of equals
	links := []Icon_Link{{href = "16.png", sizes = "16x16"}, {href = "48.png", sizes = "48x48"}, {href = "32.png", sizes = "32x32"}, {href = "x.ico"}}
	testing.expect_value(t, pick_icon(links, 32), 2)
	testing.expect_value(t, pick_icon(links, 40), 1)
	testing.expect_value(t, pick_icon(links, 64), 3)   // nothing large enough: a link without sizes before a too small one
	testing.expect_value(t, pick_icon({{href = "16.png", sizes = "16x16"}, {href = "s.svg", sizes = "any"}}, 32), 1)
	testing.expect_value(t, pick_icon({{href = "", sizes = "32x32"}, {href = "b.png", sizes = "16X16 64x64"}}, 32), 1)
	testing.expect_value(t, pick_icon({{href = "a.png", sizes = "nonsense"}, {href = "b.png", sizes = "8x8"}}, 32), 0)
}
