package browser

import "core:os"
import "core:strings"
import "core:testing"

@(private = "file") WRITE_DEMOS_INDEX :: #config(WREN_WRITE_DEMOS_INDEX, false)

// examples\site\index.html is made from the DEMOS table (demos_index.odin). Run from the repository root, as the test
// suite does. After a change to the table:
//   odin test src/browser -collection:toolkit=ext/gui_toolkit -collection:wb=src -define:WREN_WRITE_DEMOS_INDEX=true -define:ODIN_TEST_NAMES=browser.demos_index_is_up_to_date
@(test)
demos_index_is_up_to_date :: proc(t: ^testing.T) {
	want := demos_index_html()
	when WRITE_DEMOS_INDEX {
		testing.expect(t, os.write_entire_file(DEMOS_INDEX_PATH, transmute([]byte)want) == nil, "cannot write " + DEMOS_INDEX_PATH)
	}
	have, err := os.read_entire_file(DEMOS_INDEX_PATH, context.temp_allocator)
	testing.expectf(t, err == nil, "%s is missing", DEMOS_INDEX_PATH)
	testing.expectf(t, string(have) == want, "%s no longer matches the DEMOS table of demos.odin: write it again with -define:WREN_WRITE_DEMOS_INDEX=true (see demos_index_test.odin)", DEMOS_INDEX_PATH)
}

@(test)
demos_index_links :: proc(t: ^testing.T) {
	html := demos_index_html()
	for d in DEMOS {
		href := demos_index_href(d)
		switch {
		case d.path == "" || d.perf: testing.expect_value(t, href, "")
		case strings.has_prefix(d.path, "/"): testing.expectf(t, href == strings.concatenate({"http://127.0.0.1:8765", d.path}, context.temp_allocator), "%s -> %s", d.path, href)
		case d.server: testing.expectf(t, href == strings.concatenate({"http://127.0.0.1:8765/site/", d.path}, context.temp_allocator), "%s -> %s", d.path, href)
		case: testing.expectf(t, href == d.path && !strings.contains(href, ":"), "%s is relative", d.path)
		}
		if href != "" { testing.expectf(t, strings.contains(html, strings.concatenate({`href="`, href, `"`}, context.temp_allocator)), "%s is linked", href) }
	}
	testing.expect(t, strings.contains(html, `href="counter.html"`), "the counter page is a demo like the others")
	testing.expect(t, strings.contains(html, "color-scheme"), "light and dark")
	testing.expect(t, strings.contains(html, `class="badge srv"`), "the test server badge")
	testing.expect(t, !strings.contains(html, "<script"), "no module: the index is a plain page")
}
