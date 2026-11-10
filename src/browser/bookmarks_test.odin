package browser

import "core:strings"
import "core:testing"

// A file as Chrome writes it: <DT> and <p> never closed, a toolbar folder, icons, a nested folder, an entity, a script.
@(private = "file")
CHROME_EXPORT :: `<!DOCTYPE NETSCAPE-Bookmark-file-1>
<!-- This is an automatically generated file.
     It will be read and overwritten.
     DO NOT EDIT! -->
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
    <DT><H3 ADD_DATE="1700000000" LAST_MODIFIED="1700000001" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
    <DL><p>
        <DT><A HREF="https://odin-lang.org/" ADD_DATE="1700000100" ICON="data:image/png;base64,iVBORw0KGgo=">Odin &amp; friends</A>
        <DT><H3 ADD_DATE="1700000200">Docs</H3>
        <DL><p>
            <DT><A HREF="https://developer.mozilla.org/">MDN</A>
            <DT><A HREF="javascript:alert(1)">bookmarklet</A>
        </DL><p>
    </DL><p>
    <DT><A HREF="https://example.com/a?x=1&amp;y=2">Example</A>
</DL><p>
`

@(private = "file")
find_title :: proc(items: []Bookmark, title: string) -> int {
	for b, i in items { if b.title == title { return i } }
	return -1
}

// A messy export reads as its tree: folders, their links in order, dates, entities; scripts are left out.
@(test)
bookmarks_import_reads_a_chrome_export :: proc(t: ^testing.T) {
	items: [dynamic]Bookmark
	defer bookmarks_list_destroy(&items)
	next: u64
	added, ok := bookmarks_import(&items, &next, CHROME_EXPORT, 0, 42)
	testing.expect(t, ok)
	testing.expect_value(t, added, 3)
	testing.expect_value(t, len(items), 5)   // 2 folders, 3 links
	bar, docs, odin, mdn, ex := find_title(items[:], "Bookmarks bar"), find_title(items[:], "Docs"), find_title(items[:], "Odin & friends"), find_title(items[:], "MDN"), find_title(items[:], "Example")
	testing.expect(t, bar >= 0 && docs >= 0 && odin >= 0 && mdn >= 0 && ex >= 0)
	if bar < 0 || docs < 0 || odin < 0 || mdn < 0 || ex < 0 { return }
	testing.expect(t, items[bar].folder && items[docs].folder)
	testing.expect_value(t, items[bar].parent, 0)
	testing.expect_value(t, items[docs].parent, items[bar].id)
	testing.expect_value(t, items[odin].parent, items[bar].id)
	testing.expect_value(t, items[mdn].parent, items[docs].id)
	testing.expect_value(t, items[ex].parent, 0)
	testing.expect_value(t, items[odin].url, "https://odin-lang.org/")
	testing.expect_value(t, items[odin].added_ms, 1700000100 * 1000)
	testing.expect_value(t, items[mdn].added_ms, 42)   // (no date: the import's)
	testing.expect_value(t, items[ex].url, "https://example.com/a?x=1&y=2")
	testing.expect(t, odin < docs, "a folder's children keep their order")
}

