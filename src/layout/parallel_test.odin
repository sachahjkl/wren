package layout

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:html"
import "wb:style"

// Full passes with inline formatting contexts laid out ahead on the layout threads against the same passes on one
// thread (compare_layouts: every box, line, fragment, display item, space, clip, group, band), then incremental passes
// on top of the threaded result against full passes.

@(private = "file")
pt_width :: proc(user: rawptr, fo: Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(rune_count(text)) }

@(private = "file")
Pt :: struct {
	doc: ^dom.Document,
	eng: ^style.Engine,
	st:  ^style.Styled,
}

@(private = "file")
pt_load :: proc(src: string) -> Pt {
	f: Pt
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 4_000_000)
	ss := style.settings_default()
	f.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.engine_set_journal(f.eng, 1 << 16)
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	return f
}

@(private = "file")
pt_unload :: proc(f: ^Pt) {
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	dom.document_destroy(f.doc)
}

@(private = "file")
pt_input :: proc(f: ^Pt, set: ^Settings, vp: Vec2) -> Input {
	api := Text_Api{
		font = proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font { return 1 },
		width = pt_width,
		metrics = proc(user: rawptr, fo: Font, size: f32) -> Font_Metrics { return {0.8 * size, 0.2 * size, 0.5 * size} },
		concurrent = true,
	}
	return Input{doc = f.doc, styled = f.st, settings = set, text = api, viewport = vp, scale = 1.25, band_h = 64}
}

// A threaded full pass of `l` (retried while another layout holds the threads), compared with a pass on one thread.
@(private = "file")
pt_check :: proc(t: ^testing.T, f: ^Pt, l: ^Layout, vp: Vec2, what: string, want_taken := true, loc := #caller_location) {
	par := settings_default()
	par.threads, par.threads_min_contexts = 3, 0
	for tries in 0 ..< 200 {
		l.valid = false
		run(l, pt_input(f, &par, vp))
		if l.pre_counts[0] > 0 || tries == 199 || !want_taken { break }
		time.sleep(5 * time.Millisecond)
	}
	if want_taken {
		testing.expectf(t, l.pre_counts[1] > 0, "%s: no context laid out ahead was taken (%v)", what, l.pre_counts, loc = loc)
	}
	one := settings_default()
	one.threads = 0
	ref: Layout
	defer destroy(&ref)
	run(&ref, pt_input(f, &one, vp))
	testing.expect_value(t, ref.pre_counts, [2]int{})
	ok, report := compare_layouts(l, &ref)
	testing.expectf(t, ok, "%s: threaded pass differs: %s", what, report, loc = loc)
}

@(private = "file")
PT_PAGE :: `<style>
body{margin:0;font-size:10px;line-height:12px}
.sec{margin:8px 4%;padding:4px 2%;border:1px solid}
article{padding:2px;margin:3px 0}
h3{margin:0 0 4px;font-size:14px;text-indent:10%}
p{margin:2px 0}
.j{text-align:justify}
.c{text-align:center}
.pre{white-space:pre}
.pw{white-space:pre-wrap}
.e{overflow:hidden;white-space:nowrap;text-overflow:ellipsis;width:120px}
.pad{padding:0 5%;border:2px solid;margin:0 3px}
.row{display:flex;gap:4px}
.row > div{flex:1;padding:2px}
.fl{float:left;width:60px;height:30px}
.abs{position:absolute;left:10px;top:20px;width:50px}
.rel{position:relative}
.narrow{width:300px}
.mx{max-width:200px}
.ib{display:inline-block;width:40px}
.bfc{overflow:hidden}
</style><body>
<div class=sec><article><h3>Title one</h3><p>alpha beta gamma <span class=pad>delta epsilon</span> zeta eta theta iota kappa lambda mu</p></article>
<article><h3>Title two</h3><p class=j>nu xi omicron pi rho sigma tau upsilon<u> underlined</u> end and more words to justify over lines</p></article></div>
<div class=sec><p class=c>centered text that wraps<br>after a break and <b>bold <i>italic</i></b> words</p><p class=pre>pre  formatted
second line	tab</p><p class=pw>pre wrap   keeps   spaces and wraps when the line is long enough to wrap</p></div>
<div class=sec><p class=e>an ellipsis on a long line of text that overflows</p><p dir=rtl>right to left paragraph of text</p></div>
<div class="sec row"><div>one flex item</div><div>two two</div><div>three three three</div></div>
<div class=sec><div class=fl></div><p>text beside the float that wraps around it for a while and then continues below it when it is long enough</p><p>after the float</p></div>
<div class="sec bfc"><div class=fl></div><div class=bfc><p>inside a formatting context beside a float</p></div></div>
<div class=sec><p>an <span class=ib>atomic</span> inline block</p><p class=narrow>a fixed width paragraph that wraps</p><div class=mx><p>under a max width</p></div></div>
<ol><li>first item<li>second item with more words<li style="list-style-position:inside">inside marker</ol>
<div class="sec rel"><p>positioned container</p><div class=abs><p>absolute box text</p></div></div>
<table><tr><td>cell one</td><td>cell two words</td></tr></table>
<div>anonymous <p>block in block</p> text after</div>
`

