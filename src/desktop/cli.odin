package desktop

// The command line of the integration, for an uninstall script and for tests:
//
//     wren --desktop-integration=install|remove|status        (also: --desktop-integration install)
//
// The program does its job and exits without opening a window. Exit codes:
//     install, remove   0 done, 1 failed (the message says what)
//     status            0 installed, 1 absent, 2 to repair (incomplete, or it runs another executable), 3 unreadable
// The word on the first output line is the state (installed, absent, "to repair: ..."), one line per part follows.
//
// A program built for the Windows GUI subsystem has no console of its own: the output goes to the standard output when
// it is redirected or piped (the Windows way to read it from a script), else to the console of the parent.

import "core:fmt"
import "core:strings"

Cli_Mode :: enum u8 { None, Install, Remove, Status }

CLI_FLAG :: "--desktop-integration"

// Takes the flag out of the arguments. `bad` is the value when it names no mode (the caller says so and exits).
parse_cli :: proc(args: []string, allocator := context.temp_allocator) -> (mode: Cli_Mode, rest: [dynamic]string, bad: string) {
	rest = make([dynamic]string, allocator)
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		value := ""
		switch {
		case a == CLI_FLAG && i + 1 < len(args): value = args[i + 1]; i += 1
		case strings.has_prefix(a, CLI_FLAG + "="): value = a[len(CLI_FLAG) + 1:]
		case: append(&rest, a); continue
		}
		switch value {
		case "install": mode = .Install
		case "remove":  mode = .Remove
		case "status":  mode = .Status
		case:           bad = value
		}
	}
	return
}

// The roots a test (or a script that wants a dry run in a scratch place) sets in the environment. Any of them given
// also turns the system notification off: nothing outside the scratch roots is told anything.
//     WREN_DESKTOP_MENU_DIR          WREN_DESKTOP_REGISTRY_ROOT     (Windows)
//     WREN_DESKTOP_APPLICATIONS_DIR  WREN_DESKTOP_ICONS_DIR         (Linux)
roots_from_env :: proc(o: ^Options, lookup: proc(name: string) -> string) {
	scratch := false
	set :: proc(dst: ^string, v: string, scratch: ^bool) { if v != "" { dst^ = v; scratch^ = true } }
	set(&o.menu_dir, lookup("WREN_DESKTOP_MENU_DIR"), &scratch)
	set(&o.registry_root, lookup("WREN_DESKTOP_REGISTRY_ROOT"), &scratch)
	set(&o.applications_dir, lookup("WREN_DESKTOP_APPLICATIONS_DIR"), &scratch)
	set(&o.icons_dir, lookup("WREN_DESKTOP_ICONS_DIR"), &scratch)
	if scratch { o.notify_system = false }
}

// Runs `mode`, writing its report with `out`. Returns the exit code.
cli_run :: proc(mode: Cli_Mode, o: ^Options, out: proc(text: string)) -> int {
	switch mode {
	case .None: return 0
	case .Install:
		if r := install(o); r.error != .None {
			out(fmt.tprintf("install failed: %s (%s)\n", error_text(r.error), r.detail))
			return 1
		}
		out("installed\n")
		return 0
	case .Remove:
		if r := remove(o); r.error != .None {
			out(fmt.tprintf("remove failed: %s (%s)\n", error_text(r.error), r.detail))
			return 1
		}
		out("removed\n")
		return 0
	case .Status:
		s := status(o, context.temp_allocator)
		if s.error != .None { out(fmt.tprintf("unreadable: %s\n", error_text(s.error))); return 3 }
		out(fmt.tprintf("%s\n", describe(&s)))
		for p in Part {
			if p not_in s.wanted && !s.parts[p].present { continue }
			ps := s.parts[p]
			out(fmt.tprintf("  %v: %s%s%s\n", p, ps.present ? "present" : "missing", ps.partial ? " (incomplete)" : "", ps.target != "" ? fmt.tprintf(" -> %s", ps.target) : ""))
		}
		switch s.state {
		case .Installed: return 0
		case .Absent:    return 1
		case .Repair:    return 2
		}
	}
	return 0
}
