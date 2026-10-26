type: Added

**`StorageBucket.getDirectory()`**: each storage bucket has its own origin private file system. Its `estimate()` counts it, it goes when the bucket is deleted, and its handles survive `structuredClone`.
