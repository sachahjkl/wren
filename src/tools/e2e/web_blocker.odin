#+build windows
#+private file
// The content blocker against the test server's page with simulated ads (examples/site/blocker): a blocked script, frame and fetch,
// an element hidden before the first style computation, the scriptlets (on the document, on an API), responses rewritten, the shape of a
// YouTube watch page, the exception for a site, the per-site switch, dynamic rules, the counters and the journal. The pages write what they
// saw in their #log; each test waits for the line it is about.
package e2e_scenarios

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:blocker"
import "wb:config"
import "wb:cookies"
import "wb:dom"
import "wb:fetch"
import "wb:http"
import "wb:httpcache"
import "wb:page"
import "wb:tools/testenv"

PROFILE :: "build/blockertest_profile"
TAB :: 1
ADS :: "http://127.0.0.1:8765/site/blocker/ads.html"
WATCH :: "http://127.0.0.1:8765/site/blocker/ytwatch.html"
LOAD_LIMIT :: 20.0
BLOCKED_ON_THE_ADS_PAGE :: 3       // script, frame, fetch (no image is asked for without a layout)
MIN_JOURNAL_ENTRIES :: 4
CONF_HEAD :: "version\t1\n[lists]\n[sites]\n[rules]\n[my-filters]\n"
MY_FILTERS :: "||localhost^$third-party\n##.ad-banner\n127.0.0.1##+js(set-constant, adblockDetected, false)\n127.0.0.1##+js(replace-node-text, script, AAA-MARKER, BBB-MARKER)\n127.0.0.1##+js(remove-node-text, script, CCC-MARKER)\n127.0.0.1##+js(remove-attr, data-ad, #ra1)\n127.0.0.1##+js(remove-attr, data-late, #ra2, stay)\n127.0.0.1##+js(remove-class, adclass, #rc1)\n127.0.0.1##+js(set-attr, #sa, data-set, yes)\n127.0.0.1##+js(rmnt, p, /^SECRET/)\n127.0.0.1##+js(rpnt, p, /(\\d+) EUR/g, $1 USD)\n127.0.0.1##+js(rpnt, script, FLAG_ON, FLAG_OFF)\n127.0.0.1##+js(href-sanitizer, #lnk)\n127.0.0.1##+js(trusted-click-element, #clickme)\n127.0.0.1##+js(set-cookie, wb_test, 1)\n127.0.0.1##+js(set-local-storage-item, wb_ls, true)\n127.0.0.1##+js(json-prune-fetch-response, ads, , data.json)\n127.0.0.1##+js(json-prune-xhr-response, ads, , data.json)\n127.0.0.1##+js(trusted-replace-fetch-response, /\"price\":\\s*100/, '\"price\":101', url:data.json)\n127.0.0.1##+js(set-constant, ytInitialPlayerResponse.adPlacements, undefined)\n127.0.0.1##+js(set-constant, hookConst, 42)\n127.0.0.1##+js(set-constant, hookObj.flag, yes)\n127.0.0.1##+js(aopr, hookAopr)\n127.0.0.1##+js(aopw, hookAopw)\n127.0.0.1##+js(nostif, BLOCKME)\n127.0.0.1##+js(aeld, wbcustom, DEFUSEME)\n127.0.0.1##+js(jp, adsX)\n127.0.0.1##+js(nofetch, hookblock)\n127.0.0.1##+js(noxhr, hookblock)\n127.0.0.1##+js(noeval)\n127.0.0.1##+js(nowoif, popup.example)\n127.0.0.1##+js(nostif, NEVERMATCH-bench)\n127.0.0.1##+js(jp, neverKey)\n127.0.0.1##+js(set-constant, benchConst, 7)\n127.0.0.1##+js(set-constant, ytInitialPlayerResponse.adSlots, undefined)\n127.0.0.1##+js(set-constant, ytInitialPlayerResponse.playerAds, undefined)\n127.0.0.1##+js(trusted-replace-xhr-response, /\"adPlacements.*?([A-Z]\"\\}|\"\\}{2\\,4})\\}\\]\\,/, , /playlist\\?list=|\\/player(?:\\?.+)?$|watch\\?[tv]=/)\n127.0.0.1##+js(trusted-replace-xhr-response, /\"adPlacements.*?(\"adSlots\"|\"adBreakHeartbeatParams\")/gms, $1, /\\/player(?:\\?.+)?$/)\n127.0.0.1##+js(trusted-rpfr, '\"adPlacements\"', '\"no_ads\"', player?)\n||127.0.0.1/site/blocker/youtubei/v1/player?$xhr,1p,replace=/\"adPlacements\"/\"no_ads\"/\n*data2.json$replace=/\"w\":\"a+\"/\"w\":\"b\"/\n*replacedoc.html$replace=/RAWTEXT/REPLACED/\n"

