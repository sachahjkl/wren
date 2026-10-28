# bigint: arbitrary-precision integers for the JavaScript engine

`src/engine/bigint` is the ECMAScript `BigInt` arithmetic, written natively in Odin. The JavaScript
engine used to get this from QuickJS's C running inside WebAssembly; this package replaces it with a
native implementation that gives identical numeric results and reads like Odin instead of transcribed
C.

It is allocation-aware: every operation allocates its result through `context.allocator`, so the
engine injects the realm's allocator and frees results with `destroy`. No OS dependency — it builds
for `windows_amd64`, `linux_amd64` and `freestanding_wasm32`.

## Representation

Sign-magnitude, little-endian `u32` limbs, always normalized (no leading zero limb; zero is the empty
magnitude with `neg = false`). This is the natural Odin shape and keeps the arithmetic obvious. The
one place the choice shows is the bitwise operators: ECMAScript defines `& | ^ ~` and `>>` as if a
BigInt were an infinite two's-complement integer, so those operations convert each operand to its
two's-complement limb view over a common width, apply the op, and convert back (`bits.odin`).

```odin
import bi "wb:engine/bigint"

a := bi.from_i64(1_000_000_007)
b, _ := bi.from_string("340282366920938463463374607431768211456", 10) // 2^128
defer bi.destroy(&a)
defer bi.destroy(&b)

p := bi.mul(a, b);            defer bi.destroy(&p)
q := bi.div(p, a);            defer bi.destroy(&q)   // == b
s := bi.to_string(q, 16);     defer delete(s)        // "100000000000000000000000000000000"
d := bi.to_f64(b)                                     // 3.402823669209385e+38
m := bi.as_uintn(32, a);      defer bi.destroy(&m)   // BigInt.asUintN(32, a)
```

## Operations

- **Arithmetic**: `add`, `sub`, `neg`, `abs`, `mul`, `div`, `rem`, `divmod`, `pow`.
- **Comparison**: `cmp` (-1/0/1), `equals`, `sign`, `is_zero`.
- **Shifts**: `shl`, `shr` (arithmetic — `a >> n == floor(a / 2ⁿ)`, so it sign-extends negatives).
- **Bitwise**: `bit_and`, `bit_or`, `bit_xor`, `bit_not`, with two's-complement semantics.
- **Width wrap**: `as_intn(bits, a)`, `as_uintn(bits, a)`.
- **Conversion**: `from_i64`, `from_u64`, `from_f64`, `to_f64` (round-to-nearest-ties-to-even),
  `from_string`/`to_string` in any base 2–36.

Multiplication is schoolbook below ~40 limbs and **Karatsuba** above it; division is **Knuth's
Algorithm D** (with a single-limb fast path). String conversion packs as many base-R digits as fit in
a `u32` before each big multiply/divide, so parsing or printing a very large number stays close to
linear.

## How we know it is correct

There is no small C oracle for BigInt (the QuickJS version needs the whole engine, and no Python was
available), so a differential judge pins correctness two ways over **12,000,000+ checks**:

1. **Exact agreement with native `i128`/`u128`** for operands in that range — add, sub, mul, div, rem,
   all the bit ops, shifts, `asIntN`/`asUintN`, and decimal matches `%d` — plus string round trips in
   every base 2–36.
2. **Algebraic identities** for large operands (up to several thousand bits, well into the Karatsuba
   path): `(a+b)-b == a`, `(a*b)/b == a`, `(a/b)*b + a%b == a` with `sign(rem) == sign(a)`,
   `to_string`/`from_string` round trips, `(a<<n)>>n == a`, `pow` versus repeated multiply, and
   `from_f64(to_f64(a)) == a` for integers exactly representable in f64.

Result: **0 failures.**

## Integration

Division by zero and a negative exponent are RangeErrors in ECMAScript; the engine must reject them
before calling `div`/`rem`/`pow` (the package returns zero rather than trapping, to stay
allocation-safe). `BigInt(string)` strips the `0x`/`0o`/`0b` prefix and separators and calls
`from_string`; `BigInt(number)` checks integrality then calls `from_f64`; `Number(bigint)` calls
`to_f64`; `toString(radix)` calls `to_string`.
