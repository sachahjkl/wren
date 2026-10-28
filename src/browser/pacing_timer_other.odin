#+build !windows
package browser

// The timing of timed frames off Windows (pacing_timer_windows.odin uses a high-resolution waitable timer). There is no
// portable waitable timer that also takes window input, and the Linux present path is the FIFO vblank, which paces
// presents at the refresh rate on its own. So the pacer's between-frame wait is a plain high-resolution sleep of the UI
// thread: input that arrives during it is taken on the next pump. The frame-latency wait on the swap chain
// (render.frame_waitable through platform.wait_handle in pacing.odin) is unchanged and does the real present pacing.

import "core:time"
import "toolkit:platform"

pacer_timer_create :: proc() -> rawptr { return rawptr(uintptr(1)) }   // a non-nil token: the pacer only checks "!= nil"

pacer_timer_destroy :: proc(timer: rawptr) {}

pacer_timer_wait :: proc(w: ^platform.Window, timer: rawptr, wait_ns: i64) {
	if wait_ns > 0 { time.sleep(time.Duration(wait_ns)) }
}