// A blocker started on a new profile, with a tab, as the browser has it. There is no compiled index yet: `hold` is the loader's state just after the start.
Setup :: struct {
	t:     ^testing.T,
	b:     blocker.Blocker,
	prefs: config.Prefs,
	tab:   ^base.Scope,
	held_at_start: bool,
}

setup :: proc(t: ^testing.T, w: ^Setup) {
	w.t = t
	serve(t)
	_ = os.remove_all(PROFILE)
	_ = os.make_directory_all(PROFILE + "/blocker")
	_ = os.write_entire_file(PROFILE + "/blocker/blocker.conf", transmute([]byte)string(CONF_HEAD + MY_FILTERS))
	cache_settings := httpcache.settings_default()
	profile.cache = httpcache.create(&loop, cache_settings, "")
	httpcache.settings_destroy(&cache_settings)
	w.prefs = config.prefs_make()
	blocker.register_prefs(&w.prefs)
	config.set_from_string(&w.prefs, "blocker.update.enabled", "false", .User)
	// (the blocker and its prefs stay with the loader and the blocker package until shut)
	blocker.start((^blocker.Blocker)(rawptr(&w.b)), &loop, &client, &loader, (^config.Prefs)(rawptr(&w.prefs)), PROFILE)
	w.tab = base.scope_make("tab", process)
	blocker.tab_register(&w.b, TAB, w.tab)
	w.held_at_start = loader.hold
}

// The index the lists compile to is in force.
index_ready :: proc(w: ^Setup) -> bool {
	return wait_until(w.t, "the first index", w.t, proc(_: ^testing.T) -> bool { return !loader.hold }, LOAD_LIMIT)
}

shut :: proc(w: ^Setup) {
	blocker.shutdown(&w.b, &loader)
	config.prefs_destroy(&w.prefs)
	base.scope_close(w.tab)
	httpcache.destroy(profile.cache)
	profile.cache = nil
	cookies.clear_all(&profile.jar)
	drain()
	_ = os.remove_all(PROFILE)
}

// A document navigated to as the browser does it (fetch, destination document), its page under the tab.
Doc :: struct {
	w:       ^Setup,
	scope:   ^base.Scope,
	page:    ^page.Page,
	charset: string,
	failed:  string,
	parsed:  bool,
}

open_doc :: proc(w: ^Setup, address: string) -> ^Doc {
	d := new(Doc, context.temp_allocator)
	d.w = w
	d.scope = base.scope_make("navigation", w.tab)
	base.on_close(d.scope, proc(data: rawptr) { (^Doc)(data).page = nil }, d)
	fetch.start(&loader, {
		request = {url = testenv.url(address), mode = .Navigate, credentials = .Include, redirect = .Follow, destination = .Document},
		on_event = document_event, user = d, scope = d.scope, collect = true,
	})
	return d
}

document_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	d := (^Doc)(user)
	keep := base.process_context().temp_allocator
	#partial switch ev.kind {
	case .Response:
		r := ev.response
		if r.has_mime { if cs, ok := http.mime_param(r.mime, "charset"); ok { d.charset = strings.clone(cs, keep) } }
		d.page = page.page_create(&loop, &loader, &settings, d.scope, r.url, proc(user: rawptr, level: page.Log_Level, message: string) {}, d)
		page.set_embedder(d.page, {user = d, tab_key = d.scope.name})
	case .Done:
		if d.page == nil { d.failed = "no response"; return }
		page.parse_document(d.page, ev.data, d.charset, proc(p: ^page.Page, user: rawptr, pd: ^page.Parsed_Document) {
			d := (^Doc)(user)
			if !pd.decoded { d.failed = "the document could not be decoded"; return }
			page.adopt_document(p, pd)
			if !p.render.adopted { page.render_begin(p) }
			d.parsed = true
			page.scripts_start(p)
		}, d, "")
	case .Failed:
		d.failed = strings.clone(ev.detail != "" ? ev.detail : "the request failed", keep)
	}
}

// Failed, or parsed and every script ran.
is_loaded :: proc(d: ^Doc) -> bool {
	if d.failed != "" { return true }
	if d.page == nil || !d.parsed { return false }
	s := d.page.scripts
	return s == nil || s.ready_state == .Complete
}

close_doc :: proc(d: ^Doc) { base.scope_close(d.scope) }

