type: Changed

**Writing a preference only configures again what it concerns** (`src/browser/prefs_apply.odin`): a write of `browser.tabs.sidebar_width` (each step of a drag of the sidebar's edge) no longer hands the network client, the HTTP cache and the downloads their settings again; `wren ctl stats` counts it (`prefsNetApplied`...).
