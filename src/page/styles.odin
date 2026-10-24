package page

import "core:fmt"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
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
	held_event:   enum u8 { None, Load, Error, Imports },   // settled before the parser revealed the <link>, or waiting for its imports (link_sheet_settled)
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
	pending :: proc(user: rawptr, owner: base.Handle) -> bool { return held_by_reveal((^Page)(user), owner) }
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
			if old.href == k.href && old.scope == k.scope {
				// a new media attribute: the sheet, once it arrives, gets it (a loaded one has it already)
				if old.media != k.media { delete(old.media); old.media = strings.clone(k.media) }
				continue
			}
			if s := style.engine_sheet_of_owner(p.engine, k.owner); s != nil { style.engine_remove_sheet(p.engine, s) }
			free_load(p, old)
			delete_key(&p.link_loads, k.owner)
		}
		abs, ok := resolve_against(k.href, p.env.location.href)
		l := new(Style_Load)
		l.page, l.owner, l.url = p, k.owner, abs
		l.href, l.media = strings.clone(k.href), strings.clone(k.media)
		l.scope = k.scope
		p.link_loads[k.owner] = l
		if !ok {
			// kept (failed) so that the next reading does not report it again; its error event once
			log(p, .Warn, fmt.tprintf("stylesheet: invalid URL %q", k.href))
			l.failed = true
			link_sheet_settled(p, l, false)
			continue
		}
		l.parser = render_blocking_candidate(p, k.owner)
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
		if !ok {
			log(p, .Warn, fmt.tprintf("@import: invalid URL %q", pi.url))
			style.engine_fail_import(p.engine, pi.sheet_id, pi.slot)
			links_check_imports(p)
			continue
		}
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
		} else if !(r.has_mime && strings.equal_fold(r.mime.type, "text") && strings.equal_fold(r.mime.subtype, "css")) {
			// HTML "process the linked resource" (stylesheet): a Content-Type that is not text/css fails it, except in
			// a quirks-mode document for a same-origin response
			if !(p.doc.mode == .Quirks && r.type == .Basic) {
				l.bad_status = true
				l.failed = true
				log(p, .Warn, fmt.tprintf("stylesheet %s: not text/css (%s/%s), ignored", l.url, r.mime.type, r.mime.subtype))
			}
		}
	case .Data:
	case .Failed:
		l.task = base.NIL_HANDLE
		l.failed = true
		log(p, .Warn, fmt.tprintf("stylesheet %s: %s", l.url, ev.detail))
		if l.is_import { import_failed(p, l) } else { link_sheet_settled(p, l, false) }
	case .Done:
		l.task = base.NIL_HANDLE
		if l.bad_status {
			if l.is_import { import_failed(p, l) } else { link_sheet_settled(p, l, false) }
			return
		}
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
			link_sheet_settled(p, l, !l.failed)
		}
		p.style_stale = true
		start_pending_imports(p)
		if l.is_import { links_check_imports(p) }
	}
}

// The <link>'s sheet is in (or will never be): its load or error event, as a task (HTML "process the linked
// resource").
// A <link> the parser has not revealed yet (its sheet loads ahead) gets its event once revealed (link_revealed): its
// event handler attributes are only registered then, and for the page it has not been inserted before.
// Its @imports count too (CSSOM "critical subresources"): load waits for them, and is error when one failed.
@(private)
link_sheet_settled :: proc(p: ^Page, l: ^Style_Load, ok: bool) {
	if l.is_import { return }
	if _, still := p.link_loads[l.owner]; !still { return }
	ok := ok
	if ok {
		pending, failed := style.import_tree_state(p.engine, style.engine_sheet_of_owner(p.engine, l.owner))
		if pending { l.held_event = .Imports; return }
		ok = !failed
	}
	link_event(p, l, ok)
}

@(private = "file")
link_event :: proc(p: ^Page, l: ^Style_Load, ok: bool) {
	if held_by_reveal(p, l.owner) {
		l.held_event = ok ? .Load : .Error
		return
	}
	l.held_event = .None
	queue_element_event(p, l.owner, ok ? "load" : "error")
}

