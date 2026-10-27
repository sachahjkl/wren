package page

// DOMParser's XML types (DOM Parsing §, HTML §8.5.1: text/xml, application/xml, application/xhtml+xml, image/svg+xml):
// the text parsed by package xml into a new inert XML document (a Fragment with as_document, xml = .Document), its
// elements in their namespaces (XHTML, SVG and MathML ones as the HTML parser makes them, other names keeping their
// case), CDATA sections and processing instructions as their XML node kinds. A document that is not well-formed gives
// a document whose element is <parsererror> (Gecko's namespace) saying what and where, as browsers do.
//
// Its elements are marked as XML ones (dom.Xml_Kind.Element: attribute names keep their case, tagName as written);
// scripts never run in such a document.

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:xml"

NS_PARSERERROR :: "http://www.mozilla.org/newlayout/xml/parsererror.xml"

@(private = "file")
Xml_Build :: struct {
	d:       ^dom.Document,
	stack:   [dynamic]base.Handle,
	count:   int,
	limit:   int,
	over:    bool,
}

@(private = "file")
build_add :: proc(b: ^Xml_Build, h: base.Handle) -> bool {
	b.count += 1
	if b.count > b.limit { b.over = true; dom.destroy_unpinned(b.d, h); return false }
	dom.append_child(b.d, b.stack[len(b.stack) - 1], h)
	return true
}

// An element of the namespace `uri`, as the HTML parser or createElementNS would make it.
xml_create_element :: proc(d: ^dom.Document, uri, prefix, local: string) -> base.Handle {
	ns: dom.Namespace
	switch uri {
	case dom.NS_HTML: ns = .HTML
	case dom.NS_SVG: ns = .SVG
	case dom.NS_MATHML: ns = .MathML
	case "": ns = .None
	case: ns = .Other
	}
	h := dom.create_element_ns(d, local, ns, uri, prefix)
	n := dom.get(d, h)
	// an element of an XML document: its attributes' names keep their case, its tagName is not upper-cased
	n.xml = .Element
	// names keep their case (XML is case-sensitive: an XHTML <DIV> is no div); SVG's and MathML's stay lower case, the
	// browser's form for them (the bindings give SVG names their case back)
	if ns != .SVG && ns != .MathML && n.name != local { delete(n.name); n.name = strings.clone(local) }
	return h
}

@(private = "file")
xml_build :: proc(d: ^dom.Document, f: base.Handle, src: string, limit: int) -> (xml.Result, bool) {
	b := Xml_Build{d = d, limit = limit}
	b.stack = make([dynamic]base.Handle, 0, 64, context.temp_allocator)
	append(&b.stack, f)
	sink := xml.Sink{user = &b}
	sink.start_element = proc(u: rawptr, uri, prefix, local: string, attrs: []xml.Attribute) {
		b := (^Xml_Build)(u)
		if b.over { return }
		h := xml_create_element(b.d, uri, prefix, local)
		for a in attrs {
			name := a.prefix != "" ? strings.concatenate({a.prefix, ":", a.local}, context.temp_allocator) : a.local
			dom.set_attribute(b.d, h, name, a.value)
		}
		if build_add(b, h) { append(&b.stack, h) } else { append(&b.stack, base.NIL_HANDLE) }
	}
	sink.end_element = proc(u: rawptr) {
		b := (^Xml_Build)(u)
		if len(b.stack) > 1 { pop(&b.stack) }
	}
	sink.text = proc(u: rawptr, s: string) {
		b := (^Xml_Build)(u)
		if b.over { return }
		// adjacent text (a text run cut by a reference) stays one node
		parent := dom.get(b.d, b.stack[len(b.stack) - 1])
		if parent != nil && parent.last_child != base.NIL_HANDLE {
			if last := dom.get(b.d, parent.last_child); last != nil && last.kind == .Text && last.xml == .None {
				dom.set_data(b.d, parent.last_child, strings.concatenate({last.text, s}, context.temp_allocator))
				return
			}
		}
		build_add(b, dom.create_text(b.d, s))
	}
	sink.cdata = proc(u: rawptr, s: string) {
		b := (^Xml_Build)(u)
		if b.over { return }
		h := dom.create_text(b.d, s)
		dom.get(b.d, h).xml = .CDATA
		build_add(b, h)
	}
	sink.comment = proc(u: rawptr, s: string) {
		b := (^Xml_Build)(u)
		if !b.over { build_add(b, dom.create_comment(b.d, s)) }
	}
	sink.pi = proc(u: rawptr, target, data: string) {
		b := (^Xml_Build)(u)
		if b.over { return }
		h := dom.create_comment(b.d, data)
		n := dom.get(b.d, h)
		n.xml = .Processing_Instruction
		n.name = strings.clone(target)
		build_add(b, h)
	}
	sink.doctype = proc(u: rawptr, name, pub, sys: string) {
		b := (^Xml_Build)(u)
		if !b.over { build_add(b, dom.create_doctype(b.d, name, pub, sys)) }
	}
	r := xml.parse(src, &sink)
	return r, !b.over
}

