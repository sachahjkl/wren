package browser

import "core:strings"
import "core:testing"

@(test)
about_about_lists_the_builtin_pages :: proc(t: ^testing.T) {
	html := about_pages_html()
	for u in ([]string{HOME_URL, DEMOS_URL, "about:config", ABOUT_URL, "about:blank"}) {
		testing.expectf(t, strings.contains(html, strings.concatenate({`href="`, u, `"`}, context.temp_allocator)), "%s is listed", u)
	}
}
