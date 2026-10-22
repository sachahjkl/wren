#+build !windows
#+build !linux
#+build !darwin
package desktop

// Any other target: no desktop integration.

@(private)
platform_backend :: proc() -> ^Backend { return nil }

set_process_identity :: proc(id: Identity) {}
