type: Changed

**Off-thread download, Cache API, and user stylesheet I/O**: downloads now open, write, close, and remove temporary files off the interface thread; Cache API writes, deletions, and debounced index saves run on a background writer with indexed entry lookups and lock-free disk reads; `style.user_stylesheet` is read once off the interface thread and cached instead of on every new page.
