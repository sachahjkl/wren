type: Fixed

**`wren ctl stats` costs less CPU and no longer counts the threads of the whole machine** (`process_thread_count`): the thread count walked the system's list of every thread (thousands on a busy runner); it now reads the thread count of the process's own entry in the list of processes. The "idle Wren with remote on" check read its CPU time around two `stats` calls, so the 62 to 1062 ms it reported were those two calls and not a thread of the server (an idle driven Wren uses 0 ms in 3 s and draws no frame); it now reads the CPU between them.
