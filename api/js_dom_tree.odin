// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=38 partial
/// The DOM Standard's tree for JavaScript: Node, the ParentNode / ChildNode mixins, CharacterData, Text, DocumentType,
/// the creation of nodes and the mutation algorithms with every check of "pre-insert validity" (src/page/js_dom_tree.odin).
/// Offsets and lengths of character data are UTF-16 code units, as in JavaScript. A nullable string result is
/// Not_Found for null.
package api_js_dom_tree

/// node.nodeName ("#text", "DIV", "#document"...).
//@wb fn
Node_nodeName :: proc(node: Node) -> string

/// node.baseURI: the document's base URL.
//@wb fn
Node_baseURI :: proc(node: Node) -> string

/// node.isConnected
//@wb fn
Node_isConnected :: proc(node: Node) -> bool

/// node.ownerDocument (null for the document itself).
//@wb fn
Node_ownerDocument :: proc(node: Node) -> Node

/// node.parentElement
//@wb fn
Node_parentElement :: proc(node: Node) -> Element

/// node.hasChildNodes()
//@wb fn
Node_hasChildNodes :: proc(node: Node) -> bool

/// node.nodeValue: the data of a Text or Comment node, Not_Found (null) for the others.
//@wb fn raises
Node_nodeValue :: proc(node: Node) -> string

/// node.nodeValue = value (nothing for nodes without data).
//@wb fn raises
Node_set_nodeValue :: proc(node: Node, value: string)

/// node.textContent (Not_Found: null, for the document and a doctype).
//@wb fn raises
Node_textContent :: proc(node: Node) -> string

/// node.textContent = value: one mutation replacing every child by a Text node (none for "").
//@wb fn raises
Node_set_textContent :: proc(node: Node, value: string)

/// node.normalize()
//@wb fn
Node_normalize :: proc(node: Node)

/// node.cloneNode(deep). Not_Supported for the document (one document per page). The elements of the clone whose name
/// has a custom element definition are upgraded before it returns, unless `node` is in a template's contents (an inert
/// document: no definition applies there).
//@wb fn raises
Node_cloneNode :: proc(node: Node, deep: bool = false) -> Node

/// document.importNode(node, deep): the clone belongs to this document, whatever document `node` is in (a template's
/// contents included), so its elements of a defined name are upgraded before it returns.
//@wb fn raises
Document_importNodeCopy :: proc(node: Node, deep: bool = false) -> Node

/// node.isEqualNode(other)
//@wb fn optional=other
Node_isEqualNode :: proc(node: Node, other: Node) -> bool

/// node.isSameNode(other)
//@wb fn optional=other
Node_isSameNode :: proc(node: Node, other: Node) -> bool

/// node.compareDocumentPosition(other): DOCUMENT_POSITION_* bits.
//@wb fn
Node_compareDocumentPosition :: proc(node: Node, other: Node) -> u32

/// node.contains(other)
//@wb fn optional=other
Node_contains :: proc(node: Node, other: Node) -> bool

/// node.lookupPrefix(namespace) (Not_Found: null).
//@wb fn raises optional=namespace
Node_lookupPrefix :: proc(node: Node, namespace: string) -> string

/// node.lookupNamespaceURI(prefix) (Not_Found: null).
//@wb fn raises optional=prefix
Node_lookupNamespaceURI :: proc(node: Node, prefix: string) -> string

/// node.isDefaultNamespace(namespace)
//@wb fn optional=namespace
Node_isDefaultNamespace :: proc(node: Node, namespace: string) -> bool

/// node.getRootNode() (no shadow trees: the root of its tree).
//@wb fn
Node_rootNode :: proc(node: Node) -> Node

/// The length of a node (DOM "length"): UTF-16 code units of a Text or Comment node, else its number of children.
//@wb fn
Node_length :: proc(node: Node) -> u32

/// parent.insertBefore(node, child) / appendChild (child absent): DOM "pre-insert", every check (Hierarchy,
/// Not_Found), a DocumentFragment's children inserted as one mutation.
//@wb fn raises optional=child
Node_preInsert :: proc(parent: Node, node: Node, child: Node)

/// parent.replaceChild(node, child): DOM "replace a child".
//@wb fn raises
Node_replaceChildChecked :: proc(parent: Node, node: Node, child: Node)

/// parent.removeChild(child): Not_Found when child is not a child of parent.
//@wb fn raises
Node_preRemove :: proc(parent: Node, child: Node)

