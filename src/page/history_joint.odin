package page

// The joint session history (HTML §7.4, the session history of a traversable navigable): a tab's history counts and moves
// through the entries of its frames with its own. The top-level session (the tab's tree, history.odin) keeps, beside its
// entries, the steps its nested navigables made: a step is a push in a frame (another document, a fragment, pushState, an
// intercepted navigation), with the entry it made current and the one it left, filed after the top-level entry that was
// current then. The web sees one line of positions, each top-level entry of its path followed by its steps:
//
//   A    A·f1    A·f2    B    B·g1        A, B: top-level entries; f, g: steps of frames
//
// history.length counts the positions; history.go(delta), back() and forward() in any document of the tab and the browser's
// buttons move `delta` positions; navigation.traverseTo() goes to the nearest position where its own navigable shows that
// entry. At a position each frame shows the entry of its last step at or before it (before its first step: the entry that
// step left), the top-level navigable that position's entry. A push drops the positions ahead of the current one, a frame's
// push the top-level entries ahead too (session_cut_ahead). A step whose frame was removed no longer counts. A frame whose
// document left (not into the back/forward cache: navigated away, evicted) is kept with its entries (Kept_Frame: by the
// document it was in and its container's element path); when that document is loaded again in its entry (a traversal, a
// reload: set_embedder, joint_reclaim), the frame that comes at that path takes them back, and shows its entry of the current
// position instead of its src, as do frames inside it in turn. Another document in the entry (a replace) forgets them.

import "core:strings"
import "wb:dom"

Joint_Step :: struct {
	top:   u64,   // the top-level entry current when it was made (History_Entry.id)
	nav:   u64,   // the frame's navigable (Navigable.id)
	entry: u64,   // the entry of the navigable's session it made current
	from:  u64,   // the one it left
}

// A frame of a document that left: its navigable is gone, its entries stay for the steps that name it and for the frame
// its document makes at the same place when it comes back.
Kept_Frame :: struct {
	nav:     u64,               // the navigable it was (the steps name it until a frame takes it back)
	doc:     u64,               // the document its container was in (a page id: History_Entry.doc of that document's entries)
	path:    string,            // owned: its container's element path there (Navigable.path)
	session: Session_History,   // its entries
}

// A traversal to an entry of another document: how many of that entry's steps apply at the position it goes to.
Joint_Arrive :: struct { entry: u64, steps: int }

kept_frame_destroy :: proc(k: ^Kept_Frame) {
	delete(k.path)
	session_destroy(&k.session)
}

// A navigable that names steps of the line: a live one, or one kept with its entries.
@(private = "file")
joint_nav_counts :: proc(sh: ^Session_History, nav: u64) -> bool {
	if navigable_by_id(nav) != nil { return true }
	for k in sh.kept { if k.nav == nav { return true } }
	return false
}

// The entries of navigable `nav`: a live one's, or those kept for it (nil: neither).
@(private = "file")
joint_nav_session :: proc(sh: ^Session_History, nav: u64) -> ^Session_History {
	if n := navigable_by_id(nav); n != nil { return &n.session }
	for &k in sh.kept { if k.nav == nav { return &k.session } }
	return nil
}

// Navigable `n` goes because its container's document leaves: kept when steps name it or a frame kept before it was in one
// of its documents (a session that lives with the page alone ends with it: nothing to come back to).
joint_keep_frame :: proc(n: ^Navigable) {
	p := n.parent
	top := page_top(p)
	if top.web == nil || top.web.session == &top.web.own_session { return }
	sh := top.web.session
	needed := false
	for s in sh.steps { if s.nav == n.id { needed = true; break } }
	if !needed { needed = joint_holds_kept(sh, &n.session) }
	if !needed { return }
	append(&sh.kept, Kept_Frame{nav = n.id, doc = p.web.id, path = strings.clone(n.path), session = n.session})
	n.session = {}
}

// Some kept frame was in a document of one of the entries of `fs`.
@(private = "file")
joint_holds_kept :: proc(sh: ^Session_History, fs: ^Session_History) -> bool {
	for k in sh.kept {
		if joint_entry_of_doc(fs, k.doc) != nil { return true }
	}
	return false
}

@(private = "file")
joint_entry_of_doc :: proc(fs: ^Session_History, doc: u64) -> ^History_Entry {
	if doc == 0 { return nil }
	for e in fs.entries { if e.doc == doc { return e } }
	return nil
}

// Document `doc` is loaded again as document `now` (set_embedder: the entry it showed is current again): its kept frames are now's.
joint_reclaim :: proc(sh: ^Session_History, doc, now: u64) {
	if sh == nil || doc == 0 || doc == now { return }
	for &k in sh.kept { if k.doc == doc { k.doc = now } }
}

