package browser

// The address bar's index of the browsing history (urlbar.odin shows it): one entry per address, in memory, kept in
// step with the visits (global_history.odin) without reading them all again at every change.
//   * An entry: the address, its last title and icon, how often and how recently it was visited (frecency: the sum over
//     its visits of a weight by age, as Firefox buckets them: 100 within 4 days, 70 within 14, 50 within 31, 30 within
//     90, 10 beyond), its text lower-cased for matching ("bare": without the scheme nor "www.").
//   * Matching a query: an address whose bare form starts with the query (typed without a scheme, or with the entry's
//     scheme) is a prefix match, ranked first; otherwise every word of the query must occur in the title or the
//     address. Within a class: frecency, then the latest visit. Typing on (the query grows) only looks at the entries
//     the shorter one matched.
//   * Sync (url_index_sync): the visits deleted since the last one (about:history, the limits of the history) and the
//     ones appended are found by a walk over both lists, titles of the latest visits follow; nothing is read again.
//     A full build: the first time, and once a day when the field gets the keyboard (the weights age).
// Pure (no App): urlbar_test.odin.

import "core:slice"
import "core:strings"

Url_Entry :: struct {
	url:       string,   // owned: as recorded
	title:     string,   // owned: the title of its latest visit that had one
	icon:      string,   // owned
	bare:      string,   // owned: lower case, without "scheme://" nor "www."
	low_title: string,   // owned
	scheme:    string,   // slice of `url`: "https", "http", "file"...
	www:       bool,     // the address had "www." after its scheme
	host_len:  int,      // bytes of the host in `bare`
	bare_at:   int,      // where `bare` starts in `url` (its letters as recorded: url[bare_at:], when as long)
	visits:    int,
	last_ms:   i64,
	frecency:  f32,
	gone:      bool,     // forgotten (url_index_forget): left out until the next rebuild
}

// A visit as the index counted it, in the history's order.
Indexed_Visit :: struct {
	id:     u64,
	entry:  i32,
	weight: f32,
}

Url_Index :: struct {
	entries:  [dynamic]Url_Entry,
	by_url:   map[string]int,   // keys are the entries' `url`
	vis:      [dynamic]Indexed_Visit,
	serial:   u64,              // Global_History.serial in step with (0: never built)
	now_ms:   i64,              // when the weights were computed
	rebuilds: int,              // full builds (tests, measurements)
	// the last query: typing on narrows its matches instead of looking at every entry
	prev_query: string,         // owned
	prev:       [dynamic]int,
	prev_valid: bool,
}

Url_Match :: struct {
	entry:  int,
	prefix: bool,    // the bare address starts with the query
}

url_index_destroy :: proc(x: ^Url_Index) {
	url_index_clear(x)
	delete(x.entries)
	delete(x.by_url)
	delete(x.vis)
	delete(x.prev)
	delete(x.prev_query)
	x^ = {}
}

@(private = "file")
url_index_clear :: proc(x: ^Url_Index) {
	for e in x.entries { delete(e.url); delete(e.title); delete(e.icon); delete(e.bare); delete(e.low_title) }
	clear(&x.entries)
	clear(&x.by_url)
	clear(&x.vis)
	x.prev_valid = false
}

// Weight of a visit `age_ms` old in the frecency of its address.
visit_weight :: proc(age_ms: i64) -> f32 {
	DAY :: 86_400_000
	switch {
	case age_ms <= 4 * DAY:  return 100
	case age_ms <= 14 * DAY: return 70
	case age_ms <= 31 * DAY: return 50
	case age_ms <= 90 * DAY: return 30
	}
	return 10
}

// "https://www.Example.com/a" -> scheme "https", www, bare "example.com/a", host length 11, bare_at 12 (where the bare
// part starts in the address).
url_split :: proc(address: string, allocator := context.allocator) -> (scheme: string, www: bool, bare: string, host_len, bare_at: int) {
	rest := address
	if i := strings.index(rest, "://"); i > 0 {
		scheme = address[:i]
		rest = rest[i + 3:]
		bare_at = i + 3
	} else if j := strings.index_byte(rest, ':'); j > 0 {
		scheme = address[:j]   // about:, data:... (no authority)
		rest = rest[j + 1:]
		bare_at = j + 1
	}
	low := strings.to_lower(rest, allocator)
	if strings.has_prefix(low, "www.") {
		www = true
		b := strings.clone(low[4:], allocator)
		delete(low, allocator)
		low = b
		bare_at += 4
	}
	host_len = len(low)
	if j := strings.index_any(low, "/?#"); j >= 0 { host_len = j }
	return scheme, www, low, host_len, bare_at
}

