package browser

import "core:testing"

// A folder that holds something is asked about (nothing removed yet); an empty one, or a bookmark, goes at once.
@(test)
a_full_folder_is_asked_about_first :: proc(t: ^testing.T) {
	app := test_app(t)
	defer { confirm_destroy(app); bookmarks_list_destroy(&app.bms.items) }
	f := bookmark_add(&app.bms.items, &app.bms.next_id, 0, "Docs", "", true, 0)
	_ = bookmark_add(&app.bms.items, &app.bms.next_id, f, "MDN", "https://developer.mozilla.org/", false, 0)
	empty := bookmark_add(&app.bms.items, &app.bms.next_id, 0, "Empty", "", true, 0)
	bookmark_remove_asked(app, f)
	testing.expect(t, app.confirm.open && app.confirm.kind == .Bookmark_Folder && app.confirm.id == f)
	testing.expect_value(t, len(app.bms.items), 3)   // nothing removed before the answer
	testing.expect_value(t, len(app.confirm.lines), 1)
	confirm_destroy(app)
	bookmark_remove_asked(app, empty)
	testing.expect(t, !app.confirm.open)
	testing.expect_value(t, len(app.bms.items), 2)
}
