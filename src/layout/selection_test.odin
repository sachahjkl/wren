package layout

import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"
import "wb:style"

// Selection queries on laid-out documents (the fake font: every character is 0.5 em wide).

@(private = "file")
Sx :: struct {
	doc: ^dom.Document,
	eng: ^style.Engine,
	st:  ^style.Styled,
	set: Settings,
	l:   Layout,
	vp:  Vec2,
}

@(private = "file")
sx_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font { return Font(1) }
@(private = "file")
sx_width :: proc(user: rawptr, f: Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(rune_count(text)) }
@(private = "file")
sx_metrics :: proc(user: rawptr, f: Font, size: f32) -> Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }
@(private = "file")
sx_api :: Text_Api{font = sx_font, width = sx_width, metrics = sx_metrics}

@(private = "file")
sx_load :: proc(src: string) -> ^Sx {
	f := new(Sx)
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	ss := style.settings_default()
	f.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	f.set = settings_default()
	f.vp = {800, 600}
	run(&f.l, Input{doc = f.doc, styled = f.st, settings = &f.set, text = sx_api, viewport = f.vp, scale = 1, band_h = 256})
	return f
}

@(private = "file")
sx_unload :: proc(f: ^Sx) {
	destroy(&f.l)
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	free(f)
}

@(private = "file")
first_text_of :: proc(f: ^Sx, id: string) -> base.Handle {
	h := dom.find_by_id(f.doc, id)
	stack := make([dynamic]base.Handle, context.temp_allocator)
	append(&stack, h)
	for len(stack) > 0 {
		x := pop(&stack)
		n := dom.get(f.doc, x)
		if n == nil { continue }
		if n.kind == .Text { return x }
		for c := n.last_child; c != base.NIL_HANDLE; c = dom.get(f.doc, c).prev { append(&stack, c) }
	}
	return base.NIL_HANDLE
}

@(private = "file")
all_of :: proc(f: ^Sx) -> (Text_Pos, Text_Pos) {
	body := dom.find_first_by_tag(f.doc, "body")
	return {body, 0}, {body, child_count(f.doc, body)}
}

@(private = "file")
text_of_all :: proc(f: ^Sx) -> string {
	a, b := all_of(f)
	return range_text(f.doc, f.st, a, b).text
}

@(test)
boundary_order :: proc(t: ^testing.T) {
	f := sx_load(`<body><div id=a>one<b id=b>two</b>three</div><p id=c>four</p></body>`)
	defer sx_unload(f)
	a := dom.find_by_id(f.doc, "a")
	one := first_text_of(f, "a")
	two := first_text_of(f, "b")
	four := first_text_of(f, "c")
	testing.expect_value(t, pos_compare(f.doc, {one, 1}, {one, 2}), -1)
	testing.expect_value(t, pos_compare(f.doc, {one, 3}, {two, 0}), -1)
	testing.expect_value(t, pos_compare(f.doc, {four, 0}, {two, 3}), 1)
	testing.expect_value(t, pos_compare(f.doc, {a, 0}, {one, 0}), -1)      // before the first child
	testing.expect_value(t, pos_compare(f.doc, {a, 1}, {one, 2}), 1)       // after the first child
	testing.expect_value(t, pos_compare(f.doc, {a, 1}, {two, 0}), -1)
	testing.expect(t, node_in_range(f.doc, dom.find_by_id(f.doc, "b"), {one, 0}, {four, 1}), "b inside")
	testing.expect(t, !node_in_range(f.doc, dom.find_by_id(f.doc, "c"), {one, 0}, {four, 1}), "c only partly")
}

@(test)
point_to_position :: proc(t: ^testing.T) {
	f := sx_load(`<body style="margin:0;font:10px/20px x"><p id=p style="margin:0">Hello world</p>
<div style="display:flex"><div id=l style="width:200px">left side</div><div id=r>right</div></div>
<div id=moved style="transform:translateX(300px)">abcdef</div>
<p id=ns style="margin:0;user-select:none">skip me</p><p id=after style="margin:0">tail</p></body>`)
	defer sx_unload(f)
	p := first_text_of(f, "p")
	pos, ok := position_at(&f.l, f.doc, f.st, {12, 5}, f.vp, 0, sx_api)
	testing.expect(t, ok && pos.node == p, "on the first line")
	testing.expect_value(t, pos.offset, 2)          // 12 px: nearer to the 2nd boundary (10) than the 3rd (15)
	pos, ok = position_at(&f.l, f.doc, f.st, {14, 5}, f.vp, 0, sx_api)
	testing.expect_value(t, pos.offset, 3)
	pos, _ = position_at(&f.l, f.doc, f.st, {700, 5}, f.vp, 0, sx_api)
	testing.expect_value(t, pos.offset, 11)         // right of the line: its end
	// in the gutter of the flex item "left side": stays in that item
	pos, ok = position_at(&f.l, f.doc, f.st, {150, 25}, f.vp, 0, sx_api)
	testing.expect(t, ok && pos.node == first_text_of(f, "l"), "the column the point is in")
	testing.expect_value(t, pos.offset, 9)
	// transformed: the point goes through the inverse of the transform
	pos, ok = position_at(&f.l, f.doc, f.st, {311, 45}, f.vp, 0, sx_api)
	testing.expect(t, ok && pos.node == first_text_of(f, "moved"), "transformed text")
	testing.expect_value(t, pos.offset, 2)
	// user-select: none is skipped: the nearest selectable text wins
	pos, ok = position_at(&f.l, f.doc, f.st, {10, 65}, f.vp, 0, sx_api)
	testing.expect(t, ok && pos.node != first_text_of(f, "ns"), "user-select: none")
	// scrolled document: the same point is further down
	pos, ok = position_at(&f.l, f.doc, f.st, {6, 5}, f.vp, 80, sx_api)
	testing.expect(t, ok && pos.node == first_text_of(f, "after"), "below everything: the last line")
}

