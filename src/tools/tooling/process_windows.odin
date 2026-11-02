#+build windows
package tooling

import "core:strings"
import "core:sync"
import "core:time"
import win "core:sys/windows"

// A process in a job object of its own: everything it starts stays in it (no walk of parents to stop a tree, and the tree's CPU is the job's accounting,
// nothing sampled), and when the job's last handle closes, whatever is left dies: a run that is killed leaves nothing behind.

@(private = "file") JOB_BASIC_ACCOUNTING :: 1
@(private = "file") JOB_BASIC_LIMIT :: 2
@(private = "file") JOB_PROCESS_ID_LIST :: 3
@(private = "file") JOB_COMPLETION_PORT :: 7
@(private = "file") JOB_EXTENDED_LIMIT :: 9
@(private = "file") LIMIT_KILL_ON_CLOSE :: 0x2000
@(private = "file") TICKS_PER_SECOND :: 10_000_000
// The processes of a stuck tree looked at, at most.
JOB_PIDS_MAX :: 64

@(private = "file")
JOB_BASIC_LIMIT_INFORMATION :: struct {
	PerProcessUserTimeLimit, PerJobUserTimeLimit: i64,
	LimitFlags: u32,
	MinimumWorkingSetSize, MaximumWorkingSetSize: uint,
	ActiveProcessLimit: u32,
	Affinity: uint,
	PriorityClass, SchedulingClass: u32,
}

@(private = "file")
IO_COUNTERS :: struct { a, b, c, d, e, f: u64 }

@(private = "file")
JOB_EXTENDED_LIMIT_INFORMATION :: struct {
	Basic: JOB_BASIC_LIMIT_INFORMATION,
	Io: IO_COUNTERS,
	ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed: uint,
}

@(private = "file")
JOB_BASIC_ACCOUNTING_INFORMATION :: struct {
	TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime: i64,
	TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses: u32,
}

@(private = "file")
JOB_ASSOCIATE_COMPLETION_PORT :: struct { CompletionKey: rawptr, CompletionPort: win.HANDLE }

foreign import kernel32_jobs "system:Kernel32.lib"
@(default_calling_convention = "system", private = "file")
foreign kernel32_jobs {
	CreateJobObjectW :: proc(attrs: rawptr, name: win.LPCWSTR) -> win.HANDLE ---
	AssignProcessToJobObject :: proc(job, process: win.HANDLE) -> win.BOOL ---
	SetInformationJobObject :: proc(job: win.HANDLE, class: i32, info: rawptr, size: u32) -> win.BOOL ---
	QueryInformationJobObject :: proc(job: win.HANDLE, class: i32, info: rawptr, size: u32, returned: ^u32) -> win.BOOL ---
	TerminateJobObject :: proc(job: win.HANDLE, code: u32) -> win.BOOL ---
	QueryFullProcessImageNameW :: proc(process: win.HANDLE, flags: u32, name: [^]u16, size: ^u32) -> win.BOOL ---
}

Platform_Process :: struct {
	process, thread, job: win.HANDLE,
}

// As the C runtime reads a command line back: quotes when there is a space, a tab or a quote; a backslash doubled only before a quote.
quote_argument :: proc(b: ^strings.Builder, a: string) {
	if a != "" && !strings.contains_any(a, " \t\"") { strings.write_string(b, a); return }
	strings.write_byte(b, '"')
	slashes := 0
	for i := 0; i < len(a); i += 1 {
		c := a[i]
		switch c {
		case '\\': slashes += 1
		case '"':
			for _ in 0 ..< slashes + 1 { strings.write_byte(b, '\\') }
			slashes = 0
		case: slashes = 0
		}
		strings.write_byte(b, c)
	}
	for _ in 0 ..< slashes { strings.write_byte(b, '\\') }
	strings.write_byte(b, '"')
}

command_line :: proc(command: []string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for a, i in command {
		if i > 0 { strings.write_byte(&b, ' ') }
		quote_argument(&b, i == 0 ? exe_argument(a, allocator) : a)
	}
	return strings.to_string(b)
}

