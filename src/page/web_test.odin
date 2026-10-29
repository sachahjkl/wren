package page

import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:url"
import "wb:tools/testenv"

@(test)
meta_refresh_content :: proc(t: ^testing.T) {
	d, u, ok := meta_refresh_parse("0; url=/docs/button")
	testing.expect(t, ok && d == 0 && u == "/docs/button", "delay, url=")
	d, u, ok = meta_refresh_parse(" 5 ; URL = 'next.html' ")
	testing.expect(t, ok && d == 5 && u == "next.html", "quotes, case, spaces")
	d, u, ok = meta_refresh_parse("1.5,/x")
	testing.expect(t, ok && d == 1.5 && u == "/x", "comma, no url=")
	_, _, ok = meta_refresh_parse("30")
	testing.expect(t, !ok, "a delay alone reloads: not handled")
	_, _, ok = meta_refresh_parse("soon; url=/x")
	testing.expect(t, !ok, "no delay")
}

@(test)
timer_nesting_clamp :: proc(t: ^testing.T) {
	st := settings_default()
	defer settings_destroy(&st)
	s := st.web
	testing.expect_value(t, timer_effective_delay(0, 0, s), 0)
	testing.expect_value(t, timer_effective_delay(0, 5, s), 0)    // up to the threshold: as asked
	testing.expect_value(t, timer_effective_delay(0, 6, s), 4)    // deeper: at least 4 ms
	testing.expect_value(t, timer_effective_delay(2, 6, s), 4)
	testing.expect_value(t, timer_effective_delay(10, 6, s), 10)
	testing.expect_value(t, timer_effective_delay(-5, 0, s), 0)
	nan := f64(0)
	nan = nan / nan
	testing.expect_value(t, timer_effective_delay(nan, 0, s), 0)
	testing.expect_value(t, background_wait_ms(1500, 1000), 500)
	testing.expect_value(t, background_wait_ms(2000, 1000), 0)
}

@(private = "file")
decode_all :: proc(label: string, chunks: [][]byte, fatal := false, ignore_bom := false) -> (string, bool) {
	d, ok := decoder_make(label, fatal, ignore_bom)
	if !ok { return "<unknown label>", false }
	defer decoder_free(d)
	b := strings.builder_make(context.temp_allocator)
	for c, i in chunks {
		text, dok := decoder_decode(d, c, i + 1 < len(chunks), context.temp_allocator)
		if !dok { return "<fatal>", false }
		strings.write_string(&b, text)
	}
	return strings.to_string(b), true
}

@(test)
streaming_decoder :: proc(t: ^testing.T) {
	euro := []byte{0xE2, 0x82, 0xAC}   // U+20AC
	s, _ := decode_all("utf-8", {euro[:1], euro[1:2], euro[2:]})
	testing.expect_value(t, s, "€")
	s, _ = decode_all("UTF8", {{'a', 0xE2, 0x82}, {0xAC, 'b'}})
	testing.expect_value(t, s, "a€b")
	s, _ = decode_all("utf-8", {{'a', 0xE2, 0x82}})                 // flushed while incomplete: one U+FFFD
	testing.expect_value(t, s, "a\uFFFD")
	_, ok := decode_all("utf-8", {{'a', 0xE2, 0x82}}, fatal = true)
	testing.expect(t, !ok, "fatal mode rejects a truncated sequence")
	_, ok = decode_all("utf-8", {{0xFF}}, fatal = true)
	testing.expect(t, !ok, "fatal mode rejects an invalid byte")
	s, _ = decode_all("latin1", {{0x80, 'x', 0xE9}})                 // windows-1252
	testing.expect_value(t, s, "€xé")
	s, _ = decode_all("utf-8", {{0xEF, 0xBB}, {0xBF, 'h', 'i'}})       // a BOM split across chunks is still dropped
	testing.expect_value(t, s, "hi")
	s, _ = decode_all("utf-8", {{0xEF, 0xBB, 0xBF, 'h'}}, ignore_bom = true)
	testing.expect_value(t, s, "\uFEFFh")
	s, _ = decode_all("utf-16le", {{'A', 0, 0x3D}, {0xD8, 0x00, 0xDE}})   // U+1F600 as a surrogate pair cut in three
	testing.expect_value(t, s, "A😀")
	s, _ = decode_all("shift_jis", {{0x82}, {0xA0}})
	testing.expect_value(t, s, "あ")
	_, ok = decode_all("no-such-encoding", {{}})
	testing.expect(t, !ok, "unknown label")
	_, ok = decode_all("iso-2022-kr", {{}})
	testing.expect(t, !ok, "the replacement encoding is refused (RangeError)")

	d, _ := decoder_make("utf-8")
	defer decoder_free(d)
	testing.expect_value(t, decoder_name(d, context.temp_allocator), "utf-8")
	testing.expect_value(t, utf8_scrub("a\xffb", context.temp_allocator), "a\uFFFDb")
	testing.expect_value(t, utf16_length("a€😀"), 4)
}

