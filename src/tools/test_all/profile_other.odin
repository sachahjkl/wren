#+build linux
package test_all

import "core:fmt"
import "wb:tools/tooling"

// -Profile reads the job objects of Windows. On Linux a run says each step's CPU (build/test_steps.tsv, the end of the run): what wait4 reports.
Profile :: struct {}

profile_begin :: proc() -> ^Profile {
	fmt.println("-Profile: only on Windows; build/test_steps.tsv has each step's CPU")
	return nil
}
profile_end :: proc(p: ^Profile) {}
profile_port :: proc(p: ^Profile) -> rawptr { return nil }
profile_spawn :: proc(p: ^Profile, r: ^Step_Run, argv: []string, c: Command) -> tooling.Spawn { return {} }
profile_report :: proc(base: string) { fmt.println("-Profile: only on Windows") }
profile_compare :: proc(a, b: string) { fmt.println("-Profile: only on Windows") }
