# The tabs in a sidebar

`browser.tabs.position` puts the tabs in a column at the left or at the right of the page instead of the row along the top.
It is only a layout: the tabs, their order, the current tab, the context menu, the shortcuts and the rules for closing and
reordering are those of the row of tabs (`src/browser/tab_strip.odin`); `src/browser/tab_sidebar.odin` draws them one per row.

| Preference | Default | |
|---|---|---|
| `browser.tabs.position` | `top` | `top`, `left` or `right`. Applies at once. |
| `browser.tabs.sidebar_width` | 240 | 120 to 640 interface pixels (times the display scale), never more than half of the window. Dragging the inner edge changes it; the value is written when the button goes up. |
| `browser.tabs.sidebar_collapsed` | off | Icons only. |
| `browser.tabs.sidebar_collapsed_width` | 48 | 32 to 96 interface pixels. |
| `browser.tabs.sidebar_row_em` | 2.4 | 1.6 to 5 em: the height of a tab. |
| `browser.tabs.sidebar_address_min_em` | 10 | 4 to 40 em: the narrowest address bar in the title bar (below it, parts of the toolbar make room). |

Change them in about:config, with `wren ctl pref set browser.tabs.position left`, from the View menu, from the `Tab bar`
submenu of a tab's context menu or from the command palette (`Tabs: in a sidebar at the left`, `Tabs: at the top`, ...).
`Ctrl+Shift+Comma` (command `view.tabs_sidebar_collapse`) toggles the icons-only mode, as does the button at the top of the sidebar.

## Layout

```
integrated title bar:  [icon][back][forward][reload] [ address ....... ][chips] [shield][menu] ..drag.. [min][max][close]
body:                  [sidebar][ page (and docked developer tools) ]       left
                       [ page (and docked developer tools) ][sidebar]       right

system's title bar:    (Windows draws it)
address row:           [back][forward][reload][ address ......... ][chips][shield][menu]
body:                  as above
```

The sidebar's header holds the icons-only toggle and the new-tab button: the "+" glyph alone, lit under the pointer as the
toolbar's buttons are (both styles, both widths; centred in the narrow column).

### The toolbar in the title bar

With an integrated title bar (`browser.window.integrated_titlebar`, the default) the toolbar *is* the title bar: one row,
as high as the row of tabs would be (never lower than the system's title bar), instead of a title bar holding only the icon
and the window buttons above the toolbar (`sidebar_titlebar` in `tab_sidebar.odin`).

* The row is a caption (`.Window_Caption`) as the row of tabs is. Each part is a box of its own; what is clickable in them
  (the icon, the buttons, the address field, the chips) is a hole, the rest drags the window: the space around the icon,
  the gaps on either side of the address bar and the strip before the window buttons (`browser.window.min_drag_em`).
  Double click maximizes, the window buttons are the system's for its hit tests (Snap Layouts), the top resize band
  works over the whole row.
* `titlebar_layout` (pure) places the parts: they touch, in order, from the left edge to the right one; the address bar takes
  what is left. Under `browser.tabs.sidebar_address_min_em` the drag strip narrows first (to half an em), then the shield
  goes, then forward, then reload (the drag strip gets back what they freed beyond the field's minimum). Back, the
  address bar, the menu and the window buttons always stay; their shortcuts work whatever is hidden.
* The chips after the address bar (page zoom, passkey dialog) are as wide as they are; the layout counts last frame's width
  and the address bar absorbs the difference.
* The classic style draws the toolbar's gradient and its bottom line on the row ([chrome-style.md](chrome-style.md)).
* With the system's title bar there is nothing to merge: the toolbar is its own row under it. With the tabs at the top,
  nothing changes. Full screen: the bars that slide over the page hold the row of tabs and the toolbar, as before.

### Frame

* The window's left, right and bottom resize bands are the system's invisible frame, outside the client area; the top band is
  the title bar's. The sidebar starts below the title bar and cannot cover any of them. Its own width handle is inside it.
* `page_rect` is a result of the layout (the page's box in the column next to the sidebar): nothing that uses it changed.
* In full screen the bars that slide over the page hold the row of tabs, as before: there is no sidebar over a page.
* The classic style (`browser.ui.chrome_style = classic`) has a sidebar of its own: the sidebar is the tab bar, the current
  tab a classic tab with upright sides that flows into the page's side, the others flat and engraved apart, the scroll bar
  on the outer side ([chrome-style.md](chrome-style.md), "Classic, with the tabs in a sidebar").

## The list

A scroll box of the toolkit (`View_Scroll_Y`: the wheel with the page's smooth-scroll curve, a scroll bar, thumb drag) holding an
exact-height spacer (`tabs x row height`, the scroll range) and the rows as floating boxes placed by their slot. Only the rows
within two rows of the view, those the scroll is heading for (at most two views away), the one that has the keyboard and the one
being dragged are built, so 1000 tabs cost as much as 20. `side_visible_rows` is the pure function.

Reordering is the row of tabs' on the Y axis: `drag_slot` gives the slot the dragged row's middle is over, `list_move` moves the
tab (the current tab goes along), each row eases to its slot with `ui.anim` (30 halvings per second), and a row held past an edge
of the list scrolls it. A new current tab is scrolled into view; a drag does not move the scroll.

Nothing animates at rest: the rows slide only while tabs move, the loading indicator turns only while a tab loads, and no frame is
drawn for the sidebar otherwise.

## Tests

`src/browser/tab_sidebar_test.odin`: the position names and preferences (the three values, a refused value, the bounds), the
width of the sidebar, the page and the sidebar sharing the window without overlap for the three positions, the rows built for a
view of 1000 tabs, the geometry of the reorder along Y, the toolbar in the title bar (`titlebar_parts_share_the_window`: the
parts touch and make the window's width, the field's minimum, what hides and in which order; `titlebar_row_regions`: the row
built by `titlebar_row_build` gives the window a caption whose holes are the parts' clickable boxes, the window buttons, and
the hit test of each part, the drag areas and the top resize band).
