// End-to-end test of the content blocker against the test server's page with simulated ads (examples/site/blocker):
// a blocked script, image, frame and fetch, an element hidden before the first style computation, a scriptlet
// (set-constant), the exception for a site, the per-site switch, a dynamic rule, the counters and the log. Run from the
// repository root with the test server up (tools\test_all.ps1 does it):
//   blockertest.exe
package blockertest

import _ "wb:tools/crashtrace"   // a crash prints its symbolized stack

import "core:fmt"
import "core:os"
import "core:strings"
import "wb:base"
import "wb:blocker"
import "wb:config"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:net"
import "wb:page"
import "wb:tools/headless"
import "wb:tools/testenv"

failures, passes: int

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if ok { passes += 1; fmt.printf("PASS %s\n", what) } else { fmt.printf("FAIL %s  (line %d)\n", what, loc.line); failures += 1 }
}

MY_FILTERS :: "||localhost^$third-party\n##.ad-banner\n127.0.0.1##+js(set-constant, adblockDetected, false)\n127.0.0.1##+js(replace-node-text, script, AAA-MARKER, BBB-MARKER)\n127.0.0.1##+js(remove-node-text, script, CCC-MARKER)\n127.0.0.1##+js(remove-attr, data-ad, #ra1)\n127.0.0.1##+js(remove-attr, data-late, #ra2, stay)\n127.0.0.1##+js(remove-class, adclass, #rc1)\n127.0.0.1##+js(set-attr, #sa, data-set, yes)\n127.0.0.1##+js(rmnt, p, /^SECRET/)\n127.0.0.1##+js(rpnt, p, /(\\d+) EUR/g, $1 USD)\n127.0.0.1##+js(rpnt, script, FLAG_ON, FLAG_OFF)\n127.0.0.1##+js(href-sanitizer, #lnk)\n127.0.0.1##+js(trusted-click-element, #clickme)\n127.0.0.1##+js(set-cookie, wb_test, 1)\n127.0.0.1##+js(set-local-storage-item, wb_ls, true)\n127.0.0.1##+js(json-prune-fetch-response, ads, , data.json)\n127.0.0.1##+js(json-prune-xhr-response, ads, , data.json)\n127.0.0.1##+js(trusted-replace-fetch-response, /\"price\":\\s*100/, '\"price\":101', url:data.json)\n127.0.0.1##+js(set-constant, ytInitialPlayerResponse.adPlacements, undefined)\n127.0.0.1##+js(set-constant, hookConst, 42)\n127.0.0.1##+js(set-constant, hookObj.flag, yes)\n127.0.0.1##+js(aopr, hookAopr)\n127.0.0.1##+js(aopw, hookAopw)\n127.0.0.1##+js(nostif, BLOCKME)\n127.0.0.1##+js(aeld, wbcustom, DEFUSEME)\n127.0.0.1##+js(jp, adsX)\n127.0.0.1##+js(nofetch, hookblock)\n127.0.0.1##+js(noxhr, hookblock)\n127.0.0.1##+js(noeval)\n127.0.0.1##+js(nowoif, popup.example)\n*data2.json$replace=/\"w\":\"a+\"/\"w\":\"b\"/\n*replacedoc.html$replace=/RAWTEXT/REPLACED/\n"

by_id :: proc(d: ^dom.Document, id: string) -> base.Handle {
	for h in dom.ids_all(d, id) { return h }
	return base.NIL_HANDLE
}

log_text :: proc(d: ^headless.Doc) -> string {
	p := d.page
	if p == nil { return "" }
	h := by_id(p.doc, "log")
	if h == base.NIL_HANDLE { return "" }
	return dom.text_content(p.doc, h)
}

load :: proc(e: ^headless.Env, url: string) -> ^headless.Doc {
	d := headless.open(e, url)
	headless.pump(d, 20000, headless.loaded)
	headless.pump(d, 1200)
	return d
}

