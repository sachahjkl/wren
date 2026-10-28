# engine/regexp

Odin port of QuickJS-ng's `libregexp`: a full ECMAScript regular-expression parser and bytecode compiler, plus a
bounded backtracking interpreter. It replaces the C engine and leans on the language — tagged opcodes, interval
character sets, caller-supplied allocators, an explicit (non-recursive) backtrack stack — so it builds for
`windows_amd64`, `linux_amd64` and `freestanding_wasm32` with no libc.

```odin
import rx "wb:engine/regexp"
```

## API

```odin
re, err := rx.compile(pattern, flags, allocator)   // flags: rx.Flags bit_set
defer rx.destroy(&re)
if err.message != "" { /* compile error at err.pos */ }

caps: rx.Captures
st := rx.exec_search(&re, rx.input_utf16(units), start, &caps, limits, allocator)
// st is .Match / .No_Match / .Out_Of_Steps / .Stack_Overflow
if st == .Match {
    whole := caps.groups[0]        // {start, end} in code-unit offsets, or {-1,-1} if unset
    idx, ok := rx.named_group_index(&re, "year")
}
```

- **Flags** `d g i m s u v y` — `rx.parse_flags("gims")` → `rx.Flags`; `rx.flags_to_string`.
- **Input** is a slice of code units, either UTF-16 (`rx.input_utf16`, JS semantics, offsets are UTF-16 indices)
  or UTF-8 (`rx.input_utf8` / `rx.input_utf8_string`, offsets are byte indices). Surrogate pairs combine only in
  unicode mode.
- **`exec`** tries exactly one start offset; **`exec_search`** scans forward from `start` (and respects the
  sticky `y` flag, which forbids advancing).
- **Captures** are reported in code-unit offsets; group 0 is the whole match. Allocate on an arena and free the
  whole match at once.

## Limits (configurable)

The interpreter is a flat dispatch loop with an explicit backtrack stack, so a pathological pattern cannot
overflow the native stack. Two budgets bound it, exposed as preferences (`regexp.exec.max_steps`,
`regexp.exec.max_stack`) and overridable per call via `Exec_Limits`:

- `max_steps` — opcode dispatches before the match fails with `.Out_Of_Steps` (default 10,000,000).
- `max_stack` — saved choice points before `.Stack_Overflow` (default 1,000,000).

`tools` builds read the defaults; a host reads them from the registry with `rx.limits_from_prefs`.

## Grammar covered

Alternation; capturing, non-capturing and named groups `(?<name>…)`; the assertions `^ $ \b \B`; positive and
negative lookahead and lookbehind; back references, numbered `\1` and named `\k<name>`; character classes with
ranges, the class escapes `\d \D \w \W \s \S`, and `\p{…}` / `\P{…}` (general category, binary property, `Script`,
`Script_Extensions`); quantifiers `* + ? {n} {n,} {n,m}` with an optional lazy `?`; the escape forms
`\f \n \r \t \v \0 \cX \xHH \uHHHH \u{…}`; the `v`-flag nested set operations `&&` and `--`; and the Annex B
web-reality leniencies when neither `u` nor `v` is set (lone `{`, `]`, `}` as literals; invalid back references as
octal/identity escapes).

## How it works

- `parser.odin` / `parse_*.odin` build an AST (two-pass: a prescan counts groups and collects names so forward
  references resolve).
- `compile*.odin` lower the AST to bytecode: quantifiers become split/goto/loop forms with an empty-match guard
  (`Push_Char_Pos` / `Check_Advance`) so `(a*)*` cannot loop forever; classes resolve to `ucd.Char_Range`
  interval sets, case-folded once at compile time when `i` is set; a lookbehind body is compiled in reverse so a
  dedicated backward interpreter walks it.
- `vm.odin` / `vm_behind.odin` / `vm_read.odin` are the interpreter: forward and reverse dispatch, UTF-8/UTF-16
  reading in both directions, word-boundary and back-reference matching, and the lookaround sub-runner (captures
  from a positive lookaround persist; a failed or negative one leaves none).

## Judged against the C reference

`tools/rx_diff.ps1` builds a native library from QuickJS-ng 0.17's `libregexp.c` + `libunicode.c` and runs this
engine and the C side over a literal corpus, tens of thousands of random fuzz patterns, and a speed benchmark,
reporting every divergence.

Latest run (Unicode 16.0.0, seed 12345, 30,000 fuzz patterns):

- **~2,016,000 checks.** Zero divergences on regexp compile+exec, normalization, and property / category / script
  ranges (boundary-exact). The only mismatches (~3,700) are scalar Unicode predicates
  (`is_id_start`/`is_id_continue`/`is_cased`/`is_case_ignorable`) on a handful of code points where QuickJS 0.17's
  bundled `libunicode-table.h` differs from UCD 16.0.0 — a **data-version skew**, not an engine difference. Re-pin
  the generator to QuickJS's exact UCD revision to close it.
- **Speed:** 2.1×–4.6× slower than the C reference on five typical patterns (~0.2–3 µs/exec). The gap is the
  capture snapshot taken at each choice point; a copy-on-write capture scheme would narrow it.
- **Reference bug found:** QuickJS-ng 0.17's `lre_exec` corrupts the heap when a group combined with `+`/`*`
  (e.g. `(a|b)+`) is executed many times in one process. Reproduced in pure C, independent of this engine; the
  harness guards the C calls and the fuzz generator avoids the trigger for the differential pass while still
  fuzzing the Odin engine over the unrestricted grammar in `-NoC` mode (where it is robust).

Run it:

```powershell
powershell -NoProfile -File tools\rx_diff.ps1 -Seed 12345 -Fuzz 30000      # differential + speed
powershell -NoProfile -File tools\rx_diff.ps1 -NoC -Fuzz 200000            # Odin-only soundness fuzz
```
