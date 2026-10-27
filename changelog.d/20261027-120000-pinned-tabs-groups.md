type: Added

**Pinned tabs and tab groups** (`tab.pin`, `tab.group_new`, `browser.tabs.restore_pinned`) : pinned tabs sit first, as a grid of icons at the top of the tab sidebar and as icons in the row of tabs; groups have a name, one of nine colours and fold away in the sidebar under a header; tabs are pinned, unpinned, put in or taken out of a group from their menu, by dragging in the sidebar or by commands; both are saved with the session, and the pinned tabs come back at the next start even without it.
  - `wren ctl tabs --json` gives each tab's `pinned`, `group` and `rect`, and the windows' `tabGroups`.