@(private = "file")
entry_title :: proc(e: ^Url_Entry, v: Visit) {
	if v.title != "" && v.title != e.title { delete(e.title); delete(e.low_title); e.title = strings.clone(v.title); e.low_title = strings.to_lower(v.title) }
	if v.icon != e.icon { delete(e.icon); e.icon = strings.clone(v.icon) }
}

@(private = "file")
add_visit :: proc(x: ^Url_Index, v: Visit) {
	w := visit_weight(x.now_ms - v.at_ms)
	i, ok := x.by_url[v.url]
	if ok {
		e := &x.entries[i]
		e.visits += 1
		e.frecency += w
		if v.at_ms >= e.last_ms { e.last_ms = v.at_ms; entry_title(e, v) }
	} else {
		e := Url_Entry{url = strings.clone(v.url), title = strings.clone(v.title), icon = strings.clone(v.icon), low_title = strings.to_lower(v.title), visits = 1, last_ms = v.at_ms, frecency = w}
		e.scheme, e.www, e.bare, e.host_len, e.bare_at = url_split(e.url)
		append(&x.entries, e)
		i = len(x.entries) - 1
		x.by_url[e.url] = i
	}
	append(&x.vis, Indexed_Visit{id = v.id, entry = i32(i), weight = w})
}

// Builds the index from scratch.
url_index_build :: proc(x: ^Url_Index, visits: []Visit, serial: u64, now_ms: i64) {
	url_index_clear(x)
	x.now_ms = now_ms
	reserve(&x.entries, len(visits) / 2 + 16)
	reserve(&x.by_url, len(visits) / 2 + 16)
	reserve(&x.vis, len(visits))
	for v in visits { add_visit(x, v) }
	x.serial = serial
	x.rebuilds += 1
}

// In step with the history at `serial`. The history only appends visits, deletes some (keeping the order of the
// others) and changes titles in place: a walk over both lists finds the deleted ones (their addresses lose their
// weight; one left with none leaves) and the appended ones, without a string compared. `age`: weights older than a
// day are computed again (a full build: the caller does it where a pause does not show, when the field gets the
// keyboard). Anything unexpected (an order changed): a full build.
url_index_sync :: proc(x: ^Url_Index, visits: []Visit, serial: u64, now_ms: i64, age := false) {
	if x.serial == serial && x.serial != 0 && !(age && now_ms - x.now_ms > 86_400_000) { return }
	if x.serial == 0 || (age && now_ms - x.now_ms > 86_400_000) { url_index_build(x, visits, serial, now_ms); return }
	j, k := 0, 0
	changed := false
	for iv in x.vis {
		if j < len(visits) && visits[j].id == iv.id {
			x.vis[k] = iv
			k += 1
			j += 1
			continue
		}
		// deleted
		changed = true
		e := &x.entries[iv.entry]
		e.visits -= 1
		e.frecency -= iv.weight
		if e.visits <= 0 && !e.gone {
			e.gone = true
			if at, ok := x.by_url[e.url]; ok && at == int(iv.entry) { delete_key(&x.by_url, e.url) }
		}
	}
	resize(&x.vis, k)
	last: u64 = k > 0 ? x.vis[k - 1].id : 0
	for v in visits[j:] {
		if v.id <= last { url_index_build(x, visits, serial, now_ms); return }   // not an append: rebuilt
		add_visit(x, v)
		last = v.id
		changed = true
	}
	// titles and icons arrive after the visit (global_history_title): the latest visits' are followed
	for v in visits[max(j - 64, 0):j] {
		if i, ok := x.by_url[v.url]; ok {
			e := &x.entries[i]
			if v.at_ms >= e.last_ms { entry_title(e, v) }
		}
	}
	x.serial = serial
	if changed { x.prev_valid = false }
}

// The address is no longer in the history (its visits were just removed): out of the results at once (the next
// sync takes its visits off).
url_index_forget :: proc(x: ^Url_Index, address: string) {
	if i, ok := x.by_url[address]; ok {
		x.entries[i].gone = true
		delete_key(&x.by_url, address)
	}
	x.prev_valid = false
}

// Does entry `e` match? `q` lower case, trimmed; `qbare`/`qscheme`: the query split like an address.
@(private = "file")
entry_matches :: proc(e: ^Url_Entry, q, qbare, qscheme: string, terms: []string) -> (ok, prefix: bool) {
	if e.gone { return false, false }
	if qbare != "" && strings.has_prefix(e.bare, qbare) && (qscheme == "" || qscheme == e.scheme) { return true, true }
	for t in terms {
		if !strings.contains(e.low_title, t) && !strings.contains(e.bare, t) { return false, false }
	}
	return len(terms) > 0, false
}

