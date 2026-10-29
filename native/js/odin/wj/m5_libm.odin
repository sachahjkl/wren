// m5_libm.odin: the libm functions the geometry, canvas and Intl glue use (Odin's core:math: the module has no C library), under a
// libm_ prefix, as the C these domains replace called them.
package wj

import "core:math"

libm_sin   :: proc "contextless" (x: f64) -> f64 { return math.sin(x) }
libm_cos   :: proc "contextless" (x: f64) -> f64 { return math.cos(x) }
libm_tan   :: proc "contextless" (x: f64) -> f64 { return math.tan(x) }
libm_atan2 :: proc "contextless" (y, x: f64) -> f64 { return math.atan2(y, x) }
libm_hypot :: proc "contextless" (x, y: f64) -> f64 { return math.sqrt(x * x + y * y) }
libm_floor :: proc "contextless" (x: f64) -> f64 { return math.floor(x) }
libm_pow   :: proc "contextless" (x, y: f64) -> f64 { return math.pow(x, y) }
libm_log10 :: proc "contextless" (x: f64) -> f64 { return math.log10(x) }
// C's round (half away from zero), written here: the module is linked with no C library, and an Odin `math.round` would
// lower to the very `round` symbol that is missing.
libm_round :: proc "contextless" (x: f64) -> f64 {
	t := math.trunc(x)
	d := x - t
	if d >= 0.5 { return t + 1 }
	if d <= -0.5 { return t - 1 }
	return t
}
