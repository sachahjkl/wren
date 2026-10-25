package desktop

// The console launcher, `wren.com`: a small console program that Setup writes beside wren.exe when "Add Wren to PATH" is
// on and takes away when it is off (and when the installation goes). It exists because wren.exe is a program with a
// window: from cmd or PowerShell it gives the prompt back at once and has no console of its own, so a script gets
// neither its output nor its exit code. cmd.exe and PowerShell prefer `wren.com` to `wren.exe` when `wren` is typed, and
// the launcher (src/tools/wrencom) starts wren.exe, waits for a console command (`wren ctl ...`) and gives its output and
// code through; for the interface it lets go at once.
//
// The program ships inside wren.exe (the shell passes its bytes in `Options.launcher`: the release stays one file) and is
// written only next to the executable of an integration whose PATH part is on: never in another folder, never without
// the PATH entry that makes it reachable. Removal deletes only a file that carries the launcher's mark.

import "core:os"
import "core:strings"

// Said by every message of the launcher (src/tools/wrencom/plan.odin, MARK), so that a file of the same name made by
// something else is told from it. Keep the two equal.
LAUNCHER_MARK :: "(Wren console launcher)"

@(private = "file") LAUNCHER_MAX_BYTES :: 16 << 20   // (a file larger than any launcher is not read to be searched)

// `<dir>\<stem>.com` for the executable `<dir>\<stem>.exe`; "" where there is no such thing (not Windows) or `exe` has no
// extension.
launcher_file :: proc(exe: string, allocator := context.temp_allocator) -> string {
	when ODIN_OS != .Windows { return "" }
	slash := max(strings.last_index_byte(exe, '\\'), strings.last_index_byte(exe, '/'))
	dot := strings.last_index_byte(exe, '.')
	if dot <= slash + 1 { return "" }
	return strings.concatenate({exe[:dot], ".com"}, allocator)
}

// Is the file at `path` a launcher of ours (it carries the mark)?
launcher_is_ours :: proc(path: string) -> bool {
	if path == "" || !os.is_file(path) { return false }
	if info, err := os.stat(path, context.temp_allocator); err != nil || info.size <= 0 || info.size > LAUNCHER_MAX_BYTES { return false }
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil && strings.contains(string(data), LAUNCHER_MARK)
}

// Is there a launcher of ours beside the executable of these options?
launcher_current :: proc(o: ^Options) -> bool {
	return launcher_is_ours(launcher_file(o.exe))
}

// Writes the launcher beside `o.exe`, unless the options carry none. A file that is not the launcher's (no mark) is never
// replaced. One that is the same bytes is left alone (it may be running); another version is renamed aside and replaced,
// as a running program's file can be renamed, not overwritten.
launcher_write :: proc(o: ^Options) -> Result {
	if len(o.launcher) == 0 { return {} }
	path := launcher_file(o.exe)
	if path == "" { return {} }
	had := os.exists(path)
	if had {
		if !launcher_is_ours(path) {
			return {.Io, strings.concatenate({path, " exists and is not Wren's console launcher: it is left as it is, so `wren ctl` from a terminal is not set up"}, context.temp_allocator)}
		}
		if same, err := os.read_entire_file(path, context.temp_allocator); err == nil && string(same) == string(o.launcher) { return {} }
	}
	fresh := strings.concatenate({path, ".new"}, context.temp_allocator)
	old := strings.concatenate({path, OLD_SUFFIX}, context.temp_allocator)
	if err := os.write_entire_file(fresh, o.launcher); err != nil {
		_ = os.remove(fresh)
		return {.Io, strings.concatenate({"cannot write ", fresh}, context.temp_allocator)}
	}
	if had {
		_ = os.remove(old)
		if err := os.rename(path, old); err != nil {
			_ = os.remove(fresh)
			return {.Io, strings.concatenate({"cannot move ", path, " aside (is it running?)"}, context.temp_allocator)}
		}
	}
	if err := os.rename(fresh, path); err != nil {
		_ = os.remove(fresh)
		if had { _ = os.rename(old, path) }
		return {.Io, strings.concatenate({"cannot write ", path}, context.temp_allocator)}
	}
	if had { _ = os.remove(old) }   // (a running launcher holds it: the next write or removal gets it)
	return {}
}

// Deletes the launcher beside `exe` when it is ours (and the `.old` a replacement left). One that runs now cannot be
// deleted: it is renamed aside so that the name is free, and the next removal gets it.
launcher_remove :: proc(exe: string) -> Result {
	path := launcher_file(exe)
	if path == "" { return {} }
	old := strings.concatenate({path, OLD_SUFFIX}, context.temp_allocator)
	if launcher_is_ours(old) { _ = os.remove(old) }
	if !launcher_is_ours(path) { return {} }
	if err := os.remove(path); err != nil {
		_ = os.remove(old)
		if os.rename(path, old) != nil { return {.Io, strings.concatenate({"cannot delete ", path}, context.temp_allocator)} }
	}
	return {}
}
