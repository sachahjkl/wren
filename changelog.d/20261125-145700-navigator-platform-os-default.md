type: Fixed

**`navigator.platform` default on Linux and macOS** (`navigator.platform`): `navigator.platform` now defaults to `Linux x86_64` on Linux and `MacIntel` on macOS (keeping `Win32` on Windows), matching the operating system token in `User-Agent` instead of reporting `Win32` on every platform.
