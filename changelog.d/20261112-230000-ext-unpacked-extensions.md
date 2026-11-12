type: Added

**Browser extensions, first step**: `about:extensions` loads an unpacked Manifest V3 extension (Chrome build) from its folder, asks before it installs it, and lists, enables, disables, reloads and removes the extensions installed, with the sites each may access. An extension's button shows in the toolbar with its icon and badge; a click opens its popup page. Its background service worker, `chrome.storage`, messages and ports, alarms, `chrome.i18n` and the action, tabs and windows queries work; the other APIs come in later steps.
