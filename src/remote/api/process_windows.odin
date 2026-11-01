#+build windows
package api

// The processes of session.odin on Windows: a process handle (CreateProcessW, OpenProcess), told again by its creation time
// and image path.

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "wb:tools/stacks"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	QueryFullProcessImageNameW :: proc(hProcess: win.HANDLE, dwFlags: win.DWORD, lpExeName: win.LPWSTR, lpdwSize: ^win.DWORD) -> win.BOOL ---
}

Process :: struct {
	handle:   win.HANDLE,
	out, err: win.HANDLE,   // the read ends of the pipes it writes to, those it was given (Start_Options)
}

// What a pipe of Output holds before the program writing to it waits (a program that writes more waits for process_output).
OUTPUT_PIPE_BYTES :: 1 << 20
// GetExitCodeProcess of a process that runs.
STILL_ACTIVE :: 259

this_pid :: proc() -> int { return int(win.GetCurrentProcessId()) }

// The identity of the process behind `h` (opened with PROCESS_QUERY_LIMITED_INFORMATION at least). ok false: it cannot be read.
identity_of_handle :: proc(h: win.HANDLE, allocator := context.temp_allocator) -> (id: Identity, ok: bool) {
	c, e, k, u: win.FILETIME
	if !win.GetProcessTimes(h, &c, &e, &k, &u) { return {}, false }
	buf: [1024]u16
	size := win.DWORD(len(buf))
	if !QueryFullProcessImageNameW(h, 0, &buf[0], &size) { return {}, false }
	image, err := win.utf16_to_utf8(buf[:size], allocator)
	if err != nil { return {}, false }
	return {created = u64(c.dwHighDateTime) << 32 | u64(c.dwLowDateTime), image = image}, true
}

identity_of :: proc(p: ^Process, allocator := context.temp_allocator) -> (id: Identity, ok: bool) { return identity_of_handle(p.handle, allocator) }

