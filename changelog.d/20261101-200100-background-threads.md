type: Fixed

Workers, image decoding, the disk cache and script compilation no longer stall while other programs keep every core busy (a worker took 5 s to start, an image 14 s to decode): on Windows they run level with other programs, and the interface thread is raised above them, so the window stays responsive.
