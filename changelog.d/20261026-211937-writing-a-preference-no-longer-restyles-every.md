type: Fixed

**Writing a preference no longer restyles every page** (`style.engine_configure`, `page.configure_styles`): every preference change, the developer tools' size written when the separator is released included, handed every page its settings again, which recompiled the browser's own sheets and restyled the whole document at the next frame (an 85 ms frame labelled "Tasks, timers and input" when a script read the layout). The engine compares the settings and keeps its rules and styles when they are the same.
