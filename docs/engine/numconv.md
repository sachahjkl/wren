# numconv: float64 ↔ string for the JavaScript engine

`src/engine/numconv` is the part of the JavaScript engine that turns a `float64` into the string a
script sees (`String(x)`, `Number.prototype.toString/toFixed/toExponential/toPrecision`) and parses a
string back into a `float64` (`Number(s)`, `parseFloat`, `parseInt`). It is written natively in Odin,
ported deliberately from QuickJS-ng's `dtoa.c` (Fabrice Bellard, MIT), and produces **the same bytes
as QuickJS for every finite f64 and every radix 2–36**, so the engine's number output never depends
on the C that used to run inside WebAssembly.

It is allocation-free: the string producers write into a caller buffer and return the length, the
parsers read a string, and the bignum scratch that the algorithm needs lives on fixed stack arrays
(what QuickJS kept in `JSDTOATempMem`/`JSATODTempMem`). That is what lets the package build for
`windows_amd64`, `linux_amd64` **and** `freestanding_wasm32` with no allocator and no OS.

## Using it

```odin
import nc "wb:engine/numconv"

buf: [nc.MAX_STR_LEN]u8                       // always big enough for any dtoa output

n := nc.f64_to_shortest(buf[:], 3.14)         // "3.14"            (String(x), base 10)
n  = nc.f64_to_radix(buf[:], 255, 16)         // "ff"              (Number.prototype.toString(16))
n  = nc.f64_to_fixed(buf[:], 1.5, 3)          // "1.500"           (toFixed(3))
n  = nc.f64_to_exponential(buf[:], 12345, 2)  // "1.23e+4"         (toExponential(2))
n  = nc.f64_to_precision(buf[:], 12345, 3)    // "1.23e+4"         (toPrecision(3))

v := nc.parse_number("  0x1f ")               // 31   (Number(): trimmed, whole string, 0x/0o/0b)
v  = nc.parse_float("3.14abc")                // 3.14 (longest decimal prefix)
v  = nc.parse_int("0x1f zzz", 0)              // 31   (integer only, 0x prefix, trailing ignored)
```

For a tighter bound than `MAX_STR_LEN`, `dtoa_max_len(d, radix, n_digits, format, exp_mode) + 1`
gives the exact buffer size a specific call needs.

## What matches QuickJS, and how we know

The core (`dtoa.odin`) is Bellard's bignum algorithm, not a Ryū/Grisu rewrite, precisely so the
*shortest round-tripping* decimal is chosen identically — including the tie-breaking that decides, for
a value exactly between two short decimals, which one wins. `atod` is the correctly-rounded parse (the
same bignum, run the other way), so `parse_float` is round-to-nearest-ties-to-even in every base.

A differential judge (kept out of the tree) compiles QuickJS's own `dtoa.c` with `zig cc` and compares
the two, byte for byte, over:

- **2,000,000+ random f64** (uniform random bits), plus every structured edge case: ±0, ±∞, NaN, the
  smallest and largest subnormals, the smallest and largest normals, 0.1, 1/3, π, e, 1e16…1e23, and
  thousands of small integers and half-integers;
- **toString in radix 2–36**, **toFixed/toExponential/toPrecision** with every digit count 0–100;
- **atod** on the shortest string of each random f64 (round trip) and on 200,000 adversarial strings
  built from the characters `0-9 e E . + - _ ` (space).

The result is **0 mismatches**. Speed is on par with the C: `f64_to_shortest` ≈ 1.34 µs/call and
`atod` ≈ 0.5 µs/call, the same as QuickJS compiled with `-O2`.

## Shape of the port

- `itoa.odin` — integer → ASCII (`u32toa`, `i64toa_radix`, …), used by the small-integer fast paths.
- `dtoa.odin` — the `Mpb` stack bignum, the pow/log tables, `dtoa` (the exact equivalent of
  `js_dtoa`) and `atod` (`js_atod`), with Odin idioms where they are natural (slices and bit-sets for
  the flags, `transmute` for the bit casts, `intrinsics.count_leading_zeros` for `clz`).
- `numconv.odin` — the public ECMAScript surface, including full-Unicode whitespace skipping for the
  `Number()`/`parseFloat`/`parseInt` entry points.

## Integration

The engine calls `f64_to_shortest` wherever it used `js_dtoa(..., FORMAT_FREE)`, the `f64_to_*`
helpers for the four `Number.prototype` methods (the flag mapping is encoded in those helpers), and
`parse_number`/`parse_float`/`parse_int` for the coercions. The integer-tagged fast paths
(`i32_to_string`, `i64_to_string_radix`) cover `ToString` of an integer Number without touching the
bignum.
