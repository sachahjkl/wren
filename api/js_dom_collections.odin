// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=30 partial
/// Collections of nodes for JavaScript (src/page/js_dom_collections.odin): live NodeLists and HTMLCollections over the
/// tree (childNodes, children, getElementsBy*, document.forms...), kept by the browser with a cache that the
/// document's change counters invalidate, so that walking one by index is linear; static lists (querySelectorAll);
/// DOMTokenList (classList, relList...) and DOMStringMap (dataset) over content attributes.
package api_js_dom_collections

/// A live collection. Kinds: 0 child nodes, 1 child elements, 2 elements by qualified name (arg; "*" all), 3 by
/// class names (arg), 4 by name attribute (arg), 5 forms, 6 images, 7 links (a and area with href), 8 scripts,
/// 9 embeds, 10 anchors (a with name), 11 elements by namespace and local name (arg: namespace, NUL, local name;
/// "*" any), 12 all elements, 13 the select's / datalist's options, 14 a table's rows, 15 a row's cells, 16 a table's
/// tBodies, 17 a form's elements. Invalid_Argument for an unknown kind.
//@wb fn raises
Collection_create :: proc(root: Node, kind: i32, arg: string) -> Object

/// The number of nodes (0 for a dead collection).
//@wb fn
Collection_length :: proc(collection: u64) -> u32

/// The node at `index`, 0 past the end.
//@wb fn
Collection_item :: proc(collection: u64, index: u32) -> u64

/// HTMLCollection.namedItem(name): the first element whose id or name (for the elements that have one) is `name`.
//@wb fn
Collection_namedItem :: proc(collection: u64, name: string) -> u64

/// The supported property names of an HTMLCollection, each followed by a NUL byte.
//@wb fn
Collection_names :: proc(collection: u64) -> string

/// node.querySelectorAll(selectors): the elements in tree order, 8 bytes (a handle, little endian) each. Syntax for
/// an invalid selector list.
//@wb fn raises
ParentNode_querySelectorAllPacked :: proc(node: Node, selectors: string) -> bytes

/// form[name]: the first of the form's controls whose id or name is `name` (0 when none; the form's named
/// properties shadow its prototype's, [LegacyOverrideBuiltIns], so this answers for every property read).
//@wb fn
HTMLFormElement_namedControl :: proc(form: Element, name: string) -> u64

/// node.querySelector(selectors)
//@wb fn raises
ParentNode_querySelector :: proc(node: Node, selectors: string) -> Element

/// DOMTokenList over the content attribute `attr` of an element: its tokens (ordered set, ASCII whitespace split).
//@wb fn
TokenList_length :: proc(element: Element, attr: string) -> u32

/// The token at `index` (Not_Found: null).
//@wb fn raises
TokenList_item :: proc(element: Element, attr: string, index: u32) -> string

//@wb fn
TokenList_contains :: proc(element: Element, attr: string, token: string) -> bool

/// add(tokens...): `tokens` NUL-separated. Syntax for an empty token, Invalid_Character for one with whitespace.
//@wb fn raises
TokenList_add :: proc(element: Element, attr: string, tokens: string)

/// remove(tokens...): as add.
//@wb fn raises
TokenList_remove :: proc(element: Element, attr: string, tokens: string)

/// toggle(token, force): force -1 absent, 0 false, 1 true. Returns whether the token is there afterwards.
//@wb fn raises
TokenList_toggle :: proc(element: Element, attr: string, token: string, force: i32) -> bool

/// replace(token, newToken): whether it was there.
//@wb fn raises
TokenList_replace :: proc(element: Element, attr: string, token: string, new_token: string) -> bool

/// supports(token): for rel lists, whether the browser knows the link type. Type for lists without supported tokens.
//@wb fn raises
TokenList_supports :: proc(element: Element, attr: string, token: string) -> bool

/// dataset[name]: the data-* attribute of a camel-cased name (Not_Found: absent).
//@wb fn raises
Dataset_get :: proc(element: Element, name: string) -> string

/// dataset[name] = value: Syntax for a name with "-" followed by a lower-case letter, Invalid_Character for a name
/// that does not make a valid attribute name.
//@wb fn raises
Dataset_set :: proc(element: Element, name: string, value: string)

/// delete dataset[name]: whether there was one.
//@wb fn
Dataset_delete :: proc(element: Element, name: string) -> bool

/// The camel-cased names of the data-* attributes, each followed by a NUL byte.
//@wb fn
Dataset_names :: proc(element: Element) -> string

