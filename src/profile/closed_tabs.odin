package profile

// What was closed, most recent last: a tab, a window, or the session of the run before when this start did not reopen it.
// Every item carries the text of a session file so the browser can reopen it with its full state. The list lives in
// closed.txt in the profile, a line `item <kind> <closed ms> <index> <tabs> <address> <title>` before the session text of each:
//
//     wren-closed 1
//     item	0	1793000000000	2	1	https://example.com/	Example
//     wren-session 2
//     current 0
//     tab https://example.com/
//     e	...

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import config "toolkit:config"
import "wb:base"
import "wb:host"

CLOSED_HEADER :: "wren-closed 1"
CLOSED_FILE :: "closed.txt"
@(private = "file") CLOSED_ITEM_TAG :: "item\t"
@(private = "file") CLOSED_ITEM_FIELDS :: 7

CLOSED_PREFS := [?]config.Def{
	{name = "browser.tabs.closed_sessions_max", kind = .Int, default = {i = 3}, bounded = true, min = 0, max = 100,
		description = "Earlier sessions kept among what Ctrl+Shift+T can reopen (they count in browser.tabs.closed_max)."},
}

register_closed_prefs :: proc(p: ^config.Prefs) { config.register(p, CLOSED_PREFS[:]) }

Closed_Kind :: enum u8 { Tab, Window, Session }

Closed_Item :: struct {
	kind:    Closed_Kind,
	at_ms:   i64,      // when it was closed
	index:   int,      // a tab: its place in the strip
	tabs:    int,      // how many it opens
	address: string,   // owned: of the tab, or of the front one
	title:   string,   // owned: the same
	text:    string,   // owned: a session file
}

Closed_Tabs :: struct {
	items:         [dynamic]Closed_Item,
	loaded:        bool,
	dirty:         bool,   // closed.txt is behind the list
	session_waits: bool,   // this start did not reopen session.txt: it is the session of the run before
	file:          host.Profile_File,   // closed.txt
}

closed_path :: proc(dir: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({dir, "/", CLOSED_FILE}, allocator)
}

closed_item_destroy :: proc(item: Closed_Item) {
	delete(item.address)
	delete(item.title)
	delete(item.text)
}

// (pure: closed_tabs_test.odin)
closed_serialize :: proc(items: []Closed_Item, max_url_bytes: int, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, CLOSED_HEADER)
	strings.write_byte(&sb, '\n')
	for it in items {
		if len(it.address) > max_url_bytes { continue }
		fmt.sbprintf(&sb, "%s%d\t%d\t%d\t%d\t", CLOSED_ITEM_TAG, int(it.kind), it.at_ms, it.index, it.tabs)
		base.field_escape(&sb, it.address)
		strings.write_byte(&sb, '\t')
		base.field_escape(&sb, it.title)
		strings.write_byte(&sb, '\n')
		strings.write_string(&sb, it.text)
		if !strings.has_suffix(it.text, "\n") { strings.write_byte(&sb, '\n') }
	}
	return strings.to_string(sb)
}

// The items of a closed.txt (strings owned, the most recent last); a file that is not one has none, a damaged item is left out.
closed_parse :: proc(text: string) -> [dynamic]Closed_Item {
	items: [dynamic]Closed_Item
	rest := text
	head, ok := strings.split_lines_iterator(&rest)
	if !ok || strings.trim_right(head, "\r") != CLOSED_HEADER { return items }
	for strings.has_prefix(rest, CLOSED_ITEM_TAG) {
		next := strings.index(rest, "\n" + CLOSED_ITEM_TAG)
		chunk := next < 0 ? rest : rest[:next + 1]
		rest = next < 0 ? "" : rest[next + 1:]
		end := strings.index_byte(chunk, '\n')
		if end < 0 { continue }
		f := strings.split(strings.trim_right(chunk[:end], "\r"), "\t", context.temp_allocator)
		if len(f) != CLOSED_ITEM_FIELDS { continue }
		kind, k_ok := strconv.parse_int(f[1])
		at_ms, a_ok := strconv.parse_i64(f[2])
		index, i_ok := strconv.parse_int(f[3])
		tabs, t_ok := strconv.parse_int(f[4])
		if !k_ok || !a_ok || !i_ok || !t_ok || kind < 0 || kind > int(max(Closed_Kind)) { continue }
		append(&items, Closed_Item{kind = Closed_Kind(kind), at_ms = at_ms, index = index, tabs = tabs, address = base.field_unescape(f[5]),
			title = base.field_unescape(f[6]), text = strings.clone(chunk[end + 1:])})
	}
	return items
}

