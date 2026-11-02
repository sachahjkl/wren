// wrentool: the project's scripts, one program. A table of subcommands; what drives a Wren does it through the typed API (src/remote/api), what needs another program calls it (cargo, magick, ffmpeg, signtool...).
//   odin build src/tools/wrentool -collection:wb=src -out:build/wrentool.exe
//   build\wrentool help
// It compiles without any of the libraries it fetches (build.bat builds it first). What needs a desktop or real input is behind an explicit flag: it never runs by default.
package wrentool

import "core:fmt"
import "core:os"
import "wb:tools/tooling"
import "wb:tools/wrentool/changelog"
import "wb:tools/wrentool/deps"

EXIT_USAGE :: 2

Command :: struct {
	name, about: string,
	run:         proc(args: []string) -> int,
}

COMMANDS := []Command{
	{"deps", "what a build needs, each up to date: [-Profile quick|release] [-Force]", deps.run_all},
	{"fetch", "wasmtime | wgpu | openh264 | emoji [-Force] [-Unicode] [-Dest dir]", deps.run_fetch},
	{"build", "lexbor | native [-Force] [-Profile quick|release] [-Features a,b]", deps.run_build},
	{"symbols", "-Publish exe [-Store] | -Fingerprint exe", deps.run_symbols},
	{"crash-symbolize", "<report> [-Symbols folder or .map] [-Exe exe]: names the frames of a crash report", deps.run_crash_symbolize},
	{"symbolize", "-Exe exe <offset>...: the function and line at an offset of a module", deps.run_symbolize},
	{"changelog", "-New | -Check [-Release v] | -Assemble [-Version v] | -Section -Version v | -Migrate", changelog.run},
}

main :: proc() {
	if len(os.args) < 2 || os.args[1] == "help" || os.args[1] == "-h" || os.args[1] == "--help" { usage(); return }
	root := tooling.repo_root()
	if os.set_working_directory(root) != nil { fmt.eprintfln("wrentool: cannot work in %s", root); os.exit(EXIT_USAGE) }
	for c in COMMANDS {
		if c.name == os.args[1] { os.exit(c.run(os.args[2:])) }
	}
	fmt.eprintfln("wrentool: no command %s", os.args[1])
	usage()
	os.exit(EXIT_USAGE)
}

usage :: proc() {
	fmt.println("wrentool <command> [arguments]")
	for c in COMMANDS { fmt.printfln("  %-16s %s", c.name, c.about) }
}