/// prepend / append / replaceChildren (mode 0, 1, 2) of ParentNode, before / after / replaceWith (3, 4, 5) of
/// ChildNode, with their (Node or DOMString) arguments packed in `items`: per item one byte 0 then a node handle (8
/// bytes, little endian), or one byte 1 then a length (4 bytes) and UTF-8 text.
//@wb fn raises
Node_insertItems :: proc(node: Node, mode: i32, items: bytes)

/// The node handles of `nodes` stay alive while pinned (a static NodeList, a mutation record).
//@wb fn
Node_pinAll :: proc(nodes: []u64)

/// Drops the pins of Node_pinAll (dead handles are ignored).
//@wb fn
Node_unpinAll :: proc(nodes: []u64)

/// node.firstElementChild
//@wb fn
ParentNode_firstElementChild :: proc(node: Node) -> Element

/// node.lastElementChild
//@wb fn
ParentNode_lastElementChild :: proc(node: Node) -> Element

/// node.childElementCount
//@wb fn
ParentNode_childElementCount :: proc(node: Node) -> u32

/// node.remove()
//@wb fn
ChildNode_remove :: proc(node: Node)

/// node.previousElementSibling
//@wb fn
NonDocumentTypeChildNode_previousElementSibling :: proc(node: Node) -> Element

/// node.nextElementSibling
//@wb fn
NonDocumentTypeChildNode_nextElementSibling :: proc(node: Node) -> Element

/// fragment.getElementById(id) (the document has its own)
//@wb fn
NonElementParentNode_getElementById :: proc(node: Node, id: string) -> Element

/// characterData.data
//@wb fn
CharacterData_data :: proc(node: Node) -> string

/// characterData.data = value
//@wb fn
CharacterData_set_data :: proc(node: Node, value: string)

/// characterData.length (UTF-16 code units)
//@wb fn
CharacterData_length :: proc(node: Node) -> u32

/// substringData(offset, count): Index_Size past the end.
//@wb fn raises
CharacterData_substringData :: proc(node: Node, offset: u32, count: u32) -> string

/// appendData(data)
//@wb fn
CharacterData_appendData :: proc(node: Node, data: string)

/// insertData(offset, data): Index_Size past the end.
//@wb fn raises
CharacterData_insertData :: proc(node: Node, offset: u32, data: string)

/// deleteData(offset, count): Index_Size past the end.
//@wb fn raises
CharacterData_deleteData :: proc(node: Node, offset: u32, count: u32)

/// replaceData(offset, count, data): Index_Size past the end.
//@wb fn raises
CharacterData_replaceData :: proc(node: Node, offset: u32, count: u32, data: string)

/// text.splitText(offset): the new Text node (inserted after it when it has a parent). Index_Size past the end.
//@wb fn raises
Text_splitText :: proc(node: Node, offset: u32) -> Node

/// text.wholeText
//@wb fn
Text_wholeText :: proc(node: Node) -> string

/// doctype.name
//@wb fn
DocumentType_name :: proc(node: Node) -> string

/// doctype.publicId
//@wb fn
DocumentType_publicId :: proc(node: Node) -> string

/// doctype.systemId
//@wb fn
DocumentType_systemId :: proc(node: Node) -> string

/// document.createElement(localName): Invalid_Character for a name that is not a valid element name.
//@wb fn raises
Document_createElementChecked :: proc(local_name: string) -> Element

/// createElement(localName) of a document other than the page's (createHTMLDocument, DOMParser, the one a template's
/// contents belong to): no custom element registry, so the element is made as is and never constructed or upgraded.
//@wb fn raises
Document_createElementInert :: proc(local_name: string) -> Element

/// document.createElementNS(namespace, qualifiedName): Invalid_Character, Namespace as DOM "validate and extract".
//@wb fn raises optional=namespace
Document_createElementNSChecked :: proc(namespace: string, qualified_name: string) -> Element

/// document.createDocumentFragment()
//@wb fn raises
Document_createDocumentFragment :: proc() -> Node

/// document.createComment(data)
//@wb fn raises
Document_createComment :: proc(data: string) -> Node

/// document.createCDATASection(data): Not_Supported (an HTML document).
//@wb fn raises
Document_createCDATASection :: proc(data: string) -> Node

/// document.adoptNode(node): removed from its parent (one document per page). Not_Supported for the document.
//@wb fn raises
Document_adoptNode :: proc(node: Node) -> Node