// The best `max_n` matches of `query`, best first (allocated with `allocator`).
url_index_query :: proc(x: ^Url_Index, query: string, max_n: int, allocator := context.temp_allocator) -> []Url_Match {
	q := strings.to_lower(strings.trim_space(query), context.temp_allocator)
	if q == "" || max_n <= 0 { return nil }
	terms := strings.fields(q, context.temp_allocator)
	qscheme, qbare: string
	if !strings.contains(q, " ") {
		if strings.contains(q, "://") {
			s, _, b, _, _ := url_split(q, context.temp_allocator)
			qscheme, qbare = s, b
		} else {
			qbare = strings.has_prefix(q, "www.") ? q[4:] : q   // ("localhost:8080" has no scheme)
		}
	}
	// candidates: the previous query's matches when this one only adds to it (same words, more letters)
	// (not across a scheme or "www.": they change what is compared)
	narrowing := x.prev_valid && x.prev_query != "" && strings.has_prefix(q, x.prev_query) && !strings.contains(q[len(x.prev_query):], " ") &&
		!strings.contains(q, ":") && !strings.has_prefix(q, "www")
	found := make([dynamic]int, 0, narrowing ? len(x.prev) : 64)
	best := make([dynamic]Url_Match, 0, max_n + 1, context.temp_allocator)
	consider :: proc(x: ^Url_Index, best: ^[dynamic]Url_Match, max_n: int, m: Url_Match) {
		better :: proc(x: ^Url_Index, a, b: Url_Match) -> bool {
			if a.prefix != b.prefix { return a.prefix }
			ea, eb := &x.entries[a.entry], &x.entries[b.entry]
			if ea.frecency != eb.frecency { return ea.frecency > eb.frecency }
			if ea.last_ms != eb.last_ms { return ea.last_ms > eb.last_ms }
			return a.entry < b.entry
		}
		if len(best) == max_n && !better(x, m, best[len(best) - 1]) { return }
		at := len(best)
		for at > 0 && better(x, m, best[at - 1]) { at -= 1 }
		inject_at(best, at, m)
		if len(best) > max_n { pop(best) }
	}
	if narrowing {
		for i in x.prev {
			ok, prefix := entry_matches(&x.entries[i], q, qbare, qscheme, terms)
			if !ok { continue }
			append(&found, i)
			consider(x, &best, max_n, {i, prefix})
		}
	} else {
		for &e, i in x.entries {
			ok, prefix := entry_matches(&e, q, qbare, qscheme, terms)
			if !ok { continue }
			append(&found, i)
			consider(x, &best, max_n, {i, prefix})
		}
	}
	delete(x.prev)
	x.prev = found
	delete(x.prev_query)
	x.prev_query = strings.clone(q)
	x.prev_valid = true
	return slice.clone(best[:], allocator)
}

// Inline completion of `typed` (what the user typed, as typed): the best prefix match's host followed by "/" (or, when
// the typed text goes past the host, its address up to the next "/"). `text`: typed + the completed part (in the
// entry's letters); `address`: what to open. ok false: nothing to complete.
url_autofill :: proc(x: ^Url_Index, typed: string, matches: []Url_Match, allocator := context.temp_allocator) -> (text, address: string, entry: int, ok: bool) {
	if typed == "" || strings.contains(typed, " ") || len(matches) == 0 || !matches[0].prefix { return "", "", -1, false }
	e := &x.entries[matches[0].entry]
	low := strings.to_lower(typed, context.temp_allocator)
	// what was typed of the address: its bare form, or (typed with them) the scheme and www. too
	shown := e.bare
	head := ""
	if strings.contains(low, "://") { head = strings.concatenate({e.scheme, "://", e.www ? "www." : ""}, context.temp_allocator) }
	else if strings.has_prefix(low, "www.") && e.www { head = "www." }
	full := strings.concatenate({head, shown}, context.temp_allocator)
	if !strings.has_prefix(full, low) || len(low) >= len(full) { return "", "", -1, false }
	end := len(head) + e.host_len
	if len(low) >= end {
		// past the host: up to the end of the next path segment
		j := strings.index_byte(full[len(low):], '/')
		end = j >= 0 ? len(low) + j + 1 : len(full)
	} else if end < len(full) && full[end] == '/' {
		end += 1
	}
	if end <= len(low) { return "", "", -1, false }
	// the address's own letters (a path keeps its case) when lower-casing kept its length
	recorded := e.url[e.bare_at:]
	cased := len(recorded) == len(e.bare)
	from, to := len(low) - len(head), end - len(head)   // the completed part, in `bare`
	completed := cased ? recorded[from:to] : e.bare[from:to]
	text = strings.concatenate({typed, completed}, allocator)
	address = strings.clone(e.url[:e.bare_at + to], allocator) if cased else strings.concatenate({e.url[:e.bare_at], e.bare[:to]}, allocator)
	return text, address, matches[0].entry, true
}
