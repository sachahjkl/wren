type: Fixed

**`wren ctl stop` finds a Wren started from another shell, and leaves no socket behind** (Linux): the files that name the Wrens `wren ctl start` made are kept beside their sockets (`$XDG_RUNTIME_DIR/wren`), not in the temporary folder, which a shell such as `nix develop` changes; `stop`, `run` and a `start` that gives up remove the socket of the Wren they end.
