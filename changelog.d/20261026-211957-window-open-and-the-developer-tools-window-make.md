type: Fixed

**`window_open` and the developer tools' window make their `render.Surface` where it lives** (`render.surface_init`, toolkit 0.42.1), and the comment of `build.bat` on the compile time of the separate-module builds gives the measured numbers (the Odin step of the development build: about 25 s; `release`: 140 to 230 s) and the trap to look for when it takes minutes more.
