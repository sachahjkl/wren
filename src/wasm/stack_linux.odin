package wasm

import "core:sys/posix"

foreign import pthread_lib "system:pthread"
@(private = "file")
foreign pthread_lib {
	pthread_getattr_np :: proc(thread: posix.pthread_t, attr: ^posix.pthread_attr_t) -> posix.Errno ---
}

// A thread's stack stays where it is: asked once. For the main thread glibc reads /proc/self/maps at each call, milliseconds with the mappings of a page, and a script calls
// into its engine at every turn of its loops: pages froze for minutes, on Linux only (vimeo.com, css-tricks.com, 65 % of the time in the system).
@(thread_local, private = "file") stack_low: uintptr
@(thread_local, private) stack_low_reads: int

// The lowest address of the calling thread's stack (stacks grow down: what is left is here - low). For the main thread
// glibc derives it from RLIMIT_STACK. 0 (every check passes) when the system cannot say.
@(private)
thread_stack_low :: proc() -> uintptr {
	if stack_low != 0 { return stack_low }
	stack_low_reads += 1
	attr: posix.pthread_attr_t
	if pthread_getattr_np(posix.pthread_self(), &attr) != .NONE { return 0 }
	defer posix.pthread_attr_destroy(&attr)
	addr: [^]byte
	size: uint
	if posix.pthread_attr_getstack(&attr, &addr, &size) != .NONE { return 0 }
	stack_low = uintptr(addr)
	return stack_low
}
