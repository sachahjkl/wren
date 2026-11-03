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
//     (feature_enabled). Each document has its engine instance. Across origins what crosses is messages (postMessage)
//     and navigations, both as tasks; between documents of one origin a realm reaches the other's nodes
//     (frames_access.odin), with the origin checked on each call.
//   * Embedding: the shell lays out and paints each child document in its container's content box (frame_hooks),
//     routes input to it by hit testing and reports how far a lazy frame is from the viewport.
//
// Session history: a navigable keeps its entries across its documents (Navigable.session: navigation.entries()); a push in
// a frame is also a step of its tab's joint session history, which history.length counts and traversals move through
// (history_joint.odin).

import "core:fmt"
import "core:strings"
import "core:sync"
import "wb:base"
import "wb:csp"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:html"
import "wb:http"
import "wb:style"
import "wb:url"

// How much of a text resource a frame shows in its <pre>.
FRAME_TEXT_DOCUMENT_MAX_BYTES :: 1 << 20
// How much of a frame's URL prefixes its console messages.
FRAME_CONSOLE_URL_MAX :: 120
FRAME_SRCDOC_URL :: "about:srcdoc"
HTTP_NO_CONTENT :: 204     // a navigation's response of these: no document comes of it, the frame keeps the one it has
HTTP_RESET_CONTENT :: 205

// What the embedder (the shell) does with nested documents. All optional.
Frame_Hooks :: struct {
	user:     rawptr,
	// A document was made for a navigable (its initial about:blank, then one per navigation): connect it (layout,
	// geometry for scripts). `child.frames.nav` is its navigable.
	attached: proc(user: rawptr, child: ^Page),
}


Container_Kind :: enum u8 { Iframe, Frame }

