package gen

// wrentool trace start | stop [-Out file.etl] | cancel: a recording of WPR (Windows Performance Recorder) with Wren's profile,
// tools/wren.wprp (CPU samples with stacks, context switches, ready threads, the GPU's scheduler, Wren's provider: package
// trace, on in the profile build). Recording needs an elevated prompt: this asks for nothing, it says so when WPR refuses.
// WPR is the Windows Performance Toolkit's when it is installed (newer), else the system's. docs/performance.md, Profilers.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "wb:tools/tooling"

TRACE_PROFILE :: "tools/wren.wprp!Wren"
TRACE_REGIONS :: "tools\\wren_regions.xml"
TRACE_OUT :: "build/trace/wren.etl"
WPT_FOLDER :: "Windows Kits/10/Windows Performance Toolkit"

run_trace :: proc(args: []string) -> int {
	if len(args) == 0 { fmt.eprintln("wrentool trace start | stop [-Out file.etl] | cancel"); return EXIT_USAGE }
	f, ok := tooling.parse_flags(args[1:], "-Out=")
	if !ok { return EXIT_USAGE }
	wpr := wpr_program()
	command: []string
	out := tooling.flag(f, "-Out", TRACE_OUT)
	switch args[0] {
	case "start":  command = {wpr, "-start", TRACE_PROFILE, "-filemode"}
	case "stop":
		_ = os.make_directory_all(filepath.dir(out))
		command = {wpr, "-stop", out, "Wren"}
	case "cancel": command = {wpr, "-cancel"}
	case: fmt.eprintfln("wrentool trace: no %s (start, stop, cancel)", args[0]); return EXIT_USAGE
	}
	if code := tooling.run({command = command}, COMMAND_LIMIT); code != 0 {
		fmt.eprintfln("%s failed (exit code %d). Recording needs an elevated prompt; another recording may be running (wrentool trace cancel).", wpr, code)
		return 1
	}
	if args[0] == "stop" {
		fmt.printfln("%s written. Open it in WPA (wpa.exe %s), then Trace > Load Symbols (_NT_SYMBOL_PATH: docs/performance.md) and", out, out)
		fmt.printfln("Trace > Trace Properties > Regions of Interest: %s (Wren's phases as regions)", TRACE_REGIONS)
	}
	return 0
}

@(private = "file")
wpr_program :: proc() -> string {
	programs, _ := os.lookup_env("ProgramFiles(x86)", context.temp_allocator)
	wpt := fmt.tprintf("%s/%s/wpr.exe", programs, WPT_FOLDER)
	return os.exists(wpt) ? wpt : "wpr.exe"
}
