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

Change them in about:config, with `wren ctl pref set browser.tabs.position left`, from the View menu, from the `Tab bar`
submenu of a tab's context menu or from the command palette (`Tabs: in a sidebar at the left`, `Tabs: at the top`, ...).
`Ctrl+Shift+Comma` (command `view.tabs_sidebar_collapse`) toggles the icons-only mode, as does the button at the top of the sidebar.

## Layout

```
integrated title bar:  [icon] ......drag area...... [min][max][close]      (the system's one when it is not integrated)
address row:           [back][forward][reload][ address ......... ][menu]
body:                  [sidebar][ page (and docked developer tools) ]       left
                       [ page (and docked developer tools) ][sidebar]       right
```

* The title bar's row is a caption (`.Window_Caption`) as the row of tabs is: empty parts drag the window, double click
  maximizes, Snap Layouts work on the maximize button.
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
view of 1000 tabs, the geometry of the reorder along Y.
