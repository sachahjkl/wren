type: Changed

**One picture per step while another program resizes the window** (`browser.frame.resize_skip_echoes`, `src/browser/pacing.odin`): the frames of the burst after a step that would show the same picture are not made. `tools\altdrag_sim.ps1`, 500 steps in 3 s: `plain` 988 presents to 494, CPU 1078 to 531 ms; `altsnap` 1599 to 893, CPU 1938 to 969 ms.
