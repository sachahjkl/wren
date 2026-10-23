// Package blocker: the browser's content blocker. It joins the filter engine (package adblock) to the rest of the
// browser:
//
//   * the network: a fetch.Interceptor decides every request before it leaves the machine, counts it per tab and per
//     host (the panel's matrix and graph), logs it (the dashboard's journal) and applies the user's own rules (dynamic
//     rules, per-site switches, the whitelist);
//   * the lists: catalog, download in the background with conditional requests, integrity checks, compilation to the
//     binary index on a thread of its own, cache in the profile (engine_build.odin, updater.odin);
//   * the pages: cosmetic filtering and scriptlets before the first paint (page_hooks.odin).
//
// Everything here runs on the loop (interface) thread except compilation, which hands its result over with host.post.
// A browser without an interceptor installed pays nothing: `start` is what connects it, and `blocker.enabled` off
// makes the interceptor return at its first line.
package blocker

import "core:strings"
import "core:time"
import "wb:adblock"
import "wb:base"
import "wb:config"
import "wb:fetch"
import "wb:host"
import "wb:http"
import "wb:net"
import "wb:page"
import "wb:url"

Site_Flag :: enum u8 {
	Off,            // no filtering at all on this site (the whitelist)
	No_Cosmetic,    // no element hiding
	No_Scriptlets,  // no scriptlets
	Block_Fonts,    // remote fonts are blocked
	Block_Media,    // media larger than blocker.large_media_kb are blocked
	Hard,           // third-party scripts and frames are blocked unless allowed by a rule
	Allow_Fonts,    // (explicit) overrides blocker.remote_fonts for this site
	Soft,           // (explicit) overrides blocker.hard_mode for this site
}
Site_Flags :: bit_set[Site_Flag; u8]

Outcome :: enum u8 {
	Allowed,
	Blocked,
	Redirected,     // answered with a stand-in
	Rewritten,      // URL parameters removed
	Excepted,       // a filter would have blocked it, an exception allowed it
	Dyn_Blocked,
	Dyn_Allowed,
	Site_Off,       // filtering is off for the site
	Policy,         // blocked by a site switch (hard mode, fonts, large media)
	Header,         // blocked by a response header filter
}

Cell :: struct { allowed, blocked: u32 }

Host_Row :: struct {
	host:        string,                          // owned
	third_party: bool,
	cells:       [adblock.Resource]Cell,
}

Tab_State :: struct {
	id:          u64,
	scope:       ^base.Scope,
	top:         ^Doc,
	blocked:     int,        // this page
	allowed:     int,
	redirected:  int,
	rewritten:   int,
	hidden:      int,        // elements hidden by cosmetic filters
	started_ms:  i64,        // monotonic ms when the page began
	points:      [dynamic]u32,   // ms since the page began, one per blocked request
	hosts:       map[string]^Host_Row,
	order:       [dynamic]^Host_Row,
	version:     u64,        // changes with every counter: the panel redraws when it sees a new one
}

Doc :: struct {
	env:       ^fetch.Environment,
	scope:     ^base.Scope,
	parent:    ^Doc,
	tab:       ^Tab_State,
	top:       bool,
	href:      string,       // owned: the address the fields below were computed for
	host:      string,       // owned
	domain:    string,       // owned: registrable domain
	site:      Site_Flags,   // the switches in force for the document's host
	site_ver:  u64,
	unfiltered: bool,        // whitelisted, or a $document exception: nothing is filtered or hidden
	page:      adblock.Page_Flags,
	engine:    ^Engine_Ref,  // the engine the cosmetic result below comes from
	cosmetic:  adblock.Cosmetic,
	has_cosmetic: bool,
	hooks:     rawptr,       // page_hooks.odin
}

Engine_Ref :: struct {
	engine:   ^adblock.Engine,
	refs:     int,           // documents holding cosmetic ids of this engine, plus 1 while it is the current one
	src_path: string,        // the lists' text the index was built from (rule lines are read from it)
	sources:  []adblock.Source_Info,   // owned
	generation: u64,
	texts:    map[u32]string,   // rule lines already read
	rules:    int,
}

Event_Kind :: enum u8 {
	Blocked,       // a request of a tab was blocked (console line)
	Changed,       // counters, lists or settings changed: redraw
	Lists,         // a list update finished
}

