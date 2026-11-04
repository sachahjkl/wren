package trace

// Tracy's C API (public/tracy/TracyC.h of the release src/tools/wrentool/deps/tracy.odin pins), what Wren calls of it. The
// client is built with TRACY_ON_DEMAND: a zone begun while no viewer is connected is inactive and costs a test.

#assert(!TRACY || ODIN_OS == .Windows, "the Tracy client is built on Windows (wrentool build tracy)")

when TRACY {

foreign import tracy_lib {
	"../../build/tracy/tracy.lib",
	"system:libcpmt.lib",   // (C++'s standard library, static as the rest of the C runtime)
	"system:ws2_32.lib",
	"system:advapi32.lib",
	"system:user32.lib",
}

// ___tracy_source_location_data
Tracy_Location :: struct {
	name, function, file: cstring,
	line, color:          u32,
}

// ___tracy_c_zone_context (with the connection id of TRACY_ON_DEMAND)
Tracy_Ctx :: struct {
	id:         u32,
	active:     i32,
	connection: u64,
}

TRACY_SEVERITY_INFO :: 2   // TracyMessageSeverityInfo

@(private, default_calling_convention = "c")
foreign tracy_lib {
	___tracy_emit_zone_begin :: proc(srcloc: ^Tracy_Location, active: i32) -> Tracy_Ctx ---
	___tracy_emit_zone_end :: proc(ctx: Tracy_Ctx) ---
	___tracy_emit_frame_mark :: proc(name: cstring) ---
	___tracy_emit_plot :: proc(name: cstring, value: f64) ---
	___tracy_emit_logString :: proc(severity: i8, color: i32, callstack_depth: i32, size: uint, text: [^]u8) ---
}

@(private) tracy_begin :: #force_inline proc "contextless" (l: ^Tracy_Location) -> Tracy_Ctx { return ___tracy_emit_zone_begin(l, 1) }
@(private) tracy_end :: #force_inline proc "contextless" (c: Tracy_Ctx) { ___tracy_emit_zone_end(c) }
@(private) tracy_frame :: proc "contextless" () { ___tracy_emit_frame_mark(nil) }
@(private) tracy_plot :: proc "contextless" (name: cstring, value: f64) { ___tracy_emit_plot(name, value) }
@(private) tracy_message :: proc "contextless" (text: string) { ___tracy_emit_logString(TRACY_SEVERITY_INFO, 0, 0, uint(len(text)), raw_data(text)) }

} else {

Tracy_Location :: struct {}
Tracy_Ctx :: struct {}

}
