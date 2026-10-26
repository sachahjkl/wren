type: Added

**A face with `backface-visibility: hidden` that is turned away is not painted at all** (`paint_planes.odin`, `open_plane`): its layer used to be rasterized (with a shader in it, for the licence card) and thrown away when composited. A plane that keeps its children in 3D is left alone.
