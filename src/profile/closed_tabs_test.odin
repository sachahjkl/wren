package profile

import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"

@(private = "file")
make_closed_item :: proc(kind: Closed_Kind, address: string, at_ms: i64 = 1000, text := "wren-session 2\ncurrent 0\ntab https://a/\n") -> Closed_Item {
	return {kind = kind, at_ms = at_ms, index = 3, tabs = 1, address = strings.clone(address), title = strings.clone("A\ttitle"), text = strings.clone(text)}
}

@(private = "file")
closed_items_destroy :: proc(items: ^[dynamic]Closed_Item) {
	for it in items { closed_item_destroy(it) }
	delete(items^)
}

@(test)
closed_round_trip :: proc(t: ^testing.T) {
	list: [dynamic]Closed_Item
	defer closed_items_destroy(&list)
	append(&list, make_closed_item(.Tab, "https://a/"), make_closed_item(.Window, "https://b/"), make_closed_item(.Session, "https://c/", 1000, "wren-session 2\ncurrent 0"))
	append(&list, make_closed_item(.Tab, strings.repeat("x", 50, context.temp_allocator)))   // (an address too long is not written)
	back := closed_parse(closed_serialize(list[:], 40))
	defer closed_items_destroy(&back)
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
		defer closed_items_destroy(&got)
		testing.expect_value(t, len(got), 0)
	}
	got := closed_parse(CLOSED_HEADER + "\nitem\tx\t1\t2\t3\tu\tt\nitem\t9\t1\t2\t3\tu\tt\nitem\t0\t1\nitem\t0\t1\t2\t1\thttps://kept/\tKept\ntab https://kept/\n")
	defer closed_items_destroy(&got)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 { testing.expect_value(t, got[0].address, "https://kept/") }
}

@(test)
closed_cap_keeps_the_most_recent :: proc(t: ^testing.T) {
	list: [dynamic]Closed_Item
	defer closed_items_destroy(&list)
	append(&list, make_closed_item(.Session, "s1"), make_closed_item(.Tab, "t1"), make_closed_item(.Session, "s2"), make_closed_item(.Tab, "t2"), make_closed_item(.Session, "s3"), make_closed_item(.Tab, "t3"))
	closed_cap(&list, 4, 2)   // (s1 goes as the session too many, t1 as the oldest)
	testing.expect_value(t, len(list), 4)
	if len(list) == 4 {
		testing.expect_value(t, list[0].address, "s2")
		testing.expect_value(t, list[3].address, "t3")
	}
}

// Store operations without browser.App: save, reload, pop, take by address, forget range, clear.
@(test)
closed_store_lifecycle :: proc(t: ^testing.T) {
	dir := strings.concatenate({"build/tmp/profile_closed_", base.unique_name(context.temp_allocator)}, context.temp_allocator)
	_ = os.make_directory_all(dir)
	defer base.remove_tree(dir)
	h := Store_Host{dir = dir, persist = true}

	c: Closed_Tabs
	defer closed_tabs_destroy(&c)
	c.loaded = true
	closed_append(&c, make_closed_item(.Tab, "https://one/", 100), 10, 3)
	closed_append(&c, make_closed_item(.Tab, "https://two/", 200), 10, 3)
	closed_append(&c, make_closed_item(.Tab, "https://three/", 300), 10, 3)
	closed_save(&c, h, 1024)

	reloaded: Closed_Tabs
	defer closed_tabs_destroy(&reloaded)
	reloaded.session_waits = true
	testing.expect(t, closed_load_file(&reloaded, h, 10, 3))
	testing.expect_value(t, len(reloaded.items), 3)

	took, ok := closed_take_address(&reloaded, "https://two/")
	testing.expect(t, ok && took.address == "https://two/")
	closed_item_destroy(took)

	closed_forget_range(&reloaded, 50, 150)
	testing.expect_value(t, len(reloaded.items), 1)

	popped, pok := closed_pop(&reloaded)
	testing.expect(t, pok && popped.address == "https://three/")
	closed_item_destroy(popped)

	closed_tabs_clear(&reloaded)
	testing.expect_value(t, len(reloaded.items), 0)
}
