type: Added

**`wren version`, `wren help`, `wren --version` / `-V`, `wren --help` / `-h` / `-?`** (`src/browser/cli_usage.odin`): the program says its version and build, or its usage (the commands, every option), on the console and ends with code 0, before any profile or window is set up; `wren.com` waits for them like for `ctl`, so they print in a terminal and can be redirected. `version`, `help` and `ctl` are commands only as the first argument (`./help` opens a file of that name; after an option the word is refused with a message and exit code 2, not opened as `https://help`).
