type: Fixed

**A crash when a page with an IndexedDB database closes** (Linux: github.com, npr.org; a read of freed memory on Windows too): the deferred unlock of `client_destroy` read the manager from the client it had just freed.
