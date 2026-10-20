package layout

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"
import "wb:style"

// Incremental layout against full passes: after each change, the incremental result is compared with a full pass of
// the same input (compare_layouts: every box, line, fragment, display item, space, clip, group, band). Each case also
// checks that the change was handled incrementally (the point is to not fall back to full passes).

@(private = "file")
Ix :: struct {
	doc:   ^dom.Document,
	eng:   ^style.Engine,
	st:    ^style.Styled,
	tl:    ^style.Timeline,
	set:   Settings,
	l:     Layout,
	vp:    Vec2,
	now:   f64,
	sizes: map[base.Handle][2]f32,   // natural sizes of images that "decoded"
	images_gen, fonts_gen: u64,
	web_font: bool,                  // the face of family "web" arrived (wider glyphs)
	full_styles: bool,               // every mutation restyles the whole document (no style.restyle_dom)
	partial_styles: int,             // restyles done by style.restyle_dom
	threads: bool,                   // text measured from several threads: paragraphs laid out ahead (parallel.odin)
}

@(private = "file")
ix_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font {
	f := (^Ix)(user)
	if f.web_font && len(families) > 0 && families[0] == "web" { return Font(2) }
	return Font(1)
}
@(private = "file")
ix_width :: proc(user: rawptr, fo: Font, size: f32, text: string) -> f32 {
	k: f32 = fo == 2 ? 0.6 : 0.5
	return k * size * f32(rune_count(text))
}
@(private = "file")
ix_metrics :: proc(user: rawptr, fo: Font, size: f32) -> Font_Metrics {
	if fo == 2 { return {ascent = 0.9 * size, descent = 0.25 * size, x_height = 0.5 * size} }
	return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size}
}
@(private = "file")
ix_intrinsic :: proc(user: rawptr, node: base.Handle) -> (w, h: f32, ok: bool) {
	f := (^Ix)(user)
	s, found := f.sizes[node]
	return s.x, s.y, found
}

@(private = "file")
ix_input :: proc(f: ^Ix) -> Input {
	return Input{doc = f.doc, styled = f.st, settings = &f.set, text = Text_Api{user = f, font = ix_font, width = ix_width, metrics = ix_metrics, concurrent = f.threads},
		replaced = Replaced_Api{user = f, intrinsic = ix_intrinsic}, viewport = f.vp, scale = 1, band_h = 64,
		images_generation = f.images_gen, fonts_generation = f.fonts_gen}
}

@(private = "file")
ix_load :: proc(src: string, vw: f32 = 800, vh: f32 = 600) -> ^Ix {
	f := new(Ix)
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	ss := style.settings_default()
	f.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.engine_set_journal(f.eng, 1 << 16)
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	f.tl = style.timeline_make(f.eng)
	style.timeline_restyled(f.tl, f.doc, nil, f.st, 0)
	style.timeline_tick(f.tl, f.doc, f.st, 0)
	f.set = settings_default()
	f.vp = {vw, vh}
	f.sizes = make(map[base.Handle][2]f32)
	run(&f.l, ix_input(f))
	return f
}

@(private = "file")
ix_unload :: proc(f: ^Ix) {
	destroy(&f.l)
	style.timeline_destroy(f.tl, f.st)
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	delete(f.sizes)
	free(f)
}

// What the page does each frame (page.styles): styles for the document as it is (a partial restyle after a mutation
// when it can be scoped, else a full pass compared with the previous one), the timeline, then layout.
@(private = "file")
ix_frame :: proc(f: ^Ix, dt: f64 = 16) {
	f.now += dt
	if f.st.mutations != f.doc.mutations {
		partial := false
		if !f.full_styles {
			if style.dom_touches_sheets(f.eng, f.doc, f.st, nil) { style.sync_document_sheets(f.eng, f.doc, "about:test") }
			if !f.eng.dirty { _, partial = style.restyle_dom(f.eng, f.doc, f.st) }
		}
		if partial {
			f.partial_styles += 1
			style.timeline_restyled_dom(f.tl, f.doc, f.st, f.now)
		} else {
			style.sync_document_sheets(f.eng, f.doc, "about:test")
			old := f.st
			f.st = style.compute_styles(f.eng, f.doc, {})
			style.journal_diff(old, f.st)
			style.timeline_restyled(f.tl, f.doc, old, f.st, f.now)
			style.styled_destroy(old)
		}
	}
	style.timeline_tick(f.tl, f.doc, f.st, f.now)
	run(&f.l, ix_input(f))
}