@(test)
session_history_model :: proc(t: ^testing.T) {
	sh: Session_History
	defer session_destroy(&sh)
	session_push(&sh, "https://a/1", 1)
	session_push(&sh, "https://a/1", 1)   // same URL: no new entry
	session_push(&sh, "https://a/2", 1, "s", true, dedupe = false)
	session_push(&sh, "https://a/3", 1)
	testing.expect_value(t, session_length(&sh), 3)
	e, ok := session_go(&sh, -1)
	testing.expect(t, ok && e.url == "https://a/2" && e.has_state && e.state == "s")
	_, ok = session_go(&sh, -5)
	testing.expect(t, !ok && sh.index == 1)
	session_push(&sh, "https://a/x", 2)   // the forward entry becomes another branch: the web no longer sees it
	testing.expect_value(t, session_length(&sh), 3)
	testing.expect_value(t, session_current(&sh).url, "https://a/x")
	session_replace(&sh, "https://a/y", "st", true)
	testing.expect(t, session_current(&sh).url == "https://a/y" && session_current(&sh).state == "st")
	for i in 0 ..< 10 { session_push(&sh, strings.concatenate({"https://b/", string([]u8{u8('0' + i)})}, context.temp_allocator), 3, max_entries = 4) }
	testing.expect_value(t, session_length(&sh), 4)
	testing.expect_value(t, sh.index, 3)
}

@(test)
url_rewrite_rules :: proc(t: ^testing.T) {
	doc, _ := url.parse("https://a.example/dir/page?x#f", nil, context.temp_allocator)
	ok := proc(doc: url.URL, s: string) -> bool {
		u, _ := url.parse(s, nil, context.temp_allocator)
		return can_rewrite_url(doc, u)
	}
	testing.expect(t, ok(doc, "https://a.example/other"))
	testing.expect(t, !ok(doc, "https://b.example/other"))
	testing.expect(t, !ok(doc, "http://a.example/dir/page"))
	testing.expect(t, !ok(doc, "https://a.example:444/dir/page"))
	fdoc, _ := url.parse("file:///C:/x/a.html", nil, context.temp_allocator)
	testing.expect(t, ok(fdoc, "file:///C:/x/a.html?q#z"))
	testing.expect(t, !ok(fdoc, "file:///C:/x/b.html"))
}

@(private = "file")
Fixture :: struct {
	loop:     host.Loop,
	settings: Settings,
	process:  ^base.Scope,
}

@(private = "file")
fixture_init :: proc(f: ^Fixture) {
	host.loop_init(&f.loop)
	f.settings = settings_default()
	f.settings.web.storage_quota = 100
	f.process = base.scope_make("process")
}

@(private = "file")
fixture_destroy :: proc(f: ^Fixture) {
	base.scope_close(f.process)
	for _ in 0 ..< 3 { host.run_ready(&f.loop) }
	settings_destroy(&f.settings)
	host.loop_destroy(&f.loop)
}