Event :: struct {
	kind:    Event_Kind,
	tab:     u64,
	url:     string,
	rule:    string,
	type:    adblock.Resource,
}

Totals :: struct {
	blocked, allowed, redirected, rewritten: u64,
	pages:   u64,
	since:   i64,                    // unix seconds
}

Blocker :: struct {
	cfg:        Settings,
	loop:       ^host.Loop,
	client:     ^net.Client,
	prefs:      ^config.Prefs,
	dir:        string,             // <profile>/blocker
	persist:    bool,
	engine:     ^Engine_Ref,
	conf:       Conf,
	conf_ver:   u64,                // changes with every edit of the configuration
	tabs:       map[u64]^Tab_State,
	tab_scopes: map[^base.Scope]^Tab_State,
	docs:       map[^fetch.Environment]^Doc,
	doc_scopes: map[^base.Scope]^Doc,
	dyn:        Dyn_Rules,
	journal:    Journal,
	totals:     Totals,
	upd:        Updater,
	on_event:   proc(user: rawptr, ev: ^Event),
	event_user: rawptr,
	generation: u64,
	version:    u64,                // changes when anything the UI shows changes
	last_env:   ^fetch.Environment, // one-entry cache of the last resolved document
	last_doc:   ^Doc,
	watch:      int,
	shutting_down: bool,
}

the_blocker: ^Blocker

now_ms :: proc() -> i64 { return time.tick_now()._nsec / 1_000_000 }
unix_ms :: proc() -> i64 { return time.time_to_unix_nano(time.now()) / 1_000_000 }

////////////////////////////////
// Life

// Creates the blocker, loads its configuration and the compiled index (or the built-in base list while the real one is
// compiled), and installs it on the loader. `profile_dir` is the profile folder ("" keeps everything in memory).
start :: proc(b: ^Blocker, loop: ^host.Loop, client: ^net.Client, loader: ^fetch.Loader, prefs: ^config.Prefs, profile_dir: string) {
	b.loop, b.client, b.prefs = loop, client, prefs
	b.cfg = settings_from_prefs(prefs)
	b.tabs = make(map[u64]^Tab_State)
	b.tab_scopes = make(map[^base.Scope]^Tab_State)
	b.docs = make(map[^fetch.Environment]^Doc)
	b.doc_scopes = make(map[^base.Scope]^Doc)
	b.persist = profile_dir != ""
	if b.persist { b.dir = strings.concatenate({profile_dir, "/blocker"}); make_dirs(b.dir) }
	adblock.suffix_labels_hook = url.public_suffix_labels_fast
	conf_load(b)
	journal_init(&b.journal, b.cfg.log_capacity)
	the_blocker = b
	b.watch = config.watch(prefs, "blocker.", prefs_changed, b)
	engine_boot(b)
	install_page_hooks(b)   // page_hooks.odin
	loader.interceptor = fetch.Interceptor{
		user = b, request = request_hook, response = response_hook, document_begin = document_begin_hook, document_end = document_end_hook,
	}
	updater_schedule(b, b.cfg.update_delay_s)
}

@(private)
prefs_changed :: proc(user: rawptr, name: string, p: ^config.Prefs) {
	b := (^Blocker)(user)
	old := b.cfg
	b.cfg = settings_from_prefs(p)
	page.embedder.collapse_blocked = b.cfg.collapse
	if b.cfg.log_capacity != old.log_capacity { journal_resize(&b.journal, b.cfg.log_capacity) }
	b.conf_ver += 1
	touch(b)
	if b.cfg.update && !old.update { updater_schedule(b, 2) }
}

shutdown :: proc(b: ^Blocker, loader: ^fetch.Loader) {
	b.shutting_down = true
	loader.interceptor = {}
	remove_page_hooks(b)
	if b.watch != 0 { config.unwatch(b.prefs, b.watch) }
	updater_stop(b)
	conf_save(b)
	for _, d in b.docs { doc_free(b, d) }
	delete(b.docs); delete(b.doc_scopes)
	for _, t in b.tabs { tab_free(t) }
	delete(b.tabs); delete(b.tab_scopes)
	if b.engine != nil { engine_ref_drop(b, b.engine); b.engine = nil }
	dyn_destroy(&b.dyn)
	journal_destroy(&b.journal)
	conf_destroy(&b.conf)
	resources_destroy()
	delete(b.dir)
	the_blocker = nil
}

