package browser

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "wb:host"

@(private = "file")
globals_lock: sync.Mutex

@(private = "file")
DAY :: i64(86_400_000)

@(private = "file")
NOW :: i64(1_800_000_000_000)

@(private = "file")
visit_list :: proc(spec: []struct { url, title: string, n: int, age_days: i64 }) -> [dynamic]Visit {
	out := make([dynamic]Visit)
	id: u64 = 0
	for s in spec {
		for k in 0 ..< s.n {
			id += 1
			append(&out, Visit{id = id, at_ms = NOW - s.age_days * DAY - i64(k) * 1000, url = strings.clone(s.url), title = strings.clone(s.title)})
		}
	}
	// in time order, as the history keeps them
	for i := 1; i < len(out); i += 1 {
		for j := i; j > 0 && out[j - 1].at_ms > out[j].at_ms; j -= 1 { out[j - 1], out[j] = out[j], out[j - 1] }
	}
	for &v, i in out { v.id = u64(i + 1) }
	return out
}

@(private = "file")
urls_of :: proc(x: ^Url_Index, m: []Url_Match) -> []string {
	out := make([]string, len(m), context.temp_allocator)
	for r, i in m { out[i] = x.entries[r.entry].url }
	return out
}

// Prefix of the address first, by frecency; then words of the title or the address; one entry per address.
@(test)
urlbar_ranking :: proc(t: ^testing.T) {
	visits := visit_list({
		{"https://github.com/", "GitHub", 10, 1},
		{"https://gitlab.com/", "GitLab", 2, 1},
		{"https://docs.example.com/book/git", "The Git book", 1, 2},
		{"https://example.org/github-mirror", "Mirror", 40, 200},   // many, but long ago
		{"https://www.github.com/odin-lang/Odin", "Odin", 3, 3},
		{"https://news.example/", "News", 5, 1},
	})
	defer visits_destroy(&visits)
	x: Url_Index
	defer url_index_destroy(&x)
	url_index_build(&x, visits[:], 1, NOW)
	testing.expect_value(t, len(x.entries), 6)   // one per address
	e := &x.entries[x.by_url["https://github.com/"]]
	testing.expect_value(t, e.visits, 10)
	testing.expect_value(t, e.frecency, f32(1000))
	m := url_index_query(&x, "git", 10)
	got := urls_of(&x, m)
	testing.expect_value(t, len(got), 5)
	if len(got) == 5 {
		testing.expect_value(t, got[0], "https://github.com/")
		testing.expect_value(t, got[1], "https://www.github.com/odin-lang/Odin")   // prefix (www. ignored), 3 recent visits
		testing.expect_value(t, got[2], "https://gitlab.com/")
		testing.expect(t, m[0].prefix && m[2].prefix && !m[3].prefix && !m[4].prefix, "prefix matches first")
		testing.expect_value(t, got[3], "https://example.org/github-mirror")   // words: 40 * 10 > 1 * 100
		testing.expect_value(t, got[4], "https://docs.example.com/book/git")
	}
	// words of the title, in any order; nothing for no match; an empty query is no query
	w := urls_of(&x, url_index_query(&x, "book the", 10))
	testing.expect(t, len(w) == 1 && w[0] == "https://docs.example.com/book/git", "title words")
	testing.expect_value(t, len(url_index_query(&x, "zzz", 10)), 0)
	testing.expect_value(t, len(url_index_query(&x, "  ", 10)), 0)
	// the scheme typed: only that scheme's addresses as prefix
	s := url_index_query(&x, "https://gith", 10)
	testing.expect(t, len(s) >= 2 && s[0].prefix, "a typed scheme matches as a prefix")
	testing.expect_value(t, len(url_index_query(&x, "http://gith", 10)), 0)
	// at most n
	testing.expect_value(t, len(url_index_query(&x, "e", 2)), 2)
}

