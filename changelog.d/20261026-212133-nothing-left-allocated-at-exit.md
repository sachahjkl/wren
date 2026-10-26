type: Fixed

**Nothing left allocated at exit** after service workers, workers and file system handles: the Cache API and file system stores are freed, a worker's last messages are handled before the loop goes, `getFile()` no longer leaks its file's description, and two small leaks of every session (the first tab list, the pointer table) are gone. `tools\sw_e2e.ps1`, `workers_e2e.ps1` and `fs_e2e.ps1` take `-Check` (the check build, which must exit clean), a step of `test_all`.
