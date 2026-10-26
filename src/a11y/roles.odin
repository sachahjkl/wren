package a11y

// Roles of HTML elements (HTML Accessibility API Mappings 1.0, the implicit roles) and of ARIA (WAI-ARIA 1.2, the role
// attribute), as AccessKit's roles (platform.A11y_Role).

import "core:strings"
import "toolkit:platform"
import "wb:base"
import "wb:dom"

Role :: platform.A11y_Role

// The role named by an ARIA role token ("button", "tablist"...); ok = false for an unknown one (the next token counts).
aria_role :: proc(token: string) -> (r: Role, ok: bool) {
	switch token {
	case "alert": return .Alert, true
	case "alertdialog": return .Alert_Dialog, true
	case "application": return .Application, true
	case "article": return .Article, true
	case "banner": return .Banner, true
	case "blockquote": return .Blockquote, true
	case "button": return .Button, true
	case "caption": return .Caption, true
	case "cell": return .Cell, true
	case "checkbox": return .Check_Box, true
	case "code": return .Code, true
	case "columnheader": return .Column_Header, true
	case "combobox": return .Combo_Box, true
	case "complementary": return .Complementary, true
	case "contentinfo": return .Content_Info, true
	case "definition": return .Definition, true
	case "deletion": return .Content_Deletion, true
	case "dialog": return .Dialog, true
	case "document": return .Document, true
	case "emphasis": return .Emphasis, true
	case "feed": return .Feed, true
	case "figure": return .Figure, true
	case "form": return .Form, true
	case "generic": return .Generic_Container, true
	case "grid": return .Grid, true
	case "gridcell": return .Grid_Cell, true
	case "group": return .Group, true
	case "heading": return .Heading, true
	case "img", "image": return .Image, true
	case "insertion": return .Content_Insertion, true
	case "link": return .Link, true
	case "list": return .List, true
	case "listbox": return .List_Box, true
	case "listitem": return .List_Item, true
	case "log": return .Log, true
	case "main": return .Main, true
	case "mark": return .Mark, true
	case "marquee": return .Marquee, true
	case "math": return .Math, true
	case "menu": return .Menu, true
	case "menubar": return .Menu_Bar, true
	case "menuitem": return .Menu_Item, true
	case "menuitemcheckbox": return .Menu_Item_Check_Box, true
	case "menuitemradio": return .Menu_Item_Radio, true
	case "meter": return .Meter, true
	case "navigation": return .Navigation, true
	case "none", "presentation": return .Unknown, true
	case "note": return .Note, true
	case "option": return .List_Box_Option, true
	case "paragraph": return .Paragraph, true
	case "progressbar": return .Progress_Indicator, true
	case "radio": return .Radio_Button, true
	case "radiogroup": return .Radio_Group, true
	case "region": return .Region, true
	case "row": return .Row, true
	case "rowgroup": return .Row_Group, true
	case "rowheader": return .Row_Header, true
	case "scrollbar": return .Scroll_Bar, true
	case "search": return .Search, true
	case "searchbox": return .Search_Input, true
	case "separator": return .Splitter, true
	case "slider": return .Slider, true
	case "spinbutton": return .Spin_Button, true
	case "status": return .Status, true
	case "strong": return .Strong, true
	case "subscript", "superscript": return .Generic_Container, true
	case "switch": return .Switch, true
	case "tab": return .Tab, true
	case "table": return .Table, true
	case "tablist": return .Tab_List, true
	case "tabpanel": return .Tab_Panel, true
	case "term": return .Term, true
	case "textbox": return .Text_Input, true
	case "time": return .Time, true
	case "timer": return .Timer, true
	case "toolbar": return .Toolbar, true
	case "tooltip": return .Tooltip, true
	case "tree": return .Tree, true
	case "treegrid": return .Tree_Grid, true
	case "treeitem": return .Tree_Item, true
	}
	return .Unknown, false
}

