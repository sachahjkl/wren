type: Added

**`wren ctl stats` counts the frames' presents and the gaps between them** (`src/browser/frame_log.odin`, `stats --reset-frames`): `framesPresented`, `frameGapP50Ms` / `P95` / `P99` / `MaxMs`, and from the toolkit's `platform.pump_stats` `paintFrames`, `modalLoops`, `ignoredSizeMoves`. `tools\altdrag_sim.ps1` uses them: what AltSnap does to a window (a run of `SetWindowPos` from another thread, the posted `WM_ENTERSIZEMOVE` / `WM_EXITSIZEMOVE`, the `WM_SIZING` sent before each step), with no mouse and no AltSnap, and how long each call took to return.
