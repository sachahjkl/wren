#+build windows
package wrencom

import "core:strings"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
foreign import shell32 "system:Shell32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	CreateJobObjectW         :: proc(attributes: ^win.SECURITY_ATTRIBUTES, name: win.LPCWSTR) -> win.HANDLE ---
	SetInformationJobObject  :: proc(job: win.HANDLE, class: i32, info: rawptr, length: win.DWORD) -> win.BOOL ---
	AssignProcessToJobObject :: proc(job: win.HANDLE, process: win.HANDLE) -> win.BOOL ---
}

@(default_calling_convention = "system")
foreign shell32 {
	CommandLineToArgvW :: proc(command_line: win.LPCWSTR, argc: ^win.c_int) -> [^]win.LPWSTR ---
}

JobObjectExtendedLimitInformation :: 9
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x2000

Job_Basic_Limits :: struct {
	per_process_user_time: i64,
	per_job_user_time:     i64,
	limit_flags:           win.DWORD,
	minimum_working_set:   uint,
	maximum_working_set:   uint,
	active_process_limit:  win.DWORD,
	affinity:              uintptr,
	priority_class:        win.DWORD,
	scheduling_class:      win.DWORD,
}

Job_Extended_Limits :: struct {
	basic:                 Job_Basic_Limits,
	io_counters:           [6]u64,
	process_memory_limit:  uint,
	job_memory_limit:      uint,
	peak_process_memory:   uint,
	peak_job_memory:       uint,
}
#assert(size_of(Job_Extended_Limits) == 144)

// Exit codes of the launcher's own failures (wren.exe's are its own: `wren ctl` uses 0 to 4). The shells' convention.
EXIT_NOT_RUNNABLE :: 126   // wren.exe is there and would not start
EXIT_NOT_FOUND    :: 127   // there is no wren.exe beside the launcher

main :: proc() {
	win.ExitProcess(win.DWORD(run()))
}

@(private = "file")
fail :: proc(text: string) {
	write_stderr(strings.concatenate({"wren.com ", MARK, ": ", text, "\n"}, context.temp_allocator))
}

// To the standard error output the launcher was given (a file, a pipe, the console); nowhere if it has none.
@(private = "file")
write_stderr :: proc(text: string) {
	h := win.GetStdHandle(win.STD_ERROR_HANDLE)
	if h == nil || h == win.INVALID_HANDLE_VALUE { return }
	data := transmute([]byte)text
	for len(data) > 0 {
		written: win.DWORD
		if !win.WriteFile(h, raw_data(data), win.DWORD(len(data)), &written, nil) || written == 0 { return }
		data = data[written:]
	}
}

@(private = "file")
run :: proc() -> int {
	buf: [win.MAX_PATH_WIDE]u16
	n := win.GetModuleFileNameW(nil, raw_data(buf[:]), win.DWORD(len(buf)))
	if n == 0 || int(n) >= len(buf) { fail("cannot tell where it is"); return EXIT_NOT_FOUND }
	self, _ := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	target, ok := target_of(self)
	if !ok {
		fail(strings.concatenate({self, " would start itself: this program must be named wren.com, beside wren.exe, and cmd.exe then prefers it to wren.exe when `wren` is typed."}, context.temp_allocator))
		return EXIT_NOT_RUNNABLE
	}
	if win.GetFileAttributesW(win.utf8_to_wstring(target, context.temp_allocator)) == win.INVALID_FILE_ATTRIBUTES {
		fail(strings.concatenate({"there is no ", target, " beside it."}, context.temp_allocator))
		return EXIT_NOT_FOUND
	}

	plan := decide(command_line_args())
	line := win.utf8_to_wstring(command_line(target, plan.args), context.temp_allocator)
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW)}
	pi: win.PROCESS_INFORMATION
	inherit := win.BOOL(false)

	if plan.mode == .Wait {
		// Die with the child, and it with us: a launcher that is killed (a terminal closed, a build step cancelled) takes the Wren
		// it started along. The child inherits the job.
		if job := CreateJobObjectW(nil, nil); job != nil {
			limits := Job_Extended_Limits{basic = {limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE}}
			if SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, size_of(limits)) {
				AssignProcessToJobObject(job, win.GetCurrentProcess())   // (refused where a job without nesting holds us: then we only wait)
			}   // (the handle stays open for the life of the process: closing it is what kills the group)
		}
		// Ctrl+C reaches the child as well; the launcher stays, so as to give the code the child ends with. (A handler, not the
		// "ignore" attribute: that one is inherited and would make the child deaf to Ctrl+C.)
		win.SetConsoleCtrlHandler(proc "system" (_: win.DWORD) -> win.BOOL { return true }, true)

		// Our own standard handles are the child's: `> file`, `| more`, `2>&1` are then what the user wrote.
		si.dwFlags = win.STARTF_USESTDHANDLES
		si.hStdInput = inheritable(win.GetStdHandle(win.STD_INPUT_HANDLE))
		si.hStdOutput = inheritable(win.GetStdHandle(win.STD_OUTPUT_HANDLE))
		si.hStdError = inheritable(win.GetStdHandle(win.STD_ERROR_HANDLE))
		inherit = true
	}

	if !win.CreateProcessW(win.utf8_to_wstring(target, context.temp_allocator), cstring16(line), nil, nil, inherit, 0, nil, nil, &si, &pi) {
		fail(strings.concatenate({"cannot start ", target, " (error ", itoa(int(win.GetLastError())), ")."}, context.temp_allocator))
		return EXIT_NOT_RUNNABLE
	}
	win.CloseHandle(pi.hThread)
	defer win.CloseHandle(pi.hProcess)
	if plan.mode == .Detach { return 0 }

	win.WaitForSingleObject(pi.hProcess, win.INFINITE)
	code: win.DWORD
	if !win.GetExitCodeProcess(pi.hProcess, &code) { return 1 }
	return int(code)
}

// A standard handle the child may have: marked inheritable, or nil when there is none.
@(private = "file")
inheritable :: proc(h: win.HANDLE) -> win.HANDLE {
	if h == nil || h == win.INVALID_HANDLE_VALUE { return nil }
	win.SetHandleInformation(h, win.HANDLE_FLAG_INHERIT, win.HANDLE_FLAG_INHERIT)
	return h
}

@(private = "file")
itoa :: proc(n: int) -> string {
	buf: [20]byte
	i := len(buf)
	v := n
	for {
		i -= 1
		buf[i] = byte('0' + v % 10)
		v /= 10
		if v == 0 { break }
	}
	return strings.clone(string(buf[i:]), context.temp_allocator)
}

// The arguments (without the program's own name), UTF-8, as the C runtime of Odin does not give them (it hands over the
// system's ANSI code page).
@(private = "file")
command_line_args :: proc() -> []string {
	argc: win.c_int
	argv := CommandLineToArgvW(win.GetCommandLineW(), &argc)
	if argv == nil || argc < 1 { return nil }
	defer win.LocalFree(rawptr(argv))
	out := make([]string, int(argc) - 1, context.temp_allocator)
	for i in 1 ..< int(argc) {
		s, err := win.wstring_to_utf8(win.wstring(argv[i]), -1, context.temp_allocator)
		out[i - 1] = err == nil ? s : ""
	}
	return out
}
