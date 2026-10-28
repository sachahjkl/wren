// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=36 partial
/// MutationObserver, Range and Selection for JavaScript (src/page/js_dom_observe.odin, js_dom_range.odin).
///
/// MutationObserver: the browser sees every mutation as it happens (the mutation hook of the document's journal,
/// src/dom/journal.odin) and queues records for the observers registered on the node or, with `subtree`, on an
/// ancestor (transient registrations included), then a microtask (`notify`, with the observer's `user`) that delivers
/// them. The nodes of queued records are pinned until the engine took them.
package api_js_dom_observe

/// new MutationObserver: `notify(user)` runs as a microtask when records are queued.
//@wb fn
MutationObserver_create :: proc(notify: MicrotaskCallback, user: i32) -> Object

/// observer.observe(target, options): bits 1 childList, 2 attributes, 4 characterData, 8 subtree,
/// 16 attributeOldValue, 32 characterDataOldValue, 64 an attributeFilter (`filter`, names NUL-separated).
/// Type when no kind of mutation is asked for (as DOM says, after the implied ones).
//@wb fn raises
MutationObserver_observe :: proc(observer: u64, target: Node, options: u32, filter: string)

/// observer.disconnect(): no more registrations, the queue emptied.
//@wb fn
MutationObserver_disconnect :: proc(observer: u64)

/// observer.takeRecords(): the records waiting, packed (src/page/js_dom_observe.odin, records_pack). Nothing
/// changes until MutationObserver_release, so a call that did not fit can be made again.
//@wb fn
MutationObserver_takeRecords :: proc(observer: u64) -> bytes

/// The engine wrapped the nodes of the records it took: they leave the queue (and their pins go), the transient
/// registrations end (DOM "notify mutation observers").
//@wb fn
MutationObserver_release :: proc(observer: u64)

/// Whether some node the observer is registered on is still alive (the engine lets an observer go otherwise).
//@wb fn
MutationObserver_live :: proc(observer: u64) -> bool

/// A boundary point compared with another: -1 before, 0 equal, 1 after (DOM "position of a boundary point").
//@wb fn
Range_comparePoints :: proc(first: Node, first_offset: u32, second: Node, second_offset: u32) -> i32

/// range.toString(): the text of the Text nodes in the range.
//@wb fn
Range_text :: proc(start: Node, start_offset: u32, end: Node, end_offset: u32) -> string

/// The contents of a range: mode 0 cloneContents (a new fragment), 1 extractContents (a fragment, the contents
/// removed), 2 deleteContents (returns 0). Hierarchy when a doctype is in the range.
//@wb fn raises
Range_contents :: proc(start: Node, start_offset: u32, end: Node, end_offset: u32, mode: i32) -> Node

/// range.createContextualFragment(markup): parsed with the range's start node (its parent element for a Text or a
/// Comment) as the context element, a <body> without one or for <html>; the scripts of the fragment are not marked
/// "already started" (they run once inserted), except one the markup left open (HTML: end of input in a script).
//@wb fn raises
Range_createContextualFragment :: proc(start: Node, markup: string) -> Node

/// The document's selection.
SelectionState :: struct {
	anchor: u64,
	anchor_offset: u32,
	focus: u64,
	focus_offset: u32,
	/// 0 none, 1 caret (collapsed), 2 range
	kind: u32,
}

/// The selection (offsets in UTF-16 code units for Text nodes).
//@wb fn
Selection_state :: proc() -> SelectionState

/// setBaseAndExtent: Index_Size for an offset past a node's length, Invalid_Handle for a node outside the document.
//@wb fn raises
Selection_setRange :: proc(anchor: Node, anchor_offset: u32, focus: Node, focus_offset: u32)

/// removeAllRanges()
//@wb fn
Selection_clear :: proc()

/// selection.toString()
//@wb fn
Selection_text :: proc() -> string

