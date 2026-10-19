package page

// Elements for JavaScript (api/js_dom_elements.widl): names and namespaces, attributes, the members of HTMLElement and
// of the hyperlink elements.
//
// Attributes are kept by their qualified name, lower case (package dom): an attribute's namespace is that of its
// prefix (xlink:, xml:, xmlns:), and the *NS methods match on the local name and that implied namespace.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:js"
import "wb:url"

// The qualified name of an element; upper case for an HTML element (tagName, nodeName) when `upper`.
@(private)
jd_qualified_name :: proc(d: ^dom.Document, h: base.Handle, upper: bool) -> string {
	n := dom.get(d, h)
	if n == nil { return "" }
	local := jd_local_name(n)
	if n.ns == .HTML && upper { local = strings.to_upper(local, context.temp_allocator) }
	prefix := dom.ns_prefix(d, h)
	if prefix == "" { return local }
	return strings.concatenate({prefix, ":", local}, context.temp_allocator)
}

// The local name as the DOM gives it: SVG names in their mixed case (the browser keeps them lower case).
@(private)
jd_local_name :: proc(n: ^dom.Node) -> string {
	if n.ns == .SVG { return svg_case(SVG_ELEMENTS[:], n.name) }
	return n.name
}

Element_namespaceURI :: proc(c: ^Call, element: Api_Element) -> (string, Api_Error) {
	uri := dom.ns_uri(c.page.doc, H(element.handle))
	if uri == "" { return "", .Not_Found }
	return uri, .None
}

Element_prefix :: proc(c: ^Call, element: Api_Element) -> (string, Api_Error) {
	p := dom.ns_prefix(c.page.doc, H(element.handle))
	if p == "" { return "", .Not_Found }
	return p, .None
}

Element_localName :: proc(c: ^Call, element: Api_Element) -> string { return jd_local_name(element.data) }

Element_qualifiedTagName :: proc(c: ^Call, element: Api_Element) -> string { return jd_qualified_name(c.page.doc, H(element.handle), true) }

Element_slot :: proc(c: ^Call, element: Api_Element) -> string {
	v, _ := dom.get_attribute(c.page.doc, H(element.handle), "slot")
	return v
}

Element_set_slot :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error {
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), "slot", value))
}

Element_hasAttributes :: proc(c: ^Call, element: Api_Element) -> bool { return len(element.data.attrs) > 0 }

// The DOM's name of a stored attribute: SVG attribute names in their mixed case.
@(private)
jd_attr_name :: proc(n: ^dom.Node, name: string) -> string {
	if n.ns == .SVG { return svg_case(SVG_ATTRIBUTES[:], name) }
	return name
}

Element_attributeNames :: proc(c: ^Call, element: Api_Element) -> string {
	b := strings.builder_make(context.temp_allocator)
	for a in element.data.attrs {
		strings.write_string(&b, jd_attr_name(element.data, a.name))
		strings.write_byte(&b, 0)
	}
	return strings.to_string(b)
}

Element_attributeCount :: proc(c: ^Call, element: Api_Element) -> u32 { return u32(len(element.data.attrs)) }

Element_attributeNameAt :: proc(c: ^Call, element: Api_Element, index: u32) -> (string, Api_Error) {
	if int(index) >= len(element.data.attrs) { return "", .Not_Found }
	return jd_attr_name(element.data, element.data.attrs[index].name), .None
}

// The namespace of a stored attribute name, from its prefix.
@(private)
attr_namespace :: proc(name: string) -> string {
	colon := strings.index_byte(name, ':')
	if colon < 0 { return "" }
	switch name[:colon] {
	case "xlink": return dom.NS_XLINK
	case "xml": return dom.NS_XML
	case "xmlns": return dom.NS_XMLNS
	}
	return "?"   // a prefix whose namespace was not kept: matches any namespace but null
}

