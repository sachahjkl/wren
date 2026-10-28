// The DOM domain (DOM Standard, HTML's DOM members, UI Events): the declarations of the browser functions the engine's
// DOM glue calls (native/js/odin/dom_*.odin, events.odin...), migrated from api/js_dom_*.widl. The generated imports
// wj.wr_<Name> are their lowering on today's wire (jsb checks it at compile time); the host side still serves them
// through the bindgen trampolines.
//
// A node is an EventTarget handle the browser hands out once per node; Node, Element and Document are kinds of it
// (a Document argument is a document node, an Element argument an element), named after their interface so jsb.this
// finds the interface. A Collection is a live collection the engine releases (Object_release).
package api_decl

import "../abi"

Node       :: distinct abi.Handle
Element    :: distinct abi.Handle
Document   :: distinct abi.Handle
Collection :: distinct abi.Handle
Event      :: distinct abi.Handle

// Which part of a document Document_partOf returns.
DocumentPart :: enum i32 { Document_Element, Head, Body, Doctype }

// HTMLElement.hidden's state.
HiddenState :: enum i32 { Shown, Hidden, Until_Found }

// What Node_insertItems does with the items (ParentNode / ChildNode).
InsertMode :: enum i32 { Prepend, Append, Replace_Children, Before, After, Replace_With }

// ---- collections ----

// A live collection of `kind` over `root` (src/page/js_dom_collections.odin; arg: the tag / class / name filter).
Collection_create    :: #type proc(root: Node, kind: i32, arg: string) -> (Collection, abi.Api_Error)
Collection_length    :: #type proc(coll: Collection) -> u32
Collection_item      :: #type proc(coll: Collection, index: u32) -> Node
Collection_namedItem :: #type proc(coll: Collection, name: string) -> Node
Object_release       :: #type proc(object: abi.Handle) -> abi.Api_Error
Node_pinAll          :: #type proc(nodes: []u64)
Node_unpinAll        :: #type proc(nodes: []u64)

// ---- Node ----

Node_nodeType            :: #type proc(node: Node) -> i32
Node_nodeName            :: #type proc(node: Node) -> (string, abi.Api_Error)
Node_nodeValue           :: #type proc(node: Node) -> (string, abi.Api_Error)        // Not_Found: null
Node_set_nodeValue       :: #type proc(node: Node, value: string) -> abi.Api_Error
Node_textContent         :: #type proc(node: Node) -> (string, abi.Api_Error)        // Not_Found: null
Node_set_textContent     :: #type proc(node: Node, value: string) -> abi.Api_Error
Node_parentNode          :: #type proc(node: Node) -> Node
// pre-insert `node` before `child` (0: at the end) / replace / pre-remove, with the DOM Standard's exceptions
Node_preInsert           :: #type proc(parent: Node, node: Node, child: Node) -> abi.Api_Error
Node_replaceChildChecked :: #type proc(parent: Node, node: Node, child: Node) -> abi.Api_Error
Node_preRemove           :: #type proc(parent: Node, child: Node) -> abi.Api_Error
// (Node or DOMString)... packed: 0 + an 8-byte node, or 1 + a 4-byte length + UTF-8
Node_insertItems         :: #type proc(node: Node, mode: InsertMode, items: abi.Bytes) -> abi.Api_Error
// the matches, 8 bytes per node
ParentNode_querySelectorAllPacked :: #type proc(node: Node, selectors: string) -> (abi.Bytes, abi.Api_Error)
NonElementParentNode_getElementById :: #type proc(node: Node, id: string) -> Element

// ---- Document ----

