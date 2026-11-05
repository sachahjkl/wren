type: Fixed

**A read of freed memory when the browser closed with service workers running**: the page of a worker that closes asks the registry whether it is a host, and the registry was being freed one registration at a time (`sw_registry_shutdown`).
