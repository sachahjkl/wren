package page

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:html"
import "wb:style"
import "wb:url"

// Styling of a page: the style engine, the stylesheets the document asks for (<style>, <link rel=stylesheet>, @import) and
// the computed styles for the current DOM. Stylesheets are fetched through the policy layer like every other resource
// (CSP style-src, MIME checks, mixed content), so a blocked or mistyped stylesheet is an error in the console and nothing
// else.

Style_Load :: struct {
	page:         ^Page,
	owner:        base.Handle,   // <link> element (links only)
	href:         string,        // owned: the attribute as written, to notice a change
	url:          string,        // owned: absolute
	media:        string,        // owned
	sheet_id:     u64,           // imports: the importing sheet
	slot:         int,
	task:         base.Handle,
	bad_status:   bool,
	is_import:    bool,
	serial:       u64,           // tells a background parse whether this load is still the one it parses for
	parser:       bool,          // part of the document as parsed (or blocking="render"): may block its first paint
	failed:       bool,          // nothing will come of it (network error, HTTP error, refused)
	scope:        base.Handle,   // links: the shadow root the <link> is in (NIL: the document)
	settled:      bool,          // its own sheet is in the engine, or will not come (link_events.odin)
	fired:        bool,          // links: its load / error event is queued
}

@(private)
styles_init :: proc(p: ^Page) {
	p.engine = style.engine_make(page_style_settings(p))
	p.link_loads = make(map[base.Handle]^Style_Load)
	p.import_loads = make([dynamic]^Style_Load)
	p.style_stale = true
	animations_init(p)
	fonts_init(p)
}

@(private)
free_load :: proc(p: ^Page, l: ^Style_Load) {
	if l.task != base.NIL_HANDLE { fetch.cancel(p.loader, l.task) }
	delete(l.href); delete(l.url); delete(l.media)
	free(l)
}

@(private)
styles_destroy :: proc(p: ^Page) {
	for _, l in p.link_loads { free_load(p, l) }
	delete(p.link_loads)
	for l in p.import_loads { free_load(p, l) }
	delete(p.import_loads)
	fonts_destroy(p)
	animations_destroy(p)   // puts the cascaded styles back before they go
	style.styled_destroy(p.styled)
	p.styled = nil
	style.engine_destroy(p.engine)
	p.engine = nil
}

// Applies a changed configuration (preferences): the engine recompiles with the new limits and defaults.
configure_styles :: proc(p: ^Page) {
	style.engine_configure(p.engine, page_style_settings(p))
	p.style_stale = true
}

// The shell's style settings, with what belongs to this document (scripting: <noscript> is not rendered).
@(private)
page_style_settings :: proc(p: ^Page) -> style.Settings {
	s := p.settings.style
	s.scripting = p.worker == nil && js_enabled(p)
	return s
}

// Asks the style passes of the page to keep a layout journal (style.Layout_Journal) of at most `max_entries` entries,
// for an incremental layout; 0 turns it off. Cheap to call every frame.
set_layout_journal :: proc(p: ^Page, max_entries: int) {
	style.engine_set_journal(p.engine, max_entries)
}

// The inputs of :hover / :active / :focus / :target. Setting them is cheap and may happen many times per frame; the work
// (a partial restyle, or nothing when no rule depends on what changed) happens once, in the next `styles` call.
set_style_state :: proc(p: ^Page, state: style.State) {
	if !style.state_equal(state, p.style_state) {
		delete(p.style_state.target_id)
		p.style_state = state
		p.style_state.target_id = strings.clone(state.target_id)
	}
}

@(private)
resolve_against :: proc(src, base_url: string) -> (string, bool) {
	b, ok := url.parse_absolute(base_url, context.temp_allocator)
	if !ok { return "", false }
	u, ok2 := url.parse(src, &b, context.temp_allocator)
	if !ok2 { return "", false }
	return strings.clone(u.href), true
}

@(private)
start_style_fetch :: proc(p: ^Page, l: ^Style_Load, crossorigin: string, has_crossorigin: bool, nonce: string) {
	mode := fetch.Mode.No_Cors
	cred := fetch.Credentials.Include
	if has_crossorigin {
		mode = .Cors
		cred = strings.equal_fold(crossorigin, "use-credentials") ? .Include : .Same_Origin
	}
	p.offthread.next_serial += 1
	l.serial = p.offthread.next_serial
	l.task = fetch.start(p.loader, {
		request = {url = l.url, mode = mode, credentials = cred, destination = .Style, initiator = &p.env, nonce = nonce},
		on_event = style_event, user = l, scope = p.scope, collect = true,
	})
}

