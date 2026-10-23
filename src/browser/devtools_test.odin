package browser

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "wb:base"
import "toolkit:ui"
import "wb:fetch"

@(test)
console_lines_carry_their_level :: proc(t: ^testing.T) {
	l, text := con_split("error: boom")
	testing.expect_value(t, l, Con_Level.Error)
	testing.expect_value(t, text, "boom")
	l, text = con_split("warn: careful")
	testing.expect_value(t, l, Con_Level.Warn)
	testing.expect_value(t, text, "careful")
	l, text = con_split("> 1 + 1")
	testing.expect_value(t, l, Con_Level.Log)
	testing.expect_value(t, text, "> 1 + 1")
}

@(test)
console_line_numbers_do_not_move_when_old_lines_go :: proc(t: ^testing.T) {
	tab := Tab{console_added = 10}
	append(&tab.console, "a", "b", "c")   // lines 7, 8, 9
	defer delete(tab.console)
	testing.expect_value(t, con_abs(&tab, 0), 7)
	testing.expect_value(t, con_abs(&tab, 2), 9)
}

@(test)
labels_never_hold_an_id_marker_or_a_line_break :: proc(t: ^testing.T) {
	testing.expect(t, !contains(dev_line("a###b"), "###"), "### is broken")
	testing.expect_value(t, dev_line("a\nb"), "a \u00b6 b")
	testing.expect_value(t, dev_line("a\r\nb\tc"), "a \u00b6 b  c")
	testing.expect_value(t, dev_line("abcdef", 3), "abc\u2026")
}

@(private = "file")
contains :: proc(s, sub: string) -> bool {
	for i in 0 ..= len(s) - len(sub) { if s[i:i + len(sub)] == sub { return true } }
	return false
}

// The loader's observer turns requests into the rows of the tab whose scope they run in; a new navigation starts the
// list over; an answer and its end update the row.
@(test)
requests_are_logged_in_the_tab_they_run_in :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	tab := new(Tab)
	tab.scope = base.scope_make("tab")
	append(&app.tabs, tab)
	defer { delete(app.tabs); net_log_destroy(&tab.net); base.scope_close(tab.scope); free(tab); net_destroy_owner() }

	nav1 := base.scope_make("navigation", tab.scope)
	page1 := base.scope_make("page", nav1)
	net_observe(app, &fetch.Observed{kind = .Started, id = 1, scope = nav1, method = "GET", url = "https://x.test/", destination = .Document})
	net_observe(app, &fetch.Observed{kind = .Started, id = 2, scope = page1, method = "POST", url = "https://x.test/api"})
	net_observe(app, &fetch.Observed{kind = .Response, id = 1, url = "https://x.test/index", status = 200, mime = "text/html", headers = "Content-Length: 1234\r\nServer: t", status_text = "OK"})
	net_observe(app, &fetch.Observed{kind = .Done, id = 1, bytes = 1234})
	net_observe(app, &fetch.Observed{kind = .Failed, id = 2, error = .Transport, detail = "connection reset"})
	testing.expect_value(t, len(tab.net.entries), 2)
	e := tab.net.entries[0]
	testing.expect_value(t, e.url, "https://x.test/index")   // the URL after redirects
	testing.expect_value(t, e.status, 200)
	testing.expect_value(t, e.status_text, "OK")
	testing.expect_value(t, e.bytes, 1234)
	testing.expect_value(t, e.transfer, 1234)
	testing.expect(t, e.ms >= 0, "it ended")
	testing.expect_value(t, e.type, Net_Type.Doc)
	testing.expect(t, tab.net.entries[1].failed && tab.net.entries[1].error == "connection reset", "the failure is kept")
	testing.expect_value(t, tab.net.bytes, i64(1234))

	// a request of no tab is not logged
	other := base.scope_make("elsewhere")
	net_observe(app, &fetch.Observed{kind = .Started, id = 3, scope = other, method = "GET", url = "https://y.test/"})
	testing.expect_value(t, len(tab.net.entries), 2)
	base.scope_close(other)

	// a new navigation: the list starts over
	base.scope_close(nav1)
	nav2 := base.scope_make("navigation", tab.scope)
	net_observe(app, &fetch.Observed{kind = .Started, id = 4, scope = nav2, method = "GET", url = "https://x.test/next"})
	testing.expect_value(t, len(tab.net.entries), 1)
	base.scope_close(nav2)
}