// Is `now` the process that `recorded` says (same creation time to the tick, same program, as Windows spells paths: case and the
// kind of slash do not tell two programs apart)? A record with no creation time or no program (a session file of an older
// `wren ctl`) names nobody.
same_process :: proc(recorded, now: Identity) -> bool {
	if recorded.created == 0 || recorded.image == "" || recorded.created != now.created { return false }
	a, _ := strings.replace_all(recorded.image, "/", `\`, context.temp_allocator)
	b, _ := strings.replace_all(now.image, "/", `\`, context.temp_allocator)
	return strings.equal_fold(a, b)
}

// Waits for process `pid` to end. `ended` false: still running after `ms`. A process that is already gone has no code to give.
wait_process_exit :: proc(pid: int, ms: int) -> (code: int, ended: bool) {
	if pid <= 0 { return 0, true }
	h := win.OpenProcess(win.SYNCHRONIZE | win.PROCESS_QUERY_LIMITED_INFORMATION, false, win.DWORD(pid))
	if h == nil { return 0, true }
	defer win.CloseHandle(h)
	if win.WaitForSingleObject(h, win.DWORD(ms)) != win.WAIT_OBJECT_0 { return 0, false }
	c: win.DWORD
	win.GetExitCodeProcess(h, &c)
	return int(c), true
}

// What process `pid` is doing, thread by thread (the frames named by its PDB; wb:tools/stacks), for a process that hangs. `minidump`: also
// a dump in that file. ok false: it cannot be read, and `text` says why.
process_stacks :: proc(pid: int, minidump := "") -> (text: string, ok: bool) { return stacks.process_text(pid, minidump) }

@(private)
quote_arg :: proc(s: string) -> string {
	if s != "" && !strings.contains_any(s, " \t\"") { return s }
	return strings.concatenate({`"`, strings.trim_right(s, `\`), `"`}, context.temp_allocator)
}

// Starts `args` (args[0] the program). err "": started.
process_start :: proc(args: []string, o := Start_Options{}) -> (p: Process, pid: int, err: string) {
	line := strings.builder_make(context.temp_allocator)
	for a, i in args { if i > 0 { strings.write_byte(&line, ' ') }; strings.write_string(&line, quote_arg(a)) }
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW)}
	pi: win.PROCESS_INFORMATION
	wline := win.utf8_to_wstring(strings.to_string(line), context.temp_allocator)
	redirected := o.stdout != {} || o.stderr != {} || o.merged
	if redirected {
		si.dwFlags = win.STARTF_USESTDHANDLES
		si.hStdOutput = output_of_child(o.stdout, &p.out)
		si.hStdError = o.merged ? si.hStdOutput : output_of_child(o.stderr, &p.err)
	}
	defer if redirected {
		if si.hStdOutput != nil { win.CloseHandle(si.hStdOutput) }
		if si.hStdError != nil && !o.merged { win.CloseHandle(si.hStdError) }
	}
	flags: win.DWORD
	block: [^]u16
	if o.env != nil { flags |= win.CREATE_UNICODE_ENVIRONMENT; block = environment_block(o.env) }
	cwd: win.LPCWSTR = o.cwd != "" ? win.utf8_to_wstring(o.cwd, context.temp_allocator) : nil
	if !win.CreateProcessW(nil, cstring16(wline), nil, nil, win.BOOL(redirected), flags, block, cwd, &si, &pi) {
		code := win.GetLastError()
		process_release(&p)
		return {}, 0, fmt.tprintf("error %d", code)
	}
	win.CloseHandle(pi.hThread)
	p.handle = pi.hProcess
	return p, int(pi.dwProcessId), ""
}

// The handle a child writes one of its outputs to (nil: it has none); `read` gets the read end of a pipe.
@(private = "file")
output_of_child :: proc(o: Output, read: ^win.HANDLE) -> win.HANDLE {
	sa := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), bInheritHandle = true}
	if o.file != "" {
		h := win.CreateFileW(win.utf8_to_wstring(o.file, context.temp_allocator), win.GENERIC_WRITE, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, &sa, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
		return h != win.INVALID_HANDLE_VALUE ? h : nil
	}
	if !o.pipe { return nil }
	r, w: win.HANDLE
	if !win.CreatePipe(&r, &w, &sa, OUTPUT_PIPE_BYTES) { return nil }
	win.SetHandleInformation(r, win.HANDLE_FLAG_INHERIT, 0)
	read^ = r
	return w
}

// This process's environment with `over` on it: UTF-16, each "NAME=value" ended by a zero, a zero at the end.
@(private = "file")
environment_block :: proc(over: []string) -> [^]u16 {
	b := strings.builder_make(context.temp_allocator)
	name_of :: proc(v: string) -> string { i := strings.index_byte(v[1:], '='); return i < 0 ? v : v[:i + 1] }   // (a name of the system's may begin with =)
	vars, _ := os.environ(context.temp_allocator)
	outer: for v in vars {
		for n in over { if strings.equal_fold(name_of(v), name_of(n)) { continue outer } }
		strings.write_string(&b, v); strings.write_byte(&b, 0)
	}
	for n in over { if !strings.has_suffix(n, "=") { strings.write_string(&b, n); strings.write_byte(&b, 0) } }
	strings.write_byte(&b, 0)
	return raw_data(win.utf8_to_utf16(strings.to_string(b), context.temp_allocator))
}

// What the program wrote to its pipes since the last look, without waiting (the program may go on, and what it started may hold the pipes for ever).
process_output :: proc(p: ^Process, allocator := context.temp_allocator) -> (out, err: string) {
	drain :: proc(pipe: win.HANDLE, allocator := context.allocator) -> string {
		if pipe == nil { return "" }
		b := strings.builder_make(allocator)
		for {
			there: win.DWORD
			if !win.PeekNamedPipe(pipe, nil, 0, nil, &there, nil) || there == 0 { break }
			chunk := make([]byte, there, context.temp_allocator)
			n: win.DWORD
			if !win.ReadFile(pipe, raw_data(chunk), there, &n, nil) || n == 0 { break }
			strings.write_bytes(&b, chunk[:n])
		}
		return strings.to_string(b)
	}
	return drain(p.out, allocator), drain(p.err, allocator)
}

// A handle to process `pid`, to wait for it and end it (false: it is gone, or not ours to open).
process_open :: proc(pid: int) -> (Process, bool) {
	if pid <= 0 { return {}, false }
	h := win.OpenProcess(win.PROCESS_TERMINATE | win.SYNCHRONIZE | win.PROCESS_QUERY_LIMITED_INFORMATION, false, win.DWORD(pid))
	return {handle = h}, h != nil
}

process_alive :: proc(p: ^Process) -> bool { return win.WaitForSingleObject(p.handle, 0) == win.WAIT_TIMEOUT }

// Has it been ended, even if it has not left the system yet? A process killed while it holds a graphics device has its exit code at once, and is
// on the list of processes for seconds more, while the system lets go of the device.
process_ended :: proc(p: ^Process) -> bool {
	c: win.DWORD
	return bool(win.GetExitCodeProcess(p.handle, &c)) && c != STILL_ACTIVE
}

// The time it has spent on the processors (ms).
process_cpu_ms :: proc(p: ^Process) -> f64 {
	c, e, k, u: win.FILETIME
	if !win.GetProcessTimes(p.handle, &c, &e, &k, &u) { return 0 }
	ticks :: proc(t: win.FILETIME) -> f64 { return f64(u64(t.dwHighDateTime) << 32 | u64(t.dwLowDateTime)) }
	return (ticks(k) + ticks(u)) / FILETIME_TICKS_PER_MS
}
@(private = "file") FILETIME_TICKS_PER_MS :: 10_000.0

// True once it has ended (within `ms`).
process_wait :: proc(p: ^Process, ms: int) -> bool { return win.WaitForSingleObject(p.handle, win.DWORD(ms)) == win.WAIT_OBJECT_0 }

process_kill :: proc(p: ^Process) { win.TerminateProcess(p.handle, 1) }

process_release :: proc(p: ^Process) {
	if p.handle != nil { win.CloseHandle(p.handle) }
	if p.out != nil { win.CloseHandle(p.out) }
	if p.err != nil { win.CloseHandle(p.err) }
	p^ = {}
}

// Lets the process go on alone (a session `wren ctl stop` ends later).
process_detach :: proc(p: ^Process) { process_release(p) }

// The exit code of a process that has ended (process_wait said so).
process_exit_code :: proc(p: ^Process) -> int {
	c: win.DWORD
	if !win.GetExitCodeProcess(p.handle, &c) { return -1 }
	return int(c)
}
