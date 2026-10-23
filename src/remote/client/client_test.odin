package client

import "core:testing"

@(test)
options_split_into_flags_values_and_words :: proc(t: ^testing.T) {
	o, err := parse_options({"shot", "out.png", "--selector", "#a b", "--scale=0.5", "--tab", "--pref", "a.b=1", "--pref=c.d=2", "--", "--not-an-option"})
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(o.pos), 3)
	testing.expect_value(t, o.pos[0], "shot")
	testing.expect_value(t, o.pos[2], "--not-an-option")
	testing.expect_value(t, opt(&o, "selector"), "#a b")
	testing.expect_value(t, opt(&o, "scale"), "0.5")
	testing.expect(t, flag(&o, "tab"))
	testing.expect(t, !flag(&o, "window"))
	testing.expect_value(t, len(o.prefs), 2)
	testing.expect_value(t, o.prefs[1], "c.d=2")
	testing.expect_value(t, opt_int(&o, "timeout", 7), 7)
}

@(test)
options_report_what_is_wrong :: proc(t: ^testing.T) {
	_, err := parse_options({"nav", "--frobnicate"})
	testing.expect_value(t, err, "unknown option --frobnicate")
	_, err = parse_options({"nav", "--wait"})
	testing.expect_value(t, err, "--wait needs a value")
}

@(test)
sizes_and_points_parse :: proc(t: ^testing.T) {
	w, h, ok := parse_size("1280x800")
	testing.expect(t, ok && w == 1280 && h == 800)
	_, _, ok = parse_size("1280")
	testing.expect(t, !ok)
	_, _, ok = parse_size("0x5")
	testing.expect(t, !ok)
	v, good := parse_numbers("1, 2.5,3,4", 4)
	testing.expect(t, good && v[1] == 2.5 && v[3] == 4)
	_, good = parse_numbers("1,2", 4)
	testing.expect(t, !good)
	f, fok := parse_float("1.75")
	testing.expect(t, fok && f == 1.75)
	_, fok = parse_float("1.7.5")
	testing.expect(t, !fok)
}

@(test)
diff_counts_pixels_over_the_tolerance :: proc(t: ^testing.T) {
	a := []u8{0, 0, 0, 255, 10, 10, 10, 255, 200, 0, 0, 255, 5, 5, 5, 255}
	b := []u8{0, 0, 0, 255, 12, 10, 10, 255, 100, 0, 0, 255, 5, 5, 5, 255}
	n, worst, out := diff_pictures(a, b, 2, 2, 0)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, worst, 100)
	testing.expect_value(t, out[8], 255)   // a differing pixel is red
	testing.expect_value(t, out[9], 0)
	n, _, _ = diff_pictures(a, b, 2, 2, 5)   // 2 is within the tolerance, 100 is not
	testing.expect_value(t, n, 1)
	n, _, _ = diff_pictures(a, a, 2, 2, 0)
	testing.expect_value(t, n, 0)
}

@(test)
every_command_has_help :: proc(t: ^testing.T) {
	for e in HELP {
		testing.expect(t, e.usage != "" && e.text != "")
		testing.expect(t, len(e.usage) >= len(e.name) && e.usage[:len(e.name)] == e.name)
	}
}
