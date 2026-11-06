# Closed tabs and sessions

`Ctrl+Shift+T` brings back the last thing closed, one at a time, each with what it had. The menus name what comes next: *Reopen closed
tab*, *Reopen closed window*, *Restore previous session*. The command palette lists them too. Code: `src/browser/closed_tabs.odin`,
`src/browser/session.odin`.

| What | Comes back with |
|---|---|
| A tab | Its history tree, its place in the strip, its group (the group of that name and colour if the window still has it), pinned or not, where it was left |
| A window | All its tabs together, in a window of its own, at its old place |
| The session of the run before | All its windows; the first one in the current window, in the place of a start page that shows nothing |

A tab that showed nothing (the start page or a blank one, with no history) is not kept.

## At start-up

**Restore tabs at start-up**, in the main menu (`browser.session.restore`, off by default), reopens the session by itself when no address
is given on the command line. Only the current tab loads at once; the others load when first shown.

A start that does not reopen the session (the option is off, or an address was given) puts it on the list: `Ctrl+Shift+T` reopens it, even
several runs later. Pinned tabs that came back by themselves (`browser.tabs.restore_pinned`) are left out of it, so they are not doubled.
After a crash the tabs come back as described in [crash recovery](crash-recovery.md).

## What is kept

| File in the profile | Meaning |
|---|---|
| `session.txt` | The tabs and windows of this run, written with the other profile files (autosave, and at exit), whatever the option says |
| `closed.txt` | The list, most recent last: each item is the text of a session file after a line that says what it is |

`browser.tabs.closed_max` caps the list (0: nothing is kept), `browser.tabs.closed_sessions_max` the earlier sessions in it. Both files need
`browser.profile.persist`. They are read at the first use of the list or at the first autosave, not on the way to the first frame.

Clearing the history for a period (about:history) also forgets what was closed in that period.
