package page

// Nested browsing contexts (HTML §7.3 "navigables"): an <iframe> or <frame> shows a document of its own.
//
//   parent Page ── frames.children ──▶ Navigable (id, name, container element, sandbox, allow) ──▶ child Page
//                                                                                               (own document, origin,
//                                                                                                realm, tasks)
//
// A Navigable outlives the documents it shows: it is the "browsing context" scripts of other documents name
// (a WindowProxy of another realm holds its id, frames_scripts.odin), its window.name, its container's attributes as of the
// last navigation. Its active document is an ordinary Page created in the parent page's scope: closing the parent
// closes every nested document first (child scopes close before the parent's cleanups), and a navigation replaces the
// child Page by a new one (the old one is closed when the new response is in, as the shell does for a tab).
//
//   * Creation: a frame element that becomes connected gets a navigable and its initial about:blank document at once
//     (the parser's reveal and the DOM's insertion hook call frames_note_inserted; a document without scripts is
//     scanned when it is adopted); then src / srcdoc are processed ("process the iframe attributes"). Removal destroys
//     it synchronously (the DOM's removal hook: frames_note_removed).
//   * Loading: package page fetches the document itself (destination Iframe, the parent's environment as the
//     initiator: frame-src of the parent's CSP, the top level's site for cookies and the cache partition), checks
//     X-Frame-Options and frame-ancestors against every ancestor, parses it off the UI thread, starts its scripts.
//     The parent's load event waits for its frames (frames_delay_load); the container gets "load" when the nested
//     document's load is complete, or when it could not be shown.
//   * Security: a sandboxed frame gets an opaque origin unless allow-same-origin, no scripts unless allow-scripts
//     (frames_policy.odin); about:blank and srcdoc documents inherit their parent's origin; data: documents are opaque.
//     The Permissions Policy (allow attribute, Permissions-Policy header) gives each document its enabled features
//     (feature_enabled). Scripts of different documents never share objects (one engine instance per realm): what
//     crosses is messages (postMessage) and navigations, both as tasks.
//   * Embedding: the shell lays out and paints each child document in its container's content box (frame_hooks),
//     routes input to it by hit testing and reports how far a lazy frame is from the viewport.
//
// Session history: a nested document keeps a private session (history.length counts the tab's entries plus its own);
// navigations of frames do not add entries to the tab's history tree. Chromium adds joint entries; documented as a
// limit in docs and the session note.

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:csp"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:http"
import "wb:url"

// What the embedder (the shell) does with nested documents. All optional.
Frame_Hooks :: struct {
	user:     rawptr,
	// A document was made for a navigable (its initial about:blank, then one per navigation): connect it (layout,
	// geometry for scripts). `child.frames.nav` is its navigable.
	attached: proc(user: rawptr, child: ^Page),
}

frame_hooks: Frame_Hooks

Container_Kind :: enum u8 { Iframe, Frame }

Navigable :: struct {
	id:          u64,
	page:        ^Page,          // the active document; nil only while it is replaced or destroyed
	parent:      ^Page,          // the container's document; nil for a top-level navigable
	element:     base.Handle,    // the container in parent.doc
	kind:        Container_Kind,
	name:        string,         // owned: window.name, the target name of links and forms
	sandbox:     Sandbox,        // the container's sandbox attribute as of the last navigation
	allow:       Permissions_Policy,   // the container's allow attribute as of the last navigation
	src_origin:  url.Origin,     // owned: the origin of the container's src at the last navigation ('src' allowlists)
	load:        ^Frame_Load,    // the navigation in flight
	delaying:    bool,           // the parent's load event waits for this document
	lazy_wait:   bool,           // loading=lazy: waits for the embedder to say it is near the viewport
	lazy_url:    string,         // owned
	distance:    f32,            // CSS px from the viewport, as the embedder last said (max: unknown)
	cleanup:     base.Cleanup_Id,   // on page's scope: forgets the page when it closes
	navigations: u64,
}

// A page's side of nesting (made on first use).
Page_Frames :: struct {
	nav:           ^Navigable,          // the navigable this page is the active document of
	owns_nav:      bool,                // a top-level navigable made for this page (freed with it)
	children:      [dynamic]^Navigable, // the navigables of this document's frame elements
	order_version: u64,                 // doc.tree_version when `children` was last sorted in tree order
	sandbox:       Sandbox,             // the document's sandboxing flags
	inherited_off: bit_set[Feature],    // features its container did not delegate
	declared:      Permissions_Policy,  // its own Permissions-Policy header
	features:      bit_set[Feature],    // enabled features (feature_enabled)
	fallback_base: string,              // owned: about:blank / srcdoc documents resolve URLs against their parent's
	complete:      bool,                // its load is complete (the container's load event was queued)
	ready_poll:    base.Handle,         // a document without scripts: waits for its resources before it is complete
}

@(private)
navigables: map[u64]^Navigable
@(private)
next_navigable_id: u64
@(private)
navigable_count: int

// Process end (process_shutdown): the registry of navigables (empty once every page is closed).
frames_shutdown :: proc() {
	ports_shutdown()
	delete(navigables)
	navigables = nil
}

// The navigable with this id, nil once it is gone.
navigable_by_id :: proc(id: u64) -> ^Navigable {
	n, ok := navigables[id]
	return ok ? n : nil
}