// What is written reads back the same; a second import of it adds nothing (same folders, same addresses).
@(test)
bookmarks_round_trip_and_merge :: proc(t: ^testing.T) {
	items: [dynamic]Bookmark
	defer bookmarks_list_destroy(&items)
	next: u64
	_, _ = bookmarks_import(&items, &next, CHROME_EXPORT, 0, 1_700_000_300_000)   // (the file keeps seconds)
	text := bookmarks_serialize(items[:])
	testing.expect(t, strings.has_prefix(text, "<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
	testing.expect(t, strings.contains(text, `HREF="https://example.com/a?x=1&amp;y=2"`))
	back: [dynamic]Bookmark
	defer bookmarks_list_destroy(&back)
	next2: u64
	n, ok := bookmarks_import(&back, &next2, text, 0, 0)
	testing.expect(t, ok)
	testing.expect_value(t, n, 3)
	testing.expect_value(t, len(back), len(items))
	for b, i in items {
		testing.expect_value(t, back[i].title, b.title)
		testing.expect_value(t, back[i].url, b.url)
		testing.expect_value(t, back[i].folder, b.folder)
		testing.expect_value(t, back[i].added_ms, b.added_ms)
	}
	again, _ := bookmarks_import(&back, &next2, CHROME_EXPORT, 0, 0)
	testing.expect_value(t, again, 0)
	testing.expect_value(t, len(back), len(items))
	_, not_bookmarks := bookmarks_import(&back, &next2, "<p>hello</p>", 0, 0)
	testing.expect(t, !not_bookmarks)
}

// A folder goes with what it holds; a folder never moves into itself; moves keep the other folders' order.
@(test)
bookmarks_remove_and_move :: proc(t: ^testing.T) {
	items: [dynamic]Bookmark
	defer bookmarks_list_destroy(&items)
	next: u64
	_, _ = bookmarks_import(&items, &next, CHROME_EXPORT, 0, 42)
	bar := items[find_title(items[:], "Bookmarks bar")].id
	docs := items[find_title(items[:], "Docs")].id
	ex := items[find_title(items[:], "Example")].id
	testing.expect(t, !bookmark_move_into(&items, bar, docs), "into its own folder")
	testing.expect(t, bookmark_move_into(&items, ex, docs))
	testing.expect_value(t, items[bookmark_index(items[:], ex)].parent, docs)
	testing.expect(t, bookmark_shift(&items, ex, -1))   // before MDN in Docs
	mdn := find_title(items[:], "MDN")
	testing.expect(t, bookmark_index(items[:], ex) < mdn)
	testing.expect(t, !bookmark_shift(&items, ex, -1), "the first of its folder")
	testing.expect_value(t, bookmark_remove(&items, bar), 5)
	testing.expect_value(t, len(items), 0)
}

// The bar's folder: the file's PERSONAL_TOOLBAR_FOLDER is the bar, written back so; another file's bar merges into it.
@(test)
bookmarks_bar_folder_is_kept_and_merged :: proc(t: ^testing.T) {
	items: [dynamic]Bookmark
	defer bookmarks_list_destroy(&items)
	next, bar: u64
	_, ok := bookmarks_import(&items, &next, CHROME_EXPORT, 0, 1_700_000_300_000, &bar)
	testing.expect(t, ok)
	testing.expect_value(t, bar, items[find_title(items[:], "Bookmarks bar")].id)
	text := bookmarks_serialize(items[:], bar)
	testing.expect(t, strings.contains(text, `PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>`), text)
	// Firefox's bar, under another name: its bookmarks go into ours
	firefox := `<DL><p><DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Toolbar</H3><DL><p><DT><A HREF="https://kernel.org/">Kernel</A></DL><p></DL><p>`
	n, fok := bookmarks_import(&items, &next, firefox, 0, 0, &bar)
	testing.expect(t, fok)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, find_title(items[:], "Bookmarks Toolbar"), -1)
	testing.expect_value(t, items[find_title(items[:], "Kernel")].parent, bar)
}

// A bookmark moved to a place among its folder's children.
@(test)
bookmarks_move_to_a_place :: proc(t: ^testing.T) {
	items: [dynamic]Bookmark
	defer bookmarks_list_destroy(&items)
	next: u64
	a := bookmark_add(&items, &next, 0, "a", "https://a.example/", false, 0)
	b := bookmark_add(&items, &next, 0, "b", "https://b.example/", false, 0)
	f := bookmark_add(&items, &next, 0, "f", "", true, 0)
	c := bookmark_add(&items, &next, f, "c", "https://c.example/", false, 0)
	order :: proc(items: []Bookmark, parent: u64) -> []u64 {
		out := make([dynamic]u64, context.temp_allocator)
		for x in items { if x.parent == parent { append(&out, x.id) } }
		return out[:]
	}
	testing.expect(t, bookmark_move_to(&items, a, 0, 2))   // after b and f
	o := order(items[:], 0)
	testing.expectf(t, len(o) == 3 && o[0] == b && o[1] == f && o[2] == a, "%v", o)
	testing.expect(t, bookmark_move_to(&items, b, f, 0))   // into f, first
	o = order(items[:], f)
	testing.expectf(t, len(o) == 2 && o[0] == b && o[1] == c, "%v", o)
	testing.expect(t, !bookmark_move_to(&items, f, f, 0), "not into itself")
}
