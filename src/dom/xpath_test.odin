package dom

import "core:testing"
import "wb:base"

// The tree of xpath_select's tests:
//   <html><body><div id=a class=card><span>one</span><span>two</span></div>
//               <div><p>Sale now</p><!--note--><a href=/x>link</a></div></body></html>
@(private = "file")
X_Tree :: struct { d: ^Document, html, body, div_a, one, two, div_b, p, a: base.Handle }

@(private = "file")
x_tree :: proc() -> (x: X_Tree) {
	d := document_create()
	x.d = d
	el :: proc(d: ^Document, parent: base.Handle, name: string, text := "") -> base.Handle {
		h := create_element(d, name)
		append_child(d, parent, h)
		if text != "" { append_child(d, h, create_text(d, text)) }
		return h
	}
	x.html = el(d, d.root, "html")
	x.body = el(d, x.html, "body")
	x.div_a = el(d, x.body, "div")
	set_attribute(d, x.div_a, "id", "a")
	set_attribute(d, x.div_a, "class", "card")
	x.one = el(d, x.div_a, "span", "one")
	x.two = el(d, x.div_a, "span", "two")
	x.div_b = el(d, x.body, "div")
	x.p = el(d, x.div_b, "p", "Sale now")
	append_child(d, x.div_b, create_comment(d, "note"))
	x.a = el(d, x.div_b, "a", "link")
	set_attribute(d, x.a, "href", "/x")
	return
}

@(private = "file")
nodes_of :: proc(d: ^Document, expr: string) -> (out: [dynamic]base.Handle, ok: bool) {
	items := xpath_select(d, base.NIL_HANDLE, expr) or_return
	out = make([dynamic]base.Handle, context.temp_allocator)
	for it in items { append(&out, it.node) }
	return out, true
}

@(test)
xpath_paths_predicates_and_functions :: proc(t: ^testing.T) {
	x := x_tree()
	defer document_destroy(x.d)
	Case :: struct { expr: string, want: []base.Handle }
	cases := []Case{
		{"/html/body/div", {x.div_a, x.div_b}},
		{"//span", {x.one, x.two}},
		{"//span[2]", {x.two}},
		{"//span[last()]", {x.two}},
		{"//div[@id='a']/span[1]", {x.one}},
		{"//*[@class]", {x.div_a}},
		{"//DIV[@ID=\"a\"]", {x.div_a}},                     // names without case
		{"//*[contains(text(), 'Sale')]", {x.p}},
		{"//p[starts-with(., 'Sale')]", {x.p}},
		{"//span[text()='two']/..", {x.div_a}},
		{"//a/@href", {x.a}},                                 // an attribute: of its element
		{"//span | //p", {x.one, x.two, x.p}},                 // a union, in document order
		{"//div[count(span) = 2]", {x.div_a}},
		{"//div[not(@id)]", {x.div_b}},
		{"//span[position() > 1]", {x.two}},
		{"//p/following-sibling::a", {x.a}},
		{"//a/preceding-sibling::*", {x.p}},
		{"//span[1]/ancestor::div", {x.div_a}},
		{"//div[@id='a' or p]", {x.div_a, x.div_b}},
		{"//div[2]//text()", {get(x.d, x.p).first_child, get(x.d, x.a).first_child}},
		{"//comment()", {get(x.d, x.p).next}},
		{"//*[name()='a']", {x.a}},
		{"//nothing", {}},
	}
	for c in cases {
		got, ok := nodes_of(x.d, c.expr)
		same := ok && len(got) == len(c.want)
		for h, i in c.want { if same && got[i] != h { same = false } }
		testing.expectf(t, same, "%s: %v (want %v)", c.expr, got, c.want)
	}
	for bad in ([?]string{"//", "//div[", "//div[@id='a'", "foo(", "//div[unknown()]", "'text"}) {
		_, ok := xpath_select(x.d, base.NIL_HANDLE, bad)
		testing.expectf(t, !ok, "%q is not an expression it reads", bad)
	}
	_, ok := xpath_select(x.d, base.NIL_HANDLE, "1 + 1")
	testing.expect(t, !ok, "a number is not a node set")
}