// No more than the most recent `max_items`, of which `max_sessions` sessions.
closed_cap :: proc(items: ^[dynamic]Closed_Item, max_items, max_sessions: int) {
	// the sessions older than the newest `max_sessions` go: counted from the end, the kept ones moved down in one pass
	sessions := 0
	for it in items { if it.kind == .Session { sessions += 1 } }
	drop := max(sessions - max(max_sessions, 0), 0)
	if drop > 0 {
		k := 0
		for it in items {
			if it.kind == .Session && drop > 0 { closed_item_destroy(it); drop -= 1; continue }
			items[k] = it
			k += 1
		}
		resize(items, k)
	}
	if n := len(items) - max(max_items, 0); n > 0 {
		for it in items[:n] { closed_item_destroy(it) }
		remove_range(items, 0, n)
	}
}

closed_append :: proc(c: ^Closed_Tabs, item: Closed_Item, max_items, max_sessions: int) {
	append(&c.items, item)
	closed_cap(&c.items, max_items, max_sessions)
	c.dirty = true
}

// Loads closed.txt at first use. Returns true when `session_waits` was set and the caller should capture session.txt.
closed_load_file :: proc(c: ^Closed_Tabs, h: Store_Host, max_items, max_sessions: int) -> (take_session: bool) {
	if c.loaded { return false }
	c.loaded = true
	if !h.persist || max_items <= 0 { return false }
	if h.dir != "" {
		if data, err := os.read_entire_file(closed_path(h.dir), context.temp_allocator); err == nil {
			c.items = closed_parse(string(data))
			closed_cap(&c.items, max_items, max_sessions)
		}
	}
	take_session = c.session_waits
	c.session_waits = false
	return take_session
}

// Writes closed.txt when it changed, on the blocking pool (through `h.writer`).
closed_save :: proc(c: ^Closed_Tabs, h: Store_Host, max_url_bytes: int) {
	if !c.dirty || h.dir == "" { return }
	host.profile_file_init(&c.file, h.writer, closed_path(h.dir))
	host.profile_file_write(&c.file, closed_serialize(c.items[:], max_url_bytes))
	c.dirty = false
}

// Removes and returns the most recent closed item. Caller owns the returned item (free with closed_item_destroy).
closed_pop :: proc(c: ^Closed_Tabs) -> (item: Closed_Item, ok: bool) {
	if len(c.items) == 0 { return {}, false }
	item = pop(&c.items)
	c.dirty = true
	return item, true
}

// Removes and returns the most recent closed item with `address`. Caller owns the returned item.
closed_take_address :: proc(c: ^Closed_Tabs, address: string) -> (item: Closed_Item, ok: bool) {
	for i := len(c.items) - 1; i >= 0; i -= 1 {
		if c.items[i].address != address { continue }
		item = c.items[i]
		ordered_remove(&c.items, i)
		c.dirty = true
		return item, true
	}
	return {}, false
}

// Removes items closed in [from_ms, to_ms].
closed_forget_range :: proc(c: ^Closed_Tabs, from_ms, to_ms: i64) {
	for i := len(c.items) - 1; i >= 0; i -= 1 {
		if c.items[i].at_ms < from_ms || c.items[i].at_ms > to_ms { continue }
		closed_item_destroy(c.items[i])
		ordered_remove(&c.items, i)
		c.dirty = true
	}
}

// Empties the list and marks closed.txt dirty for the next save.
closed_tabs_clear :: proc(c: ^Closed_Tabs) {
	for item in c.items { closed_item_destroy(item) }
	clear(&c.items)
	c.loaded, c.dirty, c.session_waits = true, true, false
}

closed_tabs_destroy :: proc(c: ^Closed_Tabs) {
	for item in c.items { closed_item_destroy(item) }
	delete(c.items)
	host.profile_file_destroy(&c.file)
	c^ = {}
}
