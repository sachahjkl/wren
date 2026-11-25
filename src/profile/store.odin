package profile

// Pure profile stores: bookmarks, closed tabs, search engines, and global browsing history.
// Each store receives a Store_Host from its embedder instead of touching browser.App or toolkit:ui.

import "core:time"
import "wb:host"

// Host environment supplied by the embedder (browser.App, tests, tools) to profile stores.
Store_Host :: struct {
	dir:       string,               // profile directory ("" = memory only)
	persist:   bool,                 // whether the store reads and writes files in `dir`
	writer:    ^host.File_Writer,    // shared background writer (nil = synchronous writes)
	loop:      ^host.Loop,           // event loop for delayed writes and retries (nil = immediate)
	blocking:  ^host.Blocking_Pool,  // worker pool for custom write jobs (nil = calling thread)
	on_change: proc(user: rawptr),   // optional: notifies owner when store data changes
	user:      rawptr,               // passed to `on_change`
}

now_ms :: proc() -> i64 { return time.time_to_unix_nano(time.now()) / 1e6 }

@(private = "package")
store_notify :: proc(h: Store_Host) {
	if h.on_change != nil { h.on_change(h.user) }
}
