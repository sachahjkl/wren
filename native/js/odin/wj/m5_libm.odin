// m5_libm.odin: the libm functions the geometry, canvas and Intl glue use (wasi-libc's, in the same module), under a
// libm_ prefix: the C these domains replace called them, and keeping the same implementation keeps the serialised
// numbers bit-identical (an Odin core:math sin differs from musl's in the last place for some inputs).
package wj

@(default_calling_convention = "c")
foreign {
	@(link_name = "sin")   libm_sin   :: proc(x: f64) -> f64 ---
	@(link_name = "cos")   libm_cos   :: proc(x: f64) -> f64 ---
	@(link_name = "tan")   libm_tan   :: proc(x: f64) -> f64 ---
	@(link_name = "atan2") libm_atan2 :: proc(y, x: f64) -> f64 ---
	@(link_name = "hypot") libm_hypot :: proc(x, y: f64) -> f64 ---
	@(link_name = "floor") libm_floor :: proc(x: f64) -> f64 ---
	@(link_name = "pow")   libm_pow   :: proc(x, y: f64) -> f64 ---
	@(link_name = "log10") libm_log10 :: proc(x: f64) -> f64 ---
	@(link_name = "round") libm_round :: proc(x: f64) -> f64 ---
}