// An import arrived or failed: the <link>s waiting for theirs may be done.
@(private)
links_check_imports :: proc(p: ^Page) {
	for owner, l in p.link_loads {
		if l.held_event != .Imports { continue }
		s := style.engine_sheet_of_owner(p.engine, owner)
		if s == nil { l.held_event = .None; continue }
		pending, failed := style.import_tree_state(p.engine, s)
		if !pending { link_event(p, l, !failed) }
	}
}

// An import's fetch ended without a sheet: its slot fails (and the <link> above it hears of it).
@(private)
import_failed :: proc(p: ^Page, l: ^Style_Load) {
	style.engine_fail_import(p.engine, l.sheet_id, l.slot)
	links_check_imports(p)
}

// The parser revealed `node` (js_load.odin reveal_node): a <link> whose sheet settled meanwhile gets its event now.
@(private)
link_revealed :: proc(p: ^Page, node: base.Handle) {
	l, ok := p.link_loads[node]
	if !ok || l.held_event == .None || l.held_event == .Imports { return }
	ev := l.held_event
	l.held_event = .None
	queue_element_event(p, node, ev == .Load ? "load" : "error")
}

// A script inserted `node`: when it holds a <link> or <style>, the document's sheets are read again in a task of their
// own, so that a stylesheet starts loading (and fires load / error) whether or not the page is styled meanwhile (a page
// without a window, a hidden tab). Many insertions in one script make one task.
@(private)
styles_note_inserted :: proc(p: ^Page, node: base.Handle) {
	d := p.doc
	stack := make([dynamic]base.Handle, 0, 8, context.temp_allocator)
	append(&stack, node)
	for len(stack) > 0 {
		cur := pop(&stack)
		n := dom.get(d, cur)
		if n == nil || n.kind != .Element { continue }
		if n.name == "link" || n.name == "style" { styles_sync_soon(p); return }
		for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next { append(&stack, ch) }
	}
}

// An attribute of `el` changed: a <link>'s rel, href, media, type, disabled, crossorigin decide what it loads.
@(private)
styles_note_attribute :: proc(p: ^Page, el: base.Handle, name: string) {
	n := dom.get(p.doc, el)
	if n == nil || n.kind != .Element || n.name != "link" { return }
	switch name {
	case "rel", "href", "media", "type", "disabled", "crossorigin":
		if dom.is_connected(p.doc, el) || name == "rel" { styles_sync_soon(p) }
	}
}

@(private)
styles_sync_soon :: proc(p: ^Page) {
	if p.closed || p.link_sync_timer != base.NIL_HANDLE { return }
	p.link_sync_timer = host.set_timer(p.loop, 0, 0, proc(data: rawptr) {
		p := (^Page)(data)
		p.link_sync_timer = base.NIL_HANDLE
		if p.closed || p.engine == nil || p.doc == nil { return }
		sync_styles(p)
		p.style_stale = true
	}, p, p.scope)
}