frames_of :: proc(p: ^Page) -> ^Page_Frames {
	if p.frames != nil { return p.frames }
	f := new(Page_Frames)
	p.frames = f
	f.features = enabled_features({}, nil, p.env.origin)
	base.on_close(p.scope, frames_cleanup, p)
	return f
}

// The navigable of a document: a nested one's, or (made on first use) the top-level one of a tab's document. nil in a
// worker.
page_navigable :: proc(p: ^Page) -> ^Navigable {
	if p == nil || p.worker != nil || p.closed { return nil }
	f := frames_of(p)
	if f.nav != nil { return f.nav }
	n := navigable_new()
	n.page = p
	f.nav = n
	f.owns_nav = true
	return n
}

@(private)
navigable_new :: proc() -> ^Navigable {
	if navigables == nil { navigables = make(map[u64]^Navigable) }
	next_navigable_id += 1
	n := new(Navigable)
	n.id = next_navigable_id
	n.distance = max(f32)
	navigables[n.id] = n
	navigable_count += 1
	return n
}

@(private)
navigable_free :: proc(n: ^Navigable) {
	delete_key(&navigables, n.id)
	navigable_count -= 1
	delete(n.name)
	delete(n.lazy_url)
	permissions_policy_destroy(&n.allow)
	url.origin_destroy(&n.src_origin)
	free(n)
}

// The parent page's cleanup (its child pages are closed already: their scopes are children of its scope).
@(private)
frames_cleanup :: proc(data: rawptr) {
	p := (^Page)(data)
	f := p.frames
	if f == nil { return }
	ports_page_closed(p)   // the MessagePort ends it owns (ports.odin)
	for len(f.children) > 0 { frame_destroy(f.children[len(f.children) - 1]) }
	delete(f.children)
	if f.owns_nav && f.nav != nil { navigable_free(f.nav) }
	permissions_policy_destroy(&f.declared)
	delete(f.fallback_base)
	if f.ready_poll != base.NIL_HANDLE { host.clear_timer(p.loop, f.ready_poll) }
	free(f)
	p.frames = nil
}

// The top-level page of a document's tree of navigables.
page_top :: proc(p: ^Page) -> ^Page {
	cur := p
	for cur.frames != nil && cur.frames.nav != nil && cur.frames.nav.parent != nil { cur = cur.frames.nav.parent }
	return cur
}

// How deep a document is nested (0 for a tab's).
page_depth :: proc(p: ^Page) -> int {
	d := 0
	for cur := p; cur.frames != nil && cur.frames.nav != nil && cur.frames.nav.parent != nil; cur = cur.frames.nav.parent { d += 1 }
	return d
}

// The document's sandboxing (none for a tab's document).
page_sandbox :: proc(p: ^Page) -> Sandbox { return p.frames != nil ? p.frames.sandbox : {} }

// Is this policy-controlled feature enabled in the document (Permissions Policy)?
feature_enabled :: proc(p: ^Page, f: Feature) -> bool {
	if p.frames == nil { return true }   // a top-level document without a declared policy: every default holds
	return f in p.frames.features
}

// The key of the document's Web Storage (temp): its origin, followed by "^" and the top-level site when it is a frame
// whose site is not the tab's (frames.storage_partitioning, Chromium's and Firefox's storage partitioning).
storage_origin_key :: proc(p: ^Page) -> string {
	origin := url.origin_serialize(p.env.origin, context.temp_allocator)
	if !p.settings.frames.storage_partition || p.frames == nil || p.frames.nav == nil || p.frames.nav.parent == nil { return origin }
	if url.same_site(p.env.site, p.env.top_level_site) { return origin }
	top := p.env.top_level_site
	if top.opaque { return strings.concatenate({origin, "^null"}, context.temp_allocator) }
	return strings.concatenate({origin, "^", top.scheme, "://", top.domain}, context.temp_allocator)
}

////////////////////////////////
// Containers: insertion, removal, attributes

@(private)
is_frame_container :: proc(n: ^dom.Node) -> (Container_Kind, bool) {
	if n == nil || n.kind != .Element || n.ns != .HTML { return {}, false }
	switch n.name {
	case "iframe": return .Iframe, true
	case "frame": return .Frame, true
	}
	return {}, false
}

@(private)
frames_on :: proc(p: ^Page) -> bool { return p.worker == nil && !p.closed && p.settings.frames.enabled }

// A node was inserted into the document: the frame elements of its subtree that are now connected get their
// navigable (HTML "node is inserted into a document").
frames_note_inserted :: proc(p: ^Page, node: base.Handle) {
	if !frames_on(p) { return }
	d := p.doc
	n := dom.get(d, node)
	if n == nil || (n.kind != .Element && n.kind != .Document && n.kind != .Fragment) { return }
	if !dom.is_connected(d, node) { return }
	// the subtree, shadow trees included, in tree order
	found := make([dynamic]base.Handle, context.temp_allocator)
	for cur := node; cur != base.NIL_HANDLE; cur = dom.next_shadow_including(d, cur, node) {
		if _, ok := is_frame_container(dom.get(d, cur)); ok { append(&found, cur) }
	}
	for el in found {
		if p.closed { return }
		if frame_of_element(p, el) != nil || !dom.is_connected(p.doc, el) { continue }
		frame_create(p, el)
	}
}

// Every frame element of the document (a document adopted without scripts, whose insertions no hook saw).
frames_scan :: proc(p: ^Page) {
	if !frames_on(p) { return }
	frames_note_inserted(p, p.doc.root)
}

