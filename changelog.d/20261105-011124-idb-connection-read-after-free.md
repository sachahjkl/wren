type: Fixed

**IndexedDB: `close()` read the connection it had just closed and freed** to pump its database's queue: a segmentation fault under a heap that reuses memory (vimeo.com, YouTube, The Verge on Linux with freed memory poisoned).
