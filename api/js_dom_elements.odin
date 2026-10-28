// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=31 partial
/// Elements for JavaScript: names and namespaces, attributes (with their namespaces, as far as the browser keeps
/// them), selectors, markup (innerHTML / outerHTML / insertAdjacent*), the members of HTMLElement and of the hyperlink
/// elements (src/page/js_dom_elements.odin, js_dom_markup.odin). A nullable string result is Not_Found for null.
package api_js_dom_elements

/// element.namespaceURI (Not_Found: null).
//@wb fn raises
Element_namespaceURI :: proc(element: Element) -> string

/// element.prefix (Not_Found: null).
//@wb fn raises
Element_prefix :: proc(element: Element) -> string

/// element.localName (SVG names with their case).
//@wb fn
Element_localName :: proc(element: Element) -> string

/// element.tagName: the qualified name, upper case for HTML elements.
//@wb fn
Element_qualifiedTagName :: proc(element: Element) -> string

/// element.slot
//@wb fn
Element_slot :: proc(element: Element) -> string

/// element.slot = value
//@wb fn raises
Element_set_slot :: proc(element: Element, value: string)

/// element.hasAttributes()
//@wb fn
Element_hasAttributes :: proc(element: Element) -> bool

/// The attributes' names in order, each followed by a NUL byte.
//@wb fn
Element_attributeNames :: proc(element: Element) -> string

/// The number of attributes.
//@wb fn
Element_attributeCount :: proc(element: Element) -> u32

/// The name of the attribute at `index` (Not_Found past the end).
//@wb fn raises
Element_attributeNameAt :: proc(element: Element, index: u32) -> string

/// element.getAttributeNS(namespace, localName) (Not_Found: null).
//@wb fn raises optional=namespace
Element_getAttributeNS :: proc(element: Element, namespace: string, local_name: string) -> string

/// element.setAttribute(name, value): Invalid_Character for a name that is not a valid attribute name.
//@wb fn raises
Element_setAttributeChecked :: proc(element: Element, name: string, value: string)

/// element.setAttributeNS(namespace, qualifiedName, value): Invalid_Character, Namespace.
//@wb fn raises optional=namespace
Element_setAttributeNS :: proc(element: Element, namespace: string, qualified_name: string, value: string)

/// element.removeAttributeNS(namespace, localName)
//@wb fn optional=namespace
Element_removeAttributeNS :: proc(element: Element, namespace: string, local_name: string)

/// element.toggleAttribute(name, force): force -1 absent, 0 false, 1 true. Invalid_Character.
//@wb fn raises
Element_toggleAttributeChecked :: proc(element: Element, name: string, force: i32) -> bool

/// element.hasAttribute(name)
//@wb fn
Element_hasAttribute :: proc(element: Element, name: string) -> bool

/// element.hasAttributeNS(namespace, localName)
//@wb fn optional=namespace
Element_hasAttributeNS :: proc(element: Element, namespace: string, local_name: string) -> bool

/// element.closest(selectors): Syntax for an invalid selector list.
//@wb fn raises
Element_closest :: proc(element: Element, selectors: string) -> Element

/// element.matches(selectors): Syntax for an invalid selector list.
//@wb fn raises
Element_matches :: proc(element: Element, selectors: string) -> bool

/// element.webkitMatchesSelector(selectors)
//@wb fn raises
Element_webkitMatchesSelector :: proc(element: Element, selectors: string) -> bool

/// element.insertAdjacentElement(where, element): Syntax for a bad position, the tree errors of insertBefore.
//@wb fn raises
Element_insertAdjacentElement :: proc(element: Element, position: string, other: Element) -> Element

/// element.insertAdjacentText(where, data)
//@wb fn raises
Element_insertAdjacentText :: proc(element: Element, position: string, data: string)

/// element.insertAdjacentHTML(position, text): No_Modification_Allowed beside the document element.
//@wb fn raises
Element_insertAdjacentHTML :: proc(element: Element, position: string, text: string)

/// element.innerHTML: the HTML fragment serialization of its children (a template's: its contents').
//@wb fn
Element_innerHTML :: proc(element: Element) -> string

/// element.innerHTML = markup: parsed as a fragment in the element's context, one mutation replacing the children.
//@wb fn raises
Element_set_innerHTML :: proc(element: Element, value: string)

/// element.outerHTML
//@wb fn
Element_outerHTML :: proc(element: Element) -> string

/// element.outerHTML = markup: No_Modification_Allowed when the parent is the document.
//@wb fn raises
Element_set_outerHTML :: proc(element: Element, value: string)

/// element.shadowRoot: null (no shadow trees).
//@wb fn
Element_shadowRoot :: proc(element: Element) -> Node

/// The `hidden` content attribute as HTMLElement.hidden reads it: 0 absent, 1 present, 2 "until-found".
//@wb fn
HTMLElement_hiddenState :: proc(element: Element) -> i32

/// htmlElement.dir: "ltr", "rtl", "auto" or "".
//@wb fn
HTMLElement_dir :: proc(element: Element) -> string

/// htmlElement.dir = value
//@wb fn raises
HTMLElement_set_dir :: proc(element: Element, value: string)

