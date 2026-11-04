type: Fixed

**Linux: a crash on pages that use Web Animations** (reddit, YouTube): when the last effect of an element ended, the entry of the element was removed under a key read from the record just freed: glibc's heap had overwritten it, the entry stayed, the next style pass read freed memory (`page::styles`, a bounds check in `sync_runs`).
