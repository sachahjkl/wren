type: Added

**Workers from `blob:` URLs**: `new Worker(URL.createObjectURL(blob))` and `new SharedWorker(...)` run the Blob's script (revoking the URL right after the constructor is fine).
