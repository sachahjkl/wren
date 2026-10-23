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
