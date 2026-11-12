type: Changed

**Faster strings**: long substrings share their text instead of copying it, built strings keep their buffer, and string comparison and conversion read 16 bytes at a step (WebAssembly SIMD).