// Another document takes the entry of document `doc` (a replace): its kept frames will not come back.
joint_forget_document :: proc(sh: ^Session_History, doc: u64) {
	if sh == nil || doc == 0 { return }
	for i := len(sh.kept) - 1; i >= 0; i -= 1 {
		if sh.kept[i].doc != doc { continue }
		kept_frame_destroy(&sh.kept[i])
		unordered_remove(&sh.kept, i)
	}
	joint_compact(sh)
}

// Frame `n` was just made (its initial about:blank) in a document loaded again: when a frame was kept at its place, `n` takes
// its entries and the steps that named it, and goes to its entry of the current position (that frame's document, from the
// network). False: nothing was kept there, its attributes say what it loads.
joint_restore_frame :: proc(n: ^Navigable) -> bool {
	p := n.parent
	sh := joint_session(p)
	if sh == nil || len(sh.kept) == 0 { return false }
	at := -1
	for k, i in sh.kept { if k.doc == p.web.id && k.path == n.path { at = i; break } }
	if at < 0 { return false }
	k := sh.kept[at]
	unordered_remove(&sh.kept, at)
	delete(k.path)
	session_destroy(&n.session)   // (its initial about:blank's: the document there, whose embedder holds &n.session, takes the kept ones)
	n.session = k.session
	for &s in sh.steps { if s.nav == k.nav { s.nav = n.id } }
	sh.serial += 1
	list, cur := joint_positions(sh)
	id := cur >= 0 ? joint_entry_at(sh, list, cur, n.id) : 0
	if id == 0 { id = session_current_id(&n.session) }
	e := session_find(&n.session, id)
	if e == nil { return false }
	commit := Frame_Commit{type = .Traverse, entry = e.id}
	if e.url == FRAME_SRCDOC_URL {
		markup, _ := dom.get_attribute(p.doc, n.element, "srcdoc")
		frame_navigate_srcdoc(n, strings.clone(markup, context.temp_allocator), commit)
	} else {
		frame_navigate(n, strings.clone(e.url, context.temp_allocator), commit = commit)
	}
	return true
}

// What a traversal moved.
Joint_Move :: enum u8 {
	None,             // nothing: no such position, or a listener canceled it
	Frames,           // frames only: the top-level document stays on its entry
	Top,              // the top-level document went to another of its own entries (and frames with it)
	Other_Document,   // the position is an entry of another top-level document: the embedder loads it
}

// A position: a top-level entry (index in Session_History.entries) and one of its steps (index in Session_History.steps), or
// its own (-1).
@(private = "file")
Joint_Pos :: struct { top, step: int }

// The session of the top-level navigable of document `p`'s tab.
joint_session :: proc(p: ^Page) -> ^Session_History {
	top := page_top(p)
	return top.web != nil ? top.web.session : nil
}

// How many steps were made while `top` (an entry id) was current.
joint_steps_of :: proc(sh: ^Session_History, top: u64) -> int {
	n := 0
	for s in sh.steps { if s.top == top { n += 1 } }
	return n
}

// The line the web sees (temp) and the current position (-1: none). The steps of navigables that are gone are left out.
@(private = "file")
joint_positions :: proc(sh: ^Session_History) -> (list: []Joint_Pos, current: int) {
	current = -1
	if sh == nil { return }
	out := make([dynamic]Joint_Pos, 0, len(sh.entries) + len(sh.steps), context.temp_allocator)
	for e, i in sh.entries {
		if e == sh.current { current = len(out) }
		append(&out, Joint_Pos{top = i, step = -1})
		k := 0   // (its steps so far, gone or not: frame_at counts them all)
		for s, j in sh.steps {
			if s.top != e.id { continue }
			k += 1
			if !joint_nav_counts(sh, s.nav) { continue }
			append(&out, Joint_Pos{top = i, step = j})
			if e == sh.current && k <= sh.frame_at { current = len(out) - 1 }
		}
	}
	return out[:], current
}

// The entry navigable `nav` shows at position `at` (0: it has no step on the line).
@(private = "file")
joint_entry_at :: proc(sh: ^Session_History, list: []Joint_Pos, at: int, nav: u64) -> u64 {
	last, first_from: u64
	for pos, i in list {
		if pos.step < 0 || sh.steps[pos.step].nav != nav { continue }
		if first_from == 0 { first_from = sh.steps[pos.step].from }
		if i > at { break }
		last = sh.steps[pos.step].entry
	}
	return last != 0 ? last : first_from
}

