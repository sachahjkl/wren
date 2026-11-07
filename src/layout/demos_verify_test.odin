package layout

import "core:fmt"
import "core:hash"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"
import "wb:style"

// The demo pages (examples/site/*.html, without their scripts) under random mutations, as the page drives styles and
// layout every frame (page.styles): partial restyles after DOM changes and :hover moves, then an incremental layout.
// After each step both are compared with full passes (style.verify_styles, the layout's own verification:
// layout.incremental.verify), which is what `--pref style.incremental.verify=true --pref layout.incremental.verify=true`
// does in the browser. Linked sheets found next to the page are loaded too.

// Enough boxes around a reduced case for what it changes to stay a small part of the document (inc_max_ratio: "too much changed").
@(private = "file")
FILLER_BLOCKS :: `<p>a</p><p>b</p><p>c</p><p>d</p><p>e</p><p>f</p><p>g</p><p>h</p><p>i</p><p>j</p><p>k</p><p>l</p><p>m</p><p>n</p><p>o</p><p>p</p>`

@(private = "file")
Demo :: struct {
	doc:    ^dom.Document,
	eng:    ^style.Engine,
	st:     ^style.Styled,
	tl:     ^style.Timeline,
	state:  style.State,
	set:    Settings,
	l:      Layout,
	vp:     Vec2,
	now:    f64,
	sizes:  map[base.Handle][2]f32,
	images_gen: u64,
	partial: int,
}

@(private = "file")
demo_input :: proc(d: ^Demo) -> Input {
	return Input{doc = d.doc, styled = d.st, settings = &d.set,
		text = Text_Api{
			font = proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font { return Font(1 + int(weight >= 600)) },
			width = proc(user: rawptr, f: Font, size: f32, text: string) -> f32 { return (f == 2 ? 0.55 : 0.5) * size * f32(rune_count(text)) },
			metrics = proc(user: rawptr, f: Font, size: f32) -> Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} },
		},
		replaced = Replaced_Api{user = d, intrinsic = proc(user: rawptr, node: base.Handle) -> (w, h: f32, ok: bool) {
			s, found := (^Demo)(user).sizes[node]
			return s.x, s.y, found
		}},
		viewport = d.vp, scale = 1.25, band_h = 128, images_generation = d.images_gen}
}

@(private = "file")
demo_sheets :: proc(d: ^Demo, dir: string) {
	links := style.sync_document_sheets(d.eng, d.doc, "about:test")
	for l in links {
		have := false
		for s in d.eng.sheets { if s.from_link && s.owner == l.owner { have = true; break } }
		if have || strings.contains(l.href, ":") || strings.has_prefix(l.href, "/") { continue }
		path, _ := filepath.join({dir, l.href}, context.temp_allocator)
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil { continue }
		style.engine_add_sheet(d.eng, string(data), l.owner, l.media, "about:test", from_link = true, scope = l.scope)
	}
}

// One frame: the environment, styles (partial when it can be), the timeline, layout (verified).
@(private = "file")
demo_frame :: proc(d: ^Demo, dir: string) -> (style_diff: string) {
	d.now += 16
	env := style.media_env_from(&d.eng.settings, f64(d.vp.x / 1.25), f64(d.vp.y / 1.25), 1.25, false)
	style.engine_set_environment(d.eng, env)
	if d.st != nil && !d.eng.restyle_needed { _ = style.engine_extend(d.eng, d.doc, d.st) }
	full := d.st == nil || d.eng.dirty || d.eng.restyle_needed
	partial := false
	if !full && (d.st.mutations != d.doc.mutations || d.eng.shadow.dirty) {
		full = true
		if style.dom_touches_sheets(d.eng, d.doc, d.st, nil) {
			demo_sheets(d, dir)
			_ = style.engine_extend(d.eng, d.doc, d.st)
		}
		if !d.eng.dirty {
			if _, ok := style.restyle_dom(d.eng, d.doc, d.st); ok { full, partial = false, true }
		}
	}
	if !full && !style.state_equal(d.state, d.st.state) {
		if _, ok := style.restyle_state(d.eng, d.doc, d.st, d.state); !ok { full = true } else { partial = true }
	}
	if !full && d.eng.gates_pending {   // a media query changed value: the elements its rules reach (style/media_gate.odin)
		if _, ok := style.restyle_media(d.eng, d.doc, d.st); !ok { full = true } else { partial = true }
	}
	if !full && d.eng.arrivals_due {   // sheets that came or went: the elements their rules reach (style/sheet_arrival.odin)
		if _, ok := style.restyle_arrivals(d.eng, d.doc, d.st); !ok { full = true } else { partial = true }
	}
	if !full && style.engine_departures_due(d.eng) {
		if _, ok := style.restyle_departures(d.eng, d.doc, d.st); !ok { full = true } else { partial = true }
	}
	if full {
		demo_sheets(d, dir)
		old := d.st
		d.st = style.compute_styles(d.eng, d.doc, d.state)
		style.journal_diff(old, d.st)
		style.timeline_restyled(d.tl, d.doc, old, d.st, d.now)
		if old != nil { style.styled_destroy(old) }
		d.eng.restyle_needed = false
		if !d.doc.journal.on { dom.journal_enable(d.doc, d.eng.settings.inc_journal) }
	} else if partial {
		d.partial += 1
		style.timeline_restyled_dom(d.tl, d.doc, d.st, d.now)
		style_diff = style.verify_styles(d.eng, d.doc, d.st, context.temp_allocator)
	}
	style.timeline_tick(d.tl, d.doc, d.st, d.now)
	run(&d.l, demo_input(d))
	return
}

