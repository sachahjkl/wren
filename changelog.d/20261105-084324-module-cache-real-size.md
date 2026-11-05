type: Fixed

**Memory**: the compiled modules kept in memory are counted with what they cost beyond their code, up to 64 MB by default (`wasm.cache.memory_bytes`); what is left out comes back from the disk cache.
