package host

import "base:intrinsics"
import "core:sys/linux"
import "core:sys/posix"

foreign import pthread_lib "system:pthread"

@(private)
foreign pthread_lib {
	pthread_setname_np :: proc(thread: posix.pthread_t, name: cstring) -> posix.Errno ---
}

Native_Thread :: struct {
	handle: posix.pthread_t,
	tid:    i32,   // atomic: the kernel's id, set by the thread itself (its nice value is per thread)
}

// Linux has no thread priority classes: a thread's nice value (higher is lower priority) is its own. The steps are
// those of Windows' THREAD_PRIORITY_BELOW_NORMAL / LOWEST relative to their process: a clear but bounded yield.
// (the scheduler here does not starve a higher nice value: nothing to raise the interface thread above)
thread_raise_interface :: proc() {}

// The calling thread's name, as debuggers and profilers show it (the kernel keeps 15 bytes).
thread_name_self :: proc(name: string) {
	buf: [16]u8
	copy(buf[:15], name)
	pthread_setname_np(posix.pthread_self(), cstring(raw_data(buf[:])))
}

@(private)
nice_of :: proc(p: Thread_Priority) -> i32 {
	switch p {
	case .Normal:       return 0
	case .Below_Normal: return 5
	case .Lowest:       return 10
	}
	return 0
}

// The alternate signal stack of each thread this package starts: a signal handler needs a stack, a thread whose own has
// overflowed has none, and the kernel then kills the process at once (no crash report: crashtrace's handler asks for the
// alternate stack, which only the main thread had). Mapped at the thread's start, pages given by the kernel only when a
// handler runs on them; unmapped at its end. As large as crashtrace's own for the main thread: the report's handler
// unwinds through libgcc there. A Wasmtime of the thread keeps a stack of this size rather than make its own.
@(private = "file")
SIGNAL_STACK_BYTES :: 256 * 1024

// This thread's alternate signal stack (nil: none could be made, the thread runs anyway).
@(private = "file")
signal_stack_begin :: proc "contextless" () -> rawptr {
	mem, err := linux.mmap(0, SIGNAL_STACK_BYTES, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	if err != .NONE { return nil }
	ss := posix.stack_t{ss_sp = mem, ss_size = SIGNAL_STACK_BYTES}
	if posix.sigaltstack(&ss, nil) != .OK { linux.munmap(mem, SIGNAL_STACK_BYTES); return nil }
	return mem
}

// The thread ends: its alternate stack goes, unless another took its place (what installed that one restores ours later,
// which must then still be there).
@(private = "file")
signal_stack_end :: proc "contextless" (mem: rawptr) {
	if mem == nil { return }
	now: posix.stack_t
	if posix.sigaltstack(nil, &now) != .OK || now.ss_sp != mem { return }
	off := posix.stack_t{ss_flags = {.DISABLE}}
	if posix.sigaltstack(&off, nil) != .OK { return }
	linux.munmap(mem, SIGNAL_STACK_BYTES)
}

@(private)
native_thread_start :: proc(t: ^Thread, stack_bytes: int) -> bool {
	attr: posix.pthread_attr_t
	if posix.pthread_attr_init(&attr) != .NONE { return false }
	defer posix.pthread_attr_destroy(&attr)
	if stack_bytes > 0 { posix.pthread_attr_setstacksize(&attr, uint(stack_bytes)) }
	return posix.pthread_create(&t.native.handle, &attr, thread_entry, t) == .NONE
}

@(private)
thread_entry :: proc "c" (arg: rawptr) -> rawptr {
	t := (^Thread)(arg)
	signal_stack := signal_stack_begin()
	defer signal_stack_end(signal_stack)
	context = t.ctx
	tid := i32(linux.gettid())
	intrinsics.atomic_store(&t.native.tid, tid)
	if t.name_len > 0 {
		// the kernel keeps 15 bytes (what top, gdb and /proc/<pid>/task/<tid>/comm show)
		buf: [16]u8
		n := min(t.name_len, 15)
		copy(buf[:n], t.name[:n])
		pthread_setname_np(posix.pthread_self(), cstring(raw_data(buf[:])))
	}
	if t.priority != .Normal {
		base_nice, _ := linux.getpriority(.PROCESS, 0)
		// getpriority's system call answers 20 - nice
		linux.setpriority(.PROCESS, tid, (20 - base_nice) + nice_of(t.priority))
	}
	thread_run(t)
	return nil
}

// Lowering a nice value needs CAP_SYS_NICE (or RLIMIT_NICE): best effort, as the thread runs anyway.
@(private)
native_thread_boost :: proc(t: ^Thread) {
	tid := intrinsics.atomic_load(&t.native.tid)
	if tid == 0 { return }
	base_nice, _ := linux.getpriority(.PROCESS, 0)
	linux.setpriority(.PROCESS, tid, 20 - base_nice)
}

@(private)
native_thread_wait :: proc(t: ^Thread) { posix.pthread_join(t.native.handle, nil) }

@(private)
native_thread_close :: proc(t: ^Thread) {}

@(private)
native_processor_count :: proc() -> int {
	mask: [128]u64   // 8192 processors
	n, err := linux.sched_getaffinity(0, size_of(mask), &mask)
	if err != .NONE || n <= 0 { return 1 }
	count := 0
	for w in mask[:min(n / 8, len(mask))] { count += int(intrinsics.count_ones(w)) }
	return count
}
