package wrencom

// What wren.com does with its command line, as plain functions (the Windows calls are in main.odin).
//
// wren.exe is a program with a window. Run from cmd or PowerShell it gives the prompt back at once and, having no
// console of its own, cannot hand a script its output or its exit code. wren.com sits beside it: cmd and PowerShell
// find `wren.com` before `wren.exe` when someone types `wren`, so the launcher is what runs. It starts wren.exe with
// the same arguments, and
//   * for a console command (`wren ctl ...`, `--desktop-integration`, or anything given `--cli`) waits for it, hands it
//     its own standard input, output and error (so `> file`, `| more` and `2>&1` work) and ends with its exit code;
//   * for anything else (an address, an option of the window) lets go of it and gives the prompt back, as a program with
//     a window should.
// It knows nothing else of Wren: this file and main.odin import only the core library.

import "core:strings"

// Said in every message of the launcher: Setup tells its own wren.com from a file of the same name by this text
// (package desktop, LAUNCHER_MARK). Keep the two equal.
MARK :: "(Wren console launcher)"

Mode :: enum u8 {
	Detach,   // start wren.exe and return: the interface
	Wait,     // start wren.exe, wait for it and return its exit code: a console command
}

Plan :: struct {
	mode: Mode,
	args: []string,   // what wren.exe is given (the launcher's own `--cli` is not)
}

// `--cli` anywhere makes the launcher wait whatever the rest is; it is the launcher's, wren.exe never sees it.
CLI_FLAG :: "--cli"

// The console commands of wren.exe, as it reads them (browser/main.odin): `ctl` as the first argument, and the flag of
// the integration (`--desktop-integration=install|remove|status`, or the flag and its value as two arguments), which
// main.odin looks for anywhere in the line.
console_command :: proc(args: []string) -> bool {
	if len(args) > 0 && args[0] == "ctl" { return true }
	for a in args {
		if a == "--desktop-integration" || strings.has_prefix(a, "--desktop-integration=") { return true }
	}
	return false
}

// Wait or detach, and the arguments for wren.exe.
decide :: proc(args: []string, allocator := context.temp_allocator) -> Plan {
	kept := make([dynamic]string, 0, len(args), allocator)
	forced := false
	for a in args {
		if a == CLI_FLAG { forced = true } else { append(&kept, a) }
	}
	return Plan{mode = forced || console_command(kept[:]) ? .Wait : .Detach, args = kept[:]}
}

// wren.exe beside the launcher: `<dir>\wren.com` -> `<dir>\wren.exe`. ok false when the launcher is not a `.com` (it was
// renamed `.exe`, so the name it would start is its own: it would start itself without end).
target_of :: proc(self: string, allocator := context.temp_allocator) -> (target: string, ok: bool) {
	dot := strings.last_index_byte(self, '.')
	slash := max(strings.last_index_byte(self, '\\'), strings.last_index_byte(self, '/'))
	if dot <= slash + 1 || !strings.equal_fold(self[dot:], ".com") { return "", false }
	return strings.concatenate({self[:dot], ".exe"}, allocator), true
}

// One argument as CommandLineToArgvW (and the C runtime) read it back: quotes around what needs them, a backslash
// doubled only where a quote follows.
quote_arg :: proc(a: string, allocator := context.temp_allocator) -> string {
	if a != "" && !strings.contains_any(a, " \t\n\v\"") { return a }
	sb := strings.builder_make(allocator)
	strings.write_byte(&sb, '"')
	backslashes := 0
	for c in transmute([]byte)a {
		switch c {
		case '\\':
			backslashes += 1
		case '"':
			for _ in 0 ..< backslashes * 2 + 1 { strings.write_byte(&sb, '\\') }
			strings.write_byte(&sb, '"')
			backslashes = 0
		case:
			for _ in 0 ..< backslashes { strings.write_byte(&sb, '\\') }
			backslashes = 0
			strings.write_byte(&sb, c)
		}
	}
	for _ in 0 ..< backslashes * 2 { strings.write_byte(&sb, '\\') }   // (before the closing quote)
	strings.write_byte(&sb, '"')
	return strings.to_string(sb)
}

// The command line that starts `exe` with `args`.
command_line :: proc(exe: string, args: []string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, quote_arg(exe, allocator))
	for a in args {
		strings.write_byte(&sb, ' ')
		strings.write_string(&sb, quote_arg(a, allocator))
	}
	return strings.to_string(sb)
}
