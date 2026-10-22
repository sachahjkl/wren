#+build windows
package media

import win "core:sys/windows"

// The calling thread's name, as profilers, the debugger and tools\thread_cpu.ps1 show it (SetThreadDescription): the
// player's decoder and audio threads are told apart from the process's others when their CPU is measured.
name_current_thread :: proc(name: string) {
	w := win.utf8_to_wstring(name, context.temp_allocator)
	win.SetThreadDescription(win.GetCurrentThread(), w)
}
