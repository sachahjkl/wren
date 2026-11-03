type: Fixed

**Hovering one link of a nav no longer paints every link of it in its hover style** (the new tab page's links, a site's menu): alike elements share one style record, and the paint-only refresh of the display list re-pointed items by their old record, so every link that shared it took the hovered one's new style. Each display item now takes its own box's or inline item's style.
