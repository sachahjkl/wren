package desktop

import "core:strings"
import "core:testing"

@(private = "file")
test_identity :: proc() -> Identity {
	return Identity{name = "Wren", key = "Wren", slug = "wren", aumid = "FromentSoftware.Wren", description = "A small browser where WebAssembly runs everything.", vendor = "Froment Software"}
}

@(test)
desktop_entry_exact_text :: proc(t: ^testing.T) {
	o := Options{identity = test_identity(), exe = "/home/u/bin/wren", register_browser = true, file_types = {".html", ".htm", "svg", ".webp"}}
	want := `[Desktop Entry]
Type=Application
Version=1.0
Name=Wren
GenericName=Web Browser
Comment=A small browser where WebAssembly runs everything.
Exec=/home/u/bin/wren %U
TryExec=/home/u/bin/wren
Icon=wren
Terminal=false
StartupNotify=true
Categories=Network;WebBrowser;
Keywords=Internet;WWW;Browser;Web;WebAssembly;
MimeType=x-scheme-handler/http;x-scheme-handler/https;text/html;image/svg+xml;image/webp;
X-Wren-Integration=wren
`
	testing.expect_value(t, desktop_entry_text(&o), want)
}

@(test)
desktop_entry_without_browser_registration :: proc(t: ^testing.T) {
	o := Options{identity = test_identity(), exe = "/opt/wren/wren", register_browser = false}
	text := desktop_entry_text(&o)
	testing.expect(t, !strings.contains(text, "MimeType"), "no MimeType when the program is not registered as a browser")
	testing.expect(t, strings.contains(text, "Categories=Network;WebBrowser;\n"), "it is still in the browsers' category")
	v, ok := entry_value(text, ENTRY_MARKER)
	testing.expect(t, ok && v == "wren", "marker")
}

