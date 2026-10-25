package browser

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "toolkit:ui"
import "wb:base"
import "wb:fetch"
import "wb:httpcache"
import "wb:page"
import "wb:url"

// The shell's side of the HTTP cache (package httpcache, used by package fetch): created with the profile (on disk in
// <profile>/cache when the profile is kept), its preferences applied as they change, written and closed at exit; F5
// revalidates the document, Ctrl+F5 bypasses the cache for the document and what it loads, back / forward prefer the
// cache (network.cache.history_prefer_cache); about:cache lists what is stored and clears it, as does the command
// "Clear the cache".

CACHE_URL :: "about:cache"

_ :: os   // used by the profile build only

// How many entries about:cache lists at most (the newest first; the filter narrows them).
@(private = "file") CACHE_PAGE_MAX_ROWS :: 1000

http_cache_start :: proc(app: ^App) {
	s := httpcache.settings_from_prefs(&app.prefs)
	defer httpcache.settings_destroy(&s)
	dir := ""
	if app.cfg.persist_profile && s.disk_enabled {
		dir = s.directory != "" ? s.directory : strings.concatenate({app.profile_dir, "/cache"}, context.temp_allocator)
	}
	app.profile.cache = httpcache.create(&app.loop, s, dir)
}

http_cache_apply :: proc(app: ^App) {
	if app.profile.cache == nil { return }
	s := httpcache.settings_from_prefs(&app.prefs)
	defer httpcache.settings_destroy(&s)
	httpcache.apply_settings(app.profile.cache, s)
}

http_cache_stop :: proc(app: ^App) {
	httpcache.destroy(app.profile.cache)
	app.profile.cache = nil
}

http_cache_clear :: proc(app: ^App) {
	if app.profile.cache == nil { return }
	httpcache.clear_all(app.profile.cache)
	if t := current_tab(app); t != nil { set_status(t, "the HTTP cache was cleared") }
	app.frames_requested = max(app.frames_requested, 2)
}

// The cache mode of a history traversal (back, forward): a stale document is shown as it was, without asking.
history_cache_mode :: proc(app: ^App) -> fetch.Cache_Mode {
	c := app.profile.cache
	return c != nil && c.settings.history_prefer_cache ? .Force_Cache : .Default
}

// What the status bar adds to "HTTP 200".
cache_status_suffix :: proc(o: fetch.Cache_Outcome) -> string {
	switch o {
	case .Network: return ""
	case .Hit: return " (cache)"
	case .Revalidated: return " (304, cache)"
	case .Stale: return " (cache, refreshing)"
	}
	return ""
}

// "doc=<network|cache|304> net=N cache=N 304=N net_bytes=N fonts=<faces ready>/<faces>": the measurements of a first
// paint (first_paint.odin prof_first_paint).
cache_prof_fields :: proc(t: ^Tab) -> string {
	doc := "?"
	if t.load != nil {
		switch t.load.from_cache {
		case .Network: doc = "network"
		case .Hit, .Stale: doc = "cache"
		case .Revalidated: doc = "304"
		}
	}
	c: fetch.Fetch_Counts
	ready, all := 0, 0
	if t.page != nil {
		c = t.page.env.counts
		ready, all = len(page.fonts_ready(t.page)), len(page.fonts_all(t.page))
	}
	return fmt.tprintf("doc=%s\tnet=%d\tcache=%d\t304=%d\tnet_bytes=%d\tfonts=%d/%d", doc, c.network, c.cache, c.revalidated, c.network_bytes, ready, all)
}

// Profile build (WREN_PROF set): what the page of `t` cost when it is left (a navigation, the browser closing),
// appended to <WREN_PROF>.requests.txt as "URL, document source, subresources by source, network bytes".
cache_prof_leave :: proc(t: ^Tab) {
	when PROFILE {
		if !prof.on || t == nil || t.page == nil || t.kind != .Web { return }
		path := strings.concatenate({prof.out, ".requests.txt"}, context.temp_allocator)
		f, err := os.open(path, {.Write, .Create, .Append}, os.Permissions_Default_File)
		if err != nil { return }
		defer os.close(f)
		os.write_string(f, fmt.tprintf("%s\t%s\n", t.page.env.location.href, cache_prof_fields(t)))
	}
}

