type: Fixed

**Thin 3D planes no longer make their whole context split.** The order and the crossing of the planes of a `preserve-3d` context were worked out on each layer with the margin it is rasterized with (one device pixel on each side, and the rounding to texels): a plane seen almost edge-on, such as the rim of a coin or of a card, seemed to reach into every plane it touches, so all of them were taken to cut through each other and were split into hundreds of pieces (the licence seal disappeared). The geometry is now that of the layer without its margin.