// new DOMParser().parseFromString(text, <an XML type>): always a document (a <parsererror> one when the text is not
// well-formed XML); Quota past dom.max_fragment_nodes.
DOMParser_parseXMLNode :: proc(c: ^Call, text: string, type: string) -> (u64, Api_Error) {
	d := jd_doc(c)
	if d == nil { return 0, no_document(c) }
	kind: dom.Xml_Kind
	switch type {
	case "application/xml": kind = .Document
	case "text/xml": kind = .Document_Text_XML
	case "application/xhtml+xml": kind = .Document_XHTML
	case "image/svg+xml": kind = .Document_SVG
	case: return 0, fail(c, .Type, "TypeError: not an XML type of DOMParserSupportedType")
	}
	f := dom.create_fragment(d)
	fn := dom.get(d, f)
	fn.as_document, fn.xml = true, kind
	if _, fits := xml_fill(d, f, text, c.page.settings.dom.max_fragment_nodes, c.page.env.location.href); !fits {
		dom.destroy_unpinned(d, f)
		return 0, fail(c, .Quota, "the document has more nodes than dom.max_fragment_nodes")
	}
	return u64(f), .None
}

// `text` parsed as XML under `parent` (a document node): its nodes, or, when it is not well-formed, a <parsererror>
// element saying what and where (`location`: the document's URL), as browsers show. fits = false past `limit` nodes
// (what was built stays for the caller to drop). Any thread: touches nothing but `d`.
xml_fill :: proc(d: ^dom.Document, parent: base.Handle, text: string, limit: int, location: string) -> (well_formed, fits: bool) {
	src := strings.clone(text, context.temp_allocator)
	r: xml.Result
	r, fits = xml_build(d, parent, src, limit)
	if !fits || r.ok { return r.ok, fits }
	// what was built goes: the document is the error
	for ch := dom.get(d, parent).first_child; ch != base.NIL_HANDLE; ch = dom.get(d, parent).first_child {
		dom.remove_child(d, parent, ch)
		dom.destroy_unpinned(d, ch)
	}
	pe := xml_create_element(d, NS_PARSERERROR, "", "parsererror")
	dom.append_child(d, parent, pe)
	msg := fmt.tprintf("XML Parsing Error: %s\nLocation: %s\nLine Number %d, Column %d:", r.message, location, r.line, r.column)
	dom.append_child(d, pe, dom.create_text(d, msg))
	lines := strings.split_lines(src, context.temp_allocator)
	if r.line >= 1 && r.line <= len(lines) {
		st := xml_create_element(d, NS_PARSERERROR, "", "sourcetext")
		dom.append_child(d, pe, st)
		dom.append_child(d, st, dom.create_text(d, lines[r.line - 1]))
	}
	return false, true
}

// processingInstruction.target
ProcessingInstruction_target :: proc(c: ^Call, node: Api_Node) -> string {
	n := node.data
	return n.kind == .Comment && n.xml == .Processing_Instruction ? n.name : ""
}

// document.contentType of an XML document (the type DOMParser was given); Not_Found for the others (HTML ones).
Document_xmlContentType :: proc(c: ^Call, document: Api_Node) -> (string, Api_Error) {
	#partial switch document.data.xml {
	case .Document, .Created: return "application/xml", .None
	case .Document_Text_XML: return "text/xml", .None
	case .Document_XHTML, .Created_XHTML: return "application/xhtml+xml", .None
	case .Document_SVG, .Created_SVG: return "image/svg+xml", .None
	}
	return "", .Not_Found
}

// createElement / createElementNS of an XML document (DOM "create an element" with that document as node document).
Document_createXMLElement :: proc(c: ^Call, document: Api_Node, namespace: Maybe(string), qualified_name: string, with_namespace: bool) -> (u64, Api_Error) {
	d := jd_doc(c)
	if d == nil { return 0, no_document(c) }
	if !dom.is_xml_document(document.data) { return 0, .Not_Found }
	if !with_namespace {
		if !valid_element_name(qualified_name) { return 0, fail(c, .Invalid_Character, "The tag name provided is not a valid name.") }
		xhtml := document.data.xml == .Document_XHTML || document.data.xml == .Created_XHTML
		return u64(xml_create_element(d, xhtml ? dom.NS_HTML : "", "", qualified_name)), .None
	}
	ns, prefix, local, err := validate_and_extract(c, namespace, qualified_name, true)
	if err != .None { return 0, err }
	return u64(xml_create_element(d, ns, prefix, local)), .None
}

// DOMImplementation.createDocument(namespace, qualifiedName, doctype): a new XMLDocument (a Fragment with as_document).
DOMImplementation_createDocument :: proc(c: ^Call, namespace: Maybe(string), qualified_name: string, doctype: Api_Node) -> (u64, Api_Error) {
	d := jd_doc(c)
	if d == nil { return 0, no_document(c) }
	ns, prefix, local: string
	if qualified_name != "" {
		err: Api_Error
		ns, prefix, local, err = validate_and_extract(c, namespace, qualified_name, true)
		if err != .None { return 0, err }
	}
	dt := base.NIL_HANDLE
	if doctype.data != nil {
		if doctype.data.kind != .Doctype { return 0, fail(c, .Type, "TypeError: parameter 3 is not of type 'DocumentType'.") }
		dt = H(doctype.handle)
	}
	f := dom.create_fragment(d)
	fn := dom.get(d, f)
	fn.as_document = true
	switch ns {
	case dom.NS_HTML: fn.xml = .Created_XHTML
	case dom.NS_SVG: fn.xml = .Created_SVG
	case: fn.xml = .Created
	}
	if dt != base.NIL_HANDLE {
		dom.detach(d, dt)
		dom.append_child(d, f, dt)
	}
	if qualified_name != "" { dom.append_child(d, f, xml_create_element(d, ns, prefix, local)) }
	return u64(f), .None
}