// Tells the shell that something it shows changed.
touch :: proc(b: ^Blocker) {
	b.version += 1
	if b.on_event != nil && !b.shutting_down { ev := Event{kind = .Changed}; b.on_event(b.event_user, &ev) }
}

////////////////////////////////
// Tabs and documents

// A tab of the shell: its scope is what requests' scopes lead to.
tab_register :: proc(b: ^Blocker, id: u64, scope: ^base.Scope) {
	t := new(Tab_State)
	t.id, t.scope = id, scope
	t.hosts = make(map[string]^Host_Row)
	t.started_ms = now_ms()
	b.tabs[id] = t
	b.tab_scopes[scope] = t
	base.on_close(scope, tab_scope_closed, t)
}

@(private)
tab_scope_closed :: proc(data: rawptr) {
	t := (^Tab_State)(data)
	b := the_blocker
	if b == nil { return }
	delete_key(&b.tab_scopes, t.scope)
	delete_key(&b.tabs, t.id)
	for _, d in b.docs { if d.tab == t { d.tab = nil } }
	b.last_env, b.last_doc = nil, nil
	tab_free(t)
}

tab_state :: proc(b: ^Blocker, id: u64) -> ^Tab_State { return b.tabs[id] }

@(private)
tab_free :: proc(t: ^Tab_State) {
	tab_reset_counters(t)
	delete(t.hosts)
	delete(t.order)
	delete(t.points)
	free(t)
}

@(private)
tab_reset_counters :: proc(t: ^Tab_State) {
	t.blocked, t.allowed, t.redirected, t.rewritten, t.hidden = 0, 0, 0, 0, 0
	for _, r in t.hosts { delete(r.host); free(r) }
	clear(&t.hosts)
	clear(&t.order)
	clear(&t.points)
	t.started_ms = now_ms()
	t.version += 1
}

@(private)
doc_free :: proc(b: ^Blocker, d: ^Doc) {
	hooks_free(d)
	if d.has_cosmetic { adblock.cosmetic_destroy(&d.cosmetic); d.has_cosmetic = false }
	if d.engine != nil { engine_ref_drop(b, d.engine); d.engine = nil }
	delete(d.href); delete(d.host); delete(d.domain)
	free(d)
}

@(private)
document_begin_hook :: proc(user: rawptr, env: ^fetch.Environment, scope: ^base.Scope) {
	b := (^Blocker)(user)
	d := new(Doc)
	d.env, d.scope = env, scope
	// the nearest document above this scope is the parent frame; the nearest registered tab scope is the tab
	for s := scope.parent; s != nil; s = s.parent {
		if d.parent == nil { if pd, ok := b.doc_scopes[s]; ok { d.parent = pd } }
		if t, ok := b.tab_scopes[s]; ok { d.tab = t; break }
	}
	if d.parent != nil && d.tab == nil { d.tab = d.parent.tab }
	d.top = d.parent == nil
	if d.tab != nil {
		env.tag = d.tab.id
		if d.top {
			tab_reset_counters(d.tab)
			d.tab.top = d
			b.totals.pages += 1
		}
	}
	b.docs[env] = d
	b.doc_scopes[scope] = d
	doc_refresh(b, d)
	b.last_env = nil
	if d.top { touch(b) }
}

@(private)
document_end_hook :: proc(user: rawptr, env: ^fetch.Environment) {
	b := (^Blocker)(user)
	d, ok := b.docs[env]
	if !ok { return }
	delete_key(&b.docs, env)
	delete_key(&b.doc_scopes, d.scope)
	if d.tab != nil && d.tab.top == d { d.tab.top = nil }
	b.last_env, b.last_doc = nil, nil
	for _, o in b.docs { if o.parent == d { o.parent = nil } }
	doc_free(b, d)
}

