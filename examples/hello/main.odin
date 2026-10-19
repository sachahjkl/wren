// A page script written in Odin and compiled to freestanding Wasm. No JavaScript, no glue: the imports below are
// resolved by the browser itself.
package hello

foreign import console "console"

@(default_calling_convention = "contextless")
foreign console {
	@(link_name = "console_log")
	log :: proc(ptr: [^]u8, len: u32) ---
}

say :: proc "contextless" (s: string) { log(raw_data(s), u32(len(s))) }

counter: int

@(export)
wb_main :: proc "contextless" () {
	say("hello from Odin, running as Wasm")
}

@(export)
add :: proc "contextless" (a, b: i32) -> i32 { return a + b }

@(export)
spin :: proc "contextless" () {
	// an infinite loop: the host must be able to stop it
	for { counter += 1 }
}
