package browser

// The timing of timed frames on Windows (pacing.odin): a high-resolution waitable timer the pacer arms for the time it
// means to wait, then waits on while the window keeps taking input (platform.wait_handle). pacing_timer_other.odin is
// the Linux counterpart, where there is no such object and the FIFO vblank does the fine pacing.

import win "core:sys/windows"
import "toolkit:platform"

pacer_timer_create :: proc() -> rawptr {
	CREATE_WAITABLE_TIMER_HIGH_RESOLUTION :: 0x2
	h := win.CreateWaitableTimerExW(nil, nil, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win.TIMER_ALL_ACCESS)
	if h == nil { h = win.CreateWaitableTimerExW(nil, nil, 0, win.TIMER_ALL_ACCESS) }   // before Windows 10 1803
	return rawptr(h)
}

pacer_timer_destroy :: proc(timer: rawptr) {
	if timer != nil { win.CloseHandle(win.HANDLE(timer)) }
}

// Arms the timer for `wait_ns` from now and waits on it while the window takes its input, time-stamped as it arrives.
pacer_timer_wait :: proc(w: ^platform.Window, timer: rawptr, wait_ns: i64) {
	due := win.LARGE_INTEGER(-(wait_ns / 100))   // relative, in 100 ns units
	if win.SetWaitableTimerEx(win.HANDLE(timer), &due, 0, nil, nil, nil, 0) {
		platform.wait_handle(w, timer, int(wait_ns / 1_000_000) + 50)
	}
}