// Recomputes what depends on the document's address (it changes with pushState) and on the configuration.
doc_refresh :: proc(b: ^Blocker, d: ^Doc) {
	href := d.env.location.href
	if href != d.href {
		delete(d.href); delete(d.host); delete(d.domain)
		d.href = strings.clone(href)
		d.host = strings.clone(d.env.location.host)
		d.domain = strings.clone(adblock.registrable_domain(d.host))
		d.site_ver = 0
	}
	if d.site_ver != b.conf_ver + 1 {
		d.site_ver = b.conf_ver + 1
		page_host := d.host
		if d.tab != nil && d.tab.top != nil && d.tab.top != d && d.tab.top.host != "" { page_host = d.tab.top.host }
		d.site = site_flags(b, page_host)
		d.unfiltered = .Off in d.site || (d.env.location.scheme != "http" && d.env.location.scheme != "https")
		d.page = {}
		if !d.unfiltered && b.engine != nil {
			pf, _ := adblock.page_flags(b.engine.engine, href)
			d.page = pf
			if .Document in pf { d.unfiltered = true }
		}
	}
}

// Document, tab and cached state of the request's initiator.
@(private)
resolve :: proc(b: ^Blocker, env: ^fetch.Environment, scope: ^base.Scope) -> (d: ^Doc, t: ^Tab_State) {
	if env != nil {
		if env == b.last_env { d = b.last_doc } else {
			d = b.docs[env]
			b.last_env, b.last_doc = env, d
		}
		if d != nil { doc_refresh(b, d); return d, d.tab }
		if env.tag != 0 { t = b.tabs[env.tag] }
	}
	if t == nil && scope != nil {
		for s := scope; s != nil; s = s.parent {
			if tt, ok := b.tab_scopes[s]; ok { t = tt; break }
		}
	}
	return d, t
}

////////////////////////////////
// Site switches

// The switches that apply to a host: the most specific entry of the configuration (the host, then its parents).
site_flags :: proc(b: ^Blocker, host: string) -> Site_Flags {
	h := host
	for h != "" {
		if f, ok := b.conf.sites[h]; ok { return f }
		d := strings.index_byte(h, '.')
		if d < 0 { break }
		h = h[d + 1:]
	}
	return {}
}

effective_hard_of :: proc(b: ^Blocker, f: Site_Flags) -> bool { return effective_hard(b, f) }
effective_fonts_of :: proc(b: ^Blocker, f: Site_Flags) -> bool { return effective_fonts(b, f) }

@(private)
effective_hard :: proc(b: ^Blocker, f: Site_Flags) -> bool { return .Hard in f || (b.cfg.hard_mode && .Soft not_in f) }
@(private)
effective_fonts :: proc(b: ^Blocker, f: Site_Flags) -> bool { return .Block_Fonts in f || (b.cfg.remote_fonts && .Allow_Fonts not_in f) }

////////////////////////////////
// The decision

@(private)
resource_of :: proc(q: ^fetch.Intercept_Query) -> adblock.Resource {
	if q.websocket { return .Websocket }
	switch q.destination {
	case .Empty: return q.ping ? .Ping : .Xhr
	case .Document: return .Document
	case .Script, .Worker: return .Script
	case .Style: return .Stylesheet
	case .Image: return .Image
	case .Font: return .Font
	case .Audio, .Video: return .Media
	case .Manifest: return .Other
	case .Report: return .Csp_Report
	case .Iframe: return .Subdocument
	}
	return .Other
}

@(private)
request_hook :: proc(user: rawptr, q: ^fetch.Intercept_Query, r: ^fetch.Intercept_Result) {
	b := (^Blocker)(user)
	if !b.cfg.enabled || b.engine == nil { return }
	decide(b, q, r)
}

