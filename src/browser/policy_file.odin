package browser

import "core:path/filepath"
import "core:strings"
import process "toolkit:process"

POLICY_FILE_NAME :: "policies.txt"

// Where the administrator's policy file is when `--policy FILE` does not say: beside the executable, never in the working
// directory. The working directory is wherever the program was started from: a folder the Explorer opened a document in,
// a downloaded archive, a share. A file there would be read at the highest layer and lock any preference
// (security.file_access.policy, security.csp.enabled, browser.license.path...) for whoever planted it. "" when the
// executable's own path is unknown: no policy file then.
default_policy_file :: proc(exe: string, allocator := context.temp_allocator) -> string {
	dir := process.parent_dir(exe)
	if dir == "" { return "" }
	return strings.concatenate({dir, filepath.SEPARATOR_STRING, POLICY_FILE_NAME}, allocator)
}
