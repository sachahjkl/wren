# Crash reports and the symbols of a build

When Wren crashes, the toolkit's `gt:crash` writes `<profile>/crashes/crash-<date>-<time>-<pid>.txt` and, on Windows, a
minidump beside it (`.dmp`). `src/browser/crash_report.odin` installs it at the start, with the profile's folder and the
user's preferences file as the report's `[settings]`. The toolkit's [crash.md](../ext/gui_toolkit/docs/crash.md) describes
the report's format, its sections and what the handler does on each system.

- A program that ended itself with its session open (`ExitProcess` or `TerminateProcess`) leaves `exit-<date>.txt` with
  the stack that asked for it (Windows).
- A session that ended with no chance to write a report (a fail-fast, a kill, a power cut) is reported at the next start as
  `unclean-<date>.txt`.
- A close ended by the shutdown watchdog leaves no report: `host.shutdown_on_force` ends the session first, and
  `shutdown.log` in the profile says what it waited for.
- The next start keeps the newest report (`crash.last_report`). The crash recovery bar's Details button opens it in a tab.
  Nothing is sent anywhere.

Each thread of `host.thread_start` keeps room for the handler of a stack overflow (`src/host/thread_<os>.odin`): a stack
guarantee of 64 KiB on Windows, an alternate signal stack on Linux. A thread of `core:thread` or of a library has none.

## The symbols of a build

A release has no PDB, so its own frames are module offsets. `wrentool build` links with `toolbox.CRASH_LINKER_FLAGS`
(`/MAP` on Windows, `--build-id` on Linux). After each link on Windows, `toolbox.crash_publish_symbols` renames the map
`<exe stem>-<build>.map`; a release build also copies it to `build/symbols`, which keeps the newest 20. A release package
keeps its map beside the package, never in what is published.

```
wrentool crash-symbolize <report.txt> -Symbols <the .map (Windows) or the executable (Linux)>
wrentool symbols -Build <exe>          the build id a report names
wrentool symbolize -Exe <exe> <offset>  the function and line at an offset, from a -debug build's PDB
```

## Other stacks

- `wren ctl stacks <pid>` prints every thread of another process, named with its PDB (`src/stacks/stacks_windows.odin`).
- The sampling profiler and a tool's hang dump (`WREN_HANG_DUMP_MS`) walk a stopped thread of their own process in a copy of
  its stack (`src/stacks/stack_copy_windows.odin`): a damaged stack ends the walk, it does not fault.
