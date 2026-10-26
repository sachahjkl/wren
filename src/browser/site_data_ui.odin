package browser

import "core:fmt"
import "core:slice"
import "core:strings"
import "wb:base"
import "wb:cookies"
import "wb:httpcache"
import "wb:i18n"
import "wb:page"
import "wb:url"

// What the browser keeps for each site, and how it goes: about:sites lists the sites (a host: every origin, port and
// partition of it) with what each holds by type (localStorage, sessionStorage, IndexedDB, cookies, HTTP cache), their sizes,
// and removes one type or everything for one site or for all of them. "Clear site data" in the page-info box does the same
// for the page's host (`clear_site`). The storage is the page package's (storage_sites.odin); the cookies and the HTTP cache
// are the profile's.

SITES_URL :: "about:sites"

is_sites_address :: proc(a: string) -> bool { return a == SITES_URL || strings.has_prefix(a, SITES_URL + "?") }

@(private = "file")
registrable_or_host :: proc(host: string) -> string {
	if d, ok := url.registrable_domain(host); ok { return d }
	return host
}

Clear_Kind :: enum u8 { Local, Session, Indexed_Db, Cookies, Cache }
Clear_Kinds :: bit_set[Clear_Kind]
CLEAR_ALL :: Clear_Kinds{.Local, .Session, .Indexed_Db, .Cookies, .Cache}

// Removes what `kinds` names for every storage key, cookie and cache entry of `host` ("*": all of them). Returns a
// description for the status bar.
clear_site :: proc(app: ^App, host: string, kinds: Clear_Kinds) -> string {
	storage_kinds: page.Site_Kinds
	if .Local in kinds { storage_kinds += {.Local} }
	if .Session in kinds { storage_kinds += {.Session} }
	if .Indexed_Db in kinds { storage_kinds += {.Indexed_Db} }
	if storage_kinds != {} {
		for s in page.storage_sites(&app.storage) {
			// (a site's partitions of other sites' data, stored while it was the top level, go with it)
			if host == "*" || page.storage_key_host(s.key) == host || page.storage_key_top_host(s.key) == registrable_or_host(host) {
				page.storage_clear_site(&app.storage, s.key, storage_kinds)
			}
		}
	}
	cookie_count, entries := 0, 0
	if .Cookies in kinds {
		if host == "*" {
			cookie_count = cookies.count(&app.profile.jar)
			cookies.clear_all(&app.profile.jar)
		} else {
			cookie_count = cookies.delete_for_host(&app.profile.jar, host)
			cookie_count += cookies.delete_partitions_of(&app.profile.jar, registrable_or_host(host))
		}
	}
	if .Cache in kinds && app.profile.cache != nil {
		if host == "*" {
			entries = httpcache.summary(app.profile.cache).entries
			httpcache.clear_all(app.profile.cache)
		} else {
			entries = httpcache.delete_for_host(app.profile.cache, host)
		}
	}
	app.frames_requested = max(app.frames_requested, 2)
	names := make([dynamic]string, context.temp_allocator)
	if .Local in kinds { append(&names, i18n.tr("local storage")) }
	if .Session in kinds { append(&names, i18n.tr("session storage")) }
	if .Indexed_Db in kinds { append(&names, i18n.tr("IndexedDB")) }
	if .Cookies in kinds { append(&names, fmt.tprintf(i18n.tr("%d cookie(s)"), cookie_count)) }
	if .Cache in kinds { append(&names, fmt.tprintf(i18n.tr("%d cached response(s)"), entries)) }
	return fmt.tprintf(i18n.tr("cleared for %s: %s"), host, strings.join(names[:], ", ", context.temp_allocator))
}

@(private = "file")
SITES_STYLE :: `
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
  .clear:hover { background-color: #561c16; }
  td .clear { display: inline-block; padding: 0 10px; line-height: 22px; font-size: 13px; vertical-align: middle; }
  td .clear:hover { text-decoration: none; }
  input[type=search]:hover { border-color: #3f4b6e; }
  tr:hover td { background-color: #121826; }
  table { width: 100%; border-collapse: collapse; }
  th { text-align: left; color: #8993ad; font-weight: normal; border-bottom: 1px solid #232b40; padding: 4px 6px; }
  td { border-bottom: 1px solid #1a2133; padding: 4px 6px; vertical-align: top; white-space: nowrap; }
  td.site { color: #f1f4fb; white-space: normal; word-break: break-all; }
  td.num { text-align: right; }
  td a, th a { color: #ffb84d; text-decoration: none; }
  td a:hover { text-decoration: underline; }
  td .none { color: #4b5570; }
  td .rm { color: #f2a59c; font-size: 12px; margin-left: 6px; }
  .note { color: #8993ad; margin: 14px 0 0; }
  code { color: #c9d1e3; background-color: #1b2132; padding: 0 3px; border-radius: 3px; }
`

@(private = "file")
Site_Row :: struct {
	host:                   string,
	local, session, idb:    i64,
	local_keys, session_keys: int,
	cookies:                int,
	cache:                  i64,
}

