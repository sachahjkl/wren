#+build !windows
package browser

// Giving memory back off Windows (memory_trim_windows.odin has the Windows device-and-heap trim). The renderer's layer
// targets are already released by the neutral memory_trim; beyond that there is nothing portable to reclaim on demand:
// the wgpu driver manages its own pools (no IDXGIDevice3::Trim equivalent exposed), and glibc's malloc returns free
// arenas to the system on its own (malloc_trim is glibc-specific and best left to the allocator). So this is a no-op.

memory_trim_native :: proc(app: ^App) {}