// A node left the tree: the navigables whose container is no longer connected are destroyed.
frames_note_removed :: proc(p: ^Page) {
	f := p.frames
	if f == nil || len(f.children) == 0 { return }
	for i := len(f.children) - 1; i >= 0; i -= 1 {
		if i >= len(f.children) { continue }
		n := f.children[i]
		if dom.get(p.doc, n.element) == nil || !dom.is_connected(p.doc, n.element) { frame_destroy(n) }
	}
}

// An attribute of an element changed: a frame's src / srcdoc navigates it, name renames it.
frames_note_attribute :: proc(p: ^Page, el: base.Handle, name: string) {
	if p.frames == nil { return }
	n := frame_of_element(p, el)
	if n == nil { return }
	switch name {
	case "src", "srcdoc":
		// (removing srcdoc falls back to src; changing src while srcdoc is there does nothing)
		if name == "src" { if _, has := dom.get_attribute(p.doc, el, "srcdoc"); has && n.kind == .Iframe { return } }
		frame_process_attributes(n, initial = false)
	case "name":
		v, _ := dom.get_attribute(p.doc, el, "name")
		delete(n.name)
		n.name = strings.clone(v)
	}
}

// The navigable of a frame element of this document (nil: none).
frame_of_element :: proc(p: ^Page, el: base.Handle) -> ^Navigable {
	if p.frames == nil { return nil }
	for n in p.frames.children { if n.element == el { return n } }
	return nil
}

// The child navigables in tree order of their containers (window[i], window.length).
frames_children :: proc(p: ^Page) -> []^Navigable {
	f := p.frames
	if f == nil { return nil }
	frames_note_removed(p)
	if f.order_version != p.doc.tree_version && len(f.children) > 1 {
		pos := make(map[base.Handle]int, len(f.children), context.temp_allocator)
		i := 0
		for cur := p.doc.root; cur != base.NIL_HANDLE; cur = dom.next_shadow_including(p.doc, cur, p.doc.root) {
			if _, ok := is_frame_container(dom.get(p.doc, cur)); ok { pos[cur] = i }
			i += 1
		}
		for a in 1 ..< len(f.children) {
			for b := a; b > 0 && pos[f.children[b].element] < pos[f.children[b - 1].element]; b -= 1 {
				f.children[b], f.children[b - 1] = f.children[b - 1], f.children[b]
			}
		}
	}
	f.order_version = p.doc.tree_version
	return f.children[:]
}

@(private)
frame_create :: proc(p: ^Page, el: base.Handle) {
	s := &p.settings.frames
	f := frames_of(p)
	if len(f.children) >= s.max_per_page || navigable_count >= s.max_total {
		log(p, .Warn, "frames: too many nested documents (frames.max_per_page / frames.max_total): this frame stays empty")
		return
	}
	if page_depth(p) + 1 > s.max_depth {
		log(p, .Warn, "frames: nested too deep (frames.max_depth): this frame stays empty")
		return
	}
	kind, _ := is_frame_container(dom.get(p.doc, el))
	n := navigable_new()
	n.parent = p
	n.element = el
	n.kind = kind
	if v, ok := dom.get_attribute(p.doc, el, "name"); ok { n.name = strings.clone(v) }
	append(&f.children, n)
	f.order_version = 0
	frame_snapshot_container(n)
	// the initial about:blank document, made at once: contentWindow exists as soon as the element is connected
	frame_install_page(n, "about:blank", .Inherit)
	if n.page == nil || p.closed { return }
	frame_process_attributes(n, initial = true)
}

// Destroys a navigable and its documents (the container was removed, or its document closes).
frame_destroy :: proc(n: ^Navigable) {
	p := n.parent
	if p != nil && p.frames != nil {
		for c, i in p.frames.children { if c == n { ordered_remove(&p.frames.children, i); break } }
	}
	frame_load_cancel(n)
	if c := n.page; c != nil {
		n.page = nil
		base.forget_cleanup(c.scope, n.cleanup)
		page_close(c)
	}
	navigable_free(n)
}

// The sandbox and allow attributes are read when a navigation starts (HTML: changing them affects the next one).
@(private)
frame_snapshot_container :: proc(n: ^Navigable) {
	p := n.parent
	d := p.doc
	n.sandbox = {}
	if v, ok := dom.get_attribute(d, n.element, "sandbox"); ok && n.kind == .Iframe { n.sandbox = sandbox_parse(v) }
	permissions_policy_destroy(&n.allow)
	if n.kind == .Iframe {
		allow, _ := dom.get_attribute(d, n.element, "allow")
		_, fs := dom.get_attribute(d, n.element, "allowfullscreen")
		n.allow = parse_allow_attribute(allow, fs)
	}
}

////////////////////////////////
// Navigation