Navigable :: struct {
	id:          u64,
	page:        ^Page,          // the active document; nil only while it is replaced or destroyed
	parent:      ^Page,          // the container's document; nil for a top-level navigable
	element:     base.Handle,    // the container in parent.doc
	kind:        Container_Kind,
	name:        string,         // owned: window.name, the target name of links and forms
	sandbox:     Sandbox,        // the container's sandbox attribute as of the last navigation; a window's: its opener's sandboxing (auxiliary.odin)
	allow:      Permissions_Policy,   // the container's allow attribute as of the last navigation
	required_csp: string,        // owned: the policy its documents must take (frames_csp.odin), as of the last navigation; "" none
	navigator:   u64,            // a window's: the navigable of the sandboxed document that opened it, which may navigate it; 0 none
	src_origin:  url.Origin,     // owned: the origin of the container's src at the last navigation ('src' allowlists)
	load:        ^Frame_Load,    // the navigation in flight
	delaying:    bool,           // the parent's load event waits for this document
	lazy_wait:   bool,           // loading=lazy: waits for the embedder to say it is near the viewport
	lazy_url:    string,         // owned
	distance:    f32,            // CSS px from the viewport, as the embedder last said (max: unknown)
	cleanup:     base.Cleanup_Id,   // on page's scope: forgets the page when it closes
	navigations: u64,
	requests:    u64,            // navigations its documents asked for (bindings_history.odin: the last one wins)
	history_calls: int,          // history.go() in the window that began at history_window_ns (history_rate_limited)
	history_window_ns: i64,
	session:     Session_History,   // its entries, across its documents (a nested navigable's; a tab's is the shell's)
	path:        string,         // owned: its container's element path when it was made (a frame kept by the joint history finds its container again)
	initial:     bool,           // still on its initial about:blank: the next navigation replaces it
	activated:   bool,           // a navigation brought its document (navigation.activation)
	activated_by: Nav_Type,
	activated_from: u64,         // the entry it came from (0: none the API shows)
	// a top-level navigable's (auxiliary.odin):
	opener:      u64,            // the navigable whose document opened it (window.opener); 0: none, or severed
	group:       u64,            // its browsing context group: the windows it finds by name and reaches
	coop:        Opener_Policy,  // the opener policy of its active document (an initial about:blank's: its opener's)
	coop_origin: url.Origin,     // owned: that document's origin
	script_opened: bool,         // made by window.open or a link: its scripts may close it
	closing:     bool,           // window.close() was called: closed for scripts, its embedder closes it in a task
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

// The navigables of the thread's pages: an App runs its pages on the thread of its loop (docs/architecture.md, Where state lives).
@(private, thread_local)
navigables: map[u64]^Navigable
@(private)
next_navigable_id: u64   // (atomic: an id is unique in the process)
@(private, thread_local)
navigable_count: int

// The end of the pages of this thread (an App's, at its end; pages_shutdown): the registry of navigables (empty once every page is closed).
frames_shutdown :: proc() {
	shared_workers_shutdown()   // (lingering ones: extendedLifetime)
	ports_shutdown()
	delete(frames_pending_closes)
	frames_pending_closes = nil
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
	if p == nil || p.worker != nil || p.closed || p.close_pending { return nil }
	f := frames_of(p)
	if f.nav != nil { return f.nav }
	n := navigable_new()
	n.page = p
	n.group = n.id
	f.nav = n
	f.owns_nav = true
	return n
}

@(private)
navigable_new :: proc() -> ^Navigable {
	if navigables == nil { navigables = make(map[u64]^Navigable) }
	n := new(Navigable)
	n.id = sync.atomic_add(&next_navigable_id, 1) + 1
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
	delete(n.path)
	delete(n.lazy_url)
	delete(n.required_csp)
	permissions_policy_destroy(&n.allow)
	url.origin_destroy(&n.src_origin)
	url.origin_destroy(&n.coop_origin)
	session_destroy(&n.session)
	free(n)
}

// The parent page's cleanup (its child pages are closed already: their scopes are children of its scope).
@(private)
frames_cleanup :: proc(data: rawptr) {
	p := (^Page)(data)
	f := p.frames
	if f == nil { return }
	ports_page_closed(p)   // the MessagePort ends it owns (ports.odin)
	shared_workers_page_closed(p)   // the shared workers it connected to (shared_worker.odin)
	for len(f.children) > 0 { frame_destroy(f.children[len(f.children) - 1]) }
	delete(f.children)
	if f.owns_nav && f.nav != nil {
		navigable_free(f.nav)
	} else if n := f.nav; n != nil && n.parent == nil && n.page == p {
		n.page = nil   // (an embedder's navigable: it shows no document until the embedder gives it the next)
	}
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

// The document's storage key (temp): its origin, followed by "^" and the top-level site when it is a frame whose site
// is not the tab's (storage.partitioned: Chromium's, Firefox's and Safari's storage partitioning), unless the frame
// was granted storage access (document.requestStorageAccess(): storage_access.odin). Every store keys by it: Web
// Storage, IndexedDB, the Cache API, OPFS and buckets, service worker registrations, BroadcastChannel, shared workers.
storage_origin_key :: proc(p: ^Page) -> string {
	framed := p.frames != nil && p.frames.nav != nil && p.frames.nav.parent != nil
	return storage_key_of(p.env.origin, p.env.site, p.env.top_level_site, framed, p.settings.frames.storage_partition, p.env.storage_access)
}

// The storage key of a document of `origin` (site `site`) under top-level site `top` (temp): its origin, unless it is
// a frame of another site with partitioning on and no storage access in use.
storage_key_of :: proc(origin: url.Origin, site, top: url.Site, framed, partitioned: bool, access: fetch.Storage_Access) -> string {
	o := url.origin_serialize(origin, context.temp_allocator)
	if !partitioned || !framed || url.same_site(site, top) || access == .Active { return o }
	return strings.concatenate({o, "^", site_text(top)}, context.temp_allocator)
}

// A site as storage keys write it (temp).
site_text :: proc(s: url.Site) -> string { return fetch.site_partition_text(s) }

// The storage key of any realm: a worker's is its creator's (worker.odin), a document's storage_origin_key.
realm_storage_key :: proc(p: ^Page) -> string {
	if p.worker != nil { return p.worker.storage_key }
	return storage_origin_key(p)
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

// HTML's "document-tree child navigables": those whose container is not in a shadow tree (window[i], window[name],
// window.length; a frame in a shadow tree still has its document and talks with postMessage).
frames_document_tree_children :: proc(p: ^Page) -> []^Navigable {
	kids := frames_children(p)
	if len(p.doc.shadow_roots) == 0 { return kids }
	out := make([dynamic]^Navigable, 0, len(kids), context.temp_allocator)
	for k in kids { if dom.containing_shadow_root(p.doc, k.element) == base.NIL_HANDLE { append(&out, k) } }
	return out[:]
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
	n.path = strings.clone(element_path(p.doc, el))
	append(&f.children, n)
	f.order_version = 0
	frame_snapshot_container(n)
	// the initial about:blank document, made at once: contentWindow exists as soon as the element is connected
	frame_install_page(n, "about:blank", .Inherit)
	if n.page == nil || p.closed { return }
	n.initial = true
	n.activated = false
	// a document loaded again from the session history: the frame shows its entry of the current position (history_joint.odin)
	if joint_restore_frame(n) { return }
	frame_process_attributes(n, initial = true)
}

// Destroys a navigable and its documents (the container was removed, or its document closes).
frame_destroy :: proc(n: ^Navigable) {
	p := n.parent
	if p != nil && p.frames != nil {
		for c, i in p.frames.children { if c == n { ordered_remove(&p.frames.children, i); break } }
	}
	// its document leaves (not its container): the joint history keeps its entries for that document's return
	if p != nil && p.scope.closing { joint_keep_frame(n) }
	frame_load_cancel(n)
	if c := n.page; c != nil {
		if p != nil && !p.closed { navigation_detached(c) }
		n.page = nil
		base.forget_cleanup(c.scope, n.cleanup)
		page_close(c)
	}
	navigable_free(n)
}

// The sandbox, allow and csp attributes are read when a navigation starts (HTML: changing them affects the next one).
@(private)
frame_snapshot_container :: proc(n: ^Navigable) {
	p := n.parent
	d := p.doc
	n.sandbox = {}
	if v, ok := dom.get_attribute(d, n.element, "sandbox"); ok && n.kind == .Iframe { n.sandbox = sandbox_parse(v) }
	required, has := dom.get_attribute(d, n.element, "csp")
	required = frame_required_csp(n, required, has && n.kind == .Iframe)
	if required != n.required_csp {
		delete(n.required_csp)
		n.required_csp = strings.clone(required)
	}
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
frame_process_attributes :: proc(n_in: ^Navigable, initial: bool) {
	n := n_in
	p := n.parent
	d := p.doc
	el := n.element
	frame_snapshot_container(n)
	// (a change of the attributes is a navigation as any other: its navigate event, in the frame's document)
	go_on :: proc(n: ^Navigable, href: string) -> (still: ^Navigable, proceed: bool) {
		u, ok := url.parse(href, nil, context.temp_allocator)
		if !ok || n.page == nil { return n, true }
		id := n.id
		proceed = navigation_begin(n.page, u, false, opts = Nav_Options{cross_origin = !url.same_origin_domain(n.parent.env.origin, n.page.env.origin)})
		still = navigable_by_id(id)
		return still, proceed && still != nil
	}
	if n.kind == .Iframe {
		if srcdoc, has := dom.get_attribute(d, el, "srcdoc"); has {
			markup := strings.clone(srcdoc, context.temp_allocator)
			if !initial {
				proceed: bool
				if n, proceed = go_on(n, FRAME_SRCDOC_URL); !proceed { return }
			}
			frame_navigate_srcdoc(n, markup)
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
		if initial {
			frame_load_event_now(n)
		} else if still, proceed := go_on(n, "about:blank"); proceed {
			frame_navigate(still, "about:blank")
		}
		return
	}
	if target.href == "about:blank" && initial {
		frame_load_event_now(n)
		return
	}
	if initial && n.kind == .Iframe && the_pages.frame_hooks.attached != nil {
		if v, has := dom.get_attribute(d, el, "loading"); has && strings.equal_fold(strings.trim_space(v), "lazy") && n.distance > p.settings.frames.lazy_margin_px {
			n.lazy_wait = true
			delete(n.lazy_url)
			n.lazy_url = strings.clone(target.href)
			return
		}
	}
	if !initial {
		proceed: bool
		if n, proceed = go_on(n, strings.clone(target.href, context.temp_allocator)); !proceed { return }
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
	commit:    Frame_Commit,   // its state owned
}

// What a navigation of a frame does to the frame's session history when its document comes in.
Frame_Commit :: struct {
	type:      Nav_Type,
	entry:     u64,      // Traverse: the entry
	state:     string,   // the Navigation API state of the entry
	has_state: bool,
}

@(private)
frame_load_free :: proc(l: ^Frame_Load) {
	delete(l.url); delete(l.final_url); delete(l.mime); delete(l.charset); delete(l.disposition); delete(l.commit.state)
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
frame_navigate :: proc(n: ^Navigable, href: string, replace := false, method := "", body: []byte = nil, content_type := "", commit: Frame_Commit = {}) {
	p := n.parent
	if p == nil || p.closed { return }
	target, ok := url.parse(href, nil, context.temp_allocator)
	if !ok { return }
	commit := commit
	if replace { commit.type = .Replace }
	n.lazy_wait = false
	if cur := n.page; cur != nil {
		if target.scheme == "javascript" { follow_javascript_url(cur, target); return }
		// (a reload, or a traversal to another document's entry, loads whatever the fragment)
		if commit.type != .Reload && commit.type != .Traverse && target.has_fragment && url.without_fragment(target) == url.without_fragment(cur.env.location) && cur.env.location.href != "about:blank" {
			navigate_fragment(cur, target, replace)
			return
		}
	}
	if target.href == FRAME_SRCDOC_URL {   // (a reload of a srcdoc document, a traversal back to it: the attribute has the markup)
		if srcdoc, has := dom.get_attribute(p.doc, n.element, "srcdoc"); has {
			frame_navigate_srcdoc(n, strings.clone(srcdoc, context.temp_allocator), commit)
			return
		}
	}
	frame_load_cancel(n)
	n.navigations += 1
	url.origin_destroy(&n.src_origin)
	n.src_origin = url.origin_of(target)
	if target.href == "about:blank" {
		c := frame_install_page(n, "about:blank", .Inherit, commit)
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
	l.commit = commit
	l.commit.state = strings.clone(commit.state)
	n.load = l
	n.delaying = true
	rp := fetch.Referrer_Policy.Default
	if v, has := dom.get_attribute(p.doc, n.element, "referrerpolicy"); has { rp = fetch.parse_referrer_policy(v) }
	headers := make([dynamic]fetch.Header_Pair, 0, 2, context.temp_allocator)
	if content_type != "" { append(&headers, fetch.Header_Pair{"Content-Type", content_type}) }
	if n.required_csp != "" && (target.scheme == "http" || target.scheme == "https") { append(&headers, fetch.Header_Pair{REQUIRED_CSP_HEADER, n.required_csp}) }
	l.task = fetch.start(p.loader, {
		request = {url = target.href, mode = .Navigate, credentials = .Include, redirect = .Follow, destination = n.kind == .Frame ? .Frame : .Iframe,
			initiator = &p.env, referrer_policy = rp, method = method, body = body, headers = headers[:]},
		on_event = frame_fetch_event, user = l, scope = p.scope, collect = true,
	})
}

@(private)
Srcdoc_Task :: struct { nav: u64, gen: u64, html: string, commit: Frame_Commit }

// srcdoc: a document made of the attribute's markup, URL about:srcdoc, the parent's origin; from a task, as HTML's
// navigation is.
@(private)
frame_navigate_srcdoc :: proc(n: ^Navigable, markup: string, commit: Frame_Commit = {}) {
	frame_load_cancel(n)
	n.navigations += 1
	n.delaying = true
	url.origin_destroy(&n.src_origin)
	n.src_origin = url.origin_clone(n.parent.env.origin)
	t := new(Srcdoc_Task)
	t^ = Srcdoc_Task{nav = n.id, gen = n.navigations, html = strings.clone(markup), commit = commit}
	t.commit.state = strings.clone(commit.state)
	post_page_task(n.parent, proc(pg: ^Page, data: rawptr) {
		t := (^Srcdoc_Task)(data)
		defer { delete(t.html); delete(t.commit.state); free(t) }
		if pg == nil { return }
		n := navigable_by_id(t.nav)
		if n == nil || n.navigations != t.gen || n.parent != pg { return }
		c := frame_install_page(n, FRAME_SRCDOC_URL, .Inherit, t.commit)
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
		required := required_csp_verdict(n, final, r.headers)
		if required == .Refused {
			p := n.parent
			why := "it does not take the Content-Security-Policy its frame requires (csp attribute): no Allow-CSP-From, no policy of its own as strict"
			log(p, .Error, fmt.tprintf("Refused to display '%s' in a frame: %s", r.url, why))
			fetch.cancel(p.loader, l.task)
			l.task = base.NIL_HANDLE
			frame_show_error(n, "This content can't be shown.", why)
			return
		}
		// HTML "navigate": no document comes of these, the frame keeps the one it has
		disposition := strings.to_lower(strings.trim_space(l.disposition), context.temp_allocator)
		if r.status == HTTP_NO_CONTENT || r.status == HTTP_RESET_CONTENT || strings.has_prefix(disposition, "attachment") {
			if strings.has_prefix(disposition, "attachment") { log(n.parent, .Warn, fmt.tprintf("frame %s: a download (Content-Disposition: attachment) is not shown in a frame", r.url)) }
			fetch.cancel(n.parent.loader, l.task)
			l.task = base.NIL_HANDLE
			frame_load_done(n)
			frame_stopped_delaying(n)
			return
		}
		// (a response knows nothing of the fragment of the request)
		href := r.url
		if req, rok := url.parse(l.url, nil, context.temp_allocator); rok && req.has_fragment && !final.has_fragment {
			href = strings.concatenate({r.url, "#", req.fragment}, context.temp_allocator)
		}
		c := frame_install_page(n, href, .Own, l.commit)
		if c == nil { return }
		l.page = c
		csp_h := http.get_all(r.headers, "content-security-policy")
		ro_h := http.get_all(r.headers, "content-security-policy-report-only")
		rp, _ := http.get_header(r.headers, "referrer-policy")
		apply_response_headers(c, csp_h, ro_h, rp)
		if required == .Enforced { frame_enforce_required_csp(n, c) }
		apply_isolation_headers(c, r.headers, n.parent)
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
		if ev.error == .Blocked_By_Client && the_pages.embedder.collapse_blocked {
			log(p, .Warn, fmt.tprintf("frame %s: blocked (%s)", l.url, ev.detail))
			frame_show_error(n, "", "", collapse = true)
			return
		}
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
	// (COEP: a frame's document too must agree to be embedded: its own policy, and what the resource policy asks of a navigation)
	if p.env.embedder_policy == .Require_Corp {
		coep, _ := http.get_header(headers, "cross-origin-embedder-policy")
		if parse_embedder_policy(coep) == .Unsafe_None { return "it has no Cross-Origin-Embedder-Policy, which its parent requires", false }
		if refused := fetch.resource_policy_refuses(p.env.origin, final, p.env.embedder_policy, headers); refused != "" { return refused, false }
	}
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
	switch {
	case mime == "" || mime == "text/html" || xml_document_kind(mime) != .None && !strings.has_prefix(mime, "image/"):
		// HTML, or an XML document (an SVG one is shown as an image)
		parse_document(c, data, l.charset, frame_parsed, n, mime)
	case strings.has_prefix(mime, "text/") || mime == "application/json" || mime == "application/javascript" || strings.has_suffix(mime, "+json"):
		// in the response's charset (or after its byte order mark); without one, JSON is UTF-8, other text as a document
		// that declares none (a frame's parent's encoding)
		bytes := data[:min(len(data), FRAME_TEXT_DOCUMENT_MAX_BYTES)]
		json := mime == "application/json" || mime == "text/json" || strings.has_suffix(mime, "+json")
		decoded, decoded_ok := html.decode_document(bytes, l.charset, json ? "UTF-8" : default_encoding_of(c), allocator = context.temp_allocator, prescan_meta = false)
		dec := decoded_ok ? string(decoded.text) : string(bytes)
		if decoded_ok { c.encoding = html.canonical_encoding(decoded.encoding) }
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

// A navigation that brings no document: the parent's load event does not wait for it, and a frame on its initial about:blank,
// which had nothing else to wait for, has its load event.
@(private)
frame_stopped_delaying :: proc(n: ^Navigable) {
	if !n.delaying { return }
	n.delaying = false
	if n.initial && n.page != nil { frames_document_complete(n.page) }
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
frame_show_error :: proc(n: ^Navigable, headline, detail: string, collapse := false) {
	p := n.parent
	commit := Frame_Commit{type = .Replace}
	if l := n.load; l != nil { commit = l.commit }
	c := frame_install_page(n, "about:blank", .Opaque, commit)
	if c == nil { return }
	frames_of(c).sandbox = Sandbox{active = true}   // nothing runs in it
	// a frame the content blocker stopped leaves no box (embedder.odin)
	if collapse && p.engine != nil { style.engine_set_hidden(p.engine, n.element, true) }
	if p.settings.frames.error_pages && !collapse {
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

// The navigable's session history takes the document that comes: a new entry, the one it replaces, the one it goes back to.
@(private)
frame_session_commit :: proc(n: ^Navigable, href: string, commit: Frame_Commit, max_entries: int) {
	sh := &n.session
	prev := session_current(sh)
	type := commit.type
	// HTML "navigate": a navigation from an initial about:blank, of a document still loading, or to the URL it has replaces
	if type == .Push && prev != nil {
		f := n.page != nil ? n.page.frames : nil
		if n.initial || f == nil || !f.complete || prev.url == href { type = .Replace }
	}
	n.activated, n.activated_by, n.activated_from = true, type, 0
	if type != .Replace && prev != nil { n.activated_from = prev.id }
	switch type {
	case .Push:
		from := session_current_id(sh)
		session_push(sh, href, 0, dedupe = false, max_entries = max_entries)
		session_set_nav_state(sh, commit.state, commit.has_state)
		if from != 0 { joint_note_push(n, sh.current.id, from) }
	case .Replace:
		if prev != nil && n.parent != nil { joint_forget_document(joint_session(n.parent), prev.doc) }   // (another document in the entry: none of the old one's frames comes back)
		session_replace(sh, href)
		session_set_nav_state(sh, commit.state, commit.has_state)
	case .Reload:
		if prev == nil { session_push(sh, href, 0, dedupe = false, max_entries = max_entries); return }
		if prev.url != href { delete(prev.url); prev.url = strings.clone(href); sh.serial += 1 }   // (a redirect: the same entry, key and id)
		if commit.has_state { session_set_nav_state(sh, commit.state, true) }
	case .Traverse:
		if e := session_find(sh, commit.entry); e != nil {
			session_goto(sh, e)
			if e.url != href { delete(e.url); e.url = strings.clone(href); sh.serial += 1 }
		}
	}
}

// Makes the navigable's next document (closing the current one, which is unloaded first): its origin, sandboxing, policies and
// embedder, its place in the navigable's session history. nil: the frame is gone, or a listener of the unload navigated it.
@(private)
frame_install_page :: proc(n_in: ^Navigable, href_in: string, mode: Origin_Mode, commit: Frame_Commit = {}) -> ^Page {
	n := n_in
	if n.parent == nil || n.parent.closed { return nil }
	href := strings.clone(href_in, context.temp_allocator)
	commit := commit
	commit.state = strings.clone(commit.state, context.temp_allocator)   // (of the navigation, which that navigation would free)
	if leaving := n.page; leaving != nil && leaving.web != nil && leaving.web.unloading == 0 {
		id, gen := n.id, n.navigations
		page_unload(leaving)
		if n = navigable_by_id(id); n == nil || n.page != leaving || n.navigations != gen { return nil }
	}
	p := n.parent
	if p == nil || p.closed { return nil }
	if n.initial && frame_keeps_window(n, href, mode) {
		c := frame_keep_window(n, href, mode, commit)
		if c != nil && mode == .Inherit { frame_enforce_required_csp(n, c) }   // (about:blank, srcdoc: a local scheme takes it)
		return c
	}
	frame_session_commit(n, href, commit, p.settings.web.history_max_entries)
	n.initial = false
	c := page_create(p.loop, p.loader, p.settings, p.scope, href, p.console != nil ? frame_console : nil, n)
	cf := frames_of(c)
	cf.nav = n
	cf.sandbox = sandbox_combine(page_sandbox(p), n.sandbox)
	switch mode {
	case .Own:
	case .Inherit:
		env_set_origin(&c.env, url.origin_clone(p.env.origin))
		c.origin_owner = origin_owner_of(p)   // (HTML: the same origin, which document.domain changes for both)
	case .Opaque: env_set_origin(&c.env, url.new_opaque_origin())
	}
	if cf.sandbox.active && .Same_Origin not_in cf.sandbox.allow { env_set_origin(&c.env, url.new_opaque_origin()); c.origin_owner = 0 }
	top := page_top(p)
	url.site_destroy(&c.env.top_level_site)
	c.env.top_level_site = url.site_of(top.env.origin)
	c.env.storage_access = storage_access_initial(c)   // storage_access.odin: a permission granted before is "inactive"
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
	set_embedder(c, Embedder{navigate = frame_navigate_hook, user = n, session = &n.session, tab_key = pe.tab_key, storage = pe.storage})
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
	if mode == .Inherit { frame_enforce_required_csp(n, c) }   // (about:blank, srcdoc: a local scheme takes it)
	if the_pages.frame_hooks.attached != nil { the_pages.frame_hooks.attached(the_pages.frame_hooks.user, c) }
	return c
}

// HTML "navigate" keeps the Window of a frame's initial about:blank for the first document that replaces it, when that
// document is of its origin: what a script set on that Window (expandos, `navigation.onnavigate`, listeners, timers) is the
// next document's. Only a blank document whose realm was started has anything to keep; any other gets a Page of its own.
@(private)
frame_keeps_window :: proc(n: ^Navigable, href: string, mode: Origin_Mode) -> bool {
	c, p := n.page, n.parent
	if c == nil || c.js == nil || c.js.failed || c.close_pending || c.frames == nil || mode == .Opaque { return false }
	sandbox := sandbox_combine(page_sandbox(p), n.sandbox)
	if sandbox != c.frames.sandbox || sandbox.active && .Same_Origin not_in sandbox.allow { return false }
	if mode == .Inherit { return url.same_origin(p.env.origin, c.env.origin) }
	u, ok := url.parse(href, nil, context.temp_allocator)
	return ok && url.same_origin(url.origin_of(u, context.temp_allocator), c.env.origin)
}

// The blank document's Page takes the navigable's next document: its realm and its Window's objects stay; the new tree gets a
// tag of its own when it is parsed (the blank one's nodes die in every realm, the Window's objects keep the old tag: prior_tag),
// its URL, policies, frames and scripts are the new document's.
@(private)
frame_keep_window :: proc(n: ^Navigable, href: string, mode: Origin_Mode, commit: Frame_Commit) -> ^Page {
	c, p := n.page, n.parent
	frame_session_commit(n, href, commit, p.settings.web.history_max_entries)
	n.initial = false
	cf := c.frames
	delete(cf.fallback_base)
	cf.fallback_base = mode == .Inherit ? strings.clone(document_base_url(p)) : ""
	c.origin_owner = mode == .Inherit ? origin_owner_of(p) : 0
	cf.inherited_off = inherited_disabled(frames_of(p).features, p.env.origin, &n.allow, c.env.origin, n.src_origin)
	cf.features = enabled_features(cf.inherited_off, nil, c.env.origin)
	c.env.referrer_policy = mode == .Inherit ? p.env.referrer_policy : .Default
	window_keep(c, href)
	if c.closed || n.page != c { return nil }
	return c
}

// What a kept Window's Page forgets of the blank document (frame_keep_window, navigable_keep_window): its tag, frames, URL,
// policies, history state and scripts; the realm forgets what it holds of the document.
@(private)
window_keep :: proc(c: ^Page, href: string) {
	c.prior_tag, c.tag = c.tag, base.tag_new()
	c.dp.tag = c.tag
	cf := frames_of(c)
	for len(cf.children) > 0 { frame_destroy(cf.children[len(cf.children) - 1]) }
	cf.complete = false
	if cf.ready_poll != base.NIL_HANDLE {
		host.clear_timer(c.loop, cf.ready_poll)
		cf.ready_poll = base.NIL_HANDLE
	}
	set_document_url(c, href)
	csp.list_destroy(&c.env.policies)
	set_history_state(c, "", false)
	scripts_free(c)   // (the new document's start from its parse: js_load.odin)
	// what the realm holds of the document: history, the custom element registry, navigation.activation (native/js/odin/load.odin)
	if r := c.js; r != nil && !r.failed && r.inst != nil && !r.inst.dead { js_call(c, r.inst, "wj_document_replaced", nil) }
}

// A nested document's console is its tab's, each message prefixed with the frame's URL.
@(private)
frame_console :: proc(user: rawptr, level: Log_Level, message: string) {
	n := (^Navigable)(user)
	p := n.parent
	if p == nil || p.closed || p.console == nil { return }
	from := n.page != nil ? n.page.env.location.href : "frame"
	if len(from) > FRAME_CONSOLE_URL_MAX { from = from[:FRAME_CONSOLE_URL_MAX] }
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
	commit := Frame_Commit{state = req.nav_state, has_state = req.has_nav_state}
	switch req.kind {
	case .Assign: frame_navigate(n, req.url, commit = commit)
	case .Replace: frame_navigate(n, req.url, replace = true, commit = commit)
	case .Reload:
		commit.type = .Reload
		frame_navigate(n, strings.clone(p.env.location.href, context.temp_allocator), commit = commit)
	case .Traverse, .Url_Changed, .History_Changed:   // (a frame's traversals are the joint session history's: history_joint.odin)
	}
}

// The navigable of a frame's document; nil for a tab's.
frame_navigable_of :: proc(p: ^Page) -> ^Navigable {
	if p.frames == nil || p.frames.nav == nil || p.frames.nav.parent == nil { return nil }
	return p.frames.nav
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
	// (a window a sandboxed document opened: that document's navigable is its one permitted sandboxed navigator)
	if target.parent == nil && target.navigator == sn.id { return "" }
	if sb.active { return "a sandboxed frame may only navigate itself and its descendants" }
	// another window: one of the source's browsing context group (its opener, a window it or its group opened)
	if target.parent == nil {
		if top != nil && target.group == top.group { return "" }
		return "the window is not in this browsing context group"
	}
	// another frame: when the source is same origin with the target's parent document ("familiar with")
	if target.parent != nil && url.same_origin(src.env.origin, target.parent.env.origin) { return "" }
	return "the frame is not allowed to navigate this browsing context"
}

// Navigates another navigable on behalf of `src` (window.location of a WindowProxy, window.open to a frame name).
frames_navigate_from :: proc(src: ^Page, target_in: ^Navigable, href: string, replace: bool, method := "", body: []byte = nil, content_type := "", source := base.NIL_HANDLE, form := base.NIL_HANDLE, submitter := base.NIL_HANDLE) -> (why: string) {
	target := target_in
	if w := navigation_allowed(src, target); w != "" { return w }
	u, ok := url.parse(href, &src.env.location, context.temp_allocator)
	if !ok { return "invalid URL" }
	opts := Nav_Options{source = source, form = form, submitter = submitter}
	opts.cross_origin = target.page != nil && !url.same_origin_domain(src.env.origin, target.page.env.origin)
	if target.parent == nil {
		// a tab's document: its embedder navigates the tab (a POST to the top level is the shell's: forms_shell.odin)
		if tp := target.page; tp != nil { location_navigate(tp, u, replace, opts = opts) }
		return ""
	}
	h := strings.clone(u.href, context.temp_allocator)
	if cur := target.page; cur != nil {
		// the navigate event, in the frame's document (a listener may remove the frame)
		id := target.id
		if !navigation_begin(cur, u, replace, opts = opts) { return "" }
		if target = navigable_by_id(id); target == nil { return "" }
	}
	frame_navigate(target, h, replace, method, body, content_type)
	return ""
}

// The navigable a target name designates for `src` (HTML "the rules for choosing a navigable"): "_self", "_parent",
// "_top", "" (self), or the name of a frame anywhere in the tab, then of a window of its browsing context group or a frame
// of one. nil: none (a new window would be opened). `noopener`: only the first four, a name opens a new window.
frames_find_target :: proc(src: ^Page, name: string, noopener := false) -> ^Navigable {
	sn := page_navigable(src)
	if sn == nil { return nil }
	switch strings.to_lower(name, context.temp_allocator) {
	case "", "_self": return sn
	case "_parent": return sn.parent != nil ? page_navigable(sn.parent) : sn
	case "_top": return page_navigable(page_top(src))
	case "_blank": return nil
	}
	if noopener { return nil }
	// a named frame: the source's descendants first, then the whole tab, then the other windows of its group
	if n := find_named_below(src, name); n != nil { return n }
	if n := find_named_below(page_top(src), name); n != nil { return n }
	if n := find_named_window(src, name); n != nil { return n }
	for t in group_tops(src)[1:] {
		if n := find_named_below(t, name); n != nil { return n }
	}
	return nil
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
