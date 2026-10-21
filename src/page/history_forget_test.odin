package page

import "core:testing"

// Forgetting a branch removes it whole, never the current entry or one of its ancestors.
@(test)
session_forget_branch :: proc(t: ^testing.T) {
	sh: Session_History
	defer session_destroy(&sh)
	session_push(&sh, "a", 0)
	session_push(&sh, "b", 0)
	session_push(&sh, "c", 0)
	session_go(&sh, -1)
	session_push(&sh, "d", 0)   // branch from b: a b d current, c off the path
	session_go(&sh, -2)          // a current, b d ahead
	a := session_current(&sh)
	b := session_find(&sh, 2)
	testing.expect(t, a != nil && b != nil)
	serial := sh.serial
	testing.expect_value(t, len(session_forget(&sh, a)), 0)   // the current entry stays
	ids := session_forget(&sh, b)
	testing.expect_value(t, len(ids), 3)   // b, c, d
	testing.expect_value(t, sh.count, 1)
	testing.expect(t, sh.serial != serial)
	testing.expect_value(t, session_length(&sh), 1)
	testing.expect(t, session_find(&sh, 4) == nil)
	session_push(&sh, "e", 0)
	e := session_current(&sh)
	testing.expect_value(t, len(session_forget(&sh, sh.root)), 0)
	testing.expect_value(t, len(session_forget(&sh, a)), 0)   // an ancestor of the current entry stays
	testing.expect(t, e != nil && e.parent == a)
}
