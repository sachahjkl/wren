package style

import "core:math"
import "core:strings"
import "core:testing"
import "wb:css"
import "wb:dom"

// engine_reset_builtin_sheets applies pre-loaded user_stylesheet_css directly and never reads user_stylesheet from disk.
@(test)
user_stylesheet_applies_without_disk_read :: proc(t: ^testing.T) {
	s := settings_default()
	defer settings_destroy(&s)
	delete(s.user_stylesheet)
	s.user_stylesheet = strings.clone("/nonexistent/user_stylesheet_must_not_be_read.css")
	s.user_stylesheet_css = strings.clone("p { color: rgb(12, 34, 56); }")

	f := fixture_load(`<p id="x">hi</p>`, {set = &s})
	defer fixture_unload(f)

	x := dom.find_by_id(f.doc, "x")
	c := style_of(f.st, x).color
	want := css.Color{12.0 / 255.0, 34.0 / 255.0, 56.0 / 255.0, 1}
	for i in 0 ..< 4 { testing.expect(t, math.abs(c[i] - want[i]) < 0.01, "user_stylesheet_css applied") }

	// Updating user_stylesheet_css triggers engine_configure and updates computed styles.
	delete(s.user_stylesheet_css)
	s.user_stylesheet_css = strings.clone("p { color: rgb(78, 90, 12); }")
	testing.expect(t, engine_configure(f.eng, s), "changed user_stylesheet_css must reconfigure engine")
	testing.expect(t, !engine_configure(f.eng, s), "unchanged settings must be a no-op")

	st2 := compute_styles(f.eng, f.doc, {})
	defer styled_destroy(st2)
	c2 := style_of(st2, x).color
	want2 := css.Color{78.0 / 255.0, 90.0 / 255.0, 12.0 / 255.0, 1}
	for i in 0 ..< 4 { testing.expect(t, math.abs(c2[i] - want2[i]) < 0.01, "updated user_stylesheet_css applied") }
}