// Typing on narrows the previous matches: the results are those of a fresh query.
@(test)
urlbar_narrowing_is_exact :: proc(t: ^testing.T) {
	visits := visit_list({{"https://github.com/", "GitHub", 3, 1}, {"https://gitlab.com/", "GitLab", 2, 1}, {"https://digit.example/", "Digits", 1, 1}, {"https://www.gizmo.example/", "Gizmo", 1, 1}})
	defer visits_destroy(&visits)
	a, b: Url_Index
	defer url_index_destroy(&a)
	defer url_index_destroy(&b)
	url_index_build(&a, visits[:], 1, NOW)
	url_index_build(&b, visits[:], 1, NOW)
	for q in ([]string{"g", "gi", "git", "gith", "github.", "www.", "www.giz"}) {
		_ = url_index_query(&a, q, 10)   // typed letter by letter
		fresh := urls_of(&b, url_index_query(&b, q, 10))
		b.prev_valid = false
		typed := urls_of(&a, url_index_query(&a, q, 10))
		testing.expectf(t, len(fresh) == len(typed), "%q: %v vs %v", q, typed, fresh)
		for i in 0 ..< min(len(fresh), len(typed)) { testing.expect_value(t, typed[i], fresh[i]) }
	}
}

// The completion: up to the host and its "/", or past it up to the next "/"; the address's own letters and scheme.
@(test)
urlbar_autofill :: proc(t: ^testing.T) {
	visits := visit_list({
		{"https://github.com/", "GitHub", 10, 1},
		{"https://github.com/odin-lang/Odin", "Odin", 4, 1},
		{"https://www.wikipedia.org/", "Wikipedia", 2, 1},
		{"http://localhost:8765/demo", "Demo", 1, 1},
	})
	defer visits_destroy(&visits)
	x: Url_Index
	defer url_index_destroy(&x)
	url_index_build(&x, visits[:], 1, NOW)
	fill :: proc(x: ^Url_Index, typed: string) -> (string, string, bool) {
		text, address, _, ok := url_autofill(x, typed, url_index_query(x, typed, 8))
		return text, address, ok
	}
	text, address, ok := fill(&x, "git")
	testing.expect(t, ok && text == "github.com/" && address == "https://github.com/", fmt.tprint(text, address))
	text, address, ok = fill(&x, "Git")
	testing.expect(t, ok && text == "Github.com/", "what was typed keeps its letters")
	text, address, ok = fill(&x, "github.com/od")
	testing.expect(t, ok && text == "github.com/odin-lang/" && address == "https://github.com/odin-lang/", fmt.tprint(text, address))
	text, address, ok = fill(&x, "github.com/odin-lang/O")
	testing.expect(t, ok && text == "github.com/odin-lang/Odin" && address == "https://github.com/odin-lang/Odin", fmt.tprint(text, address))
	text, address, ok = fill(&x, "wiki")
	testing.expect(t, ok && text == "wikipedia.org/" && address == "https://www.wikipedia.org/", fmt.tprint(text, address))
	text, address, ok = fill(&x, "www.wiki")
	testing.expect(t, ok && text == "www.wikipedia.org/", fmt.tprint(text, address))
	text, address, ok = fill(&x, "https://git")
	testing.expect(t, ok && text == "https://github.com/" && address == "https://github.com/", fmt.tprint(text, address))
	text, address, ok = fill(&x, "localh")
	testing.expect(t, ok && text == "localhost:8765/" && address == "http://localhost:8765/", fmt.tprint(text, address))
	// nothing to complete: words, a full address, no prefix match
	_, _, ok = fill(&x, "git hub")
	testing.expect(t, !ok, "words")
	_, _, ok = fill(&x, "github.com/")
	testing.expect(t, !ok, "already complete")
	_, _, ok = fill(&x, "odin")
	testing.expect(t, !ok, "a word of the path is no prefix")
}

