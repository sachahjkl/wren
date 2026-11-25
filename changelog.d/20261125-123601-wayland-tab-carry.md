type: Added

**Live window carry for Wayland tab tear-off**: dragging a tab out of its bar on Wayland compositors advertising `xdg-toplevel-drag-v1` now detaches and carries a real browser window attached to the pointer via `platform.Drag_Carry` (or carries the source window itself for a single-tab window), renders live frames while dragging, re-attaches cleanly when dropped back into a Wren tab strip, and falls back to the existing `application/x-wren-tab` drag path on compositors without `xdg-toplevel-drag-v1`.