// The layout equals a full pass of the same input; `want`: how the last pass was done.
@(private = "file")
ix_check :: proc(t: ^testing.T, f: ^Ix, want := Pass_Kind.Incremental, loc := #caller_location) -> bool {
	ref: Layout
	defer destroy(&ref)
	ref.scroll = make(map[base.Handle]Vec2)
	for k, v in f.l.scroll { ref.scroll[k] = v }
	run_full(&ref, ix_input(f))
	ok, report := compare_layouts(&f.l, &ref)
	testing.expectf(t, ok, "incremental differs from full: %s", report, loc = loc)
	if want != .None {
		testing.expectf(t, f.l.last_pass == want, "pass %v, want %v (%s)", f.l.last_pass, want, f.l.inc.fallback, loc = loc)
		ok = ok && f.l.last_pass == want
	}
	return ok
}

@(private = "file")
id :: proc(f: ^Ix, s: string) -> base.Handle { return dom.find_by_id(f.doc, s) }

@(private = "file")
first_text_node :: proc(f: ^Ix, h: base.Handle) -> base.Handle {
	for ch := dom.get(f.doc, h).first_child; ch != base.NIL_HANDLE; ch = dom.get(f.doc, ch).next {
		if dom.get(f.doc, ch).kind == .Text { return ch }
	}
	return base.NIL_HANDLE
}

@(private = "file")
add_el :: proc(f: ^Ix, parent: base.Handle, tag: string, attrs: string = "", text: string = "", before := base.NIL_HANDLE) -> base.Handle {
	e := dom.create_element(f.doc, tag)
	if attrs != "" { dom.set_attribute(f.doc, e, "style", attrs) }
	if text != "" { dom.append_child(f.doc, e, dom.create_text(f.doc, text)) }
	dom.insert_before(f.doc, parent, e, before)
	return e
}

@(private = "file")
PAGE :: `<style>
body{margin:0;font-size:10px;line-height:12px}
.sec{margin:8px 4px;padding:4px;border:1px solid}
article{padding:2px;margin:3px 0}
h3{margin:0 0 4px;font-size:14px}
p{margin:2px 0}
.row{display:flex;gap:4px}
.row > div{flex:1;padding:2px}
table{border-spacing:2px}
.fl{float:left;width:60px;height:30px}
.abs{position:absolute;left:10px;top:20px;width:50px}
.rel{position:relative}
</style><body>
<div class=sec id=s1><article><h3>Title one</h3><p id=p1>alpha beta gamma <span id=sp1>delta epsilon</span> zeta eta theta iota kappa lambda mu</p></article>
<article id=a2><h3>Title two</h3><p id=p2>nu xi omicron pi rho sigma tau upsilon<u> underlined</u> end</p></article></div>
<div class="sec row" id=flex><div id=f1>one</div><div id=f2>two two</div><div id=f3>three three three</div></div>
<div class=sec id=floats><div class=fl id=fl1></div><p id=pf>text beside the float that wraps around it for a while and then continues below it when it is long enough</p><div id=after>after</div></div>
<table id=tab><tbody id=tb><tr id=r1><td id=c11>a</td><td>bb</td></tr><tr id=r2><td>ccc</td><td id=c22>dddd</td></tr></tbody></table>
<ol id=ol><li>first<li id=li2>second<li>third</ol>
<div class="sec rel" id=pos><p id=pp>positioned container</p><div class=abs id=ab>absolute box</div></div>
<div class=sec id=imgs><img id=im1 width=40 height=20><span> image text</span></div>
<div class=sec id=last><p id=pl>the end</p></div>
`

// The page above with enough filler after it that a local change is a small part of it.
@(private = "file")
page :: proc() -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, PAGE)
	for i in 0 ..< 60 { fmt.sbprintf(&sb, "<div class=sec><p>filler %d with <b>some</b> words to wrap in lines</p></div>\n", i) }
	strings.write_string(&sb, "</body>")
	return strings.to_string(sb)
}

