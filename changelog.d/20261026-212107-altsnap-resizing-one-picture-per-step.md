type: Changed

**AltSnap resizing: one picture per step** (toolkit 0.35.2 `ui.wake_due` / `ui.wake_in_ms`): the second frame of each step came from the loop woken by the `WM_SIZING` AltSnap sends before the step, which made a frame because a caret blink was asked for (not yet due); `wren ctl stats` now says why the frames of a resize were made (`resizeFrameCauses`: `Ui_Timer` 882 of 1544 before). `tools\altdrag_sim.ps1 -Variants altsnap`: 893 presents for 500 steps to 494, CPU 969 to 578 ms.