@(test)
exec_quoting_follows_the_specification :: proc(t: ^testing.T) {
	// no reserved character: as is
	testing.expect_value(t, quote_exec_argument("/usr/bin/wren"), "/usr/bin/wren")
	// a space puts it in double quotes
	testing.expect_value(t, quote_exec_argument("/home/a b/wren"), `"/home/a b/wren"`)
	// inside quotes: backslash, double quote, dollar and backtick are escaped; % is always doubled
	testing.expect_value(t, quote_exec_argument("/h/a b/$x`y\"z\\w%"), `"/h/a b/\$x\` + "`" + `y\"z\\w%%"`)
	testing.expect_value(t, quote_exec_argument("100%"), "100%%")

	// the file's string escape comes after: every backslash doubles again
	o := Options{identity = test_identity(), exe = `/h/a b/q"r`}
	text := desktop_entry_text(&o)
	exec, _ := entry_value(text, "Exec")
	testing.expect_value(t, exec, `"/h/a b/q\\"r" %U`)
	// ... and reading it back gives the path
	testing.expect_value(t, exec_program(exec), `/h/a b/q"r`)
}

@(test)
exec_program_reads_both_forms :: proc(t: ^testing.T) {
	testing.expect_value(t, exec_program("/usr/bin/wren %U"), "/usr/bin/wren")
	testing.expect_value(t, exec_program(`"/home/a b/wren" %U`), "/home/a b/wren")
	testing.expect_value(t, exec_program(`  "/x/y" --flag`), "/x/y")
	testing.expect_value(t, exec_program("/p/100%% %U"), "/p/100%")
	testing.expect_value(t, exec_program(""), "")
}

@(test)
entry_value_reads_the_main_group_only :: proc(t: ^testing.T) {
	text := "# comment\r\n[Desktop Entry]\r\nName=Wren\r\nName[fr]=Moineau\r\nExec = /x/wren %U\r\n\r\n[Desktop Action new]\r\nName=Other\r\nExec=/not/this\r\n"
	v, ok := entry_value(text, "Name")
	testing.expect(t, ok && v == "Wren", "the unlocalized key of the main group")
	v, ok = entry_value(text, "Exec")
	testing.expect(t, ok && v == "/x/wren %U", "spaces around =")
	_, ok = entry_value(text, "Missing")
	testing.expect(t, !ok, "absent key")
	// the action's group is not read as the main one
	text2 := "[Desktop Action new]\nExec=/not/this\n[Desktop Entry]\nExec=/this\n"
	v, _ = entry_value(text2, "Exec")
	testing.expect_value(t, v, "/this")
}

@(test)
string_value_escapes_round_trip :: proc(t: ^testing.T) {
	s := "a\\b\nc\td"
	testing.expect_value(t, escape_value(s), `a\\b\nc\td`)
	testing.expect_value(t, unescape_value(escape_value(s)), s)
	testing.expect_value(t, unescape_value(`a\sb`), "a b")
}

@(test)
mime_types_of_file_types :: proc(t: ^testing.T) {
	m := mime_types({".html", ".HTM", "xhtml", ".nope", ""})
	testing.expect_value(t, len(m), 4)
	testing.expect_value(t, m[0], "x-scheme-handler/http")
	testing.expect_value(t, m[1], "x-scheme-handler/https")
	testing.expect_value(t, m[2], "text/html")
	testing.expect_value(t, m[3], "application/xhtml+xml")
	testing.expect_value(t, len(mime_types({})), 2)
}

@(test)
classify_states :: proc(t: ^testing.T) {
	both := Parts{.Launcher, .Registration}
	s: Status
	classify(&s, both)
	testing.expect_value(t, s.state, State.Absent)

	s = {}
	s.parts[.Launcher] = {present = true}
	s.parts[.Registration] = {present = true}
	classify(&s, both)
	testing.expect_value(t, s.state, State.Installed)

	// one part missing: to repair, incomplete
	s = {}
	s.parts[.Launcher] = {present = true}
	classify(&s, both)
	testing.expect_value(t, s.state, State.Repair)
	testing.expect(t, s.incomplete, "incomplete")
	// ... but not when that part is not wanted
	classify(&s, Parts{.Launcher})
	testing.expect_value(t, s.state, State.Installed)

	// a part with a missing piece
	s = {}
	s.parts[.Launcher] = {present = true}
	s.parts[.Registration] = {present = true, partial = true}
	classify(&s, both)
	testing.expect_value(t, s.state, State.Repair)

	// pointing elsewhere
	s = {}
	s.parts[.Launcher] = {present = true, stale = true, target = strings.clone("C:\\old\\wren.exe")}
	s.parts[.Registration] = {present = true}
	classify(&s, both)
	testing.expect_value(t, s.state, State.Repair)
	testing.expect_value(t, s.stale_exe, "C:\\old\\wren.exe")
	testing.expect(t, !s.incomplete, "complete, only stale")
	testing.expect_value(t, describe(&s), "to repair: points to C:\\old\\wren.exe")
	status_destroy(&s)
}

@(test)
cli_flag_parsing :: proc(t: ^testing.T) {
	m, rest, bad := parse_cli({"--desktop-integration=install", "https://a.test/"})
	testing.expect_value(t, m, Cli_Mode.Install)
	testing.expect_value(t, len(rest), 1)
	testing.expect_value(t, bad, "")
	m, rest, bad = parse_cli({"--profile", "x", "--desktop-integration", "status"})
	testing.expect_value(t, m, Cli_Mode.Status)
	testing.expect_value(t, len(rest), 2)
	m, _, bad = parse_cli({"--desktop-integration=frobnicate"})
	testing.expect_value(t, m, Cli_Mode.None)
	testing.expect_value(t, bad, "frobnicate")
	m, rest, _ = parse_cli({"page.html"})
	testing.expect_value(t, m, Cli_Mode.None)
	testing.expect_value(t, len(rest), 1)
}

@(test)
identity_is_validated :: proc(t: ^testing.T) {
	o := Options{identity = test_identity(), exe = "x"}
	testing.expect_value(t, validate(&o, false).error, Error.None)
	o.identity.key = "Wren Dev"
	testing.expect_value(t, validate(&o, false).error, Error.Bad_Options)
	o.identity = test_identity()
	o.identity.slug = "Wren"
	testing.expect_value(t, validate(&o, false).error, Error.Bad_Options)
	o.identity = test_identity()
	o.identity.name = "a/b"
	testing.expect_value(t, validate(&o, false).error, Error.Bad_Options)
	o.identity = test_identity()
	o.exe = "Z:\\no\\such\\file.exe"
	testing.expect_value(t, validate(&o, true).error, Error.No_Executable)
}
