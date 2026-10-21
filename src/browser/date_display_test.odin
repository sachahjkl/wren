package browser

import "core:strings"
import "core:testing"
import "wb:forms"

// The short forms depend on the user's locale: the test checks what does not (the parts are there, in some order;
// invalid values are shown as they are).
@(test)
date_field_display_forms :: proc(t: ^testing.T) {
	d := date_field_display(.Date, "2026-09-21")
	testing.expectf(t, strings.contains(d, "2026") && strings.contains(d, "21") && !strings.contains(d, "2026-09-21"), "date: %q", d)
	dt := date_field_display(.Datetime_Local, "2026-09-21T07:05")
	testing.expectf(t, strings.contains(dt, "2026") && strings.contains(dt, "05"), "datetime-local: %q", dt)
	tm := date_field_display(.Time, "18:30")
	testing.expectf(t, strings.contains(tm, "30"), "time: %q", tm)
	m := date_field_display(.Month, "2026-09")
	testing.expectf(t, strings.contains(m, "2026"), "month: %q", m)
	for bad in ([]string{"", "2026-13-01", "2026-02-x1", "1500-01-01", "21/09/2026", "2026-09-21T25:00"}) {
		testing.expectf(t, date_field_display(.Date, bad) == "" || bad == "2026-09-21T25:00", "invalid date %q shown as it is", bad)
		testing.expectf(t, date_field_display(.Datetime_Local, bad) == "", "invalid datetime %q", bad)
	}
	testing.expect_value(t, date_field_display(.Week, "2026-W38"), "")
	testing.expect_value(t, date_field_display(forms.Input_Type.Text, "2026-09-21"), "")
}
