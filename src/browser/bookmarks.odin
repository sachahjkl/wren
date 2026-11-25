package browser

// Browser bridge for the bookmarks store (src/profile/bookmarks.odin).

import "wb:profile"

BOOKMARKS_FILE :: profile.BOOKMARKS_FILE
BOOKMARKS_SAVE_DELAY_MS :: profile.BOOKMARKS_SAVE_DELAY_MS

Bookmark :: profile.Bookmark
Bookmarks :: profile.Bookmarks

bookmark_free :: profile.bookmark_free
bookmarks_list_destroy :: profile.bookmarks_list_destroy
bookmark_index :: profile.bookmark_index
bookmark_of_url :: profile.bookmark_of_url
bookmark_within :: profile.bookmark_within
bookmark_add :: profile.bookmark_add
bookmark_remove :: profile.bookmark_remove
bookmark_move_into :: profile.bookmark_move_into
bookmark_move_to :: profile.bookmark_move_to
bookmark_shift :: profile.bookmark_shift
bookmarks_serialize :: profile.bookmarks_serialize
bookmarks_import :: profile.bookmarks_import
bookmark_address_ok :: profile.bookmark_address_ok

@(private = "file")
bookmarks_ensure_host :: proc(app: ^App) {
	if app.bms.host.writer == nil { app.bms.host = profile_store_host(app) }
}

bookmarks_init :: proc(app: ^App) {
	profile.bookmarks_init(&app.bms, profile_store_host(app))
}

bookmarks_changed :: proc(app: ^App) {
	bookmarks_ensure_host(app)
	profile.bookmarks_changed(&app.bms)
}

bookmarks_shutdown :: proc(app: ^App) {
	profile.bookmarks_shutdown(&app.bms)
}

// The bookmark of the page `t` shows, added at the bookmarks bar, or the one it has (its id).
bookmark_page :: proc(app: ^App, t: ^Tab) -> (id: u64, added: bool) {
	if t == nil { return 0, false }
	bookmarks_ensure_host(app)
	return profile.bookmarks_add_page(&app.bms, t.url, t.title)
}

// The bookmarks bar's folder, made at the top of the top level when there is none.
bookmarks_toolbar :: proc(app: ^App) -> u64 {
	bookmarks_ensure_host(app)
	return profile.bookmarks_toolbar(&app.bms)
}