// The stored attribute that (namespace, local name) designates; "" when none.
@(private)
find_attr_ns :: proc(n: ^dom.Node, namespace: Maybe(string), local_name: string) -> string {
	ns, _ := namespace.?
	local := strings.to_lower(local_name, context.temp_allocator)
	if n.name == "xmlns" && ns == dom.NS_XMLNS && local == "xmlns" { return "xmlns" }
	for a in n.attrs {
		a_ns := attr_namespace(a.name)
		a_local := a.name
		if colon := strings.index_byte(a.name, ':'); colon >= 0 { a_local = a.name[colon + 1:] }
		if a.name == "xmlns" { a_ns = dom.NS_XMLNS }
		if a_local != local { continue }
		if ns == "" { if a_ns == "" { return a.name } } else if a_ns == ns || a_ns == "?" { return a.name }
	}
	return ""
}

Element_getAttributeNS :: proc(c: ^Call, element: Api_Element, namespace: Maybe(string), local_name: string) -> (string, Api_Error) {
	name := find_attr_ns(element.data, namespace, local_name)
	if name == "" { return "", .Not_Found }
	v, _ := dom.get_attribute(c.page.doc, H(element.handle), name)
	return v, .None
}

Element_setAttributeChecked :: proc(c: ^Call, element: Api_Element, name: string, value: string) -> Api_Error {
	if !valid_attribute_name(name) { return fail(c, .Invalid_Character, "The attribute name provided is not a valid name.") }
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), name, value))
}

Element_setAttributeNS :: proc(c: ^Call, element: Api_Element, namespace: Maybe(string), qualified_name: string, value: string) -> Api_Error {
	ns, _, local, err := validate_and_extract(c, namespace, qualified_name, false)
	if err != .None { return err }
	// an attribute of that namespace and local name already there keeps its qualified name
	if existing := find_attr_ns(element.data, ns, local); existing != "" {
		return dom_error(dom.set_attribute(c.page.doc, H(element.handle), existing, value))
	}
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), qualified_name, value))
}

Element_removeAttributeNS :: proc(c: ^Call, element: Api_Element, namespace: Maybe(string), local_name: string) {
	if name := find_attr_ns(element.data, namespace, local_name); name != "" {
		dom.remove_attribute(c.page.doc, H(element.handle), strings.clone(name, context.temp_allocator))
	}
}

Element_toggleAttributeChecked :: proc(c: ^Call, element: Api_Element, name: string, force: i32) -> (bool, Api_Error) {
	if !valid_attribute_name(name) { return false, fail(c, .Invalid_Character, "The attribute name provided is not a valid name.") }
	d := c.page.doc
	h := H(element.handle)
	_, has := dom.get_attribute(d, h, name)
	if !has {
		if force == 0 { return false, .None }
		return true, dom_error(dom.set_attribute(d, h, name, ""))
	}
	if force == 1 { return true, .None }
	dom.remove_attribute(d, h, name)
	return false, .None
}

Element_hasAttribute :: proc(c: ^Call, element: Api_Element, name: string) -> bool {
	_, ok := dom.get_attribute(c.page.doc, H(element.handle), name)
	return ok
}

Element_hasAttributeNS :: proc(c: ^Call, element: Api_Element, namespace: Maybe(string), local_name: string) -> bool {
	return find_attr_ns(element.data, namespace, local_name) != ""
}

Element_shadowRoot :: proc(c: ^Call, element: Api_Element) -> u64 { return 0 }

HTMLTemplateElement_content :: proc(c: ^Call, element: Api_Element) -> u64 {
	if element.data.name != "template" || element.data.ns != .HTML { return 0 }
	return u64(dom.template_content(c.page.doc, H(element.handle)))
}

////////////////////////////////
// HTMLElement

HTMLElement_hiddenState :: proc(c: ^Call, element: Api_Element) -> i32 {
	v, ok := dom.get_attribute(c.page.doc, H(element.handle), "hidden")
	if !ok { return 0 }
	return strings.equal_fold(v, "until-found") ? 2 : 1
}