// HTML "process the iframe attributes" (and the frame element's equivalent).
@(private)
frame_process_attributes :: proc(n: ^Navigable, initial: bool) {
	p := n.parent
	d := p.doc
	el := n.element
	frame_snapshot_container(n)
	if n.kind == .Iframe {
		if srcdoc, has := dom.get_attribute(d, el, "srcdoc"); has {
			frame_navigate_srcdoc(n, srcdoc)
			return
		}
	}
	src, _ := dom.get_attribute(d, el, "src")
	target: url.URL
	ok := false
	if strings.trim_space(src) != "" {
		target, ok = url.parse(src, nil, context.temp_allocator)
		if !ok {
			base_href := document_base_url(p)
			bu, bok := url.parse(base_href, nil, context.temp_allocator)
			if bok { target, ok = url.parse(src, &bu, context.temp_allocator) }
		}
	}
	if !ok {
		// no src (or an invalid one): the initial about:blank stays; its load event fires now on first insertion
		if initial { frame_load_event_now(n) } else { frame_navigate(n, "about:blank") }
		return
	}
	if target.href == "about:blank" && initial {
		frame_load_event_now(n)
		return
	}
	if initial && n.kind == .Iframe && frame_hooks.attached != nil {
		if v, has := dom.get_attribute(d, el, "loading"); has && strings.equal_fold(strings.trim_space(v), "lazy") && n.distance > p.settings.frames.lazy_margin_px {
			n.lazy_wait = true
			delete(n.lazy_url)
			n.lazy_url = strings.clone(target.href)
			return
		}
	}
	frame_navigate(n, target.href)
}

// HTML "iframe load event steps", run synchronously on first insertion of a frame without a document to load.
@(private)
frame_load_event_now :: proc(n: ^Navigable) {
	p := n.parent
	if c := n.page; c != nil { frames_of(c).complete = true }
	dispatch_event(p, n.element, dom.Event{type = "load"})
}

// The embedder says how far (CSS px) a frame element is from the viewport: a lazy frame that comes close loads.
frames_set_distance :: proc(p: ^Page, el: base.Handle, distance: f32) {
	n := frame_of_element(p, el)
	if n == nil { return }
	n.distance = distance
	if n.lazy_wait && distance <= p.settings.frames.lazy_margin_px {
		n.lazy_wait = false
		u := strings.clone(n.lazy_url, context.temp_allocator)
		frame_navigate(n, u)
	}
}

Frame_Load :: struct {
	nav:       ^Navigable,
	task:      base.Handle,
	url:       string,   // owned: the request's URL
	final_url: string,   // owned
	status:    int,
	mime:      string,   // owned (essence)
	charset:   string,   // owned
	page:      ^Page,    // the new document, once the response is in
	disposition: string, // owned: Content-Disposition
}

@(private)
frame_load_free :: proc(l: ^Frame_Load) {
	delete(l.url); delete(l.final_url); delete(l.mime); delete(l.charset); delete(l.disposition)
	free(l)
}

@(private)
frame_load_cancel :: proc(n: ^Navigable) {
	l := n.load
	if l == nil { return }
	n.load = nil
	if l.task != base.NIL_HANDLE && n.parent != nil && !n.parent.closed { fetch.cancel(n.parent.loader, l.task) }
	frame_load_free(l)
}

// Navigates a frame to `href` (absolute). Fragments of the same document stay in it; javascript: runs in the current
// document; about:blank is made at once; anything else is fetched.
frame_navigate :: proc(n: ^Navigable, href: string, replace := false, method := "", body: []byte = nil, content_type := "") {
	p := n.parent
	if p == nil || p.closed { return }
	target, ok := url.parse(href, nil, context.temp_allocator)
	if !ok { return }
	n.lazy_wait = false
	if cur := n.page; cur != nil {
		if target.scheme == "javascript" { follow_javascript_url(cur, target); return }
		if target.has_fragment && url.without_fragment(target) == url.without_fragment(cur.env.location) && cur.env.location.href != "about:blank" {
			navigate_fragment(cur, target, replace)
			return
		}
	}
	frame_load_cancel(n)
	n.navigations += 1
	url.origin_destroy(&n.src_origin)
	n.src_origin = url.origin_of(target)
	if target.href == "about:blank" {
		c := frame_install_page(n, "about:blank", .Inherit)
		if c != nil { frame_document_ready(c) }
		return
	}
	// a document may not contain itself (HTML: an ancestor with the same URL, fragments aside)
	for cur := p; cur != nil; {
		if url.without_fragment(cur.env.location) == url.without_fragment(target) && target.scheme != "about" {
			log(p, .Warn, fmt.tprintf("frames: %s is not loaded in a frame of itself (recursive frames)", target.href))
			return
		}
		cur = cur.frames != nil && cur.frames.nav != nil ? cur.frames.nav.parent : nil
	}
	l := new(Frame_Load)
	l.nav = n
	l.url = strings.clone(target.href)
	n.load = l
	n.delaying = true
	rp := fetch.Referrer_Policy.Default
	if v, has := dom.get_attribute(p.doc, n.element, "referrerpolicy"); has { rp = fetch.parse_referrer_policy(v) }
	headers: []fetch.Header_Pair
	if content_type != "" { headers = {{"Content-Type", content_type}} }
	l.task = fetch.start(p.loader, {
		request = {url = target.href, mode = .Navigate, credentials = .Include, redirect = .Follow, destination = .Iframe,
			initiator = &p.env, referrer_policy = rp, method = method, body = body, headers = headers},
		on_event = frame_fetch_event, user = l, scope = p.scope, collect = true,
	})
}

@(private)
Srcdoc_Task :: struct { nav: u64, gen: u64, html: string }