// The status bar's tip: where this page's requests came from.
cache_requests_tip :: proc(t: ^Tab) -> string {
	if t == nil || t.page == nil { return "Requests of this tab" }
	c := t.page.env.counts
	return fmt.tprintf("Requests of this tab (the Network tab's list), %d of them in flight. Subresources of this page: %d from the network (%s), %d from the cache, %d revalidated (304)", t.net.pending, c.network, size_text(c.network_bytes), c.cache, c.revalidated)
}

is_cache_address :: proc(a: string) -> bool { return a == CACHE_URL || strings.has_prefix(a, CACHE_URL + "?") }

////////////////////////////////
// about:cache

@(private = "file")
CACHE_PAGE_STYLE :: `
  html { background-color: #0d1017; }
  body { margin: 0; color: #c9d1e3; font-family: system-ui; font-size: 14px; }
  .main { max-width: 1100px; box-sizing: border-box; margin: 0 auto; padding: 28px 20px; }
  h1 { font-size: 26px; margin: 0 0 6px; color: #f1f4fb; }
  .intro { color: #8993ad; margin: 0 0 20px; }
  .stats { display: flex; flex-wrap: wrap; gap: 8px; margin: 0 0 16px; }
  .stat { padding: 6px 12px; background-color: #131825; border: 1px solid #232b40; border-radius: 8px; min-width: 100px; }
  .stat b { display: block; font-size: 16px; color: #f1f4fb; }
  .stat span { color: #8993ad; font-size: 12px; }
  form { display: flex; gap: 8px; margin: 0 0 14px; }
  input[type=search] { flex: 1; padding: 6px 10px; background-color: #131825; color: #c9d1e3; border: 1px solid #2c3550; border-radius: 6px; }
  button, .clear { padding: 6px 14px; border-radius: 6px; border: 1px solid #2f5ea8; background-color: #10213f; color: #9cc0f2; text-decoration: none; }
  .clear { border-color: #a83a2f; background-color: #3f1410; color: #f2a59c; }
  button:hover { background-color: #17305a; }
  button:active { background-color: #1e3c70; }
  .clear:hover { background-color: #561c16; }
  .clear:active { background-color: #6b231b; }
  input[type=search]:hover { border-color: #3f4b6e; }
  tr:hover td { background-color: #121826; }
  table { width: 100%; border-collapse: collapse; }
  th { text-align: left; color: #8993ad; font-weight: normal; border-bottom: 1px solid #232b40; padding: 4px 6px; }
  td { border-bottom: 1px solid #1a2133; padding: 4px 6px; vertical-align: top; }
  td { white-space: nowrap; }
  td.url { white-space: normal; word-break: break-all; color: #f1f4fb; }
  td.part { color: #8993ad; font-size: 12px; }
  .fresh { color: #7fd68a; }
  .stale { color: #ffb84d; }
  .note { color: #8993ad; margin: 14px 0 0; }
  code { color: #c9d1e3; background-color: #1b2132; padding: 0 3px; border-radius: 3px; }
`

@(private = "file")
size_text :: proc(n: i64) -> string {
	switch {
	case n >= 1 << 30: return fmt.tprintf("%.1f GiB", f64(n) / f64(1 << 30))
	case n >= 1 << 20: return fmt.tprintf("%.1f MiB", f64(n) / f64(1 << 20))
	case n >= 1 << 10: return fmt.tprintf("%.1f KiB", f64(n) / f64(1 << 10))
	}
	return fmt.tprintf("%d B", n)
}

@(private = "file")
duration_text :: proc(s: i64) -> string {
	switch {
	case s >= 2 * 86400: return fmt.tprintf("%d days", s / 86400)
	case s >= 2 * 3600: return fmt.tprintf("%d h", s / 3600)
	case s >= 120: return fmt.tprintf("%d min", s / 60)
	}
	return fmt.tprintf("%d s", s)
}

