type: Fixed

**`ctl` given as an address no longer opens https://ctl (in the user's Wren)** (`main.odin`): `wren ctl ...` is the remote control client only as the first argument; written after an option (`wren --profile p ctl ping`) the word was taken for a host and handed to the Wren that runs. It now stops with a message and exit code 2 (`./ctl` still opens a file or host named ctl).