// Reads the document's stylesheets and starts what has to be loaded. Safe to call after any mutation.
sync_styles :: proc(p: ^Page) {
	// the parser's reveal has the rest of the document detached for now: its stylesheets stay as they are until it
	// finishes (js_load.odin), instead of being dropped and loaded again; new ones (a script's) are added meanwhile
	revealing := scripts_revealing(p)
	// a sheet stays when its owner is in the part not revealed yet (not one a script removed)
	pending :: proc(user: rawptr, owner: base.Handle) -> bool {
		p := (^Page)(user)
		d := p.doc
		if dom.get(d, owner) == nil { return false }
		r := dom.shadow_including_root(d, owner)
		if r == d.root { return false }
		ps := &p.scripts.parser
		for it in ps.queue[ps.next:] { if it.node == r { return true } }
		return false
	}
	links := style.sync_document_sheets(p.engine, p.doc, p.env.location.href, keep_missing = revealing ? pending : nil, keep_user = p)

	// links that disappeared
	if !revealing {
		for owner, l in p.link_loads {
			found := false
			for k in links { if k.owner == owner { found = true; break } }
			if !found { free_load(p, l); delete_key(&p.link_loads, owner) }
		}
	}
	// new or changed links
	for k in links {
		if old, ok := p.link_loads[k.owner]; ok {
			if old.href == k.href && old.scope == k.scope { continue }
			if s := style.engine_sheet_of_owner(p.engine, k.owner); s != nil { style.engine_remove_sheet(p.engine, s) }
			free_load(p, old)
			delete_key(&p.link_loads, k.owner)
		}
		abs, ok := resolve_against(k.href, p.env.location.href)
		if !ok { log(p, .Warn, fmt.tprintf("stylesheet: invalid URL %q", k.href)); continue }
		l := new(Style_Load)
		l.page, l.owner, l.url = p, k.owner, abs
		l.href, l.media = strings.clone(k.href), strings.clone(k.media)
		l.scope = k.scope
		l.parser = render_blocking_candidate(p, k.owner)
		p.link_loads[k.owner] = l
		co, has_co := dom.get_attribute(p.doc, k.owner, "crossorigin")
		nonce, _ := dom.get_attribute(p.doc, k.owner, "nonce")
		start_style_fetch(p, l, co, has_co, nonce)
	}
	start_pending_imports(p)
}

@(private)
start_pending_imports :: proc(p: ^Page) {
	for pi in style.engine_take_pending_imports(p.engine) {
		base_url := pi.base_url != "" ? pi.base_url : p.env.location.href
		abs, ok := resolve_against(pi.url, base_url)
		if !ok { log(p, .Warn, fmt.tprintf("@import: invalid URL %q", pi.url)); continue }
		l := new(Style_Load)
		l.page, l.url, l.is_import, l.sheet_id, l.slot = p, abs, true, pi.sheet_id, pi.slot
		l.parser = p.render.collecting   // imports found before the first paint (of the document's own sheets) block it
		append(&p.import_loads, l)
		start_style_fetch(p, l, "", false, "")
	}
}

@(private)
style_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	l := (^Style_Load)(user)
	p := l.page
	switch ev.kind {
	case .Response:
		r := ev.response
		if r.type != .Opaque && (r.status < 200 || r.status >= 300) {
			l.bad_status = true
			l.failed = true
			log(p, .Warn, fmt.tprintf("stylesheet %s: HTTP %d", l.url, r.status))
		}
	case .Data:
	case .Failed:
		l.task = base.NIL_HANDLE
		l.failed = true
		log(p, .Warn, fmt.tprintf("stylesheet %s: %s", l.url, ev.detail))
		style_load_settled(p, l, false)
	case .Done:
		l.task = base.NIL_HANDLE
		if l.bad_status { style_load_settled(p, l, false); return }
		if !l.is_import { if _, still := p.link_loads[l.owner]; !still { return } }
		if parse_sheet_offthread(p, l, ev.data) { return }   // registered when parsed (offthread.odin)
		text := decode_css(ev.data, p.settings.style.max_sheet_bytes)
		defer delete(text)
		if l.is_import {
			if !style.engine_resolve_import_by_id(p.engine, l.sheet_id, l.slot, string(text), l.url) { l.failed = true }
		} else {
			if _, still := p.link_loads[l.owner]; !still { return }
			if s := style.engine_add_sheet(p.engine, string(text), l.owner, l.media, l.url, from_link = true, scope = l.scope); s == nil {
				l.failed = true
				log(p, .Warn, fmt.tprintf("stylesheet %s: too large or disabled", l.url))
			}
		}
		p.style_stale = true
		start_pending_imports(p)   // (before settling: a link waits for the @imports its sheet starts)
		style_load_settled(p, l, !l.failed)
	}
}

