package js

import win "core:sys/windows"

// Whether this computer has a touch screen (a digitizer that takes touches: GetSystemMetrics SM_MAXIMUMTOUCHES), for
// javascript.touch_events = auto.
has_touch_screen :: proc() -> bool {
	SM_MAXIMUMTOUCHES :: 95
	return win.GetSystemMetrics(SM_MAXIMUMTOUCHES) > 0
}