@(private = "file")
environment_block :: proc(add: []string) -> [^]u16 {
	b := make([dynamic]u16, context.temp_allocator)
	for e in merged_env(add) {
		w := win.utf8_to_utf16(e, context.temp_allocator)
		append(&b, ..w)
		append(&b, 0)
	}
	append(&b, 0)
	return raw_data(b)
}

@(private = "file")
inheritable_file :: proc(path: string, access, disposition: u32) -> win.HANDLE {
	sa := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), bInheritHandle = true}
	share := win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE
	return win.CreateFileW(win.utf8_to_wstring(path, context.temp_allocator), access, share, &sa, disposition, win.FILE_ATTRIBUTE_NORMAL, nil)
}

spawn :: proc(d: Spawn) -> (p: Process, why: string) {
	sync.guard(&spawn_lock)
	p.job = CreateJobObjectW(nil, nil)
	if p.job != nil {
		limit: JOB_EXTENDED_LIMIT_INFORMATION
		limit.Basic.LimitFlags = LIMIT_KILL_ON_CLOSE
		SetInformationJobObject(p.job, JOB_EXTENDED_LIMIT, &limit, size_of(limit))
		port := d.port != nil ? d.port : task_port
		if port != nil {
			assoc := JOB_ASSOCIATE_COMPLETION_PORT{rawptr(d.port_key), win.HANDLE(port)}
			SetInformationJobObject(p.job, JOB_COMPLETION_PORT, &assoc, size_of(assoc))
		}
	}
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW), dwFlags = win.STARTF_USESTDHANDLES}
	null_in := inheritable_file("NUL", win.GENERIC_READ, win.OPEN_EXISTING)
	si.hStdInput = null_in
	defer win.CloseHandle(null_in)
	log: win.HANDLE
	if d.log != "" {
		log = inheritable_file(d.log, win.FILE_APPEND_DATA, win.OPEN_ALWAYS)
		if log == win.INVALID_HANDLE_VALUE { release(&p); return p, "its log cannot be opened" }
		si.hStdOutput, si.hStdError = log, log
	} else {
		si.hStdOutput = win.GetStdHandle(win.STD_OUTPUT_HANDLE)
		si.hStdError = win.GetStdHandle(win.STD_ERROR_HANDLE)
		win.SetHandleInformation(si.hStdOutput, win.HANDLE_FLAG_INHERIT, win.HANDLE_FLAG_INHERIT)
		win.SetHandleInformation(si.hStdError, win.HANDLE_FLAG_INHERIT, win.HANDLE_FLAG_INHERIT)
	}
	defer if log != nil { win.CloseHandle(log) }
	pi: win.PROCESS_INFORMATION
	line := win.utf8_to_wstring(command_line(d.command), context.temp_allocator)
	dir: win.LPCWSTR = nil
	if d.dir != "" { dir = win.utf8_to_wstring(d.dir, context.temp_allocator) }
	flags := u32(win.CREATE_SUSPENDED | win.CREATE_UNICODE_ENVIRONMENT)
	switch d.console {
	case .Inherited:
	case .Own: flags |= win.CREATE_NO_WINDOW
	case .None: flags |= win.DETACHED_PROCESS
	}
	if !win.CreateProcessW(nil, line, nil, nil, true, flags, environment_block(d.env), dir, &si, &pi) {
		release(&p)
		return p, last_error_text()
	}
	if p.job != nil { AssignProcessToJobObject(p.job, pi.hProcess) }
	win.ResumeThread(pi.hThread)
	p.process, p.thread = pi.hProcess, pi.hThread
	p.began = time.tick_now()
	return p, ""
}

@(private = "file")
last_error_text :: proc() -> string {
	code := win.GetLastError()
	if code == win.ERROR_FILE_NOT_FOUND { return "it is not on the PATH" }
	return strings.concatenate({"system error ", digits(int(code))}, context.temp_allocator)
}