main :: proc() {
	context = testenv.context_of_process()
	dir := "build/blockertest_profile"
	os.remove_all(dir)
	os.make_directory_all(strings.concatenate({dir, "/blocker"}, context.temp_allocator))
	conf := strings.concatenate({"version\t1\n[lists]\n[sites]\n[rules]\n[my-filters]\n", MY_FILTERS}, context.temp_allocator)
	_ = os.write_entire_file(strings.concatenate({dir, "/blocker/blocker.conf"}, context.temp_allocator), conf)

	e: headless.Env
	if !headless.init(&e) { fmt.println("FAIL headless init"); os.exit(1) }
	prefs := config.prefs_make()
	blocker.register_prefs(&prefs)
	config.set_from_string(&prefs, "blocker.update.enabled", "false", .User)
	b: blocker.Blocker
	blocker.start(&b, &e.loop, &e.client, &e.loader, &prefs, dir)
	blocker.tab_register(&b, 1, e.process)
	headless.pump(&headless.Doc{env = &e}, 300)   // the index of the user's filters is compiled on a thread

	url := testenv.url("http://127.0.0.1:8765/site/blocker/ads.html")
	d := load(&e, url)
	text := log_text(d)
	ts := blocker.tab_state(&b, 1)
	check(d.failed == "", "the page loads")
	check(ts != nil && ts.blocked >= 3, fmt.tprintf("script, frame and fetch are blocked (%d blocked)", ts != nil ? ts.blocked : -1))
	check(strings.contains(text, "ad.js ran: false"), "the blocked script did not run")
	check(strings.contains(text, "adblockDetected: false"), "the scriptlet set-constant ran before the page's script")
	check(strings.contains(text, "tracker fetch: failed"), "the blocked fetch failed")
	// (the scriptlets that rewrite the text of <script> elements: found among the elements of the tag, once each; the page reads the text 400 ms in)
	headless.pump(d, 700)
	text = log_text(d)
	check(strings.contains(text, "node text: var secretMarker = \"BBB-MARKER\";"), "replace-node-text rewrote the text of a script")
	check(strings.contains(text, "removed node text length: 0"), "remove-node-text emptied the text of a script")
	check(strings.contains(text, "first party fetch: ok"), "the first-party fetch went through")
	if h := by_id(d.page.doc, "ad1"); h != base.NIL_HANDLE {
		headless.pump(d, 300)
		check(page.computed_property(d.page, h, "display") == "none", "the .ad-banner element is hidden by the user stylesheet")
	} else { check(false, "ad1 exists") }
	if h := by_id(d.page.doc, "intro"); h != base.NIL_HANDLE { check(page.computed_property(d.page, h, "display") != "none", "other elements are not hidden") }
	// the per-tab matrix knows the third-party host
	row := ts != nil ? ts.hosts["localhost"] : nil
	check(row != nil && row.third_party, "the matrix has the third-party host")
	headless.close(d)

	// the scriptlets that change the document run natively: no realm is involved
	{
		dom_url := testenv.url("http://127.0.0.1:8765/site/blocker/domops.html")
		dd := load(&e, dom_url)
		headless.pump(dd, 800)
		dp := dd.page
		attr :: proc(p: ^page.Page, id, name: string) -> (string, bool) { return dom.get_attribute(p.doc, by_id(p.doc, id), name) }
		_, has := attr(dp, "ra1", "data-ad")
		check(!has, "remove-attr: the attribute is gone")
		_, has = attr(dp, "ra2", "data-late")
		check(!has, "remove-attr with stay: an element that arrives later is cleaned too")
		cls, _ := attr(dp, "rc1", "class")
		check(cls == "rc keep", fmt.tprintf("remove-class leaves the other classes (%q)", cls))
		v, _ := attr(dp, "sa", "data-set")
		check(v == "yes", "set-attr sets the attribute")
		check(dom.text_content(dp.doc, by_id(dp.doc, "sec")) == "", "remove-node-text empties the node")
		check(dom.text_content(dp.doc, by_id(dp.doc, "rep")) == "price: 100 USD, 200 USD", "replace-node-text with a regex and $1")
		href, _ := attr(dp, "lnk", "href")
		check(href == "https://example.org/page", fmt.tprintf("href-sanitizer takes the link's target (%q)", href))
		log := log_text(dd)
		check(strings.contains(log, "flag=FLAG_OFF;"), fmt.tprintf("replace-node-text rewrites an inline script before it runs (%q)", log))
		check(strings.contains(log, "dyn=FLAG_OFF;"), "...and one inserted later")
		check(strings.contains(log, "clicked;"), "trusted-click-element clicks the button")
		check(strings.contains(page.document_cookies(dp), "wb_test=1"), "set-cookie writes the cookie")
		// (the storage writes need the browser's storage manager: the headless environment has none)
		headless.close(dd)
	}
	// responses rewritten by the loader: JSON of fetch and XHR, the JSON literal in the page's own markup
	{
		rw := load(&e, testenv.url("http://127.0.0.1:8765/site/blocker/rewrite.html"))
		headless.pump(rw, 1500)
		lg := log_text(rw)
		check(strings.contains(lg, "src:false;"), fmt.tprintf("the literal in the page's markup lost adPlacements before the parser read it (%q)", lg))
		check(strings.contains(lg, "fetch:keep,price;price=101;"), fmt.tprintf("json-prune-fetch-response and the text replacement (%q)", lg))
		check(strings.contains(lg, "xhr:keep,price;"), "json-prune-xhr-response")
		check(strings.contains(lg, "data2:b;"), fmt.tprintf("a `$replace filter rewrites a fetch answer (%q)", lg))
		headless.close(rw)
		rd := load(&e, testenv.url("http://127.0.0.1:8765/site/blocker/replacedoc.html"))
		check(dom.text_content(rd.page.doc, by_id(rd.page.doc, "t")) == "REPLACED", "a `$replace filter rewrites a document before it is parsed")
		headless.close(rd)
	}
	// the scriptlets that change what an API does: native hooks of the engine (then, as a check of the fallback, as JavaScript)
	for mode in ([]string{"true", "false"}) {
		config.set_from_string(&prefs, "blocker.hooks.native", mode, .User)
		hd := load(&e, testenv.url("http://127.0.0.1:8765/site/blocker/hooks.html"))
		headless.pump(hd, 600)
		hl := log_text(hd)
		what := mode == "true" ? "native hook" : "JavaScript fallback"
		check(strings.contains(hl, "const:42;obj:yes;aopr:threw;aopw:threw;aeld2:ran;json:keepX;eval:undefined;open:null;"), fmt.tprintf("%s: set-constant, abort-on-property-read / write, listener defuser, JSON.parse prune, noeval, window.open (%q)", what, hl))
		check(strings.contains(hl, "timeout2:ran;") && !strings.contains(hl, "timeout:ran;") && !strings.contains(hl, "aeld:ran"), fmt.tprintf("%s: a timer is defused by its function text and the others run (%q)", what, hl))
		check(strings.contains(hl, "fetch:{};") && strings.contains(hl, "xhr:200:0;"), fmt.tprintf("%s: fetch and XHR answered without the network (%q)", what, hl))
		headless.close(hd)
	}
	config.set_from_string(&prefs, "blocker.hooks.native", "true", .User)
	// the site is on the whitelist: nothing is blocked or hidden
	blocker.site_toggle(&b, "127.0.0.1", .Off, true)
	d = load(&e, url)
	text = log_text(d)
	check(strings.contains(text, "ad.js ran: true"), "whitelisted site: the script runs")
	check(blocker.tab_state(&b, 1).blocked == 0, "whitelisted site: nothing counted as blocked")
	if h := by_id(d.page.doc, "ad1"); h != base.NIL_HANDLE { check(page.computed_property(d.page, h, "display") != "none", "whitelisted site: the element is shown") }
	headless.close(d)
	blocker.site_toggle(&b, "127.0.0.1", .Off, false)

	// a dynamic rule allows the third-party host: the filter's block is overridden
	blocker.dyn_set(&b.dyn, "*", "localhost", .All, .Allow)
	b.conf_ver += 1
	d = load(&e, url)
	text = log_text(d)
	check(strings.contains(text, "ad.js ran: true"), "dynamic allow rule: the host's script goes through")
	headless.close(d)
	blocker.dyn_clear(&b.dyn)
	b.conf_ver += 1

	// a dynamic block rule stops what the lists leave alone
	blocker.dyn_set(&b.dyn, "*", "127.0.0.1", .Xhr, .Block)
	b.conf_ver += 1
	d = load(&e, url)
	check(!strings.contains(log_text(d), "first party fetch: ok"), "dynamic block rule: the first-party fetch is stopped")
	headless.close(d)
	blocker.dyn_clear(&b.dyn)

	// the journal records while it is armed
	b.journal.armed = true
	d = load(&e, url)
	check(blocker.journal_len(&b.journal) > 4, "the journal recorded the requests")
	blocked_entries := 0
	for i in 0 ..< blocker.journal_len(&b.journal) { if blocker.journal_get(&b.journal, i).outcome == .Blocked { blocked_entries += 1 } }
	check(blocked_entries >= 3, "the journal marks the blocked ones")
	headless.close(d)

	// switched off: no filtering
	config.set_from_string(&prefs, "blocker.enabled", "false", .User)
	d = load(&e, url)
	check(strings.contains(log_text(d), "ad.js ran: true"), "blocker.enabled off: the script runs")
	headless.close(d)

	blocker.shutdown(&b, &e.loader)
	config.prefs_destroy(&prefs)
	headless.destroy(&e)
	os.remove_all(dir)
	host.blocking_settle(&e.blocking)
	page.process_shutdown()
	fetch.loader_destroy(&e.loader)
	host.blocking_destroy(&e.blocking)
	net.client_destroy(&e.client)
	fetch.profile_destroy(&e.profile)
	host.loop_destroy(&e.loop)
	page.settings_destroy(&e.settings)
	failures += testenv.mem_check("blockertest")
	fmt.printf("\n%d checks passed, %d failure(s)\n", passes, failures)
	os.exit(failures > 0 ? 1 : 0)
}

_ :: fetch