@(test)
inc_text_change :: proc(t: ^testing.T) {
	f := ix_load(page())
	defer ix_unload(f)
	ix_frame(f)
	ix_check(t, f, .None)
	// same length: nothing moves
	tn := first_text_node(f, id(f, "p2"))
	dom.set_text_content(f.doc, tn, "NU XI OMICRON PI RHO SIGMA TAU UPSILON")
	ix_frame(f)
	ix_check(t, f)
	testing.expect(t, f.l.inc.last_rebuilt < 10, "only the paragraph is rebuilt")
	testing.expect(t, f.l.inc.last_spliced, "nothing moved: the display list is spliced")
	// shorter, still one line: spliced too (fewer items)
	dom.set_text_content(f.doc, tn, "NU XI")
	ix_frame(f)
	ix_check(t, f)
	testing.expect(t, f.l.inc.last_spliced, "spliced with fewer items")
	// an inline element added inside the paragraph
	add_el(f, id(f, "p2"), "em", "", " added")
	ix_frame(f)
	ix_check(t, f)
	// longer: more lines, everything below moves
	dom.set_text_content(f.doc, tn, strings.repeat("word ", 60, context.temp_allocator))
	ix_frame(f)
	ix_check(t, f)
	// text of an inline element
	dom.set_text_content(f.doc, id(f, "sp1"), "x")
	ix_frame(f)
	ix_check(t, f)
	// text in a paragraph beside a float
	dom.set_text_content(f.doc, first_text_node(f, id(f, "pf")), "short")
	ix_frame(f)
	ix_check(t, f)
}

@(test)
inc_insert_remove :: proc(t: ^testing.T) {
	f := ix_load(page())
	defer ix_unload(f)
	// flex: insert, remove
	x := add_el(f, id(f, "flex"), "div", "", "new item with words", id(f, "f2"))
	ix_frame(f)
	ix_check(t, f)
	dom.remove_child(f.doc, id(f, "flex"), id(f, "f1"))
	ix_frame(f)
	ix_check(t, f)
	dom.remove_child(f.doc, id(f, "flex"), x)
	dom.release(f.doc, x)
	ix_frame(f)
	ix_check(t, f)
	// table: a row, a cell
	r := add_el(f, id(f, "tb"), "tr")
	add_el(f, r, "td", "", "wide cell content here")
	ix_frame(f)
	ix_check(t, f)
	add_el(f, id(f, "r1"), "td", "", "third")
	ix_frame(f)
	ix_check(t, f)
	// block with floats: a float before the paragraph, then removed
	fl := add_el(f, id(f, "floats"), "div", "float:right;width:80px;height:50px", "", id(f, "pf"))
	ix_frame(f)
	ix_check(t, f)
	dom.remove_child(f.doc, id(f, "floats"), fl)
	ix_frame(f)
	ix_check(t, f)
	// list: an item in the middle renumbers the following ones
	add_el(f, id(f, "ol"), "li", "", "inserted", id(f, "li2"))
	ix_frame(f)
	ix_check(t, f)
	// a whole section
	add_el(f, dom.find_first_by_tag(f.doc, "body"), "div", "padding:5px", "new section", id(f, "last"))
	ix_frame(f)
	ix_check(t, f)
}

@(private = "file")
GRID_PAGE :: `<style>
body{margin:0;font-size:10px;line-height:12px}
.g{display:grid;grid-template-columns:repeat(auto-fill,minmax(60px,1fr));gap:4px;padding:4px}
.areas{display:grid;grid-template:"h h" 20px "s m" auto / 80px 1fr;gap:2px}
.areas > header{grid-area:h} .areas > nav{grid-area:s} .areas > main{grid-area:m}
.dense{display:grid;grid-template-columns:repeat(4,40px);grid-auto-flow:dense}
.wide{grid-column:span 2}
.fx{filter:blur(2px) drop-shadow(2px 2px 3px black);padding:3px}
.clip{clip-path:circle(40%);width:50px;height:50px}
.blend{mix-blend-mode:multiply;padding:2px}
</style><body>
<div class=g id=gal><div id=g1>one</div><div id=g2>two words</div><div id=g3>three words here</div><div>four</div><div>five</div></div>
<div class=areas id=ar><header>head</header><nav id=nav>side text</nav><main id=mn><p id=mp>main text that wraps over a few lines in the main area</p></main></div>
<div class=dense id=dn><div class=wide>a</div><div>b</div><div class=wide>c</div><div>d</div></div>
<div class=fx id=fx><p id=fp>blurred text with a shadow</p></div>
<div class=clip id=cl>clipped</div>
<div style="isolation:isolate"><div class=blend id=bl>multiplied text</div></div>
</body>`

