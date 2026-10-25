package js

// The touch points of this computer's touch screen (0: none), for browser.touch.expose = auto and
// navigator.maxTouchPoints. The browser sets it from the toolkit (platform.touch_max_points) when it starts and when the
// preference changes; tools that do not set it see no touch screen.
@(private)
hardware_touch_points: int

set_touch_points :: proc(n: int) { hardware_touch_points = max(n, 0) }

touch_points :: proc() -> int { return hardware_touch_points }

// What pages are told about touch (browser.touch.expose): auto = the hardware, on = always a touch screen (at least one
// point), off = never. `points` is navigator.maxTouchPoints; `handlers` exposes ontouch* and the Touch constructors.
touch_exposure :: proc(mode: string, hardware: int) -> (points: int, handlers: bool) {
	switch mode {
	case "on": return max(hardware, 1), true
	case "off": return 0, false
	}
	return hardware, hardware > 0
}
