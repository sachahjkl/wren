type: Fixed

**Filters and nested viewports around SVG `<foreignObject>`**: the HTML inside is clipped to the nested `<svg>` it is in (unless its overflow is visible) and takes the filter functions of its ancestors and the `<filter>`s made of blurs, saturation, hue rotation and linear transfers.