// Grid containers and effect groups (merged after the incremental work): every change still equals a full pass.
@(test)
inc_grid_and_effects :: proc(t: ^testing.T) {
	f := ix_load(GRID_PAGE)
	defer ix_unload(f)
	ix_frame(f)
	ix_check(t, f, .None)
	dom.set_text_content(f.doc, first_text_node(f, id(f, "mp")), "short")
	ix_frame(f)
	ix_check(t, f, .None)
	dom.set_text_content(f.doc, id(f, "g2"), strings.repeat("long ", 30, context.temp_allocator))
	ix_frame(f)
	ix_check(t, f, .None)
	x := add_el(f, id(f, "gal"), "div", "grid-column:1 / -1", "full row", id(f, "g3"))
	ix_frame(f)
	ix_check(t, f, .None)
	dom.remove_child(f.doc, id(f, "gal"), x)
	dom.release(f.doc, x)
	ix_frame(f)
	ix_check(t, f, .None)
	add_el(f, id(f, "dn"), "div", "", "e", dom.get(f.doc, id(f, "dn")).first_child)
	ix_frame(f)
	ix_check(t, f, .None)
	dom.set_attribute(f.doc, id(f, "nav"), "style", "padding:10px")
	ix_frame(f)
	ix_check(t, f, .None)
	dom.set_text_content(f.doc, first_text_node(f, id(f, "fp")), "other blurred words, longer than before, on two lines maybe")
	ix_frame(f)
	ix_check(t, f, .None)
	dom.set_attribute(f.doc, id(f, "cl"), "style", "width:80px;height:30px")
	ix_frame(f)
	ix_check(t, f, .None)
	dom.set_text_content(f.doc, id(f, "bl"), "x")
	ix_frame(f)
	ix_check(t, f, .None)
	for w in ([]f32{600, 333, 150, 800}) {
		f.vp.x = w
		ix_frame(f)
		ix_check(t, f, .None)
	}
}

@(test)
inc_viewport :: proc(t: ^testing.T) {
	f := ix_load(page())
	defer ix_unload(f)
	for w in ([]f32{700, 520, 300, 801, 800}) {
		f.vp.x = w
		ix_frame(f)
		ix_check(t, f)
	}
	f.vp.y = 400
	ix_frame(f)
	ix_check(t, f)
	laid := f.l.inc.last_laid
	testing.expectf(t, laid * 4 < len(f.l.boxes), "height only: %d boxes of %d laid out again", laid, len(f.l.boxes))
	// percentage heights, fixed boxes and vh follow the height
	g := ix_load(`<style>html,body{height:100%;margin:0} .h{height:50%} .fx{position:fixed;bottom:0;height:10%;width:20px} .v{height:10vh}</style><body><div class=h id=h>half</div><div class=fx></div><div class=v>vh</div></body>`)
	defer ix_unload(g)
	for h in ([]f32{500, 300, 650}) {
		g.vp.y = h
		ix_frame(g)
		ix_check(t, g)
	}
}

@(test)
inc_styles :: proc(t: ^testing.T) {
	f := ix_load(page())
	defer ix_unload(f)
	steps := [?]struct { id, style: string, want: Pass_Kind }{
		{"a2", "width:300px", .Incremental},             // keeps its box: laid out again
		{"s1", "font-size:20px", .Incremental},          // inherited by everything inside: that section rebuilt
		{"f2", "display:none", .Incremental},
		{"f2", "", .Incremental},
		{"p1", "display:inline-block", .Incremental},
		{"ab", "left:100px;top:5px", .Incremental},
		{"pos", "position:static", .Incremental},
		{"pp", "float:left;width:100px", .Incremental},
		{"c11", "padding:10px", .Incremental},
		{"imgs", "margin-left:50px", .Incremental},
		{"a2", "overflow:hidden;height:20px", .Incremental},
		{"pl", "margin-top:-30px", .Incremental},
		{"last", "position:fixed;top:0", .None},          // out of flow in the body: the body's content is rebuilt
	}
	for s in steps {
		dom.set_attribute(f.doc, id(f, s.id), "style", s.style)
		ix_frame(f)
		if !ix_check(t, f, s.want) { fmt.println("after", s.id, s.style) }
	}
}

@(test)
inc_animation :: proc(t: ^testing.T) {
	f := ix_load(`<style>
@keyframes grow { from { width: 100px; margin-left: 0 } to { width: 300px; margin-left: 40px } }
@keyframes spin { from { transform: rotate(0deg) } to { transform: rotate(90deg) } }
.a { animation: grow 1000ms linear infinite; padding: 2px }
.b { animation: spin 1000ms linear infinite }
</style><body><div class=a id=a>growing box with some text in it that wraps</div><p>below</p><div class=b>spinning</div><p>end</p></body>`)
	defer ix_unload(f)
	for _ in 0 ..< 10 {
		ix_frame(f, 37)
		ix_check(t, f, .None)
		testing.expect(t, f.l.last_pass == .Incremental || f.l.last_pass == .Refresh, "animation frames are incremental")
	}
}

