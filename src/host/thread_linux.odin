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
@(private)
nice_of :: proc(p: Thread_Priority) -> i32 {
	switch p {
	case .Normal:       return 0
	case .Below_Normal: return 5
	case .Lowest:       return 10
	}
	return 0
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