HTMLElement_dir :: proc(c: ^Call, element: Api_Element) -> string {
	v, _ := dom.get_attribute(c.page.doc, H(element.handle), "dir")
	return enumerated_dir(v)
}

HTMLElement_set_dir :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error {
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), "dir", value))
}

// An enumerated attribute with "true" / "false" keywords: whether it says `want`, else what the ancestors say (or
// `default` at the top), as translate and spellcheck inherit.
@(private)
inherited_flag :: proc(d: ^dom.Document, h: base.Handle, attr, yes, no: string, default: bool) -> bool {
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil || n.kind != .Element { break }
		if v, ok := dom.get_attribute(d, cur, attr); ok {
			if strings.equal_fold(v, yes) || (yes == "true" && v == "") { return true }
			if strings.equal_fold(v, no) { return false }
		}
		cur = n.parent
	}
	return default
}

HTMLElement_translate :: proc(c: ^Call, element: Api_Element) -> bool {
	return inherited_flag(c.page.doc, H(element.handle), "translate", "yes", "no", true)
}

HTMLElement_set_translate :: proc(c: ^Call, element: Api_Element, value: bool) -> Api_Error {
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), "translate", value ? "yes" : "no"))
}

HTMLElement_draggable :: proc(c: ^Call, element: Api_Element) -> bool {
	d := c.page.doc
	h := H(element.handle)
	if v, ok := dom.get_attribute(d, h, "draggable"); ok {
		if strings.equal_fold(v, "true") { return true }
		if strings.equal_fold(v, "false") { return false }
	}
	// auto: images and links with an href are draggable
	n := element.data
	if n.name == "img" { return true }
	if n.name == "a" { _, has := dom.get_attribute(d, h, "href"); return has }
	return false
}

HTMLElement_set_draggable :: proc(c: ^Call, element: Api_Element, value: bool) -> Api_Error {
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), "draggable", value ? "true" : "false"))
}

HTMLElement_spellcheck :: proc(c: ^Call, element: Api_Element) -> bool {
	return inherited_flag(c.page.doc, H(element.handle), "spellcheck", "true", "false", true)
}

HTMLElement_set_spellcheck :: proc(c: ^Call, element: Api_Element, value: bool) -> Api_Error {
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), "spellcheck", value ? "true" : "false"))
}

HTMLElement_accessKeyLabel :: proc(c: ^Call, element: Api_Element) -> string { return "" }

// Elements focusable by default (HTML §6.6.3 "focusable area"), whose tabIndex is 0 without the attribute.
@(private)
focusable_by_default :: proc(d: ^dom.Document, h: base.Handle, n: ^dom.Node) -> bool {
	if n.ns != .HTML { return n.ns == .SVG && n.name == "a" }
	switch n.name {
	case "button", "select", "textarea", "iframe", "summary", "frame", "object", "embed": return true
	case "input":
		t, _ := dom.get_attribute(d, h, "type")
		return !strings.equal_fold(t, "hidden")
	case "a", "area":
		_, has := dom.get_attribute(d, h, "href")
		return has
	case "audio", "video":
		_, has := dom.get_attribute(d, h, "controls")
		return has
	}
	if ce, ok := dom.get_attribute(d, h, "contenteditable"); ok { return ce == "" || strings.equal_fold(ce, "true") || strings.equal_fold(ce, "plaintext-only") }
	return false
}

// HTML "rules for parsing integers"
@(private)
parse_html_int :: proc(s: string) -> (int, bool) {
	t := strings.trim_left(s, " \t\n\f\r")
	sign := 1
	if len(t) > 0 && (t[0] == '-' || t[0] == '+') { if t[0] == '-' { sign = -1 }; t = t[1:] }
	end := 0
	for end < len(t) && t[end] >= '0' && t[end] <= '9' { end += 1 }
	if end == 0 { return 0, false }
	v, ok := strconv.parse_i64(t[:min(end, 18)])
	if !ok { return 0, false }
	return sign * int(v), true
}