@(test)
inc_images_fonts :: proc(t: ^testing.T) {
	f := ix_load(`<style>body{margin:0} .w{font-family:web, sans-serif}</style><body><p>before <img id=im> after</p><img id=im2 style="width:50%"><p class=w id=w>web font text that is long enough to wrap at some point in the viewport width</p><p>plain</p></body>`, 300, 200)
	defer ix_unload(f)
	f.sizes[id(f, "im")] = {40, 30}
	f.images_gen += 1
	ix_frame(f)
	ix_check(t, f)
	f.sizes[id(f, "im2")] = {200, 100}
	f.images_gen += 1
	ix_frame(f)
	ix_check(t, f)
	f.web_font = true
	f.fonts_gen += 1
	ix_frame(f)
	ix_check(t, f)
}

@(test)
inc_attributes :: proc(t: ^testing.T) {
	f := ix_load(page())
	defer ix_unload(f)
	dom.set_attribute(f.doc, id(f, "c11"), "colspan", "2")
	ix_frame(f)
	ix_check(t, f)
	dom.set_attribute(f.doc, id(f, "ol"), "start", "7")
	ix_frame(f)
	ix_check(t, f)
	dom.set_attribute(f.doc, id(f, "im1"), "width", "120")
	ix_frame(f)
	ix_check(t, f)
	dom.set_attribute(f.doc, id(f, "p1"), "data-x", "1")   // nothing for layout
	ix_frame(f)
	ix_check(t, f)
}

@(test)
inc_disabled_and_garbage :: proc(t: ^testing.T) {
	f := ix_load(page())
	defer ix_unload(f)
	f.set.incremental = false
	run(&f.l, ix_input(f))   // settings changed: full
	dom.set_text_content(f.doc, first_text_node(f, id(f, "p2")), "changed")
	ix_frame(f)
	ix_check(t, f, .Full)
	f.set.incremental = true
	ix_frame(f)
	ix_check(t, f, .None)
	// many partial rebuilds: under the floor (layout.incremental.garbage_floor_bytes) nothing is collected...
	fulls := f.l.passes[.Full]
	for i in 0 ..< 200 {
		dom.set_text_content(f.doc, first_text_node(f, id(f, "p2")), fmt.tprintf("text %d", i))
		ix_frame(f)
	}
	ix_check(t, f, .None)
	testing.expect_value(t, f.l.passes[.Full], fulls)
	// ... past it, memory left behind is bounded by full passes
	f.set.inc_garbage_floor = 0
	ix_frame(f)   // (settings changed: a full pass)
	fulls = f.l.passes[.Full]
	for i in 0 ..< 200 {
		dom.set_text_content(f.doc, first_text_node(f, id(f, "p2")), fmt.tprintf("text %d", i))
		ix_frame(f)
	}
	ix_check(t, f, .None)
	testing.expect(t, f.l.passes[.Full] > fulls, "garbage made some full passes")
	testing.expect(t, f.l.passes[.Incremental] > 300, "most passes stay incremental")
	// verification mode agrees
	f.set.inc_verify = true
	run(&f.l, ix_input(f))
	dom.set_text_content(f.doc, first_text_node(f, id(f, "p2")), "verified")
	ix_frame(f)
	testing.expect(t, f.l.inc.verify_failures == 0, f.l.inc.verify_report)
}

// Random mutations on a generated document: after each one the incremental layout equals a full one.
@(test)
inc_random :: proc(t: ^testing.T) { inc_random_run(t, false) }

// The same with the layout threads on every pass (no minimum: every incremental pass lays paragraphs out ahead).
@(test)
inc_random_threads :: proc(t: ^testing.T) {
	defer shutdown_threads()
	inc_random_run(t, true)
}

