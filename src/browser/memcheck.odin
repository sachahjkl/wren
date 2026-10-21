package browser

// The check build (build.bat check -> build\browser_check.exe: -debug, -define:WREN_TRACK_MEMORY=true): every
// allocation of the process is tracked (base/memory.odin), and once the browser has shut everything down the blocks
// still allocated are written to <profile>/memtrack.txt (or to the file WREN_MEMTRACK_REPORT names). With
// WREN_MEMTRACK_FAIL=1 the process then exits with code 3 when there are any (tools\screenshot.ps1 -Exe
// build\browser_check.exe in tools\test_all.ps1). A normal build does nothing here.

@(require) import "core:os"
@(require) import "core:strings"
@(require) import "wb:base"

// `profile_dir` is a copy the caller keeps until this returns (the app's is freed before).
memcheck_exit :: proc(profile_dir: string) {
	when base.TRACK_MEMORY {
		file := ""
		if os.get_env("WREN_MEMTRACK_REPORT", context.temp_allocator) == "" {
			file = strings.concatenate({profile_dir, "/memtrack.txt"}, context.temp_allocator)
		}
		n := base.mem_report("browser", file)
		if n > 0 && os.get_env("WREN_MEMTRACK_FAIL", context.temp_allocator) == "1" { os.exit(3) }
	}
}
