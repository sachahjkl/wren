type: Changed

**A download on a slow disk slows down instead of freezing the window**: while a piece of the file is being written, the download waits and the network holds back at most 1 MB (`network.queue.high_water_bytes`), so the interface never writes to the disk. `browser.download.max_buffered_bytes` is gone: a download no longer holds up to 64 MB in memory.