// In step with the history without reading it all again: appended visits and titles; a rebuild when visits went;
// a forgotten address leaves at once.
@(test)
urlbar_index_sync :: proc(t: ^testing.T) {
	visits := visit_list({{"https://a.example/", "A", 2, 1}, {"https://b.example/", "", 1, 1}})
	defer visits_destroy(&visits)
	x: Url_Index
	defer url_index_destroy(&x)
	url_index_sync(&x, visits[:], 1, NOW)
	testing.expect_value(t, x.rebuilds, 1)
	append(&visits, Visit{id = 100, at_ms = NOW, url = strings.clone("https://c.example/"), title = strings.clone("C")})
	url_index_sync(&x, visits[:], 2, NOW)
	testing.expect_value(t, x.rebuilds, 1)
	testing.expect_value(t, len(x.entries), 3)
	// a title arrives for b's last visit
	for &v in visits { if v.url == "https://b.example/" { delete(v.title); v.title = strings.clone("Bee") } }
	url_index_sync(&x, visits[:], 3, NOW)
	testing.expect_value(t, x.entries[x.by_url["https://b.example/"]].title, "Bee")
	// visits deleted elsewhere (about:history, the oldest trimmed): their weight goes, an address left without any too
	a := x.by_url["https://a.example/"]
	ids := []u64{1}
	history_delete(&visits, ids)
	url_index_sync(&x, visits[:], 4, NOW)
	testing.expect_value(t, x.entries[a].visits, 1)
	testing.expect_value(t, x.entries[a].frecency, f32(100))
	ids = []u64{100}
	history_delete(&visits, ids)
	url_index_sync(&x, visits[:], 5, NOW)
	testing.expect_value(t, len(url_index_query(&x, "c.example", 5)), 0)
	testing.expect_value(t, x.rebuilds, 1)   // no full build for any of it
	// forgotten through the address bar: out of the results at once
	ids = []u64{2}
	history_delete(&visits, ids)
	url_index_forget(&x, "https://a.example/")
	testing.expect_value(t, len(url_index_query(&x, "a.example", 5)), 0)
	url_index_sync(&x, visits[:], 6, NOW)
	testing.expect_value(t, x.rebuilds, 1)
	testing.expect_value(t, len(x.vis), len(visits))
	// visited again later: back
	append(&visits, Visit{id = 200, at_ms = NOW, url = strings.clone("https://a.example/"), title = strings.clone("A")})
	url_index_sync(&x, visits[:], 7, NOW)
	testing.expect_value(t, len(url_index_query(&x, "a.example", 5)), 1)
	// the day after, when the field gets the keyboard: the weights are computed again
	url_index_sync(&x, visits[:], 7, NOW + DAY * 2, age = true)
	testing.expect_value(t, x.rebuilds, 2)
}

