package dom

import "wb:base"

// Mutation hooks: what the embedder does, synchronously, when the tree changes in a way scripts react to at once (HTML:
// a script element that becomes connected runs, and a script element's text inserted later too; an event handler
// content attribute that is set registers its handler; a script's src set later fetches it). The page installs them
// (src/page/js_load.odin); a document without hooks (a parse in progress on another thread) calls nothing.
//
// Contract for callers of insert_before / append_child / set_attribute / remove_attribute on a document with hooks:
// the hook may run scripts, which may create, move and free nodes. Do not keep a ^Node across these calls (handles
// stay valid or dead, never dangling). Code that inserts several nodes as one operation (a fragment, innerHTML) mutes
// the hooks around it: what happens meanwhile is reported, in order, when the last hooks_unmute runs.

Hook_Kind :: enum u8 { Inserted, Attribute }

Hook_Event :: struct {
	kind: Hook_Kind,
	node: base.Handle,
	name: string,   // Attribute: the attribute's name (lower case, owned while queued)
}

Hooks :: struct {
	user:      rawptr,
	// `node` was inserted (it may have a subtree); called once the tree is consistent again
	inserted:  proc(user: rawptr, d: ^Document, node: base.Handle),
	// an attribute of `element` was set, changed or removed
	attribute: proc(user: rawptr, d: ^Document, element: base.Handle, name: string),
	muted:     int,
	queued:    [dynamic]Hook_Event,
}

hooks_set :: proc(d: ^Document, h: Hooks) {
	hooks_free(d)
	d.hooks = h
	d.hooks.muted = 0
	d.hooks.queued = nil
}

hooks_mute :: proc(d: ^Document) { d.hooks.muted += 1 }

// Ends a muted section; the last one reports what happened meanwhile.
hooks_unmute :: proc(d: ^Document) {
	if d.hooks.muted == 0 { return }
	d.hooks.muted -= 1
	if d.hooks.muted > 0 { return }
	for len(d.hooks.queued) > 0 {
		ev := d.hooks.queued[0]
		ordered_remove(&d.hooks.queued, 0)
		switch ev.kind {
		case .Inserted: if d.hooks.inserted != nil { d.hooks.inserted(d.hooks.user, d, ev.node) }
		case .Attribute: if d.hooks.attribute != nil { d.hooks.attribute(d.hooks.user, d, ev.node, ev.name) }
		}
		delete(ev.name)
	}
}

@(private)
hooks_free :: proc(d: ^Document) {
	for ev in d.hooks.queued { delete(ev.name) }
	delete(d.hooks.queued)
	d.hooks.queued = nil
}

@(private)
notify_inserted :: proc(d: ^Document, node: base.Handle) {
	if d.hooks.inserted == nil { return }
	if d.hooks.muted > 0 { append(&d.hooks.queued, Hook_Event{kind = .Inserted, node = node}); return }
	d.hooks.inserted(d.hooks.user, d, node)
}

@(private)
notify_attribute :: proc(d: ^Document, element: base.Handle, name: string) {
	if d.hooks.attribute == nil { return }
	if d.hooks.muted > 0 { append(&d.hooks.queued, Hook_Event{kind = .Attribute, node = element, name = heap_str(name)}); return }
	d.hooks.attribute(d.hooks.user, d, element, name)
}
