package page

// A tab's session history, kept as a tree. Going back then somewhere else does not drop the entries that were ahead:
// they stay, as another branch of the entry the new one grew from. Each entry remembers when it was last visited; the
// "active branch" of an entry is its child visited last. The web sees only the active path (HTML's joint session
// history stays linear): from the oldest ancestor of the current entry down through it, then on through the active
// child of each entry. history.length, back / forward / go(n), popstate and the shell's back and forward buttons all
// walk that path; the other branches are reached from the browser's interface (the tab's history tree), which makes
// the path to the chosen entry the active one.
//
// The shell keeps one per tab and hands it to each page of the tab (Embedder.session); a page without an embedder keeps
// a private one. Entries remember which document created them (`doc`, a page id): traversing to an entry of the current
// document is a same-document traversal (popstate), anything else is a navigation by the shell.
//
// Sizes: the path the web sees holds at most `window` entries (history.max_entries: the oldest ancestors are hidden past
// it, the forward ones next), and the whole tree at most `max_nodes` (history.tree.max_nodes): past it the entries
// visited least recently go first, entries off the active path before those on it.

import "core:slice"
import "core:strings"
import "core:time"

History_Entry :: struct {
	id:        u64,      // unique in its tree, stable (serialized)
	url:       string,   // owned
	state:     string,   // owned; history.state when has_state
	has_state: bool,
	doc:       u64,      // id of the page that owns the entry (0 = none yet)
	title:     string,   // owned: the document's title when it was last shown (the interface's)
	created_ms: i64,     // Unix time the entry was made
	visited_ms: i64,     // ... last made current
	seq:       u64,      // order of the last visits within the tree: the child with the highest is the active branch
	scroll_manual: bool, // history.scrollRestoration = "manual" for this entry
	persisted: Persisted_State,   // what the document showed when it was left (history_state.odin)
	parent:    ^History_Entry,    // nil for the tree's root (no URL: the top of the tab)
	children:  [dynamic]^History_Entry,   // in the order they were made
}

Session_History :: struct {
	root:      ^History_Entry,           // made on first use
	entries:   [dynamic]^History_Entry,  // the active path as the web sees it (views of tree nodes)
	index:     int,                      // current entry in `entries`, -1 when empty
	current:   ^History_Entry,
	count:     int,                      // nodes, the root aside
	next_id:   u64,
	seq:       u64,
	window:    int,                      // most entries in `entries` (0: 50)
	max_nodes: int,                      // most nodes (0: 1000)
	serial:    u64,                      // bumped at every change (the interface redraws its tree)
}

@(private = "file")
entry_free :: proc(e: ^History_Entry) {
	for c in e.children { entry_free(c) }
	delete(e.children)
	delete(e.url); delete(e.state); delete(e.title)
	persisted_destroy(&e.persisted)
	free(e)
}

session_destroy :: proc(sh: ^Session_History) {
	if sh.root != nil { entry_free(sh.root) }
	delete(sh.entries)
	sh^ = {}
}

@(private = "file")
now_unix_ms :: proc() -> i64 { return time.time_to_unix_nano(time.now()) / 1e6 }

session_root :: proc(sh: ^Session_History) -> ^History_Entry {
	if sh.root == nil {
		sh.root = new(History_Entry)
		sh.index = -1
	}
	return sh.root
}

session_current :: proc(sh: ^Session_History) -> ^History_Entry {
	if sh == nil { return nil }
	return sh.current
}

session_length :: proc(sh: ^Session_History) -> int { return len(sh.entries) if sh != nil else 0 }

// The child of `e` visited last (its active branch), nil for a leaf.
session_active_child :: proc(e: ^History_Entry) -> ^History_Entry {
	best: ^History_Entry
	for c in e.children { if best == nil || c.seq > best.seq { best = c } }
	return best
}

// The entry with this id, nil when there is none.
session_find :: proc(sh: ^Session_History, id: u64) -> ^History_Entry {
	if sh == nil || sh.root == nil { return nil }
	stack := make([dynamic]^History_Entry, 0, 64, context.temp_allocator)
	append(&stack, sh.root)
	for len(stack) > 0 {
		e := pop(&stack)
		if e.id == id && e != sh.root { return e }
		append(&stack, ..e.children[:])
	}
	return nil
}

// Whether `e` is the current entry or one of its ancestors / active descendants (the path the web sees, before the
// window cuts it).
session_on_active_path :: proc(sh: ^Session_History, e: ^History_Entry) -> bool {
	if sh.current == nil { return false }
	for a := sh.current; a != nil; a = a.parent { if a == e { return true } }
	for d := session_active_child(sh.current); d != nil; d = session_active_child(d) { if d == e { return true } }
	return false
}

