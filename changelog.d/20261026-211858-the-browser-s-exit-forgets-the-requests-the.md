type: Fixed

**The browser's exit forgets the requests the performance timeline still described** (`page.timeline_shutdown` was only called by the end-to-end tools): a block of 9.5 KB was left allocated, found by the check build of the CI.
