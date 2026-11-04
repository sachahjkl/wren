type: Fixed

**Frames sandboxed without scripts**: the parent's scripts keep what they set on such a frame's window, and its `open()` opens a window as the frame does, sandboxed as it is.