HTMLOrSVGOrMathMLElement_tabIndex :: proc(c: ^Call, element: Api_Element) -> i32 {
	d := c.page.doc
	h := H(element.handle)
	if v, ok := dom.get_attribute(d, h, "tabindex"); ok {
		if x, good := parse_html_int(v); good { return i32(clamp(x, int(min(i32)), int(max(i32)))) }
	}
	return focusable_by_default(d, h, element.data) ? 0 : -1
}

HTMLOrSVGOrMathMLElement_set_tabIndex :: proc(c: ^Call, element: Api_Element, value: i32) -> Api_Error {
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), "tabindex", fmt.tprintf("%d", value)))
}

HTMLOrSVGOrMathMLElement_nonce :: proc(c: ^Call, element: Api_Element) -> string {
	v, _ := dom.get_attribute(c.page.doc, H(element.handle), "nonce")
	return v
}

HTMLOrSVGOrMathMLElement_set_nonce :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error {
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), "nonce", value))
}

ElementContentEditable_contentEditable :: proc(c: ^Call, element: Api_Element) -> string {
	v, ok := dom.get_attribute(c.page.doc, H(element.handle), "contenteditable")
	if !ok { return "inherit" }
	switch {
	case v == "" || strings.equal_fold(v, "true"): return "true"
	case strings.equal_fold(v, "false"): return "false"
	case strings.equal_fold(v, "plaintext-only"): return "plaintext-only"
	}
	return "inherit"
}

ElementContentEditable_set_contentEditable :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error {
	d := c.page.doc
	h := H(element.handle)
	switch {
	case strings.equal_fold(value, "inherit"): dom.remove_attribute(d, h, "contenteditable"); return .None
	case strings.equal_fold(value, "true"): return dom_error(dom.set_attribute(d, h, "contenteditable", "true"))
	case strings.equal_fold(value, "false"): return dom_error(dom.set_attribute(d, h, "contenteditable", "false"))
	case strings.equal_fold(value, "plaintext-only"): return dom_error(dom.set_attribute(d, h, "contenteditable", "plaintext-only"))
	}
	return fail(c, .Syntax, "The value provided is not one of 'true', 'false', 'plaintext-only', or 'inherit'.")
}

ElementContentEditable_isContentEditable :: proc(c: ^Call, element: Api_Element) -> bool {
	d := c.page.doc
	for cur := H(element.handle); cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil || n.kind != .Element { break }
		if v, ok := dom.get_attribute(d, cur, "contenteditable"); ok {
			if v == "" || strings.equal_fold(v, "true") || strings.equal_fold(v, "plaintext-only") { return dom.is_connected(d, H(element.handle)) }
			if strings.equal_fold(v, "false") { return false }
		}
		cur = n.parent
	}
	return false
}

////////////////////////////////
// Hyperlinks (HTMLHyperlinkElementUtils): the href attribute parsed against the document's base URL

@(private)
link_url :: proc(c: ^Call, element: Api_Element) -> (url.URL, bool) {
	href, has := dom.get_attribute(c.page.doc, H(element.handle), "href")
	if !has { return {}, false }
	b, ok := url.parse_absolute(document_base_url(c.page), context.temp_allocator)
	if !ok { return url.parse_absolute(href, context.temp_allocator) }
	return url.parse(href, &b, context.temp_allocator)
}

HTMLHyperlinkElementUtils_href :: proc(c: ^Call, element: Api_Element) -> string {
	if u, ok := link_url(c, element); ok { return u.href }
	v, _ := dom.get_attribute(c.page.doc, H(element.handle), "href")
	return v
}

HTMLHyperlinkElementUtils_set_href :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error {
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), "href", value))
}

@(private)
link_component :: proc(c: ^Call, element: Api_Element, comp: url.Component) -> string {
	u, ok := link_url(c, element)
	if !ok { return comp == .Origin ? "" : "" }
	return url.component(u, comp, context.temp_allocator)
}

