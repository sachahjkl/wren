package crashmodes

import "base:intrinsics"
import "core:sys/posix"
import "core:time"
import "wb:tools/crashtrace"

foreign import libc "system:c"
@(default_calling_convention = "c")
foreign libc {
	malloc :: proc(size: uint) -> rawptr ---
	free   :: proc(p: rawptr) ---
	abort  :: proc() -> ! ---
}

@(private = "file")
block: rawptr

die_system :: proc(mode: string) {
	switch mode {
	case "heap":
		// glibc's own check: a block freed twice ("free(): double free detected": abort). Through a volatile slot: the
		// optimizer knows malloc and free and would drop the pair.
		intrinsics.volatile_store(&block, malloc(64))
		free(intrinsics.volatile_load(&block))
		free(intrinsics.volatile_load(&block))
	case "failfast":
		abort()
	case "clean":
		time.sleep(500 * time.Millisecond)
		crashtrace.end_session()
	case "exit":
		posix._exit(9)
	}
}
