type: Changed

**The test tooling is in Odin**: `src/tools/test_all` (a typed table of steps, a small state machine, the result cache, the profiler, its own desktop; on Windows and Linux) instead of `tools\test_all.ps1`, `test_cache.ps1`, `test_profile.ps1`, `tools/linux_ci.sh`; `src/tools/wpt` and `src/tools/test262` are the whole of their runs (the pinned checkout, the second chance, `-update`); `src/tools/buildjs` builds the JavaScript engine, `src/tools/endurance` is the long-run memory test. A step costs no PowerShell, and a process per test program at most.
