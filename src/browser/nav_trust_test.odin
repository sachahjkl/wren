package browser

import "core:testing"
import "wb:fetch"
import "wb:url"

@(private = "file")
env_of :: proc(href: string) -> fetch.Environment {
	u, _ := url.parse_absolute(href, context.temp_allocator)
	return fetch.environment_make(u)
}

@(private = "file")
Judge_Row :: struct {
	origin:  Nav_Origin,
	from:    string,   // the requester's address; "" none
	target:  string,
	address: string,   // expected
	acts:    bool,
	refused: bool,
}

@(private = "file") SITES_CLEAR :: "about:sites?clear=*&type=all"
@(private = "file") WEB         :: "https://evil.example/page"
@(private = "file") FILE_DOC    :: "file:///C:/site/index.html"

@(test)
judge_table :: proc(t: ^testing.T) {
	rows := []Judge_Row{
		// the destructive addresses: only a person, or the page itself, makes them act
		{.Page,   WEB,       SITES_CLEAR,                       "about:sites", false, false},
		{.Page,   "",        SITES_CLEAR,                       "about:sites", false, false},   // a requester that is gone is not a privilege
		{.Page,   FILE_DOC,  SITES_CLEAR,                       "about:sites", false, false},
		{.Page,   "about:demos", SITES_CLEAR,                   "about:sites", false, false},   // (only about:sites clears its data)
		{.Page,   "about:sites", SITES_CLEAR,                   SITES_CLEAR,   true,  false},
		{.User,   "",        SITES_CLEAR,                       SITES_CLEAR,   true,  false},
		{.Replay, "",        SITES_CLEAR,                       "about:sites", false, false},   // F5, back and forward never clear
		{.Replay, WEB,       SITES_CLEAR,                       "about:sites", false, false},
		{.Page,   WEB,       "about:sites?q=ex&clear=a.example&type=cookies", "about:sites?q=ex", false, false},
		{.Page,   WEB,       "about:sites?cl%65ar=*&type=all",  "about:sites", false, false},   // a name is never decoded into one that is kept
		{.Page,   WEB,       "about:sites?q=ex#top",            "about:sites?q=ex#top", false, false},
		{.Page,   WEB,       "about:cache?clear=1",             "about:cache", false, false},
		{.Page,   "about:cache", "about:cache?clear=1",         "about:cache?clear=1", true, false},
		{.Page,   "about:sites", "about:cache?clear=1",         "about:cache", false, false},   // not the cache's own page
		{.Replay, "",        "about:cache?q=x&clear=1",         "about:cache?q=x", false, false},
		{.User,   "",        "about:cache?clear=1",             "about:cache?clear=1", true, false},
		{.Page,   WEB,       "about:wren?action=remove",        "about:wren",  false, false},
		{.Page,   WEB,       "about:wren?action=register&key=x#a", "about:wren#a", false, false},
		{.Page,   WEB,       "about:wren?choose=1",             "about:wren",  false, false},
		{.Page,   WEB,       "about:wren?card=sample",          "about:wren?card=sample", false, false},
		{.Page,   WEB,       "about:wren?card=sample&action=remove", "about:wren?card=sample", false, false},
		{.Page,   "about:wren", "about:wren?action=remove",     "about:wren?action=remove", true, false},   // the form of the page
		{.Page,   "about:demos", "about:wren?action=remove",    "about:wren?action=remove", true, false},
		{.User,   "",        "about:wren?action=remove",        "about:wren?action=remove", true, false},
		{.Replay, "",        "about:wren?action=remove",        "about:wren",  false, false},
		{.Page,   WEB,       "about:licenses#x",                "about:licenses#x", false, false},   // nothing to cut
		// a licence file is read from disk only for a person or the browser's own pages
		{.User,   "",        "file:///C:/Users/x/a.wrenlicense", "file:///C:/Users/x/a.wrenlicense", true, false},
		{.Page,   "about:wren", "file:///C:/Users/x/a.wrenlicense", "file:///C:/Users/x/a.wrenlicense", true, false},
		{.Page,   WEB,       "file:///C:/Users/x/a.wrenlicense", "file:///C:/Users/x/a.wrenlicense", false, true},
		{.Page,   WEB,       "file://evil.example/s/x.wrenlicense", "file://evil.example/s/x.wrenlicense", false, true},
		{.Replay, "",        "file:///C:/Users/x/a.wrenlicense", "file:///C:/Users/x/a.wrenlicense", false, false},
		// files and shares: a web page gets none, a file document only what the loader allows it, a person all
		{.Page,   WEB,       "file:///C:/Windows/win.ini",      "file:///C:/Windows/win.ini", false, true},
		{.Page,   WEB,       "FILE:///C:/Windows/win.ini",      "FILE:///C:/Windows/win.ini", false, true},
		{.Page,   WEB,       "file://attacker.example/share/x.html", "file://attacker.example/share/x.html", false, true},
		{.Page,   WEB,       "view-source:file:///C:/x.html",   "view-source:file:///C:/x.html", false, true},
		{.Page,   WEB,       "view-source:view-source:file:///C:/x.html", "view-source:view-source:file:///C:/x.html", false, true},
		{.Page,   "",        "file:///C:/Windows/win.ini",      "file:///C:/Windows/win.ini", false, true},
		{.Page,   "about:sites", "file:///C:/x.html",           "file:///C:/x.html", false, true},   // (a page of the browser that is not a link list)
		{.Page,   "about:demos", "file:///C:/demos/a.html",     "file:///C:/demos/a.html", false, false},   // about:demos links to local files
		{.Page,   FILE_DOC,  "file:///C:/site/other.html",      "file:///C:/site/other.html", false, false},
		{.Page,   FILE_DOC,  "file://localhost/C:/site/o.html", "file://localhost/C:/site/o.html", false, false},
		{.Page,   FILE_DOC,  "file://attacker.example/s/x.html", "file://attacker.example/s/x.html", false, true},   // another machine from a local page
		{.Page,   "file://srv/share/a.html", "file://srv/share/b.html", "file://srv/share/b.html", false, false},   // the same machine
		{.Page,   "file://srv/share/a.html", "file://other/share/b.html", "file://other/share/b.html", false, true},
		{.User,   "",        "file:///C:/Windows/win.ini",      "file:///C:/Windows/win.ini", false, false},
		{.User,   "",        "file://server/share/x.html",      "file://server/share/x.html", false, false},
		{.Replay, "",        "file://server/share/x.html",      "file://server/share/x.html", false, false},
		// the web goes through
		{.Page,   WEB,       "https://example.org/a?clear=1",   "https://example.org/a?clear=1", false, false},
		{.Page,   WEB,       "about:blank",                     "about:blank", false, false},
		{.Page,   WEB,       "about:config?q=x&action=remove",  "about:config?q=x&action=remove", false, false},   // (no effect through the address)
	}
	for r, i in rows {
		env: fetch.Environment
		has_env := r.from != ""
		if has_env { env = env_of(r.from) }
		defer if has_env { fetch.environment_destroy(&env) }
		v := nav_judge(r.origin, has_env ? &env : nil, .Own_Tree, r.target)
		testing.expectf(t, v.address == r.address, "row %d %v from %q to %q: address %q, want %q", i, r.origin, r.from, r.target, v.address, r.address)
		testing.expectf(t, v.acts == r.acts, "row %d %v from %q to %q: acts %v, want %v", i, r.origin, r.from, r.target, v.acts, r.acts)
		testing.expectf(t, (v.refuse != "") == r.refused, "row %d %v from %q to %q: refused %q, want %v", i, r.origin, r.from, r.target, v.refuse, r.refused)
	}
}