by_id :: proc(d: ^dom.Document, id: string) -> base.Handle {
	for h in dom.ids_all(d, id) { return h }
	return base.NIL_HANDLE
}

log_text :: proc(d: ^Doc) -> string {
	if d.page == nil { return "" }
	h := by_id(d.page.doc, "log")
	return h == base.NIL_HANDLE ? "" : dom.text_content(d.page.doc, h)
}

load :: proc(w: ^Setup, address: string, loc := #caller_location) -> ^Doc {
	d := open_doc(w, address)
	wait_until(w.t, address, d, is_loaded, LOAD_LIMIT, loc)
	return d
}

Waiting_Log :: struct { d: ^Doc, text: string }

// The page's log has this text.
wait_log :: proc(d: ^Doc, text: string, loc := #caller_location) -> bool {
	ok := wait_until(d.w.t, fmt.tprintf("%q in the log", text), Waiting_Log{d, text}, proc(w: Waiting_Log) -> bool {
		return strings.contains(log_text(w.d), w.text)
	}, LOAD_LIMIT, loc)
	if !ok { testing.expectf(d.w.t, false, "the log so far: %q", log_text(d), loc = loc) }
	return ok
}

// ads.html: its page is loaded and both its fetches have ended.
ads_settled :: proc(d: ^Doc, loc := #caller_location) {
	wait_log(d, "tracker fetch:", loc)
	wait_log(d, "first party fetch:", loc)
}

@(test)
blocker_a_page_asked_for_at_start_up_waits_for_the_index :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	w: Setup
	setup(t, &w)
	defer shut(&w)
	testing.expect(t, w.held_at_start, "the loader holds the requests while the first index is compiled")
	d := open_doc(&w, WATCH)
	defer close_doc(d)
	// no compiled index in the profile yet: the requests wait (the loader holds them) until the real one is installed, so that the very
	// first page is filtered by the lists too
	wait_log(d, "page:")
	testing.expectf(t, strings.contains(log_text(d), "page:none:OK:"), "a page asked for at start-up is filtered once the index is there (%q)", log_text(d))
	testing.expect(t, !loader.hold, "the hold on requests ended with the compile job")
}

@(test)
blocker_filters_a_page :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	w: Setup
	setup(t, &w)
	defer shut(&w)
	index_ready(&w)
	d := load(&w, ADS)
	defer close_doc(d)
	ads_settled(d)
	wait_log(d, "removed node text length:")
	text := log_text(d)
	ts := blocker.tab_state(&w.b, TAB)
	testing.expect(t, d.failed == "", "the page loads")
	testing.expectf(t, ts != nil && ts.blocked == BLOCKED_ON_THE_ADS_PAGE, "script, frame and fetch are blocked (%d blocked)", ts != nil ? ts.blocked : -1)
	testing.expect(t, strings.contains(text, "ad.js ran: false"), "the blocked script did not run")
	testing.expect(t, strings.contains(text, "adblockDetected: false"), "the scriptlet set-constant ran before the page's script")
	testing.expect(t, strings.contains(text, "tracker fetch: failed"), "the blocked fetch failed")
	testing.expect(t, strings.contains(text, "node text: var secretMarker = \"BBB-MARKER\";"), "replace-node-text rewrote the text of a script")
	testing.expect(t, strings.contains(text, "removed node text length: 0"), "remove-node-text emptied the text of a script")
	testing.expect(t, strings.contains(text, "first party fetch: ok"), "the first-party fetch went through")
	ad := by_id(d.page.doc, "ad1")
	testing.expect(t, ad != base.NIL_HANDLE, "ad1 exists")
	testing.expect(t, page.computed_property(d.page, ad, "display") == "none", "the .ad-banner element is hidden by the user stylesheet")
	intro := by_id(d.page.doc, "intro")
	testing.expect(t, intro != base.NIL_HANDLE && page.computed_property(d.page, intro, "display") != "none", "other elements are not hidden")
	// the per-tab matrix knows the third-party host
	row := ts != nil ? ts.hosts["localhost"] : nil
	testing.expect(t, row != nil && row.third_party, "the matrix has the third-party host")
}

attr :: proc(p: ^page.Page, id, name: string) -> (string, bool) { return dom.get_attribute(p.doc, by_id(p.doc, id), name) }

