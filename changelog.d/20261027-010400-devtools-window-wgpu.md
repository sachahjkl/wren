type: Fixed

**Detached developer tools on WebGPU**: the detached developer tools window now works with the WebGPU renderer (`TOOLKIT_RENDER=wgpu`), not only Direct3D 11; the toolkit gained a per-window WebGPU surface (`render.surface_*`) alongside the Direct3D one.