@(test)
storage_quota_order_events_persistence :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	dir := "build/test_storage_profile"
	testenv.remove_tree(dir)
	defer testenv.remove_tree(dir)

	m := new(Storage_Manager)
	defer free(m)
	storage_manager_init(m, &f.loop, nil, dir)
	a := page_create(&f.loop, nil, &f.settings, f.process, "https://site.example/a")
	b := page_create(&f.loop, nil, &f.settings, f.process, "https://site.example/b")
	c := page_create(&f.loop, nil, &f.settings, f.process, "https://other.example/")
	o := page_create(&f.loop, nil, &f.settings, f.process, "file:///C:/x.html")
	set_embedder(a, {storage = m, tab_key = "tab1"})
	set_embedder(b, {storage = m, tab_key = "tab2"})
	set_embedder(c, {storage = m, tab_key = "tab1"})
	set_embedder(o, {storage = m, tab_key = "tab1"})

	testing.expect_value(t, storage_set_item(o, .Local, "k", "v"), WEB_ERR_SECURITY)
	testing.expect_value(t, storage_set_item(a, .Local, "k1", "one"), 0)
	testing.expect_value(t, storage_set_item(a, .Local, "k2", "two"), 0)
	testing.expect_value(t, storage_set_item(a, .Local, "k1", "uno"), 0)   // replacing keeps the position
	k, found, _ := storage_key(b, .Local, 0)
	testing.expect(t, found && k == "k1", "key(0) is the first key set, seen from another page of the origin")
	v, vf, _ := storage_get_item(b, .Local, "k1")
	testing.expect(t, vf && v == "uno")
	_, found, _ = storage_get_item(c, .Local, "k1")
	testing.expect(t, !found, "another origin sees nothing")

	// quota: 100 code units of keys + values; "€" and "😀" count 1 and 2
	big := strings.repeat("x", 88, context.temp_allocator)   // 10 used + 3 + 88 > 100
	testing.expect_value(t, storage_set_item(a, .Local, "big", big), WEB_ERR_QUOTA)
	_, found, _ = storage_get_item(a, .Local, "big")
	testing.expect(t, !found, "a refused write changes nothing")
	testing.expect_value(t, storage_set_item(a, .Local, "e", "😀😀"), 0)

	// sessionStorage: per tab
	testing.expect_value(t, storage_set_item(a, .Session, "s", "1"), 0)
	n, _ := storage_length(b, .Session)
	testing.expect_value(t, n, 0)

	// events: only for the other pages of the origin (b; c is another origin); sessionStorage only within the tab
	before := storage_events_delivered
	for _ in 0 ..< 3 { host.run_ready(&f.loop) }
	testing.expect_value(t, storage_events_delivered - before, 4)   // 4 local changes seen by b, none by c or a

	testing.expect_value(t, storage_remove_item(a, .Local, "k2"), 0)
	testing.expect_value(t, storage_remove_item(a, .Local, "nope"), 0)
	for _ in 0 ..< 3 { host.run_ready(&f.loop) }
	testing.expect_value(t, storage_events_delivered - before, 5)   // removing a missing key fires nothing

	// persistence: a new manager on the same directory ("restart") sees localStorage, not sessionStorage
	page_close(a); page_close(b); page_close(c); page_close(o)
	storage_manager_destroy(m)
	storage_manager_init(m, &f.loop, nil, dir)
	defer storage_manager_destroy(m)
	a2 := page_create(&f.loop, nil, &f.settings, f.process, "https://site.example/again")
	set_embedder(a2, {storage = m, tab_key = "tab1"})
	v, vf, _ = storage_get_item(a2, .Local, "k1")
	testing.expect(t, vf && v == "uno", "localStorage survives a restart")
	v, vf, _ = storage_get_item(a2, .Local, "e")
	testing.expect(t, vf && v == "😀😀")
	n, _ = storage_length(a2, .Local)
	testing.expect_value(t, n, 2)
	n, _ = storage_length(a2, .Session)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, storage_clear(a2, .Local), 0)
	page_close(a2)
	message_transfer(t)
}

// Called by the storage test: tests creating pages share the page registry and must not run in parallel.
@(private = "file")
message_transfer :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	src := page_create(&f.loop, nil, &f.settings, f.process, "https://a.example/")
	dst := page_create(&f.loop, nil, &f.settings, f.process, "https://b.example/")
	b1 := buffer_create(src, transmute([]byte)string("hello"), 0)
	b2 := buffer_create(src, transmute([]byte)string("!!"), 0)
	_, err := message_capture(src, "x", {b1, b1})
	testing.expect_value(t, err, dom.Error.Invalid_Argument)
	m, err2 := message_capture(src, "text", {b1, b2})
	testing.expect_value(t, err2, dom.Error.None)
	testing.expect_value(t, len(buffer_bytes(src, b1)), 0)   // detached
	testing.expect_value(t, src.held, 0)
	msg, ok := message_deliver(dst, &m, 0, context.temp_allocator)
	testing.expect(t, ok && msg.text == "text" && len(msg.buffers) == 2)
	testing.expect_value(t, string(buffer_bytes(dst, msg.buffers[0])), "hello")
	testing.expect_value(t, dst.held, 7)
	page_close(src)
	page_close(dst)
}