@(test)
item_ranges :: proc(t: ^testing.T) {
	f := sx_load(`<body style="margin:0;font:10px/20px x"><p id=p style="margin:0">Hello <b id=b>bold</b> end</p></body>`)
	defer sx_unload(f)
	hello := first_text_of(f, "p")
	bold := first_text_of(f, "b")
	n := 0
	for i in 0 ..< len(f.l.items) {
		a, b, ok := item_range(&f.l, f.doc, i, {hello, 2}, {bold, 2})
		if !ok { continue }
		node, _, _, _ := item_source(&f.l, f.doc, i)
		if node == hello { testing.expect_value(t, f.l.items[i].text[a:b], "llo ") }
		if node == bold { testing.expect_value(t, f.l.items[i].text[a:b], "bo") }
		n += 1
	}
	testing.expect_value(t, n, 2)
}

@(test)
words :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, text: string, at: int, want: string, eat := false, loc := #caller_location) {
		a, b := word_bounds(text, at, eat)
		testing.expectf(t, text[a:b] == want, "%q at %d: got %q, want %q", text, at, text[a:b], want, loc = loc)
	}
	check(t, "hello world", 2, "hello")
	check(t, "hello world", 5, " ")
	check(t, "hello world", 2, "hello ", eat = true)
	check(t, "l'été, c'est", 3, "l'été")
	check(t, "pi = 3.14159!", 7, "3.14159")
	check(t, "end.", 1, "end")
	check(t, "a -- b", 3, "--")
	check(t, "日本語のテキスト", 0, "日")
	check(t, "日本語のテキスト", 12, "テキスト")
	check(t, "snake_case_name x", 4, "snake_case_name")
	check(t, "x", 1, "x")
}

@(test)
words_across_elements :: proc(t: ^testing.T) {
	f := sx_load(`<body><p id=p>say foo<b id=b>bar</b> baz</p><div id=d>first<br>second line</div></body>`)
	defer sx_unload(f)
	bar := first_text_of(f, "b")
	s, e, ok := word_range(f.doc, f.st, {bar, 1})
	testing.expect(t, ok, "found")
	testing.expect_value(t, range_text(f.doc, f.st, s, e).text, "foobar")
	s, e, ok = paragraph_range(f.doc, f.st, {bar, 1})
	testing.expect_value(t, range_text(f.doc, f.st, s, e).text, "say foobar baz")
	s, e, ok = paragraph_range(f.doc, f.st, {first_text_of(f, "d"), 0})
	testing.expect_value(t, range_text(f.doc, f.st, s, e).text, "first\nsecond line")
}

@(test)
inner_text_serialization :: proc(t: ^testing.T) {
	{
		f := sx_load(`<body><div>a</div><div>b</div><p>x</p><p>y</p>tail</body>`)
		defer sx_unload(f)
		testing.expect_value(t, text_of_all(f), "a\nb\n\nx\n\ny\n\ntail")
	}
	{
		f := sx_load(`<body><table><tr><td>1</td><td>2</td></tr><tr><td>3</td><td>4</td></tr></table></body>`)
		defer sx_unload(f)
		testing.expect_value(t, text_of_all(f), "1\t2\n3\t4")
	}
	{
		f := sx_load(`<body><ul><li>one</li><li>two <i>2</i></li></ul><ol><li>three</ol></body>`)
		defer sx_unload(f)
		testing.expect_value(t, text_of_all(f), "one\ntwo 2\nthree")
	}
	{
		f := sx_load("<body><p>  many   spaces\n and\tlines  </p><pre>keep  \n  this</pre><span style=\"display:none\">hidden</span><span style=\"visibility:hidden\">invisible</span>shown<br>next</body>")
		defer sx_unload(f)
		testing.expect_value(t, text_of_all(f), "many spaces and lines\n\nkeep  \n  this\nshown\nnext")
	}
	{
		f := sx_load(`<body><p style="text-transform:uppercase">loud</p><p style="white-space:pre-line">a  b
c</p></body>`)
		defer sx_unload(f)
		testing.expect_value(t, text_of_all(f), "LOUD\n\na b\nc")
	}
	{
		// a range from the middle of one block to the middle of another
		f := sx_load(`<body><div id=a>alpha beta</div><div id=b>gamma delta</div></body>`)
		defer sx_unload(f)
		ft := range_text(f.doc, f.st, {first_text_of(f, "a"), 6}, {first_text_of(f, "b"), 5})
		testing.expect_value(t, ft.text, "beta\ngamma")
		// and back to the DOM
		p, ok := flat_to_pos(ft, 5)
		testing.expect(t, ok && p.node == first_text_of(f, "b") && p.offset == 0, "the second block starts at its text")
		testing.expect_value(t, pos_to_flat(f.doc, ft, {first_text_of(f, "a"), 8}), 2)
	}
}

@(test)
html_of_a_range :: proc(t: ^testing.T) {
	f := sx_load(`<body><p id=p>one <a href="x?a=1&amp;b=2" onclick="evil()">two</a> three</p></body>`)
	defer sx_unload(f)
	one := first_text_of(f, "p")
	p := dom.find_by_id(f.doc, "p")
	s := range_html(f.doc, {one, 2}, {p, child_count(f.doc, p)})
	testing.expect(t, strings.contains(s, `e <a href="x?a=1&amp;b=2">two</a> three`), s)
	testing.expect(t, !strings.contains(s, "onclick"), "no event handlers")
}
