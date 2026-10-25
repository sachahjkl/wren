package page

import "core:testing"

@(test)
test_io_margin_forms :: proc(t: ^testing.T) {
	sides, text, ok := parse_margin("10px 0")
	testing.expect(t, ok)
	testing.expect_value(t, text, "10px 0px 10px 0px")
	testing.expect_value(t, sides[1], Io_Length{0, false})
	delete(text)

	_, text2, ok2 := parse_margin("  5%  -2.5PX 1px ")
	testing.expect(t, ok2)
	testing.expect_value(t, text2, "5% -2.5px 1px -2.5px")
	delete(text2)

	_, text3, ok3 := parse_margin("-0px")
	testing.expect(t, ok3)
	testing.expect_value(t, text3, "0px 0px 0px 0px")
	delete(text3)
}

@(test)
test_io_margin_refused :: proc(t: ^testing.T) {
	for bad in ([]string{"", "  ", "1em", "10", "1px 2px 3px 4px 5px", "px", "+3px", "nan", "inf", "1e", "10 px", "calc(1px)"}) {
		_, text, ok := parse_margin(bad)
		testing.expectf(t, !ok, "%q must be refused", bad)
		delete(text)
	}
}

@(test)
test_io_geometry :: proc(t: ^testing.T) {
	r := io_grow(Io_Rect{100, 50, 300, 250}, [4]Io_Length{{10, false}, {50, true}, {-10, false}, {0, false}})   // top right bottom left
	testing.expect_value(t, r, Io_Rect{100, 40, 400, 240})
	a := io_intersect(Io_Rect{0, 0, 10, 10}, Io_Rect{10, 5, 20, 20})
	testing.expect(t, a.x1 >= a.x0 && a.y1 >= a.y0)   // touching edges still intersect
	b := io_intersect(Io_Rect{0, 0, 10, 10}, Io_Rect{11, 0, 20, 10})
	testing.expect(t, b.x1 < b.x0)
	th := []f64{0, 0.5, 1}
	testing.expect_value(t, io_threshold_index(th, 0), 1)
	testing.expect_value(t, io_threshold_index(th, 0.49), 1)
	testing.expect_value(t, io_threshold_index(th, 0.5), 2)
	testing.expect_value(t, io_threshold_index(th, 1), 3)
}
