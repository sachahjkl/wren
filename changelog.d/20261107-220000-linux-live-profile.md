type: Fixed

**Linux: a second start of a profile no longer takes the Wren running on it for a crash**: it opened that session's tabs again and took over its files. The start time of a process is read from the boot time (`/proc/stat`), the same at every reading.
