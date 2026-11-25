# Profile stores (`src/profile`)

`src/profile` holds the persistent profile data stores with no dependency on `browser`, `page`, or `toolkit:ui`.

## Purpose

Before `src/profile`, the profile stores (`bookmarks`, `closed_tabs`, `search_engines`, `global_history`) lived inside `src/browser` and took `^App` directly. Any unit test of bookmarks or history had to compile and link the entire browser package, and each store could reach any field of `App`.

## Design decisions

- **Explicit host struct (`profile.Store_Host`) instead of `^App`.** Each store takes a small `Store_Host` value (`dir`, `persist`, `writer`, `loop`, `blocking`, `on_change`, `user`) from its owner (`browser` passes `profile_store_host(app)`; tests pass a zero or minimal host). Refused: keeping a global or passing `^App`, which reintroduces coupling and breaks multi-instance isolation.
- **Value-copied host on stateful stores.** `Bookmarks` and `Global_History` schedule timers and blocking-pool jobs that complete asynchronously after the caller returns. They store `Store_Host` by value inside the store struct so callbacks never dereference a stack-allocated host.
- **Nil-safe host fields for headless tests.** When `loop` is `nil`, delayed saves run immediately through `writer`; when `writer` or `blocking` is `nil`, `host.Profile_File` and `history_save` fall back to synchronous writes on the calling thread. Unit tests in `src/profile` exercise full disk round-trips without starting an event loop or window.
- **Browser glue stays thin in `src/browser`.** `profile_writes.odin` stays in `src/browser` because it owns the toast callback and the cookie/HSTS/prefs bridge on `App`. `src/browser/bookmarks.odin`, `closed_tabs.odin`, `search_engines.odin`, and `global_history.odin` keep only aliases and thin `^App`/`^Tab`/`^Browser_Window` wrappers (such as session snapshot/restore and localized menu labels for closed tabs).
- **Minimal dependency surface.** `src/profile` imports only `wb:base`, `wb:host`, `wb:url`, `wb:dom`, `wb:html` (for Netscape bookmark HTML import), and `toolkit:config` (for `CLOSED_PREFS` and search engine migration). Zero `toolkit:ui`, zero `the_app`, zero cycles.
