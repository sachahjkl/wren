package media

import "core:sys/posix"
import "core:time"

foreign import pthread_lib "system:pthread"

@(private = "file")
foreign pthread_lib {
	pthread_setname_np :: proc(thread: posix.pthread_t, name: cstring) -> posix.Errno ---
}

// The calling thread's name, as top, gdb and /proc/<pid>/task/<tid>/comm show it (the kernel keeps 15 bytes).
name_current_thread :: proc(name: string) {
	buf: [16]u8
	n := min(len(name), 15)
	copy(buf[:n], name[:n])
	pthread_setname_np(posix.pthread_self(), cstring(raw_data(buf[:])))
}

// Monotonic nanoseconds (CLOCK_MONOTONIC: the clock the audio output's positions are stamped with too).
mono_ns :: proc "contextless" () -> i64 { return i64(time.tick_now()._nsec) }

// No component runtime to start on a decoder's thread.
com_thread_init_any :: proc() {}
