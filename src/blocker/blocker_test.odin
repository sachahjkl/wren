package blocker

import "core:strings"
import "core:testing"
import "wb:adblock"
import "wb:base"
import "wb:config"
import "wb:fetch"

@(private = "file")
make_blocker :: proc(my_filters: string) -> (b: ^Blocker, prefs: ^config.Prefs) {
	prefs = new(config.Prefs)
	prefs^ = config.prefs_make()
	register_prefs(prefs)
	b = new(Blocker)
	b.prefs = prefs
	b.cfg = settings_from_prefs(prefs)
	b.tabs = make(map[u64]^Tab_State)
	b.tab_scopes = make(map[^base.Scope]^Tab_State)
	b.docs = make(map[^fetch.Environment]^Doc)
	b.doc_scopes = make(map[^base.Scope]^Doc)
	b.conf.sites = make(map[string]Site_Flags)
	journal_init(&b.journal, 100)
	lists := [?]adblock.List_Text{{BASE_LIST_ID, "Wren base list", BASE_LIST_TEXT}, {MY_FILTERS_ID, "My filters", my_filters}}
	blob := adblock.compile(lists[:])
	e, _ := adblock.engine_load(blob, true, false)
	ref := new(Engine_Ref)
	ref.engine, ref.texts = e, make(map[u32]string)
	ref.sources = adblock.engine_sources(e)
	b.engine = ref
	ref.refs = 1
	the_blocker = b
	return
}

@(private = "file")
free_blocker :: proc(b: ^Blocker, prefs: ^config.Prefs) {
	dyn_destroy(&b.dyn)
	journal_destroy(&b.journal)
	conf_destroy(&b.conf)
	engine_ref_drop(b, b.engine)
	delete(b.tabs); delete(b.tab_scopes); delete(b.docs); delete(b.doc_scopes)
	config.prefs_destroy(prefs)
	free(prefs); free(b)
	the_blocker = nil
}

@(private = "file")
query :: proc(url: string, dest: fetch.Destination) -> fetch.Intercept_Query {
	return fetch.Intercept_Query{url = url, method = "GET", destination = dest}
}

@(test)
test_dynamic_rules_specificity :: proc(t: ^testing.T) {
	d: Dyn_Rules
	defer dyn_destroy(&d)
	dyn_set(&d, "*", "*", .Third_Party, .Block)
	dyn_set(&d, "*", "cdn.good.com", .All, .Allow)
	dyn_set(&d, "news.org", "cdn.good.com", .Script_3p, .Block)
	r, _ := dyn_eval(&d, "news.org", "x.evil.net", .Script, true, .Script)
	testing.expect_value(t, r, Dyn_Result.Block)
	r, _ = dyn_eval(&d, "news.org", "x.evil.net", .Image, false, .Image)
	testing.expect_value(t, r, Dyn_Result.Noop)
	r, _ = dyn_eval(&d, "other.org", "cdn.good.com", .Image, true, .Image)
	testing.expect_value(t, r, Dyn_Result.Allow)   // the destination's own rule beats the global third-party block
	r, _ = dyn_eval(&d, "news.org", "cdn.good.com", .Script, true, .Script)
	testing.expect_value(t, r, Dyn_Result.Block)   // a more specific kind and source
	dyn_set(&d, "*", "*", .Third_Party, .Noop)
	testing.expect_value(t, len(d.rules), 2)
}

@(test)
test_decisions :: proc(t: ^testing.T) {
	b, prefs := make_blocker("||tracker.test^\n@@||tracker.test/ok.js\n||site.test/ad/*\n")
	defer free_blocker(b, prefs)
	r: fetch.Intercept_Result
	q := query("https://tracker.test/x.js", .Script)
	request_hook(b, &q, &r)
	testing.expect_value(t, r.action, fetch.Intercept_Action.Block)
	testing.expect(t, r.reason != "")
	r = {}
	q = query("https://tracker.test/ok.js", .Script)
	request_hook(b, &q, &r)
	testing.expect_value(t, r.action, fetch.Intercept_Action.Allow)
	// a base-list script is answered with a stand-in
	r = {}
	q = query("https://www.google-analytics.com/analytics.js", .Script)
	request_hook(b, &q, &r)
	testing.expect_value(t, r.action, fetch.Intercept_Action.Replace)
	testing.expect(t, len(r.body) > 20)
	// switched off: nothing is looked at
	b.cfg.enabled = false
	r = {}
	q = query("https://tracker.test/x.js", .Script)
	request_hook(b, &q, &r)
	testing.expect_value(t, r.action, fetch.Intercept_Action.Allow)
}

@(test)
test_dynamic_rule_overrides_lists :: proc(t: ^testing.T) {
	b, prefs := make_blocker("||tracker.test^\n")
	defer free_blocker(b, prefs)
	dyn_set(&b.dyn, "*", "tracker.test", .All, .Allow)
	r: fetch.Intercept_Result
	q := query("https://tracker.test/x.js", .Script)
	request_hook(b, &q, &r)
	testing.expect_value(t, r.action, fetch.Intercept_Action.Allow)
	dyn_set(&b.dyn, "*", "plain.test", .All, .Block)
	r = {}
	q = query("https://plain.test/a.png", .Image)
	request_hook(b, &q, &r)
	testing.expect_value(t, r.action, fetch.Intercept_Action.Block)
}