@(private = "file")
pt_page :: proc() -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, PT_PAGE)
	for i in 0 ..< 120 {
		fmt.sbprintf(&sb, "<div class=sec><p>filler %d with <b>some</b> words to wrap in lines <a href=#>link</a> and <em>more %d</em></p></div>\n", i, i * 7)
	}
	strings.write_string(&sb, "</body>")
	return strings.to_string(sb)
}

@(test)
parallel_full_passes :: proc(t: ^testing.T) {
	defer shutdown_threads()
	f := pt_load(pt_page())
	defer pt_unload(&f)
	l: Layout
	defer destroy(&l)
	for w in ([]f32{800, 333, 1500, 90}) { pt_check(t, &f, &l, {w, 600}, fmt.tprintf("width %v", w)) }
	// a fresh layout (first pass of a document)
	{
		l2: Layout
		defer destroy(&l2)
		pt_check(t, &f, &l2, {640, 480}, "fresh layout")
	}

	// incremental passes on top of a threaded full pass
	par := settings_default()
	par.threads, par.threads_min_contexts = 3, 0
	pt_check(t, &f, &l, {800, 600}, "before changes")
	inc_ok :: proc(t: ^testing.T, f: ^Pt, l: ^Layout, set: ^Settings, vp: Vec2, what: string) {
		run(l, pt_input(f, set, vp))
		ref: Layout
		defer destroy(&ref)
		one := settings_default()
		one.threads = 0
		run_full(&ref, pt_input(f, &one, vp))
		ok, report := compare_layouts(l, &ref)
		testing.expectf(t, ok, "%s (%v pass): differs from a full pass: %s", what, l.last_pass, report)
	}
	inc_ok(t, &f, &l, &par, {700, 600}, "resize")
	// a text changed
	ps := make([dynamic]base.Handle, context.temp_allocator)
	stack := make([dynamic]base.Handle, context.temp_allocator)
	append(&stack, f.doc.root)
	for len(stack) > 0 {
		h := pop(&stack)
		n := dom.get(f.doc, h)
		if n.kind == .Element && n.name == "p" { append(&ps, h) }
		for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(f.doc, ch).next { append(&stack, ch) }
	}
	dom.set_text_content(f.doc, ps[len(ps) / 2], "a changed paragraph that is longer than it was and wraps on a few lines at this width")
	old := f.st
	f.st = style.compute_styles(f.eng, f.doc, {})
	style.journal_diff(old, f.st)
	style.styled_destroy(old)
	inc_ok(t, &f, &l, &par, {700, 600}, "text")
}

// A page with no paragraph laid out ahead (every context has an atomic inline or sits in a flex container).
@(test)
parallel_nothing_ahead :: proc(t: ^testing.T) {
	defer shutdown_threads()
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "<style>.ib{display:inline-block}.row{display:flex}</style><body>")
	for i in 0 ..< 40 { fmt.sbprintf(&sb, "<p>text <span class=ib>%d</span></p><div class=row><div>flex %d</div></div>", i, i) }
	f := pt_load(strings.to_string(sb))
	defer pt_unload(&f)
	l: Layout
	defer destroy(&l)
	pt_check(t, &f, &l, {500, 400}, "nothing ahead", want_taken = false)
	testing.expect_value(t, l.pre_counts[1], 0)
}
