package style

import "core:strings"
import "wb:base"
import "wb:dom"

Linked_Sheet :: struct {
	owner: base.Handle,   // the <link> element
	href:  string,        // as written; the caller resolves it against the document URL and fetches it
	media: string,
	scope: base.Handle,   // the shadow root the <link> is in (NIL: the document): engine_add_sheet's `scope`
}

@(private)
is_css_type :: proc(n: ^dom.Node) -> bool {
	t, ok := attr(n, "type")
	if !ok { return true }
	t = strings.trim_space(t)
	return t == "" || strings.equal_fold(t, "text/css")
}

@(private)
has_token :: proc(list, token: string) -> bool {
	rest := list
	for len(rest) > 0 {
		for len(rest) > 0 && is_space(rest[0]) { rest = rest[1:] }
		end := 0
		for end < len(rest) && !is_space(rest[end]) { end += 1 }
		if end > 0 && strings.equal_fold(rest[:end], token) { return true }
		rest = rest[end:]
	}
	return false
}

// Brings the engine's document sheets in line with the document, cheaply enough to call after every mutation:
//   * a <style> element keeps its sheet while its text and media stay the same, gets a new one when they change, and loses
//     it when the element goes away or stops being a stylesheet;
//   * a <link rel="stylesheet"> keeps its (separately loaded) sheet while the element exists; the sheet is dropped with it.
// Returns every <link rel="stylesheet"> currently in the document, for the caller to load and register with
// `engine_add_sheet(..., from_link = true)`.
// `keep_missing`: whether the sheet of an owner that is not found stays (part of the document is detached for a while).
sync_document_sheets :: proc(e: ^Engine, doc: ^dom.Document, base_url: string, allocator := context.temp_allocator, keep_missing: proc(user: rawptr, owner: base.Handle) -> bool = nil, keep_user: rawptr = nil) -> []Linked_Sheet {
	links := make([dynamic]Linked_Sheet, allocator)
	Style_El :: struct { owner: base.Handle, text, media: string, scope: base.Handle }
	styles := make([dynamic]Style_El, context.temp_allocator)
	// the document and every shadow tree of it (the sheets of a shadow tree are its own: scope.odin)
	shadows := dom.has_shadow_trees(doc)
	for h := doc.root; h != base.NIL_HANDLE; h = dom.next_shadow_including(doc, h, doc.root) {
		n := dom.get(doc, h)
		if n.kind != .Element { continue }
		switch n.name {
		case "style":
			if _, off := attr(n, "disabled"); !off && is_css_type(n) {
				media, _ := attr(n, "media")
				append(&styles, Style_El{h, dom.text_content(doc, h), media, shadows ? dom.containing_shadow_root(doc, h) : base.NIL_HANDLE})
			}
		case "link":
			rel, _ := attr(n, "rel")
			href, has_href := attr(n, "href")
			if has_href && href != "" && has_token(rel, "stylesheet") && !has_token(rel, "alternate") && is_css_type(n) {
				if _, off := attr(n, "disabled"); !off {
					media, _ := attr(n, "media")
					append(&links, Linked_Sheet{h, href, media, shadows ? dom.containing_shadow_root(doc, h) : base.NIL_HANDLE})
				}
			}
		}
	}

	// drop what no longer matches
	for i := len(e.sheets) - 1; i >= 0; i -= 1 {
		s := e.sheets[i]
		if s.origin != .Author || s.constructed { continue }
		keep := false
		found := false
		if s.from_link {
			for l in links {
				if l.owner == s.owner && l.scope == s.scope {
					keep = true
					// (media="print" onload="this.media='all'": the loaded sheet starts applying)
					sheet_set_media(e, s, l.media)
					break
				}
			}
			found = keep
		} else {
			for st in styles {
				if st.owner != s.owner { continue }
				found = true
				if st.scope == s.scope && st.text == s.sheet.source && st.media == s.media_text { keep = true; break }
			}
		}
		if !found && keep_missing != nil && keep_missing(keep_user, s.owner) { keep = true; s.detached = true }
		// the owner is back in the tree: the rebuilds made meanwhile ordered the sheet as if it were nowhere
		if found && keep && s.detached { s.detached = false; sheet_changed(e, s) }
		if !keep {
			sheet_changed(e, s)
			sheet_free(s)
			ordered_remove(&e.sheets, i)
		}
	}
	// add the new <style> sheets
	for st in styles {
		have := false
		for s in e.sheets { if s.origin == .Author && !s.from_link && !s.constructed && s.owner == st.owner { have = true; break } }
		if !have { engine_add_sheet(e, st.text, st.owner, st.media, base_url, scope = st.scope) }
	}
	return links[:]
}
