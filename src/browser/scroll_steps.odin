package browser

// The desktop's mouse-wheel scroll settings (smooth_scroll.odin's wheel_step), as the toolkit reads them (platform.wheel_lines):
// how many lines a vertical notch scrolls and how many characters a horizontal notch scrolls, or WHEEL_PAGESCROLL (max u32) for
// "one screen at a time". Read at each wheel event: it costs nothing, and a change of the setting is seen at once.

import "toolkit:platform"

system_wheel_scroll :: proc() -> (lines, chars: u32) {
	notch :: proc(n: f32) -> u32 { return n <= 0 ? max(u32) : u32(n) }   // (0: a page at a time)
	return notch(platform.wheel_lines()), notch(platform.wheel_lines(across = true))
}
