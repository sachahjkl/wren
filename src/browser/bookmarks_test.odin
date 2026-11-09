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
