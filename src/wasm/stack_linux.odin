package wasm

import "core:sys/posix"

foreign import pthread_lib "system:pthread"
@(private = "file")
foreign pthread_lib {
	pthread_getattr_np :: proc(thread: posix.pthread_t, attr: ^posix.pthread_attr_t) -> posix.Errno ---
}

// The lowest address of the calling thread's stack (stacks grow down: what is left is here - low). For the main thread
// glibc derives it from RLIMIT_STACK. 0 (every check passes) when the system cannot say.
@(private)
thread_stack_low :: proc() -> uintptr {
	attr: posix.pthread_attr_t
	if pthread_getattr_np(posix.pthread_self(), &attr) != .NONE { return 0 }
	defer posix.pthread_attr_destroy(&attr)
	addr: [^]byte
	size: uint
	if posix.pthread_attr_getstack(&attr, &addr, &size) != .NONE { return 0 }
	return uintptr(addr)
}
