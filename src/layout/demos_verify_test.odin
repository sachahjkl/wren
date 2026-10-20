package layout

import "core:fmt"
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
	full := d.st == nil || d.eng.dirty || d.eng.restyle_needed
	partial := false
	if !full && (d.st.mutations != d.doc.mutations || d.eng.shadow.dirty) {
		full = true
		if style.dom_touches_sheets(d.eng, d.doc, d.st, nil) { demo_sheets(d, dir) }
		if !d.eng.dirty {
			if _, ok := style.restyle_dom(d.eng, d.doc, d.st); ok { full, partial = false, true }
		}
	}
	if !full && !style.state_equal(d.state, d.st.state) {
		if _, ok := style.restyle_state(d.eng, d.doc, d.st, d.state); !ok { full = true } else { partial = true }
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
	r := rand.create(20261020)
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
		for iter in 0 ..< 60 {
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
	for &it in d.l.items { if it.kind == .Text && it.deco != {} { red = it.deco_color.r > 0.9 && it.deco_color.b < 0.1 } }
	testing.expect(t, red, "the underline is red")
}