@(private = "file")
inc_random_run :: proc(t: ^testing.T, threads: bool) {
	r := rand.create(20261019)
	gen := rand.default_random_generator(&r)
	context.random_generator = gen
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<style>body{margin:0;font-size:10px} .f{display:flex;flex-wrap:wrap;gap:3px} .f>*{flex:1 1 40px}
.fl{float:left;width:30px;height:20px} .ab{position:absolute;right:5px;width:40px} .rl{position:relative} li{margin-left:20px}
td{border:1px solid} .ib{display:inline-block;width:50px} .hid{display:none}</style><body>`)
	words := [?]string{"lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do"}
	for i in 0 ..< 12 {
		switch i % 6 {
		case 0: fmt.sbprintf(&sb, `<div class=rl><p>%s %s <b>%s</b> %s</p><div class=ab>abs</div></div>`, words[i % 10], words[(i + 3) % 10], words[(i + 5) % 10], words[(i + 7) % 10])
		case 1: fmt.sbprintf(&sb, `<div class=f><div>%s</div><div>%s %s</div><span>%s</span></div>`, words[i % 10], words[(i + 1) % 10], words[(i + 2) % 10], words[(i + 4) % 10])
		case 2: fmt.sbprintf(&sb, `<div><div class=fl></div><p>%s %s %s %s %s %s</p></div>`, words[0], words[1], words[2], words[3], words[4], words[5])
		case 3: fmt.sbprintf(&sb, `<table><tr><td>%s</td><td>%s</td></tr><tr><td colspan=2>%s</td></tr></table>`, words[i % 10], words[(i + 2) % 10], words[(i + 6) % 10])
		case 4: fmt.sbprintf(&sb, `<ul><li>%s<li>%s <span class=ib>%s</span></ul>`, words[i % 10], words[(i + 8) % 10], words[(i + 9) % 10])
		case 5: fmt.sbprintf(&sb, `<section><h4>%s</h4>text <em>%s</em> more<div>block in %s</div>tail</section>`, words[i % 10], words[(i + 2) % 10], words[(i + 3) % 10])
		}
	}
	strings.write_string(&sb, `</body>`)
	f := ix_load(strings.to_string(sb), 500, 400)
	defer ix_unload(f)
	ahead := 0
	if threads {
		f.threads = true
		f.set.threads, f.set.threads_min_contexts, f.set.threads_min_boxes = 3, 0, 0
		run(&f.l, ix_input(f))
	}

	all_elements :: proc(f: ^Ix) -> [dynamic]base.Handle {
		out := make([dynamic]base.Handle, context.temp_allocator)
		body := dom.find_first_by_tag(f.doc, "body")
		stack := make([dynamic]base.Handle, context.temp_allocator)
		append(&stack, body)
		for len(stack) > 0 {
			h := pop(&stack)
			n := dom.get(f.doc, h)
			if n.kind == .Element && h != body { append(&out, h) }
			for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(f.doc, ch).next { append(&stack, ch) }
		}
		return out
	}
	text_nodes :: proc(f: ^Ix) -> [dynamic]base.Handle {
		out := make([dynamic]base.Handle, context.temp_allocator)
		stack := make([dynamic]base.Handle, context.temp_allocator)
		append(&stack, f.doc.root)
		for len(stack) > 0 {
			h := pop(&stack)
			n := dom.get(f.doc, h)
			if n.kind == .Text && dom.get(f.doc, n.parent).name != "style" { append(&out, h) }
			for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(f.doc, ch).next { append(&stack, ch) }
		}
		return out
	}
	styles := [?]string{"", "width:120px", "font-size:14px", "display:none", "display:inline", "display:block", "float:right;width:40px",
		"position:absolute;left:3px", "position:relative;top:4px", "margin:6px", "padding:3px 9px", "display:flex", "overflow:hidden",
		"display:inline-block", "height:30px", "line-height:20px", "text-align:center", "white-space:nowrap", "display:table-cell"}
	tags := [?]string{"div", "span", "p", "b", "li", "img", "td", "section"}
	incremental := 0
	failures := 0
	for iter in 0 ..< 500 {
		els := all_elements(f)
		op := rand.int_max(10)
		what := ""
		switch op {
		case 0, 1:
			tn := text_nodes(f)
			if len(tn) == 0 { continue }
			h := tn[rand.int_max(len(tn))]
			n := rand.int_max(8)
			parts := make([dynamic]string, context.temp_allocator)
			for _ in 0 ..< n { append(&parts, words[rand.int_max(len(words))]) }
			dom.set_text_content(f.doc, h, strings.join(parts[:], " ", context.temp_allocator))
			what = "text"
		case 2, 3:
			if len(els) == 0 { continue }
			p := els[rand.int_max(len(els))]
			if dom.get(f.doc, p).name == "img" { continue }
			e := add_el(f, p, tags[rand.int_max(len(tags))], styles[rand.int_max(len(styles))], words[rand.int_max(len(words))])
			if dom.get(f.doc, e).name == "img" { f.sizes[e] = {f32(10 + rand.int_max(40)), f32(10 + rand.int_max(30))} }
			what = "insert"
		case 4:
			if len(els) < 10 { continue }
			h := els[rand.int_max(len(els))]
			dom.remove_child(f.doc, dom.get(f.doc, h).parent, h)
			dom.release(f.doc, h)
			what = "remove"
		case 5, 6:
			if len(els) == 0 { continue }
			h := els[rand.int_max(len(els))]
			s := styles[rand.int_max(len(styles))]
			dom.set_attribute(f.doc, h, "style", s)
			what = fmt.tprintf("style %s", s)
		case 7:
			f.vp.x = f32(200 + rand.int_max(500))
			if rand.int_max(3) == 0 { f.vp.y = f32(200 + rand.int_max(400)) }
			what = "viewport"
		case 8:
			for h, _ in f.sizes { f.sizes[h] = {f32(5 + rand.int_max(80)), f32(5 + rand.int_max(60))}; break }
			f.images_gen += 1
			what = "image"
		case 9:
			if len(els) == 0 { continue }
			h := els[rand.int_max(len(els))]
			dom.set_attribute(f.doc, h, rand.int_max(2) == 0 ? "class" : "colspan", rand.int_max(2) == 0 ? "f" : "2")
			what = "attribute"
		}
		ix_frame(f)
		if f.l.last_pass == .Incremental { incremental += 1; ahead += f.l.pre_counts[1] }
		if !ix_check(t, f, .None) {
			fmt.println("iteration", iter, what)
			failures += 1
			if failures > 3 { break }
		}
		free_all(context.temp_allocator)
	}
	testing.expectf(t, incremental > 250, "%d of 500 passes incremental", incremental)
	testing.expectf(t, f.partial_styles > 150, "%d partial restyles", f.partial_styles)
	if threads { testing.expectf(t, ahead > 0, "no paragraph laid out ahead was taken by an incremental pass") }
}

// Style and layout both incremental: classes toggled on elements of a page whose rules reach descendants and
// siblings. Every pass is compared with full ones (styles: style.verify_styles; layout: compare_layouts); the style
// records of the layout are re-pointed from the style journal only.
@(test)
inc_restyle_classes :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<style>body{margin:0;font-size:10px;line-height:12px} .sec{margin:4px;padding:2px}
.hl{background:#ff0} .hl p{color:red} .wide p{padding-left:20px} .big{font-size:16px} .gone .x{display:none}
.on + .sec{border-top:3px solid} .row{display:flex} .row > .on{flex:2} li:first-child{font-weight:bold}</style><body>`)
	for i in 0 ..< 80 {
		fmt.sbprintf(&sb, `<div class=sec id=s%d><p>para %d with words</p><p class=x>hidden %d</p><div class=row><span>a</span><span id=r%d>b</span></div><ul><li>one<li>two</ul></div>`, i, i, i, i)
	}
	strings.write_string(&sb, `</body>`)
	f := ix_load(strings.to_string(sb))
	defer ix_unload(f)
	ix_frame(f)
	ix_check(t, f, .None)
	r := rand.create(7)
	context.random_generator = rand.default_random_generator(&r)
	classes := [?]string{"hl", "wide", "big", "gone", "on", ""}
	before := f.partial_styles
	for step in 0 ..< 60 {
		k := rand.int_max(80)
		target := dom.find_by_id(f.doc, fmt.tprintf(rand.int_max(3) == 0 ? "r%d" : "s%d", k))
		cls := classes[rand.int_max(len(classes))]
		dom.set_attribute(f.doc, target, "class", strings.concatenate({"sec ", cls}, context.temp_allocator))
		if step % 7 == 0 {
			// a list item inserted first: :first-child moves
			ul := dom.get(f.doc, dom.get(f.doc, target).parent)
			_ = ul
			if lst := dom.find_first_by_tag(f.doc, "ul"); lst != base.NIL_HANDLE {
				add_el(f, lst, "li", "", "new", dom.get(f.doc, lst).first_child)
			}
		}
		ix_frame(f)
		testing.expect_value(t, style.verify_styles(f.eng, f.doc, f.st, context.temp_allocator), "")
		if !ix_check(t, f, .None) { fmt.println("step", step, cls); break }
		free_all(context.temp_allocator)
	}
	testing.expectf(t, f.partial_styles - before >= 55, "%d of 60 restyles partial", f.partial_styles - before)
	testing.expect(t, f.l.passes[.Incremental] > 40)
}