// The list: the typed row first (or the completion), the history after it, a search when the text looked like an
// address; data: and javascript: never; the cross removes every visit of the address, in the profile too, and the list
// stays with the next row chosen.
@(test)
urlbar_rows_and_removal :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	host.loop_init(&app.loop)
	defer host.loop_destroy(&app.loop)
	host.blocking_init(&app.blocking, &app.loop, 1)
	defer host.blocking_destroy(&app.blocking)
	sync.mutex_lock(&globals_lock)   // (the history, its settings and the bar are globals)
	defer sync.mutex_unlock(&globals_lock)
	saved_ghist, saved_hcfg, saved_ub := ghist, hcfg, ub
	defer { ghist, hcfg, ub = saved_ghist, saved_hcfg, saved_ub }
	hcfg = {global = true, max_visits = 1000, max_url_bytes = 8192, save_delay_ms = 1}
	ub = {}
	ub.cfg = {enabled = true, history = true, tabs = true, search = true, autofill = true, max_rows = 8, max_tab_rows = 3, min_chars = 1}
	dir := strings.concatenate({os.get_env("TEMP", context.temp_allocator), "/wren_urlbar_test"}, context.temp_allocator)
	_ = os.make_directory_all(dir)
	path := strings.concatenate({dir, "/history.txt"}, context.temp_allocator)
	now := time.time_to_unix_nano(time.now()) / 1e6
	ghist = {app = app, path = strings.clone(path)}
	add :: proc(url, title: string, at: i64) {
		ghist.next_id += 1
		append(&ghist.visits, Visit{id = ghist.next_id, at_ms = at, url = strings.clone(url), title = strings.clone(title)})
	}
	add("https://github.com/", "GitHub", now - 3000)
	add("https://github.com/", "GitHub", now - 2000)
	add("https://gitlab.com/", "GitLab", now - 1500)
	add("https://example.com/gitea", "Gitea notes", now - 1000)
	add("data:text/html,git", "", now - 900)   // (never recorded; never shown either)
	ghist.serial = 1
	defer {
		visits_destroy(&ghist.visits)
		delete(ghist.path)
		url_index_destroy(&ub.idx)
		delete(ub.rows); delete(ub.typed); delete(ub.fill_text); delete(ub.fill_address)
		delete(app.address.buf)
	}

	// "git" typed: completed to github.com/, the completion's row first, gitlab and gitea after it, a search last
	ub.typed = strings.clone("git")
	urlbar_refresh(app, .New)
	testing.expect(t, ub.open, "open")
	testing.expect_value(t, string(app.address.buf[:]), "github.com/")
	testing.expect(t, app.address.mark == 3 && app.address.cursor == len("github.com/"), "the completed part is selected")
	kinds := make([dynamic]Urlbar_Row_Kind, context.temp_allocator)
	for r in ub.rows { append(&kinds, r.kind) }
	testing.expectf(t, len(ub.rows) == 3 && ub.rows[0].fill && kinds[1] == .History && kinds[2] == .History, "%v", kinds)
	for r in ub.rows { if r.kind == .History { testing.expect(t, !strings.has_prefix(ub.idx.entries[r.entry].url, "data:"), "no data:") } }

	// words: the typed row first ("Search")
	delete(ub.typed); ub.typed = strings.clone("gitea notes")
	urlbar_refresh(app, .New)
	testing.expect(t, len(ub.rows) == 2 && ub.rows[0].kind == .Search && ub.rows[1].kind == .History, "a search, then the page")
	// an address: Go first, a search last
	delete(ub.typed); ub.typed = strings.clone("gitlab.co")
	urlbar_refresh(app, .None)
	testing.expect(t, len(ub.rows) == 3 && ub.rows[0].kind == .Go && ub.rows[1].kind == .History && ub.rows[2].kind == .Search, "go, the page, search")

	// the cross on gitlab's row (chosen with Down): removed from the history, the next row chosen, the text kept
	delete(ub.typed); ub.typed = strings.clone("git")
	urlbar_refresh(app, .None)   // (no completion: Backspace removed it)
	testing.expect_value(t, string(app.address.buf[:]), "github.com/")   // (the field is the app's: left as it was)
	at := -1
	for r, i in ub.rows { if r.kind == .History && ub.idx.entries[r.entry].url == "https://gitlab.com/" { at = i } }
	testing.expect(t, at > 0, "gitlab is listed")
	urlbar_choose(app, at)
	testing.expect_value(t, string(app.address.buf[:]), "https://gitlab.com/")
	n := len(ub.rows)
	urlbar_remove_row(app, at)
	testing.expect(t, ub.open, "the list stays open")
	testing.expect_value(t, len(ub.rows), n - 1)
	testing.expect_value(t, ub.typed, "git")
	for r in ub.rows { if r.kind == .History { testing.expect(t, ub.idx.entries[r.entry].url != "https://gitlab.com/", "gone from the list") } }
	for v in ghist.visits { testing.expect(t, v.url != "https://gitlab.com/", "gone from the history") }
	testing.expect_value(t, ub.sel, min(at, len(ub.rows) - 1))
	// written at once: wait for the background write
	deadline := time.tick_now()
	for ghist.saving && time.duration_seconds(time.tick_since(deadline)) < 10 { host.run_ready(&app.loop); time.sleep(5 * time.Millisecond) }
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil, "the history file was written")
	testing.expect(t, strings.contains(string(data), "https://github.com/") && !strings.contains(string(data), "gitlab"), "the profile's history has no gitlab")
	os.remove(path)
}