// history.length: the positions of the line.
joint_length :: proc(p: ^Page) -> int {
	list, _ := joint_positions(joint_session(p))
	return len(list)
}

// The line as the browser's interface shows it (back and forward): the top-level entry of each position (temp), the current one.
joint_view :: proc(sh: ^Session_History) -> (tops: []^History_Entry, current: int) {
	list, cur := joint_positions(sh)
	out := make([]^History_Entry, len(list), context.temp_allocator)
	for pos, i in list { out[i] = sh.entries[pos.top] }
	return out, cur
}

// The steps of the current entry ahead of the current position go, with the entries they made in their frames' sessions (a
// push makes another future).
joint_drop_ahead :: proc(sh: ^Session_History) {
	if sh.current == nil || len(sh.steps) == 0 { return }
	cur := sh.current.id
	k := 0
	for i := 0; i < len(sh.steps); {
		s := sh.steps[i]
		if s.top != cur { i += 1; continue }
		k += 1
		if k <= sh.frame_at { i += 1; continue }
		if fs := joint_nav_session(sh, s.nav); fs != nil {
			if e := session_find(fs, s.entry); e != nil { session_forget(fs, e) }
		}
		ordered_remove(&sh.steps, i)
	}
}

// The steps of navigables that are gone (and not kept) go, and the oldest past what the web sees of a path
// (history.max_entries); then the kept frames that nothing needs any more (no step names them, no frame kept in one of
// their documents).
@(private = "file")
joint_compact :: proc(sh: ^Session_History) {
	cur: u64 = sh.current != nil ? sh.current.id : 0
	applied, seen := 0, 0
	for i := 0; i < len(sh.steps); {
		s := sh.steps[i]
		mine := s.top == cur
		if mine { seen += 1 }
		if !joint_nav_counts(sh, s.nav) { ordered_remove(&sh.steps, i); continue }
		if mine && seen <= sh.frame_at { applied += 1 }
		i += 1
	}
	sh.frame_at = applied
	for len(sh.steps) > session_window(sh) {
		if sh.steps[0].top == cur { sh.frame_at -= 1 }
		ordered_remove(&sh.steps, 0)
	}
	outer: for i := len(sh.kept) - 1; i >= 0; i -= 1 {
		k := &sh.kept[i]
		for s in sh.steps { if s.nav == k.nav { continue outer } }
		if joint_holds_kept(sh, &k.session) { continue }
		kept_frame_destroy(k)
		unordered_remove(&sh.kept, i)
	}
}

// A push in the session of document `p` (from entry `from`): a frame's is a step of its tab's joint session history.
joint_pushed :: proc(p: ^Page, from: u64) {
	n := frame_navigable_of(p)
	cur := session_current(p.web.session)
	if n == nil || from == 0 || cur == nil || cur.id == from { return }
	joint_note_push(n, cur.id, from)
}

// Frame `n` made entry `entry` current, leaving `from`: the positions ahead of the current one go, then the step is the next.
joint_note_push :: proc(n: ^Navigable, entry, from: u64) {
	if n == nil || n.parent == nil || n.parent.closed { return }
	top := page_top(n.parent)
	sh := joint_session(top)
	if sh == nil || sh.current == nil { return }
	joint_drop_ahead(sh)
	if session_cut_ahead(sh) { post_page_task(top, proc(pg: ^Page, _: rawptr) { if pg != nil { navigation_sync(pg) } }, nil) }
	joint_compact(sh)
	append(&sh.steps, Joint_Step{top = sh.current.id, nav = n.id, entry = entry, from = from})
	sh.frame_at += 1
	sh.serial += 1
	notify_history_changed(top)
}

// How many positions away the nearest one where document `p`'s navigable shows entry `e` (of its own session) is, looking the
// way `e` lies in that session; false when the line has none.
joint_delta_to :: proc(p: ^Page, e: ^History_Entry) -> (int, bool) {
	own, ok := session_delta_of(p.web.session, e)
	if !ok || own == 0 { return 0, ok }
	sh := joint_session(p)
	list, cur := joint_positions(sh)
	if cur < 0 { return 0, false }
	n := frame_navigable_of(p)
	dir := own < 0 ? -1 : 1
	for at := cur + dir; at >= 0 && at < len(list); at += dir {
		shown := n != nil ? joint_entry_at(sh, list, at, n.id) : sh.entries[list[at].top].id
		if shown == e.id { return at - cur, true }
	}
	return 0, false
}

// Where `delta` positions take document `p`'s tab: the top-level entry there, how many of its steps are applied, what each
// frame shows (read before anything moves: a traversal's listeners may change the history).
@(private = "file")
Joint_Plan :: struct {
	top:     ^Page,
	target:  ^History_Entry,
	applied: int,
	shown:   [dynamic]Joint_Shown,   // temp
}

