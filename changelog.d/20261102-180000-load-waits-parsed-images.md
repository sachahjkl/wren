Type: Fixed

**The load event waits for the images of the parsed document**: the `<img>` elements start their requests at the next image pass, and a load that came before it (right after the end of parsing) did not count them, so `onload` could run with images still on their way.
