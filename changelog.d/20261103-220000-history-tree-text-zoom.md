type: Fixed

**The history tree's text follows its zoom** (about:history#tree): during an animated zoom (+ / -, the zoom buttons, Fit, Current) the nodes' titles grew or shrank in a jump of the 8 % steps text is laid out at, and at rest they stayed up to 8 % smaller than their nodes; the text laid out at a step is now drawn scaled to the zoom's exact size, frame by frame. Page zoom and the interface's zoom were not affected (they do not animate; their text is laid out at its size).