@(private)
decide :: proc(b: ^Blocker, q: ^fetch.Intercept_Query, r: ^fetch.Intercept_Result) {
	d, tab := resolve(b, q.initiator, q.scope)
	type := resource_of(q)
	req := adblock.Request{url = q.url, type = type, method = adblock.method_from_string(q.method)}
	req.host = adblock.url_host(q.url)
	if req.host == "" { return }

	// the page the request belongs to: switches are the top document's
	nav := type == .Document
	site := Site_Flags{}
	unfiltered := false
	doc_url := ""
	if nav {
		site = site_flags(b, req.host)
		unfiltered = .Off in site
		if !unfiltered { if pf, _ := adblock.page_flags(b.engine.engine, q.url); .Document in pf { unfiltered = true } }
		req.source_host = req.host
	} else if d != nil {
		site, unfiltered = d.site, d.unfiltered
		doc_url = d.href
		req.source_url, req.source_host, req.source_domain = d.href, d.host, d.domain
		req.third_party = adblock.registrable_domain(req.host) != d.domain
	} else if q.initiator != nil {
		// a worker or another environment the blocker does not track: judged by its own address
		loc := &q.initiator.location
		req.source_url, req.source_host = loc.href, loc.host
		req.source_domain = adblock.registrable_domain(loc.host)
		doc_url = loc.href
		site = site_flags(b, loc.host)
		unfiltered = .Off in site
		req.third_party = adblock.registrable_domain(req.host) != req.source_domain
	}

	outcome := Outcome.Allowed
	rule := u32(adblock.NO_FILTER)
	reason := ""

	if unfiltered {
		outcome = .Site_Off
	} else {
		// 1. the user's own rules decide first
		dyn_res := Dyn_Result.Noop
		note := ""
		if dyn_active(&b.dyn) {
			dyn_res, note = dyn_eval(&b.dyn, req.source_host == "" ? req.host : req.source_host, req.host, type, req.third_party, q.destination)
		}
		switch dyn_res {
		case .Block: outcome, reason = .Dyn_Blocked, note
		case .Allow: outcome = .Dyn_Allowed
		case .Noop:
			switch {
			case !nav && type == .Font && effective_fonts(b, site):
				outcome, reason = .Policy, "remote fonts are blocked on this site"
			case !nav && req.third_party && effective_hard(b, site) && (type == .Script || type == .Subdocument):
				outcome, reason = .Policy, "hard mode: third-party scripts and frames are blocked on this site"
			case:
				v := adblock.match(b.engine.engine, &req)
				switch v.action {
				case .Allow:
				case .Block: outcome, rule = .Blocked, v.filter
				case .Exception: outcome, rule = .Excepted, v.filter
				case .Redirect:
					outcome, rule = .Blocked, v.filter
					if b.cfg.redirects {
						if res, ok := resource_find(v.resource, q.destination); ok {
							outcome = .Redirected
							r.action, r.status, r.mime, r.body = .Replace, 200, res.mime, res.data
						}
					}
				}
				if outcome == .Allowed && b.cfg.removeparam && strings.contains_rune(q.url, '?') {
					if nu, changed := adblock.rewrite_url(b.engine.engine, &req, context.temp_allocator); changed {
						outcome = .Rewritten
						r.action, r.new_url = .Rewrite, nu
					}
				}
			}
		}
	}

	switch outcome {
	case .Blocked, .Dyn_Blocked, .Policy, .Header:
		r.action = .Block
		if rule != adblock.NO_FILTER { reason = rule_text(b, b.engine, rule) }
		r.reason = reason
	case .Redirected:
		reason = rule_text(b, b.engine, rule)
		r.reason = reason
	case .Rewritten: r.reason = "removeparam"
	case .Allowed, .Excepted, .Dyn_Allowed, .Site_Off:
	}
	record(b, tab, q, &req, outcome, rule, reason, doc_url)
}

////////////////////////////////
// Counting

@(private)
record :: proc(b: ^Blocker, tab: ^Tab_State, q: ^fetch.Intercept_Query, req: ^adblock.Request, outcome: Outcome, rule: u32, reason: string, doc_url: string) {
	blocked := outcome == .Blocked || outcome == .Dyn_Blocked || outcome == .Policy || outcome == .Header
	counted := blocked || outcome == .Redirected
	switch {
	case blocked: b.totals.blocked += 1
	case outcome == .Redirected: b.totals.redirected += 1; b.totals.blocked += 1
	case outcome == .Rewritten: b.totals.rewritten += 1
	case: b.totals.allowed += 1
	}
	if tab != nil {
		hosts_count(b, tab, req, counted)
		switch {
		case blocked: tab.blocked += 1
		case outcome == .Redirected: tab.redirected += 1; tab.blocked += 1
		case outcome == .Rewritten: tab.rewritten += 1; tab.allowed += 1
		case: tab.allowed += 1
		}
		if counted && len(tab.points) < b.cfg.graph_points { append(&tab.points, u32(max(now_ms() - tab.started_ms, 0))) }
		tab.version += 1
	}
	if b.journal.armed || b.cfg.log_always {
		list := u8(0)
		if rule != adblock.NO_FILTER && b.engine != nil { list = adblock.filter_ref(b.engine.engine, rule).list }
		journal_add(&b.journal, Log_Entry{
			time = unix_ms(), tab = tab != nil ? tab.id : 0, type = req.type, outcome = outcome, url = q.url, doc = doc_url,
			rule = reason, filter = rule, list = list, engine = b.generation,
		})
	}
	if counted {
		trace("%d ms %v %v %s", now_ms() - (tab != nil ? tab.started_ms : 0), req.type, outcome, q.url)
		if b.on_event != nil {
			ev := Event{kind = .Blocked, tab = tab != nil ? tab.id : 0, url = q.url, rule = reason, type = req.type}
			b.on_event(b.event_user, &ev)
		}
		b.version += 1
	}
}

