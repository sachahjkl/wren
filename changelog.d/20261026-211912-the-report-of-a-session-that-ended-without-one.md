type: Fixed

**The report of a session that ended without one is no longer empty on a loaded machine** (`crashtrace.begin_session`, security review of 2026-10-25, finding 9): the thread that reads the previous session's file was started before the text it reads was set, so it could read `""` (no process id, no event found). The text is set first.
