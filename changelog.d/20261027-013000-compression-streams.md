type: Added

**CompressionStream and DecompressionStream** (`gzip`, `deflate`, `deflate-raw`): chunks compressed and decompressed as they come, on the toolkit's DEFLATE codec (`flate`: streaming inflate with the gzip / zlib checks, LZ77 with the cheapest of stored, fixed or dynamic Huffman blocks for compression); data that is not of the format, cut before its end or followed by more is a TypeError; one chunk's output is bounded by `page.max_fetch_bytes`.
