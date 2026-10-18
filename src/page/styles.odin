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
}

@(private)
styles_init :: proc(p: ^Page) {
	p.engine = style.engine_make(p.settings.style)
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
	style.engine_configure(p.engine, p.settings.style)
	p.style_stale = true
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
	l.task = fetch.start(p.loader, {
		request = {url = l.url, mode = mode, credentials = cred, destination = .Style, initiator = &p.env, nonce = nonce},
		on_event = style_event, user = l, scope = p.scope, collect = true,
	})
}

// Reads the document's stylesheets and starts what has to be loaded. Safe to call after any mutation.
sync_styles :: proc(p: ^Page) {
	links := style.sync_document_sheets(p.engine, p.doc, p.env.location.href)

	// links that disappeared
	for owner, l in p.link_loads {
		found := false
		for k in links { if k.owner == owner { found = true; break } }
		if !found { free_load(p, l); delete_key(&p.link_loads, owner) }
	}
	// new or changed links
	for k in links {
		if old, ok := p.link_loads[k.owner]; ok {
			if old.href == k.href { continue }
			if s := style.engine_sheet_of_owner(p.engine, k.owner); s != nil { style.engine_remove_sheet(p.engine, s) }
			free_load(p, old)
			delete_key(&p.link_loads, k.owner)
		}
		abs, ok := resolve_against(k.href, p.env.location.href)
		if !ok { log(p, .Warn, fmt.tprintf("stylesheet: invalid URL %q", k.href)); continue }
		l := new(Style_Load)
		l.page, l.owner, l.url = p, k.owner, abs
		l.href, l.media = strings.clone(k.href), strings.clone(k.media)
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
			log(p, .Warn, fmt.tprintf("stylesheet %s: HTTP %d", l.url, r.status))
		}
	case .Data:
	case .Failed:
		l.task = base.NIL_HANDLE
		log(p, .Warn, fmt.tprintf("stylesheet %s: %s", l.url, ev.detail))
	case .Done:
		l.task = base.NIL_HANDLE
		if l.bad_status { return }
		text := decode_css(ev.data, p.settings.style.max_sheet_bytes)
		defer delete(text)
		if l.is_import {
			style.engine_resolve_import_by_id(p.engine, l.sheet_id, l.slot, string(text), l.url)
		} else {
			if _, still := p.link_loads[l.owner]; !still { return }
			if s := style.engine_add_sheet(p.engine, string(text), l.owner, l.media, l.url, from_link = true); s == nil {
				log(p, .Warn, fmt.tprintf("stylesheet %s: too large or disabled", l.url))
			}
		}
		p.style_stale = true
		start_pending_imports(p)
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
//   * sheets or DOM changed            -> read the stylesheets again, full restyle
//   * viewport / color scheme changed  -> full restyle only if some rule can depend on it (media query, vw units...)
//   * hover / focus / active / target  -> partial restyle of the elements those states can reach, or nothing
// The result is cached; its `serial` changes exactly when some computed style changed, which is what layout watches.
styles :: proc(p: ^Page, viewport_w, viewport_h: f32, dppx: f64) -> ^style.Styled {
	e := p.engine
	env := style.media_env_from(&e.settings, f64(viewport_w), f64(viewport_h), dppx, false)
	style.engine_set_environment(e, env)

	now := document_time_ms(p)
	full := p.styled == nil || p.style_stale || p.styled.mutations != p.doc.mutations || e.dirty || e.restyle_needed
	partial := false
	if !full && !style.state_equal(p.style_state, p.styled.state) {
		if _, ok := style.restyle_state(e, p.doc, p.styled, p.style_state); !ok { full = true } else { partial = true }
	}
	if full {
		if p.styled == nil || p.style_stale || p.styled.mutations != p.doc.mutations { sync_styles(p) }
		old := p.styled
		p.styled = style.compute_styles(e, p.doc, p.style_state)
		// transitions compare against the old styles (animated values included): they go only after this
		style.timeline_restyled(p.anim.timeline, p.doc, old, p.styled, now)
		style.styled_destroy(old)
		p.style_stale = false
		e.restyle_needed = false
		fonts_sync(p)
	} else if partial {
		style.timeline_restyled_partial(p.anim.timeline, p.doc, p.styled, now)
	}
	style.timeline_tick(p.anim.timeline, p.doc, p.styled, now)
	animations_after_tick(p)
	return p.styled
}