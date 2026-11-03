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

// Gives an element the name `name` (copied unless it is one of the program's), freeing the one it had.
set_name :: proc(n: ^Node, name: string) {
	if !n.name_static { delete(n.name) }
	if s := static_name(name); s != "" {
		n.name, n.name_static = s, true
	} else {
		n.name, n.name_static = heap_str(name), false
	}
}