@(private = "file")
Joint_Shown :: struct { nav, entry: u64 }

@(private = "file")
joint_plan :: proc(p: ^Page, delta: int) -> (plan: Joint_Plan, ok: bool) {
	top := page_top(p)
	if top.closed || top.web == nil || delta == 0 { return }
	sh := top.web.session
	list, cur := joint_positions(sh)
	at := cur + delta
	if cur < 0 || at < 0 || at >= len(list) { return }
	plan.top, plan.target = top, sh.entries[list[at].top]
	if list[at].step >= 0 {
		for s, j in sh.steps { if s.top == plan.target.id && j <= list[at].step { plan.applied += 1 } }
	}
	plan.shown = make([dynamic]Joint_Shown, 0, len(list), context.temp_allocator)
	outer: for pos in list {
		if pos.step < 0 { continue }
		nav := sh.steps[pos.step].nav
		for x in plan.shown { if x.nav == nav { continue outer } }
		append(&plan.shown, Joint_Shown{nav, joint_entry_at(sh, list, at, nav)})
	}
	return plan, true
}

// HTML "allowed by sandboxing to navigate": a sandboxed document's traversal may move only navigables it may navigate (its
// own steps move its navigable and its descendants).
@(private = "file")
joint_plan_allowed :: proc(p: ^Page, plan: ^Joint_Plan) -> bool {
	if !page_sandbox(p).active { return true }
	if plan.target != plan.top.web.session.current && navigation_allowed(p, page_navigable(plan.top)) != "" { return false }
	for x in plan.shown {
		n := navigable_by_id(x.nav)
		if n != nil && x.entry != session_current_id(&n.session) && navigation_allowed(p, n) != "" { return false }
	}
	return true
}

// Whether document `p` may move its tab `delta` positions (navigation.traverseTo rejects what it may not).
joint_traverse_allowed :: proc(p: ^Page, delta: int) -> bool {
	plan, ok := joint_plan(p, delta)
	return !ok || joint_plan_allowed(p, &plan)
}

// Moves `delta` positions along the line of document `p`'s tab: each frame whose entry differs there is traversed, and the
// top-level document when the position is another of its entries. A position of another top-level document is returned for
// the embedder to load (`user`: the browser's buttons, navigate's userInitiated; a document's traversal moves nothing it may not
// navigate).
joint_traverse :: proc(p: ^Page, delta: int, user := false) -> (Joint_Move, ^History_Entry) {
	plan, ok := joint_plan(p, delta)
	if !ok || !user && !joint_plan_allowed(p, &plan) { return .None, nil }
	top := plan.top
	sh := top.web.session
	if plan.target != sh.current && plan.target.doc != top.web.id {
		// (its frames are made again: those kept show their entries of that position, joint_restore_frame)
		sh.arrive = {entry = plan.target.id, steps = plan.applied}
		return .Other_Document, plan.target
	}
	moved := Joint_Move.Frames
	if plan.target != sh.current {
		if history_traverse_to(top, plan.target, user) != .Same_Document || top.closed { return .None, nil }
		moved = .Top
	}
	sh.frame_at = plan.applied
	sh.serial += 1
	for x in plan.shown { joint_show(x.nav, x.entry) }
	return moved, nil
}

// Top-level document `p` came back from the back/forward cache for a position among its entry's steps: its frames go to
// what they show there (they showed what they had when it was left).
joint_show_position :: proc(p: ^Page) {
	sh := joint_session(p)
	if sh == nil { return }
	list, cur := joint_positions(sh)
	if cur < 0 { return }
	navs := make([dynamic]u64, 0, len(list), context.temp_allocator)
	outer: for pos in list {
		if pos.step < 0 { continue }
		nav := sh.steps[pos.step].nav
		for x in navs { if x == nav { continue outer } }
		append(&navs, nav)
	}
	for nav in navs { joint_show(nav, joint_entry_at(sh, list, cur, nav)) }
}

// Frame `nav` shows its entry `entry`: a same-document traversal, or its document loaded again.
@(private = "file")
joint_show :: proc(nav, entry: u64) {
	n := navigable_by_id(nav)
	if n == nil || n.page == nil || entry == 0 { return }
	e := session_find(&n.session, entry)
	if e == nil || e == session_current(&n.session) { return }
	href := strings.clone(e.url, context.temp_allocator)
	if history_traverse_to(n.page, e, user = false) != .Other_Document { return }
	if n = navigable_by_id(nav); n == nil { return }
	frame_navigate(n, href, commit = Frame_Commit{type = .Traverse, entry = entry})
}
