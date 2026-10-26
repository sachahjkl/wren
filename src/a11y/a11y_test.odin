package a11y

import "core:strings"
import "core:testing"
import "toolkit:platform"
import "wb:base"
import "wb:dom"
import "wb:html"

SAMPLE :: #load("../../examples/a11y/page.html", string)

Fx :: struct {
	doc: ^dom.Document,
	u:   platform.A11y_Update,
	by_id: map[string]int,   // html id -> node index
}

@(private = "file")
open :: proc(f: ^Fx, src: string, focus_id := "") {
	f.doc = dom.document_create()
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 100_000)
	v := View{src = {doc = f.doc}, title = "Sample", url = "http://test/"}
	if focus_id != "" { v.focus = dom.find_by_id(f.doc, focus_id) }
	build(&v, &f.u)
	f.by_id = make(map[string]int)
	for _, i in f.u.nodes {
		if id := platform.a11y_node_string(&f.u, i, .Html_Id); id != "" { f.by_id[id] = i }
	}
}

@(private = "file")
close :: proc(f: ^Fx) {
	delete(f.by_id)
	platform.a11y_update_destroy(&f.u)
	dom.document_destroy(f.doc)
	free_all(context.temp_allocator)
}

@(private = "file")
Expect :: struct {
	id:    string,
	role:  Role,
	name:  string,          // "-": not checked
	flags: platform.A11y_Flags,
}

@(private = "file")
prop :: proc(f: ^Fx, i: int, kind: platform.A11y_Prop_Kind) -> (platform.A11y_Prop, bool) {
	for p in platform.a11y_node_props(&f.u, i) { if p.kind == kind { return p, true } }
	return {}, false
}

