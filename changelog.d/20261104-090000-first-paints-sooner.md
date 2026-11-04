type: Changed

**First paints sooner**: the image decoder no longer holds the page while its first thread looks for optional codecs (a page's first image cost 12 ms there, and a page with images and an imported stylesheet painted at 73 ms, now 40 ms); the text renderer builds the data of the glyphs a page uses first in half the time (gui_toolkit 0.75.0: the first paint of a page of many scripts 23 -> 18 ms). The numbers, and what was measured and not kept: `docs/performance.md`.