@(private = "file")
sd_size :: proc(n: i64) -> string {
	switch {
	case n >= 1 << 30: return fmt.tprintf("%.1f GiB", f64(n) / f64(1 << 30))
	case n >= 1 << 20: return fmt.tprintf("%.1f MiB", f64(n) / f64(1 << 20))
	case n >= 1 << 10: return fmt.tprintf("%.1f KiB", f64(n) / f64(1 << 10))
	}
	return fmt.tprintf("%d B", n)
}

@(private = "file")
sd_param :: proc(query, name: string) -> string {
	sp := url.params_make(context.temp_allocator)
	url.params_parse(&sp, query)
	v, _ := url.params_get(sp, name)
	return v
}

@(private = "file")
sd_enc :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(s) {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~' || c == '*' {
			strings.write_byte(&b, c)
		} else {
			strings.write_byte(&b, '%'); strings.write_byte(&b, HEX[c >> 4]); strings.write_byte(&b, HEX[c & 15])
		}
	}
	return strings.to_string(b)
}

@(private = "file")
sd_cell :: proc(sb: ^strings.Builder, bytes: i64, detail: string, host, type: string) {
	if bytes <= 0 && detail == "" {
		strings.write_string(sb, "<td class=\"num\"><span class=\"none\">-</span></td>")
		return
	}
	fmt.sbprintf(sb, "<td class=\"num\">%s%s<a class=\"rm\" href=\"%s?clear=%s&amp;type=%s\" title=\"%s\">&times;</a></td>",
		bytes > 0 ? sd_size(bytes) : "", detail != "" ? fmt.tprintf(" <span class=\"none\">%s</span>", escape_html(detail)) : "",
		SITES_URL, sd_enc(host), type, escape_html(i18n.tr("Clear")))
}

// The rows: one per host, from the storage, the cookies and the HTTP cache.
@(private = "file")
sites_rows :: proc(app: ^App) -> []Site_Row {
	rows := make(map[string]^Site_Row, context.temp_allocator)
	row :: proc(rows: ^map[string]^Site_Row, host: string) -> ^Site_Row {
		if r, ok := rows[host]; ok { return r }
		r := new(Site_Row, context.temp_allocator)
		r.host = strings.clone(host, context.temp_allocator)
		rows[r.host] = r
		return r
	}
	for s in page.storage_sites(&app.storage) {
		r := row(&rows, page.storage_key_host(s.key))
		r.local += s.local_bytes
		r.local_keys += max(s.local_keys, 0)
		r.session += s.session_bytes
		r.session_keys += s.session_keys
		r.idb += s.idb_bytes
	}
	for c in cookies.all(&app.profile.jar) {
		h := strings.trim_prefix(c.domain, ".")
		if h == "" { continue }
		_ = row(&rows, h)
	}
	for _, r in rows { r.cookies = cookies.count_for_host(&app.profile.jar, r.host) }
	if c := app.profile.cache; c != nil {
		for h, n in httpcache.bytes_by_host(c) { row(&rows, h).cache += n }
	}
	list := make([dynamic]Site_Row, 0, len(rows), context.temp_allocator)
	for _, r in rows {
		if r.local == 0 && r.session == 0 && r.idb == 0 && r.cookies == 0 && r.cache == 0 && r.session_keys == 0 { continue }
		append(&list, r^)
	}
	slice.sort_by(list[:], proc(a, b: Site_Row) -> bool { return a.host < b.host })
	return list[:]
}