// Shadow trees: boxes follow the flat tree (slotted nodes where their slot is), and changes inside shadow trees, slot
// assignments and attachShadow keep the incremental layout equal to a full one.
@(test)
inc_shadow_trees :: proc(t: ^testing.T) {
	f := ix_load(`<!doctype html><body><div id=host><template shadowrootmode=open><style>.big { height: 50px }</style>
		<header id=hd style="height: 20px">head</header><slot name=a></slot><div id=mid style="height: 10px">mid</div><slot></slot></template>
		<p id=pa slot=a>slotted a</p><p id=pd>default</p><p id=pu slot=nowhere>unassigned</p></div><p id=after>after</p></body>`)
	defer ix_unload(f)
	f.set.inc_max_ratio = 1   // a small document: any change is a large part of it
	ix_frame(f)
	sid :: proc(f: ^Ix, id: string) -> base.Handle {
		for h := f.doc.root; h != base.NIL_HANDLE; h = dom.next_shadow_including(f.doc, h, f.doc.root) {
			if v, ok := dom.get_attribute(f.doc, h, "id"); ok && v == id { return h }
		}
		return base.NIL_HANDLE
	}
	y_of :: proc(f: ^Ix, id: string) -> f32 {
		bi := box_index(&f.l, sid(f, id))
		if bi == NONE { return -1 }
		return f.l.boxes[bi].pos.y
	}
	// order on screen: header, slotted a, mid, default; the unassigned one has no box
	testing.expect(t, y_of(f, "hd") < y_of(f, "pa") && y_of(f, "pa") < y_of(f, "mid") && y_of(f, "mid") < y_of(f, "pd"))
	testing.expect_value(t, box_index(&f.l, sid(f, "pu")), NONE)
	ix_check(t, f, .None)

	mid := sid(f, "mid")
	dom.set_attribute(f.doc, mid, "class", "big")
	ix_frame(f)
	ix_check(t, f)
	dom.set_text_content(f.doc, sid(f, "hd"), "a longer heading")
	ix_frame(f)
	ix_check(t, f)
	// reassignment: pu to the default slot, pa away
	dom.remove_attribute(f.doc, sid(f, "pu"), "slot")
	ix_frame(f)
	ix_check(t, f)
	testing.expect(t, box_index(&f.l, sid(f, "pu")) != NONE)
	dom.set_attribute(f.doc, sid(f, "pa"), "slot", "zzz")
	ix_frame(f)
	ix_check(t, f)
	testing.expect_value(t, box_index(&f.l, sid(f, "pa")), NONE)
	// insertions into the host and into the shadow root
	host := sid(f, "host")
	np := dom.create_element(f.doc, "p")
	dom.append_child(f.doc, np, dom.create_text(f.doc, "new light"))
	dom.append_child(f.doc, host, np)
	ix_frame(f)
	ix_check(t, f)
	root := dom.shadow_root_of(f.doc, host)
	nd := dom.create_element(f.doc, "div")
	dom.append_child(f.doc, nd, dom.create_text(f.doc, "new shadow"))
	dom.insert_before(f.doc, root, nd, dom.get(f.doc, root).first_child)
	ix_frame(f)
	ix_check(t, f)
	// attachShadow on a rendered element hides its children
	after := sid(f, "after")
	r2, _ := dom.attach_shadow(f.doc, after, {mode = .Open})
	_ = r2
	ix_frame(f)
	ix_check(t, f, .None)
	testing.expect(t, f.l.inc.fallback == "" || f.l.last_pass == .Incremental || f.l.last_pass == .Full)
	sp := dom.create_element(f.doc, "span")
	dom.append_child(f.doc, sp, dom.create_text(f.doc, "shadow text"))
	dom.append_child(f.doc, r2, sp)
	ix_frame(f)
	ix_check(t, f, .None)
	testing.expect(t, box_index(&f.l, sp) != NONE)
}