@(test)
roles_names_states :: proc(t: ^testing.T) {
	f: Fx
	open(&f, SAMPLE)
	defer close(&f)
	cases := []Expect{
		{"top", .Banner, "-", {}},
		{"home", .Link, "Home", {}},
		{"nav", .Navigation, "Main", {}},
		{"menu", .List, "-", {}},
		{"li2", .List_Item, "-", {}},
		{"main", .Main, "-", {}},
		{"title", .Heading, "Accessibility sample", {}},
		{"intro", .Paragraph, "-", {}},
		{"form-sec", .Region, "Form", {}},
		{"form", .Form, "Sign up", {}},
		{"name", .Text_Input, "Your name", {.Required}},
		{"email", .Email_Input, "Email", {}},
		{"search", .Search_Input, "Search the site", {}},
		{"pw", .Password_Input, "Password", {}},
		{"news", .Check_Box, "Newsletter", {}},
		{"size", .Group, "Size", {}},
		{"large", .Radio_Button, "Large", {}},
		{"country", .Combo_Box, "Country", {.Has_Expanded}},
		{"fr", .List_Box_Option, "France", {.Has_Selected, .Selected}},
		{"de", .List_Box_Option, "Germany", {.Has_Selected}},
		{"vol", .Slider, "Volume", {}},
		{"note", .Multiline_Text_Input, "Note", {}},
		{"go", .Button, "Submit", {}},
		{"save", .Button, "Save", {.Disabled}},
		{"icon", .Button, "Delete", {}},
		{"fake", .Button, "Bold", {}},
		{"steps", .List, "-", {}},
		{"defs", .Description_List, "-", {}},
		{"term", .Term, "Term", {}},
		{"def", .Definition, "-", {}},
		{"t", .Table, "Scores", {}},
		{"th-name", .Column_Header, "Name", {}},
		{"row-h", .Row_Header, "Ada", {}},
		{"c1", .Cell, "10", {}},
		{"r1", .Row, "-", {}},
		{"fig", .Figure, "Our cat", {}},
		{"pic", .Image, "A cat", {}},
		{"more", .Details, "-", {}},
		{"sum", .Disclosure_Triangle, "More", {.Has_Expanded}},
		{"tabs", .Tab_List, "Views", {}},
		{"tab1", .Tab, "Grid", {.Has_Selected, .Selected}},
		{"tab2", .Tab, "List", {.Has_Selected}},
		{"p1", .Tab_Panel, "Grid", {}},
		{"prog", .Progress_Indicator, "-", {}},
		{"h-level", .Heading, "Deep", {}},
		{"live", .Generic_Container, "3 messages", {}},
		{"alert", .Alert, "Saved", {}},
		{"dlg", .Dialog, "Confirm", {.Modal}},
		{"ok", .Button, "OK", {}},
		{"foot", .Content_Info, "-", {}},
	}
	for c in cases {
		i, ok := f.by_id[c.id]
		if !testing.expectf(t, ok, "%s: a node", c.id) { continue }
		n := f.u.nodes[i]
		testing.expectf(t, Role(n.role) == c.role, "%s: role %v, expected %v", c.id, Role(n.role), c.role)
		if c.name != "-" {
			name := platform.a11y_node_string(&f.u, i, .Label)
			if Role(n.role) == .Label { name = platform.a11y_node_string(&f.u, i, .Value) }
			testing.expectf(t, name == c.name, "%s: name %q, expected %q", c.id, name, c.name)
		}
		for fl in c.flags { testing.expectf(t, fl in n.flags, "%s: %v", c.id, fl) }
		if .Selected not_in c.flags && .Has_Selected in c.flags { testing.expectf(t, .Selected not_in n.flags, "%s: not selected", c.id) }
	}

	// left out: aria-hidden, hidden, inert; a presentation role is no node (its text is)
	for id in ([]string{"hidden1", "hb", "hidden2", "hb2", "inert", "ib", "decor"}) {
		_, there := f.by_id[id]
		testing.expectf(t, !there, "%s is left out", id)
	}

	// states and values
	if i, ok := f.by_id["news"]; ok {
		p, has := prop(&f, i, .Toggled)
		testing.expect(t, has && p.a == u64(platform.A11y_Toggled.True), "the newsletter box is checked")
	}
	if i, ok := f.by_id["small"]; ok {
		p, has := prop(&f, i, .Toggled)
		testing.expect(t, has && p.a == u64(platform.A11y_Toggled.False), "small is not checked")
	}
	if i, ok := f.by_id["fake"]; ok {
		p, has := prop(&f, i, .Toggled)
		testing.expect(t, has && p.a == u64(platform.A11y_Toggled.True), "aria-pressed: a toggle button that is on")
	}
	if i, ok := f.by_id["name"]; ok {
		testing.expect_value(t, platform.a11y_node_string(&f.u, i, .Value), "Ada")
		testing.expect_value(t, platform.a11y_node_string(&f.u, i, .Placeholder), "First and last name")
		testing.expect(t, .Set_Value in f.u.nodes[i].actions && .Focus in f.u.nodes[i].actions, "a field can be set and focused")
		kids := platform.a11y_node_children(&f.u, i)
		testing.expect_value(t, len(kids), 1)   // its text run
	}
	if i, ok := f.by_id["pw"]; ok {
		testing.expect_value(t, platform.a11y_node_string(&f.u, i, .Value), "")   // a password is not read out
	}
	if i, ok := f.by_id["email"]; ok {
		testing.expect_value(t, platform.a11y_node_string(&f.u, i, .Description), "We never share it.")
	}
	if i, ok := f.by_id["vol"]; ok {
		p, _ := prop(&f, i, .Numeric_Value)
		lo, _ := prop(&f, i, .Min_Numeric_Value)
		hi, _ := prop(&f, i, .Max_Numeric_Value)
		testing.expect(t, p.f == 4 && lo.f == 0 && hi.f == 10, "the range's value and bounds")
	}
	if i, ok := f.by_id["prog"]; ok {
		p, _ := prop(&f, i, .Numeric_Value)
		testing.expect(t, p.f > 0.29 && p.f < 0.31, "the progress's value")
	}
	for c in ([][2]string{{"title", "1"}, {"h-level", "5"}, {"form-h", "2"}}) {
		if i, ok := f.by_id[c[0]]; ok {
			p, _ := prop(&f, i, .Level)
			testing.expectf(t, p.a == u64(c[1][0] - '0'), "%s: level %d", c[0], p.a)
		}
	}
	if i, ok := f.by_id["li2"]; ok {
		pos, _ := prop(&f, i, .Position_In_Set)
		size, _ := prop(&f, i, .Size_Of_Set)
		testing.expect(t, pos.a == 2 && size.a == 3, "the second of three items")
	}
	if i, ok := f.by_id["t"]; ok {
		r, _ := prop(&f, i, .Row_Count)
		c, _ := prop(&f, i, .Column_Count)
		testing.expect(t, r.a == 3 && c.a == 2, "a table of 3 rows, 2 columns")
	}
	if i, ok := f.by_id["live"]; ok {
		p, _ := prop(&f, i, .Live)
		testing.expect_value(t, p.a, u64(platform.A11y_Live.Polite))
	}
	if i, ok := f.by_id["alert"]; ok {
		p, _ := prop(&f, i, .Live)
		testing.expect_value(t, p.a, u64(platform.A11y_Live.Assertive))
	}
	if i, ok := f.by_id["tab1"]; ok {
		p, has := prop(&f, i, .Controls)
		testing.expect(t, has && p.len == 1, "the tab controls its panel")
	}
	if i, ok := f.by_id["home"]; ok {
		testing.expect_value(t, platform.a11y_node_string(&f.u, i, .Url), "/")
		testing.expect(t, .Click in f.u.nodes[i].actions, "a link can be clicked")
	}

	// the root: the document, its title; every child a node
	testing.expect_value(t, Role(f.u.nodes[len(f.u.nodes) - 1].role), Role.Document)
	ids := make(map[u64]bool, len(f.u.nodes), context.temp_allocator)
	for n in f.u.nodes { testing.expect(t, !ids[n.id], "ids are unique"); ids[n.id] = true }
	for _, i in f.u.nodes { for c in platform.a11y_node_children(&f.u, i) { testing.expect(t, ids[c], "a child that is a node") } }
}

