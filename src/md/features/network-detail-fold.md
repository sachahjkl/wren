# The Network detail folds to a rail

The developer tools' Network tab shows the selected request's detail beside the requests table when the panel is wide
(640 px or more) and under it otherwise. Beside the table, the detail is the toolkit's foldable side panel
(`ui.Side_Panel`, `ext/gui_toolkit/src/md/features/side-panels.md`): Wren keeps no fold rule of its own.

- **The rule is the toolkit's.** The detail folds to its rail when its width leaves the table less than the table's
  least, and opens again 1 em past that. A fold or an opening by hand (the fold button, a pull of the rail's edge, a
  click on the rail's mark) holds until the panel's width next crosses that threshold.
- **The table's least is the Name column's width plus the scroll bar.** `net_layout` drops the other columns from the
  right when they do not fit and never drops Name: under that width the table cuts the names, which are what a person
  reads to pick a request. So a person who widens the Name column also moves the threshold. Refused: a fixed width,
  which folds the detail while the table still shows every column, or leaves the names cut.
- **The share stays the unit.** The detail's open width is a share of the split (`unit = room`), kept as before in
  `browser.devtools.network.split` (the table's share: the detail's is `1 - split`). A wider panel gives both sides
  more room, as before. The fold is the hidden preference `browser.devtools.network.detail_fold`
  (`ui.side_fold_format`: both bits), so a restart at the same width keeps a choice by hand, and a restart on the
  other side of the threshold is a crossing.
- **The preferences are the state.** Each frame reads the fold and the share from the preferences and writes them back
  only on a change: there is no second copy that a reset of the layout or an import of the settings leaves stale.
- **The rail shows the selected request's mark**: its type's icon (red when it failed) over its status's dot, in the
  colours of the table's row, with the method, the status and the name as the tooltip. The rail is about 2 em wide: a
  word does not fit, and the mark says which request opening the detail shows and whether it failed. A click on the
  mark opens the detail. Refused: an empty rail, which hides that a request is still selected.
- **The fold button is at the end of the detail's first bar**, at the same pixel open and folded: the detail is at the
  right, so its right edge is the one that does not move. The rail's width is the button and the same gap on each
  side. In the open bar, the close button and the view tabs are clipped before the fold button is.
- **Under the table, nothing folds.** The stacked split stays the toolkit's plain splitter: `ui.side_handle` is
  horizontal only, and a detail under the table is not narrowed by the room's width.
