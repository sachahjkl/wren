# datetime (package `jsdate`): the JavaScript engine's Date

`src/engine/datetime` is the ECMAScript `Date` calendar and string handling, written natively in Odin
(the package is named `jsdate` so it never collides with `core:time/datetime`). It is ported from
QuickJS-ng and produces the same results as QuickJS over the whole valid range, so `Date` behaves
identically without the C that used to run in WebAssembly.

Time values are milliseconds since the Unix epoch as `f64`, `NaN` for an invalid Date; the valid range
is ±8.64 × 10¹⁵ ms (about ±273 790 years). Fields use the ECMAScript order
`[year, month(0–11), day(1–31), hour, min, sec, ms, weekday, tz-minutes]`.

The package is allocation-free and has no OS dependency, so it builds for `windows_amd64`,
`linux_amd64` and `freestanding_wasm32`. The one thing it cannot compute on its own — the local time
zone offset — is a host callback.

## The time zone callback

```odin
import jsdate "wb:engine/datetime"

jsdate.timezone_offset_proc = proc "contextless" (time_ms: i64) -> int {
    return host_get_timezone_offset(time_ms) // minutes west of UTC, i.e. getTimezoneOffset(t)
}
```

This is the exact role of `js.timezone_offset` in the Wren host. When the callback is nil, local time
equals UTC, so UTC-only code (and tests) work with no host wired up.

## Using it

```odin
// time value -> fields (UTC or local)
f, ok := jsdate.get_date_fields(t_ms, is_local = true, force = false)
// fields -> time value (MakeDay/MakeTime/MakeDate + TimeClip, with month/day overflow)
t := jsdate.set_date_fields(f, is_local = true)

// formatting
buf: [64]u8
n := jsdate.format_date(buf[:], f, .ISO,     .All)  // 2018-01-02T23:02:56.927Z
n  = jsdate.format_date(buf[:], f, .UTC,     .All)  // Tue, 02 Jan 2018 23:04:46 GMT
n  = jsdate.format_date(buf[:], f, .ToString,.All)  // Wed Jan 03 2018 00:05:22 GMT+0100
n  = jsdate.format_date(buf[:], f, .Locale,  .All)  // 1/2/2018, 11:40:40 PM

// parsing (Date.parse / new Date(string))
t = jsdate.parse("2018-01-02T23:02:56.927Z")        // strict ISO 8601
t = jsdate.parse("Wed Jan 03 2018 00:05:22 GMT+0100") // legacy browser format
```

`get_date_fields` returns `ok = false` for a `NaN` time when `force` is false (the caller then emits
"Invalid Date", or a RangeError for `toISOString`). `set_date_fields` performs the spec's MakeDay /
MakeTime / MakeDate in `f64` with the operation order ECMAScript mandates, so out-of-range months and
days roll over exactly as required (and the fp-evaluation-order test262 case passes).

`parse` tries the strict ISO form first, then the legacy "other" format: weekday and month
abbreviations, `GMT±HHMM`, named zones (`GMT`, `UTC`, `PST`, `CET`, …), `AM`/`PM`, parenthesized
comments, and the loose day/month/year ordering old browsers accept. Input is folded to ASCII first
(U+2212 → `-`, anything else above 255 → `x`) and capped at 127 bytes, matching QuickJS.

## How we know it is correct

A differential judge compiles QuickJS's Date calendar and parser (copied verbatim from `quickjs.c`)
with `zig cc`, using the same deterministic, instant-dependent time-zone rule on both sides, and
compares over **1,500,000+ cases**:

- `set_date_fields` on random fields, including out-of-range months and days and years spanning
  ±300 000, in both UTC and local mode;
- `get_date_fields` on random time values, the ±8.64e15 limits and `NaN`, in UTC and local, with and
  without `force`;
- the UTC calendar inverse (`set(get(t)) == t`) — local time is intentionally non-invertible when the
  offset varies with the instant, exactly as in QuickJS;
- `parse` on ISO and UTC strings generated from random times, plus a battery of hand-written legacy
  forms and the ±extreme-year ISO boundaries.

Result: **0 mismatches.**

## Integration

The engine wires `timezone_offset_proc` to `js.timezone_offset`, backs `Date` objects with the `f64`
time value, and calls `set_date_fields` for the `Date` constructor / `Date.UTC` / the setters,
`get_date_fields` for the getters, `format_date` for the `toString` family, and `parse` for
`Date.parse` and `new Date(string)`. `Date.now` and `new Date()` still read the clock from the host.
