type: Changed

**Memory**: smaller caches by default: decoded images 128 MB (`images.cache.max_bytes`), bytecode 32 MB (`javascript.bytecode_cache.memory_bytes`), HTTP bodies 32 MB (`network.cache.memory.max_bytes`); the two last are on disk as well.
