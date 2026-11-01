#+build windows
package e2e_scenarios

// Where the policy file is read from (src\browser\policy_file.odin): beside the executable, or where --policy says; never from the working
// directory (a folder a document was opened from, an archive, a share), where a file planted by someone else would be read at the highest
// layer and lock any preference (security.file_access.policy=all, ...).

import "core:fmt"
import "core:os"
import "core:testing"
import "wb:e2e"
import "wb:remote/api"

@(private = "file") POLICY_FILE :: "policies.txt"
@(private = "file") PREF :: "security.file_access.policy"
@(private = "file") PREF_BY_DEFAULT :: "own_tree"

@(private = "file")
policy_text :: proc(value: string) -> string { return fmt.tprintf("wbpolicy 1\n%s\t%s\n", PREF, value) }

@(private = "file")
pref_of_a_start :: proc(t: ^testing.T, exe, cwd: string) -> string {
	p := e2e.launch(t, {exe = exe, start = {cwd = cwd}})
	value, _ := api.pref_get(p.s, PREF)
	e2e.quit(p)
	return value
}

@(test)
the_policy_file_is_beside_the_program_never_in_the_working_folder :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	trap := fmt.tprintf("%s/trap", dir)
	home := fmt.tprintf("%s/program", dir)
	_ = os.make_directory_all(trap)
	_ = os.make_directory_all(home)
	copy := fmt.tprintf("%s/wren.exe", home)
	testing.expect_value(t, os.copy_file(copy, e2e.wren_exe()), nil)
	e2e.write_text(fmt.tprintf("%s/%s", trap, POLICY_FILE), policy_text("all"))
	testing.expect_value(t, pref_of_a_start(t, copy, trap), PREF_BY_DEFAULT)
	e2e.write_text(fmt.tprintf("%s/%s", home, POLICY_FILE), policy_text("none"))
	testing.expect_value(t, pref_of_a_start(t, copy, trap), "none")
}
