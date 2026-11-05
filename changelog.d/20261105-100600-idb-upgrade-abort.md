type: Fixed

**IndexedDB: a read of freed memory when a version change was aborted**: the transaction went on using its connection, which the failed upgrade had just let go.
