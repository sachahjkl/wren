package page

import "core:strings"
import "wb:base"
import "wb:dom"

// XMLSerializer (DOM Parsing §3.2, "XML serialization", the well-formed flag off) for JavaScript: native/js/runtime/
// dom_core.c (wjr_XMLSerializer_*), api/js_xml.widl. A node and its subtree as XML: each element's namespace declared
// where it differs from the one in scope (xmlns="..." on the first HTML element, on an <svg> inside HTML...), prefixed
// names and the xlink: / xml: attributes of SVG declared as they appear, empty elements of other namespaces closed
// as <x/>, HTML void elements as <br />, text and attribute values escaped, a template's contents as its children.
// Without recursion (deep trees); its length is bounded by page.max_fetch_bytes (the memory a page's data may take).

@(private = "file")
VOID_ELEMENTS :: [?]string{"area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "img", "input", "keygen", "link", "meta", "param", "source", "track", "wbr"}

@(private = "file")
xml_escape :: proc(b: ^strings.Builder, s: string, attribute: bool) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&': strings.write_string(b, "&amp;")
		case '<': strings.write_string(b, "&lt;")
		case '>': strings.write_string(b, "&gt;")
		case '"': if attribute { strings.write_string(b, "&quot;") } else { strings.write_byte(b, '"') }
		case: strings.write_byte(b, s[i])
		}
	}
}

// Known prefixes of attributes the HTML parser keeps with their prefix (SVG's xlink:href, xml:lang...).
@(private = "file")
prefix_uri :: proc(prefix: string) -> string {
	switch prefix {
	case "xlink": return dom.NS_XLINK
	case "xml": return dom.NS_XML
	case "xmlns": return dom.NS_XMLNS
	}
	return ""
}

