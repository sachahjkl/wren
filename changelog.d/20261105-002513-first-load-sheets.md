type: Changed

**Pages with large stylesheets load faster**: a sheet takes about a third less time to read and to index and less than half the memory (87 KB of CSS: 6.2 -> 4 ms, 6.7 -> 2.8 MB), a page's first image no longer holds the window thread (20 ms before the first paint of such a page), and the first read of a layout is no longer laid out twice.
