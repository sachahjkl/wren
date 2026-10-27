type: Added

**Remote control over a Unix socket on Linux** (`wren ctl`, `remote.start`) : the channel listens on `$XDG_RUNTIME_DIR/wren/remote-<name>.sock` (else `/tmp/wren-<uid>`), in a folder only this user may enter, the socket 0600, every client's credentials checked (SO_PEERCRED); a socket another live process listens on is never taken over, one left by a crash is replaced. `wren ctl run`, `start` and `stop` start and end their Wren with posix_spawn, and tell it again by its start time and program (/proc). Same protocol, same threads and limits as the named pipe of Windows.