// The XML serialization of `root` (a node of the page's document or of one of its inert documents).
xml_serialize :: proc(p: ^Page, root: base.Handle, limit: int) -> (out: string, ok: bool) {
	d := p.doc
	b := strings.builder_make(context.temp_allocator)
	Item :: struct {
		h:      base.Handle,
		close:  bool,
		ns:     string,          // the default namespace in scope for the node's children
		depth:  int,             // index of the prefixes this element declared (popped with it)
	}
	prefixes := make([dynamic][2]string, 0, 8, context.temp_allocator)   // prefix, uri in scope
	marks := make([dynamic]int, 0, 32, context.temp_allocator)
	stack := make([dynamic]Item, 0, 64, context.temp_allocator)
	declared :: proc(prefixes: [][2]string, prefix: string) -> string {
		for i := len(prefixes) - 1; i >= 0; i -= 1 { if prefixes[i][0] == prefix { return prefixes[i][1] } }
		return prefix_uri(prefix) if prefix == "xml" else ""
	}
	start := root
	if rn := dom.get(d, root); rn != nil && (rn.kind == .Document || rn.kind == .Fragment) {
		for c := rn.last_child; c != base.NIL_HANDLE; c = dom.get(d, c).prev { append(&stack, Item{h = c}) }
		start = base.NIL_HANDLE
	}
	if start != base.NIL_HANDLE { append(&stack, Item{h = start}) }
	for len(stack) > 0 {
		if strings.builder_len(b) > limit { return "", false }
		it := pop(&stack)
		n := dom.get(d, it.h)
		if n == nil { continue }
		if it.close {
			strings.write_string(&b, "</")
			strings.write_string(&b, jd_qualified_name(d, it.h, false))
			strings.write_byte(&b, '>')
			if len(marks) > 0 { resize(&prefixes, pop(&marks)) }
			continue
		}
		switch n.kind {
		case .Text:
			if n.xml == .CDATA {
				strings.write_string(&b, "<![CDATA[")
				strings.write_string(&b, n.text)
				strings.write_string(&b, "]]>")
			} else {
				xml_escape(&b, n.text, false)
			}
			continue
		case .Comment:
			if n.xml == .Processing_Instruction {
				strings.write_string(&b, "<?")
				strings.write_string(&b, n.name)
				strings.write_byte(&b, ' ')
				strings.write_string(&b, n.text)
				strings.write_string(&b, "?>")
				continue
			}
			strings.write_string(&b, "<!--")
			strings.write_string(&b, n.text)
			strings.write_string(&b, "-->")
			continue
		case .Doctype:
			strings.write_string(&b, "<!DOCTYPE ")
			strings.write_string(&b, n.name)
			pub, sys := "", ""
			for a in n.attrs {
				if a.name == "publicId" { pub = a.value }
				if a.name == "systemId" { sys = a.value }
			}
			if pub != "" {
				strings.write_string(&b, " PUBLIC \"")
				strings.write_string(&b, pub)
				strings.write_byte(&b, '"')
			} else if sys != "" {
				strings.write_string(&b, " SYSTEM")
			}
			if sys != "" {
				strings.write_string(&b, " \"")
				strings.write_string(&b, sys)
				strings.write_byte(&b, '"')
			}
			strings.write_byte(&b, '>')
			continue
		case .Document, .Fragment:
			for c := n.last_child; c != base.NIL_HANDLE; c = dom.get(d, c).prev { append(&stack, Item{h = c, ns = it.ns}) }
			continue
		case .Element:
		}
		uri := dom.ns_uri(d, it.h)
		prefix := dom.ns_prefix(d, it.h)
		qname := jd_qualified_name(d, it.h, false)
		append(&marks, len(prefixes))
		strings.write_byte(&b, '<')
		strings.write_string(&b, qname)
		// the element's own namespace
		has_xmlns := false
		for a in n.attrs { if a.name == "xmlns" { has_xmlns = true } }
		child_ns := it.ns
		if prefix != "" {
			if declared(prefixes[:], prefix) != uri {
				strings.write_string(&b, " xmlns:")
				strings.write_string(&b, prefix)
				strings.write_string(&b, "=\"")
				xml_escape(&b, uri, true)
				strings.write_byte(&b, '"')
				append(&prefixes, [2]string{prefix, uri})
			}
		} else if uri != it.ns {
			if !has_xmlns {
				strings.write_string(&b, " xmlns=\"")
				xml_escape(&b, uri, true)
				strings.write_byte(&b, '"')
			}
			child_ns = uri
		}
		// attributes: a prefix not in scope is declared first (the ones the HTML parser keeps: xlink, xml)
		for a in n.attrs {
			if colon := strings.index_byte(a.name, ':'); colon > 0 {
				ap := a.name[:colon]
				if ap != "xmlns" && ap != "xml" && declared(prefixes[:], ap) == "" {
					if u := prefix_uri(ap); u != "" {
						already := false
						for x in n.attrs { if x.name == strings.concatenate({"xmlns:", ap}, context.temp_allocator) { already = true } }
						if !already {
							strings.write_string(&b, " xmlns:")
							strings.write_string(&b, ap)
							strings.write_string(&b, "=\"")
							strings.write_string(&b, u)
							strings.write_byte(&b, '"')
						}
						append(&prefixes, [2]string{ap, u})
					}
				}
			}
		}
		for a in n.attrs {
			if strings.has_prefix(a.name, "xmlns:") { append(&prefixes, [2]string{a.name[6:], a.value}) }
			strings.write_byte(&b, ' ')
			strings.write_string(&b, jd_attr_name(n, a.name))
			strings.write_string(&b, "=\"")
			xml_escape(&b, a.value, true)
			strings.write_byte(&b, '"')
		}
		// children: a template's are its contents
		first := n.first_child
		if n.ns == .HTML && n.name == "template" { if c, okc := d.templates[it.h]; okc { if cn := dom.get(d, c); cn != nil { first = cn.first_child } } }
		if first == base.NIL_HANDLE {
			if n.ns == .HTML {
				void := false
				for v in VOID_ELEMENTS { if v == n.name { void = true; break } }
				if void {
					strings.write_string(&b, " />")
					resize(&prefixes, pop(&marks))
					continue
				}
				strings.write_string(&b, "></")
				strings.write_string(&b, qname)
				strings.write_byte(&b, '>')
			} else {
				strings.write_string(&b, "/>")
			}
			resize(&prefixes, pop(&marks))
			continue
		}
		strings.write_byte(&b, '>')
		append(&stack, Item{h = it.h, close = true})
		kids := make([dynamic]base.Handle, 0, 8, context.temp_allocator)
		for c := first; c != base.NIL_HANDLE; c = dom.get(d, c).next { append(&kids, c) }
		for i := len(kids) - 1; i >= 0; i -= 1 { append(&stack, Item{h = kids[i], ns = child_ns}) }
	}
	return strings.to_string(b), true
}

XMLSerializer_serialize :: proc(c: ^Call, node: Api_Node) -> (string, Api_Error) {
	s, ok := xml_serialize(c.page, H(node.handle), c.page.settings.max_fetch_bytes)
	if !ok { return "", fail(c, .Range, "the serialization is longer than page.max_fetch_bytes") }
	return s, .None
}