Window_document                 :: #type proc() -> Document
Document_createElementChecked   :: #type proc(local_name: string) -> (Element, abi.Api_Error)
Document_createElementInert     :: #type proc(local_name: string) -> (Element, abi.Api_Error)
Document_createElementNSChecked :: #type proc(namespace: Maybe(string), qualified_name: string) -> (Element, abi.Api_Error)
// an element of a document of its own (XML keeps the name's case); Not_Found: that document is an HTML one
Document_createXMLElement       :: #type proc(document: Document, namespace: Maybe(string), qualified_name: string, with_namespace: bool) -> (Element, abi.Api_Error)
Document_getElementById         :: #type proc(id: string) -> Element
Document_importNodeCopy         :: #type proc(node: Node, deep: bool) -> (Node, abi.Api_Error)
Document_partOf                 :: #type proc(document: Document, which: DocumentPart) -> Node
Document_set_body               :: #type proc(body: Element) -> abi.Api_Error
Document_xmlContentType         :: #type proc(document: Document) -> (string, abi.Api_Error)   // Not_Found: the page's
Document_contentType            :: #type proc() -> string
Document_URL                    :: #type proc() -> string
Document_createTextNode         :: #type proc(data: string) -> (Node, abi.Api_Error)
Document_createComment          :: #type proc(data: string) -> (Node, abi.Api_Error)
Document_createDocumentFragment :: #type proc() -> (Node, abi.Api_Error)
VisibilityState :: enum i32 { Visible, Hidden }
Document_visibilityState        :: #type proc() -> VisibilityState

DOMImplementation_createHTMLDocument :: #type proc(title: Maybe(string)) -> (Document, abi.Api_Error)
DOMImplementation_createDocumentType :: #type proc(name: string, public_id: string, system_id: string) -> (Node, abi.Api_Error)
DOMImplementation_createDocument     :: #type proc(namespace: Maybe(string), qualified_name: string, doctype: Node) -> (Document, abi.Api_Error)
DOMParser_parseHTMLNode              :: #type proc(html: string) -> (Document, abi.Api_Error)
DOMParser_parseXMLNode               :: #type proc(text: string, type: string) -> (Document, abi.Api_Error)
XMLSerializer_serialize              :: #type proc(node: Node) -> (string, abi.Api_Error)

// ---- Element and its attributes ----

Element_qualifiedTagName       :: #type proc(element: Element) -> (string, abi.Api_Error)
Element_namespaceURI           :: #type proc(element: Element) -> (string, abi.Api_Error)
Element_attributeNames         :: #type proc(element: Element) -> abi.Bytes   // NUL-separated
Element_attributeCount         :: #type proc(element: Element) -> u32
Element_attributeNameAt        :: #type proc(element: Element, index: u32) -> (string, abi.Api_Error)
Element_getAttribute           :: #type proc(element: Element, name: string) -> (string, abi.Api_Error)   // Not_Found: absent
Element_hasAttribute           :: #type proc(element: Element, name: string) -> bool
Element_setAttribute           :: #type proc(element: Element, name: string, value: string) -> abi.Api_Error
Element_setAttributeChecked    :: #type proc(element: Element, name: string, value: string) -> abi.Api_Error
Element_removeAttribute        :: #type proc(element: Element, name: string) -> abi.Api_Error
// force: -1 none, 0 false, 1 true
Element_toggleAttributeChecked :: #type proc(element: Element, name: string, force: i32) -> (bool, abi.Api_Error)
Element_set_innerHTML          :: #type proc(element: Element, value: string) -> abi.Api_Error
Element_set_outerHTML          :: #type proc(element: Element, value: string) -> abi.Api_Error

// DOMTokenList over attribute `attr` (tokens NUL-separated for add / remove)
TokenList_length   :: #type proc(element: Element, attr: string) -> u32
TokenList_item     :: #type proc(element: Element, attr: string, index: u32) -> (string, abi.Api_Error)
TokenList_contains :: #type proc(element: Element, attr: string, token: string) -> bool
TokenList_add      :: #type proc(element: Element, attr: string, tokens: abi.Bytes) -> abi.Api_Error
TokenList_remove   :: #type proc(element: Element, attr: string, tokens: abi.Bytes) -> abi.Api_Error
TokenList_toggle   :: #type proc(element: Element, attr: string, token: string, force: i32) -> (bool, abi.Api_Error)
TokenList_replace  :: #type proc(element: Element, attr: string, token: string, new_token: string) -> (bool, abi.Api_Error)
TokenList_supports :: #type proc(element: Element, attr: string, token: string) -> (bool, abi.Api_Error)

// DOMStringMap (dataset): names in their camel-case form, NUL-separated for the list
Dataset_get    :: #type proc(element: Element, name: string) -> (string, abi.Api_Error)
Dataset_set    :: #type proc(element: Element, name: string, value: string) -> abi.Api_Error
Dataset_delete :: #type proc(element: Element, name: string) -> abi.Api_Error
Dataset_names  :: #type proc(element: Element) -> abi.Bytes