// Whether `node` is in the part of the document the parser's reveal has not attached yet (js_load.odin).
@(private)
held_by_reveal :: proc(p: ^Page, node: base.Handle) -> bool {
	if !scripts_revealing(p) { return false }
	d := p.doc
	if dom.get(d, node) == nil { return false }
	r := dom.shadow_including_root(d, node)
	if r == d.root { return false }
	ps := &p.scripts.parser
	for it in ps.queue[ps.next:] { if it.node == r { return true } }
	return false
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
	t0 := time.tick_now()
	if embedder.before_styles != nil && p.worker == nil { embedder.before_styles(embedder.user, p) }   // (embedder.odin)
	env := style.media_env_from(&e.settings, f64(viewport_w), f64(viewport_h), dppx, style.os_appearance().dark)
	env.scripting = e.settings.scripting   // (scripting: enabled) / (scripting: none)
	style.engine_set_environment(e, env)
	media_queries_update(p, env)   // matchMedia lists (js_web_media.odin)

	now := document_time_ms(p)
	full := p.styled == nil || p.style_stale || e.dirty || e.restyle_needed
	why := p.styled == nil ? "no styles yet" : p.style_stale ? "the page's styles were marked stale" : e.dirty ? "style rules changed (a sheet came or went)" : e.restyle_needed ? "an environment change asked for one" : ""
	partial, dom_partial := false, false
	if !full && (p.styled.mutations != p.doc.mutations || e.shadow.dirty) {
		full, why = true, "shadow tree rules changed"
		if e.settings.inc_enabled {
			owners := make([dynamic]base.Handle, 0, len(p.link_loads), context.temp_allocator)
			for o in p.link_loads { append(&owners, o) }
			if style.dom_touches_sheets(e, p.doc, p.styled, owners[:]) { sync_styles(p) }
			if !e.dirty {
				if _, ok := style.restyle_dom(e, p.doc, p.styled, style_threads(p)); ok { full, dom_partial = false, true } else { why = e.last_restyle.fallback }
			} else { why = "a changed element carries style rules (<style>, <link>)" }
		}
	}
	if !full && !style.state_equal(effective_state(p), p.styled.state) {
		if _, ok := style.restyle_state(e, p.doc, p.styled, effective_state(p)); !ok { full = true } else { partial = true }
	}
	if full {
		if p.styled == nil || p.style_stale || p.styled.mutations != p.doc.mutations { sync_styles(p) }
		old := p.styled
		p.styled = style.compute_styles(e, p.doc, effective_state(p), style_threads(p), p.settings.threads.style_min_nodes)
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
			style.watch_prepare(e, p.doc)   // (what removed subtrees held, for the :has() anchors: dom.Watch)
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
	styles_note(full, dom_partial, partial, time.tick_since(t0), why)
	return p.styled
}
// What the style passes cost, for the profile report (prof.odin) and the measuring scripts: how many passes of each kind and
// the time they took, and the engine's rebuilds (style.rebuild_total).
Styles_Stats :: struct {
	calls, full, dom, state, none: int,
	full_ns, dom_ns, state_ns, none_ns: i64,
	why: map[string]Why_Count,   // the full passes by the reason the incremental one was not enough
}
Why_Count :: struct { n: int, ns: i64 }
styles_stats: Styles_Stats

@(private = "file")
styles_note :: proc(full, dom, state: bool, d: time.Duration, why: string) {
	s := &styles_stats
	s.calls += 1
	switch {
	case full:
		s.full += 1; s.full_ns += i64(d)
		if s.why == nil { s.why = make(map[string]Why_Count, 16, base.process_allocator()) }
		w := s.why[why]
		w.n += 1; w.ns += i64(d)
		s.why[why] = w
	case dom: s.dom += 1; s.dom_ns += i64(d)
	case state: s.state += 1; s.state_ns += i64(d)
	case: s.none += 1; s.none_ns += i64(d)
	}
}

styles_stats_text :: proc() -> string {
	s := styles_stats
	r := style.rebuild_total
	return fmt.tprintf("style passes: %d | full %d (%.0f ms) | partial after DOM changes %d (%.0f ms) | partial after state changes %d (%.0f ms) | nothing to do %d (%.0f ms)\nstyle engine rebuilds (every sheet flattened again): %d, %.0f ms, %.1f sheets on average",
		s.calls, s.full, f64(s.full_ns) / 1e6, s.dom, f64(s.dom_ns) / 1e6, s.state, f64(s.state_ns) / 1e6, s.none, f64(s.none_ns) / 1e6,
		r.n, f64(r.ns) / 1e6, f64(r.sheets) / f64(max(r.n, 1)))
}
styles_stats_why :: proc() -> string {
	sb := strings.builder_make(context.temp_allocator)
	for k, v in styles_stats.why { fmt.sbprintf(&sb, "  full pass x %d, %.0f ms: %s\n", v.n, f64(v.ns) / 1e6, k) }
	return strings.to_string(sb)
}