@(test)
test_conf_roundtrip :: proc(t: ^testing.T) {
	b, prefs := make_blocker("")
	defer free_blocker(b, prefs)
	conf_defaults(&b.conf)
	site_set_flags(b, "example.org", {.Off})
	site_set_flags(b, "news.test", {.No_Cosmetic, .Hard})
	dyn_set(&b.dyn, "a.test", "b.test", .Image, .Block)
	delete(b.conf.my_filters)
	b.conf.my_filters = strings.clone("||x.test^\n##.y\n")
	l := list_add_custom(b, "Mine", "https://example.org/l.txt")
	testing.expect(t, l != nil && l.custom)
	text := conf_text(b, false)
	defer delete(text)
	// an import into a fresh configuration restores the same things
	b2, prefs2 := make_blocker("")
	defer free_blocker(b2, prefs2)
	conf_defaults(&b2.conf)
	ok, bad := conf_parse(b2, text, true)
	testing.expect(t, ok >= 5)
	testing.expect_value(t, bad, 0)
	testing.expect_value(t, site_flags(b2, "www.example.org"), Site_Flags{.Off})
	testing.expect_value(t, site_flags(b2, "news.test"), Site_Flags{.No_Cosmetic, .Hard})
	testing.expect_value(t, dyn_get(&b2.dyn, "a.test", "b.test", .Image), Dyn_Action.Block)
	testing.expect_value(t, b2.conf.my_filters, "||x.test^\n##.y\n")
	found := false
	for x in b2.conf.lists { if x.custom && x.url == "https://example.org/l.txt" { found = true } }
	testing.expect(t, found)
}

@(test)
test_journal_ring :: proc(t: ^testing.T) {
	j: Journal
	journal_init(&j, 3)
	defer journal_destroy(&j)
	for i in 0 ..< 5 { journal_add(&j, Log_Entry{url = "u", time = i64(i)}) }
	testing.expect_value(t, journal_len(&j), 3)
	testing.expect_value(t, journal_get(&j, 0).time, i64(2))
	testing.expect_value(t, journal_get(&j, 2).time, i64(4))
	journal_resize(&j, 2)
	testing.expect_value(t, journal_len(&j), 2)
	testing.expect_value(t, journal_get(&j, 0).time, i64(3))
}

@(test)
test_procedural_parse :: proc(t: ^testing.T) {
	testing.expect(t, needs_procedural("div:has-text(Ad)"))
	testing.expect(t, needs_procedural("div:has(:has-text(x))"))
	testing.expect(t, !needs_procedural("div:has(.x)"))
	testing.expect(t, !needs_procedural("a:not(.y)"))
	s, ok := proc_parse(".post:has-text(/sponsor/i):upward(2):remove()")
	testing.expect(t, ok)
	defer { proc_destroy(s); free(s) }
	testing.expect(t, s.remove)
	testing.expect_value(t, len(s.tasks), 3)
	testing.expect_value(t, s.tasks[1].kind, Task_Kind.Has_Text)
	testing.expect(t, s.tasks[1].re != nil)
	testing.expect_value(t, s.tasks[2].kind, Task_Kind.Upward_N)
	testing.expect_value(t, s.tasks[2].n, 2)
	_, bad := proc_parse(":nth-ancestor(x)")
	testing.expect(t, !bad)
}

@(test)
test_split_args :: proc(t: ^testing.T) {
	a := split_args("set-constant, a.b, \"x, y\", true")
	testing.expect_value(t, len(a), 4)
	testing.expect_value(t, a[2], "x, y")
	b := split_args("json-prune, a\\,b")
	testing.expect_value(t, b[1], "a,b")
}

@(test)
test_resources :: proc(t: ^testing.T) {
	defer resources_destroy()
	for name in ([]string{"noop.js", "google-analytics_ga.js", "googletagservices_gpt.js", "1x1.gif", "2x2-transparent.png", "32x32.png", "noopmp3-0.1s", "noopmp4-1s", "empty", "noopframe", "noop.css"}) {
		r, ok := resource_find(name, .Script)
		testing.expectf(t, ok, "%s must exist", name)
		_ = r
	}
	png, _ := resource_find("32x32.png", .Image)
	testing.expect(t, len(png.data) > 60 && string(png.data[1:4]) == "PNG")
	_, ok := resource_find("no-such-resource.js", .Script)
	testing.expect(t, !ok)
	js, _ := resource_find("noop.js:5", .Script)
	testing.expect(t, strings.has_prefix(js.mime, "text/javascript"))
}

@(test)
test_base_list_compiles :: proc(t: ^testing.T) {
	lists := [?]adblock.List_Text{{BASE_LIST_ID, "base", BASE_LIST_TEXT}}
	e, err := adblock.engine_from_lists(lists[:])
	testing.expect_value(t, err, adblock.Load_Error.None)
	if e == nil { return }
	defer adblock.engine_destroy(e)
	srcs := adblock.engine_sources(e, context.temp_allocator)
	testing.expect_value(t, srcs[0].invalid, u32(0))
	testing.expect(t, srcs[0].net > 100)
}
