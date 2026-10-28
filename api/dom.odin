// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=10 exposed=(Window,Worker)
/// The document tree (DOM Standard: Document, Node, Element). In a worker there is no document: the functions taking a
/// node see no live node, and those returning one return null.
package api_dom

//@wb handle parent=EventTarget host=dom.Node lookup=lookup_Node
/// A node of the document. A node created by the module and never inserted lives until Node_release.
Node :: distinct Handle

//@wb handle parent=Node host=dom.Node lookup=lookup_Element
/// A node that is an element.
Element :: distinct Handle

/// document.documentElement (null in a worker).
//@wb fn
Document_documentElement :: proc() -> Element

/// document.head (null in a worker).
//@wb fn
Document_head :: proc() -> Element

/// document.body (null in a worker).
//@wb fn
Document_body :: proc() -> Element

/// document.createElement(tag). Invalid_Argument for an empty tag, Invalid_Handle in a worker (no document).
//@wb fn raises
Document_createElement :: proc(tag: string) -> Element

/// document.createTextNode(text). Invalid_Handle in a worker.
//@wb fn raises
Document_createTextNode :: proc(text: string) -> Node

/// document.getElementById(id): null when there is none.
//@wb fn
Document_getElementById :: proc(id: string) -> Element

/// parent.appendChild(child).
//@wb fn raises
Node_appendChild :: proc(parent: Node, child: Node)

/// parent.insertBefore(child, ref): ref null appends. Not_Found when ref is not a child of parent.
//@wb fn raises optional=ref
Node_insertBefore :: proc(parent: Node, child: Node, ref: Node)

/// parent.removeChild(child). Not_Found when child is not a child of parent.
//@wb fn raises
Node_removeChild :: proc(parent: Node, child: Node)

/// Frees a detached node (and its subtree) the module no longer needs. Attached when it is still in the tree.
//@wb fn raises
Node_release :: proc(node: Node)

/// node.parentNode (null when detached).
//@wb fn
Node_parentNode :: proc(node: Node) -> Node

/// node.firstChild
//@wb fn
Node_firstChild :: proc(node: Node) -> Node

/// node.lastChild
//@wb fn
Node_lastChild :: proc(node: Node) -> Node

/// node.previousSibling
//@wb fn
Node_previousSibling :: proc(node: Node) -> Node

/// node.nextSibling
//@wb fn
Node_nextSibling :: proc(node: Node) -> Node

/// node.nodeType: 1 element, 3 text, 8 comment, 9 document.
//@wb fn
Node_nodeType :: proc(node: Node) -> i32

/// node.textContent = text
//@wb fn raises
Node_setTextContent :: proc(node: Node, text: string)

/// node.textContent
//@wb fn
Node_getTextContent :: proc(node: Node) -> string

/// element.tagName (lower case for HTML elements).
//@wb fn
Element_tagName :: proc(element: Element) -> string

/// element.setAttribute(name, value)
//@wb fn raises
Element_setAttribute :: proc(element: Element, name: string, value: string)

/// element.getAttribute(name): Not_Found when the attribute is absent (null).
//@wb fn raises
Element_getAttribute :: proc(element: Element, name: string) -> string

/// element.removeAttribute(name)
//@wb fn raises
Element_removeAttribute :: proc(element: Element, name: string)

