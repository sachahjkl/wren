package browser

// The desktop's mouse-wheel scroll settings (smooth_scroll.odin's wheel_step): how many lines a vertical notch scrolls
// and how many characters a horizontal notch scrolls, or WHEEL_PAGESCROLL (max u32) for "one screen at a time". Read at
// each wheel event (cheap, and the setting may change while Wren runs). The Linux counterpart is scroll_steps_other.odin.

import win "core:sys/windows"

system_wheel_scroll :: proc() -> (lines, chars: u32) {
	lines, chars = 3, 3
	win.SystemParametersInfoW(0x0068, 0, &lines, 0)   // SPI_GETWHEELSCROLLLINES
	win.SystemParametersInfoW(0x006C, 0, &chars, 0)   // SPI_GETWHEELSCROLLCHARS
	return
}
