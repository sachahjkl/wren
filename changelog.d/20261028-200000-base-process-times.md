type: Added

**`base.process_times`, `base.process_threads` and `base.process_counters`** (neutral): the process's CPU and wall time, its thread count, and its memory with the open handle and (Windows) GDI / USER counts, read from the kernel on Windows and from `/proc` on Linux. The browser's remote-control stats and the memory-check driver read these instead of calling Win32 directly, so they work on every system.
