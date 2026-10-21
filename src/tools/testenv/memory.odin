package testenv

// The memory check of the end-to-end tools. tools\test_all.ps1 builds them with -define:WREN_TRACK_MEMORY=true: every
// allocation of the process (every thread, the Wasm host calls, the callbacks of WinHTTP) goes through the tracker of
// package base, and the tool fails when anything is still allocated once it has shut everything down. A normal build
// checks nothing.
//
//     main :: proc() {
//         context = testenv.context_of_process()
//         ... the tests, then every destroy / stop ...
//         failures += testenv.mem_check("policytest")
//         fmt.printf("%d failure(s)\n", failures)
//     }

import "base:runtime"
import "core:fmt"
import "wb:base"

// The context a tool's main starts from: the tracker in a check build.
context_of_process :: proc "contextless" () -> runtime.Context { return base.process_context() }

// After the tool has freed everything: prints the leaks and bad frees (if any) and returns 1 when there are some, else
// 0, to add to the failures. Checks nothing in a normal build.
mem_check :: proc(tool: string) -> int {
	when base.TRACK_MEMORY {
		n := base.mem_report(tool)
		if n > 0 { fmt.printfln("FAIL %s: %d leaked block(s) or bad free(s) (memtrack above)", tool, n) }
		return n > 0 ? 1 : 0
	} else {
		return 0
	}
}
