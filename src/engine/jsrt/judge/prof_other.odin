#+build !windows
package jsrt_judge

// The sampler suspends a thread and reads its registers through Win32 and the PDB; off Windows JSRT_PROF does nothing.

prof_enabled :: proc() -> bool {
	return false
}

prof_start :: proc() {}

prof_report :: proc() {}
