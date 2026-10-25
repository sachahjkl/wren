# Crash recovery

After Wren ends abnormally (a crash, a kill, a power cut) the next start opens the tabs again, with no setting to turn on, and never
loops on a page that crashes it. `browser.session.crash_recovery` (on by default) is the switch; it needs `browser.profile.persist`
(a throwaway profile writes nothing). Code: `src/browser/crash_recovery.odin` (decision, files, snapshot), `crash_banner.odin` (the bar).
It is separate from `browser.session.restore` (reopen the tabs after a normal end, off by default).

## Files in the profile

| File | Meaning |
|---|---|
| `running.txt` | A Wren runs (or ran and ended abnormally): `pid`, `created` (the process's creation time, FILETIME) and `restoring` (this run reopened a crashed session and is not known stable yet). Written at the start, removed at a normal end. |
| `recovery.txt` | The snapshot: the session file format of `session.odin` (every tab: address, whole history tree, scroll position and zoom, which tab is current). Removed at a normal end. |
| `crashed-session <date>.txt` | The snapshot of a session that crashed twice while it was restored. The last `browser.session.crash_backups` are kept. |

## Deciding at the start

`recovery_start` runs right after the single-instance step, before the window, so a start that dies early is counted too.

| Marker | Process it names | Decision |
|---|---|---|
| none | | normal start (a stray `recovery.txt` is deleted) |
| yes | still runs, and is not this process | `Live`: not a crash, this start touches none of the files (no marker, no snapshot) |
| yes, `restoring 0` | gone | `Crashed`: restore `recovery.txt` |
| yes, `restoring 1` | gone | `Crashed_Twice`: do not restore |

"Still runs" is the single-instance mutex when this process holds it (then nothing else runs on the profile and the marker is stale,
even if its process id was reused), else the process id **and** creation time. A marker that cannot be read counts as an abnormal end.
A snapshot with only blank pages is not worth restoring: the start is a plain one.

## The snapshot

`recovery_touch` is called where the snapshot changes (a tab opened, closed, selected or moved, a history entry added or traversed,
a document parsed). It arms one timer of `browser.session.crash_snapshot_ms` (3 s); changes in between share one write. When it
fires, the interface thread builds the text (it reads the tabs) and a worker of the blocking pool writes it atomically (temporary
file, then `MoveFileEx`); a second write waits for the first. Nothing is written when the text did not change. At a normal end the
timers stop, a write in flight finishes, then `running.txt` and `recovery.txt` are removed, the marker first (a snapshot without a
marker is only stale; a marker without a snapshot would be a crash).

Reading is forgiving (`session_parse_tabs`): a file above 64 MiB, a tab count above `browser.session.max_tabs`, entries above
`history.tree.max_nodes` per tab, addresses above `browser.session.max_url_bytes` or that do not parse are dropped; a truncated or
foreign file restores what is readable.

## Never in a loop

A start that restores writes `restoring 1` in its marker and clears it after `browser.session.crash_stable_ms` (30 s). If it ends
before, the next start is `Crashed_Twice`: it moves `recovery.txt` to `crashed-session <date>.txt`, opens `about:blank` and shows
"Wren crashed twice while restoring; your tabs are saved in ...". `Restore tabs` (or the command `tab.restore_crashed`) opens them
by hand; that start is not marked restoring, so a crash after it restores the snapshot once more and the next is again `Crashed_Twice`:
at most one restoring start in a row. Only the current tab loads at once (the others when first shown), as in `browser.session.restore`.

A start with an address on the command line opens the restored tabs, then the address as a new tab (shown); after two crashes the
address alone.

## The bar

`Wren closed unexpectedly. Restored N tabs.` with `Start fresh` (closes the restored tabs, leaves the homepage) and `Details` (the
newest report of `<profile>\crashes` written since the crashed run began, `crash *.txt` before `unclean exit *.txt`, in a tab; a notice
when there is none: the process was ended from outside). The x dismisses the bar. The texts go through `i18n.tr`.

## Tests

`odin test src/browser` (`crash_recovery_test.odin`): marker format and every truncation, the start decision (clean, crashed, live,
twice), the snapshot round trip, a truncated and a hostile file, the plan over a scratch profile (crash, restore, crash again,
backup, blank page), live instance, backup pruning, report lookup, the preferences. `tools\crash_recovery_e2e.ps1` (in `test_all`):
real processes ended by their own id.