@(private)
hosts_count :: proc(b: ^Blocker, tab: ^Tab_State, req: ^adblock.Request, blocked: bool) {
	row, ok := tab.hosts[req.host]
	if !ok {
		if len(tab.order) >= b.cfg.max_hosts_per_tab { return }
		row = new(Host_Row)
		row.host = strings.clone(req.host)
		row.third_party = req.third_party
		tab.hosts[row.host] = row
		append(&tab.order, row)
	}
	c := &row.cells[req.type]
	if blocked { c.blocked += 1 } else { c.allowed += 1 }
}

@(private)
Header_Lookup :: struct { h: http.Headers }

@(private)
header_lookup :: proc(user: rawptr, name: string) -> (string, bool) {
	l := (^Header_Lookup)(user)
	return http.get_header(l.h, name)
}

@(private)
response_hook :: proc(user: rawptr, q: ^fetch.Intercept_Query, headers: http.Headers, r: ^fetch.Intercept_Result) {
	b := (^Blocker)(user)
	if !b.cfg.enabled || b.engine == nil || q.ping { return }
	d, tab := resolve(b, q.initiator, q.scope)
	nav := q.destination == .Document
	if d != nil && d.unfiltered && !nav { return }
	type := resource_of(q)
	req := adblock.Request{url = q.url, type = type, method = adblock.method_from_string(q.method)}
	req.host = adblock.url_host(q.url)
	if req.host == "" { return }
	site := Site_Flags{}
	if nav {
		site = site_flags(b, req.host)
		if .Off in site { return }
		req.source_host = req.host
	} else if d != nil {
		site = d.site
		req.source_url, req.source_host, req.source_domain = d.href, d.host, d.domain
		req.third_party = adblock.registrable_domain(req.host) != d.domain
	} else { return }

	// large media: decided from Content-Length, before the body is read
	if type == .Media && .Block_Media in site {
		if v, ok := http.get_header(headers, "content-length"); ok {
			n := 0
			for c in transmute([]u8)v { if c >= '0' && c <= '9' && n < 1 << 50 { n = n * 10 + int(c - '0') } }
			if n > b.cfg.large_media_kb * 1024 {
				r.action = .Block
				r.reason = "large media are blocked on this site"
				record(b, tab, q, &req, .Policy, adblock.NO_FILTER, r.reason, d.href)
				return
			}
		}
	}
	if !adblock.has_response_filters(b.engine.engine) { return }
	// $header filters
	lk := Header_Lookup{headers}
	fid := adblock.match_response_headers(b.engine.engine, &req, header_lookup, &lk)
	if fid != adblock.NO_FILTER {
		r.action = .Block
		r.reason = rule_text(b, b.engine, fid)
		record(b, tab, q, &req, .Header, fid, r.reason, d != nil ? d.href : "")
		return
	}
	// $csp: policies added to a document's answer
	if type == .Document || type == .Subdocument {
		if pol := adblock.csp_directives(b.engine.engine, &req, context.temp_allocator); len(pol) > 0 { r.csp = pol }
	}
}

////////////////////////////////
// Engines

engine_ref_drop :: proc(b: ^Blocker, e: ^Engine_Ref) {
	e.refs -= 1
	if e.refs > 0 { return }
	adblock.engine_destroy(e.engine)
	for _, s in e.texts { delete(s) }
	delete(e.texts)
	delete(e.sources)
	delete(e.src_path)
	free(e)
}

// Installs a new engine as the current one; documents keep the one their cosmetic result comes from until they end.
engine_install :: proc(b: ^Blocker, e: ^Engine_Ref) {
	old := b.engine
	b.engine = e
	b.generation += 1
	e.generation = b.generation
	e.refs += 1
	b.last_env, b.last_doc = nil, nil
	b.conf_ver += 1
	if old != nil { engine_ref_drop(b, old) }
	touch(b)
}
