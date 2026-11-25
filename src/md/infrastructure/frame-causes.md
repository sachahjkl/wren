# Typed Frame Causes and Automatic Layout Settle

`src/browser/windows.odin` tracks why a window needs a frame with `Frame_Cause` and `Frame_Causes` instead of numeric frame counts (`request_frames(app, n)`) and a separate `Frame_Errand` bit set.

## Problem

Numeric frame counts (`n = 2`, `3`, `4`) force every caller to guess how many immediate-mode UI builds a change needs to settle. Because `windows_pass` decremented `frames_requested` after `frame()`, any in-frame request had to pass at least `2`, and changes that resized chrome or `page_rect` guessed `3` or `4`. Meanwhile, `Frame_Errand` tracked quiet at-rest work (`.Caret`, `.Status_Bar`, `.Reader`) in a separate side channel with special-case merging rules (`errands_after_request`).

## Design

- **One typed cause set (`Frame_Cause` / `Frame_Causes`)**: `Input`, `Layout`, `Style`, `Page`, `Chrome`, `Animation`, `Media`, `Caret`, `Status_Bar`, `Reader`, and `Remote`.
- **Errands are a subset, not a separate state machine**: `FRAME_ERRAND_CAUSES = {.Caret, .Status_Bar, .Reader}`. A frame is errand-only when it ran solely for `.Asked`, has no pending legacy `frames_requested`, and `frame_causes != {} && frame_causes <= FRAME_ERRAND_CAUSES`. Multiple errands merge naturally by bit-set union; any non-errand cause makes the frame active.
- **Consume at frame entry (`window_frame_begin`)**: When `frame()` commits to building and drawing, it moves `w.causes` into `w.frame_causes` and clears `w.causes = {}`. Any `window_invalidate` called during input handling, page update, or `build_ui` accumulates into `w.causes` for the next frame.
- **Automatic layout follow-up (`window_layout_check`)**: After `ui.end_build()`, Wren hashes the built UI box tree (`b.key`, `b.rect`, and scrollable boxes' `view_bounds` and `view_off`) with a zero-allocation iterative traversal (`ui_layout_signature`). When the signature changes from the previous active build, `window_note_layout` schedules one `.Layout` follow-up. Errand-only frames (`.Caret`, `.Status_Bar`, `.Reader`) record the updated signature without scheduling an extra follow-up frame so idle settling stays at one frame. Consecutive automatic layout follow-ups are bounded by `MAX_LAYOUT_FOLLOWUPS` (3) so an oscillating layout cannot spin the loop.
- **Explicit rest predicate (`window_at_rest`)**: True when `w.causes == {}`, `w.frames_requested == 0`, and `w.ui` has neither `needs_frame` nor `wake_due`.
- **Loop telemetry separation**: `loop_rates.odin` keeps `Loop_Cause :: api.Frame_Cause` for the remote wire protocol (`Loop_Stats`) so existing remote clients, `wrentool bench idle`, and e2e assertions keep working unchanged.

## Transitional Helper

`request_frames` and `window_request` remain temporarily for subsystems not yet migrated. Once all remaining callers move to `window_invalidate` / `app_invalidate`, delete `frames_requested`, `window_request`, `request_frames`, and `windows_spill`.
