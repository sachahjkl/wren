package remote

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

// The folder of the channels' sockets: $XDG_RUNTIME_DIR/wren (the user's own, cleared at logout), else /tmp/wren-<uid>
// (the folder of the instance lock too). Only a folder that is this user's, not a link and closed to everyone else is
// used: another user who made /tmp/wren-<uid> first could otherwise read the requests or answer them.
socket_dir :: proc() -> (dir: string, ok: bool) {
	if x := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator); x != "" {
		dir = strings.concatenate({x, "/wren"}, context.temp_allocator)
	} else {
		dir = fmt.tprintf("/tmp/wren-%d", linux.getuid())
	}
	c := strings.clone_to_cstring(dir, context.temp_allocator)
	linux.mkdir(c, {.IRUSR, .IWUSR, .IXUSR})
	st: linux.Stat
	if linux.lstat(c, &st) != .NONE { return dir, false }
	kind := st.mode & {.IFIFO, .IFCHR, .IFDIR, .IFREG}
	others := st.mode & {.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}
	return dir, kind == {.IFDIR} && st.uid == linux.getuid() && others == {}
}

// The socket of instance `name`.
pipe_path :: proc(name: string, allocator := context.temp_allocator) -> string {
	dir, _ := socket_dir()
	return strings.concatenate({dir, "/remote-", name, ".sock"}, allocator)
}