@(test)
inc_demo_pages :: proc(t: ^testing.T) {
	dir := "examples/site"
	fis, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil { return }   // not run from the repository root
	defer os.file_info_slice_delete(fis, context.allocator)
	// WREN_DEMOS_SEED / WREN_DEMOS_STEPS: other random sequences, longer ones (to look for divergences; the default is
	// what the suite runs)
	seed := u64(20261020)
	if s := os.get_env("WREN_DEMOS_SEED", context.temp_allocator); s != "" { seed = u64(parse_int(s, 0)) }
	steps := 60
	if s := os.get_env("WREN_DEMOS_STEPS", context.temp_allocator); s != "" { steps = max(parse_int(s, 60), 1) }
	r := rand.create(seed)
	context.random_generator = rand.default_random_generator(&r)
	pages := 0
	// WREN_DEMOS_TRACE=<page name prefix>: each step of those pages is printed, and the document before it written to
	// build\demos_<page>_<step>.html (a failing sequence can then be replayed and reduced from a document)
	trace := os.get_env("WREN_DEMOS_TRACE", context.allocator)
	defer delete(trace)
	for fi in fis {
		if !strings.has_suffix(fi.name, ".html") || fi.name == "index.html" { continue }
		src, rerr := os.read_entire_file(fi.fullpath, context.allocator)
		if rerr != nil { continue }
		defer delete(src)
		pages += 1
		// one sequence per page, from the seed and the page's name: a demo page added to examples/site must not change what
		// the pages after it are asked to do. (With one sequence for all pages, adding the fullscreen demo re-rolled layout.html's
		// and once surfaced a divergence on an inline box with overflow set, `<span class="scroll">`: a full pass seeded its
		// scrollable overflow to its padding box while an incremental pass left it empty, though an inline box never becomes
		// a scroll container and that value is never read (verify_layout "overflow Rect{0} / Rect{...}"). finish.odin now
		// leaves an inline box's overflow empty in both paths. WREN_DEMOS_SEED=<n> tries other sequences.)
		r = rand.create(seed ~ hash.fnv64a(transmute([]byte)fi.name))
		d := new(Demo)
		d.doc = dom.document_create(nil)
		html.parse_into(d.doc, d.doc.root, src, 2_000_000)
		ss := style.settings_default()
		d.eng = style.engine_make(ss)
		style.settings_destroy(&ss)
		style.engine_set_journal(d.eng, 1 << 16)
		d.tl = style.timeline_make(d.eng)
		d.set = settings_default()
		d.set.inc_verify = true
		d.vp = {1000, 700}
		d.sizes = make(map[base.Handle][2]f32)
		// images decode: natural sizes for every <img>
		for h := d.doc.root; h != base.NIL_HANDLE; h = dom.next_shadow_including(d.doc, h, d.doc.root) {
			if n := dom.get(d.doc, h); n.kind == .Element && n.name == "img" { d.sizes[h] = {f32(16 + rand.int_max(200)), f32(16 + rand.int_max(120))} }
		}
		demo_frame(d, dir)

		elements :: proc(d: ^Demo) -> [dynamic]base.Handle {
			out := make([dynamic]base.Handle, context.temp_allocator)
			for h := d.doc.root; h != base.NIL_HANDLE; h = dom.next_shadow_including(d.doc, h, d.doc.root) {
				n := dom.get(d.doc, h)
				if n.kind != .Element { continue }
				switch n.name {
				case "html", "head", "body", "style", "link", "script", "meta", "title", "template": continue
				}
				append(&out, h)
			}
			return out
		}
		// the class tokens of the page: toggling them reaches what its rules say
		classes := make([dynamic]string)
		defer { for c in classes { delete(c) }; delete(classes) }
		for h in elements(d) {
			if c, ok := dom.get_attribute(d.doc, h, "class"); ok {
				for tok in strings.fields(c, context.temp_allocator) { append(&classes, strings.clone(tok)) }
			}
		}
		append(&classes, strings.clone(""))
		styles := [?]string{"", "display:none", "width:40%", "font-size:22px", "padding:7px 3px", "position:relative;top:3px",
			"float:left;width:90px", "display:inline-block", "display:flex", "display:grid;grid-template-columns:1fr 2fr",
			"overflow:hidden;height:40px", "margin-top:-12px", "opacity:0.5", "transform:rotate(3deg)", "position:absolute;left:5px"}
		words := [?]string{"lorem", "ipsum", "dolor", "sit", "amet", "longerwordwithoutbreaks", "x"}
		failures := 0
		for iter in 0 ..< steps {
			els := elements(d)
			if len(els) == 0 { break }
			h := els[rand.int_max(len(els))]
			what := ""
			switch rand.int_max(8) {
			case 0:
				c := classes[rand.int_max(len(classes))]
				dom.set_attribute(d.doc, h, "class", c)
				what = fmt.tprintf("class=%q", c)
			case 1:
				s := styles[rand.int_max(len(styles))]
				dom.set_attribute(d.doc, h, "style", s)
				what = fmt.tprintf("style=%q", s)
			case 2:
				// text of an element without element children
				n := dom.get(d.doc, h)
				if n.first_child != base.NIL_HANDLE && dom.get(d.doc, n.first_child).kind == .Element { continue }
				dom.set_text_content(d.doc, h, strings.join({words[rand.int_max(len(words))], words[rand.int_max(len(words))]}, " ", context.temp_allocator))
				what = "text"
			case 3:
				e := dom.create_element(d.doc, rand.int_max(2) == 0 ? "div" : "span")
				dom.append_child(d.doc, e, dom.create_text(d.doc, words[rand.int_max(len(words))]))
				if c := classes[rand.int_max(len(classes))]; c != "" { dom.set_attribute(d.doc, e, "class", c) }
				dom.insert_before(d.doc, dom.get(d.doc, h).parent, e, h)
				what = "insert"
			case 4:
				if len(els) < 8 { continue }
				dom.remove_child(d.doc, dom.get(d.doc, h).parent, h)
				what = "remove"
			case 5:
				d.vp.x = f32(320 + rand.int_max(1200))
				what = "viewport"
			case 6:
				d.state.hover = h
				what = "hover"
			case 7:
				d.state.focus = h
				d.state.active = rand.int_max(2) == 0 ? h : base.NIL_HANDLE
				what = "focus"
			}
			{
				n := dom.get(d.doc, h)
				hid, _ := dom.get_attribute(d.doc, h, "id")
				hcl, _ := dom.get_attribute(d.doc, h, "class")
				what = fmt.tprintf("%s on <%s id=%q class=%q>", what, n != nil ? n.name : "?", hid, hcl)
			}
			if trace != "" && strings.has_prefix(fi.name, trace) {
				sb := strings.builder_make(context.temp_allocator)
				dump_html(d.doc, d.doc.root, &sb)
				_ = os.write_entire_file(fmt.tprintf("build/demos_%s_%d.html", fi.name, iter), transmute([]byte)strings.to_string(sb))
			}
			diff := demo_frame(d, dir)
			if trace != "" && strings.has_prefix(fi.name, trace) { fmt.println("step", iter, what, d.vp, d.l.last_pass, d.l.inc.fallback) }
			testing.expectf(t, diff == "", "%s step %d (%s): styles: %s", fi.name, iter, what, diff)
			lok := d.l.inc.verify_failures == 0
			testing.expectf(t, lok, "%s step %d (%s): layout: %s", fi.name, iter, what, d.l.inc.verify_report)
			if diff != "" || !lok {
				failures += 1
				if failures >= 2 { break }
				d.l.inc.verify_failures = 0
			}
			free_all(context.temp_allocator)
		}
		destroy(&d.l)
		style.timeline_destroy(d.tl, d.st)
		style.styled_destroy(d.st)
		style.engine_destroy(d.eng)
		dom.document_destroy(d.doc)
		delete(d.sizes)
		free(d)
		free_all(context.temp_allocator)
	}
	testing.expectf(t, pages >= 20, "%d demo pages", pages)
}

