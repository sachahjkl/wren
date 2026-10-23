package i18n

import "core:testing"

@(test)
english_is_the_text_itself :: proc(t: ^testing.T) {
	testing.expect_value(t, tr("Open in a new tab"), "Open in a new tab")
	testing.expect_value(t, tr(""), "")
	testing.expect_value(t, trc("tab strip", "Close"), "Close")
}

@(test)
plural_follows_the_count :: proc(t: ^testing.T) {
	testing.expect_value(t, trn(0, "%d request", "%d requests"), "%d requests")
	testing.expect_value(t, trn(1, "%d request", "%d requests"), "%d request")
	testing.expect_value(t, trn(2, "%d request", "%d requests"), "%d requests")
	testing.expect_value(t, trn(-1, "%d request", "%d requests"), "%d requests")
}

// English costs nothing: the text comes back as the very same bytes (no copy, no allocation), which is what keeps a call in
// an interface drawn every frame free.
@(test)
english_returns_the_same_bytes :: proc(t: ^testing.T) {
	text := "Open in a new tab"
	testing.expect(t, raw_data(tr(text)) == raw_data(text), "tr copied the text")
	testing.expect(t, raw_data(trc("menu", text)) == raw_data(text), "trc copied the text")
	testing.expect(t, raw_data(trn(1, text, "other")) == raw_data(text), "trn copied the text")
}