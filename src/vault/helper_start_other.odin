#+build !windows
package vault

import "core:os"

// Starts the helper with its stdin and stdout on our pipes (helper_start_windows.odin: the same without a console).
@(private)
helper_start :: proc(path: string, stdin, stdout: ^os.File) -> (p: os.Process, err: os.Error) {
	return os.process_start({command = {path}, stdin = stdin, stdout = stdout, stderr = nil})
}