////////////////////////////////
// The filter field

@(private = "file")
filter_of :: proc(text: string, regex := false, cased := false, invert := false) -> Dt_Filter {
	f: Dt_Filter
	ui.field_set(&f.field, text)
	f.use_re, f.cased, f.invert = regex, cased, invert
	dt_filter_prepare(&f)
	return f
}

@(test)
filter_matches_words_and_excludes_with_a_minus :: proc(t: ^testing.T) {
	f := filter_of("cat -dog")
	defer dt_filter_destroy(&f)
	testing.expect(t, dt_filter_match(&f, "A Cat sat"), "a word, any case")
	testing.expect(t, !dt_filter_match(&f, "cat and dog"), "-dog excludes")
	testing.expect(t, !dt_filter_match(&f, "a bird"), "all the words are needed")
	g := filter_of("Cat", cased = true)
	defer dt_filter_destroy(&g)
	testing.expect(t, !dt_filter_match(&g, "a cat"), "case matters when asked")
	testing.expect(t, dt_filter_match(&g, "a Cat"), "case matters when asked")
	h := filter_of("cat", invert = true)
	defer dt_filter_destroy(&h)
	testing.expect(t, !dt_filter_match(&h, "cat"), "inverted")
	testing.expect(t, dt_filter_match(&h, "dog"), "inverted")
	e := filter_of("")
	defer dt_filter_destroy(&e)
	testing.expect(t, dt_filter_match(&e, "anything"), "empty matches all")
}

@(test)
filter_regular_expressions :: proc(t: ^testing.T) {
	f := filter_of("^a.c$", regex = true)
	defer dt_filter_destroy(&f)
	testing.expect(t, dt_filter_match(&f, "abc"), "matches")
	testing.expect(t, dt_filter_match(&f, "ABC"), "case-insensitive by default")
	testing.expect(t, !dt_filter_match(&f, "abcd"), "anchored")
	bad := filter_of("(", regex = true)
	defer dt_filter_destroy(&bad)
	testing.expect(t, dt_filter_match(&bad, "whatever"), "an invalid pattern shows everything")
	testing.expect(t, bad.re_bad, "and is marked")
}

@(test)
contains_fold_is_ascii_case_insensitive :: proc(t: ^testing.T) {
	testing.expect(t, dt_contains_fold("Hello World", "lo wo"), "found")
	testing.expect(t, !dt_contains_fold("Hello", "world"), "not found")
	testing.expect(t, dt_contains_fold("x", ""), "empty needle")
	testing.expect(t, !dt_contains_fold("ab", "abc"), "longer needle")
}

////////////////////////////////
// The Console's helpers

@(test)
group_depth_and_source_of_a_line :: proc(t: ^testing.T) {
	d, rest := con_depth("    deeper")
	testing.expect_value(t, d, 2)
	testing.expect_value(t, rest, "deeper")
	d, rest = con_depth("flat")
	testing.expect_value(t, d, 0)
	src := con_source("Error: x\n    at f (http://h/a/b.js:12:34)\n    at http://h/c.js:5:1")
	testing.expect_value(t, src.file, "b.js")
	testing.expect_value(t, src.line, 12)
	testing.expect_value(t, src.col, 34)
	src = con_parse_location("http://h/p/q.js?v=1:7")
	testing.expect_value(t, src.file, "q.js")
	testing.expect_value(t, src.line, 7)
	src = con_parse_location("nothing")
	testing.expect_value(t, src.line, 0)
}

@(test)
payload_level_reads_the_start :: proc(t: ^testing.T) {
	testing.expect_value(t, payload_level(`{"l":"warn","a":[]}`), "warn")
	testing.expect_value(t, payload_level(`{"a":[]}`), "")
}

