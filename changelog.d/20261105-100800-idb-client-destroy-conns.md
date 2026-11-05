type: Fixed

**IndexedDB: a read of freed memory when a page closed during a version change**: rolling back the upgrade ended the connection that `client_destroy` went on to close.
