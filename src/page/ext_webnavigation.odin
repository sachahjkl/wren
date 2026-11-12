package page

// webNavigation (api/ext_webnavigation.widl): the frames of a tab and the steps of their documents. The frame id is
// Chrome's: 0 for the tab's top document, else the frame's navigable id; the documentId is the document's
// (ext_inject.odin). An extension gets the events and the frames of the documents it may see (ext_may_see_of: the tabs
// permission, a host grant, or its own pages).
//
// The events come from the points of a document (ext_inject.odin): onCommitted when its parsed tree is adopted,
// onDOMContentLoaded when the parser finished, onCompleted at its load event. Not sent yet: onBeforeNavigate,
// onErrorOccurred, onCreatedNavigationTarget, onReferenceFragmentUpdated, onHistoryStateUpdated, onTabReplaced (the
// navigations start in the shell and in frames.odin, which tell no extension yet).

import "core:fmt"
import "core:strings"
import "core:time"
import "wb:extensions"

// The tab a document is in (false: a page of no tab: a popup, an offscreen document, a background's host).
ext_tab_of_page :: proc(p: ^Page) -> (i64, bool) {
	top := page_id(ext_top_page(p))
	if top == 0 { return -1, false }
	for t in ext_tabs_list() { if t.page == top { return t.id, true } }
	return -1, false
}

// The documents of a tab, the top one first, then its frames in tree order (temp).
ext_tab_documents :: proc(top: ^Page) -> []^Page {
	out := make([dynamic]^Page, 0, 4, context.temp_allocator)
	stack := make([dynamic]^Page, 0, 4, context.temp_allocator)
	append(&stack, top)
	for len(stack) > 0 {
		q := pop(&stack)
		if q == nil || q.closed { continue }
		append(&out, q)
		if q.frames == nil { continue }
		// (pushed in reverse: popped in tree order)
		for i := len(q.frames.children) - 1; i >= 0; i -= 1 {
			if c := q.frames.children[i].page; c != nil { append(&stack, c) }
		}
	}
	return out[:]
}

// The top document of tab `tab` (nil: none).
ext_tab_top_page :: proc(tab: i64) -> ^Page {
	for t in ext_tabs_list() { if t.id == tab { return page_by_id(t.page) } }
	return nil
}

@(private)
ext_parent_frame :: proc(p: ^Page) -> (^Page, i64) {
	n := frame_navigable_of(p)
	if n == nil || n.parent == nil { return nil, -1 }
	return n.parent, ext_frame_id(n.parent)
}

// A frame's FrameDetails (the URL as the document has it now).
@(private)
ext_frame_json :: proc(b: ^strings.Builder, p: ^Page) {
	parent, parent_frame := ext_parent_frame(p)
	fmt.sbprintf(b, `{{"errorOccurred":false,"url":%s,"frameId":%d,"parentFrameId":%d,"processId":0,"documentId":%s`,
		extensions.json_quote(p.env.location.href), ext_frame_id(p), parent_frame, extensions.json_quote(ext_document_id(p)))
	if parent != nil { fmt.sbprintf(b, `,"parentDocumentId":%s`, extensions.json_quote(ext_document_id(parent))) }
	fmt.sbprintf(b, `,"documentLifecycle":"active","frameType":%s}}`, parent == nil ? `"outermost_frame"` : `"sub_frame"`)
}

ext_web_navigation_get_frame :: proc(x: ^Ext_Call, a: Ext_Web_Navigation_Get_Frame_Args) {
	d := a.details
	top := ext_tab_top_page(d.tab_id)
	if top == nil { ext_fail(x, fmt.tprintf("No tab with id: %d.", d.tab_id)); return }
	frame, has_frame := d.frame_id.?
	doc, has_doc := d.document_id.?
	if !has_frame && !has_doc { frame, has_frame = 0, true }
	for q in ext_tab_documents(top) {
		if has_frame && ext_frame_id(q) != frame { continue }
		if has_doc && ext_document_id(q) != doc { continue }
		if !ext_may_see(x, q.env.location.href) { break }
		b := strings.builder_make(context.temp_allocator)
		ext_frame_json(&b, q)
		ext_ok(x, strings.to_string(b))
		return
	}
	ext_ok(x, "null")
}

ext_web_navigation_get_all_frames :: proc(x: ^Ext_Call, a: Ext_Web_Navigation_Get_All_Frames_Args) {
	top := ext_tab_top_page(a.details.tab_id)
	if top == nil { ext_fail(x, fmt.tprintf("No tab with id: %d.", a.details.tab_id)); return }
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	first := true
	for q in ext_tab_documents(top) {
		if !ext_may_see(x, q.env.location.href) { continue }
		if !first { strings.write_byte(&b, ',') }
		first = false
		ext_frame_json(&b, q)
	}
	strings.write_byte(&b, ']')
	ext_ok(x, strings.to_string(b))
}

////////////////////////////////
// Events

// Sends webNavigation `event` for document `p` to every extension that listens to it and may see the document.
@(private)
ext_webnav_emit :: proc(p: ^Page, event: string, committed: bool) {
	reg := ext_registry()
	tab := i64(-1)
	ok, sent := false, false
	for e in reg.list {
		if !e.enabled || e.image == nil || !e.image.ok || !extensions.manifest_has_permission(&e.image.manifest, "webNavigation") { continue }
		listens := false
		for _, c in ext_router().contexts { if c.ext == e.id && c.kind != .Content && ext_listens(c, event) { listens = true; break } }
		if !listens || !ext_may_see_of(reg, e, p.env.location.href) { continue }
		if !sent {
			tab, ok = ext_tab_of_page(p)
			sent = true
		}
		if !ok { return }
		parent, parent_frame := ext_parent_frame(p)
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, `[{{"tabId":%d,"frameId":%d,"parentFrameId":%d,"url":%s,"timeStamp":%.3f,"processId":0,"documentId":%s`,
			tab, ext_frame_id(p), parent_frame, extensions.json_quote(p.env.location.href),
			f64(time.time_to_unix_nano(time.now())) / 1e6, extensions.json_quote(ext_document_id(p)))
		if parent != nil { fmt.sbprintf(&b, `,"parentDocumentId":%s`, extensions.json_quote(ext_document_id(parent))) }
		fmt.sbprintf(&b, `,"documentLifecycle":"active","frameType":%s`, parent == nil ? `"outermost_frame"` : `"sub_frame"`)
		if committed { strings.write_string(&b, `,"transitionType":"link","transitionQualifiers":[]`) }
		strings.write_string(&b, "}]")
		ext_emit(e.id, event, strings.to_string(b))
	}
}

ext_webnav_committed :: proc(p: ^Page) { ext_webnav_emit(p, "webNavigation.onCommitted", true) }
ext_webnav_dom_loaded :: proc(p: ^Page) { ext_webnav_emit(p, "webNavigation.onDOMContentLoaded", false) }
ext_webnav_completed :: proc(p: ^Page) { ext_webnav_emit(p, "webNavigation.onCompleted", false) }