sites_page_html :: proc(app: ^App, filter, notice: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>%s</title>\n<style>", escape_html(i18n.tr("Site data")))
	strings.write_string(&sb, SITES_STYLE)
	fmt.sbprintf(&sb, "</style>\n</head>\n<body>\n<div class=\"main\">\n<h1>%s</h1>\n", escape_html(i18n.tr("Site data")))
	fmt.sbprintf(&sb, "<p class=\"intro\">%s %s</p>\n", escape_html(i18n.tr("What the browser keeps for each site: local and session storage, IndexedDB, cookies and cached responses. A site is a host, with every port, scheme and partition of it.")),
		notice != "" ? fmt.tprintf("<b>%s</b>", escape_html(notice)) : "")
	rows := sites_rows(app)
	local, session, idb, cache: i64
	n_cookies := 0
	for r in rows { local += r.local; session += r.session; idb += r.idb; cache += r.cache; n_cookies += r.cookies }
	stat :: proc(sb: ^strings.Builder, value, label: string) {
		fmt.sbprintf(sb, "<div class=\"stat\"><b>%s</b><span>%s</span></div>", escape_html(value), escape_html(label))
	}
	strings.write_string(&sb, "<div class=\"stats\">")
	stat(&sb, fmt.tprintf("%d", len(rows)), i18n.tr("sites"))
	stat(&sb, sd_size(local), i18n.tr("local storage"))
	stat(&sb, sd_size(session), i18n.tr("session storage"))
	stat(&sb, sd_size(idb), i18n.tr("IndexedDB"))
	stat(&sb, fmt.tprintf("%d", n_cookies), i18n.tr("cookies"))
	stat(&sb, sd_size(cache), i18n.tr("HTTP cache"))
	strings.write_string(&sb, "</div>\n")
	fmt.sbprintf(&sb, "<form action=\"%s\" method=\"get\"><input type=\"search\" name=\"q\" value=\"%s\" placeholder=\"%s\"><button type=\"submit\">%s</button><a class=\"clear\" href=\"%s?clear=*&amp;type=all\">%s</a></form>\n",
		SITES_URL, escape_html(filter), escape_html(i18n.tr("Filter by site")), escape_html(i18n.tr("Filter")), SITES_URL, escape_html(i18n.tr("Clear everything")))
	fmt.sbprintf(&sb, "<table><tr><th>%s</th><th>%s</th><th>%s</th><th>%s</th><th>%s</th><th>%s</th><th></th></tr>\n",
		escape_html(i18n.tr("Site")), escape_html(i18n.tr("Local storage")), escape_html(i18n.tr("Session storage")), escape_html(i18n.tr("IndexedDB")),
		escape_html(i18n.tr("Cookies")), escape_html(i18n.tr("HTTP cache")))
	needle := strings.to_lower(filter, context.temp_allocator)
	shown := 0
	for r in rows {
		if needle != "" && !strings.contains(r.host, needle) { continue }
		shown += 1
		fmt.sbprintf(&sb, "<tr><td class=\"site\">%s</td>", escape_html(r.host))
		sd_cell(&sb, r.local, r.local_keys > 0 ? fmt.tprintf("%d keys", r.local_keys) : "", r.host, "local")
		sd_cell(&sb, r.session, r.session_keys > 0 ? fmt.tprintf("%d keys", r.session_keys) : "", r.host, "session")
		sd_cell(&sb, r.idb, "", r.host, "idb")
		sd_cell(&sb, 0, r.cookies > 0 ? fmt.tprintf("%d", r.cookies) : "", r.host, "cookies")
		sd_cell(&sb, r.cache, "", r.host, "cache")
		fmt.sbprintf(&sb, "<td><a class=\"clear\" href=\"%s?clear=%s&amp;type=all\">%s</a></td></tr>\n", SITES_URL, sd_enc(r.host), escape_html(i18n.tr("Clear all")))
	}
	strings.write_string(&sb, "</table>\n")
	if shown == 0 { fmt.sbprintf(&sb, "<p class=\"note\">%s</p>\n", escape_html(i18n.tr("No site matches."))) }
	fmt.sbprintf(&sb, "<p class=\"note\">%s <code>indexeddb.*</code>, <code>storage.*</code>, <code>network.cache.*</code>.</p>\n", escape_html(i18n.tr("Limits and durability are preferences in about:config:")))
	strings.write_string(&sb, "</div>\n</body>\n</html>\n")
	return strings.to_string(sb)
}

// about:sites, about:sites?q=filter; about:sites?clear=<host or *>&type=<all|local|session|idb|cookies|cache> removes data when
// the person or about:sites itself asks (`acts`, from nav_judge: a web page linking there, or a navigation replayed, does nothing).
show_sites_page :: proc(app: ^App, t: ^Tab, target: string, acts: bool) {
	query := ""
	if i := strings.index_byte(target, '?'); i >= 0 { query = target[i + 1:] }
	filter := sd_param(query, "q")
	notice := ""
	if clear_host := sd_param(query, "clear"); clear_host != "" && acts {
		kinds: Clear_Kinds
		switch sd_param(query, "type") {
		case "local": kinds = {.Local}
		case "session": kinds = {.Session}
		case "idb": kinds = {.Indexed_Db}
		case "cookies": kinds = {.Cookies}
		case "cache": kinds = {.Cache}
		case "all": kinds = CLEAR_ALL
		}
		if kinds != {} { notice = clear_site(app, clear_host, kinds) }
		// the entry is about:sites again: going back here must not clear it once more
		page.session_replace(&t.session, SITES_URL)
		sync_history(t)
	}
	base.scope_close(t.nav)
	t.nav = base.scope_make("navigation", t.scope)
	t.load, t.kind = nil, .Web
	shown := SITES_URL if notice != "" else target
	t.page = page.page_create(&app.loop, &app.loader, &app.page_settings, t.nav, shown, console_sink, t)
	attach_page(app, t, t.page)
	layout_reset(&t.layout)
	t.scroll_target = base.NIL_HANDLE
	t.scroll = 0
	for l in t.console { delete(l) }
	clear(&t.console)
	page.load_html(t.page, transmute([]byte)sites_page_html(app, filter, notice))
	delete(t.url); t.url = strings.clone(shown)
	delete(t.title); t.title = strings.clone(i18n.tr("Site data"))
	set_status(t, notice != "" ? notice : SITES_URL)
	address_set(app, t, shown)
}