// The scriptlets that change the document run natively: no realm is involved.
@(test)
blocker_scriptlets_change_the_document :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	w: Setup
	setup(t, &w)
	defer shut(&w)
	index_ready(&w)
	d := load(&w, "http://127.0.0.1:8765/site/blocker/domops.html")
	defer close_doc(d)
	wait_log(d, "dyn=")        // the nodes that arrive after the parse
	wait_log(d, "clicked;")
	p := d.page
	_, has := attr(p, "ra1", "data-ad")
	testing.expect(t, !has, "remove-attr: the attribute is gone")
	_, has = attr(p, "ra2", "data-late")
	testing.expect(t, by_id(p.doc, "ra2") != base.NIL_HANDLE && !has, "remove-attr with stay: an element that arrives later is cleaned too")
	cls, _ := attr(p, "rc1", "class")
	testing.expectf(t, cls == "rc keep", "remove-class leaves the other classes (%q)", cls)
	v, _ := attr(p, "sa", "data-set")
	testing.expect(t, v == "yes", "set-attr sets the attribute")
	testing.expect(t, dom.text_content(p.doc, by_id(p.doc, "sec")) == "", "remove-node-text empties the node")
	testing.expect(t, dom.text_content(p.doc, by_id(p.doc, "rep")) == "price: 100 USD, 200 USD", "replace-node-text with a regex and $1")
	href, _ := attr(p, "lnk", "href")
	testing.expectf(t, href == "https://example.org/page", "href-sanitizer takes the link's target (%q)", href)
	log := log_text(d)
	testing.expectf(t, strings.contains(log, "flag=FLAG_OFF;"), "replace-node-text rewrites an inline script before it runs (%q)", log)
	testing.expect(t, strings.contains(log, "dyn=FLAG_OFF;"), "...and one inserted later")
	testing.expect(t, strings.contains(log, "clicked;"), "trusted-click-element clicks the button")
	testing.expect(t, strings.contains(page.document_cookies(p), "wb_test=1"), "set-cookie writes the cookie")
}

// Responses rewritten by the loader: JSON of fetch and XHR, the JSON literal in the page's own markup.
@(test)
blocker_rewrites_responses :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	w: Setup
	setup(t, &w)
	defer shut(&w)
	index_ready(&w)
	rw := load(&w, "http://127.0.0.1:8765/site/blocker/rewrite.html")
	defer close_doc(rw)
	wait_log(rw, "xhr:")
	wait_log(rw, "data2:")
	log := log_text(rw)
	testing.expectf(t, strings.contains(log, "src:false;"), "the literal in the page's markup lost adPlacements before the parser read it (%q)", log)
	testing.expectf(t, strings.contains(log, "fetch:keep,price;price=101;"), "json-prune-fetch-response and the text replacement (%q)", log)
	testing.expect(t, strings.contains(log, "xhr:keep,price;"), "json-prune-xhr-response")
	testing.expectf(t, strings.contains(log, "data2:b;"), "a `$replace filter rewrites a fetch answer (%q)", log)
	rd := load(&w, "http://127.0.0.1:8765/site/blocker/replacedoc.html")
	defer close_doc(rd)
	testing.expect(t, dom.text_content(rd.page.doc, by_id(rd.page.doc, "t")) == "REPLACED", "a `$replace filter rewrites a document before it is parsed")
}

// The shape of a YouTube watch page: the player data in an inline literal, then the answers of /youtubei/v1/player to XHR and fetch,
// with the rules of the lists (set-constant on the variable, trusted-replace-*-response, trusted-rpfr, $xhr,1p,replace=).
@(test)
blocker_a_youtube_watch_page :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	w: Setup
	setup(t, &w)
	defer shut(&w)
	index_ready(&w)
	yt := load(&w, WATCH)
	defer close_doc(yt)
	wait_log(yt, "fetch:")
	log := log_text(yt)
	testing.expectf(t, strings.contains(log, "page:none:OK:") && strings.contains(log, ":34:"), "the player data of the page has no ad data and keeps the rest (%q)", log)
	testing.expectf(t, !strings.contains(log, "playerAds") && strings.contains(log, "adBreakHeartbeatParams"), "a property set to undefined is not listed among the keys (%q)", log)
	testing.expect(t, strings.contains(log, "boot:none;"), "the variable read again through window[...] has none either")
	testing.expectf(t, strings.contains(log, "xhr:none:OK:wbtest00001:clean;"), "the XHR answer of /youtubei/v1/player has no ad data (%q)", log)
	testing.expectf(t, strings.contains(log, "fetch:none:OK:1:clean;"), "the fetch answer of /youtubei/v1/player has no ad data (%q)", log)
}

