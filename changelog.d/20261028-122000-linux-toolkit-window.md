type: Changed

**Linux portability**: the window wake-up (`wake_window`) now goes through the toolkit's neutral `platform.wake` instead of posting a Win32 message, so it compiles and works on the toolkit's new Linux window backend (Wayland and X11). `build.sh` and `docs/portability.md` note what still blocks the Linux browser executable: the toolkit's render package on wgpu for Linux, and the remaining Win32 calls in `src/browser`.
