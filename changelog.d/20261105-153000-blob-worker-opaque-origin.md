type: Fixed

**A blob: worker of an opaque origin starts**: a sandboxed frame's `new Worker(URL.createObjectURL(...))` was refused as not same-origin, because a `blob:null/...` URL says nothing of who made it. A blob: URL is now of the origin that made it, its worker of its creator's origin (dedicated, shared and nested), and what such a worker reads of its own blob: URLs is its own.