// A large history is indexed on a thread from a copy: no history rows meanwhile, then the rows; what changed in the
// history during the build is caught up; the bar closing during a build waits for it and frees everything.
@(test)
urlbar_thread_build :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	host.loop_init(&app.loop)
	defer host.loop_destroy(&app.loop)
	host.blocking_init(&app.blocking, &app.loop, 1)
	defer host.blocking_destroy(&app.blocking)
	sync.mutex_lock(&globals_lock)   // (the history, its settings and the bar are globals)
	defer sync.mutex_unlock(&globals_lock)
	saved_ghist, saved_hcfg, saved_ub := ghist, hcfg, ub
	defer { ghist, hcfg, ub = saved_ghist, saved_hcfg, saved_ub }
	hcfg = {global = true, max_visits = 100_000, max_url_bytes = 8192}
	ub = {app = app}
	ub.cfg = {enabled = true, history = true, max_rows = 8, min_chars = 1}
	ghist = {app = app}
	now := time.time_to_unix_nano(time.now()) / 1e6
	for i in 0 ..< URLBAR_THREAD_VISITS + 100 {
		ghist.next_id += 1
		append(&ghist.visits, Visit{id = ghist.next_id, at_ms = now - i64(URLBAR_THREAD_VISITS + 100 - i) * 1000, url = fmt.aprintf("https://site%d.example/", i % 1000), title = fmt.aprintf("Site %d", i % 1000)})
	}
	ghist.serial = 1
	defer {
		visits_destroy(&ghist.visits)
		delete(ub.rows); delete(ub.typed); delete(ub.fill_text); delete(ub.fill_address)
		delete(app.address.buf)
	}
	ub.typed = strings.clone("site12")
	urlbar_refresh(app, .None)
	testing.expect(t, ub.job.state != .Idle, "a build on the pool")
	for r in ub.rows { testing.expect(t, r.kind != .History, "no history rows before the index is built") }
	// meanwhile: a visit deleted, one appended
	ids := []u64{ghist.visits[0].id}
	history_delete(&ghist.visits, ids)
	ghist.next_id += 1
	append(&ghist.visits, Visit{id = ghist.next_id, at_ms = now, url = strings.clone("https://site12-new.example/"), title = strings.clone("New")})
	ghist.serial = 2
	start := time.tick_now()
	for ub.job.state != .Idle && time.duration_seconds(time.tick_since(start)) < 20 { host.run_ready(&app.loop); time.sleep(2 * time.Millisecond) }
	testing.expect(t, ub.job.state == .Idle, "the build came back")
	urlbar_refresh(app, .None)
	urls := make([dynamic]string, context.temp_allocator)
	for r in ub.rows { if r.kind == .History { append(&urls, ub.idx.entries[r.entry].url) } }
	testing.expectf(t, len(urls) >= 2, "history rows: %v", urls)
	testing.expect_value(t, len(url_index_query(&ub.idx, "site12-new", 5)), 1)   // appended during the build: there
	testing.expect_value(t, len(ub.idx.vis), len(ghist.visits))

	// a build running when the bar goes: waited for, freed (the tracking allocator reports a leak otherwise)
	ub.idx.now_ms = 0   // a day old: the next focus builds again
	testing.expect(t, !urlbar_index_ready(app, age = true), "a new build started")
	urlbar_destroy(app)
	testing.expect(t, ub.job.state == .Idle && ub.idx.serial == 0, "destroyed")
}

