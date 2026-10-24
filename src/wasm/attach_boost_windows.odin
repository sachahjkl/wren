package wasm

import "core:thread"
import win "core:sys/windows"

// The compile threads run below normal priority; the one that joins them waits, so they run at least as urgently (a starved thread
// takes seconds to finish a job while every core is busy: host.thread_join does the same).
@(private)
boost_for_join :: proc(t: ^thread.Thread) {
	if win.GetThreadPriority(t.win32_thread) < 0 { win.SetThreadPriority(t.win32_thread, 1) }
}
