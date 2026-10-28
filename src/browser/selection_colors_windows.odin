package browser

// The default text-selection colors on Windows: the system highlight (COLOR_HIGHLIGHT / COLOR_HIGHLIGHTTEXT), used when
// the preference is not a colour. selection_colors_other.odin has the Linux defaults.

import win "core:sys/windows"
import "toolkit:draw"

@(private = "file")
sys_color :: proc(index: i32) -> draw.Color {
	c := win.GetSysColor(index)
	return draw.srgb(f32(c & 0xff) / 255, f32((c >> 8) & 0xff) / 255, f32((c >> 16) & 0xff) / 255, 1)
}

system_selection_bg :: proc() -> draw.Color { return sys_color(win.COLOR_HIGHLIGHT) }
system_selection_fg :: proc() -> draw.Color { return sys_color(win.COLOR_HIGHLIGHTTEXT) }
