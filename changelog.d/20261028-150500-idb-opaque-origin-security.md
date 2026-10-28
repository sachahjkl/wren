type: Fixed

**IndexedDB on an opaque origin** (`indexedDB.open`, `indexedDB.deleteDatabase`, `indexedDB.databases`) : a sandboxed iframe, a `data:` worker, or disabled storage now rejects with a `SecurityError`, as the spec requires, instead of a misleading `TypeError`. The host already raised the error; the factory methods used to clobber it while reading the (absent) reply.