// ---- HTML elements ----

HTMLElement_hiddenState   :: #type proc(element: Element) -> HiddenState
HTMLElement_focus         :: #type proc(element: Element) -> abi.Api_Error
HTMLElement_innerText     :: #type proc(element: Element) -> (string, abi.Api_Error)
HTMLElement_set_innerText :: #type proc(element: Element, value: string) -> abi.Api_Error
HTMLImageElement_naturalWidth  :: #type proc(image: Element) -> i32
HTMLImageElement_naturalHeight :: #type proc(image: Element) -> i32
// the ValidityState flags of any control (wr_ValidityState_*)
HTMLInputElement_validity      :: #type proc(control: Element) -> u32
// setRangeText's selectMode
SelectionMode :: enum i32 { Preserve, Select, Start, End }
// start / end -1: the selection
HTMLInputElement_setRangeText    :: #type proc(control: Element, text: string, start: i32, end: i32, mode: SelectionMode) -> abi.Api_Error
HTMLTextAreaElement_setRangeText :: #type proc(control: Element, text: string, start: i32, end: i32, mode: SelectionMode) -> abi.Api_Error
HTMLInputElement_valueAsDate     :: #type proc(control: Element) -> f64   // NaN: none
HTMLInputElement_setValueAsDate  :: #type proc(control: Element, ms: f64) -> abi.Api_Error
PointerCapture_set     :: #type proc(element: Element, pointer_id: i32) -> abi.Api_Error
PointerCapture_release :: #type proc(element: Element, pointer_id: i32) -> abi.Api_Error
PointerCapture_has     :: #type proc(element: Element, pointer_id: i32) -> bool

// ---- event handler content attributes ----

// What an inline script is, for the Content-Security-Policy check.
InlineScriptKind :: enum i32 { Element, Attribute, Navigation }
// Whether the page's CSP lets the inline script / handler `source` of `element` run (a refusal is reported).
Script_allowInline :: #type proc(element: Element, kind: InlineScriptKind, source: string) -> bool

// ---- EventTarget and Event (events.odin) ----

// An event target the browser knows: a node, a host object, the global (a handle of either kind).
EventTarget :: distinct abi.Handle

EventTarget_create :: #type proc() -> EventTarget
// options: wr_ListenerOptions bits (Capture, Once, Passive); the browser calls `callback` (a function-table index) with
// `user` for each event; the result is the listener's id
EventTarget_addEventListener    :: #type proc(target: EventTarget, type: string, callback: i32, user: i32, options: u32) -> (i32, abi.Api_Error)
EventTarget_removeEventListener :: #type proc(target: EventTarget, id: i32) -> abi.Api_Error
// an Event of the engine (engine_id: its wrapper) dispatched by the browser; init: wr_EventInit bits; true when not
// canceled
EventTarget_dispatchEngineEvent :: #type proc(target: EventTarget, type: string, init: u32, engine_id: i64, time_stamp: f64) -> (bool, abi.Api_Error)
// the target / relatedTarget of the last dispatchEngineEvent once retargeted (0: cleared)
EventTarget_lastTarget  :: #type proc() -> EventTarget
EventTarget_lastRelated :: #type proc() -> EventTarget
// the relatedTarget of the next dispatchEngineEvent
Event_setNextRelated    :: #type proc(related: Node)

Event_isLive                   :: #type proc(event: Event) -> bool
Event_engineId                 :: #type proc(event: Event) -> i64   // 0: a browser event
Event_interface                :: #type proc(event: Event) -> u32
Event_type                     :: #type proc(event: Event) -> string
Event_bubbles                  :: #type proc(event: Event) -> bool
Event_cancelable               :: #type proc(event: Event) -> bool
Event_composed                 :: #type proc(event: Event) -> bool
Event_isTrusted                :: #type proc(event: Event) -> bool
Event_timeStamp                :: #type proc(event: Event) -> f64
Event_target                   :: #type proc(event: Event) -> EventTarget
Event_currentTarget            :: #type proc(event: Event) -> EventTarget
Event_eventPhase               :: #type proc(event: Event) -> i32
Event_inShadowTreeNow          :: #type proc(event: Event) -> bool
Event_stopPropagation          :: #type proc(event: Event)
Event_stopImmediatePropagation :: #type proc(event: Event)
Event_propagationStopped       :: #type proc(event: Event) -> bool
Event_preventDefault           :: #type proc(event: Event)
Event_defaultPrevented         :: #type proc(event: Event) -> bool
// the path, 8 bytes per target (shadow.odin)
Event_composedPathPacked       :: #type proc(event: Event) -> abi.Bytes

