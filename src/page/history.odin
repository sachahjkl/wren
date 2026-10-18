package page

// A tab's joint session history: the entries back / forward walk through, with the state history.pushState saved in
// them. The shell keeps one per tab and hands it to each page of the tab (Embedder.session); a page without an
// embedder keeps a private one. Entries remember which document created them (`doc`, a page id): traversing to an entry
// of the current document is a same-document traversal (popstate), anything else is a navigation by the shell.

import "core:strings"

History_Entry :: struct {
	url:       string,   // owned
	state:     string,   // owned; history.state when has_state
	has_state: bool,
	doc:       u64,      // id of the page that owns the entry (0 = none yet)
}

Session_History :: struct {
	entries: [dynamic]History_Entry,
	index:   int,        // current entry, -1 when empty
}

session_destroy :: proc(sh: ^Session_History) {
	for e in sh.entries { delete(e.url); delete(e.state) }
	delete(sh.entries)
	sh^ = {}
}

session_current :: proc(sh: ^Session_History) -> ^History_Entry {
	if sh == nil || sh.index < 0 || sh.index >= len(sh.entries) { return nil }
	return &sh.entries[sh.index]
}

session_length :: proc(sh: ^Session_History) -> int { return len(sh.entries) if sh != nil else 0 }

// A new entry after the current one; the forward entries are dropped. With `dedupe`, visiting the URL of the current
// entry again (a reload typed in the address bar) does not add one. The oldest entries go past `max_entries`.
session_push :: proc(sh: ^Session_History, url: string, doc: u64, state := "", has_state := false, dedupe := true, max_entries := 50) -> ^History_Entry {
	if len(sh.entries) == 0 { sh.index = -1 }
	if dedupe {
		if cur := session_current(sh); cur != nil && cur.url == url { return cur }
	}
	for len(sh.entries) > sh.index + 1 {
		e := pop(&sh.entries)
		delete(e.url); delete(e.state)
	}
	append(&sh.entries, History_Entry{url = strings.clone(url), state = strings.clone(state), has_state = has_state, doc = doc})
	sh.index = len(sh.entries) - 1
	for len(sh.entries) > max(max_entries, 1) {
		delete(sh.entries[0].url); delete(sh.entries[0].state)
		ordered_remove(&sh.entries, 0)
		sh.index -= 1
	}
	return session_current(sh)
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
}

// The entry `delta` steps away, or nil when there is none.
session_peek :: proc(sh: ^Session_History, delta: int) -> ^History_Entry {
	if sh == nil { return nil }
	i := sh.index + delta
	if i < 0 || i >= len(sh.entries) { return nil }
	return &sh.entries[i]
}

// Moves the current entry `delta` steps. False (and no change) when there is no such entry.
session_go :: proc(sh: ^Session_History, delta: int) -> (^History_Entry, bool) {
	e := session_peek(sh, delta)
	if e == nil { return nil, false }
	sh.index += delta
	return e, true
}
