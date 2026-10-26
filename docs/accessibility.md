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

The current page is a tree of its own (`src/a11y`, package `a11y`), grafted under the page area (`A11y_Info.graft`,
tree id from the tab's id: `page_tree_id`) and sent after the chrome's tree (`src/browser/a11y_page.odin`).

- **Roles** (`roles.odin`): the implicit roles of HTML-AAM (links with `href`, buttons, every `input` type, `select` as
  combo box or list box, `textarea`, headings, landmarks with their scoping rules for `header` / `footer`, `section`
  and `form` only when named, lists, description lists, tables with row and column headers, `img` (`alt=""` is
  decoration), `figure`, `details` / `summary`, `dialog`, `fieldset` / `legend`, `label`, `progress`, `meter`,
  `output`...) and the ARIA `role` attribute (first known token; `none` / `presentation` ignored on focusable
  elements and those with global ARIA).
- **Names and descriptions** (`name.odin`, Accessible Name and Description Computation 1.2): `aria-labelledby`
  (hidden referenced text counts), `aria-label`, the host language (labels `for` and around, `alt`, `caption`,
  `legend`, `figcaption`, the value of input buttons, "Submit" / "Reset", `title` of frames, option labels), the
  content for the roles named by it (embedded controls give their value, block elements are separated), `title`,
  then `placeholder`; descriptions from `aria-describedby`, `aria-description` or `title`.
- **States and properties**: disabled (also through a disabled `fieldset`), checked / mixed / pressed, selected,
  expanded (`aria-expanded`, a `details`' summary), required, read only, multiselectable, busy, modal, level, "3 of 7"
  (`aria-posinset`/`setsize` or the place among siblings), values (range, number, progress, meter, `aria-value*`),
  text field values (a password is not read), placeholder, link URL, `aria-current`, `aria-invalid`,
  `aria-haspopup`, `aria-orientation`, `aria-controls` / `details` / `flowto` / `owns`, `aria-activedescendant`,
  `aria-errormessage`, `aria-keyshortcuts`, `aria-roledescription`, `lang`; tables: row and column counts, row and
  column indexes, spans.
- **Left out**: `display: none`, `aria-hidden="true"`, `hidden`, `inert`; `visibility: hidden` elements are not nodes
  (their visible children are).
- **Live regions**: `aria-live`, roles `alert` (assertive), `status` and `log` (polite): their text is their name, so
  AccessKit raises a live region event when it changes.
- **Focus**: the page's focused element (the forms' focus) while the page has the keyboard (`ui.a11y_focus_on` the
  page area).
- **Text fields**: their text as a text run (reading by character); no caret position yet.
- **Shadow trees**: the composed tree (a host's shadow root, a slot's assigned nodes).
- **Bounds**: from the layout (`layout.box_of_view`, document coordinates; the document node's transform is the
  page area's place and the scroll: scrolling changes one node).
- **Actions** of screen readers: click (a synthetic click, as `HTMLElement.click()`: `page.click_element`), focus
  (`forms.focus`), set value (`forms.set_value`, as typed: input events), increment / decrement (`forms.step`, as the
  arrow keys), scroll into view, scroll up / down.
- **Updates**: the tree is made again only when what it reads changed (the document's mutation counters, the forms'
  serial, the layout, the focus, the scroll, the page area, the title), and only the nodes that changed go to the
  adapter. A document of more than 50 000 nodes is cut there.

Not done yet (next steps): iframes as subtrees of their own (an `iframe` is a node named by its `title`, without its
document), caret and selection inside text fields and page text (text runs with character positions), static text
bounds (a text node has its element's bounds), a tree updated from the DOM's mutations node by node (it is made
again whole, then diffed), several windows (the page tree follows the main window's current tab).

## Testing

- `src/a11y` unit tests (in `test_all`): the tree of `examples/a11y/page.html` (a form, a list, a table, a dialog,
  live regions, ARIA tabs, hidden parts) against the expected roles, names and states, and the name computation's
  precedence.
- `tools\a11y_e2e.ps1` (in `test_all`): a Wren started by `wren ctl` with no window shown is read through UI Automation
  by the toolkit's `uia_probe` (built into `build\uia_probe.exe` when stale): the chrome's roles, names and states, then
  invoke New tab, set the address bar's value, select a tab, expand and collapse the menu; then
  `examples/a11y/page.html`: its document, controls, states, what is left out, and setting a field, toggling a check
  box, focusing a field and invoking a button act on the page (checked with `wren ctl eval`).
- By hand: `build\uia_probe.exe dump --pid <pid of wren.exe>` prints every element as a screen reader sees it.
- With a person: NVDA and Narrator (what they say, browse and focus modes): see the session note of 2026-10-26.