// srcdoc: a document made of the attribute's markup, URL about:srcdoc, the parent's origin; from a task, as HTML's
// navigation is.
@(private)
frame_navigate_srcdoc :: proc(n: ^Navigable, markup: string) {
	frame_load_cancel(n)
	n.navigations += 1
	n.delaying = true
	url.origin_destroy(&n.src_origin)
	n.src_origin = url.origin_clone(n.parent.env.origin)
	t := new(Srcdoc_Task)
	t^ = Srcdoc_Task{nav = n.id, gen = n.navigations, html = strings.clone(markup)}
	post_page_task(n.parent, proc(pg: ^Page, data: rawptr) {
		t := (^Srcdoc_Task)(data)
		defer { delete(t.html); free(t) }
		if pg == nil { return }
		n := navigable_by_id(t.nav)
		if n == nil || n.navigations != t.gen || n.parent != pg { return }
		c := frame_install_page(n, "about:srcdoc", .Inherit)
		if c == nil { return }
		load_html(c, transmute([]byte)t.html)
		frame_document_adopted(c)
	}, t)
}

@(private)
frame_fetch_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	l := (^Frame_Load)(user)
	n := l.nav
	switch ev.kind {
	case .Response:
		r := ev.response
		l.status = r.status
		l.final_url = strings.clone(r.url)
		if r.has_mime {
			l.mime = strings.clone(http.mime_essence(r.mime))
			if cs, ok := http.mime_param(r.mime, "charset"); ok { l.charset = strings.clone(cs) }
		}
		if v, ok := http.get_header(r.headers, "content-disposition"); ok { l.disposition = strings.clone(v) }
		final, okf := url.parse(r.url, nil, context.temp_allocator)
		if !okf { return }
		if why, embeddable := frame_embedding_allowed(n, final, r.headers); !embeddable {
			p := n.parent
			log(p, .Error, fmt.tprintf("Refused to display '%s' in a frame: %s", r.url, why))
			fetch.cancel(p.loader, l.task)
			l.task = base.NIL_HANDLE
			host_name := final.host != "" ? final.host : r.url
			frame_show_error(n, fmt.tprintf("%s refused to connect.", host_name), why)
			return
		}
		c := frame_install_page(n, r.url, .Own)
		if c == nil { return }
		l.page = c
		csp_h := http.get_all(r.headers, "content-security-policy")
		ro_h := http.get_all(r.headers, "content-security-policy-report-only")
		rp, _ := http.get_header(r.headers, "referrer-policy")
		apply_response_headers(c, csp_h, ro_h, rp)
		frame_apply_permissions_header(c, http.get_all(r.headers, "permissions-policy"))
	case .Data:
	case .Done:
		l.task = base.NIL_HANDLE
		c := l.page
		if c == nil || c.closed || n.page != c { return }
		frame_document_body(n, l, ev.data)
	case .Failed:
		l.task = base.NIL_HANDLE
		if ev.error == .Aborted { return }
		p := n.parent
		log(p, .Error, fmt.tprintf("frame %s: %s", l.url, ev.detail))
		frame_show_error(n, "This content can't be shown.", ev.detail)
	}
}

// X-Frame-Options and frame-ancestors of a nested document's response, against its ancestors' origins.
@(private)
frame_embedding_allowed :: proc(n: ^Navigable, final: url.URL, headers: http.Headers) -> (why: string, ok: bool) {
	p := n.parent
	s := &p.settings.frames
	self := url.origin_of(final, context.temp_allocator)
	ancestors := make([dynamic]url.Origin, context.temp_allocator)
	for cur := p; cur != nil; {
		append(&ancestors, cur.env.origin)
		cur = cur.frames != nil && cur.frames.nav != nil ? cur.frames.nav.parent : nil
	}
	has_fa := false
	if s.frame_ancestors && csp_on(p) {
		list: csp.Policy_List
		defer csp.list_destroy(&list)
		for v in http.get_all(headers, "content-security-policy") { csp.parse_header(&list, v, .Enforce) }
		for v in http.get_all(headers, "content-security-policy-report-only") { csp.parse_header(&list, v, .Report_Only) }
		has_fa = csp.has_directive(&list, "frame-ancestors")
		v := csp.check_frame_ancestors(&list, self, ancestors[:])
		for viol in v.violations { csp_violation(p, viol) }
		if !v.allowed { return "an ancestor violates the Content-Security-Policy directive frame-ancestors", false }
	}
	// an enforced frame-ancestors makes X-Frame-Options irrelevant (CSP 3 §6.4.2)
	if s.x_frame_options && !has_fa {
		if !xfo_allows(http.get_all(headers, "x-frame-options"), self, ancestors[:]) {
			v, _ := http.get_header(headers, "x-frame-options")
			return fmt.tprintf("it set 'X-Frame-Options' to '%s'", strings.to_lower(strings.trim_space(v), context.temp_allocator)), false
		}
	}
	return "", true
}

@(private)
frame_apply_permissions_header :: proc(c: ^Page, values: []string) {
	f := frames_of(c)
	permissions_policy_destroy(&f.declared)
	if len(values) > 0 { f.declared = parse_permissions_policy_header(values) }
	f.features = enabled_features(f.inherited_off, &f.declared, c.env.origin)
}

// Applies the Permissions-Policy header of a tab's document (the shell calls it with its response headers).
apply_permissions_policy :: proc(p: ^Page, values: []string) {
	if len(values) == 0 && p.frames == nil { return }
	frame_apply_permissions_header(p, values)
}