@(private = "file")
demo_load :: proc(src: string, dir := "examples/site") -> ^Demo {
	d := new(Demo)
	d.doc = dom.document_create(nil)
	html.parse_into(d.doc, d.doc.root, transmute([]byte)src, 2_000_000)
	ss := style.settings_default()
	d.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.engine_set_journal(d.eng, 1 << 16)
	d.tl = style.timeline_make(d.eng)
	d.set = settings_default()
	d.set.inc_verify = true
	d.vp = {1000, 700}
	d.sizes = make(map[base.Handle][2]f32)
	demo_frame(d, dir)
	return d
}

@(private = "file")
demo_unload :: proc(d: ^Demo) {
	destroy(&d.l)
	style.timeline_destroy(d.tl, d.st)
	style.styled_destroy(d.st)
	style.engine_destroy(d.eng)
	dom.document_destroy(d.doc)
	delete(d.sizes)
	free(d)
}

// A paint-only restyle (refresh pass) re-points the items of an unchanged element's ::before to the ::before's record,
// not to the element's (the next incremental pass then kept the element's record on the generated text).
@(test)
inc_refresh_keeps_pseudo_records :: proc(t: ^testing.T) {
	d := demo_load(`<style>.card:hover { background: #fe0 } .note::before { content: "Note: "; font-weight: bold }</style>
<div class=card><h2 id=h>Title</h2><p class=note>Generated text.</p></div><p>after <code id=c>code</code></p>`)
	defer demo_unload(d)
	d.state.hover = dom.find_by_id(d.doc, "h")
	demo_frame(d, "")
	testing.expect_value(t, d.l.last_pass, Pass_Kind.Refresh)
	c := dom.find_by_id(d.doc, "c")
	dom.remove_child(d.doc, dom.get(d.doc, c).parent, c)
	demo_frame(d, "")
	testing.expect(t, d.l.inc.verify_failures == 0, d.l.inc.verify_report)
}
// An element removed that had no box of its own but made inline content (<br>, the children of display: contents, a
// <slot>'s assigned nodes): its container's content is made again (the plan saw no box before or after, and the
// paragraph kept its line break).
@(test)
inc_removed_element_without_box :: proc(t: ^testing.T) {
	srcs := []string{`<div><p>one<br>two<br id=x>three</p></div><p>after</p>`, `<p>one<br id=x>two</p>`,
		`<p>a <span id=x style="display:contents"><b>bold</b> <i>it</i></span> z</p><p>after</p>`,
		`<div id=h><template shadowrootmode=open><p>before</p><slot id=x></slot><p>after</p></template><span>slotted</span></div>`}
	for s in srcs {
		d := demo_load(s)
		defer demo_unload(d)
		x := dom.find_by_id(d.doc, "x")
		if x == base.NIL_HANDLE {
			for h := d.doc.root; h != base.NIL_HANDLE; h = dom.next_shadow_including(d.doc, h, d.doc.root) {
				if v, ok := dom.get_attribute(d.doc, h, "id"); ok && v == "x" { x = h }
			}
		}
		dom.remove_child(d.doc, dom.get(d.doc, x).parent, x)
		demo_frame(d, "")
		testing.expectf(t, d.l.inc.verify_failures == 0, "%s: %s", s, d.l.inc.verify_report)
		testing.expectf(t, d.l.last_pass == .Incremental || d.l.inc.fallback == "too much changed", "%s: %v (%s)", s, d.l.last_pass, d.l.inc.fallback)
	}
}
// The document as markup (shadow roots as declarative templates), for WREN_DEMOS_TRACE.
@(private = "file")
dump_html :: proc(d: ^dom.Document, h: base.Handle, sb: ^strings.Builder) {
	n := dom.get(d, h)
	switch n.kind {
	case .Text: strings.write_string(sb, n.text)
	case .Element:
		fmt.sbprintf(sb, "<%s", n.name)
		for a in n.attrs { fmt.sbprintf(sb, " %s=\"%s\"", a.name, a.value) }
		strings.write_string(sb, ">")
		if n.shadow != base.NIL_HANDLE {
			strings.write_string(sb, "<template shadowrootmode=open>")
			for ch := dom.get(d, n.shadow).first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next { dump_html(d, ch, sb) }
			strings.write_string(sb, "</template>")
		}
		for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next { dump_html(d, ch, sb) }
		fmt.sbprintf(sb, "</%s>", n.name)
	case .Document, .Fragment:
		strings.write_string(sb, "<!doctype html>")
		for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next { dump_html(d, ch, sb) }
	case .Comment, .Doctype:
	}
}
// A subgrid laid out again at the same size after its parent's track sizing measured its items (through their proxies)
// at their natural size: it is not taken from the layout cache, its items are stretched to their rows again.
@(test)
inc_subgrid_resize :: proc(t: ^testing.T) {
	d := demo_load(`<style>.inner { display: grid; grid-template-columns: repeat(3, auto); justify-content: space-between } .inner i { padding: 2px 6px }
.card { display: grid; grid-row: span 3; grid-template-rows: subgrid }</style><div class="inner"><i class="card">delta</i><i>zeta</i></div>`)
	defer demo_unload(d)
	for w in ([]f32{1108, 700, 900}) {
		d.vp = {w, 700}
		demo_frame(d, "")
		testing.expectf(t, d.l.inc.verify_failures == 0, "%v: %s", w, d.l.inc.verify_report)
		testing.expect_value(t, d.l.last_pass, Pass_Kind.Incremental)
	}
}
// The color of a text decoration is the decorating box's current one: a paint-only restyle (hover) followed by a pass
// that makes the display list again from the same inline items paints the new color (the items kept the old one).
@(test)
inc_decoration_color_follows_restyles :: proc(t: ^testing.T) {
	d := demo_load(`<style>u:hover { color: red } u { color: blue }</style><p><u id=u>underlined</u> text</p><div id=d>below</div>`)
	defer demo_unload(d)
	d.state.hover = dom.find_by_id(d.doc, "u")
	demo_frame(d, "")
	dom.set_attribute(d.doc, dom.find_by_id(d.doc, "d"), "style", "padding:7px")
	demo_frame(d, "")
	testing.expect(t, d.l.inc.verify_failures == 0, d.l.inc.verify_report)
	red := false
	for &it in d.l.items { if it.kind == .Text && it.deco != {} { c := d.l.boxes[it.deco_box].cs.text_decoration_color; red = c.r > 0.9 && c.b < 0.1 } }
	testing.expect(t, red, "the underline is red")
}
// A grid item in fixed tracks is not laid out by the track sizing: one whose content changed is laid out when placed
// (it kept its old layout, its text never laid out and the grid's baseline stale).
@(test)
inc_grid_item_in_fixed_tracks :: proc(t: ^testing.T) {
	d := demo_load(`<div style="display:grid;grid-template-columns:60px 60px;grid-template-rows:30px 30px"><span id=s></span><span></span></div><p>after</p>`)
	defer demo_unload(d)
	dom.set_text_content(d.doc, dom.find_by_id(d.doc, "s"), "lorem ipsum")
	demo_frame(d, "")
	testing.expect(t, d.l.inc.verify_failures == 0, d.l.inc.verify_report)
	testing.expect_value(t, d.l.last_pass, Pass_Kind.Incremental)
}

