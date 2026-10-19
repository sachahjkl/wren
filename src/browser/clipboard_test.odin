package browser

import "core:strconv"
import "core:strings"
import "core:testing"

@(test)
cf_html_offsets_point_at_the_fragment :: proc(t: ^testing.T) {
	frag := "<b>caf\u00e9</b> & co"
	s := cf_html(frag, "https://example.test/page")
	field :: proc(s, name: string) -> int {
		i := strings.index(s, name)
		if i < 0 { return -1 }
		v, _ := strconv.parse_int(s[i + len(name):i + len(name) + 10])
		return v
	}
	sf, ef := field(s, "StartFragment:"), field(s, "EndFragment:")
	sh, eh := field(s, "StartHTML:"), field(s, "EndHTML:")
	testing.expect_value(t, s[sf:ef], frag)
	testing.expect(t, strings.has_prefix(s[sh:], "<html>"), "StartHTML is the markup")
	testing.expect_value(t, eh, len(s))
	testing.expect(t, strings.contains(s, "SourceURL:https://example.test/page\r\n"), "source URL")
}

@(test)
png_of_pixels :: proc(t: ^testing.T) {
	px := [16]u8{255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 255, 255, 255, 255}
	png := encode_png(px[:], 2, 2, 8)
	testing.expect(t, len(png) > 8 && string(png[1:4]) == "PNG", "a PNG file")
}

@(test)
search_urls :: proc(t: ^testing.T) {
	s := Interaction_Settings{search_engine = "custom", search_custom = "https://s.test/?q=%s&x=1"}
	testing.expect_value(t, search_url(&s, "caf\u00e9 & tea"), "https://s.test/?q=caf%C3%A9+%26+tea&x=1")
	s.search_engine = "duckduckgo"
	testing.expect_value(t, search_url(&s, "a b"), "https://duckduckgo.com/?q=a+b")
}

@(test)
source_markup_escapes_and_colors :: proc(t: ^testing.T) {
	m := source_markup(`<!doctype html><!-- c --><a href="x?a=1&b">t</a><script>if (a < b) {}</script>`, true, false)
	testing.expect(t, strings.contains(m, `<span class="t">&lt;a</span> <span class="n">href</span>=<span class="v">"x?a=1&amp;b"</span>`), m)
	testing.expect(t, strings.contains(m, `<span class="c">&lt;!-- c --&gt;</span>`), "comment")
	testing.expect(t, strings.contains(m, "if (a &lt; b) {}"), "script text is escaped, never markup")
	testing.expect(t, !strings.contains(m, "<script>"), "no script element in the source page")
}
