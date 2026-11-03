package dom

import "core:strings"
import "wb:base"

// The namespace of an attribute (DOM §4.9.2): an index, not a string. None is the null namespace (nearly every
// attribute's); the three the parsers give have fixed indexes; any other URI (setAttributeNS) is kept once in its
// document's `attr_namespaces`, at the index past the fixed ones.
Attr_Ns :: distinct u16

ATTR_NS_NONE  :: Attr_Ns(0)
ATTR_NS_XLINK :: Attr_Ns(1)
ATTR_NS_XML   :: Attr_Ns(2)
ATTR_NS_XMLNS :: Attr_Ns(3)

// The URIs of the fixed indexes.
@(private = "file")
ATTR_NS_FIXED :: [?]string{"", NS_XLINK, NS_XML, NS_XMLNS}

// The index of namespace `uri` in `d` ("" = null), added when new.
attr_ns_of :: proc(d: ^Document, uri: string) -> Attr_Ns {
	if ns, ok := attr_ns_find(d, uri); ok { return ns }
	append(&d.attr_namespaces, strings.clone(uri))
	return Attr_Ns(len(ATTR_NS_FIXED) + len(d.attr_namespaces) - 1)
}

// The index of namespace `uri` in `d` when some attribute has had it (none can have it otherwise).
attr_ns_find :: proc(d: ^Document, uri: string) -> (Attr_Ns, bool) {
	fixed := ATTR_NS_FIXED
	for f, i in fixed { if f == uri { return Attr_Ns(i), true } }
	for u, i in d.attr_namespaces { if u == uri { return Attr_Ns(len(ATTR_NS_FIXED) + i), true } }
	return ATTR_NS_NONE, false
}

// The URI of namespace `ns` ("" = null).
attr_ns_uri :: proc(d: ^Document, ns: Attr_Ns) -> string {
	fixed := ATTR_NS_FIXED
	if int(ns) < len(fixed) { return fixed[ns] }
	return d.attr_namespaces[int(ns) - len(fixed)]
}

// The local name of a qualified name in namespace `ns`: all of it in none (setAttribute("pre:fix") has no prefix),
// else what follows the first colon.
attr_local_of :: proc(ns: Attr_Ns, qualified: string) -> string {
	if ns == ATTR_NS_NONE { return qualified }
	if colon := strings.index_byte(qualified, ':'); colon >= 0 { return qualified[colon + 1:] }
	return qualified
}

attr_local :: #force_inline proc(a: Attr) -> string { return attr_local_of(a.ns, a.name) }

// The prefix of an attribute ("" = none).
attr_prefix :: proc(a: Attr) -> string {
	if a.ns == ATTR_NS_NONE { return "" }
	if colon := strings.index_byte(a.name, ':'); colon >= 0 { return a.name[:colon] }
	return ""
}

// HTML "adjust foreign attributes" (§13.2.6.1): the namespaces of the attributes the HTML parser gave an SVG or MathML
// element by their qualified names.
adjust_foreign_attributes :: proc(d: ^Document, h: base.Handle) {
	n := get(d, h)
	if n == nil || n.kind != .Element { return }
	for &a in n.attrs {
		switch a.name {
		case "xlink:actuate", "xlink:arcrole", "xlink:href", "xlink:role", "xlink:show", "xlink:title", "xlink:type": a.ns = ATTR_NS_XLINK
		case "xml:lang", "xml:space": a.ns = ATTR_NS_XML
		case "xmlns", "xmlns:xlink": a.ns = ATTR_NS_XMLNS
		}
	}
}