// The body of a nested document's response: HTML is parsed (off the UI thread), text shown as text, an image in a
// document of its own; anything else is not shown (the console says why).
@(private)
frame_document_body :: proc(n: ^Navigable, l: ^Frame_Load, data: []byte) {
	c := l.page
	mime := l.mime
	disp := strings.to_lower(strings.trim_space(l.disposition), context.temp_allocator)
	if strings.has_prefix(disp, "attachment") {
		log(n.parent, .Warn, fmt.tprintf("frame %s: a download (Content-Disposition: attachment) is not shown in a frame", l.final_url))
		frame_document_ready(c)
		frame_load_done(n)
		return
	}
	switch {
	case mime == "" || mime == "text/html" || mime == "application/xhtml+xml":
		parse_document(c, data, l.charset, frame_parsed, n)
	case strings.has_prefix(mime, "text/") || mime == "application/json" || mime == "application/javascript" || strings.has_suffix(mime, "+json") || strings.has_suffix(mime, "+xml") || mime == "application/xml":
		dec := strings.clone(string(data[:min(len(data), 1 << 20)]), context.temp_allocator)
		pre := dom.create_element(c.doc, "pre")
		dom.set_attribute(c.doc, pre, "style", "word-wrap: break-word; white-space: pre-wrap;")
		dom.set_text_content(c.doc, pre, dec)
		dom.append_child(c.doc, c.body, pre)
		render_begin(c)
		frame_document_ready(c)
		frame_load_done(n)
	case strings.has_prefix(mime, "image/"):
		img := dom.create_element(c.doc, "img")
		dom.set_attribute(c.doc, img, "src", l.final_url)
		dom.set_attribute(c.doc, img, "style", "display: block; max-width: 100%; margin: auto;")
		dom.append_child(c.doc, c.body, img)
		render_begin(c)
		frame_document_ready(c)
		frame_load_done(n)
	case:
		log(n.parent, .Warn, fmt.tprintf("frame %s: a document of type %s is not shown in a frame", l.final_url, mime))
		render_begin(c)
		frame_document_ready(c)
		frame_load_done(n)
	}
}

@(private)
frame_parsed :: proc(c: ^Page, user: rawptr, d: ^Parsed_Document) {
	n := (^Navigable)(user)
	if n.page != c { return }
	if !d.decoded { log(c, .Error, "frame: its text could not be decoded") }
	adopt_document(c, d)
	if !c.render.adopted { render_begin(c) }
	frame_load_done(n)
	frame_document_adopted(c)
}

// The navigation's request is over (the document is in, or could not be).
@(private)
frame_load_done :: proc(n: ^Navigable) {
	if l := n.load; l != nil && l.task == base.NIL_HANDLE {
		n.load = nil
		frame_load_free(l)
	}
}

// A nested document was adopted (parsed, srcdoc, error page): its scripts start; one without scripts finds its own
// frames and completes once its resources are in.
@(private)
frame_document_adopted :: proc(c: ^Page) {
	scripts_start(c)   // (a document without scripts: frames_scan and frame_document_ready from there)
}

// A document whose scripts do not run: its frames are found now, and it is complete when its resources are in (images,
// stylesheets, fonts: what delays a load event), polled.
frame_document_ready :: proc(c: ^Page) {
	if c.closed { return }
	f := frames_of(c)
	if f.complete || f.ready_poll != base.NIL_HANDLE { return }
	frames_scan(c)
	frame_ready_check(c)
}

@(private)
frame_ready_check :: proc(c: ^Page) {
	f := c.frames
	f.ready_poll = base.NIL_HANDLE
	if f.complete || c.closed { return }
	if resources_delay_load(c) || frames_delay_load(c) {
		f.ready_poll = host.set_timer(c.loop, c.settings.js_load.poll_ms, 0, proc(data: rawptr) { frame_ready_check((^Page)(data)) }, c, c.scope)
		return
	}
	frames_document_complete(c)
}

// The document's load is complete (after its window's load event): its container gets "load" (a task of the parent),
// and the parent's own load event no longer waits for it.
frames_document_complete :: proc(c: ^Page) {
	if c.frames == nil { return }
	f := c.frames
	f.complete = true
	n := f.nav
	if n == nil || n.parent == nil || n.page != c { return }
	n.delaying = false
	p := n.parent
	if dom.get(p.doc, n.element) != nil { queue_element_event(p, n.element, "load") }
}

// Does the parent's load event still wait for one of its frames?
frames_delay_load :: proc(p: ^Page) -> bool {
	f := p.frames
	if f == nil { return false }
	for n in f.children {
		if n.delaying && !n.lazy_wait && n.page != nil { return true }
	}
	return false
}

// A frame that cannot show its document: Chromium's short explanation (opaque origin, no scripts), and the
// container's load event.
@(private)
frame_show_error :: proc(n: ^Navigable, headline, detail: string) {
	p := n.parent
	c := frame_install_page(n, "about:blank", .Opaque)
	if c == nil { return }
	frames_of(c).sandbox = Sandbox{active = true}   // nothing runs in it
	if p.settings.frames.error_pages {
		// (concatenated: fmt reads braces as its own)
		html := strings.concatenate({`<!doctype html><html><head><meta charset="utf-8"><style>html{background:#f2f2f2;color:#5f6368;font:13px system-ui,sans-serif}body{margin:0;display:flex;align-items:center;justify-content:center;min-height:100vh;text-align:center}p{margin:8px 16px}.h{font-size:15px;color:#202124}</style></head><body><div><p class="h">`,
			escape_text(headline), `</p><p>`, escape_text(detail), `</p></div></body></html>`}, context.temp_allocator)
		load_html(c, transmute([]byte)html)
	}
	render_begin(c)
	frame_load_done(n)
	frame_document_ready(c)
}

