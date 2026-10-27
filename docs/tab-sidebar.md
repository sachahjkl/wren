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
| `browser.tabs.sidebar_animation_ms` | 180 | 0 to 2000 ms: opening and closing to icons (0: at once). |
| `browser.tabs.sidebar_row_em` | 2.4 | 1.6 to 5 em: the height of a tab. |
| `browser.tabs.sidebar_address_min_em` | 10 | 4 to 40 em: the narrowest address bar in the title bar (below it, parts of the toolbar make room). |

Every `browser.tabs.*` preference (the row of tabs, the sidebar, pinned tabs, groups, sound, favicons, closed tabs) is in
the **Tabs** category of about:config (`register_tab_prefs` registers them with the category `tabs`; their titles drop the
`browser.tabs` the heading says: "Sidebar width"). Change them in about:config, with `wren ctl pref set browser.tabs.position left`, from the View menu, from the `Tab bar`
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

### Opening and closing

Icons only and the titles are the two ends of one layout, not two layouts: `open` (0 closed, 1 open) is eased by the
toolkit's `ui.anim` toward what `browser.tabs.sidebar_collapsed` says, in `browser.tabs.sidebar_animation_ms` (95 % of the
way), and everything is placed from it:

* the width goes from the icons-only width to the open one (`sidebar_open_extent`), so the page widens or narrows a little
  each frame instead of jumping;
