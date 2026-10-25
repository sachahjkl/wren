# The look of the browser's own interface

The tab bar, the tabs, the toolbar and the address field are drawn by the toolkit (not by a page). Two styles, chosen by a
preference, and a palette on top of either (`browser.ui.theme`: Graphite, Daylight, Nord, ...).

| Preference | Default | |
|---|---|---|
| `browser.ui.chrome_style` | `modern` | `modern`: flat, tabs are rounded pills. `classic`: Chrome of 2010-2015, see below. Applies at once. |
| `browser.ui.classic_slope_deg` | 22 | Classic: how far the sides of a tab lean from the vertical (8 to 40). The larger, the more angular, the more the tabs overlap. |
| `browser.ui.classic_gloss` | 1 | Classic: strength of the gradients and of the steps between the current tab, the other tabs and the tab bar (0 = flat colors, shapes and lines stay; 2 = more depth). |

Change it in about:config, with `wren ctl pref set browser.ui.chrome_style classic`, from the command palette
(`Appearance: classic tabs`, `Appearance: modern tabs`) or from the menu, View.

## Classic

- **Tabs** are trapezoids: sloped sides, rounded shoulders, and at each foot a *concave* curve that flares out and joins the
  toolbar's line, as a fillet. A thin dark line runs outside the shape and a light one inside, along the top and the sides.
- **The current tab is attached to the toolbar**: its gradient goes on into the toolbar's, and the toolbar's top line is
  interrupted under it (between the two curves of its feet): no line between them. The other tabs are lower in value
  (darker on a light palette, and on a dark one), have their own gradient, sit behind the current one and overlap by a few
  pixels (their feet are covered by the next tab). Under the pointer a tab is lit most of the way to the current one.
- **Gradients** on the tab bar (a little lighter at the top), on every tab, on the toolbar, and in the address field, which
  is a white (dark palettes: darker than the toolbar) hollow with an outline and a light line under it.
- Title cut by a fade, not dots; a close cross on every tab that is wide enough (`browser.tabs.close_button_min_em`), the
  loading indicator, the icon, drag to reorder, scrolling when the tabs are too many, the new-tab button (a faint small
  trapezoid) work as in the modern style.
- A dragged tab is drawn on top, with a shadow.

### How the colors are made

No palette is named: from the palette's window color `base` and `border`, `shade(base, amount)` is a mix toward white or
black in sRGB values (the way the toolkit steps its hover and press states), by amounts that depend on whether the
palette is light or dark (average sRGB value of `base` under one half). `classic_gloss` scales the amounts. See
`classic_colors` in `src/browser/chrome_style.odin`; `chrome_style_test.odin` checks the order tab bar < other tabs <
current tab on every named palette.

### How it is drawn, and clicked

- A tab is three polygons (the region under its outline moved out by a hairline, as is, moved in by a hairline) used as
  the toolkit's polygon clip: a flat dark fill, a flat light fill, then the gradient. Hairlines are whole physical pixels,
  and every length is in `em` or in `dpi` units, so lines stay sharp at 100, 125, 150 and 175 %.
- The shapes are made once per size in the tab's own coordinates (`tab_shape_get`: a small cache) and only moved when
  drawn: a frame that draws the strip again makes no geometry. Nothing draws while nothing changes (the chrome is drawn
  when a frame is asked for, as before).
- The hit shape of a tab is `ui.Box.slant` (gui_toolkit 0.28.0): the toolkit's pointer tests, and the window's hit test over
  an integrated title bar (`platform.Chrome_Regions.slanted`), follow the trapezoid: the corners a tab does not cover still
  drag the window. Tabs are built in the order they are drawn (the others from left to right, the current one, the one
  dragged), the last one under the pointer getting the click, so a click in two overlapping feet goes to the tab on top.
  (Consequence: the Tab key goes through the tabs in that order.)