@(private)
escape_text :: proc(s: string) -> string {
	r, _ := strings.replace_all(s, "&", "&amp;", context.temp_allocator)
	r, _ = strings.replace_all(r, "<", "&lt;", context.temp_allocator)
	r, _ = strings.replace_all(r, ">", "&gt;", context.temp_allocator)
	return r
}

////////////////////////////////
// Documents of a navigable

Origin_Mode :: enum u8 {
	Own,       // the document's URL's origin (a fetched document; data: is opaque)
	Inherit,   // the parent's (about:blank, about:srcdoc)
	Opaque,    // a fresh opaque origin (error pages)
}

// Makes the navigable's next document (closing the current one): its origin, sandboxing, policies and embedder.
@(private)
frame_install_page :: proc(n: ^Navigable, href: string, mode: Origin_Mode) -> ^Page {
	p := n.parent
	if p == nil || p.closed { return nil }
	c := page_create(p.loop, p.loader, p.settings, p.scope, href, p.console != nil ? frame_console : nil, n)
	cf := frames_of(c)
	cf.nav = n
	cf.sandbox = sandbox_combine(page_sandbox(p), n.sandbox)
	switch mode {
	case .Own:
	case .Inherit: env_set_origin(&c.env, url.origin_clone(p.env.origin))
	case .Opaque: env_set_origin(&c.env, url.new_opaque_origin())
	}
	if cf.sandbox.active && .Same_Origin not_in cf.sandbox.allow { env_set_origin(&c.env, url.new_opaque_origin()) }
	top := page_top(p)
	url.site_destroy(&c.env.top_level_site)
	c.env.top_level_site = url.site_of(top.env.origin)
	c.env.secure_context = c.env.secure_context && p.env.secure_context
	if mode == .Inherit {
		c.env.referrer_policy = p.env.referrer_policy
		cf.fallback_base = strings.clone(document_base_url(p))
	}
	// Permissions Policy: what the container delegates
	pf := frames_of(p)
	cf.inherited_off = inherited_disabled(pf.features, p.env.origin, &n.allow, c.env.origin, n.src_origin)
	cf.features = enabled_features(cf.inherited_off, nil, c.env.origin)
	pe := p.web.embedder
	set_embedder(c, Embedder{navigate = frame_navigate_hook, user = n, tab_key = pe.tab_key, storage = pe.storage})
	old := n.page
	n.page = c
	if old != nil {
		base.forget_cleanup(old.scope, n.cleanup)
		page_close(old)
	}
	n.cleanup = base.on_close(c.scope, proc(data: rawptr) {
		// the document closed on its own (its scope with the parent's: the navigable goes with the parent anyway)
		n := (^Navigable)(data)
		n.page = nil
	}, n)
	if frame_hooks.attached != nil { frame_hooks.attached(frame_hooks.user, c) }
	return c
}

// A nested document's console is its tab's, each message prefixed with the frame's URL.
@(private)
frame_console :: proc(user: rawptr, level: Log_Level, message: string) {
	n := (^Navigable)(user)
	p := n.parent
	if p == nil || p.closed || p.console == nil { return }
	from := n.page != nil ? n.page.env.location.href : "frame"
	if len(from) > 120 { from = from[:120] }
	p.console(p.console_user, level, strings.concatenate({"[frame ", from, "] ", message}, context.temp_allocator))
}

@(private)
env_set_origin :: proc(e: ^fetch.Environment, o: url.Origin) {
	url.origin_destroy(&e.origin)
	url.site_destroy(&e.site)
	e.origin = o
	e.site = url.site_of(e.origin)
}

// What a nested document's script asks of its own navigable (location, reload, history).
@(private)
frame_navigate_hook :: proc(user: rawptr, p: ^Page, req: Navigate_Request) {
	n := (^Navigable)(user)
	if n.page != p { return }
	switch req.kind {
	case .Assign: frame_navigate(n, req.url)
	case .Replace: frame_navigate(n, req.url, replace = true)
	case .Reload: frame_navigate(n, p.env.location.href)
	case .Traverse: log(p, .Warn, "frames: history traversal across the documents of a frame is not supported")
	case .Url_Changed:
	}
}

// The document's base URL fallback for about:blank and about:srcdoc documents: their parent's base URL.
frame_fallback_base :: proc(p: ^Page) -> string {
	if p.frames == nil || p.frames.fallback_base == "" { return "" }
	scheme := p.env.location.scheme
	if scheme != "about" { return "" }
	return p.frames.fallback_base
}

////////////////////////////////
// Between navigables (window.parent, frames[i], postMessage, location of another window)

