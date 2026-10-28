// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=44 partial
/// Shadow trees for JavaScript (DOM §4.2.2 and §4.8, HTML slots and declarative shadow roots, ElementInternals,
/// CSSOM constructable stylesheets): src/page/js_shadow.odin, native/js/runtime/shadow.c, native/js/prelude/shadow.js.
/// Modes: 0 open, 1 closed; slot assignment: 0 named, 1 manual.
package api_js_shadow__dom

/// element.attachShadow(init): Not_Supported for an element that cannot host one, a host already (unless its root
/// was declared by the parser with the same mode: emptied and returned), or a custom element whose definition
/// disables shadow roots.
//@wb fn raises
Element_attachShadowInit :: proc(element: Element, mode: u32, delegates_focus: bool, slot_assignment: u32, clonable: bool, serializable: bool) -> Node

/// The definition of custom element `name` disables shadow roots or element internals (its disabledFeatures):
/// attachShadow / attachInternals refuse.
//@wb fn
CustomElements_disable :: proc(name: string, shadow: bool, internals: bool)

/// shadowRoot.mode: "open" or "closed".
//@wb fn
ShadowRoot_mode :: proc(root: Node) -> string

/// shadowRoot.delegatesFocus
//@wb fn
ShadowRoot_delegatesFocus :: proc(root: Node) -> bool

/// shadowRoot.clonable
//@wb fn
ShadowRoot_clonable :: proc(root: Node) -> bool

/// shadowRoot.serializable
//@wb fn
ShadowRoot_serializable :: proc(root: Node) -> bool

/// shadowRoot.slotAssignment: "named" or "manual".
//@wb fn
ShadowRoot_slotAssignment :: proc(root: Node) -> string

/// shadowRoot.host
//@wb fn
ShadowRoot_host :: proc(root: Node) -> Element

/// shadowRoot.innerHTML
//@wb fn
ShadowRoot_innerHTML :: proc(root: Node) -> string

/// shadowRoot.innerHTML = markup: parsed in the host's context (no declarative shadow roots), one mutation.
//@wb fn raises
ShadowRoot_set_innerHTML :: proc(root: Node, value: string)

/// shadowRoot.activeElement: the focused element retargeted against the root (null when it is not in its tree).
//@wb fn
ShadowRoot_activeElement :: proc(root: Node) -> Element

/// element.getHTML(options) / shadowRoot.getHTML(options): the children's serialization, with the shadow roots of
/// hosts that are serializable (when `serializable_roots`) or listed in `roots`, as declarative shadow roots.
//@wb fn
Node_getHTML :: proc(node: Node, serializable_roots: bool, roots: []u64) -> string

/// element.setHTMLUnsafe(html) / shadowRoot.setHTMLUnsafe(html): parsed with declarative shadow roots, one mutation.
//@wb fn raises
Node_setHTMLUnsafe :: proc(node: Node, html: string)

/// Document.parseHTMLUnsafe(html): a new inert document (as createHTMLDocument makes) with declarative shadow roots.
//@wb fn raises
Document_parseHTMLUnsafeNode :: proc(html: string) -> Node

/// node.getRootNode({composed})
//@wb fn
Node_rootNodeComposed :: proc(node: Node, composed: bool) -> Node

/// node.assignedSlot: the slot it is assigned to, null when none or in a closed shadow root.
//@wb fn
Slottable_assignedSlot :: proc(node: Node) -> Element

/// slot.assignedNodes({flatten}) / assignedElements({flatten}) (`elements`): node handles, 8 bytes each.
//@wb fn
HTMLSlotElement_assignedPacked :: proc(slot: Element, flatten: bool, elements: bool) -> bytes

/// slot.assign(...nodes): the slot's manually assigned nodes.
//@wb fn raises
HTMLSlotElement_assignNodes :: proc(slot: Element, nodes: []u64)

/// The handles of every element named `name` in shadow-including tree order (custom element upgrades at define).
//@wb fn
Document_shadowIncludingByName :: proc(name: string) -> bytes

/// elementsFromPoint(x, y) of the document or of a shadow root: the elements hit, retargeted against `root`,
/// innermost first. Handles, 8 bytes each.
//@wb fn
DocumentOrShadowRoot_elementsFromPointPacked :: proc(root: Node, x: f64, y: f64) -> bytes

/// Fires slotchange at the slots signalled since the last time (the engine's job, wj_slot_queue).
//@wb fn
Shadow_fireSlotChanges :: proc()

/// Whether `node` is a live node of the page (not destroyed).
//@wb fn
Node_isLive :: proc(node: u64) -> bool

/// The shadow-including descendants of `root` that are elements, in tree order (customElements.upgrade).
//@wb fn
Node_shadowIncludingElements :: proc(root: Node) -> bytes

