package browser

import "core:testing"

// The address bar in the middle of its row, at most its width; pushed aside by what is next to it when they leave it no
// room to be in the middle; narrower in a narrow row; never under nothing.
@(test)
address_bar_centred :: proc(t: ^testing.T) {
	expect_span :: proc(t: ^testing.T, row_w, lead, trail, max_w, before, width: f32, loc := #caller_location) {
		b, w := address_bar_span(row_w, lead, trail, max_w)
		testing.expect_value(t, b, before, loc = loc)
		testing.expect_value(t, w, width, loc = loc)
	}
	expect_span(t, 1000, 100, 150, 500, 150, 500)   // in the middle: 250 .. 750
	expect_span(t, 800, 100, 250, 400, 50, 400)     // the middle (200) would overlap what follows: as near as it lets it
	expect_span(t, 700, 100, 150, 500, 0, 450)      // narrow: all the room there is
	expect_span(t, 200, 100, 150, 500, 0, 0)        // narrower than its neighbours
	expect_span(t, 1000, 100, 150, 1e6, 0, 750)     // no limit: the whole room (as at full width)
}

// The toolbar in the title bar with a centred field: the field keeps its largest width, the gaps on either side take the
// rest (they drag the window), the field is in the middle of the window when its neighbours let it.
@(test)
titlebar_field_centred :: proc(t: ^testing.T) {
	test_app(t)
	want := [Titlebar_Part]f32{
		.Lead = 32, .Back = 29, .Forward = 29, .Reload = 29, .Gap_Before = 6, .Field = 140, .Chips = 0, .Gap_After = 6,
		.Shield = 35, .Menu = 32, .Drag = 42, .Buttons = 138,
	}
	l := titlebar_layout(1280, want, 42, field_max = 500)
	testing.expect_value(t, l.w[.Field], 500)
	testing.expect_value(t, l.x[.Field], 390)                  // (1280 - 500) / 2
	testing.expect_value(t, l.w[.Gap_Before], 271)
	testing.expect_value(t, l.w[.Gap_After], 6 + 1280 - 378 - 500 - 265)
	testing.expect_value(t, l.w[.Drag], 42)
	testing.expect_value(t, l.x[.Buttons] + l.w[.Buttons], 1280)
	// a wide field whose middle would be under the buttons on its left: as near the middle as they let it
	l = titlebar_layout(1280, want, 42, field_max = 880)
	testing.expect_value(t, l.w[.Gap_Before], 28)
	testing.expect_value(t, l.w[.Gap_After], 6)
	// narrow: as without a largest width, and the drag strip keeps its width (the shield goes first)
	l = titlebar_layout(500, want, 42, field_max = 500)
	testing.expect_value(t, l.w[.Field], 140 + 35 - 18)
	testing.expect_value(t, l.w[.Drag], 42)
	testing.expect(t, .Shield not_in l.shown)
}
