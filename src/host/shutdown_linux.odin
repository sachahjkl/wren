package host

import "core:sys/linux"

// Lowering the process's nice value below where it started needs CAP_SYS_NICE: an ordinary user's process cannot be
// raised above normal, so the teardown keeps the priority it has.
@(private)
shutdown_raise_priority :: proc() {}

// (`ctl stacks` is written for Windows only.)
@(private)
shutdown_read_stacks :: proc(program, path: string, wait_ms: int) {}

// exit_group, not exit(3): no atexit handler or stdio flush may wait for the thread that hangs.
@(private)
shutdown_force_exit :: proc() -> ! {
	linux.exit_group(0)
}

// The process ends now, with this code: every thread and every library left as they are. Whatever must reach a disk has been written before this.
process_end :: proc(code: int) -> ! {
	linux.exit_group(i32(code))
}
