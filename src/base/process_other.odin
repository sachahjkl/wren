#+build darwin, freebsd, openbsd, netbsd
package base

// Not measured yet on these systems (macOS: task_info's TASK_VM_INFO phys_footprint).
@(private)
native_process_memory :: proc() -> Process_Memory { return {} }
