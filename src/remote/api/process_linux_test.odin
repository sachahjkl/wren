#+build linux
package api

// process_start on Linux: what Start_Options asks of the child (its folder, its outputs in pipes or merged) is what it gets.

import "core:os"
import "core:strings"
import "core:testing"

@(private = "file") SHELL :: "/bin/sh"
// What the child prints: its folder on stdout, a word on stderr.
@(private = "file") SCRIPT :: "pwd; echo said-on-stderr 1>&2"
@(private = "file") WAIT_MS :: 10_000

@(private = "file")
run :: proc(t: ^testing.T, o: Start_Options) -> (out, err: string) {
	p, _, why := process_start({SHELL, "-c", SCRIPT}, o)
	testing.expectf(t, why == "", "started: %s", why)
	if why != "" { return }
	ended := process_wait(&p, WAIT_MS)
	testing.expect(t, ended, "it ends")
	out, err = process_output(&p)
	process_release(&p)
	return
}

@(test)
a_child_has_its_folder_and_its_outputs_in_pipes :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "wren-process-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove(dir)
	out, err := run(t, {cwd = dir, stdout = {pipe = true}, stderr = {pipe = true}})
	testing.expect_value(t, strings.trim_space(out), dir)
	testing.expect_value(t, strings.trim_space(err), "said-on-stderr")
	merged, none := run(t, {stdout = {pipe = true}, merged = true})
	testing.expectf(t, strings.contains(merged, "said-on-stderr"), "merged: stderr goes where stdout goes: %q", merged)
	testing.expect_value(t, none, "")
}