@(private = "file")
digits :: proc(v: int) -> string {
	buf: [20]u8
	i := len(buf)
	n := v
	for {
		i -= 1
		buf[i] = u8('0' + n % 10)
		n /= 10
		if n == 0 { break }
	}
	return strings.clone(string(buf[i:]), context.temp_allocator)
}

// Whether it has ended, and with what. (What it started may still run: `kill_tree`, or `release`, ends that.)
poll :: proc(p: ^Process) -> (done: bool, code: int) {
	if p.process == nil { return true, -1 }
	if win.WaitForSingleObject(p.process, 0) != win.WAIT_OBJECT_0 { return false, 0 }
	exit: u32
	win.GetExitCodeProcess(p.process, &exit)
	return true, int(i32(exit))
}

kill_tree :: proc(p: ^Process) {
	if p.job != nil { TerminateJobObject(p.job, 1) } else if p.process != nil { win.TerminateProcess(p.process, 1) }
}

// What the tree has used so far.
usage :: proc(p: ^Process) -> (u: Usage) {
	if p.job != nil {
		info: JOB_BASIC_ACCOUNTING_INFORMATION
		if QueryInformationJobObject(p.job, JOB_BASIC_ACCOUNTING, &info, size_of(info), nil) {
			u.cpu_seconds = f64(info.TotalUserTime + info.TotalKernelTime) / TICKS_PER_SECOND
			u.processes = int(info.TotalProcesses)
		}
	}
	if p.process != nil {
		mem: win.PROCESS_MEMORY_COUNTERS
		if win.GetProcessMemoryInfo(p.process, &mem, size_of(mem)) { u.peak_bytes = u64(mem.PeakWorkingSetSize) }
	}
	return
}

// The process ids of the tree that still run.
tree_pids :: proc(p: ^Process, allocator := context.temp_allocator) -> []int {
	if p.job == nil { return nil }
	List :: struct { assigned, in_list: u32, ids: [JOB_PIDS_MAX]uint }
	list: List
	if !QueryInformationJobObject(p.job, JOB_PROCESS_ID_LIST, &list, size_of(list), nil) { return nil }
	out := make([]int, list.in_list, allocator)
	for i in 0 ..< int(list.in_list) { out[i] = int(list.ids[i]) }
	return out
}

// How many of the tree still run.
tree_active :: proc(p: ^Process) -> int {
	if p.job == nil { return 0 }
	info: JOB_BASIC_ACCOUNTING_INFORMATION
	if !QueryInformationJobObject(p.job, JOB_BASIC_ACCOUNTING, &info, size_of(info), nil) { return 0 }
	return int(info.ActiveProcesses)
}

// Lets go of it: whatever of the tree still runs dies with the job's handle.
release :: proc(p: ^Process) {
	if p.thread != nil { win.CloseHandle(p.thread) }
	if p.process != nil { win.CloseHandle(p.process) }
	if p.job != nil { win.CloseHandle(p.job) }
	p.process, p.thread, p.job = nil, nil, nil
}

// A job that kills what is in it when this process ends (the desktop's re-execution: a killed outer run kills the inner one), with `process` in it.
hold_process :: proc(process: win.HANDLE) -> win.HANDLE {
	job := CreateJobObjectW(nil, nil)
	if job == nil { return nil }
	limit: JOB_EXTENDED_LIMIT_INFORMATION
	limit.Basic.LimitFlags = LIMIT_KILL_ON_CLOSE
	SetInformationJobObject(job, JOB_EXTENDED_LIMIT, &limit, size_of(limit))
	AssignProcessToJobObject(job, process)
	return job
}

// The full path of a running process's program.
process_image_path :: proc(process: win.HANDLE, allocator := context.temp_allocator) -> string {
	IMAGE_PATH_CHARS :: 4096
	path: [IMAGE_PATH_CHARS]u16
	size := u32(IMAGE_PATH_CHARS)
	if !QueryFullProcessImageNameW(process, 0, &path[0], &size) { return "" }
	text, _ := win.utf16_to_utf8(path[:size], allocator)
	return text
}
