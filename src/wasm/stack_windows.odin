package wasm

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system", private = "file")
foreign kernel32 {
	GetCurrentThreadStackLimits :: proc(low, high: ^uintptr) ---
}

// The lowest address of the calling thread's stack (stacks grow down: what is left is here - low).
@(private)
thread_stack_low :: proc() -> uintptr {
	low, high: uintptr
	GetCurrentThreadStackLimits(&low, &high)
	return low
}