@(test)
payload_runs_substitute_and_preview :: proc(t: ^testing.T) {
	root, ok := con_payload_parse(`{"l":"log","a":[{"t":"s","v":"%s is %d"},{"t":"s","v":"Ada"},{"t":"n","v":"36"}]}`)
	testing.expect(t, ok, "parses")
	runs := con_payload_runs(root, 200)
	b := strings.builder_make(context.temp_allocator)
	for r in runs { strings.write_string(&b, r.text) }
	testing.expect_value(t, strings.to_string(b), "Ada is 36")
	root, ok = con_payload_parse(`{"l":"log","a":[{"t":"o","c":"Object","m":2,"p":[["a",{"t":"n","v":"1"}],["b",{"t":"o","c":"Array","m":3}]]}]}`)
	testing.expect(t, ok, "parses")
	runs = con_payload_runs(root, 200)
	b = strings.builder_make(context.temp_allocator)
	for r in runs { strings.write_string(&b, r.text) }
	testing.expect_value(t, strings.to_string(b), "{a: 1, b: (3) […]}")
}

////////////////////////////////
// The Network's helpers

@(test)
request_names_types_and_hosts :: proc(t: ^testing.T) {
	testing.expect_value(t, net_name_of("https://x.test/a/b/c.js?v=2"), "c.js?v=2")
	testing.expect_value(t, net_name_of("https://x.test/"), "x.test")
	testing.expect_value(t, net_name_of("https://x.test/dir/"), "dir")
	testing.expect_value(t, net_name_of("data:text/plain,hi"), "data:")
	testing.expect_value(t, net_host_of("https://u@x.test:8080/p?q"), "x.test:8080")
	testing.expect_value(t, net_path_of("https://x.test/p/q?z=1#h"), "/p/q?z=1#h")
	e := Net_Entry{dest = .Script, mime = "application/javascript"}
	testing.expect_value(t, net_type_of(&e), Net_Type.JS)
	e = Net_Entry{dest = .Empty, mime = "application/json"}
	testing.expect_value(t, net_type_of(&e), Net_Type.XHR)
	e = Net_Entry{dest = .Empty, mime = "image/png"}
	testing.expect_value(t, net_type_of(&e), Net_Type.Img)
	e = Net_Entry{dest = .Script, mime = "application/wasm"}
	testing.expect_value(t, net_type_of(&e), Net_Type.Wasm)
}

@(test)
glob_patterns_of_blocked_requests :: proc(t: ^testing.T) {
	testing.expect(t, net_glob("https://a.test/x", "https://a.test/x"), "exact")
	testing.expect(t, !net_glob("https://a.test/x", "https://a.test/y"), "exact")
	testing.expect(t, net_glob("*://a.test/*", "https://a.test/p/q"), "any scheme and path")
	testing.expect(t, !net_glob("*://a.test/*", "https://b.test/p"), "other host")
	testing.expect(t, net_glob("*.png", "http://x/y/z.png"), "suffix")
	testing.expect(t, !net_glob("*.png", "http://x/y/z.png?v=1"), "suffix is the end")
}

@(test)
url_decoding :: proc(t: ^testing.T) {
	testing.expect_value(t, url_decode("a%20b+c%2Fd"), "a b c/d")
	testing.expect_value(t, url_decode("100%"), "100%")
	testing.expect_value(t, url_decode("plain"), "plain")
	q := net_query_pairs("http://x/?a=1&b=x%20y&c")
	testing.expect_value(t, len(q), 3)
	testing.expect_value(t, q[1][1], "x y")
}

@(test)
rows_sort_stably_by_a_column :: proc(t: ^testing.T) {
	entries := []Net_Entry{{url = "http://x/b", status = 200, bytes = 5}, {url = "http://x/a", status = 404, bytes = 50}, {url = "http://x/c", status = 200, bytes = 5}}
	rows := []int{0, 1, 2}
	net_sort(rows, entries, .Name, false)
	testing.expect_value(t, rows[0], 1)
	testing.expect_value(t, rows[2], 2)
	net_sort(rows, entries, .Status, true)
	testing.expect_value(t, rows[0], 1)
	rows = {0, 1, 2}
	net_sort(rows, entries, .Size, false)
	testing.expect_value(t, rows[0], 0)   // ties keep the order of arrival
	testing.expect_value(t, rows[1], 2)
	testing.expect_value(t, rows[2], 1)
}

