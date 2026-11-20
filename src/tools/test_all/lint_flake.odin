package test_all

// The flake's toolkit is the submodule's: flake.nix takes gui_toolkit from an input pinned to a commit (a flake fetched
// from GitHub is a tarball without submodules), so a bump of ext/gui_toolkit that leaves flake.lock behind builds the
// Nix package against the old toolkit. Nothing else says so before `nix build` fails (gui_toolkit docs/toolbox.md,
// "The flake's toolkit").

import "core:fmt"
import "core:os"
import toolbox "toolkit:toolbox"
import "wb:tools/tooling"

task_lint_flake_toolkit :: proc(t: ^Task_Run) -> bool {
	lock, err := os.read_entire_file_from_path("flake.lock", context.temp_allocator)
	if err != nil { return true }   // (no flake: nothing to agree with)
	pin, pinned := toolbox.flake_toolkit_pin(string(lock))
	if !pinned { return true }
	head, _ := toolbox.checkout_head("ext/gui_toolkit")
	if why := toolbox.flake_toolkit_says(pin, head); why != "" {
		tooling.append_text(t.log, fmt.tprintf("error: %s\n", why))
		return false
	}
	return true
}