// the interface name of a host object
Object_kind                    :: #type proc(object: abi.Handle) -> string
Window_self                    :: #type proc() -> EventTarget
DedicatedWorkerGlobalScope_self :: #type proc() -> EventTarget
Performance_now                :: #type proc() -> f64

// ---- tree walking (dom_observe.odin) ----

Node_firstChild      :: #type proc(node: Node) -> Node
Node_lastChild       :: #type proc(node: Node) -> Node
Node_nextSibling     :: #type proc(node: Node) -> Node
Node_previousSibling :: #type proc(node: Node) -> Node
Node_rootNode        :: #type proc(node: Node) -> Node
Node_contains        :: #type proc(node: Node, other: Node) -> bool
Node_length          :: #type proc(node: Node) -> u32
ChildNode_remove     :: #type proc(node: Node)
Text_splitText       :: #type proc(node: Node, offset: u32) -> (Node, abi.Api_Error)

// ---- MutationObserver ----

MutationObserver :: distinct abi.Handle

// notify: the function-table index of the notification (wj_cb_mutation), called with `user`
MutationObserver_create      :: #type proc(notify: i32, user: i32) -> MutationObserver
// options: childList 1, attributes 2, characterData 4, subtree 8, attributeOldValue 16, characterDataOldValue 32,
// attributeFilter 64 (the names NUL-separated)
MutationObserver_observe     :: #type proc(observer: MutationObserver, target: Node, options: u32, filter: abi.Bytes) -> abi.Api_Error
MutationObserver_disconnect  :: #type proc(observer: MutationObserver)
// the records, packed (dom_observe.odin take_records)
MutationObserver_takeRecords :: #type proc(observer: MutationObserver) -> abi.Bytes
MutationObserver_release     :: #type proc(observer: MutationObserver)

// ---- Range and Selection (boundary points: a node and an offset) ----

// -1, 0, 1: the first point is before, equal to, after the second
Range_comparePoints              :: #type proc(first: Node, first_offset: u32, second: Node, second_offset: u32) -> i32
Range_text                       :: #type proc(start: Node, start_offset: u32, end: Node, end_offset: u32) -> string
// mode: 0 clone, 1 extract, 2 delete; the fragment (0 for delete)
Range_contents                   :: #type proc(start: Node, start_offset: u32, end: Node, end_offset: u32, mode: i32) -> (Node, abi.Api_Error)
// the rectangles, 32 bytes each (x, y, width, height as f64)
Range_clientRectsPacked          :: #type proc(start: Node, start_offset: u32, end: Node, end_offset: u32) -> abi.Bytes
Range_createContextualFragment   :: #type proc(start: Node, markup: string) -> (Node, abi.Api_Error)
Selection_setRange               :: #type proc(anchor: Node, anchor_offset: u32, focus: Node, focus_offset: u32) -> abi.Api_Error
Selection_clear                  :: #type proc()
Selection_text                   :: #type proc() -> string

// ---- shadow trees, slots, markup (shadow.odin) ----

ShadowRootMode :: enum u32 { Open, Closed }
SlotAssignmentMode :: enum u32 { Named, Manual }

Element_attachShadowInit   :: #type proc(element: Element, mode: ShadowRootMode, delegates_focus: bool, slot_assignment: SlotAssignmentMode, clonable: bool, serializable: bool) -> (Node, abi.Api_Error)
Node_rootNodeComposed      :: #type proc(node: Node, composed: bool) -> Node
Node_isLive                :: #type proc(node: Node) -> bool
Node_getHTML               :: #type proc(node: Node, serializable_roots: bool, roots: []u64) -> (string, abi.Api_Error)
Node_setHTMLUnsafe         :: #type proc(node: Node, html: string) -> abi.Api_Error
Document_parseHTMLUnsafeNode :: #type proc(html: string) -> (Document, abi.Api_Error)
// the slot's assigned nodes / elements, 8 bytes each
HTMLSlotElement_assignedPacked :: #type proc(slot: Element, flatten: bool, elements: bool) -> (abi.Bytes, abi.Api_Error)
HTMLSlotElement_assignNodes    :: #type proc(slot: Element, nodes: []u64) -> abi.Api_Error
// the elements at (x, y), innermost first, 8 bytes each
DocumentOrShadowRoot_elementsFromPointPacked :: #type proc(root: Node, x: f64, y: f64) -> abi.Bytes
Shadow_fireSlotChanges     :: #type proc()

