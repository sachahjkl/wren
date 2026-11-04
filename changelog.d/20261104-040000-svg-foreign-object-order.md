type: Fixed

**HTML inside inline SVG** (`<foreignObject>`) keeps the SVG's drawing order: shapes drawn after it cover it (Google's "G" had its gradient over the blue bar). It is clipped to the `<svg>`'s viewport and by every `<clipPath>` around it (bounding box units too), and placed through nested `<svg>` viewports.
