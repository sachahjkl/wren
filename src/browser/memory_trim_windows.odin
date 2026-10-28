package browser

// Giving memory back on Windows (memory_trim.odin has the neutral part): the Direct3D device's lazily-held pools
// (IDXGIDevice3::Trim after a context flush, what the system asks of an application that stops drawing) and the process
// heaps' free blocks (HeapCompact). Guarded by the Direct3D backend: a wgpu build on Windows, if ever made, has no
// app.r.ctx / app.r.device, and the driver manages its own pools then. memory_trim_other.odin is the Linux counterpart.

import "core:sys/windows"
import "vendor:directx/dxgi"
import "toolkit:render"

foreign import kernel32_trim "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32_trim {
	@(link_name = "GetProcessHeaps") trim_GetProcessHeaps :: proc(n: u32, heaps: [^]windows.HANDLE) -> u32 ---
	@(link_name = "HeapCompact") trim_HeapCompact :: proc(heap: windows.HANDLE, flags: u32) -> uint ---
}

memory_trim_native :: proc(app: ^App) {
	when !render.USE_WGPU {
		if app.r.ctx != nil { app.r.ctx->Flush() }
		if app.r.device != nil {
			dev3: ^dxgi.IDevice3
			if windows.SUCCEEDED(app.r.device->QueryInterface(dxgi.IDevice3_UUID, (^rawptr)(&dev3))) {
				dev3->Trim()
				dev3->Release()
			}
		}
	}
	heaps: [64]windows.HANDLE
	n := min(int(trim_GetProcessHeaps(len(heaps), &heaps[0])), len(heaps))
	for i in 0 ..< n { trim_HeapCompact(heaps[i], 0) }
}
