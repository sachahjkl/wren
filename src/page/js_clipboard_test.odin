package page

import "core:testing"

@(test)
clipboard_policy :: proc(t: ^testing.T) {
	V :: Clipboard_Verdict
	// write: focus or a gesture
	testing.expect_value(t, clipboard_verdict(true, true, true, true, false), V.Allowed)
	testing.expect_value(t, clipboard_verdict(true, true, true, false, true), V.Allowed)
	testing.expect_value(t, clipboard_verdict(true, true, true, false, false), V.Not_Focused)
	// read: focus and a gesture
	testing.expect_value(t, clipboard_verdict(false, true, true, true, true), V.Allowed)
	testing.expect_value(t, clipboard_verdict(false, true, true, true, false), V.No_Gesture)
	testing.expect_value(t, clipboard_verdict(false, true, true, false, true), V.Not_Focused)
	// turned off, and no window (tools): nothing to ask for
	testing.expect_value(t, clipboard_verdict(true, false, true, true, true), V.Disabled)
	testing.expect_value(t, clipboard_verdict(false, false, false, true, true), V.Disabled)
	testing.expect_value(t, clipboard_verdict(false, true, false, false, false), V.Allowed)
}
