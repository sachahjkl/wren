package base

import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"

@(private = "file")
unique_counter: u64

// A name no other call of any process has made: process id, clock in nanoseconds, and a counter of this process. The clock
// alone is not unique: the unit tests of a package start on several threads at once, and two of them read the same
// nanosecond (seen on a loaded machine and on the CI runner), took the same scratch folder or profile key, and one
// removed what the other was using.
unique_name :: proc(allocator := context.allocator) -> string {
	n := sync.atomic_add(&unique_counter, 1)
	return fmt.aprintf("%d_%d_%d", os.get_pid(), time.to_unix_nanoseconds(time.now()), n, allocator = allocator)
}
