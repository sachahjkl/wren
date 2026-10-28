#+build !windows
package browser

// The mouse-wheel scroll settings off Windows (scroll_steps_windows.odin has the Windows reader). The toolkit does not
// yet surface the desktop's lines/chars-per-notch setting on Linux, so this returns the common default of 3 lines and 3
// characters per notch (what wheel_step turns into 100 px, as Chromium and Edge do). A user can still set an exact pixel
// step with the browser.scroll.step_px preference, which wins over this.

system_wheel_scroll :: proc() -> (lines, chars: u32) { return 3, 3 }
