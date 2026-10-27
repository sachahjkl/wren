#+build windows
package client

// The processes of spawn.odin on Windows: a process handle (CreateProcessW, OpenProcess), told again by its creation time
// and image path.

import "core:fmt"
import "core:strings"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	QueryFullProcessImageNameW :: proc(hProcess: win.HANDLE, dwFlags: win.DWORD, lpExeName: win.LPWSTR, lpdwSize: ^win.DWORD) -> win.BOOL ---
}

Process :: struct { handle: win.HANDLE }

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

@(private)
quote_arg :: proc(s: string) -> string {
	if s != "" && !strings.contains_any(s, " \t\"") { return s }
	return strings.concatenate({`"`, strings.trim_right(s, `\`), `"`}, context.temp_allocator)
}

// Starts `args` (args[0] the program). err "": started.
process_start :: proc(args: []string) -> (p: Process, pid: int, err: string) {
	line := strings.builder_make(context.temp_allocator)
	for a, i in args { if i > 0 { strings.write_byte(&line, ' ') }; strings.write_string(&line, quote_arg(a)) }
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW)}
	pi: win.PROCESS_INFORMATION
	wline := win.utf8_to_wstring(strings.to_string(line), context.temp_allocator)
	if !win.CreateProcessW(nil, cstring16(wline), nil, nil, false, 0, nil, nil, &si, &pi) {
		return {}, 0, fmt.tprintf("error %d", win.GetLastError())
	}
	win.CloseHandle(pi.hThread)
	return {pi.hProcess}, int(pi.dwProcessId), ""
}

// A handle to process `pid`, to wait for it and end it (false: it is gone, or not ours to open).
process_open :: proc(pid: int) -> (Process, bool) {
	if pid <= 0 { return {}, false }
	h := win.OpenProcess(win.PROCESS_TERMINATE | win.SYNCHRONIZE | win.PROCESS_QUERY_LIMITED_INFORMATION, false, win.DWORD(pid))
	return {h}, h != nil
}

process_alive :: proc(p: ^Process) -> bool { return win.WaitForSingleObject(p.handle, 0) == win.WAIT_TIMEOUT }

// True once it has ended (within `ms`).
process_wait :: proc(p: ^Process, ms: int) -> bool { return win.WaitForSingleObject(p.handle, win.DWORD(ms)) == win.WAIT_OBJECT_0 }

process_kill :: proc(p: ^Process) { win.TerminateProcess(p.handle, 1) }

process_release :: proc(p: ^Process) {
	if p.handle != nil { win.CloseHandle(p.handle) }
	p^ = {}
}

// Lets the process go on alone (a session `wren ctl stop` ends later).
process_detach :: proc(p: ^Process) { process_release(p) }