@(test)
focus_and_names :: proc(t: ^testing.T) {
	f: Fx
	open(&f, SAMPLE, focus_id = "email")
	defer close(&f)
	i, ok := f.by_id["email"]
	if testing.expect(t, ok, "email") { testing.expect_value(t, f.u.focus, f.u.nodes[i].id) }

	// accname: aria-labelledby wins over aria-label, which wins over content; hidden text referenced counts; a
	// control inside a label gives its value
	g: Fx
	open(&g, `<span id="a" hidden>Hidden part</span><span id="b">Visible</span>
		<button id="x" aria-labelledby="b a" aria-label="Ignored">Content</button>
		<button id="y" aria-label="Labelled">Content</button>
		<label for="z">Amount <input type="text" id="inner" value="5"> euros</label><input id="z" type="text">
		<a id="img-link" href="/x"><img src="a.png" alt="Profile"></a>
		<div id="gen">plain</div>`)
	defer close(&g)
	check :: proc(t: ^testing.T, g: ^Fx, id, want: string) {
		i, ok := g.by_id[id]
		if !testing.expectf(t, ok, "%s: a node", id) { return }
		testing.expectf(t, platform.a11y_node_string(&g.u, i, .Label) == want, "%s: %q, expected %q", id, platform.a11y_node_string(&g.u, i, .Label), want)
	}
	check(t, &g, "x", "Visible Hidden part")
	check(t, &g, "y", "Labelled")
	check(t, &g, "z", "Amount 5 euros")
	check(t, &g, "img-link", "Profile")
	_, gen := g.by_id["gen"]
	testing.expect(t, !gen, "a div that says nothing is no node (its text is)")
	_ = strings.contains
	_ = base.NIL_HANDLE
}
