Type: Changed

**A new tab puts the keyboard in the address bar, with no list until a click** (`browser.newtab.focus_address`, now on by default; `src/browser/urlbar.odin`): Ctrl+T, Ctrl+N and the + of the strip focus the field as Chromium does, and the list of pages visited (`browser.urlbar.top_sites`) opens only for a click in the field (or a letter typed), not for the keyboard put there by a new tab, Ctrl+L or Tab.
