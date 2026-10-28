package browser

import "core:testing"
import win "core:sys/windows"

// One wheel notch: browser.scroll.step_px when set, else what Windows says, as Chromium (lines per notch x 100/3 px).
@(test)
wheel_step_follows_windows :: proc(t: ^testing.T) {
	app: App
	app.cfg.scroll_step = 48
	testing.expect_value(t, wheel_step(&app), [2]f32{48, 48})
	app.cfg.scroll_step = 0
	lines: u32 = 3
	win.SystemParametersInfoW(0x0068, 0, &lines, 0)   // SPI_GETWHEELSCROLLLINES
	s := wheel_step(&app, {800, 600})
	if lines == max(u32) {
		testing.expect_value(t, s.y, f32(600 * 0.875))   // "one screen at a time"
	} else {
		testing.expect(t, abs(s.y - f32(lines) * 100.0 / 3.0) < 0.01, "lines per notch times 100/3 px")
	}
	if lines == 3 { testing.expect(t, abs(s.y - 100) < 0.01, "the default 3 lines: 100 px, as in Chromium and Edge") }
}
