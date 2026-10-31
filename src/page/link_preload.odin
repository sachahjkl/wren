package page

// <link rel=preload> and <link rel=modulepreload>: the resource is fetched, which leaves it in the HTTP cache for its real use,
// and the element gets `load` or `error`, which loaders of code wait for (Squoosh's inserts the script from `load`).
// The bytes are not kept apart: a response the cache may not keep is fetched again when used.

import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:url"

@(private)
Link_Preload :: struct {
	page:  ^Page,
	owner: base.Handle,
	href:  string,
	bad:   bool,
	task:  base.Handle,
}

// What `as` asks for: false when it is not a value that fetches anything.
@(private = "file")
preload_destination :: proc(as: string) -> (fetch.Destination, bool) {
	switch strings.to_lower(as, context.temp_allocator) {
	case "script": return .Script, true
	case "style":  return .Style, true
	case "image":  return .Image, true
	case "font":   return .Font, true
	case "audio":  return .Audio, true
	case "video":  return .Video, true
	case "fetch":  return .Empty, true
	}
	return .Empty, false
}

@(private = "file")
rel_has :: proc(rel, token: string) -> bool {
	list := rel
	for t in strings.fields_iterator(&list) { if strings.equal_fold(t, token) { return true } }
	return false
}

// A <link> was inserted, revealed by the parser, or an attribute of it changed.
@(private)
link_preload_note :: proc(p: ^Page, el: base.Handle) {
	if p.loader == nil || !dom.is_connected(p.doc, el) { return }
	n := dom.get(p.doc, el)
	if n == nil || n.kind != .Element || n.name != "link" { return }
	rel, _ := dom.get_attribute(p.doc, el, "rel")
	module := rel_has(rel, "modulepreload")
	if !module && !rel_has(rel, "preload") { return }
	href, has_href := dom.get_attribute(p.doc, el, "href")
	if !has_href || href == "" { return }
	if old, ok := p.link_preloads[el]; ok && old.href == href { return }
	as, _ := dom.get_attribute(p.doc, el, "as")
	destination, known := preload_destination(as)
	if module {
		destination, known = .Script, true
	}
	if !known { return }   // (HTML: no fetch and no event for an `as` it does not know)
	u, ok := url.parse(href, &p.env.location, context.temp_allocator)
	l := new(Link_Preload)
	l.page, l.owner, l.href = p, el, strings.clone(href)
	if old, had := p.link_preloads[el]; had { link_preload_free(p, old) }
	p.link_preloads[el] = l
	if !ok {
		queue_element_event(p, el, "error")
		return
	}
	mode := fetch.Mode.No_Cors
	credentials := fetch.Credentials.Include
	co, has_co := dom.get_attribute(p.doc, el, "crossorigin")
	if has_co || module || destination == .Font {
		mode = .Cors
		credentials = strings.equal_fold(co, "use-credentials") ? .Include : .Same_Origin
	}
	nonce, _ := dom.get_attribute(p.doc, el, "nonce")
	script := module ? fetch.Script_Type.Module : fetch.Script_Type.Classic
	l.task = fetch.start(p.loader, {
		request = {url = u.href, mode = mode, credentials = credentials, destination = destination, script = script, initiator = &p.env, nonce = nonce},
		on_event = link_preload_event, user = l, scope = p.scope, collect = false,
	})
}

@(private = "file")
link_preload_free :: proc(p: ^Page, l: ^Link_Preload) {
	if l.task != base.NIL_HANDLE { fetch.cancel(p.loader, l.task) }
	delete(l.href)
	free(l)
}

@(private)
link_preloads_free :: proc(p: ^Page) {
	for _, l in p.link_preloads { link_preload_free(p, l) }
	delete(p.link_preloads)
}

@(private = "file")
link_preload_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	l := (^Link_Preload)(user)
	p := l.page
	#partial switch ev.kind {
	case .Response:
		r := ev.response
		if r.type != .Opaque && (r.status < 200 || r.status >= 300) { l.bad = true }
	case .Done:
		l.task = base.NIL_HANDLE
		if dom.get(p.doc, l.owner) != nil { queue_element_event(p, l.owner, l.bad ? "error" : "load") }
	case .Failed:
		l.task = base.NIL_HANDLE
		if ev.error != .Aborted && dom.get(p.doc, l.owner) != nil { queue_element_event(p, l.owner, "error") }
	}
}