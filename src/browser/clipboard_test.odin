package browser

import "core:strings"
import "core:testing"

// (the clipboard's formats, "HTML Format" and PNG included, are the toolkit's: gui_toolkit tests/clipboard)

@(test)
source_markup_escapes_and_colors :: proc(t: ^testing.T) {
	m := source_markup(`<!doctype html><!-- c --><a href="x?a=1&b">t</a><script>if (a < b) {}</script>`, true, false)
	testing.expect(t, strings.contains(m, `<span class="t">&lt;a</span> <span class="n">href</span>=<span class="v">"x?a=1&amp;b"</span>`), m)
	testing.expect(t, strings.contains(m, `<span class="c">&lt;!-- c --&gt;</span>`), "comment")
	testing.expect(t, strings.contains(m, "if (a &lt; b) {}"), "script text is escaped, never markup")
	testing.expect(t, !strings.contains(m, "<script>"), "no script element in the source page")
}
