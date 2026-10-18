package page

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:style"

// The tree as text: kinds, names, attributes, texts, in document order.
@(private = "file")
dump_tree :: proc(d: ^dom.Document) -> string {
	sb := strings.builder_make(context.temp_allocator)
	walk :: proc(sb: ^strings.Builder, d: ^dom.Document, h: base.Handle, depth: int) {
		n := dom.get(d, h)
		fmt.sbprintf(sb, "%d %v %s %q [", depth, n.kind, n.name, n.text)
		for a in n.attrs { fmt.sbprintf(sb, "%s=%q ", a.name, a.value) }
		strings.write_string(sb, "]\n")
		for c := n.first_child; c != base.NIL_HANDLE; c = dom.get(d, c).next { walk(sb, d, c, depth + 1) }
	}
	walk(&sb, d, d.root, 0)
	return strings.to_string(sb)
}

// A stylesheet as text: every rule, selector count, declaration and value token, recursively.
@(private = "file")
dump_rules :: proc(sb: ^strings.Builder, rules: []^css.Rule) {
	values :: proc(sb: ^strings.Builder, vs: []css.Value) {
		for v in vs {
			fmt.sbprintf(sb, "<%v %v %q %v>", v.kind, v.tok.kind, v.tok.text, v.tok.num)
			if len(v.children) > 0 { strings.write_byte(sb, '('); values(sb, v.children); strings.write_byte(sb, ')') }
		}
	}
	for r in rules {
		fmt.sbprintf(sb, "{%v sel=%d url=%q layer=%q name=%q ", r.kind, len(r.selectors), r.url, r.layer, r.name)
		for d in r.declarations { fmt.sbprintf(sb, "%s%s:", d.name, d.important ? "!" : ""); values(sb, d.value); strings.write_byte(sb, ';') }
		dump_rules(sb, r.nested)
		dump_rules(sb, r.rules)
		strings.write_string(sb, "}\n")
	}
}

@(private = "file")
SHEET :: `@charset "utf-8"; @import url(more.css) layer(base);
@layer base, theme;
:root { --accent: #3a7; }
body { margin: 0; font: 15px/1.4 system-ui, sans-serif; color: rgb(20 30 40 / 90%) }
.card > h2 + p:not(.lead), a[href^="https"]:hover { color: var(--accent, red) !important; padding: calc(1em + 2px) 4px }
@media (min-width: 600px) and (prefers-color-scheme: dark) { .card { display: grid; grid-template-columns: repeat(3, 1fr) } }
@supports (display: grid) { .grid { display: grid } }
.nest { color: blue; & .inner { color: green } }
@font-face { font-family: X; src: url(x.woff2) }
@keyframes pulse { from { opacity: 0 } to { opacity: 1 } }
`

@(private = "file")
big_html :: proc() -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "<!doctype html><html><head><meta charset=utf-8><title>t</title><style>")
	for i in 0 ..< 400 { fmt.sbprintf(&sb, ".c%d {{ color: #%06x; padding: %dpx }}\n", i, i * 2654435761 & 0xFFFFFF, i % 9) }
	strings.write_string(&sb, "</style><style media=print>p{color:black}</style></head><body>")
	for i in 0 ..< 2000 { fmt.sbprintf(&sb, "<section class='c%d'><p id=p%d data-x=\"%d\">text &amp; more <b>%d</b><!-- c --></p></section>", i % 400, i, i, i) }
	strings.write_string(&sb, "<table><tr><td>unclosed<p>implied</table></body></html>")
	return strings.to_string(sb)
}