// Whether `src` may navigate `target` (HTML "allowed to navigate", with the sandbox's rules and Chromium's
// framebusting intervention: a cross-origin frame does not navigate its top without user activation). Why not, else "".
navigation_allowed :: proc(src: ^Page, target: ^Navigable) -> string {
	sn := page_navigable(src)
	if sn == nil || target == nil { return "no browsing context" }
	if sn == target { return "" }
	// an ancestor may navigate its descendants
	for cur := target.parent; cur != nil; {
		if cur == src { return "" }
		cur = cur.frames != nil && cur.frames.nav != nil ? cur.frames.nav.parent : nil
	}
	sb := page_sandbox(src)
	top := page_navigable(page_top(src))
	if target == top {
		if sb.active && .Top_Navigation not_in sb.allow && !(.Top_Navigation_By_User_Activation in sb.allow && webauthn_has_activation(src)) {
			return "the frame is sandboxed without allow-top-navigation"
		}
		if tp := target.page; tp != nil && !url.same_origin(src.env.origin, tp.env.origin) && !webauthn_has_activation(src) {
			return "a cross-origin frame may navigate the top level only after a user gesture"
		}
		return ""
	}
	if sb.active { return "a sandboxed frame may only navigate itself and its descendants" }
	// another frame: when the source is same origin with the target's parent document ("familiar with")
	if target.parent != nil && url.same_origin(src.env.origin, target.parent.env.origin) { return "" }
	return "the frame is not allowed to navigate this browsing context"
}

// Navigates another navigable on behalf of `src` (window.location of a WindowProxy, window.open to a frame name).
frames_navigate_from :: proc(src: ^Page, target: ^Navigable, href: string, replace: bool, method := "", body: []byte = nil, content_type := "") -> (why: string) {
	if w := navigation_allowed(src, target); w != "" { return w }
	u, ok := url.parse(href, &src.env.location, context.temp_allocator)
	if !ok { return "invalid URL" }
	if target.parent == nil {
		// a tab's document: its embedder navigates the tab (a POST to the top level is the shell's: forms_shell.odin)
		if tp := target.page; tp != nil { request_navigation(tp, replace ? .Replace : .Assign, u.href) }
		return ""
	}
	h := strings.clone(u.href, context.temp_allocator)
	frame_navigate(target, h, replace, method, body, content_type)
	return ""
}

// The navigable a target name designates for `src` (HTML "the rules for choosing a navigable"): "_self", "_parent",
// "_top", "" (self), or the name of a frame anywhere in the tab. nil: none (a new window would be opened).
frames_find_target :: proc(src: ^Page, name: string) -> ^Navigable {
	sn := page_navigable(src)
	if sn == nil { return nil }
	switch strings.to_lower(name, context.temp_allocator) {
	case "", "_self": return sn
	case "_parent": return sn.parent != nil ? page_navigable(sn.parent) : sn
	case "_top": return page_navigable(page_top(src))
	case "_blank": return nil
	}
	// a named frame: the source's descendants first, then the whole tab
	if n := find_named_below(src, name); n != nil { return n }
	return find_named_below(page_top(src), name)
}

@(private)
find_named_below :: proc(p: ^Page, name: string) -> ^Navigable {
	if p == nil || p.frames == nil { return nil }
	for c in frames_children(p) {
		if c.name == name { return c }
		if c.page != nil { if r := find_named_below(c.page, name); r != nil { return r } }
	}
	return nil
}

@(private)
Message_Task :: struct {
	target:  u64,      // navigable
	doc:     u64,      // the target's document when posted (a message for a document that is gone is dropped)
	source:  u64,      // navigable of the sender
	origin:  string,   // the sender's origin, serialized
	data:    []byte,   // structured serialization
	ports:   []u64,    // MessagePort ends travelling with it (ports.odin)
}

// window.postMessage to another window: the target's document must still be the same at delivery, and its origin
// must match targetOrigin ("*" anything, "/" the sender's own); a mismatch drops the message silently, as HTML says.
frames_post_message :: proc(src: ^Page, target: ^Navigable, data: []byte, target_origin: string, ports: []u64 = nil) -> (Api_Error, string) {
	sent := false
	defer if !sent { for x in ports { port_close_end(x) } }   // a dropped message's ports are closed
	if len(data) > src.settings.frames.max_message_bytes { return .Data_Clone, "DataCloneError: the message is larger than frames.max_message_bytes" }
	tp := target.page
	if tp == nil || tp.closed { return .None, "" }
	switch target_origin {
	case "*":
	case "/":
		if !url.same_origin(src.env.origin, tp.env.origin) { return .None, "" }
	case:
		u, ok := url.parse(target_origin, nil, context.temp_allocator)
		if !ok { return .Syntax, "SyntaxError: Failed to execute 'postMessage' on 'Window': Invalid target origin." }
		o := url.origin_of(u, context.temp_allocator)
		if !url.same_origin(o, tp.env.origin) {
			log(src, .Warn, fmt.tprintf("Failed to execute 'postMessage' on 'DOMWindow': The target origin provided ('%s') does not match the recipient window's origin ('%s').", target_origin, url.origin_serialize(tp.env.origin, context.temp_allocator)))
			return .None, ""
		}
	}
	sn := page_navigable(src)
	t := new(Message_Task)
	t^ = Message_Task{target = target.id, doc = page_id(tp), source = sn != nil ? sn.id : 0, origin = url.origin_serialize(src.env.origin)}
	t.data = make([]byte, len(data))
	copy(t.data, data)
	t.ports = make([]u64, len(ports))
	copy(t.ports, ports)
	sent = true
	post_page_task(tp, proc(pg: ^Page, d: rawptr) {
		t := (^Message_Task)(d)
		defer { delete(t.origin); delete(t.data); delete(t.ports); free(t) }
		if pg == nil || pg.closed || page_id(pg) != t.doc { for x in t.ports { port_close_end(x) }; return }
		js_frames_deliver(pg, t.data, t.origin, t.source, t.ports)
	}, t)
	return .None, ""
}
