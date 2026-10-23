package i18n

import "core:testing"

@(test)
english_is_the_text_itself :: proc(t: ^testing.T) {
	testing.expect_value(t, tr("Open in a new tab"), "Open in a new tab")
	testing.expect_value(t, tr(""), "")
	testing.expect_value(t, tr("tab strip", "Close"), "Close")
}

@(test)
plural_follows_the_count :: proc(t: ^testing.T) {
	testing.expect_value(t, tr(0, "%d request", "%d requests"), "%d requests")
	testing.expect_value(t, tr(1, "%d request", "%d requests"), "%d request")
	testing.expect_value(t, tr(2, "%d request", "%d requests"), "%d requests")
	testing.expect_value(t, tr(-1, "%d request", "%d requests"), "%d requests")
	n := 1
	testing.expect_value(t, tr(n, "%d tab", "%d tabs"), "%d tab")
}

// English costs nothing: the text comes back as the very same bytes (no copy, no allocation), which is what keeps a call in
// an interface drawn every frame free.
@(test)
english_returns_the_same_bytes :: proc(t: ^testing.T) {
	text := "Open in a new tab"
	testing.expect(t, raw_data(tr(text)) == raw_data(text), "tr copied the text")
	testing.expect(t, raw_data(tr("menu", text)) == raw_data(text), "tr with a context copied the text")
	testing.expect(t, raw_data(tr(1, text, "other")) == raw_data(text), "tr with a count copied the text")
}
