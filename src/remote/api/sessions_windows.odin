package api

// The folder of the files `wren ctl start` writes to name the Wrens it made (what `stop` reads).
sessions_dir :: proc() -> string { return state_dir() }
