// buildjs: builds Wren's JavaScript engine (wb:tools/tooling, js_engine.odin says what it does); wrentool build does the same in its own process; nothing happens when it is up to date.
//   odin run src/tools/buildjs -collection:wb=src -out:build/buildjs.exe -- [-force] [-names] [-no-snapshot] [-test262] [-o size|speed|...] [-out <dir>]
// -names keeps the function names in the module (a readable profile); WREN_ODIN_FLAGS (;-separated): more flags for the glue and the engine (-disable-assert -no-bounds-check ...).
package buildjs

import "core:fmt"
import "core:os"
import "core:strings"
import "wb:tools/tooling"

main :: proc() {
	o: tooling.Js_Options
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-force": o.force = true
		case "-names": o.names = true
		case "-no-snapshot": o.no_snapshot = true
		case "-test262": o.test262 = true
		case "-o":
			i += 1
			if i < len(args) { o.odin_opt = args[i] }
		case "-out":
			i += 1
			if i < len(args) { o.out = args[i] }
		case:
			fmt.eprintfln("buildjs: unknown argument %s", args[i])
			os.exit(2)
		}
	}
	if os.set_working_directory(tooling.repo_root()) != nil { fmt.eprintln("buildjs: no repository"); os.exit(2) }
	if extra, ok := os.lookup_env("WREN_ODIN_FLAGS", context.allocator); ok && extra != "" { o.odin_flags = strings.split(extra, ";") }
	os.exit(tooling.build_js_engine(o) ? 0 : 1)
}