// The role an element has without a role attribute (HTML-AAM); .Unknown: none (generic, not exposed unless it says
// something). `has_name`: the element has an accessible name of its own (a section, a form: regions only then).
implicit_role :: proc(d: ^dom.Document, h: base.Handle, n: ^dom.Node, has_name: bool) -> Role {
	attr :: proc(d: ^dom.Document, h: base.Handle, name: string) -> (string, bool) { return dom.get_attribute(d, h, name) }
	if n.ns == .SVG { return n.name == "svg" ? .Svg_Root : .Unknown }
	if n.ns == .MathML { return n.name == "math" ? .Math : .Unknown }
	switch n.name {
	case "a", "area":
		_, href := attr(d, h, "href")
		return href ? .Link : .Unknown
	case "article": return .Article
	case "aside": return .Complementary
	case "blockquote": return .Blockquote
	case "button": return .Button
	case "caption": return .Caption
	case "code": return .Code
	case "datalist": return .List_Box
	case "dd": return .Definition
	case "del", "s": return .Content_Deletion
	case "details": return .Details
	case "dfn": return .Term
	case "dialog": return .Dialog
	case "dl": return .Description_List
	case "dt": return .Term
	case "em": return .Emphasis
	case "fieldset": return .Group
	case "figcaption": return .Figure_Caption
	case "figure": return .Figure
	case "footer": return in_sectioning(d, h) ? .Section_Footer : .Content_Info
	case "form": return has_name ? .Form : .Unknown
	case "h1", "h2", "h3", "h4", "h5", "h6": return .Heading
	case "header": return in_sectioning(d, h) ? .Section_Header : .Banner
	case "hr": return .Splitter
	case "iframe": return .Iframe
	case "img":
		if alt, ok := attr(d, h, "alt"); ok && alt == "" {
			// alt="" is decoration, unless something names it all the same
			if _, l := attr(d, h, "aria-label"); !l { if _, lb := attr(d, h, "aria-labelledby"); !lb { if _, t := attr(d, h, "title"); !t { return .Unknown } } }
		}
		return .Image
	case "input": return input_role(d, h)
	case "ins": return .Content_Insertion
	case "label": return .Label
	case "legend": return .Legend
	case "li": return .List_Item
	case "main": return .Main
	case "mark": return .Mark
	case "math": return .Math
	case "menu", "ol", "ul": return .List
	case "meter": return .Meter
	case "nav": return .Navigation
	case "optgroup": return .Group
	case "option": return .List_Box_Option
	case "output": return .Status
	case "p": return .Paragraph
	case "pre": return .Generic_Container
	case "progress": return .Progress_Indicator
	case "search": return .Search
	case "section": return has_name ? .Region : .Unknown
	case "select":
		_, multiple := attr(d, h, "multiple")
		size := 1
		if v, ok := attr(d, h, "size"); ok { size = max(parse_int(v, 1), 1) }
		return (multiple || size > 1) ? .List_Box : .Combo_Box
	case "strong": return .Strong
	case "summary": return .Disclosure_Triangle
	case "table": return .Table
	case "tbody", "thead", "tfoot": return .Row_Group
	case "td": return .Cell
	case "textarea": return .Multiline_Text_Input
	case "th": return header_role(d, h)
	case "time": return .Time
	case "tr": return .Row
	case "video": return .Video
	case "audio": return .Audio
	case "canvas": return .Canvas
	case "abbr": return .Abbr
	case "br": return .Line_Break
	}
	return .Unknown
}

@(private)
input_role :: proc(d: ^dom.Document, h: base.Handle) -> Role {
	t, _ := dom.get_attribute(d, h, "type")
	_, has_list := dom.get_attribute(d, h, "list")
	switch strings.to_lower(t, context.temp_allocator) {
	case "button", "submit", "reset", "image": return .Button
	case "checkbox": return .Check_Box
	case "radio": return .Radio_Button
	case "range": return .Slider
	case "number": return .Spin_Button
	case "hidden": return .Unknown
	case "search": return has_list ? .Combo_Box : .Search_Input
	case "email": return has_list ? .Combo_Box : .Email_Input
	case "tel": return has_list ? .Combo_Box : .Phone_Number_Input
	case "url": return has_list ? .Combo_Box : .Url_Input
	case "password": return .Password_Input
	case "date": return .Date_Input
	case "datetime-local": return .Date_Time_Input
	case "month": return .Month_Input
	case "week": return .Week_Input
	case "time": return .Time_Input
	case "color": return .Color_Well
	case "file": return .Button
	}
	return has_list ? .Combo_Box : .Text_Input
}

