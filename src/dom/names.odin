package dom

// Element names are the program's own strings when they are one of the names below (create_element): a page that makes
// thousands of elements a frame (nodes10k) allocated and freed a copy of "li" for each. A node says which it holds
// (`Node.name_static`); anything that replaces a name goes through `set_name`.

// Longer names are never looked up.
NAME_STATIC_MAX :: 10

// By first letter, a to z: the HTML elements, the older ones the parser still meets, and SVG's and MathML's most used
// (lower case, as elements are kept).
@(rodata)
STATIC_NAMES := [26][]string{
	{"a", "abbr", "address", "area", "article", "aside", "audio"},
	{"b", "base", "bdi", "bdo", "blockquote", "body", "br", "button"},
	{"canvas", "caption", "center", "circle", "cite", "code", "col", "colgroup"},
	{"data", "datalist", "dd", "defs", "del", "details", "dfn", "dialog", "div", "dl", "dt"},
	{"ellipse", "em", "embed"},
	{"fieldset", "figcaption", "figure", "font", "footer", "form"},
	{"g"},
	{"h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr", "html"},
	{"i", "iframe", "image", "img", "input", "ins"},
	{},
	{"kbd"},
	{"label", "legend", "li", "line", "link"},
	{"main", "map", "mark", "mask", "math", "menu", "meta", "meter", "mi", "mn", "mo", "mrow"},
	{"nav", "noscript"},
	{"object", "ol", "optgroup", "option", "output"},
	{"p", "path", "pattern", "picture", "polygon", "polyline", "pre", "progress"},
	{"q"},
	{"rect", "rp", "rt", "ruby"},
	{"s", "samp", "script", "search", "section", "select", "slot", "small", "source", "span", "stop", "strong", "style", "sub", "summary", "sup", "svg", "symbol"},
	{"table", "tbody", "td", "template", "text", "textarea", "tfoot", "th", "thead", "time", "title", "tr", "track", "tspan"},
	{"u", "ul", "use"},
	{"var", "video"},
	{"wbr"},
	{},
	{},
	{},
}

// The program's string equal to `name` (already lower case), or "".
static_name :: proc "contextless" (name: string) -> string {
	if len(name) == 0 || len(name) > NAME_STATIC_MAX || name[0] < 'a' || name[0] > 'z' { return "" }
	for s in STATIC_NAMES[name[0] - 'a'] {
		if s == name { return s }
	}
	return ""
}

// Attribute names are the program's own strings when they are one of the names below (Attr.name_static): most
// attributes a page sets have one of them, and a copy of "class" per element was a heap block each. Exact names, as
// stored (the lower case of HTML and SVG elements, the case of a doctype's identifiers).
ATTR_STATIC_MAX :: 16

@(rodata)
STATIC_ATTRS := [26][]string{
	{"accesskey", "action", "align", "allow", "allowfullscreen", "alt", "aria-checked", "aria-controls", "aria-current",
	 "aria-describedby", "aria-disabled", "aria-expanded", "aria-haspopup", "aria-hidden", "aria-label",
	 "aria-labelledby", "aria-live", "aria-pressed", "aria-selected", "async", "autocomplete", "autofocus", "autoplay"},
	{"border"},
	{"charset", "checked", "cite", "class", "clip-path", "clip-rule", "color", "cols", "colspan", "content",
	 "contenteditable", "controls", "coords", "crossorigin", "cx", "cy"},
	{"d", "data-id", "data-testid", "datetime", "decoding", "default", "defer", "dir", "disabled", "download", "draggable"},
	{"elementtiming", "enctype"},
	{"fetchpriority", "fill", "fill-opacity", "fill-rule", "focusable", "for", "form", "frameborder"},
	{},
	{"headers", "height", "hidden", "high", "href", "hreflang", "http-equiv"},
	{"id", "inert", "inputmode", "integrity", "is", "ismap", "itemprop", "itemscope", "itemtype"},
	{},
	{"kind"},
	{"label", "lang", "list", "loading", "loop", "low"},
	{"max", "maxlength", "media", "method", "min", "minlength", "multiple", "muted"},
	{"name", "nomodule", "nonce", "novalidate"},
	{"offset", "opacity", "open", "optimum"},
	{"part", "path", "pattern", "placeholder", "playsinline", "points", "popover", "popovertarget", "poster", "preload",
	 "property", "publicId"},
	{},
	{"r", "readonly", "referrerpolicy", "rel", "required", "reversed", "role", "rows", "rowspan", "rx", "ry"},
	{"sandbox", "scope", "selected", "shape", "size", "sizes", "slot", "span", "spellcheck", "src", "srcdoc", "srclang",
	 "srcset", "start", "step", "stop-color", "stroke", "stroke-linecap", "stroke-linejoin", "stroke-width", "style",
	 "systemId"},
	{"tabindex", "target", "title", "transform", "translate", "type"},
	{"usemap"},
	{"value", "version", "viewbox", "visibility"},
	{"width", "wrap"},
	{"x", "x1", "x2", "xmlns", "xmlns:xlink", "xlink:href"},
	{"y", "y1", "y2"},
	{},
}

// The program's string equal to the attribute name `name` (exactly), or "".
static_attr_name :: proc "contextless" (name: string) -> string {
	if len(name) == 0 || len(name) > ATTR_STATIC_MAX || name[0] < 'a' || name[0] > 'z' { return "" }
	for s in STATIC_ATTRS[name[0] - 'a'] {
		if s == name { return s }
	}
	return ""
}

// An attribute named `name`: the program's string when it is one of STATIC_ATTRS, else a copy.
@(private)
attr_make :: proc(name, value: string, ns: Attr_Ns) -> Attr {
	if s := static_attr_name(name); s != "" { return Attr{name = s, value = heap_str(value), ns = ns, name_static = true} }
	return Attr{name = heap_str(name), value = heap_str(value), ns = ns}
}

// Gives attribute `a` the name `name` (setAttributeNode's prefix), freeing the one it had.
@(private)
attr_rename :: proc(a: ^Attr, name: string) {
	if !a.name_static { delete(a.name) }
	if s := static_attr_name(name); s != "" {
		a.name, a.name_static = s, true
	} else {
		a.name, a.name_static = heap_str(name), false
	}
}

// Frees what attribute `a` owns.
@(private)
attr_free :: proc(a: Attr) {
	if !a.name_static { delete(a.name) }
	delete(a.value)
}

// The heap bytes of attribute `a`'s strings (the document's account, Document.bytes).
@(private)
attr_bytes :: proc(a: Attr) -> int { return (a.name_static ? 0 : len(a.name)) + len(a.value) }

// Gives an element the name `name` (copied unless it is one of the program's), freeing the one it had.
set_name :: proc(n: ^Node, name: string) {
	if !n.name_static { delete(n.name) }
	if s := static_name(name); s != "" {
		n.name, n.name_static = s, true
	} else {
		n.name, n.name_static = heap_str(name), false
	}
}