// A component setter: applied to the parsed URL, written back to href; nothing for a URL that does not parse.
@(private)
link_set_component :: proc(c: ^Call, element: Api_Element, comp: url.Component, value: string) -> Api_Error {
	u, ok := link_url(c, element)
	if !ok { return .None }
	r, res := url.set_component(u, comp, value, context.temp_allocator)
	if res != .Ok { return .None }
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), "href", r.href))
}

HyperlinkElementUtils_origin :: proc(c: ^Call, element: Api_Element) -> string { return link_component(c, element, .Origin) }
HyperlinkElementUtils_protocol :: proc(c: ^Call, element: Api_Element) -> string {
	if _, ok := link_url(c, element); !ok { return ":" }
	return link_component(c, element, .Protocol)
}
HyperlinkElementUtils_set_protocol :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error { return link_set_component(c, element, .Protocol, value) }
HyperlinkElementUtils_username :: proc(c: ^Call, element: Api_Element) -> string { return link_component(c, element, .Username) }
HyperlinkElementUtils_set_username :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error { return link_set_component(c, element, .Username, value) }
HyperlinkElementUtils_password :: proc(c: ^Call, element: Api_Element) -> string { return link_component(c, element, .Password) }
HyperlinkElementUtils_set_password :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error { return link_set_component(c, element, .Password, value) }
HyperlinkElementUtils_host :: proc(c: ^Call, element: Api_Element) -> string { return link_component(c, element, .Host) }
HyperlinkElementUtils_set_host :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error { return link_set_component(c, element, .Host, value) }
HyperlinkElementUtils_hostname :: proc(c: ^Call, element: Api_Element) -> string { return link_component(c, element, .Hostname) }
HyperlinkElementUtils_set_hostname :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error { return link_set_component(c, element, .Hostname, value) }
HyperlinkElementUtils_port :: proc(c: ^Call, element: Api_Element) -> string { return link_component(c, element, .Port) }
HyperlinkElementUtils_set_port :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error { return link_set_component(c, element, .Port, value) }
HyperlinkElementUtils_pathname :: proc(c: ^Call, element: Api_Element) -> string { return link_component(c, element, .Pathname) }
HyperlinkElementUtils_set_pathname :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error { return link_set_component(c, element, .Pathname, value) }
HyperlinkElementUtils_search :: proc(c: ^Call, element: Api_Element) -> string { return link_component(c, element, .Search) }
HyperlinkElementUtils_set_search :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error { return link_set_component(c, element, .Search, value) }
HyperlinkElementUtils_hash :: proc(c: ^Call, element: Api_Element) -> string { return link_component(c, element, .Hash) }
HyperlinkElementUtils_set_hash :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error { return link_set_component(c, element, .Hash, value) }

HTMLAnchorElement_text :: proc(c: ^Call, element: Api_Element) -> string { return dom.text_content(c.page.doc, H(element.handle)) }

HTMLAnchorElement_set_text :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error {
	return dom_error(dom.set_text_content(c.page.doc, H(element.handle), value))
}

// document.lastModified: the page does not keep the response's Last-Modified header; HTML then says the current local
// date and time, "MM/DD/YYYY hh:mm:ss".
@(private)
document_last_modified :: proc(p: ^Page) -> string {
	now := time.now()
	off := f64(js_timezone_minutes(now)) * 60
	t := time.time_add(now, time.Duration(-off * f64(time.Second)))
	y, mon, day := time.date(t)
	h, m, s := time.clock(t)
	return fmt.tprintf("%02d/%02d/%04d %02d:%02d:%02d", int(mon), day, y, h, m, s)
}

// Minutes to add to local time to get UTC at `t`.
@(private)
js_timezone_minutes :: proc(t: time.Time) -> i32 { return js.timezone_offset(f64(time.time_to_unix_nano(t)) / 1e6) }
