package crashtrace

// A crash of a test tool (an access violation, an illegal instruction, a stack overflow...) prints the faulting
// thread's call stack with function names, files and lines (DbgHelp and the PDB next to the exe: build the tool with
// -debug, -o:speed keeps working) on standard output and standard error, then lets the process die as before. Without
// it a crash under load left only a "Fault offset" in the Windows event log. Importing the package installs it.
//
// The stack is unwound from the exception's context with the unwind tables of the modules (RtlVirtualUnwind; Wasmtime
// registers those of the code it compiles). Only the faulting thread is shown.

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"

@(private = "file")
MAX_FRAMES :: 64

@(private = "file")
RUNTIME_FUNCTION :: struct {
	begin, end, unwind: u32,
}

foreign import kernel32 "system:Kernel32.lib"

@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	RtlLookupFunctionEntry :: proc(ControlPc: u64, ImageBase: ^u64, HistoryTable: rawptr) -> ^RUNTIME_FUNCTION ---
	RtlVirtualUnwind :: proc(HandlerType: u32, ImageBase: u64, ControlPc: u64, FunctionEntry: ^RUNTIME_FUNCTION, ContextRecord: ^win.CONTEXT, HandlerData: ^rawptr, EstablisherFrame: ^u64, ContextPointers: rawptr) -> rawptr ---
}

@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	GetLocalTime :: proc(lpSystemTime: ^win.SYSTEMTIME) ---
}

@(private = "file")
installed: bool

// Where a crash also leaves its report (set_report_dir): "<dir>\crash <date> <time>.txt", the stack as printed, and a
// ".dmp" next to it (a minidump with the threads and the memory they point to, for WinDbg or Visual Studio). Kept as
// UTF-16 in fixed buffers: nothing is allocated while the process is crashing.
@(private = "file")
report_dir: [512]u16
@(private = "file")
report_header: [512]u8
@(private = "file")
report_header_len: int
@(private = "file")
report_file: win.HANDLE

// The folder where crashes leave their report and minidump (created on the first crash), and a line written at the
// top of each report (the program and its version). Call it once at startup; until then a crash only prints.
set_report_dir :: proc(dir: string, header := "") {
	w := win.utf8_to_utf16(dir, context.temp_allocator)
	n := min(len(w), len(report_dir) - 1)
	copy(report_dir[:n], w[:n])
	report_dir[n] = 0
	report_header_len = copy(report_header[:], header)
}

