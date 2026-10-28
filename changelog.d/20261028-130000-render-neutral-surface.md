type: Changed

**The shell opens the renderer through neutral window handles**: the main window, the developer-tools window and the fixed-surface size no longer pass an `HWND` to `render`; they use `render.init_window` / `render.surface_init` with `platform.native_surface_handles`, and `platform.monitor_size`, so the render path builds on Linux (wgpu) as well as Windows. The Win32-only placement details (raise-to-top, client-rect, hide-on-close, the menu-command subclass) sit behind `when ODIN_OS == .Windows`.
