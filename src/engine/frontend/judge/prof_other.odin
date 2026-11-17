#+build !windows
package judge

import "core:fmt"

// The sampler suspends the worker and reads its registers through Win32 and the PDB; off Windows `prof` only says so.
cmd_prof :: proc(file: string, iters: int) -> int {
	fmt.eprintln("prof: Windows only")
	return 1
}
