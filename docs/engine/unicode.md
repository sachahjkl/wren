# engine/unicode (`ucd`)

Odin port of QuickJS-ng's `libunicode`. It provides the Unicode data the regexp engine and the JS lexer need:
character-set intervals, case conversion / folding / the ECMAScript regexp `canonicalize`, the identifier and
whitespace predicates, the `\p{}` property / general-category / script sets, and the four normalization forms.

The package is named `ucd` (not `unicode`) so it does not collide with `core:unicode`. Import it with an alias:

```odin
import ucd "wb:engine/unicode"
```

It compiles for `windows_amd64`, `linux_amd64` and `freestanding_wasm32`. Nothing in the runtime path touches the
OS; every allocation goes through a caller-supplied allocator (pass an arena to free a whole build at once). The
only hosted-only file is `settings.odin` (the preference registry needs an OS); it is excluded from the
freestanding build with a `#+build` tag.

## Data: generated, pinned, never copied

The tables are **generated** from the authoritative Unicode Character Database, not copied from QuickJS's
`libunicode-table.h`:

- `tools/gen_unicode.ps1` downloads the pinned UCD files for a fixed Unicode release (16.0.0), verifies each
  file's SHA-256 (the same idiom as `tools/build_js.ps1`), then runs the generator.
- `src/engine/unicode/gen/` (an Odin program) parses the UCD text and writes `tables_generated.odin`: sorted
  half-open interval runs for every property / category / script, simple and full case/fold tables, and the
  decomposition / combining-class / composition tables for normalization.
- `src/engine/unicode/tables_generated.odin` is committed so a normal build needs no network. Re-run the script
  to move to another Unicode release; the pinned version shows up as the `unicode.version` preference.

## Char_Range and set operations

`Char_Range` is a set of code points stored as a sorted, non-overlapping list of half-open `[lo, hi)` intervals
on a caller-chosen allocator. It is the `v`-flag set-notation primitive and the shape every property lookup fills.

```odin
cr: ucd.Char_Range
ucd.cr_init(&cr, allocator)
defer ucd.cr_destroy(&cr)
ucd.general_category(&cr, "Lu")          // fill with uppercase letters
ucd.cr_op_inplace(&cr, &other, .Inter)   // union / inter / xor / sub
ucd.cr_invert(&cr)                        // complement within [0, 0x110000)
in_set := ucd.cr_contains(&cr, 'A')
```

## Case, canonicalize, predicates

```odin
ucd.simple_case(c, .To_Upper | .To_Lower | .Fold) -> u32          // 1:1
ucd.full_case(&res3, c, conv) -> int                               // 1..3 code points
ucd.canonicalize(c, is_unicode) -> u32                             // ECMAScript regexp i-flag rule
ucd.cr_canonicalize(&cr, is_unicode)                               // canonicalize a whole class
ucd.is_id_start / is_id_continue / is_white_space / is_cased / is_case_ignorable
ucd.js_is_ident_first / js_is_ident_next                           // lexer rule: ID_* plus $ _ ZWNJ ZWJ
```

`is_id_start`/`is_id_continue` return the raw Unicode property (matching QuickJS's `lre_is_*`). The lexer-level
helpers add `$`, `_`, ZWNJ and ZWJ.

## Normalization

```odin
out := ucd.normalize(src_codepoints, .NFC | .NFD | .NFKC | .NFKD, allocator)
```

Standard algorithm: recursive canonical/compat decomposition, canonical ordering by combining class, then
canonical composition for the C forms, with the algorithmic Hangul rules built in.

## Checking it

`tools/rx_diff.ps1` builds a native reference library from QuickJS-ng 0.17's `libunicode.c` and compares this
package against it over every code point and thousands of random normalization inputs. See `docs/engine/regexp.md`
for the results and the one known caveat (a Unicode data-version skew between UCD 16.0.0 and the table QuickJS
ships).