@(test)
copy_as_cURL_fetch_and_PowerShell :: proc(t: ^testing.T) {
	e := Net_Entry{method = "POST", url = "https://x.test/api?a=1", req_headers = "Host: x.test\r\nContent-Type: application/json\r\nX-It: it's", req_body = transmute([]byte)string(`{"a":1}`)}
	curl := net_curl(&e)
	testing.expect(t, strings.has_prefix(curl, "curl 'https://x.test/api?a=1'"), curl)
	testing.expect(t, strings.contains(curl, "-H 'Content-Type: application/json'"), curl)
	testing.expect(t, strings.contains(curl, "'X-It: it'\\''s'"), "a quote inside is closed, escaped and opened again")
	testing.expect(t, !strings.contains(curl, "Host:"), "Host is the URL's")
	testing.expect(t, strings.contains(curl, `--data-raw '{"a":1}'`), curl)
	testing.expect(t, !strings.contains(curl, " -X POST"), "a body implies POST")
	f := net_fetch_code(&e)
	testing.expect(t, strings.has_prefix(f, `fetch("https://x.test/api?a=1", {`), f)
	testing.expect(t, strings.contains(f, `"body": "{\"a\":1}"`), f)
	p := net_powershell(&e)
	testing.expect(t, strings.contains(p, "Invoke-WebRequest -UseBasicParsing -Uri 'https://x.test/api?a=1'"), p)
	testing.expect(t, strings.contains(p, "'X-It' = 'it''s'"), p)
	g := Net_Entry{method = "GET", url = "http://x/"}
	testing.expect(t, !strings.contains(net_curl(&g), "-X"), "GET needs no method")
}

@(test)
sizes_and_times_are_written_for_a_person :: proc(t: ^testing.T) {
	testing.expect_value(t, dt_size_text(999), "999 B")
	testing.expect_value(t, dt_size_text(1500), "1.5 kB")
	testing.expect_value(t, dt_size_text(2_500_000), "2.50 MB")
	testing.expect_value(t, dt_ms_text(0.5), "0.50 ms")
	testing.expect_value(t, dt_ms_text(12.34), "12 ms")
	testing.expect_value(t, dt_ms_text(1500), "1.50 s")
	testing.expect_value(t, content_length_of("Server: x\r\nContent-Length: 42\r\n"), 42)
}

////////////////////////////////
// Syntax coloring

@(test)
syntax_runs_cover_the_whole_line :: proc(t: ^testing.T) {
	for lang in Syn_Lang {
		line := `{"a": [1, true, null, "x\"y"], b: 'z' } // <tag attr="v"> .c { color: #fff; }`
		runs := syn_runs(line, lang)
		b := strings.builder_make(context.temp_allocator)
		for r in runs { strings.write_string(&b, r.text) }
		testing.expect_value(t, strings.to_string(b), line)
	}
	runs := syn_runs(`{"k": 12}`, .JSON)
	testing.expect(t, len(runs) >= 4, "keys, numbers and punctuation are runs of their own")
	testing.expect_value(t, syn_lang_of("application/json; charset=utf-8", ""), Syn_Lang.JSON)
	testing.expect_value(t, syn_lang_of("", "http://x/a.css?v=1"), Syn_Lang.CSS)
	testing.expect_value(t, syn_lang_of("image/svg+xml", ""), Syn_Lang.HTML)
}
@(test)
har_export_is_json :: proc(t: ^testing.T) {
	tab := Tab{}
	defer net_log_destroy(&tab.net)
	append(&tab.net.entries, Net_Entry{method = strings.clone("GET"), url = strings.clone("http://x/a?q=\"1\""), status = 200, status_text = strings.clone("OK"), res_headers = strings.clone("A: b\r\nC: d"), req_headers = strings.clone("H: v"), mime = strings.clone("text/html"), bytes = 5, transfer = 7})
	har := net_har(&tab)
	v, err := json.parse(transmute([]byte)har, allocator = context.temp_allocator)
	testing.expect(t, err == nil, har)
	root, _ := v.(json.Object)
	log, _ := root["log"].(json.Object)
	entries, _ := log["entries"].(json.Array)
	testing.expect_value(t, len(entries), 1)
}