@(private = "file")
query_param :: proc(query, name: string) -> string {
	sp := url.params_make(context.temp_allocator)
	url.params_parse(&sp, query)
	v, _ := url.params_get(sp, name)
	return v
}

@(private = "file")
stat_box :: proc(sb: ^strings.Builder, value, label: string) {
	fmt.sbprintf(sb, "<div class=\"stat\"><b>%s</b><span>%s</span></div>", escape_html(value), escape_html(label))
}

cache_page_html :: proc(app: ^App, filter: string, cleared: bool) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>HTTP cache</title>\n<style>")
	strings.write_string(&sb, CACHE_PAGE_STYLE)
	strings.write_string(&sb, "</style>\n</head>\n<body>\n<div class=\"main\">\n<h1>HTTP cache</h1>\n")
	c := app.profile.cache
	if c == nil {
		strings.write_string(&sb, "<p class=\"intro\">There is no HTTP cache in this browser.</p></div></body></html>")
		return strings.to_string(sb)
	}
	s := httpcache.summary(c)
	where_ := s.directory != "" ? fmt.tprintf("on disk in <code>%s</code>", escape_html(s.directory)) : "in memory only (the profile is not kept, or <code>network.cache.disk.enabled</code> is off)"
	fmt.sbprintf(&sb, "<p class=\"intro\">Responses kept by the browser (RFC 9111), %s, keyed by the site of the page and the URL. %s%s</p>\n",
		where_, c.settings.enabled ? "" : "<b>The cache is off</b> (<code>network.cache.enabled</code>). ", cleared ? "<b>The cache was cleared.</b>" : "")
	strings.write_string(&sb, "<div class=\"stats\">")
	stat_box(&sb, fmt.tprintf("%d", s.entries), "entries")
	stat_box(&sb, size_text(s.disk_bytes), fmt.tprintf("on disk (of %s)", size_text(c.settings.disk_max_bytes)))
	stat_box(&sb, size_text(s.resident_bytes), fmt.tprintf("in memory, %d entries (of %s)", s.resident, size_text(c.settings.memory_max_bytes)))
	stat_box(&sb, fmt.tprintf("%d", s.stats.hits), "served from the cache")
	stat_box(&sb, fmt.tprintf("%d", s.stats.revalidated), "revalidated (304)")
	stat_box(&sb, fmt.tprintf("%d", s.stats.misses), "fetched")
	stat_box(&sb, fmt.tprintf("%d", s.stats.stored), "stored")
	stat_box(&sb, fmt.tprintf("%d", s.stats.evicted), "evicted")
	stat_box(&sb, size_text(s.stats.bytes_served), "bytes served from the cache")
	if s.stats.disk_failures > 0 { stat_box(&sb, fmt.tprintf("%d", s.stats.disk_failures), "damaged files dropped") }
	if !s.ready { stat_box(&sb, "loading", "the index") }
	strings.write_string(&sb, "</div>\n")
	fmt.sbprintf(&sb, "<form action=\"%s\" method=\"get\"><input type=\"search\" name=\"q\" value=\"%s\" placeholder=\"Filter by URL or site\"><button type=\"submit\">Filter</button><a class=\"clear\" href=\"%s?clear=1\">Clear the cache</a></form>\n",
		CACHE_URL, escape_html(filter), CACHE_URL)
	strings.write_string(&sb, "<table><tr><th>URL</th><th>Status</th><th>Size</th><th>Fresh until</th><th>Last used</th><th>Where</th></tr>\n")
	now := httpcache.now_s()
	shown, matching := 0, 0
	needle := strings.to_lower(filter, context.temp_allocator)
	for e := httpcache.first(c); e != nil; e = e.next {
		if needle != "" && !strings.contains(strings.to_lower(e.key, context.temp_allocator), needle) { continue }
		matching += 1
		if shown >= CACHE_PAGE_MAX_ROWS { continue }
		shown += 1
		// the key: "1/<top-level site> <frame site> <credentials><n?> <url>"
		part := ""
		if f := strings.split_n(e.key, " ", 4, context.temp_allocator); len(f) == 4 {
			part = fmt.tprintf("%s · %s · %s", strings.trim_prefix(f[0], "1/"), f[1], strings.has_prefix(f[2], "c") ? "with credentials" : "anonymous")
		}
		fresh := e.fresh_until > now
		used := time.unix(e.last_used_ms / 1000, 0)
		y, mo, d := time.date(used)
		h, mi, sec := time.clock(used)
		where_e := e.resident ? (e.disk == .Stored ? "memory + disk" : (e.disk == .Writing ? "memory, writing" : "memory")) : "disk"
		fmt.sbprintf(&sb, "<tr><td class=\"url\">%s<div class=\"part\">%s</div></td><td>%d</td><td>%s</td><td class=\"%s\">%s</td><td>%04d-%02d-%02d %02d:%02d:%02d UTC</td><td>%s</td></tr>\n",
			escape_html(e.url), escape_html(part), e.status, size_text(e.body_size), fresh ? "fresh" : "stale",
			fresh ? duration_text(e.fresh_until - now) : "stale", y, int(mo), d, h, mi, sec, where_e)
	}
	strings.write_string(&sb, "</table>\n")
	if matching > shown { fmt.sbprintf(&sb, "<p class=\"note\">%d more entries are not listed: filter to find them.</p>\n", matching - shown) }
	if matching == 0 { strings.write_string(&sb, "<p class=\"note\">Nothing stored matches.</p>\n") }
	strings.write_string(&sb, "<p class=\"note\">Settings: <code>network.cache.*</code> in about:config. F5 revalidates the page with its server; Ctrl+F5 loads it and everything it uses from the network.</p>\n")
	strings.write_string(&sb, "</div>\n</body>\n</html>\n")
	return strings.to_string(sb)
}