// An element without a box whose style hides it (a <br> made display: none, a slot) takes away what it made in its
// container.
@(test)
inc_boxless_element_hidden :: proc(t: ^testing.T) {
	for s in ([]string{`<p>one<br id=x>two</p><p>after</p>`, `<p>a <span id=x style="display:contents"><b>bold</b></span> z</p><p>after</p>`,
		// (a <br> in the anonymous block beside a block child, then beside one in an inline-block, inside its context's items)
		`<div>one<br id=x>two<p>block</p></div>`, `<p>a <span style="display:inline-block">b<br id=x>c<div>block</div></span> z</p>`}) {
		d := demo_load(s)
		defer demo_unload(d)
		dom.set_attribute(d.doc, dom.find_by_id(d.doc, "x"), "style", "display:none")
		demo_frame(d, "")
		testing.expectf(t, d.l.inc.verify_failures == 0, "%s: %s", s, d.l.inc.verify_report)
	}
}
// A block inserted first among the children of a container with a ::before goes after what that generated: its box was placed
// first, before the anonymous block of the ::before.
@(test)
inc_child_inserted_after_generated_content :: proc(t: ^testing.T) {
	d := demo_load(`<style>.n::before { content: "Note: " }</style><ol class=n><li id=a>one</li></ol>` + FILLER_BLOCKS)
	defer demo_unload(d)
	a := dom.find_by_id(d.doc, "a")
	e := dom.create_element(d.doc, "div")
	dom.insert_before(d.doc, dom.get(d.doc, a).parent, e, a)
	demo_frame(d, "")
	testing.expect(t, d.l.inc.verify_failures == 0, d.l.inc.verify_report)
	testing.expect_value(t, d.l.last_pass, Pass_Kind.Incremental)
}
// A transform promised by an animation is a transform: nothing on an inline box. Its element's record has one already and the
// animation crosses no threshold of the style's, so a stacking context of the full pass alone was left to differ.
@(test)
inc_transform_animation_on_an_inline_box :: proc(t: ^testing.T) {
	d := demo_load(`<style>@keyframes spin { to { transform: rotate(360deg) } } .c { animation: spin 4s linear infinite }</style><p><span id=s style="transform:rotate(3deg)">text</span></p><p>after</p>`)
	defer demo_unload(d)
	s := dom.find_by_id(d.doc, "s")
	dom.set_attribute(d.doc, s, "class", "c")
	demo_frame(d, "")
	testing.expect(t, d.l.inc.verify_failures == 0, d.l.inc.verify_report)
	testing.expect(t, .Stacking not_in d.l.boxes[box_index(&d.l, s)].flags, "an inline box is not transformed")
}
// An element that made its content without a box of its own and gets a box: what its content made in its container goes (the plan
// of one child left the old boxes beside the new one).
@(test)
inc_element_without_box_gets_one :: proc(t: ^testing.T) {
	srcs := []string{`<div><p>before</p><section id=x style="display:contents"><p>one</p><p>two</p></section></div>` + FILLER_BLOCKS,
		`<div id=h><template shadowrootmode=open><div><p>before</p><slot id=x></slot></div></template><p>one</p><p>two</p></div>` + FILLER_BLOCKS}
	for s in srcs {
		d := demo_load(s)
		defer demo_unload(d)
		x := base.NIL_HANDLE
		for h := d.doc.root; h != base.NIL_HANDLE; h = dom.next_shadow_including(d.doc, h, d.doc.root) {
			if v, ok := dom.get_attribute(d.doc, h, "id"); ok && v == "x" { x = h }
		}
		dom.set_attribute(d.doc, x, "style", "display:grid")
		demo_frame(d, "")
		testing.expectf(t, d.l.inc.verify_failures == 0, "%s: %s", s, d.l.inc.verify_report)
		testing.expect_value(t, d.l.last_pass, Pass_Kind.Incremental)
	}
}
// A box below clearance keeps the top margin of its first child inside; a float grown shorter leaves it no clearance, and that
// margin collapses through it: its cached height is not for that.
@(test)
inc_box_that_stops_clearing_a_float :: proc(t: ^testing.T) {
	d := demo_load(`<div id=f style="float:left;width:10px;height:100px"></div><div style="height:50px"></div><div style="clear:both"><p style="margin:20px 0 0">text</p></div>` + FILLER_BLOCKS)
	defer demo_unload(d)
	dom.set_attribute(d.doc, dom.find_by_id(d.doc, "f"), "style", "float:left;width:10px;height:10px")
	demo_frame(d, "")
	testing.expect(t, d.l.inc.verify_failures == 0, d.l.inc.verify_report)
	testing.expect_value(t, d.l.last_pass, Pass_Kind.Incremental)
}
// A <style> that goes with its parent: a frame does what the page does (page.styles), the elements of its rules restyled.
@(test)
inc_style_element_removed_with_its_parent :: proc(t: ^testing.T) {
	d := demo_load(`<div id=d><style>.x { fill: rgb(255, 128, 0) }</style></div><p class=x>text</p>`)
	defer demo_unload(d)
	dom.set_text_content(d.doc, dom.find_by_id(d.doc, "d"), "gone")
	testing.expect_value(t, demo_frame(d, ""), "")
	testing.expect(t, d.l.inc.verify_failures == 0, d.l.inc.verify_report)
}
// An empty inline box on a line of its own in one layout and past the end of the last line in the next has no fragment there: it
// keeps no position of the layout before.
@(test)
inc_empty_inline_box_that_loses_its_fragment :: proc(t: ^testing.T) {
	d := demo_load(`<div id=d style="width:40px">aaa bbb <span id=s></span></div>` + FILLER_BLOCKS)
	defer demo_unload(d)
	s := box_index(&d.l, dom.find_by_id(d.doc, "s"))
	testing.expect(t, d.l.boxes[s].size.y > 0, "the box has a fragment on the second line")
	dom.set_attribute(d.doc, dom.find_by_id(d.doc, "d"), "style", "width:60px")
	demo_frame(d, "")
	testing.expect(t, d.l.inc.verify_failures == 0, d.l.inc.verify_report)
	testing.expect_value(t, d.l.last_pass, Pass_Kind.Incremental)
	testing.expect_value(t, d.l.boxes[s].size, Vec2{})
}
// Two empty blocks paint nothing: their places in the display list are the same. Text in the second, spliced in, then text in
// the first: its items go before the second's (its range moved with what followed the place, and they went after).
@(test)
inc_text_in_empty_neighbours :: proc(t: ^testing.T) {
	d := demo_load(`<div id=a style="height:40px"></div><div id=b style="height:40px"></div>` + FILLER_BLOCKS)
	defer demo_unload(d)
	for id in ([]string{"b", "a"}) {
		dom.set_text_content(d.doc, dom.find_by_id(d.doc, id), "text")
		demo_frame(d, "")
		testing.expectf(t, d.l.inc.verify_failures == 0, "%s: %s", id, d.l.inc.verify_report)
		testing.expect_value(t, d.l.last_pass, Pass_Kind.Incremental)
	}
}
// The root element is block-level whatever it says (CSS Display 3 §2.7), and over-constrained in the direction of the initial containing
// block, the principal one: wider than the viewport from right to left it overflows on the left, and the page scrolls there.
@(test)
root_element_wider_than_the_viewport_from_right_to_left :: proc(t: ^testing.T) {
	d := demo_load(`<!doctype html><html style="display:inline;direction:rtl;width:2000px;height:50px"><body></body></html>`)
	defer demo_unload(d)
	testing.expect_value(t, style.style_of(d.st, d.l.canvas_els[0]).display, style.Display.Block)
	testing.expect(t, d.l.doc_min_x < 0, "the page overflows on the left")
	_, _, bar := doc_scrollbar_x(&d.l, d.vp)
	testing.expect(t, bar, "with a horizontal bar")
}
// Text changed in an inline-block that stays where it is: its baseline moves what is on its line with it, and that takes more than a splice of its own text.
@(test)
inc_inline_block_with_another_baseline :: proc(t: ^testing.T) {
	d := demo_load(`<style>i { display: inline-block; width: 60px; height: 60px }</style><p style="overflow:hidden;height:40px"><i id=x>three short words</i> </p>` + FILLER_BLOCKS)
	defer demo_unload(d)
	dom.set_text_content(d.doc, dom.find_by_id(d.doc, "x"), "two words")
	demo_frame(d, "")
	testing.expect(t, d.l.inc.verify_failures == 0, d.l.inc.verify_report)
	testing.expect_value(t, d.l.last_pass, Pass_Kind.Incremental)
}
// The width of a <select> follows its options, a hidden one too: a change of its text reaches the box.
@(test)
inc_hidden_option_of_a_select :: proc(t: ^testing.T) {
	d := demo_load(`<p><select><option id=o style="display:none">one</option><option>two</option></select></p>` + FILLER_BLOCKS)
	defer demo_unload(d)
	dom.set_text_content(d.doc, dom.find_by_id(d.doc, "o"), "a much longer text")
	demo_frame(d, "")
	testing.expect(t, d.l.inc.verify_failures == 0, d.l.inc.verify_report)
	testing.expect_value(t, d.l.last_pass, Pass_Kind.Incremental)
}
// An orthogonal box whose frame has no block size takes its inline size from the viewport, under inputs from its frame that
// stay the same: a viewport that changes, in either axis, reaches it and the shrink-to-fit box around it.
@(test)
inc_orthogonal_box_follows_the_viewport :: proc(t: ^testing.T) {
	TEXT :: "a horizontal block in a vertical parent, long enough to be wrapped at every viewport"
	across := fmt.tprintf(`<div style="display:flex"><div style="writing-mode:vertical-rl;height:200px"><div id=o style="writing-mode:horizontal-tb">%s</div></div></div>`, TEXT)
	along := fmt.tprintf(`<div style="float:left"><div id=o style="writing-mode:vertical-rl">%s %s %s</div></div>`, TEXT, TEXT, TEXT)
	for c in ([]struct{src: string, a, b: Vec2}{{across, {423, 700}, {383, 700}}, {along, {1000, 500}, {1000, 300}}}) {
		d := demo_load(c.src)
		defer demo_unload(d)
		o := box_index(&d.l, dom.find_by_id(d.doc, "o"))
		sizes: [2]Vec2
		for vp, i in ([]Vec2{c.a, c.b}) {
			d.vp = vp
			incremental := d.l.passes[.Incremental]   // (the scroll bars that follow may end the frame with a full pass)
			demo_frame(d, "")
			testing.expectf(t, d.l.inc.verify_failures == 0, "%v: %s", vp, d.l.inc.verify_report)
			testing.expect(t, d.l.passes[.Incremental] > incremental, "an incremental pass was made")
			sizes[i] = d.l.boxes[o].size
		}
		testing.expectf(t, sizes[0] != sizes[1], "the box follows the viewport: %v", sizes)
	}
}
// The intrinsic size of an orthogonal box asked before its parent reached it: its padding counts in a first pass as in the
// passes after it, which found the padding of the pass before (an inline-block around it was narrower in a full pass).
@(test)
inc_orthogonal_box_padding_in_a_box_that_shrinks :: proc(t: ^testing.T) {
	d := demo_load(`<div id=o style="display:inline-block"><div id=v style="writing-mode:vertical-rl;padding:10px;height:200px">text</div></div>`)
	defer demo_unload(d)
	o, v := box_index(&d.l, dom.find_by_id(d.doc, "o")), box_index(&d.l, dom.find_by_id(d.doc, "v"))
	testing.expect_value(t, d.l.boxes[o].size.x, d.l.boxes[v].size.x)
	d.vp = {700, 700}
	demo_frame(d, "")
	testing.expect(t, d.l.inc.verify_failures == 0, d.l.inc.verify_report)
}
// A paint-only restyle gives an anonymous box its parent's new color, and with it what currentcolor is for it: a link
// made a flex container, whose text is in an anonymous flex item, left by the pointer (its border color stayed the hover's).
@(test)
inc_anonymous_box_current_color_after_refresh :: proc(t: ^testing.T) {
	d := demo_load(`<style>a { color: blue } a:hover { color: red }</style><a id=a href=x style="display:flex">link</a><p id=p>after</p>`)
	defer demo_unload(d)
	d.state.hover = dom.find_by_id(d.doc, "a")
	demo_frame(d, "")
	testing.expect_value(t, d.l.last_pass, Pass_Kind.Refresh)
	dom.set_attribute(d.doc, dom.find_by_id(d.doc, "p"), "style", "padding:7px")
	demo_frame(d, "")
	testing.expect_value(t, d.l.last_pass, Pass_Kind.Incremental)
	testing.expect(t, d.l.inc.verify_failures == 0, d.l.inc.verify_report)
}
// What says how a record came to be is not copied to an anonymous box: the parent's list of what it inherits, here another
// one under the pointer, and what its animations promise (the box would have made a stacking context of its own).
@(test)
inc_anonymous_box_keeps_nothing_of_its_parents_record :: proc(t: ^testing.T) {
	d := demo_load(`<style>div:hover { color: red }</style><div id=a style="display:flex">text</div><p id=p>after</p>`)
	defer demo_unload(d)
	d.state.hover = dom.find_by_id(d.doc, "a")
	demo_frame(d, "")
	testing.expect_value(t, d.l.last_pass, Pass_Kind.Refresh)
	dom.set_attribute(d.doc, dom.find_by_id(d.doc, "p"), "style", "padding:7px")
	demo_frame(d, "")
	testing.expect(t, d.l.inc.verify_failures == 0, d.l.inc.verify_report)
	e := demo_load(`<style>@keyframes spin { to { transform: rotate(360deg) } } .c { display: flex; animation: spin 4s linear infinite }</style><div class=c id=c>text</div>`)
	defer demo_unload(e)
	demo_frame(e, "")
	c := box_index(&e.l, dom.find_by_id(e.doc, "c"))
	testing.expect(t, e.l.boxes[c].cs.compositing != {}, "the animation promises a transform")
	testing.expect(t, e.l.boxes[e.l.boxes[c].first].cs.compositing == {}, "the anonymous flex item makes no such promise")
	f := demo_load(`<style>::highlight(found) { color: red }</style><div id=g style="display:grid">text</div>`)
	defer demo_unload(f)
	g := box_index(&f.l, dom.find_by_id(f.doc, "g"))
	testing.expect(t, len(f.l.boxes[g].cs.highlights) > 0, "the element's rules say what its highlights are")
	testing.expect(t, f.l.boxes[f.l.boxes[g].first].cs.highlights == nil, "the anonymous grid item's record has none of them")
}
// An animated element's record is an overlay, the same address from one style pass to the next: its anonymous flex item was
// not made again, and kept the inherited group of a pass that goes (an access violation in the verification, reading it).
@(test)
inc_anonymous_box_of_an_animated_parent_after_a_style_pass :: proc(t: ^testing.T) {
	d := demo_load(`<style>@keyframes spin { to { transform: rotate(360deg) } } .c { display: flex; animation: spin 4s linear infinite }</style><div class=c id=c>text</div><p>after</p>`)
	defer demo_unload(d)
	demo_frame(d, "")
	c := box_index(&d.l, dom.find_by_id(d.doc, "c"))
	overlay := d.l.boxes[c].cs
	d.eng.restyle_needed = true
	demo_frame(d, "")
	testing.expect_value(t, d.l.last_pass, Pass_Kind.Incremental)
	testing.expect(t, d.l.boxes[c].cs == overlay, "the overlay's record stays where it is")
	testing.expect(t, d.l.inc.verify_failures == 0, d.l.inc.verify_report)
	first := d.l.boxes[c].first
	testing.expect(t, .Anonymous in d.l.boxes[first].flags, "the text is in an anonymous flex item")
	testing.expect(t, d.l.boxes[first].cs.inherited_group == d.l.boxes[c].cs.inherited_group, "the inherited group of this pass")
}
// A paint-only restyle of an element whose ::before sits in an anonymous block beside block children: that generated
// box is re-pointed to the new ::before record too (it kept the old one, and its old color).
@(test)
inc_pseudo_in_anonymous_block_restyled :: proc(t: ^testing.T) {
	d := demo_load(`<style>li::before { content: "- " } .hot { color: red }</style><ul><li id=a>two<ol><li>nested</li></ol></li><li>three</li></ul><p>after</p>`)
	defer demo_unload(d)
	dom.set_attribute(d.doc, dom.find_by_id(d.doc, "a"), "class", "hot")
	demo_frame(d, "")
	dom.set_attribute(d.doc, dom.find_by_id(d.doc, "a"), "style", "padding-top:3px")
	demo_frame(d, "")
	testing.expect(t, d.l.inc.verify_failures == 0, d.l.inc.verify_report)
}
