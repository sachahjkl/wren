# `wren.com`: Wren from a terminal

`wren.exe` is a program with a window. Typed in cmd or PowerShell it gives the prompt back at once and has no console of
its own, so `wren ctl ...` shows nothing reliably and a script gets no exit code. `wren.com` is a small console program
(`src/tools/wrencom`, about 150 KB, core library only) that sits beside `wren.exe`. cmd and PowerShell find `wren.com`
before `wren.exe` when `wren` is typed (the order of `PATHEXT`), so the launcher is what runs.

```bat
wren ctl help                       :: text on the standard output, exit code 0
wren ctl nosuchcommand              :: message on the standard error output, exit code 4
wren ctl help > help.txt            :: redirections and pipes work: the launcher gives its own handles to wren.exe
wren ctl help | findstr run
wren https://example.org/           :: the window opens, the prompt comes back at once
```

## Wait or let go

The launcher starts `wren.exe` with the same arguments and decides from them (`decide` in `src/tools/wrencom/plan.odin`):

| Arguments | The launcher |
|---|---|
| `ctl ...` as the **first** argument | waits, ends with `wren.exe`'s exit code |
| `--desktop-integration[=...]` anywhere | waits, same |
| `--cli` anywhere (it is the launcher's: `wren.exe` does not see it) | waits whatever the rest is |
| anything else (an address, `--new-window`, `--setup`, `--profile ...`) | lets go and returns 0 |

`wren.exe` reads `ctl` the same way: only the first argument (`./ctl` opens a file named ctl).

When it waits, it hands its own standard input, output and error to `wren.exe` (`STARTF_USESTDHANDLES`), so `> file`,
`2> file`, `2>&1` and `| more` act on what `wren.exe` prints. It also puts itself in a Job Object with
`KILL_ON_JOB_CLOSE`: if the launcher is killed (terminal closed, build step cancelled), the Wren it started goes with it.
Ctrl+C reaches both; the launcher stays until `wren.exe` ends so that it can return its code.

Its own failures use the shells' codes: **126** the launcher is named `.exe` (it would start itself) or `wren.exe` would
not start, **127** there is no `wren.exe` beside it. The messages are English and begin with
`wren.com (Wren console launcher):`; they are for a terminal, not part of Wren's interface, and the launcher imports nothing
from Wren, so they are not in the `i18n` catalogue.

## Where it comes from and who writes it

- `build.bat` compiles it to `build\wren.com` (`-subsystem:console`, before the browser).
- `wren.exe` embeds it (`#load`, `src/browser/console_launcher.odin`): the release stays one file.
- **Setup writes it** beside the installed `wren.exe` when "Add Wren to PATH" is ticked and **removes it** when it is
  unticked, when the integration is removed (`--desktop-integration=remove`) and when Wren is uninstalled or the installation is
  moved (`src/desktop/launcher.odin`). It is never written anywhere else, and never without the PATH entry that makes it
  reachable. `--desktop-integration=install` does the same for a copy that is not installed.
- It carries a mark (`(Wren console launcher)` in every message): a `wren.com` without it is another program's, and is
  neither replaced nor deleted. An installation that has the PATH entry but no `wren.com` (older Setup) is shown as "to
  repair" and **Repair** writes it.
- A launcher that is running cannot be overwritten or deleted: it is renamed to `wren.com.old`, and removed by the next
  write or removal (on uninstall it is reported with the other files a running program holds).

## Tests

- `odin test src/tools/wrencom -vet`: the decision (wait / let go), the target (`wren.com` to `wren.exe`, refusing a `.exe`), and
  the quoting of the command line (read back by `CommandLineToArgvW`).
- `odin test src/desktop`: Setup's side (written with the PATH option, replaced by a new version, removed with it, never
  over another program's file, removed with the install folder).
- `tools\wrencom_e2e.ps1` (a step of `test_all.ps1`): the launcher and `wren.exe` copied into a scratch folder; `ctl help`,
  an unknown command, `> file`, `2>`, `2>&1`, `| findstr`, `%ERRORLEVEL%`, `--desktop-integration=status`, the integration
  writing and removing `wren.com`, the refusals, an interface start that returns at once, `--cli`, and the death of the child
  with the launcher.
