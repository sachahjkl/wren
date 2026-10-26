# Crash reports and the symbols of a build

When Wren crashes, `src/tools/crashtrace` writes `<profile>\crashes\crash <date> <time>.txt` (the faulting thread's
stack) and a minidump beside it (`.dmp`). A session that ended with no chance to write one (a fail-fast, a kill) is
reported at the next start as `unclean exit <date>.txt`.

## What a report says

```
Wren 0.4.0 (g6933902 2026-10-26)

*** crash: exception (0xC000008C) at 0x7FF8A66B408A, thread 40736
  build wren.exe 6ADF67692DFE000, base 0x7FF741D90000, size 0x2DFE000
  #00 0x7FF8A66B408A RaiseException+0x8A  [KERNELBASE.dll+0xC408A]
  #01 0x7FF741D98491 ?+0x0  [wren.exe+0x8491]
  ...
```

- `build <exe> <fingerprint>`: the build that crashed. The fingerprint is the link time stamp and the image size of
  the exe's PE header (`%08X%X`, the key a symbol server uses for an executable): every link makes a new one, and
  signing does not change it. `base` is where the exe was loaded.
- Each frame: its address, what DbgHelp found in the process, and `[module+offset]`. A development, debug, check or
  profile build has its PDB beside it: the frames have names, files and lines. **A release has no PDB** (`-debug` would
  change the program: `ODIN_DEBUG`, the Direct3D debug layer, other code), so its own frames say `?` or the nearest
  export, which is wrong; the offsets are what counts.

## The symbols of a build

`build.bat` links every variant with `/MAP` (it changes nothing in the exe: the sections are byte for byte the same) and
`tools\symbols.ps1 -Publish` renames the map `build\<exe>-<fingerprint>.map`; a release's is also kept in
`build\symbols` (the 20 latest). The map lists every function with its address: Odin names a procedure `pkg::proc`, and a
private one `pkg::[file.odin]::proc`, so a frame gets its function and, often, its file; there are no line numbers
(those need the debug information of `-debug`).

The map is never in what a user gets: `tools\package.ps1` puts it in `build\dist\symbols\<package>-<fingerprint>.map`,
the CI keeps it as an artifact (`wren-symbols-<commit>`; `wren-<version>-symbols` for a release, 90 days), and
`tools\experimental.ps1` leaves it beside the zip (and zipped in the `-Vault` folder).

## Naming the frames of a report

```
powershell -File tools\crash_symbolize.ps1 "<profile>\crashes\crash 2026-10-26 15-47-09.txt" [-Symbols <folder or .map>] [-Exe <exe with its PDB>]
```

It reads the `build` line, finds `*-<fingerprint>.map` (in `-Symbols`, the report's folder, `build\`, `build\symbols`) and
rewrites each frame inside the program as `function+0xoffset (file.odin)  [exe+0xoffset]`. A report from before the
`build` line has only addresses: the minidump beside it gives the base and the fingerprint (its module list). Given a
`.dmp` alone it names the exception's address. `-Symbols <file.map>` takes a map of another link, for instance the same
commit rebuilt with the same flags: the script warns that the time stamps differ, and the Odin frames are right as long
as the code is the same. `-Exe` uses an exe and its PDB through DbgHelp instead (files and lines; a development build).

The crash of 26/10 (an experimental build without the `build` line), named from its minidump and a rebuild of `6933902`
with the same flags:

```
  #01 ... runtime.windows_trap_array_bounds+0x21  (procs_windows_amd64.odin)  [...exe+0x8491]
  #02 ... runtime.bounds_trap+0x9
  #03 ... runtime.bounds_check_error.handle_error-720+0x68
  #04 ... ui.spacer+0x316
  #05 ... browser.build_ui+0x3A8D
  #06 ... browser.frame+0x7D12
  #07 ... browser.main+0x15575
```

## Tests

`tools\crash_e2e.ps1` (with `-Ui` in `test_all`: it needs a desktop session) builds `src/tools/crashmodes` as a release is
built (no PDB, a map), makes it index out of range, and checks that the report has the `build` line and module offsets,
that `crash_symbolize.ps1` names `crashmodes.index_out_of_range` under `main`, and that a report without the `build`
line is named through its minidump. `src/tools/crashtrace` has a unit test of the fingerprint (read in memory and from
the file).
