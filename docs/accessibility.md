# Accessibility

Wren is read by screen readers (NVDA, Narrator, JAWS) and other assistive technologies through UI Automation. The
toolkit makes the accessibility tree of the interface from its boxes and hands it to AccessKit
(`ext/gui_toolkit/docs/accessibility.md`); Wren says what only a browser knows.

## Build

`native/media` builds the toolkit's adapter (`ext/gui_toolkit/native/a11y`, AccessKit 0.25 and its Windows adapter) into
`wren_media.lib` (feature `a11y`: a program links one Rust static library), and `build.bat` builds with
`-define:A11Y_ACCESSKIT=true -define:A11Y_NATIVE_LINK=false`. The crates are listed in `native/media/rust-crates.txt`
(about:licenses).

Nothing is built until an assistive technology asks for a window's tree; from then on each frame sends the nodes that
changed. `wren ctl stats --json` says what was sent: `a11yUpdates`, `a11yRefused`, `a11yLastNodes`, `a11yNodes`.

## The interface

| Part | Role | What it says |
|---|---|---|
| Tab strip, tab sidebar | TabList ("Tabs", horizontal / vertical) | |
| A tab | Tab | the page's title (else its address, else "New tab"), selected, "3 of 12", busy while loading; its close button inside |
| Back, Forward, Reload, New tab, Menu, the blocker's shield, Page information | Button | named by their tooltip, its shortcut (Alt+Left, F5, Ctrl+T...), the tooltip as description; disabled when they cannot act; Menu: expanded, has a menu |
| Address bar | Edit ("Address and search bar", Ctrl+L) | its text, caret and selection (text runs), the placeholder; while suggestions show: expanded, controls the list, the chosen suggestion read as the focus |
| Suggestions | ListBox of ListBoxOptions | title, address, what Enter does |
| Menus (main menu, context menus) | Menu, MenuItem | the commands' titles and shortcuts, checked items, submenus |
| Caption buttons | Button | Minimize, Maximize / Restore, Close (`i18n.tr`) |
| Status bar | Status | its items as text, their tooltips as descriptions |
| Toasts | Alert / Status | announced when they appear |
| Sidebar's resize handle | Splitter | the width |
| DevTools | Tab per panel, Buttons | the panels' titles; buttons named by their tooltips, toggles say on / off |

The names go through `i18n.tr` (the tooltips of the chrome were already its texts). The helpers are in
`src/browser/a11y_chrome.odin`: `chrome_tip_a11y` (a button named by its tooltip: "Back (Alt+Left); right click:
history" is "Back", shortcut "Alt+Left"), `tab_a11y`, `tab_list_a11y`.

## Pages

The pages' own tree (roles from HTML and ARIA, accessible names, focus, live regions, text) is the next step: the page
area becomes a graft node and each document a tree of its own (`A11y_Info.graft`, `platform.a11y_send`).

## Testing

- `tools\a11y_e2e.ps1` (in `test_all`): a Wren started by `wren ctl` with no window shown is read through UI Automation
  by the toolkit's `uia_probe` (built into `build\uia_probe.exe` when stale): the chrome's roles, names and states, then
  invoke New tab, set the address bar's value, select a tab, expand and collapse the menu.
- By hand: `build\uia_probe.exe dump --pid <pid of wren.exe>` prints every element as a screen reader sees it.
- With a person: NVDA and Narrator (what they say, browse and focus modes): see the session note of 2026-10-26.
