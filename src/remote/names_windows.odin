package remote

import "core:strings"

PIPE_PREFIX :: `\\.\pipe\wren-remote-`

// The named pipe of instance `name`.
pipe_path :: proc(name: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({PIPE_PREFIX, name}, allocator)
}
