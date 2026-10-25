package browser

import "core:testing"

// The policy file is the administrator's: beside the program, never wherever the program was started from.
@(test)
policy_file_is_beside_the_executable :: proc(t: ^testing.T) {
	testing.expect_value(t, default_policy_file(`C:\Apps\Wren\wren.exe`), `C:\Apps\Wren\policies.txt`)
	testing.expect_value(t, default_policy_file(`C:/Apps/Wren/wren.exe`), `C:/Apps/Wren\policies.txt`)
	testing.expect_value(t, default_policy_file(`C:\wren.exe`), `C:\policies.txt`)
	testing.expect_value(t, default_policy_file(`\\server\share\wren.exe`), `\\server\share\policies.txt`)
	testing.expect_value(t, default_policy_file(""), "")           // no executable path: no policy file, and never ./policies.txt
	testing.expect_value(t, default_policy_file("wren.exe"), "")   // a bare name has no folder: not the working directory
}
