package wrencom

import "core:testing"
import win "core:sys/windows"

@(private = "file")
expect_plan :: proc(t: ^testing.T, args: []string, mode: Mode, forwarded: []string) {
	p := decide(args)
	testing.expectf(t, p.mode == mode, "%v: mode %v, want %v", args, p.mode, mode)
	testing.expectf(t, len(p.args) == len(forwarded), "%v: forwarded %v, want %v", args, p.args, forwarded)
	if len(p.args) == len(forwarded) {
		for a, i in forwarded { testing.expectf(t, p.args[i] == a, "%v: forwarded %v, want %v", args, p.args, forwarded) }
	}
}

@(test)
interface_detaches :: proc(t: ^testing.T) {
	expect_plan(t, {}, .Detach, {})
	expect_plan(t, {"https://example.org/"}, .Detach, {"https://example.org/"})
	expect_plan(t, {"--new-window", "a.html", "b.html"}, .Detach, {"--new-window", "a.html", "b.html"})
	expect_plan(t, {"--setup"}, .Detach, {"--setup"})
	expect_plan(t, {"--profile", "p", "--pref", "x=y"}, .Detach, {"--profile", "p", "--pref", "x=y"})
}

@(test)
ctl_waits :: proc(t: ^testing.T) {
	expect_plan(t, {"ctl"}, .Wait, {"ctl"})
	expect_plan(t, {"ctl", "help"}, .Wait, {"ctl", "help"})
	expect_plan(t, {"ctl", "run", "--shot", "o.png", "https://a/"}, .Wait, {"ctl", "run", "--shot", "o.png", "https://a/"})
}

@(test)
ctl_is_a_command_only_first :: proc(t: ^testing.T) {
	// as wren.exe reads it: after an option it is an address (it answers with a message, and the window does not open)
	expect_plan(t, {"--new-window", "ctl"}, .Detach, {"--new-window", "ctl"})
	// the version and the usage are console commands too: the words as the first argument, the flags anywhere
	expect_plan(t, {"version"}, .Wait, {"version"})
	expect_plan(t, {"help"}, .Wait, {"help"})
	expect_plan(t, {"--version"}, .Wait, {"--version"})
	expect_plan(t, {"-V"}, .Wait, {"-V"})
	expect_plan(t, {"--profile", "p", "--help"}, .Wait, {"--profile", "p", "--help"})
	expect_plan(t, {"-h"}, .Wait, {"-h"})
	expect_plan(t, {"-?"}, .Wait, {"-?"})
	expect_plan(t, {"--new-window", "help"}, .Detach, {"--new-window", "help"})
	expect_plan(t, {"./help"}, .Detach, {"./help"})
	expect_plan(t, {"./ctl"}, .Detach, {"./ctl"})
	expect_plan(t, {"ctl.example"}, .Detach, {"ctl.example"})
}

@(test)
integration_flag_waits :: proc(t: ^testing.T) {
	expect_plan(t, {"--desktop-integration=status"}, .Wait, {"--desktop-integration=status"})
	expect_plan(t, {"--desktop-integration", "remove"}, .Wait, {"--desktop-integration", "remove"})
	expect_plan(t, {"--profile", "p", "--desktop-integration=install"}, .Wait, {"--profile", "p", "--desktop-integration=install"})
	expect_plan(t, {"--desktop-integrations"}, .Detach, {"--desktop-integrations"})
}

@(test)
cli_flag_forces_the_wait_and_is_not_forwarded :: proc(t: ^testing.T) {
	expect_plan(t, {"--cli"}, .Wait, {})
	expect_plan(t, {"--cli", "https://example.org/"}, .Wait, {"https://example.org/"})
	expect_plan(t, {"https://example.org/", "--cli"}, .Wait, {"https://example.org/"})
	expect_plan(t, {"--cli", "ctl", "help"}, .Wait, {"ctl", "help"})   // (ctl is the first argument wren.exe sees)
}

@(test)
target_is_the_exe_beside_the_com :: proc(t: ^testing.T) {
	p, ok := target_of(`C:\Users\a b\Programs\Wren\wren.com`)
	testing.expect(t, ok)
	testing.expect_value(t, p, `C:\Users\a b\Programs\Wren\wren.exe`)
	p, ok = target_of(`D:\x\WREN.COM`)
	testing.expect(t, ok)
	testing.expect_value(t, p, `D:\x\WREN.exe`)
	_, ok = target_of(`C:\x\wren.exe`)
	testing.expect(t, !ok, "an .exe would start itself")
	_, ok = target_of(`C:\x.y\wren`)
	testing.expect(t, !ok, "no extension")
	_, ok = target_of(`C:\x\.com`)
	testing.expect(t, !ok, "no name")
}

// The command line is read back by CommandLineToArgvW, as wren.exe reads its own.
@(test)
command_line_round_trips :: proc(t: ^testing.T) {
	cases := [?][]string{
		{},
		{"ctl", "help"},
		{"plain", "with space", "", "quo\"te", `back\slash`, `trailing\`, `trailing space\ `, `q\"uote`, `\\"x`, "tab\tx", `C:\Program Files\Wren\`, "é 日本"},
	}
	exe := `C:\Program Files\Wren\wren.exe`
	for args in cases {
		line := command_line(exe, args)
		argc: win.c_int
		argv := CommandLineToArgvW(win.utf8_to_wstring(line, context.temp_allocator), &argc)
		testing.expect(t, argv != nil)
		if argv == nil { continue }
		defer win.LocalFree(rawptr(argv))
		testing.expect_value(t, int(argc), len(args) + 1)
		if int(argc) != len(args) + 1 { continue }
		for i in 0 ..< int(argc) {
			s, _ := win.wstring_to_utf8(win.wstring(argv[i]), -1, context.temp_allocator)
			want := i == 0 ? exe : args[i - 1]
			testing.expectf(t, s == want, "argument %d: %q, want %q (line %s)", i, s, want, line)
		}
	}
}
