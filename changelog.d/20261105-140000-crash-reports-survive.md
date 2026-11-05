type: Fixed

**Crash reports survive more crashes**: a crash on a stack the system could not walk ended the process with no report at all, a second thread faulting during the report ended the process under it, and a report stuck on a lock the crash left held wrote nothing. The text now comes first and the minidump last, every faulting thread waits for the report, and the walk of a damaged stack cannot fault.