/// document.documentURI
//@wb fn
Document_documentURI :: proc() -> string

/// document.compatMode: "CSS1Compat" or "BackCompat".
//@wb fn
Document_compatMode :: proc() -> string

/// document.characterSet
//@wb fn
Document_characterSet :: proc() -> string

/// document.charset
//@wb fn
Document_charset :: proc() -> string

/// document.inputEncoding
//@wb fn
Document_inputEncoding :: proc() -> string

/// document.contentType
//@wb fn
Document_contentType :: proc() -> string

/// document.doctype
//@wb fn
Document_doctype :: proc() -> Node

/// document.title: the <title> text, whitespace collapsed (the <svg> root's title in an SVG document).
//@wb fn
Document_title :: proc() -> string

/// document.title = value: the first <title> (made in <head> when missing).
//@wb fn
Document_set_title :: proc(value: string)

/// document.dir
//@wb fn
Document_dir :: proc() -> string

/// document.dir = value
//@wb fn
Document_set_dir :: proc(value: string)

/// document.hasFocus()
//@wb fn
Document_hasFocus :: proc() -> bool

/// document.referrer
//@wb fn
Document_referrer :: proc() -> string

/// document.lastModified ("MM/DD/YYYY hh:mm:ss")
//@wb fn
Document_lastModified :: proc() -> string

/// document.domain (getter)
//@wb fn
Document_domain :: proc() -> string

/// document.scrollingElement
//@wb fn
Document_scrollingElement :: proc() -> Element

/// document.body = element: Hierarchy when not a <body> or <frameset>, or without a document element.
//@wb fn raises optional=body
Document_set_body :: proc(body: Element)

/// document.implementation.createHTMLDocument(title): an inert document of its own (nothing loads or runs in it),
/// made of the page's nodes: a doctype, <html>, <head> (with <title> when given) and <body>.
//@wb fn raises optional=title
DOMImplementation_createHTMLDocument :: proc(title: string) -> Node

/// new DOMParser().parseFromString(html, "text/html"): a new inert document (as createHTMLDocument makes) holding
/// the whole document parsed from `html` (no declarative shadow roots, nothing loads or runs in it).
//@wb fn raises
DOMParser_parseHTMLNode :: proc(html: string) -> Node

/// parseFromString(text, type) for the XML types (text/xml, application/xml, application/xhtml+xml, image/svg+xml):
/// a new inert XML document; one whose element is <parsererror> when the text is not well-formed. Type for another
/// type, Quota past dom.max_fragment_nodes.
//@wb fn raises
DOMParser_parseXMLNode :: proc(text: string, type: string) -> Node

/// processingInstruction.target
//@wb fn
ProcessingInstruction_target :: proc(node: Node) -> string

/// document.contentType of an XML document (DOMParser's type); Not_Found for an HTML one.
//@wb fn raises
Document_xmlContentType :: proc(document: Node) -> string

/// createElement(localName) (`with_namespace` false) or createElementNS(namespace, qualifiedName) of an XML document
/// (DOMParser's XML types, createDocument): an element of that document, whose names keep their case (tagName as
/// written, attribute names as given); createElement gives it the HTML namespace only in an application/xhtml+xml
/// document. Invalid_Character, Namespace as the others; Not_Found when `document` is not an XML document.
//@wb fn raises optional=namespace
Document_createXMLElement :: proc(document: Node, namespace: string, qualified_name: string, with_namespace: bool) -> Element

/// document.implementation.createDocument(namespace, qualifiedName, doctype): a new inert XMLDocument, with the
/// doctype (a node made by createDocumentType, not in a tree) and its element when the name is not empty; its
/// contentType follows the namespace (application/xhtml+xml, image/svg+xml, else application/xml).
//@wb fn raises optional=namespace,doctype
DOMImplementation_createDocument :: proc(namespace: string, qualified_name: string, doctype: Node) -> Node

/// document.implementation.createDocumentType(name, publicId, systemId): Invalid_Character for a bad name.
//@wb fn raises
DOMImplementation_createDocumentType :: proc(name: string, public_id: string, system_id: string) -> Node

/// A part of a document node (the page's or one createHTMLDocument made): 0 documentElement, 1 head, 2 body,
/// 3 doctype. 0 when there is none.
//@wb fn
Document_partOf :: proc(document: Node, which: i32) -> Node

