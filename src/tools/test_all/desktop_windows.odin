#+build windows
package test_all

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "wb:tools/stacks"
import "wb:tools/tooling"

// The run runs itself again on a Windows desktop of its own, which nobody looks at: everything it starts stays there. What a step opens cannot take the focus, the mouse or the keyboard of the
// person at the machine, whatever it does, and their clicks cannot reach it. (Real input of the machine goes nowhere there: what needs one is -Ui.) What the run prints comes through a file: a console does
// not cross desktops. The inner run is in a job of this process: this one killed, it dies, and all it started.

@(private = "file") ON_DESKTOP_VAR :: "WREN_ON_TEST_DESKTOP"
@(private = "file") DESKTOP_RIGHTS :: 0x10000000   // GENERIC_ALL
@(private = "file") POLL_MS :: 100                 // how often what it printed is passed on
@(private = "file") READ_BYTES :: 16 * 1024
@(private = "file") USAGE_EXIT :: 2

foreign import user32_desktop "system:User32.lib"
@(default_calling_convention = "system", private = "file")
foreign user32_desktop {
	CreateDesktopW :: proc(name, device: win.LPCWSTR, mode: rawptr, flags, access: u32, attrs: rawptr) -> win.HANDLE ---
	CloseDesktop :: proc(desktop: win.HANDLE) -> win.BOOL ---
}

// True: the run happened on the other desktop, and `code` is its exit code. False: this is the run (already there, or no desktop can be made).
on_own_desktop :: proc(code: ^int) -> bool {
	if env_set(ON_DESKTOP_VAR) { return false }
	name := fmt.tprintf("WrenTests-%d", os.get_pid())
	desktop := CreateDesktopW(win.utf8_to_wstring(name, context.temp_allocator), nil, nil, 0, DESKTOP_RIGHTS, nil)
	if desktop == nil { return false }
	defer CloseDesktop(desktop)

	output := fmt.tprintf("%s/wren_test_desktop_%d.txt", TEMP_DIR, os.get_pid())
	sa := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), bInheritHandle = true}
	share := win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE
	file := win.CreateFileW(win.utf8_to_wstring(output, context.temp_allocator), win.GENERIC_WRITE, share, &sa, win.CREATE_ALWAYS, 0, nil)
	if file == win.INVALID_HANDLE_VALUE { return false }
	defer os.remove(output)

	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW), dwFlags = win.STARTF_USESTDHANDLES, hStdOutput = file, hStdError = file}
	where_ := fmt.tprintf("WinSta0\\%s", name)
	si.lpDesktop = (^u16)(win.utf8_to_wstring(where_, context.temp_allocator))
	exe_path, _ := os.get_executable_path(context.temp_allocator)
	line := strings.builder_make(context.temp_allocator)
	tooling.quote_argument(&line, exe_path)
	for a in os.args[1:] {
		strings.write_byte(&line, ' ')
		tooling.quote_argument(&line, a)
	}
	os.set_env(ON_DESKTOP_VAR, "1")
	pi: win.PROCESS_INFORMATION
	if !win.CreateProcessW(nil, win.utf8_to_wstring(strings.to_string(line), context.temp_allocator), nil, nil, true, win.CREATE_SUSPENDED, nil, nil, &si, &pi) {
		win.CloseHandle(file)
		fmt.eprintln("test_all: no process on its own desktop")
		code^ = USAGE_EXIT
		return true
	}
	win.CloseHandle(file)
	defer win.CloseHandle(pi.hProcess)
	defer win.CloseHandle(pi.hThread)
	job := tooling.hold_process(pi.hProcess)
	defer if job != nil { win.CloseHandle(job) }
	win.ResumeThread(pi.hThread)

	reader, rerr := os.open(output)
	buf: [READ_BYTES]u8
	for {
		done := win.WaitForSingleObject(pi.hProcess, POLL_MS) == win.WAIT_OBJECT_0
		if rerr == nil {
			for {
				n, _ := os.read(reader, buf[:])
				if n <= 0 { break }
				os.write(os.stdout, buf[:n])
			}
		}
		if done { break }
	}
	if rerr == nil { os.close(reader) }
	exit: u32
	win.GetExitCodeProcess(pi.hProcess, &exit)
	code^ = int(exit)
	return true
}

// What the threads of a process are doing (the code of `wren ctl stacks`).
process_stacks_text :: proc(pid: int) -> string {
	text, ok := stacks.process_text(pid)
	if !ok { return fmt.tprintfln("process %d: its stacks cannot be read", pid) }
	return fmt.tprintfln("what process %d is doing:\n%s", pid, text)
}

// A Wren left by a run that was stopped holds build/wren.exe against every build: said at the start.
warn_programs_running :: proc() {
	TH32CS_SNAPPROCESS :: 2
	snapshot := win.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
	if snapshot == win.INVALID_HANDLE_VALUE { return }
	defer win.CloseHandle(snapshot)
	build_dir := here("build")
	entry := win.PROCESSENTRY32W{dwSize = size_of(win.PROCESSENTRY32W)}
	for ok := win.Process32FirstW(snapshot, &entry); ok; ok = win.Process32NextW(snapshot, &entry) {
		name, _ := win.wstring_to_utf8(win.wstring(&entry.szExeFile[0]), -1, context.temp_allocator)
		if !strings.has_prefix(strings.to_lower(name, context.temp_allocator), "wren") { continue }
		process := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, false, entry.th32ProcessID)
		if process == nil { continue }
		defer win.CloseHandle(process)
		text := tooling.process_image_path(process)
		if strings.has_prefix(strings.to_lower(text, context.temp_allocator), strings.to_lower(build_dir, context.temp_allocator)) {
			fmt.printfln("warning: %s (pid %d) runs from this worktree's build folder: a build of the browser cannot replace it", name, entry.th32ProcessID)
		}
	}
}

// The emoji font and Unicode's emoji data (the toolkit's tests/colr skip without them), before the steps start. The toolkit's own script, pinned by commit and SHA-256: once on a machine.
fetch_emoji_when_missing :: proc() {
	if os.exists("build/emoji/NotoColorEmoji-COLRv1.ttf") && os.exists("build/emoji/emoji-test.txt") && os.exists("build/emoji/emoji-data.txt") { return }
	_ = tooling.run({command = {"powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "tools/fetch_emoji.ps1", "-Unicode"}, log = fmt.tprintf("%s/fetch_emoji.log", LOG_DIR)})
}
