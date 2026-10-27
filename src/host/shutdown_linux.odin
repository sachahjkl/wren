package host

import "core:sys/linux"

// Lowering the process's nice value below where it started needs CAP_SYS_NICE: an ordinary user's process cannot be
// raised above normal, so the teardown keeps the priority it has.
@(private)
shutdown_raise_priority :: proc() {}

// exit_group, not exit(3): no atexit handler or stdio flush may wait for the thread that hangs.
@(private)
shutdown_force_exit :: proc() -> ! {
	linux.exit_group(0)
}
