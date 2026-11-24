// m6_libc.odin: the libm functions the engine core's ports use beyond libc.odin's.
package wj

import "core:math"

// (no libc is linked into the image: declared as a foreign `floor`, it was an env.floor import that an optimised build
// folded into f64.floor and a -o:minimal one left unresolved, which stopped a page's scripts at its first call)
floor :: proc "contextless" (x: f64) -> f64 { return math.floor(x) }

NAN_F64 :: f64(0h7FF8_0000_0000_0000)
INF_F64 :: f64(0h7FF0_0000_0000_0000)