// Marks `e` and its ancestors as just visited: the path from the root to `e` becomes the active one.
@(private = "file")
visit :: proc(sh: ^Session_History, e: ^History_Entry) {
	for a := e; a != nil && a != sh.root; a = a.parent {
		sh.seq += 1
		a.seq = sh.seq
	}
	e.visited_ms = now_unix_ms()
	sh.current = e
}

// Recomputes the web's view: the current entry's ancestors, it, then its active descendants, at most `window` of them.
@(private = "file")
rebuild :: proc(sh: ^Session_History) {
	clear(&sh.entries)
	sh.serial += 1
	if sh.current == nil { sh.index = -1; return }
	chain := make([dynamic]^History_Entry, 0, 64, context.temp_allocator)
	for a := sh.current; a != nil && a != sh.root; a = a.parent { append(&chain, a) }
	slice.reverse(chain[:])
	ci := len(chain) - 1
	for d := session_active_child(sh.current); d != nil; d = session_active_child(d) { append(&chain, d) }
	window := sh.window > 0 ? sh.window : 50
	start := 0
	if len(chain) > window { start = min(len(chain) - window, ci) }
	end := min(len(chain), start + window)
	append(&sh.entries, ..chain[start:end])
	sh.index = ci - start
}

// A new entry after the current one, as its child: entries that were ahead stay as another branch. With `dedupe`,
// visiting the URL of the current entry again (a reload typed in the address bar) does not add one. `max_entries` is
// the length of the path the web sees.
session_push :: proc(sh: ^Session_History, url: string, doc: u64, state := "", has_state := false, dedupe := true, max_entries := 50) -> ^History_Entry {
	root := session_root(sh)
	sh.window = max(max_entries, 1)
	if dedupe {
		if cur := sh.current; cur != nil && cur.url == url { return cur }
	}
	parent := sh.current != nil ? sh.current : root
	sh.next_id += 1
	e := new(History_Entry)
	e^ = History_Entry{id = sh.next_id, url = strings.clone(url), state = strings.clone(state), has_state = has_state, doc = doc, parent = parent, created_ms = now_unix_ms()}
	if sh.current != nil { e.scroll_manual = sh.current.scroll_manual && doc != 0 && doc == sh.current.doc }   // (same document: the mode carries over, as in HTML)
	append(&parent.children, e)
	sh.count += 1
	visit(sh, e)
	prune(sh)
	rebuild(sh)
	return e
}

// Replaces the URL (and the state, when `set_state`) of the current entry.
session_replace :: proc(sh: ^Session_History, url: string, state := "", has_state := false, set_state := true) {
	cur := session_current(sh)
	if cur == nil { session_push(sh, url, 0, state, has_state, dedupe = false); return }
	if cur.url != url { delete(cur.url); cur.url = strings.clone(url) }
	if set_state {
		delete(cur.state)
		cur.state, cur.has_state = strings.clone(state), has_state
	}
	sh.serial += 1
}

// The entry `delta` steps away on the path the web sees, or nil when there is none.
session_peek :: proc(sh: ^Session_History, delta: int) -> ^History_Entry {
	if sh == nil { return nil }
	i := sh.index + delta
	if i < 0 || i >= len(sh.entries) { return nil }
	return sh.entries[i]
}

// Moves the current entry `delta` steps along the active path. False (and no change) when there is no such entry.
session_go :: proc(sh: ^Session_History, delta: int) -> (^History_Entry, bool) {
	e := session_peek(sh, delta)
	if e == nil { return nil, false }
	session_goto(sh, e)
	return e, true
}

// Makes `e` (any entry of the tree) the current one: the path to it becomes the active one.
session_goto :: proc(sh: ^Session_History, e: ^History_Entry) {
	if e == nil || e == sh.root { return }
	visit(sh, e)
	rebuild(sh)
}

// How many steps along the active path `e` is from the current entry (0, false when it is not on it).
session_delta_of :: proc(sh: ^Session_History, e: ^History_Entry) -> (int, bool) {
	for x, i in sh.entries { if x == e { return i - sh.index, true } }
	return 0, false
}

// Removes the current entry, which must be a leaf made by the last push (a navigation that became a download): its
// parent is current again, with the branch it had before.
session_drop_current :: proc(sh: ^Session_History) {
	e := sh.current
	if e == nil || len(e.children) > 0 { return }
	parent := e.parent
	detach(sh, e)
	sh.current = parent != sh.root ? parent : session_active_child(sh.root)
	rebuild(sh)
}