@(private = "file")
open_report :: proc(info: ^win.EXCEPTION_POINTERS, tid: win.DWORD) {
	if report_dir[0] == 0 { return }
	win.CreateDirectoryW(cstring16(&report_dir[0]), nil)
	st: win.SYSTEMTIME
	GetLocalTime(&st)
	name: [64]u8
	stem := fmt.bprintf(name[:], "\\crash %04d-%02d-%02d %02d-%02d-%02d", st.year, st.month, st.day, st.hour, st.minute, st.second)
	path: [len(report_dir) + 80]u16
	n := 0
	for report_dir[n] != 0 { path[n] = report_dir[n]; n += 1 }
	for c in stem { path[n] = u16(c); n += 1 }
	ext :: proc(path: []u16, n: int, e: string) { for c, i in e { path[n + i] = u16(c) }; path[n + len(e)] = 0 }

	ext(path[:], n, ".dmp")
	dump := win.CreateFileW(cstring16(&path[0]), win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if dump != win.INVALID_HANDLE_VALUE {
		mei := win.MINIDUMP_EXCEPTION_INFORMATION{ThreadId = tid, ExceptionPointers = info, ClientPointers = false}
		// MiniDumpWithIndirectlyReferencedMemory | MiniDumpWithThreadInfo
		win.MiniDumpWriteDump(win.GetCurrentProcess(), win.GetCurrentProcessId(), dump, win.MINIDUMP_TYPE(0x1040), &mei, nil, nil)
		win.CloseHandle(dump)
	}
	ext(path[:], n, ".txt")
	report_file = win.CreateFileW(cstring16(&path[0]), win.GENERIC_WRITE, win.FILE_SHARE_READ, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if report_file == win.INVALID_HANDLE_VALUE { report_file = nil; return }
	if report_header_len > 0 {
		written: win.DWORD
		win.WriteFile(report_file, &report_header[0], win.DWORD(report_header_len), &written, nil)
		win.WriteFile(report_file, raw_data(string("\n")), 1, &written, nil)
	}
}

@(init, private = "file")
install :: proc "contextless" () {
	if installed { return }
	installed = true
	// room for the handler on a thread whose stack is gone (a stack overflow leaves one page: not enough to write a report)
	guarantee: u32 = 128 * 1024
	SetThreadStackGuarantee(&guarantee)
	report_wake = win.CreateEventW(nil, false, false, nil)
	report_done = win.CreateEventW(nil, true, false, nil)
	if report_wake != nil && report_done != nil { report_thread = win.CreateThread(nil, 4 << 20, parked_report_thread, nil, 0, nil) }
	win.SetUnhandledExceptionFilter(on_crash)
	// What kills a process without the filter being asked: a heap the system found corrupted (0xC0000374) ends it at once, and
	// a stack overflow often leaves the filter no room. The vectored handler is called first for those two (and for a failed
	// security check raised as an exception); it only reports, the process dies as it would have.
	win.AddVectoredExceptionHandler(0, on_fatal)
}

@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	SetThreadStackGuarantee :: proc(size: ^u32) -> win.BOOL ---
}

@(private = "file")
reported: i32          // the report is written once, by whichever handler comes first
@(private = "file")
pending: ^win.EXCEPTION_POINTERS
@(private = "file")
pending_thread: win.DWORD

@(private = "file")
on_crash :: proc "system" (info: ^win.EXCEPTION_POINTERS) -> win.LONG {
	hand_over(info)
	return 0   // EXCEPTION_CONTINUE_SEARCH: the process dies as it would have (exit code, event log)
}

@(private = "file")
on_fatal :: proc "system" (info: ^win.EXCEPTION_POINTERS) -> win.LONG {
	switch u32(info.ExceptionRecord.ExceptionCode) {
	case 0xC0000374, 0xC00000FD, 0xC0000409: hand_over(info)
	}
	return 0   // EXCEPTION_CONTINUE_SEARCH
}

// The report is written by a thread of its own, with a stack of its own, while the faulting thread waits: the faulting thread may
// have none left (a stack overflow), and the dump of a process is best written by a thread that is not the one in trouble.
// The thread that writes it is made at start-up and parked on an event: a handler that runs on a thread with one page of stack left
// (a stack overflow on a thread that did not ask for a guarantee) can set an event and wait, where making a thread (what this did
// before) needs more stack than that on some versions of Windows, and the handler then died of its own access violation, with no report.
@(private = "file")
report_wake, report_done: win.HANDLE
@(private = "file")
report_thread: win.HANDLE

@(private = "file")
hand_over :: proc "contextless" (info: ^win.EXCEPTION_POINTERS) {
	if intrinsics.atomic_exchange(&reported, 1) != 0 { return }
	pending, pending_thread = info, win.GetCurrentThreadId()
	if report_thread != nil && report_wake != nil && report_done != nil {
		win.SetEvent(report_wake)
		win.WaitForSingleObject(report_done, 60_000)
		return
	}
	h := win.CreateThread(nil, 4 << 20, write_report_thread, nil, 0, nil)
	if h == nil { write_report_thread(nil); return }   // (no thread to be had: here, as before)
	win.WaitForSingleObject(h, 60_000)
}

@(private = "file")
write_report_thread :: proc "system" (_: rawptr) -> win.DWORD {
	context = runtime.default_context()   // memcheck: not the tracker (the crashing thread may hold its lock)
	write_report(pending, pending_thread)
	return 0
}

// The parked thread: wakes for the one report of the process.
@(private = "file")
parked_report_thread :: proc "system" (_: rawptr) -> win.DWORD {
	win.WaitForSingleObject(report_wake, win.INFINITE)
	write_report_thread(nil)
	win.SetEvent(report_done)
	return 0
}
@(private = "file")
code_name :: proc(code: u32) -> string {
	switch code {
	case 0xC0000005: return "access violation"
	case 0xC000001D: return "illegal instruction (an Odin assertion or bounds check)"
	case 0xC00000FD: return "stack overflow"
	case 0xC0000094: return "integer division by zero"
	case 0xC0000409: return "stack buffer overrun / fast fail"
	case 0xC0000374: return "heap corruption (the system found the heap damaged)"
	case 0x80000003: return "breakpoint"
	}
	return "exception"
}

@(private = "file")
write_report :: proc(info: ^win.EXCEPTION_POINTERS, tid: win.DWORD) {
	rec := info.ExceptionRecord
	ctx := info.ContextRecord^   // unwound in a copy
	process := win.GetCurrentProcess()
	win.SymSetOptions(win.SYMOPT_LOAD_LINES | win.SYMOPT_DEFERRED_LOADS)
	win.SymInitialize(process, nil, true)
	open_report(info, tid)

	buf: [8192]u8
	b := fmt.bprintf(buf[:], "\n*** crash: %s (0x%08X) at 0x%X, thread %d", code_name(u32(rec.ExceptionCode)), u32(rec.ExceptionCode), uintptr(rec.ExceptionAddress), tid)
	if rec.ExceptionCode == 0xC0000005 && rec.NumberParameters >= 2 {
		kind := uintptr(rec.ExceptionInformation[0])
		b = fmt.bprintf(buf[:], "%s, %s address 0x%X", b, kind == 0 ? "reading" : (kind == 1 ? "writing" : "executing"), uintptr(rec.ExceptionInformation[1]))
	}
	emit(b)

	for i in 0 ..< MAX_FRAMES {
		pc := ctx.Rip
		if pc == 0 { break }
		emit(frame_line(buf[:], process, i, pc))
		image_base: u64
		fn := RtlLookupFunctionEntry(pc, &image_base, nil)
		if fn == nil {
			// a leaf function: the return address is on top of the stack
			if ctx.Rsp == 0 { break }
			ctx.Rip = (^u64)(uintptr(ctx.Rsp))^
			ctx.Rsp += 8
		} else {
			handler_data: rawptr
			establisher: u64
			RtlVirtualUnwind(0, image_base, pc, fn, &ctx, &handler_data, &establisher, nil)
		}
	}
	emit("*** end of the stack\n")
	if report_file != nil { win.CloseHandle(report_file); report_file = nil }
}

@(private = "file")
frame_line :: proc(buf: []u8, process: win.HANDLE, i: int, pc: u64) -> string {
	SYM_NAME :: 256
	raw: [size_of(win.SYMBOL_INFOW) + SYM_NAME * 2]u8
	sym := (^win.SYMBOL_INFOW)(&raw[0])
	sym.SizeOfStruct = size_of(win.SYMBOL_INFOW)
	sym.MaxNameLen = SYM_NAME
	disp: u64
	name := "?"
	name_buf: [SYM_NAME * 3]u8
	if win.SymFromAddrW(process, pc, &disp, sym) {
		w := ([^]u16)(&sym.Name[0])[:sym.NameLen]
		n := 0
		for c in w { if n < len(name_buf) - 1 { name_buf[n] = c < 128 ? u8(c) : '?'; n += 1 } }
		name = string(name_buf[:n])
	}
	line: win.IMAGEHLP_LINE64
	line.SizeOfStruct = size_of(win.IMAGEHLP_LINE64)
	ldisp: win.DWORD
	file_buf: [512]u8
	file := ""
	if win.SymGetLineFromAddrW64(process, pc, &ldisp, &line) && line.FileName != nil {
		w := ([^]u16)(rawptr(line.FileName))
		n := 0
		for n < len(file_buf) - 1 && w[n] != 0 { file_buf[n] = w[n] < 128 ? u8(w[n]) : '?'; n += 1 }
		file = string(file_buf[:n])
	}
	if file != "" { return fmt.bprintf(buf, "  #%02d 0x%X %s+0x%X  %s:%d", i, pc, name, disp, file, line.LineNumber) }
	return fmt.bprintf(buf, "  #%02d 0x%X %s+0x%X", i, pc, name, disp)
}

// A tool that seems stuck: the call stack of another thread of the process (suspended meanwhile), printed like a
// crash's. `thread` needs THREAD_SUSPEND_RESUME and THREAD_GET_CONTEXT (OpenThread with the thread's id).
dump_thread :: proc(thread: win.HANDLE, what: string) {
	context = runtime.default_context()   // memcheck: not the tracker (the dumped thread may hold its lock)
	if win.SuspendThread(thread) == ~win.DWORD(0) { emit("*** dump: cannot suspend the thread"); return }
	defer win.ResumeThread(thread)
	ctx: win.CONTEXT
	ctx.ContextFlags = 0x0010000B   // CONTEXT_FULL (AMD64)
	if !win.GetThreadContext(thread, &ctx) { emit("*** dump: cannot read the thread's context"); return }
	process := win.GetCurrentProcess()
	win.SymSetOptions(win.SYMOPT_LOAD_LINES | win.SYMOPT_DEFERRED_LOADS)
	win.SymInitialize(process, nil, true)
	buf: [8192]u8
	emit(fmt.bprintf(buf[:], "\n*** stack of %s", what))
	for i in 0 ..< MAX_FRAMES {
		pc := ctx.Rip
		if pc == 0 { break }
		emit(frame_line(buf[:], process, i, pc))
		image_base: u64
		fn := RtlLookupFunctionEntry(pc, &image_base, nil)
		if fn == nil {
			if ctx.Rsp == 0 { break }
			ctx.Rip = (^u64)(uintptr(ctx.Rsp))^
			ctx.Rsp += 8
		} else {
			handler_data: rawptr
			establisher: u64
			RtlVirtualUnwind(0, image_base, pc, fn, &ctx, &handler_data, &establisher, nil)
		}
	}
	emit("*** end of the stack\n")
}

// On standard output (where test_all keeps the tools' reports), standard error and the crash's report file (when
// set_report_dir was called), with nothing buffered.
@(private = "file")
emit :: proc(s: string) {
	for h in ([2]win.DWORD{win.STD_OUTPUT_HANDLE, win.STD_ERROR_HANDLE}) {
		out := win.GetStdHandle(h)
		if out == nil || out == win.INVALID_HANDLE_VALUE { continue }
		written: win.DWORD
		win.WriteFile(out, raw_data(s), win.DWORD(len(s)), &written, nil)
		win.WriteFile(out, raw_data(string("\n")), 1, &written, nil)
	}
	if report_file != nil {
		written: win.DWORD
		win.WriteFile(report_file, raw_data(s), win.DWORD(len(s)), &written, nil)
		win.WriteFile(report_file, raw_data(string("\r\n")), 2, &written, nil)
	}
}

////////////////////////////////
// Sessions that ended without a report

// Some ends leave the filter no chance: a fail-fast (a Rust or C runtime that aborts, __fastfail), the system killing the process,
// ExitProcess of a watchdog. A file "session.txt" in the report folder says a session is running (its process id and start time,
// the header); end_session() removes it at a clean exit. Found at the next start with its process gone, it becomes
// "unclean exit <date>.txt" in the same folder: what the session was, and Windows' own record of the end (the Application Error
// event with the exception code and the fault offset: wevtutil), so that an end without a stack still says what it was.
begin_session :: proc() {
	if report_dir[0] == 0 { return }
	win.CreateDirectoryW(cstring16(&report_dir[0]), nil)
	path := session_path()
	if prev, ok := read_file(path); ok {
		pid, started := parse_session(prev)
		if pid != 0 && !process_is(pid, started) {
			h := win.CreateThread(nil, 1 << 20, unclean_thread, nil, 0, nil)   // (wevtutil takes a moment: not on the start-up path)
			if h != nil {
				unclean_text = prev
				win.CloseHandle(h)
			}
		}
	}
	ft: win.FILETIME
	win.GetSystemTimeAsFileTime(&ft)
	text := fmt.tprintf("%d\n%d\n%s\n", win.GetCurrentProcessId(), u64(ft.dwHighDateTime) << 32 | u64(ft.dwLowDateTime), string(report_header[:report_header_len]))
	write_file(path, transmute([]u8)text)
}

end_session :: proc() {
	if report_dir[0] == 0 { return }
	path := session_path()
	win.DeleteFileW(cstring16(&path[0]))
}

@(private = "file")
unclean_text: string

@(private = "file")
session_path :: proc() -> (path: [len(report_dir) + 32]u16) {
	n := 0
	for report_dir[n] != 0 { path[n] = report_dir[n]; n += 1 }
	for c in string("\\session.txt") { path[n] = u16(c); n += 1 }
	return
}

@(private = "file")
read_file :: proc(path: [len(report_dir) + 32]u16) -> (text: string, ok: bool) {
	path := path
	h := win.CreateFileW(cstring16(&path[0]), win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE { return }
	defer win.CloseHandle(h)
	buf := make([]u8, 4096, context.allocator)
	n: win.DWORD
	if !win.ReadFile(h, raw_data(buf), win.DWORD(len(buf)), &n, nil) { return }
	return string(buf[:n]), true
}

@(private = "file")
write_file :: proc(path: [len(report_dir) + 32]u16, data: []u8) {
	path := path
	h := win.CreateFileW(cstring16(&path[0]), win.GENERIC_WRITE, win.FILE_SHARE_READ, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE { return }
	n: win.DWORD
	win.WriteFile(h, raw_data(data), win.DWORD(len(data)), &n, nil)
	win.CloseHandle(h)
}

@(private = "file")
parse_session :: proc(text: string) -> (pid: u32, started: u64) {
	lines := strings.split(text, "\n", context.temp_allocator)
	if len(lines) < 2 { return }
	p, ok1 := strconv.parse_uint(strings.trim_space(lines[0]), 10)
	s, ok2 := strconv.parse_u64(strings.trim_space(lines[1]), 10)
	if ok1 && ok2 { return u32(p), s }
	return
}

// Whether the process `pid` that started at `started` (FILETIME) still runs (a recycled id is another process).
@(private = "file")
process_is :: proc(pid: u32, started: u64) -> bool {
	h := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if h == nil { return false }
	defer win.CloseHandle(h)
	code: win.DWORD
	if !win.GetExitCodeProcess(h, &code) || code != 259 { return false }   // STILL_ACTIVE
	c, e, k, u: win.FILETIME
	if win.GetProcessTimes(h, &c, &e, &k, &u) {
		created := u64(c.dwHighDateTime) << 32 | u64(c.dwLowDateTime)
		return created <= started + 10 * 10_000_000   // (started is when the session was written, a moment after the process was made)
	}
	return true
}

@(private = "file")
unclean_thread :: proc "system" (_: rawptr) -> win.DWORD {
	context = runtime.default_context()   // memcheck: not the tracker (a thread of its own, started at the start-up)
	prev := unclean_text
	pid, _ := parse_session(prev)
	st: win.SYSTEMTIME
	GetLocalTime(&st)
	out := strings.builder_make(context.allocator)
	fmt.sbprintf(&out, "%s\n\n*** a session ended without a crash report: no stack, the filter was not run (a fail-fast, the system or a watchdog ended the process).\nThe session file said (process id, start, program):\n%s\n", string(report_header[:report_header_len]), prev)
	// Windows' own record: the Application Error event (id 1000) of that process id, which names the exception code and the offset
	events := run_hidden("wevtutil.exe qe Application \"/q:*[System[(EventID=1000)]]\" /c:40 /rd:true /f:text")
	hex := fmt.tprintf("0x%X", pid)
	dec := fmt.tprintf("%d", pid)
	found := false
	for block in strings.split(events, "Event[", context.temp_allocator) {
		if strings.contains(strings.to_upper(block, context.temp_allocator), hex) || strings.contains(block, fmt.tprintf(" %s ", dec)) {
			fmt.sbprintf(&out, "\nWindows' event for process %d:\n%s\n", pid, block)
			found = true
			break
		}
	}
	if !found { fmt.sbprintf(&out, "\n(no Application Error event for process %d: it was closed or killed from outside, or by an exit of its own)\n", pid) }
	name: [64]u8
	stem := fmt.bprintf(name[:], "\\unclean exit %04d-%02d-%02d %02d-%02d-%02d.txt", st.year, st.month, st.day, st.hour, st.minute, st.second)
	path: [len(report_dir) + 80]u16
	n := 0
	for report_dir[n] != 0 { path[n] = report_dir[n]; n += 1 }
	for c in stem { path[n] = u16(c); n += 1 }
	h := win.CreateFileW(cstring16(&path[0]), win.GENERIC_WRITE, win.FILE_SHARE_READ, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h != win.INVALID_HANDLE_VALUE {
		w: win.DWORD
		text := strings.to_string(out)
		win.WriteFile(h, raw_data(text), win.DWORD(len(text)), &w, nil)
		win.CloseHandle(h)
	}
	return 0
}

// A command line run without a window, its output (the first 64 KB) read from a pipe.
@(private = "file")
run_hidden :: proc(cmd: string) -> string {
	sa := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), bInheritHandle = true}
	rd, wr: win.HANDLE
	if !win.CreatePipe(&rd, &wr, &sa, 0) { return "" }
	win.SetHandleInformation(rd, 1, 0)   // HANDLE_FLAG_INHERIT off for the read end
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW), dwFlags = 0x101, wShowWindow = 0, hStdOutput = wr, hStdError = wr}   // STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES
	pi: win.PROCESS_INFORMATION
	line := win.utf8_to_utf16(cmd, context.temp_allocator)
	ok := win.CreateProcessW(nil, cstring16(raw_data(line)), nil, nil, true, 0x08000000, nil, nil, &si, &pi)   // CREATE_NO_WINDOW
	win.CloseHandle(wr)
	if !ok { win.CloseHandle(rd); return "" }
	out := make([dynamic]u8, context.temp_allocator)
	buf: [4096]u8
	for len(out) < 64 * 1024 {
		n: win.DWORD
		if !win.ReadFile(rd, &buf[0], len(buf), &n, nil) || n == 0 { break }
		append(&out, ..buf[:n])
	}
	win.WaitForSingleObject(pi.hProcess, 5000)
	win.CloseHandle(pi.hProcess)
	win.CloseHandle(pi.hThread)
	win.CloseHandle(rd)
	return string(out[:])
}
