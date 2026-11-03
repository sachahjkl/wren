type: Fixed

**Crash recovery keeps the tabs when a start that was restoring them is killed while it saves them.** Windows holds the file it was renaming for a few seconds after such a process ends; the next start could not read it, found nothing worth keeping and deleted it, so the tabs were lost. That start now reads the file, opens a blank page and saves the tabs in a crashed-session file.