// Partial restyles give restyled elements new font-family lists: the partial passes that follow find the fonts they
// already made by content instead of adding one per restyled element (which made the table grow until
// layout.incremental.garbage_ratio forced a full pass every few hundred milliseconds on an animated page).
@(test)
inc_fonts_reused_across_partial_restyles :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<style>.on { color: red } .c { font-family: "web", serif; padding: 2px }</style><div id=root>`)
	for i in 0 ..< 200 { fmt.sbprintf(&sb, `<p class=c id=p%d>card <em>item %d</em></p>`, i, i) }
	strings.write_string(&sb, `</div>`)
	f := ix_load(strings.to_string(sb))
	defer ix_unload(f)
	fonts := len(f.l.fonts)
	for frame in 0 ..< 30 {
		for k := frame % 10; k < 200; k += 100 {
			h := dom.find_by_id(f.doc, fmt.tprintf("p%d", k))
			dom.set_attribute(f.doc, h, "class", frame % 20 < 10 ? "c on" : "c")
			// and its text: its content is made again with the new style
			em := dom.get(f.doc, h).last_child
			_ = dom.set_text_content(f.doc, em, fmt.tprintf("item %d", frame))
		}
		ix_frame(f)
		if !ix_check(t, f) { return }
	}
	testing.expectf(t, len(f.l.fonts) == fonts, "fonts after 30 partial passes: %d, after the full one: %d", len(f.l.fonts), fonts)
	testing.expect_value(t, f.l.passes[.Full], 1)
}