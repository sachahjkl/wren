package wasm

// Sleep() would round the ticker's period up to the system timer (15.6 ms unless some process asked for better): the
// ticker sleeps on a high-resolution waitable timer.

import "core:time"
import win "core:sys/windows"

@(private)
ticker_timer: win.HANDLE

// Sleeps `ms` on a high-resolution waitable timer (Sleep where there is none: before Windows 10 1803).
@(private)
ticker_sleep :: proc(ms: int) {
	if ticker_timer == nil {
		CREATE_WAITABLE_TIMER_HIGH_RESOLUTION :: 0x2
		ticker_timer = win.CreateWaitableTimerExW(nil, nil, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win.TIMER_ALL_ACCESS)
	}
	if ticker_timer != nil {
		due := win.LARGE_INTEGER(-i64(ms) * 10_000)   // relative, 100 ns units
		if win.SetWaitableTimerEx(ticker_timer, &due, 0, nil, nil, nil, 0) {
			win.WaitForSingleObject(ticker_timer, win.INFINITE)
			return
		}
	}
	time.sleep(time.Duration(ms) * time.Millisecond)
}

// The ticker's timer, when it stops.
@(private)
ticker_sleep_destroy :: proc() {
	if ticker_timer != nil { win.CloseHandle(ticker_timer); ticker_timer = nil }
}
