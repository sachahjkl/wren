type: Added

**Files dropped from another application reach the page** (toolkit 0.35.0 OLE drop target, replacing `WM_DROPFILES` except in an elevated browser): a page that cancels `dragover` or `drop` keeps the drop; elsewhere the file opens as before (`browser.drop.open_files`), and a dropped link loads (`browser.drop.open_links`, new). Over the tab strip or the toolbar a dropped file or link opens in a new tab, over the address field in the current one. `browser.dnd.page_events` turns the page's events off.