* a row's icon slides from the middle of the narrow row to its place (`side_icon_x`), the title and the close button fade
  in behind it (`side_title_alpha`: nothing while the row is too narrow for any of it, the box's `transparency`), clipped by
  the row while it widens;
* the header's two buttons go in a straight line from one above the other to side by side (`side_header_layout`);
* the width handle is there only when the sidebar is open.

The animation asks for its frames while it moves and stops once the width is within half a pixel of its end (none after).
With `browser.ui.animations` off, or `system` and Windows' animation effects off, or a duration of 0, it changes at once.

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

### Many tabs

Neither tab bar builds what does not show: the sidebar builds the rows in view (and those its scroll heads for), the row of
tabs the tabs in view and two on either side (`strip_visible_tabs`), both also the current tab, the one dragged and the one
that has the keyboard. What still runs over every tab each frame is cheap and constant per tab: `tab_refresh` returns at
once for a tab without a page or whose document did not change, the sound state reads a page's media elements only when it
has some, and an icon not drawn is only marked as still used in the cache.

`tools/sidebar_perf.ps1` (a measure, not in the CI; `-Perf` asserts the 180 Hz budget) restores a session of N tabs (in
groups of ten every other ten) and reads the CPU time of a frame from `wren ctl stats`. On the development machine
(2026-10-27, dev build, 240 frames):

| tabs | row of tabs, before | row of tabs | sidebar |
|---|---|---|---|
| 10 | 0.65 ms (p95 0.74) | 0.69 ms (p95 0.75) | 0.81 ms (p95 0.89) |
| 1000 | 10.8 ms (p95 29.8, max 100) | 0.82 ms (p95 0.93) | 0.98 ms (p95 1.12) |

## Pinned tabs and groups

`src/browser/tab_groups.odin` holds the model, `src/browser/tab_sidebar_list.odin` draws it.

* **Pinned tabs** are at the start of the window's tabs and in no group. The sidebar shows them as a grid of icons above
  the list, as many per line as the width holds (one in the narrow column), in a box of their own that scrolls past
  `browser.tabs.sidebar_pins_max` of the window's height (0.4). The row of tabs shows their icon alone. Pin and unpin from a
  tab's menu or `tab.pin`; drag a pinned tab over another to reorder them; drag a tab of the list up to the pinned tabs to
  pin it, a pinned tab down into the list to unpin it.
* **Groups** belong to a window: an id (unique in the window), a name (may be empty: the header then says how many tabs),
  one of nine colours (`grey blue red yellow green pink purple cyan orange`) and whether it is collapsed. Its tabs are next
  to each other. The sidebar shows a header row before them (a disc of its colour, a ring when collapsed; its name) and a
  rail of its colour beside its rows; the row of tabs a line of its colour along the top of each of its tabs.
  * a click on the header collapses or expands it (its tabs leave the list; the current tab is never hidden: collapsing
    the group of the current tab selects the nearest tab outside it, a tab of a collapsed group that becomes current opens
    it); a double click renames it in place (Enter or leaving the field keeps the name, Escape gives up); right click: rename,
    collapse, colour, new tab in the group, ungroup, close the group;
  * a tab's menu: add to a new group, add to one of the window's groups, remove from its group; the commands `tab.group_new`,
    `tab.group_leave`, `tab.group_collapse`, `tab.group_rename`, `tab.group_color.<colour>` act on the current tab;
  * a tab dragged in the list with its middle over a tab of a group joins it, over a tab outside the group or over a
    header leaves it (`side_drop`); moved with the keyboard (`Ctrl+Shift+PageUp/PageDown`), it takes the group of the tab whose
    place it takes;
  * a group without tabs goes; a tab moved to another window leaves its group.
* The order rule (pinned first, a group's tabs together) is restored by `tabs_normalize` after anything that moves tabs or
  changes what they are in (`tabs_fix`).
* **Saved**: with the session and the crash recovery (`session.odin`: `tgroup` lines for a window's groups, `pin` and
  `group <id>` after a tab; an older reader skips them). Without the session, the pinned tabs come back at the next start
  (`browser.tabs.restore_pinned`, on by default: `pinned.txt` in the profile). The "restore the crashed session" command
  opens the tabs into the current window: their pins come back, their groups not.
* `wren ctl tabs --json` gives each tab's `pinned`, `group`, `groupName`, `groupColor`, `groupCollapsed` and the `rect` its
  last frame drew it at in the tab bar (window pixels), and `tabGroups` (each window's groups and their header's `rect`).

| Preference | Default | |
|---|---|---|
| `browser.tabs.sidebar_pins_max` | 0.4 | 0.1 to 0.9: the share of the window's height the pinned tabs take at most. |
| `browser.tabs.restore_pinned` | on | The pinned tabs come back without the session. |
| `browser.tabs.group_name_max` | 64 | 1 to 1024 characters. |

## Sound

`src/browser/tab_sound.odin`. A tab that plays sound (a media element of its page or of one of its frames, playing, with an
audio track, not muted, at a volume above 0) shows a speaker; a muted tab a crossed-out one.

* In the open sidebar and the row of tabs the speaker is a button before the close button: a click mutes or unmutes the tab.
  In the narrow sidebar and on a pinned tab it is a badge over the icon's corner (the tab's menu mutes it). Also the tab's
  menu (`Mute tab` / `Unmute tab`) and the command `tab.mute` (current tab).
* Muting silences the tab's players from the browser's side (`media.player_set_host_muted`): the page's `volume` and
  `muted` are untouched and it is not told. A player that appears later in a muted tab is silenced as it appears.
* The speaker stays `browser.tabs.audio_hold_ms` (2000) after the sound stops, so a pause between two sounds does not make it
  blink; a timer brings the frame that removes it. `browser.tabs.audio_indicator` off: no speaker.
* `wren ctl tabs --json`: `playing` (a media element plays sound now), `audible` (the speaker shows sound), `muted`.

## Tests

`src/browser/tab_sidebar_test.odin`: the position names and preferences (the three values, a refused value, the bounds), the
width of the sidebar, the page and the sidebar sharing the window without overlap for the three positions, the rows built for a
view of 1000 tabs, the geometry of the reorder along Y, the toolbar in the title bar (`titlebar_parts_share_the_window`: the
parts touch and make the window's width, the field's minimum, what hides and in which order; `titlebar_row_regions`: the row
built by `titlebar_row_build` gives the window a caption whose holes are the parts' clickable boxes, the window buttons, and
the hit test of each part, the drag areas and the top resize band), `sidebar_opens_without_a_jump`.

`src/browser/tab_groups_test.odin`: the order rule, groups without tabs going, the rows of the list with groups (headers,
collapsed groups, the binary search, 1000 tabs in 50 groups), where a dragged tab goes and in which group, the pinned tabs'
grid, pins and groups through a session file.

`tools/sidebar_tabs_e2e.ps1` (no window shown, `wren ctl`; in `test_all`): the opening and closing animation seen by the
page's resize events; pinning, reordering pinned tabs, pinning and unpinning by dragging; a group made, joined by dragging,
renamed in its header, coloured, collapsed and expanded by a click, left by dragging, gone with its last tab; the pinned
tabs back after a restart without the session, the group with it. `-ShotDir` writes a picture of each state.