@(test)
document_parsed_in_the_background_is_identical_to_the_synchronous_parse :: proc(t: ^testing.T) {
	// the HTML tree builder allocates from the process heap (its Lexbor callbacks run with the default context): free
	// from the same heap rather than through the test's tracker
	context.allocator = runtime.heap_allocator()
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	pool: host.Blocking_Pool
	host.blocking_init(&pool, &loop, 2)
	defer host.blocking_destroy(&pool)
	loader := fetch.Loader{loop = &loop, blocking = &pool}
	settings := settings_default()
	defer settings_destroy(&settings)
	settings.threads.parse_html_min_bytes = 0
	scope := base.scope_make("test")
	defer base.scope_close(scope)
	src := big_html()

	a := page_create(&loop, &loader, &settings, scope, "http://example.test/")
	ra := load_html(a, transmute([]byte)src)

	b := page_create(&loop, &loader, &settings, scope, "http://example.test/")
	State :: struct { done: bool, offthread: bool, result: Parse_Info }
	st: State
	parse_document(b, transmute([]byte)src, "utf-8", proc(p: ^Page, user: rawptr, d: ^Parsed_Document) {
		s := (^State)(user)
		s.offthread = d.offthread
		r := adopt_document(p, d)
		s.result = Parse_Info{r.ok, r.nodes, d.encoding == "UTF-8"}
		s.done = true
	}, &st)
	start := time.tick_now()
	for !st.done && time.duration_seconds(time.tick_since(start)) < 10 { host.loop_wait(&loop, 5) }
	testing.expect(t, st.done && st.offthread, "parsed on the pool, delivered on the loop thread")
	testing.expect(t, st.result.ok && st.result.nodes == ra.nodes && st.result.utf8, "same parse result")
	testing.expect(t, dump_tree(a.doc) == dump_tree(b.doc), "identical trees")
	testing.expect(t, b.doc.scope == b.scope, "the adopted document belongs to the page")
	testing.expect(t, b.body != base.NIL_HANDLE && b.head != base.NIL_HANDLE)

	// the large <style> was parsed with the document; the computed styles are the same
	sa := styles(a, 800, 600, 1)
	sb := styles(b, 800, 600, 1)
	testing.expect_value(t, len(b.engine.sheets), len(a.engine.sheets))
	testing.expect_value(t, b.engine.rule_count, a.engine.rule_count)
	same := true
	for i in 0 ..< 2000 {
		ha := dom.find_by_id(a.doc, fmt.tprintf("p%d", i))
		hb := dom.find_by_id(b.doc, fmt.tprintf("p%d", i))
		ca, cb := style.style_of(sa, ha), style.style_of(sb, hb)
		if ca == nil || cb == nil || ca.color != cb.color || ca.padding != cb.padding { same = false; break }
	}
	testing.expect(t, same, "same computed styles")

	// a page closing while its document is being parsed: the result is dropped, nothing leaks
	c := page_create(&loop, &loader, &settings, scope, "http://example.test/")
	called := false
	parse_document(c, transmute([]byte)src, "", proc(p: ^Page, user: rawptr, d: ^Parsed_Document) { (^bool)(user)^ = true }, &called)
	page_close(c)
	for _ in 0 ..< 50 { host.loop_wait(&loop, 5) }
	testing.expect(t, !called, "no callback for a closed page")

	// preference off: synchronous, same result
	settings.threads.parse_html = false
	d := page_create(&loop, &loader, &settings, scope, "http://example.test/")
	sync_done := false
	parse_document(d, transmute([]byte)src, "", proc(p: ^Page, user: rawptr, pd: ^Parsed_Document) {
		adopt_document(p, pd)
		(^bool)(user)^ = !pd.offthread
	}, &sync_done)
	testing.expect(t, sync_done, "called before parse_document returned")
	testing.expect(t, dump_tree(d.doc) == dump_tree(a.doc), "identical trees on the synchronous path")
}

@(private = "file")
Parse_Info :: struct { ok: bool, nodes: int, utf8: bool }

@(test)
stylesheet_parsed_in_the_background_is_identical :: proc(t: ^testing.T) {
	opt := css.Parse_Options{max_nesting_depth = 64, max_rules = 100_000}
	direct := css.parse_stylesheet(SHEET, opt)
	defer { css.stylesheet_destroy(direct); free(direct) }

	j := new(Css_Job)
	j.data = make([]byte, len(SHEET))
	copy(j.data, SHEET)
	j.opt, j.max_bytes = opt, 1 << 20
	th := host.thread_start(css_work, j)
	host.thread_join(th)
	testing.expect(t, j.sheet != nil && j.text == nil)
	da := strings.builder_make(context.temp_allocator)
	db := strings.builder_make(context.temp_allocator)
	dump_rules(&da, direct.rules)
	dump_rules(&db, j.sheet.rules)
	testing.expect(t, strings.to_string(da) == strings.to_string(db), "identical rules")
	testing.expect(t, len(direct.rules) >= 9)

	// registered in an engine: the same index as the synchronous path
	settings := style.settings_default()
	defer style.settings_destroy(&settings)
	e1 := style.engine_make(settings)
	defer style.engine_destroy(e1)
	e2 := style.engine_make(settings)
	defer style.engine_destroy(e2)
	style.engine_add_sheet(e1, SHEET, base.Handle(7), "screen", "http://x.test/a.css", from_link = true)
	style.engine_add_parsed_sheet(e2, j.sheet, base.Handle(7), "screen", "http://x.test/a.css", from_link = true)
	j.sheet = nil
	style.engine_rebuild(e1)
	style.engine_rebuild(e2)
	testing.expect_value(t, e2.rule_count, e1.rule_count)
	testing.expect_value(t, len(e2.layers), len(e1.layers))
	testing.expect_value(t, len(e2.keyframes), len(e1.keyframes))
	p1 := style.engine_take_pending_imports(e1)
	p2 := style.engine_take_pending_imports(e2)
	testing.expect(t, len(p1) == 1 && len(p2) == 1 && p1[0].url == p2[0].url, "the same @import to fetch")
	css_job_free(j)

	// over the size limit: not parsed, refused by the engine exactly like the synchronous path
	k := new(Css_Job)
	k.data = make([]byte, len(SHEET))
	copy(k.data, SHEET)
	k.opt, k.max_bytes = opt, 10
	css_work(k)
	testing.expect(t, k.sheet == nil && len(k.text) == len(SHEET), "too large: kept as text for the engine to refuse")
	css_job_free(k)
}
