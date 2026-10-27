type: Added

**visibility-state timeline entries** (`PerformanceObserver` type `visibility-state`, `VisibilityStateEntry`, pref `performance.visibility_state_entries`) : each time the page becomes visible or hidden (and once for its state at the first paint) an entry named `visible` or `hidden` is recorded with its `startTime`. `PerformanceObserver.supportedEntryTypes` lists it.
