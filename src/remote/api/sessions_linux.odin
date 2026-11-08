package api

import "wb:remote"

// The folder of the files `wren ctl start` writes to name the Wrens it made (what `stop` reads): beside their sockets
// ($XDG_RUNTIME_DIR/wren), the same for every process of the user. The temporary folder is not: a shell (nix develop)
// sets its own TMPDIR, and a `stop` from another shell found no session.
sessions_dir :: proc() -> string {
	dir, _ := remote.socket_dir()
	return dir
}
