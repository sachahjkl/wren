#+build windows
package bench

import win "core:sys/windows"

// What the system counts: the threads of a process, its memory, the performance counter.

@(private = "file") SYSTEM_PROCESS_INFORMATION_CLASS :: 5
@(private = "file") THREAD_QUERY_LIMITED :: 0x800
@(private = "file") SNAPSHOT_BYTES :: 8 * 1024 * 1024
// The layout of SYSTEM_PROCESS_INFORMATION and SYSTEM_THREAD_INFORMATION on x64.
@(private = "file") P_NEXT :: 0
@(private = "file") P_THREADS :: 4
@(private = "file") P_PID :: 0x50
@(private = "file") P_SIZE :: 0x100
@(private = "file") T_SIZE :: 80
@(private = "file") T_KERNEL :: 0
@(private = "file") T_USER :: 8
@(private = "file") T_TID :: 48
@(private = "file") T_SWITCHES :: 64

foreign import ntdll "system:ntdll.lib"
@(default_calling_convention = "system", private = "file")
foreign ntdll {
	NtQuerySystemInformation :: proc(class: i32, buffer: rawptr, size: u32, needed: ^u32) -> i32 ---
}

foreign import kernel32_threads "system:Kernel32.lib"
@(default_calling_convention = "system", private = "file")
foreign kernel32_threads {
	GetThreadDescription :: proc(thread: win.HANDLE, description: ^win.wstring) -> i32 ---
	OpenThread :: proc(access: u32, inherit: win.BOOL, id: u32) -> win.HANDLE ---
	QueryThreadCycleTime :: proc(thread: win.HANDLE, cycles: ^u64) -> win.BOOL ---
	GetSystemTimes :: proc(idle, kernel, user: ^win.FILETIME) -> win.BOOL ---
	LocalFree :: proc(memory: rawptr) -> rawptr ---
}

@(private = "file") read_at :: proc(p: [^]u8, at: int, $T: typeid) -> T { return (^T)(&p[at])^ }

read_threads :: proc(pid: int) -> []Thread_Count {
	buffer := make([]u8, SNAPSHOT_BYTES, context.temp_allocator)
	if NtQuerySystemInformation(SYSTEM_PROCESS_INFORMATION_CLASS, raw_data(buffer), SNAPSHOT_BYTES, nil) != 0 { return nil }
	p := ([^]u8)(raw_data(buffer))
	for {
		if read_at(p, P_PID, uint) == uint(pid) {
			n := int(read_at(p, P_THREADS, u32))
			out := make([]Thread_Count, n, context.temp_allocator)
			for i in 0 ..< n {
				t := P_SIZE + i * T_SIZE
				out[i] = {read_at(p, t + T_TID, u64), i64(read_at(p, t + T_SWITCHES, u32)), read_at(p, t + T_KERNEL, i64) + read_at(p, t + T_USER, i64)}
			}
			return out
		}
		next := int(read_at(p, P_NEXT, u32))
		if next == 0 { return nil }
		p = p[next:]
	}
}

thread_name :: proc(id: u64) -> string {
	h := OpenThread(THREAD_QUERY_LIMITED, false, u32(id))
	if h == nil { return "" }
	defer win.CloseHandle(h)
	text: win.wstring
	if GetThreadDescription(h, &text) < 0 || text == nil { return "" }
	defer LocalFree(rawptr(text))
	name, _ := win.wstring_to_utf8(text, -1, context.temp_allocator)
	return name
}

process_working_set :: proc(pid: int) -> int {
	if pid == 0 { return 0 }
	h := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, false, win.DWORD(pid))
	if h == nil { return 0 }
	defer win.CloseHandle(h)
	mem: win.PROCESS_MEMORY_COUNTERS
	if !win.GetProcessMemoryInfo(h, &mem, size_of(mem)) { return 0 }
	return int(mem.WorkingSetSize)
}

qpc_now :: proc() -> i64 {
	v: win.LARGE_INTEGER
	win.QueryPerformanceCounter(&v)
	return i64(v)
}

// The cycle counter of a thread of another process (base.thread_cycles, read from outside).
Thread_Reader :: distinct win.HANDLE

thread_reader :: proc(id: int) -> Thread_Reader { return Thread_Reader(OpenThread(THREAD_QUERY_LIMITED, false, u32(id))) }
thread_reader_ok :: proc(r: Thread_Reader) -> bool { return r != nil }
thread_reader_close :: proc(r: Thread_Reader) { win.CloseHandle(win.HANDLE(r)) }

thread_read :: proc(r: Thread_Reader) -> u64 {
	cycles: u64
	QueryThreadCycleTime(win.HANDLE(r), &cycles)
	return cycles
}

// What the machine's processors have spent since it started, and of that on anything but idling (100 ns units, all processors summed).
machine_times :: proc() -> (busy, total: i64) {
	as_i64 :: proc(t: win.FILETIME) -> i64 { return i64(t.dwHighDateTime) << 32 | i64(t.dwLowDateTime) }
	idle, kernel, user: win.FILETIME
	GetSystemTimes(&idle, &kernel, &user)
	total = as_i64(kernel) + as_i64(user)   // (kernel holds idle)
	return total - as_i64(idle), total
}