// A th: a row header when it heads its row (scope=row, or the first of a row whose other cells are data), else a
// column header.
@(private)
header_role :: proc(d: ^dom.Document, h: base.Handle) -> Role {
	if s, ok := dom.get_attribute(d, h, "scope"); ok {
		switch strings.to_lower(s, context.temp_allocator) {
		case "row", "rowgroup": return .Row_Header
		case "col", "colgroup": return .Column_Header
		}
	}
	n := dom.get(d, h)
	if n == nil { return .Column_Header }
	// in a row with data cells: a header of that row
	for c := n.next; c != base.NIL_HANDLE; {
		cn := dom.get(d, c)
		if cn == nil { break }
		if cn.kind == .Element && cn.name == "td" { return .Row_Header }
		c = cn.next
	}
	return .Column_Header
}

// Inside an article, aside, main, nav or section: a header / footer of that part, not of the page.
@(private)
in_sectioning :: proc(d: ^dom.Document, h: base.Handle) -> bool {
	n := dom.get(d, h)
	for n != nil && n.parent != base.NIL_HANDLE {
		p := dom.get(d, n.parent)
		if p == nil || p.kind != .Element { break }
		switch p.name {
		case "article", "aside", "main", "nav", "section": return true
		}
		n = p
	}
	return false
}

@(private)
parse_int :: proc(s: string, fallback: int) -> int {
	t := strings.trim_space(s)
	if t == "" { return fallback }
	v, neg := 0, false
	i := 0
	if t[0] == '-' || t[0] == '+' { neg = t[0] == '-'; i = 1 }
	if i >= len(t) || t[i] < '0' || t[i] > '9' { return fallback }
	for ; i < len(t) && t[i] >= '0' && t[i] <= '9'; i += 1 { v = v * 10 + int(t[i] - '0'); if v > 1_000_000_000 { break } }
	return neg ? -v : v
}

// Roles whose content names them (accname 1.2 §4.3.2 step 2F: "name from content").
name_from_content :: proc(r: Role) -> bool {
	#partial switch r {
	case .Button, .Default_Button, .Cell, .Check_Box, .Column_Header, .Grid_Cell, .Heading, .Link, .Menu_Item,
	     .Menu_Item_Check_Box, .Menu_Item_Radio, .List_Box_Option, .Radio_Button, .Row, .Row_Header, .Switch, .Tab,
	     .Tooltip, .Tree_Item, .Label, .Legend, .Caption, .Figure_Caption, .Disclosure_Triangle, .Term, .Abbr,
	     .Doc_Back_Link, .Doc_Biblio_Ref, .Doc_Gloss_Ref, .Doc_Note_Ref:
		return true
	}
	return false
}

// Roles whose children are presentational (WAI-ARIA 1.2: their content is their name, not nodes of their own).
children_presentational :: proc(r: Role) -> bool {
	#partial switch r {
	case .Button, .Default_Button, .Check_Box, .Image, .Math, .Menu_Item_Check_Box, .Menu_Item_Radio, .Meter,
	     .List_Box_Option, .Progress_Indicator, .Radio_Button, .Scroll_Bar, .Splitter, .Slider, .Switch, .Tab,
	     .Text_Input, .Multiline_Text_Input, .Search_Input, .Email_Input, .Phone_Number_Input, .Url_Input,
	     .Password_Input, .Number_Input, .Spin_Button, .Date_Input, .Date_Time_Input, .Month_Input, .Week_Input,
	     .Time_Input, .Color_Well, .Link:
		return true
	}
	return false
}
