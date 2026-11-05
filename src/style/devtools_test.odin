package style

import "core:testing"

// The developer tools keep a rule between two frames, and a script may have taken its sheet away by then.
@(test)
a_rule_of_a_sheet_that_went_is_left_alone :: proc(t: ^testing.T) {
	ss := settings_default()
	defer settings_destroy(&ss)
	e := engine_make(ss)
	defer engine_destroy(e)
	s := engine_add_sheet(e, "@media all { p { color: red } }", 0, "", "about:test")
	rule := s.sheet.rules[0].rules[0]
	testing.expect(t, dev_rule_stands(e, s, rule))
	engine_remove_sheet(e, s)
	testing.expect(t, !dev_rule_stands(e, s, rule))
	e.dirty = false
	dev_set_rule_decls(e, s, rule, {{name = "color", value = "blue"}})
	testing.expect(t, !e.dirty, "nothing was changed")
}
