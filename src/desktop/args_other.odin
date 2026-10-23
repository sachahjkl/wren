#+build !windows
package desktop

import "core:os"

// The program's arguments (without the program's own name).
command_line_args :: proc(allocator := context.temp_allocator) -> []string { return os.args[1:] }