@(test)
judge_file_policy :: proc(t: ^testing.T) {
	env := env_of(FILE_DOC)
	defer fetch.environment_destroy(&env)
	testing.expect(t, nav_judge(.Page, &env, .Own_Tree, "file:///C:/site/o.html").refuse == "")
	testing.expect(t, nav_judge(.Page, &env, .All, "file:///C:/site/o.html").refuse == "")
	testing.expect(t, nav_judge(.Page, &env, .None, "file:///C:/site/o.html").refuse != "", "security.file_access.policy=none: a local page opens no other file either")
	testing.expect(t, nav_judge(.User, &env, .None, "file:///C:/site/o.html").refuse == "", "the person's address bar is not a page")
}

@(test)
home_search_box :: proc(t: ^testing.T) {
	words, ok := home_search_words("about:home?q=wren+browser%21+caf%C3%A9&x=1#top")
	testing.expect(t, ok)
	testing.expect_value(t, words, "wren browser! café")
	_, ok = home_search_words("about:home?art=on")
	testing.expect(t, !ok, "no q: not a search")
	_, ok = home_search_words("about:history?q=a")
	testing.expect(t, !ok, "another page's q is its own filter")
	web := env_of(WEB)
	defer fetch.environment_destroy(&web)
	home := env_of("about:home")
	defer fetch.environment_destroy(&home)
	testing.expect(t, nav_judge(.Page, &home, .Own_Tree, "about:home?q=cats").acts, "the start page's own form acts")
	v := nav_judge(.Page, &web, .Own_Tree, "about:home?q=cats")
	testing.expect(t, !v.acts, "a web page's form does not search through the start page")
	testing.expect_value(t, v.address, "about:home")
}

@(test)
only_a_person_trusts :: proc(t: ^testing.T) {
	web := env_of(WEB)
	defer fetch.environment_destroy(&web)
	demos := env_of("about:demos")
	defer fetch.environment_destroy(&demos)
	testing.expect(t, nav_judge(.User, nil, .Own_Tree, "https://example.org/").trusted)
	testing.expect(t, nav_judge(.Page, &demos, .Own_Tree, "https://example.org/").trusted, "the browser's own link pages open as the address bar would")
	testing.expect(t, !nav_judge(.Page, &web, .Own_Tree, "https://example.org/").trusted)
	testing.expect(t, !nav_judge(.Page, nil, .Own_Tree, "https://example.org/").trusted, "a navigation with no origin said is nobody's")
	testing.expect(t, !nav_judge(.Replay, nil, .Own_Tree, "https://example.org/").trusted)
	testing.expect_value(t, Nav_Origin{}, Nav_Origin.Page)   // the zero value is the least privileged
}
