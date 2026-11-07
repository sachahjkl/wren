package page

import "core:testing"

// Numbers of computed values: the shortest decimal that is the same f32 (20.7px reads back as written), at most six
// decimals, no exponent.
@(test)
css_numbers_serialize_short :: proc(t: ^testing.T) {
	testing.expect_value(t, css_num(20.7), "20.7")
	testing.expect_value(t, css_num(-0.2), "-0.2")
	testing.expect_value(t, css_num(1.0 / 3.0), "0.333333")
	testing.expect_value(t, css_num(12), "12")
	testing.expect_value(t, css_num(0.0000001), "0")
	testing.expect_value(t, css_num(-0.0000001), "0")
	testing.expect_value(t, css_px(150.25), "150.25px")
}