// Unlinks `e` from the tree and frees it; its children go up to its parent, in its place.
@(private = "file")
detach :: proc(sh: ^Session_History, e: ^History_Entry) {
	parent := e.parent
	at := -1
	for c, i in parent.children { if c == e { at = i; break } }
	if at < 0 { return }
	ordered_remove(&parent.children, at)
	for c, k in e.children {
		c.parent = parent
		inject_at(&parent.children, at + k, c)
	}
	clear(&e.children)
	entry_free(e)
	sh.count -= 1
}

// Keeps the tree within max_nodes: leaves off the active path, visited least recently first; then the oldest
// ancestors of the active path. The current entry always stays.
@(private = "file")
prune :: proc(sh: ^Session_History) {
	limit := sh.max_nodes > 0 ? sh.max_nodes : 1000
	for sh.count > limit {
		victim: ^History_Entry
		stack := make([dynamic]^History_Entry, 0, 64, context.temp_allocator)
		append(&stack, sh.root)
		for len(stack) > 0 {
			e := pop(&stack)
			append(&stack, ..e.children[:])
			if e == sh.root || len(e.children) > 0 || e == sh.current || session_on_active_path(sh, e) { continue }
			if victim == nil || e.seq < victim.seq { victim = e }
		}
		if victim == nil {
			// a single chain: its oldest entry goes (never the current one)
			oldest := sh.root.children[0] if len(sh.root.children) > 0 else nil
			if oldest == nil || oldest == sh.current { return }
			victim = oldest
		}
		detach(sh, victim)
	}
}

// Sets the tree's size limits (preferences) and applies them.
session_set_limits :: proc(sh: ^Session_History, window, max_nodes: int) {
	sh.window = max(window, 1)
	sh.max_nodes = max(max_nodes, 1)
	if sh.root == nil { return }
	prune(sh)
	rebuild(sh)
}

// Sets the title the interface shows for the current entry.
session_set_title :: proc(sh: ^Session_History, title: string) {
	cur := session_current(sh)
	if cur == nil || cur.title == title { return }
	delete(cur.title)
	cur.title = strings.clone(title)
	sh.serial += 1
}

////////////////////////////////
// Building a tree from saved entries (session restore)

Saved_Entry :: struct {
	id, parent: u64,      // parent 0: a top-level entry
	url, title, state: string,
	has_state: bool,
	created_ms, visited_ms: i64,
	seq:       u64,
	scroll_manual: bool,
	scroll:    [2]f32,
	zoom:      f32,
}

// Rebuilds `sh` from entries listed parents first (unknown parents make top-level entries; repeated ids are skipped).
// `current` is the id of the entry to make current (else the last one).
session_load :: proc(sh: ^Session_History, saved: []Saved_Entry, current: u64, window, max_nodes: int) {
	session_destroy(sh)
	root := session_root(sh)
	sh.window, sh.max_nodes = max(window, 1), max(max_nodes, 1)
	by_id := make(map[u64]^History_Entry, len(saved), context.temp_allocator)
	last: ^History_Entry
	for s in saved {
		if s.id == 0 || s.id in by_id { continue }
		parent := root
		if p, ok := by_id[s.parent]; ok { parent = p }
		e := new(History_Entry)
		e^ = History_Entry{id = s.id, url = strings.clone(s.url), title = strings.clone(s.title), state = strings.clone(s.state), has_state = s.has_state,
			created_ms = s.created_ms, visited_ms = s.visited_ms, seq = s.seq, scroll_manual = s.scroll_manual, parent = parent}
		e.persisted.saved = s.scroll != {} || s.zoom != 0
		e.persisted.scroll = s.scroll
		e.persisted.zoom = s.zoom
		append(&parent.children, e)
		by_id[s.id] = e
		sh.count += 1
		sh.next_id = max(sh.next_id, s.id)
		sh.seq = max(sh.seq, s.seq)
		last = e
	}
	cur := by_id[current] if current in by_id else last
	if cur == nil { return }
	// the current entry's path is the active one, whatever the saved orders said (its visit time stays the saved one)
	visited := cur.visited_ms
	visit(sh, cur)
	if visited != 0 { cur.visited_ms = visited }
	prune(sh)
	rebuild(sh)
}

// The tree in an order that lists parents first (depth first, children in their order).
session_flatten :: proc(sh: ^Session_History, allocator := context.temp_allocator) -> []^History_Entry {
	out := make([dynamic]^History_Entry, 0, sh.count, allocator)
	if sh.root == nil { return out[:] }
	walk :: proc(e: ^History_Entry, out: ^[dynamic]^History_Entry) {
		for c in e.children {
			append(out, c)
			walk(c, out)
		}
	}
	walk(sh.root, &out)
	return out[:]
}