ElementInternals :: distinct abi.Handle

Element_attachInternals        :: #type proc(element: Element) -> (ElementInternals, abi.Api_Error)
ElementInternals_shadowRootOf  :: #type proc(internals: ElementInternals) -> Node
CustomStates_add               :: #type proc(internals: ElementInternals, state: string)
CustomStates_delete            :: #type proc(internals: ElementInternals, state: string) -> bool
CustomStates_has               :: #type proc(internals: ElementInternals, state: string) -> bool
CustomStates_clear             :: #type proc(internals: ElementInternals)
CustomStates_list              :: #type proc(internals: ElementInternals) -> abi.Bytes   // NUL-separated

// ---- stylesheets (src/page/js_cssom.odin) ----

CSSStyleSheet :: distinct abi.Handle

CSSStyleSheet_create         :: #type proc(media: string, disabled: bool, base_url: string) -> CSSStyleSheet   // 0: none here
CSSStyleSheet_isSheet        :: #type proc(sheet: CSSStyleSheet) -> bool
CSSStyleSheet_isConstructed  :: #type proc(sheet: CSSStyleSheet) -> bool
CSSStyleSheet_isDisabled     :: #type proc(sheet: CSSStyleSheet) -> bool
CSSStyleSheet_setDisabled    :: #type proc(sheet: CSSStyleSheet, disabled: bool)
CSSStyleSheet_replaceText    :: #type proc(sheet: CSSStyleSheet, text: string) -> abi.Api_Error
CSSStyleSheet_insertRuleAt   :: #type proc(sheet: CSSStyleSheet, rule: string, index: u32) -> (u32, abi.Api_Error)
CSSStyleSheet_deleteRuleAt   :: #type proc(sheet: CSSStyleSheet, index: u32) -> abi.Api_Error
CSSStyleSheet_ruleCount      :: #type proc(sheet: CSSStyleSheet) -> u32
CSSStyleSheet_ruleId         :: #type proc(sheet: CSSStyleSheet, index: u32) -> u32
CSSStyleSheet_rulesVersion   :: #type proc(sheet: CSSStyleSheet) -> u32
CSSStyleSheet_ruleText       :: #type proc(sheet: CSSStyleSheet, index: u32) -> (string, abi.Api_Error)
CSSStyleSheet_hrefOf         :: #type proc(sheet: CSSStyleSheet) -> (string, abi.Api_Error)   // empty: null
CSSStyleSheet_titleOf        :: #type proc(sheet: CSSStyleSheet) -> (string, abi.Api_Error)   // empty: null
CSSStyleSheet_ownerNodeOf    :: #type proc(sheet: CSSStyleSheet) -> Node
LinkStyle_sheetOf            :: #type proc(node: Node) -> CSSStyleSheet
DocumentOrShadowRoot_sheetCount :: #type proc(root: Node) -> u32
DocumentOrShadowRoot_sheetAt    :: #type proc(root: Node, index: u32) -> CSSStyleSheet
// adoptedStyleSheets: the constructed sheets of a root
DocumentOrShadowRoot_adopt      :: #type proc(root: Node, sheets: []u64) -> abi.Api_Error

// ---- events (UI Events' details of a browser event) ----

UiEvent_key            :: #type proc(event: Event) -> string
UiEvent_code           :: #type proc(event: Event) -> string
Event_data             :: #type proc(event: Event) -> string
Event_text             :: #type proc(event: Event) -> string
Event_object           :: #type proc(event: Event) -> Node
Event_relatedNow       :: #type proc(event: Event) -> abi.Handle
DragEvent_dataTransfer :: #type proc(event: Event) -> abi.Handle