// about:cache, about:cache?q=filter; about:cache?clear=1 clears the cache when the browser itself or about:cache asks
// (`acts`, from nav_judge: a web page linking there, or a navigation replayed, does nothing).
show_cache_page :: proc(app: ^App, t: ^Tab, target: string, acts: bool) {
	query := ""
	if i := strings.index_byte(target, '?'); i >= 0 { query = target[i + 1:] }
	filter := query_param(query, "q")
	cleared := false
	if query_param(query, "clear") == "1" && acts {
		http_cache_clear(app)
		cleared = true
		// the entry is about:cache again: going back here must not clear it once more
		page.session_replace(&t.session, CACHE_URL)
		sync_history(t)
	}
	base.scope_close(t.nav)
	t.nav = base.scope_make("navigation", t.scope)
	t.load, t.kind = nil, .Web
	shown := cleared ? CACHE_URL : target
	t.page = page.page_create(&app.loop, &app.loader, &app.page_settings, t.nav, shown, console_sink, t)
	attach_page(app, t, t.page)
	layout_reset(&t.layout)
	t.scroll_target = base.NIL_HANDLE
	t.scroll = 0
	console_reset(t)
	page.load_html(t.page, transmute([]byte)cache_page_html(app, filter, cleared))
	if c := app.profile.cache; c != nil && !httpcache.is_ready(c) {
		// at start-up the index is still being read: the page is made again once it is
		httpcache.when_ready(c, proc(user: rawptr, ok: bool) {
			id := u64(uintptr(user))
			for tab in the_app.tabs {
				if tab.id == id && is_cache_address(tab.url) { show_cache_page(the_app, tab, strings.clone(tab.url, context.temp_allocator), false); break }
			}
			the_app.frames_requested = max(the_app.frames_requested, 2)
		}, rawptr(uintptr(t.id)))
	}
	delete(t.url); t.url = strings.clone(shown)
	delete(t.title); t.title = strings.clone("HTTP cache")
	set_status(t, cleared ? "the HTTP cache was cleared" : CACHE_URL)
	ui.field_set(&app.address, shown)
}
