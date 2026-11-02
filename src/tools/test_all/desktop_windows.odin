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

// (tooling.on_own_desktop: what a tool that opens a window shares)
on_own_desktop :: proc(code: ^int) -> bool { return tooling.on_own_desktop(code, TEMP_DIR) }

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
	_ = tooling.run({command = {"powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "ext/gui_toolkit/tools/fetch_emoji.ps1", "-Dest", "build/emoji", "-Unicode"}, log = fmt.tprintf("%s/fetch_emoji.log", LOG_DIR)})
}