api_hooks :: proc(t: ^testing.T, native: string, what: string, loc := #caller_location) {
	w: Setup
	setup(t, &w)
	defer shut(&w)
	index_ready(&w)
	config.set_from_string(&w.prefs, "blocker.hooks.native", native, .User)
	d := load(&w, "http://127.0.0.1:8765/site/blocker/hooks.html")
	defer close_doc(d)
	// (of two timers of the same delay, the second: the defused one would have run)
	wait_log(d, "timeout2:ran;", loc)
	wait_log(d, "fetch:", loc)
	wait_log(d, "xhr:", loc)
	log := log_text(d)
	testing.expectf(t, strings.contains(log, "const:42;obj:yes;aopr:threw;aopw:threw;aeld2:ran;json:keepX;eval:undefined;open:null;"), "%s: set-constant, abort-on-property-read / write, listener defuser, JSON.parse prune, noeval, window.open (%q)", what, log, loc = loc)
	testing.expectf(t, strings.contains(log, "timeout2:ran;") && !strings.contains(log, "timeout:ran;") && !strings.contains(log, "aeld:ran"), "%s: a timer is defused by its function text and the others run (%q)", what, log, loc = loc)
	testing.expectf(t, strings.contains(log, "fetch:{};") && strings.contains(log, "xhr:200:0;"), "%s: fetch and XHR answered without the network (%q)", what, log, loc = loc)
}

// The scriptlets that change what an API does: native hooks of the engine ...
@(test)
blocker_native_hooks_change_an_api :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	api_hooks(t, "true", "native hook")
}

// ... then, as a check of the fallback, as JavaScript.
@(test)
blocker_javascript_scriptlets_change_an_api :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	api_hooks(t, "false", "JavaScript fallback")
}

// The site is on the whitelist: nothing is blocked or hidden.
@(test)
blocker_a_whitelisted_site :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	w: Setup
	setup(t, &w)
	defer shut(&w)
	index_ready(&w)
	blocker.site_toggle(&w.b, "127.0.0.1", .Off, true)
	d := load(&w, ADS)
	defer close_doc(d)
	ads_settled(d)
	testing.expect(t, strings.contains(log_text(d), "ad.js ran: true"), "whitelisted site: the script runs")
	testing.expect(t, blocker.tab_state(&w.b, TAB).blocked == 0, "whitelisted site: nothing counted as blocked")
	ad := by_id(d.page.doc, "ad1")
	testing.expect(t, ad != base.NIL_HANDLE && page.computed_property(d.page, ad, "display") != "none", "whitelisted site: the element is shown")
}

// A dynamic rule allows the third-party host: the filter's block is overridden.
@(test)
blocker_a_dynamic_allow_rule :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	w: Setup
	setup(t, &w)
	defer shut(&w)
	index_ready(&w)
	blocker.dyn_set(&w.b.dyn, "*", "localhost", .All, .Allow)
	w.b.conf_ver += 1
	d := load(&w, ADS)
	defer close_doc(d)
	testing.expect(t, strings.contains(log_text(d), "ad.js ran: true"), "dynamic allow rule: the host's script goes through")
}

// A dynamic block rule stops what the lists leave alone.
@(test)
blocker_a_dynamic_block_rule :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	w: Setup
	setup(t, &w)
	defer shut(&w)
	index_ready(&w)
	blocker.dyn_set(&w.b.dyn, "*", "127.0.0.1", .Xhr, .Block)
	w.b.conf_ver += 1
	d := load(&w, ADS)
	defer close_doc(d)
	wait_log(d, "first party fetch:")
	testing.expect(t, strings.contains(log_text(d), "first party fetch: failed"), "dynamic block rule: the first-party fetch is stopped")
}

// The journal records while it is armed.
@(test)
blocker_the_journal :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	w: Setup
	setup(t, &w)
	defer shut(&w)
	index_ready(&w)
	w.b.journal.armed = true
	d := load(&w, ADS)
	defer close_doc(d)
	ads_settled(d)
	testing.expect(t, blocker.journal_len(&w.b.journal) > MIN_JOURNAL_ENTRIES, "the journal recorded the requests")
	blocked_entries := 0
	for i in 0 ..< blocker.journal_len(&w.b.journal) { if blocker.journal_get(&w.b.journal, i).outcome == .Blocked { blocked_entries += 1 } }
	testing.expect_value(t, blocked_entries, BLOCKED_ON_THE_ADS_PAGE)
}

// Switched off: no filtering.
@(test)
blocker_switched_off :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	w: Setup
	setup(t, &w)
	defer shut(&w)
	index_ready(&w)
	config.set_from_string(&w.prefs, "blocker.enabled", "false", .User)
	d := load(&w, ADS)
	defer close_doc(d)
	testing.expect(t, strings.contains(log_text(d), "ad.js ran: true"), "blocker.enabled off: the script runs")
}
