package browser

import "core:strings"
import "core:testing"

@(private = "file")
item :: proc(kind: Closed_Kind, address: string, text := "wren-session 2\ncurrent 0\ntab https://a/\n") -> Closed_Item {
	return {kind = kind, at_ms = 1000, index = 3, tabs = 1, address = strings.clone(address), title = strings.clone("A\ttitle"), text = strings.clone(text)}
}

@(private = "file")
items_destroy :: proc(items: ^[dynamic]Closed_Item) {
	for it in items { delete(it.address); delete(it.title); delete(it.text) }
	delete(items^)
}

@(test)
closed_round_trip :: proc(t: ^testing.T) {
	list: [dynamic]Closed_Item
	defer items_destroy(&list)
	append(&list, item(.Tab, "https://a/"), item(.Window, "https://b/"), item(.Session, "https://c/", "wren-session 2\ncurrent 0"))
	append(&list, item(.Tab, strings.repeat("x", 50, context.temp_allocator)))   // (an address too long is not written)
	back := closed_parse(closed_serialize(list[:], 40))
	defer items_destroy(&back)
	testing.expect_value(t, len(back), 3)
	if len(back) == 3 {
		testing.expect_value(t, back[0].kind, Closed_Kind.Tab)
		testing.expect_value(t, back[0].index, 3)
		testing.expect_value(t, back[0].at_ms, 1000)
		testing.expect_value(t, back[0].title, "A\ttitle")
		testing.expect_value(t, back[0].text, list[0].text)
		testing.expect_value(t, back[1].kind, Closed_Kind.Window)
		testing.expect_value(t, back[2].address, "https://c/")
		testing.expect_value(t, back[2].text, "wren-session 2\ncurrent 0\n")
	}
}

// Whatever is in the file, the browser goes on: what can be read of it is kept.
@(test)
closed_damaged_files :: proc(t: ^testing.T) {
	for text in ([]string{"", "not a list", "wren-closed 9\nitem\t0\t1\t2\t3\tu\tt\n"}) {
		got := closed_parse(text)
		defer items_destroy(&got)
		testing.expect_value(t, len(got), 0)
	}
	got := closed_parse(CLOSED_HEADER + "\nitem\tx\t1\t2\t3\tu\tt\nitem\t9\t1\t2\t3\tu\tt\nitem\t0\t1\nitem\t0\t1\t2\t1\thttps://kept/\tKept\ntab https://kept/\n")
	defer items_destroy(&got)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 { testing.expect_value(t, got[0].address, "https://kept/") }
}

@(test)
closed_cap_keeps_the_most_recent :: proc(t: ^testing.T) {
	list: [dynamic]Closed_Item
	defer items_destroy(&list)
	append(&list, item(.Session, "s1"), item(.Tab, "t1"), item(.Session, "s2"), item(.Tab, "t2"), item(.Session, "s3"), item(.Tab, "t3"))
	closed_cap(&list, 4, 2)   // (s1 goes as the session too many, t1 as the oldest)
	testing.expect_value(t, len(list), 4)
	if len(list) == 4 {
		testing.expect_value(t, list[0].address, "s2")
		testing.expect_value(t, list[3].address, "t3")
	}
}

@(test)
session_kept_drops_what_comes_back_by_itself :: proc(t: ^testing.T) {
	windows := []Session_Window{
		{tabs = {{url = "pinned", pinned = true}, {url = "a"}, {url = "b"}}, current = 2},
		{tabs = {{url = "only pinned", pinned = true}}},
		{},
	}
	kept := session_kept(windows, drop_pinned = true)
	testing.expect_value(t, len(kept), 1)
	if len(kept) == 1 {
		testing.expect_value(t, len(kept[0].tabs), 2)
		testing.expect_value(t, kept[0].tabs[kept[0].current].url, "b")
	}
	testing.expect_value(t, len(session_kept(windows)), 2)
}

@(test)
session_tab_blank_is_a_tab_with_nothing_to_show :: proc(t: ^testing.T) {
	testing.expect(t, session_tab_blank({url = HOME_URL}))
	testing.expect(t, session_tab_blank({url = "about:blank"}))
	testing.expect(t, !session_tab_blank({url = "https://a/"}))
}
