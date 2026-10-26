type: Added

**CompressionStream and DecompressionStream** (`gzip`, `deflate`, `deflate-raw`): chunks compressed and decompressed as they come, on a DEFLATE codec of Wren's own (`src/flate`: streaming inflate with the gzip / zlib checks, LZ77 with fixed codes for compression); data that is not of the format, cut before its end or followed by more is a TypeError; one chunk's output is bounded by `page.max_fetch_bytes`.
