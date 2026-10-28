// m6_libc.odin: the libm symbols the engine core's ports use beyond libc.odin's (wasi-libc, same module).
package wj

@(default_calling_convention = "c")
foreign {
	floor :: proc(x: f64) -> f64 ---
}

NAN_F64 :: f64(0h7FF8_0000_0000_0000)
INF_F64 :: f64(0h7FF0_0000_0000_0000)