// 50 000 visits of 12 000 addresses: a query per letter typed stays under 2 ms (an optimized build; the test build is
// not: it checks a looser bound and prints the times).
@(test)
urlbar_speed :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // the browser's (not the test runner's tracking allocator)
	visits := make([dynamic]Visit)
	defer visits_destroy(&visits)
	hosts := []string{"github.com", "developer.mozilla.org", "news.ycombinator.com", "en.wikipedia.org", "docs.odin-lang.org", "stackoverflow.com", "www.example.com", "learn.microsoft.com"}
	for i in 0 ..< 50_000 {
		u := i % 12_000
		url := fmt.aprintf("https://%s/section-%d/page-%d?q=%d", hosts[u % len(hosts)], u / 97, u, u * 7)
		title := fmt.aprintf("Page %d of %s: article about topic %d", u, hosts[u % len(hosts)], u % 300)
		append(&visits, Visit{id = u64(i + 1), at_ms = NOW - i64(50_000 - i) * 60_000, url = url, title = title})
	}
	x: Url_Index
	defer url_index_destroy(&x)
	start := time.tick_now()
	url_index_build(&x, visits[:], 1, NOW)
	build_ms := time.duration_milliseconds(time.tick_since(start))
	testing.expect_value(t, len(x.entries), 12_000)
	worst, total: f64
	typed := "developer.mozilla.org/en"
	n := 0
	samples := make([dynamic]f64)
	defer delete(samples)
	for round in 0 ..< 3 {
		x.prev_valid = false
		for i in 1 ..= len(typed) {
			s := time.tick_now()
			m := url_index_query(&x, typed[:i], 12)
			_, _, _, _ = url_autofill(&x, typed[:i], m)
			ms := time.duration_milliseconds(time.tick_since(s))
			if round > 0 { worst = max(worst, ms); total += ms; n += 1; append(&samples, ms) }
			free_all(context.temp_allocator)
		}
	}
	words := time.tick_now()
	x.prev_valid = false
	_ = url_index_query(&x, "article topic 42", 12)
	words_ms := time.duration_milliseconds(time.tick_since(words))
	// browsing at the history's limit: each visit trims the oldest one; the sync walks, builds nothing
	delete(visits[0].url); delete(visits[0].title)
	ordered_remove(&visits, 0)
	append(&visits, Visit{id = 60_000, at_ms = NOW, url = strings.clone("https://github.com/new"), title = strings.clone("New")})
	s := time.tick_now()
	url_index_sync(&x, visits[:], 2, NOW)
	sync_ms := time.duration_milliseconds(time.tick_since(s))
	testing.expect_value(t, x.rebuilds, 1)
	slice.sort(samples[:])
	p90 := samples[len(samples) * 9 / 10]
	fmt.printf("urlbar_speed: %d entries, build %.2f ms, per letter mean %.3f ms 90th percentile %.3f ms worst %.3f ms, three words at once %.3f ms, sync after a trim %.3f ms\n", len(x.entries), build_ms, total / f64(n), p90, worst, words_ms, sync_ms)
	// a time bound means nothing under AddressSanitizer (every access instrumented, several times slower): the build only
	// checks memory there
	when .Address in ODIN_SANITIZER_FLAGS {
	} else when ODIN_OPTIMIZATION_MODE == .Speed {
		testing.expect(t, worst < 2, "under 2 ms per letter")
	} else {
		// A debug build on a shared runner: one query can lose its time slice (the CI measured a mean of 0.77 ms with a
		// single 24 ms query among 48). A real slowdown (a scan of every entry per letter) moves the mean and the whole
		// distribution, so the mean and the 90th percentile are strict and the single worst only has a wide bound.
		testing.expectf(t, total / f64(n) < 5, "mean under 5 ms per letter in a debug build: %.3f", total / f64(n))
		testing.expectf(t, p90 < 20, "90th percentile under 20 ms per letter in a debug build: %.3f", p90)
		testing.expectf(t, worst < 250, "worst under 250 ms per letter in a debug build: %.3f", worst)
	}
}
