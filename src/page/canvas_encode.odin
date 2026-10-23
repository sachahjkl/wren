package page

Canvas_encode :: proc(c: ^Call, canvas: u64, type: string, quality: f64) -> (u64, Api_Error) {
	return 0, fail(c, .Not_Supported, "encoding a canvas is not available")
}