/// htmlElement.translate
//@wb fn
HTMLElement_translate :: proc(element: Element) -> bool

/// htmlElement.translate = value
//@wb fn raises
HTMLElement_set_translate :: proc(element: Element, value: bool)

/// htmlElement.draggable
//@wb fn
HTMLElement_draggable :: proc(element: Element) -> bool

/// htmlElement.draggable = value
//@wb fn raises
HTMLElement_set_draggable :: proc(element: Element, value: bool)

/// htmlElement.spellcheck
//@wb fn
HTMLElement_spellcheck :: proc(element: Element) -> bool

/// htmlElement.spellcheck = value
//@wb fn raises
HTMLElement_set_spellcheck :: proc(element: Element, value: bool)

/// htmlElement.innerText: the rendered text (from the layout's text when the element is rendered, else
/// textContent).
//@wb fn
HTMLElement_innerText :: proc(element: Element) -> string

/// htmlElement.innerText = value: text nodes and <br> for line feeds.
//@wb fn raises
HTMLElement_set_innerText :: proc(element: Element, value: string)

/// htmlElement.outerText
//@wb fn
HTMLElement_outerText :: proc(element: Element) -> string

/// htmlElement.outerText = value: No_Modification_Allowed without a parent.
//@wb fn raises
HTMLElement_set_outerText :: proc(element: Element, value: string)

/// htmlElement.accessKeyLabel ("": no access keys)
//@wb fn
HTMLElement_accessKeyLabel :: proc(element: Element) -> string

/// element.tabIndex: the attribute, else 0 for focusable elements and -1 for the others.
//@wb fn
HTMLOrSVGOrMathMLElement_tabIndex :: proc(element: Element) -> i32

/// element.tabIndex = value
//@wb fn raises
HTMLOrSVGOrMathMLElement_set_tabIndex :: proc(element: Element, value: i32)

/// element.nonce
//@wb fn
HTMLOrSVGOrMathMLElement_nonce :: proc(element: Element) -> string

/// element.nonce = value
//@wb fn raises
HTMLOrSVGOrMathMLElement_set_nonce :: proc(element: Element, value: string)

/// element.contentEditable: "true", "false", "plaintext-only" or "inherit".
//@wb fn
ElementContentEditable_contentEditable :: proc(element: Element) -> string

/// element.contentEditable = value: Syntax for anything else.
//@wb fn raises
ElementContentEditable_set_contentEditable :: proc(element: Element, value: string)

/// element.isContentEditable
//@wb fn
ElementContentEditable_isContentEditable :: proc(element: Element) -> bool

/// a.href / area.href: the URL resolved, or the attribute as is when it does not parse.
//@wb fn
HTMLHyperlinkElementUtils_href :: proc(element: Element) -> string

/// a.href = value
//@wb fn raises
HTMLHyperlinkElementUtils_set_href :: proc(element: Element, value: string)

/// a.origin
//@wb fn
HyperlinkElementUtils_origin :: proc(element: Element) -> string

/// a.protocol and the other components (URL Standard setters; nothing for a URL that does not parse)
//@wb fn
HyperlinkElementUtils_protocol :: proc(element: Element) -> string

//@wb fn raises
HyperlinkElementUtils_set_protocol :: proc(element: Element, value: string)

//@wb fn
HyperlinkElementUtils_username :: proc(element: Element) -> string

//@wb fn raises
HyperlinkElementUtils_set_username :: proc(element: Element, value: string)

//@wb fn
HyperlinkElementUtils_password :: proc(element: Element) -> string

//@wb fn raises
HyperlinkElementUtils_set_password :: proc(element: Element, value: string)

//@wb fn
HyperlinkElementUtils_host :: proc(element: Element) -> string

//@wb fn raises
HyperlinkElementUtils_set_host :: proc(element: Element, value: string)

//@wb fn
HyperlinkElementUtils_hostname :: proc(element: Element) -> string

//@wb fn raises
HyperlinkElementUtils_set_hostname :: proc(element: Element, value: string)

//@wb fn
HyperlinkElementUtils_port :: proc(element: Element) -> string

//@wb fn raises
HyperlinkElementUtils_set_port :: proc(element: Element, value: string)

//@wb fn
HyperlinkElementUtils_pathname :: proc(element: Element) -> string

//@wb fn raises
HyperlinkElementUtils_set_pathname :: proc(element: Element, value: string)

//@wb fn
HyperlinkElementUtils_search :: proc(element: Element) -> string

//@wb fn raises
HyperlinkElementUtils_set_search :: proc(element: Element, value: string)

//@wb fn
HyperlinkElementUtils_hash :: proc(element: Element) -> string

//@wb fn raises
HyperlinkElementUtils_set_hash :: proc(element: Element, value: string)

/// a.text: its textContent.
//@wb fn
HTMLAnchorElement_text :: proc(element: Element) -> string

/// a.text = value
//@wb fn raises
HTMLAnchorElement_set_text :: proc(element: Element, value: string)

/// template.content
//@wb fn
HTMLTemplateElement_content :: proc(element: Element) -> Node