// A stylesheet's bytes as UTF-8: byte-order mark, then an @charset rule, then UTF-8 (the Content-Type charset is not
// carried here; servers that need another encoding say so with @charset or a BOM).
@(private)
decode_css :: proc(data: []byte, max_bytes: int) -> []byte {
	label := ""
	if len(data) > 10 && string(data[:9]) == `@charset "` {
		rest := string(data[9:min(len(data), 9 + 64)])
		if end := strings.index_byte(rest, '"'); end > 0 { label = rest[:end] }
	}
	d, ok := html.decode_document(data, label, "utf-8", prescan_meta = false)
	if !ok { return nil }
	return d.text
}

// The computed styles for the document as it is now, doing as little as the changes since the last call allow:
//   * sheets changed                   -> read the stylesheets again, full restyle
//   * DOM changed                      -> partial restyle of what the mutations can reach (style.restyle_dom), else full
//   * viewport / color scheme changed  -> full restyle only if some rule can depend on it (media query, vw units...)
//   * hover / focus / active / target  -> partial restyle of the elements those states can reach, or nothing
// The result is cached; its `serial` changes exactly when some computed style changed, which is what layout watches.
styles :: proc(p: ^Page, viewport_w, viewport_h: f32, dppx: f64) -> ^style.Styled {
	e := p.engine
	env := style.media_env_from(&e.settings, f64(viewport_w), f64(viewport_h), dppx, style.os_appearance().dark)
	env.scripting = e.settings.scripting   // (scripting: enabled) / (scripting: none)
	style.engine_set_environment(e, env)
	media_queries_update(p, env)   // matchMedia lists (js_web_media.odin)

	now := document_time_ms(p)
	full := p.styled == nil || p.style_stale || e.dirty || e.restyle_needed
	partial, dom_partial := false, false
	if !full && (p.styled.mutations != p.doc.mutations || e.shadow.dirty) {
		full = true
		if e.settings.inc_enabled {
			owners := make([dynamic]base.Handle, 0, len(p.link_loads), context.temp_allocator)
			for o in p.link_loads { append(&owners, o) }
			if style.dom_touches_sheets(e, p.doc, p.styled, owners[:]) { sync_styles(p) }
			if !e.dirty {
				if _, ok := style.restyle_dom(e, p.doc, p.styled, style_threads(p)); ok { full, dom_partial = false, true }
			}
		}
	}
	if !full && !style.state_equal(p.style_state, p.styled.state) {
		if _, ok := style.restyle_state(e, p.doc, p.styled, p.style_state); !ok { full = true } else { partial = true }
	}
	if full {
		if p.styled == nil || p.style_stale || p.styled.mutations != p.doc.mutations { sync_styles(p) }
		old := p.styled
		p.styled = style.compute_styles(e, p.doc, p.style_state, style_threads(p), p.settings.threads.style_min_nodes)
		// what changed for an incremental layout (only when one asked: set_layout_journal)
		if old != nil && p.doc.nodes.count >= p.settings.threads.style_min_nodes {
			style.journal_diff(old, p.styled, style_threads(p))
		} else {
			style.journal_diff(old, p.styled)
		}
		// transitions compare against the old styles (animated values included): they go only after this
		style.timeline_restyled(p.anim.timeline, p.doc, old, p.styled, now)
		style.styled_recycle(e, old)
		p.style_stale = false
		e.restyle_needed = false
		fonts_sync(p)
		// later mutations restyle partially: they need the document's mutation journal from now on
		if e.settings.inc_enabled {
			if !p.doc.journal.on { dom.journal_enable(p.doc, e.settings.inc_journal) }
			p.doc.journal.max = max(p.doc.journal.max, e.settings.inc_journal)
		}
	} else if partial || dom_partial {
		style.timeline_restyled_dom(p.anim.timeline, p.doc, p.styled, now)
		if dom_partial {
			fonts_sync(p)
			if e.settings.inc_verify {
				if diff := style.verify_styles(e, p.doc, p.styled, context.temp_allocator); diff != "" {
					log(p, .Warn, fmt.tprintf("style.incremental.verify: partial restyle differs from a full one: %s", diff))
				}
			}
		}
	}
	style.timeline_tick(p.anim.timeline, p.doc, p.styled, now)
	animations_after_tick(p)
	return p.styled
}