package wpt

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:dom"
import lay "wb:layout"
import "wb:page"
import "wb:tools/headless"
import "wb:tools/wpt/reftest"

// Reference tests in the child: both pages laid out headless (layout_host.odin) and rasterised (package reftest), then
// compared under the rules of WPT's docs/writing-tests/reftests.md at the pinned commit: of a page's links, at least one
// match must hold when there are any and every mismatch must; a reference's own links must hold in turn. The screenshot
// is taken as wptrunner takes it: after the load event and web fonts; with class="reftest-wait" on the root, an event
// TestRendered is fired at the root and the class is waited for, within the test's time limit. A status other than PASS and
// FAIL ends the test: TIMEOUT, ERROR (a reference that does not exist, a page that does not load).

// Pictures of pages kept per child: references are shared by many tests (the green square of /css/reference/...).
@(private = "file")
REF_CACHE_MAX :: 16
// How deep a chain of references may go: past it (a cycle) the test is an error.
@(private = "file")
REF_CHAIN_MAX :: 16
// A turn of the wait for a page, and of a pending picture's decoding, ms.
@(private = "file")
RENDER_TURN_MS :: 10
// The frames a page that asks for animation frames gets before the screenshot (wptrunner's pending paints), and how long
// one lasts, ms.
@(private = "file")
SETTLE_FRAMES :: 2
@(private = "file")
SETTLE_FRAME_MS :: 17
@(private = "file")
REFTEST_WAIT_CLASS :: "reftest-wait"
@(private = "file")
TEST_RENDERED :: `document.documentElement.dispatchEvent(new Event("TestRendered", {bubbles: true}));`
@(private = "file")
DUMP_ENV :: "WPT_REFTEST_DUMP"
// Priority of a picture's decoding: everything here is on screen, in one go.
@(private = "file")
DECODE_PRIORITY :: 1

STATUS_PASS :: "PASS"
STATUS_FAIL :: "FAIL"
STATUS_TIMEOUT :: "TIMEOUT"
STATUS_ERROR :: "ERROR"

@(private = "file")
Cached :: struct {
	key:   string,
	image: reftest.Image,
	items: string,   // with -dump: its display list
	used:  u64,
}

@(private = "file")
Ref_Run :: struct {
	env:      ^headless.Env,
	cache:    [dynamic]^Cached,
	clock:    u64,
	infos:    map[string]^reftest.Page_Info,
	deadline: time.Tick,
	limit_ms: f64,
	viewport: [2]int,
	compared: [dynamic]string,   // the pairs of pages compared for this test
	// the first comparison that failed, for the message and the dump
	failed:   bool,
	message:  string,
	first:    Kept_Pair,
	// the last comparison that held (with -dump-all)
	last:     Kept_Pair,
}

@(private = "file")
ref_run: Ref_Run

dump_dir_from_env :: proc() -> string { return os.get_env(DUMP_ENV, context.temp_allocator) }

// A directory for pictures outside the repository: no folder from it up has a ".git".
dump_dir_allowed :: proc(dir: string) -> bool {
	abs, err := os.get_absolute_path(dir, context.temp_allocator)
	if err != nil { return false }
	p := abs
	for {
		if os.exists(filepath.join({p, ".git"}, context.temp_allocator) or_else "") { return false }
		up := filepath.dir(p)
		if up == p || up == "" || up == "." { return true }
		p = up
	}
}

// The file of a path on the server (without its query); "" for a path that climbs out of the checkout.
@(private = "file")
file_of :: proc(path: string) -> string {
	p := path
	if k := strings.index_byte(p, '?'); k >= 0 { p = p[:k] }
	return filepath.join({opts.root, p}, context.temp_allocator) or_else ""
}

// What a page says of its references, from its file (as WPT's manifest reads it). nil: no such file.
@(private = "file")
page_info :: proc(path: string) -> ^reftest.Page_Info {
	if info, found := ref_run.infos[path]; found { return info }
	data, err := os.read_entire_file(file_of(path), context.temp_allocator)
	if err != nil { return nil }
	info := new(reftest.Page_Info)
	info^ = reftest.scan_page(string(data), path)
	ref_run.infos[strings.clone(path)] = info
	return info
}

@(private = "file")
has_wait_class :: proc(d: ^headless.Doc) -> bool {
	doc := d.page != nil ? d.page.doc : nil
	if doc == nil { return false }
	n := dom.get(doc, doc.root)
	if n == nil { return false }
	for c := n.first_child; c != base.NIL_HANDLE; c = dom.get(doc, c).next {
		cn := dom.get(doc, c)
		if cn.kind != .Element { continue }
		v, ok := dom.get_attribute(doc, c, "class")
		if !ok { return false }
		for token in strings.fields(v, context.temp_allocator) { if token == REFTEST_WAIT_CLASS { return true } }
		return false
	}
	return false
}

@(private = "file")
loads_pending :: proc(p: ^page.Page) -> bool {
	if p.fonts.loading > 0 || len(p.fonts.queue) > 0 { return true }
	if !p.images.ready { return false }
	for _, r in p.images.requests {
		if r.state == .Queued || r.state == .Loading || r.state == .Probing { return true }
	}
	return false
}

// The content of a replaced element or a control for the rasteriser.
@(private = "file")
raster_replaced :: proc(user: rawptr, l: ^lay.Layout, it: ^lay.Display_Item, w, h: int) -> reftest.Content {
	host := (^Layout_Host)(user)
	p := host.page
	if p == nil || p.doc == nil { return {} }
	n := dom.get(p.doc, it.node)
	if n == nil || n.kind != .Element { return {} }
	attr :: proc(p: ^page.Page, node: base.Handle, name: string) -> string {
		v, _ := dom.get_attribute(p.doc, node, name)
		return v
	}
	if it.kind == .Control {
		_, checked := dom.get_attribute(p.doc, it.node, "checked")
		return reftest.Content{kind = .Stand_In, key = fmt.tprintf("%s|%s|%s|%v|%s", n.name, attr(p, it.node, "type"), attr(p, it.node, "value"), checked, n.name == "textarea" ? dom.text_content(p.doc, it.node) : "")}
	}
	picture :: proc(v: page.Image_View, w, h: int) -> reftest.Content {
		switch v.state {
		case .None: return {}
		case .Loading: return reftest.Content{kind = .Pending}
		case .Broken: return reftest.Content{kind = .Stand_In, key = "broken"}
		case .Ready:
		}
		// a raster picture at its natural size (no reduced decode); a vector one at the size it is shown at
		fw, fh := v.svg ? w : v.pixel_size[0], v.svg ? h : v.pixel_size[1]
		fp := page.frame_pixels(v.id, 0, fw, fh, DECODE_PRIORITY)
		if !fp.ok { return reftest.Content{kind = .Pending} }
		return reftest.Content{kind = .Pixels, pixels = fp.pixels, width = fp.width, height = fp.height, stride = fp.stride, natural = v.natural}
	}
	switch n.name {
	case "svg":
		v := page.inline_svg_view(p, it.node, f32(w), f32(h))
		c := picture(v, w, h)
		if c.kind == .Pixels { c.natural = {f32(w), f32(h)} }
		return c
	case "canvas":
		v := page.canvas_view(p, it.node)
		if !v.ok { return {} }
		if v.gpu != nil { return reftest.Content{kind = .Stand_In, key = "canvas"} }
		return reftest.Content{kind = .Pixels, pixels = v.bmp.pix, width = v.bmp.w, height = v.bmp.h, stride = v.bmp.w * reftest.CHANNELS, natural = {f32(v.bmp.w), f32(v.bmp.h)}, premultiplied = true}
	case "img", "input":
		c := picture(page.image_view(p, it.node), w, h)
		if c.kind == .Stand_In { c.key = fmt.tprintf("broken %s", attr(p, it.node, "src")) }
		return c
	}
	// (video, a frame's document...: not rendered headless)
	return reftest.Content{kind = .Stand_In, key = fmt.tprintf("%s %s%s", n.name, attr(p, it.node, "src"), attr(p, it.node, "data"))}
}

@(private = "file")
raster_css_image :: proc(user: rawptr, url: string, w, h: int) -> reftest.Content {
	p := (^Layout_Host)(user).page
	if p == nil { return {} }
	v := page.css_image_view(p, url)
	switch v.state {
	case .None, .Broken: return {}
	case .Loading: return reftest.Content{kind = .Pending}
	case .Ready:
	}
	c := reftest.Content{kind = .Pixels, natural = v.natural, vector = v.svg, ratio_only = v.ratio_only, has_size = v.has_size}
	if w <= 0 { return c }
	// a raster picture at its natural size; a vector one at the size of the tile
	fp := page.frame_pixels(v.id, 0, v.svg ? w : v.pixel_size[0], v.svg ? h : v.pixel_size[1], DECODE_PRIORITY)
	if !fp.ok { return reftest.Content{kind = .Pending} }
	c.pixels, c.width, c.height, c.stride = fp.pixels, fp.width, fp.height, fp.stride
	return c
}

// What -dump writes beside the pictures, to tell a layout's fault from a rasteriser's: the display list, one item a line.
@(private = "file")
display_list_text :: proc(l: ^lay.Layout) -> string {
	b := strings.builder_make()
	fmt.sbprintfln(&b, "canvas %v", l.canvas)
	for &it, i in l.items {
		fi := lay.item_font(l, &it)
		fmt.sbprintfln(&b, "%d %v rect %v baseline %v flags %v space %d clip %d group %d box %d font %v text %q", i, it.kind, it.rect, it.baseline, it.flags, it.space, it.clip, it.group, it.box, fi != nil ? fi.size : 0, it.text)
	}
	return strings.to_string(b)
}

// Loads a page, waits as the harness waits and draws it. A status != "" when there is no picture.
@(private = "file")
render_page :: proc(path: string) -> (img: reftest.Image, items, status, message: string) {
	cs: Child_State
	cs.layout = host_make(true, ref_run.viewport)
	defer host_destroy(cs.layout)
	d := headless.open(ref_run.env, test_url(path), child_on_console, &cs)
	defer headless.close(d)
	d.on_parsed = host_attach
	d.by_type = true   // (most reference tests of CSS are .xht: some of their sheets are in CDATA sections)
	defer delete(cs.first_error)
	host := reftest.Host{user = cs.layout, replaced = raster_replaced, css_image = raster_css_image}
	rendered_event := false
	settle := 0
	undecoded := 0
	idle_since: time.Tick
	idle := false
	for {
		headless.pump(d, RENDER_TURN_MS)
		if d.failed != "" { return {}, "", STATUS_ERROR, fmt.aprintf("%s did not load: %s", path, d.failed) }
		if time.tick_since(ref_run.deadline) >= 0 {
			why := "the page did not finish loading"
			switch {
			case has_wait_class(d): why = "the class reftest-wait stays"
			case d.page != nil && headless.loaded(d) && loads_pending(d.page): why = "images or fonts are still loading"
			case undecoded > 0: why = "pictures are still decoding"
			}
			return {}, "", STATUS_TIMEOUT, fmt.aprintf("%s: %s", path, why)
		}
		if !headless.loaded(d) || d.page == nil || d.page.closed { continue }
		p := d.page
		host_update(cs.layout, p)
		page.images_sync(p)
		for node in page.images_watched(p) { page.images_set_distance(p, node, 0) }
		page.canvas_frame(p)
		if loads_pending(p) { continue }
		if has_wait_class(d) {
			if !rendered_event {
				rendered_event = true
				page.js_run(p, transmute([]byte)string(TEST_RENDERED), "wpt-runner.js")
				continue
			}
			// a page that can no longer do anything will not remove the class
			if opts.idle_ms > 0 && !page_busy(p) {
				if !idle { idle = true; idle_since = time.tick_now() }
				if time.duration_milliseconds(time.tick_since(idle_since)) >= f64(opts.idle_ms) {
					return {}, "", STATUS_TIMEOUT, fmt.aprintf("%s: the class reftest-wait stays and the page has nothing left to do", path)
				}
			} else {
				idle = false
			}
			continue
		}
		if settle < SETTLE_FRAMES && page.wants_animation_frame(p) {
			settle += 1
			headless.pump(d, SETTLE_FRAME_MS)
			continue
		}
		host_update(cs.layout, p)
		page.images_sync(p)
		if has_wait_class(d) || loads_pending(p) { continue }
		res := reftest.render(&cs.layout.l, cs.layout.view[0], cs.layout.view[1], f32(cs.layout.scroll[1]), cs.layout.l.canvas, &host)
		if res.pending == 0 {
			if opts.dump != "" { items = display_list_text(&cs.layout.l) }
			return res.image, items, "", ""
		}
		undecoded = res.pending
		reftest.image_destroy(&res.image)
	}
}

// The picture of a page, from the child's cache or drawn now. The pointer is good until REF_CACHE_MAX other pages are drawn.
@(private = "file")
picture_of :: proc(path: string) -> (pic: ^Cached, status, message: string) {
	r := &ref_run
	r.clock += 1
	key := fmt.tprintf("%s@%dx%d", path, r.viewport[0], r.viewport[1])
	for c in r.cache {
		if c.key == key { c.used = r.clock; return c, "", "" }
	}
	img, items, st, msg := render_page(path)
	if st != "" { return nil, st, msg }
	if len(r.cache) >= REF_CACHE_MAX {
		oldest := 0
		for c, i in r.cache { if c.used < r.cache[oldest].used { oldest = i } }
		c := r.cache[oldest]
		unordered_remove(&r.cache, oldest)
		delete(c.key)
		delete(c.items)
		reftest.image_destroy(&c.image)
		free(c)
	}
	c := new(Cached)
	c.key, c.image, c.items, c.used = strings.clone(key), img, items, r.clock
	append(&r.cache, c)
	return c, "", ""
}

// A comparison kept for the dump: what the pages looked like then (the cache may let them go).
@(private = "file")
Kept_Pair :: struct {
	a, b:             reftest.Image,
	a_items, b_items: string,
}

@(private = "file")
keep_pair :: proc(k: ^Kept_Pair, a, b: ^Cached) {
	clone :: proc(from: ^reftest.Image, to: ^reftest.Image) {
		reftest.image_destroy(to)
		to^ = reftest.image_make(from.width, from.height)
		copy(to.rgba, from.rgba)
	}
	clone(&a.image, &k.a)
	clone(&b.image, &k.b)
	delete(k.a_items)
	delete(k.b_items)
	k.a_items, k.b_items = strings.clone(a.items), strings.clone(b.items)
}

// Whether `path` holds against its references. A status != "" ends the test.
@(private = "file")
check_page :: proc(path: string, depth: int) -> (ok: bool, status, message: string) {
	if depth > REF_CHAIN_MAX { return false, STATUS_ERROR, fmt.aprintf("the chain of references from %s goes on and on", path) }
	info := page_info(path)
	if info == nil { return false, STATUS_ERROR, fmt.aprintf("no file for %s", path) }
	has_match, matched := false, false
	all_mismatch := true
	for link in info.refs {
		// wptrunner's comparison key: a pair is compared once in a test, so that two pages may link to each other
		pair := link.url < path ? fmt.aprintf("%v %s %s", link.relation, link.url, path) : fmt.aprintf("%v %s %s", link.relation, path, link.url)
		seen := false
		for p in ref_run.compared { if p == pair { seen = true; break } }
		if seen { delete(pair); continue }
		append(&ref_run.compared, pair)
		if link.relation == .Match {
			has_match = true
			if matched { continue }   // (one is enough)
		}
		if page_info(link.url) == nil { return false, STATUS_ERROR, fmt.aprintf("%s links to %s, which does not exist", path, link.url) }
		a, sta, msga := picture_of(path)
		if sta != "" { return false, sta, msga }
		b, stb, msgb := picture_of(link.url)
		if stb != "" { return false, stb, msgb }
		diff := reftest.compare(&a.image, &b.image)
		f, has_fuzzy := reftest.fuzzy_for(info, link.url)
		equal := reftest.considered_equal(diff, f, has_fuzzy)
		holds := equal == (link.relation == .Match)
		if holds {
			if opts.dump != "" && opts.dump_all { keep_pair(&ref_run.last, a, b) }
			// the reference's own links must hold too
			sub, st, msg := check_page(link.url, depth + 1)
			if st != "" { return false, st, msg }
			holds = sub
		} else if !ref_run.failed {
			ref_run.failed = true
			if link.relation == .Match {
				ref_run.message = fmt.aprintf("%s differs from %s: %d pixels, by at most %d", path, link.url, diff.pixels, diff.max_channel)
			} else {
				ref_run.message = fmt.aprintf("%s is the same as %s, which it should not be", path, link.url)
			}
			if opts.dump != "" { keep_pair(&ref_run.first, a, b) }
		}
		if link.relation == .Match { matched = matched || holds } else { all_mismatch = all_mismatch && holds }
	}
	return (!has_match || matched) && all_mismatch, "", ""
}

@(private = "file")
dump_pair :: proc(test_path: string, k: ^Kept_Pair) {
	name := strings.builder_make(context.temp_allocator)
	for c in transmute([]byte)strings.trim_left(test_path, "/") {
		switch c {
		case '/', '\\', ':', '?', '*', '"', '<', '>', '|': strings.write_byte(&name, '_')
		case: strings.write_byte(&name, c)
		}
	}
	base_path := filepath.join({opts.dump, strings.to_string(name)}, context.temp_allocator) or_else ""
	_ = os.make_directory_all(opts.dump)
	write :: proc(base_path, suffix: string, img: ^reftest.Image) {
		data := reftest.png_encode(img, context.temp_allocator)
		_ = os.write_entire_file(strings.concatenate({base_path, suffix}, context.temp_allocator), data)
	}
	write(base_path, ".test.png", &k.a)
	write(base_path, ".ref.png", &k.b)
	d := reftest.difference_image(&k.a, &k.b, context.temp_allocator)
	write(base_path, ".diff.png", &d)
	_ = os.write_entire_file(strings.concatenate({base_path, ".test.items.txt"}, context.temp_allocator), k.a_items)
	_ = os.write_entire_file(strings.concatenate({base_path, ".ref.items.txt"}, context.temp_allocator), k.b_items)
}

// One reference test: PASS, FAIL, TIMEOUT or ERROR.
@(private = "file")
run_reftest :: proc(path: string, limit_ms: f64) -> (status, message: string) {
	r := &ref_run
	r.deadline = time.tick_add(time.tick_now(), time.Duration(limit_ms) * time.Millisecond)
	r.failed = false
	for p in r.compared { delete(p) }
	clear(&r.compared)
	r.viewport = {}
	if info := page_info(path); info != nil { r.viewport = info.viewport }
	if r.viewport == {} { r.viewport = {LAYOUT_VIEW_W, LAYOUT_VIEW_H} }
	ok, st, msg := check_page(path, 0)
	switch {
	case st != "": status, message = st, msg
	case ok: status, message = STATUS_PASS, ""
	case: status, message = STATUS_FAIL, r.message
	}
	if opts.dump != "" {
		if status == STATUS_FAIL && r.first.a.rgba != nil { dump_pair(path, &r.first) }
		if status == STATUS_PASS && opts.dump_all && r.last.a.rgba != nil { dump_pair(path, &r.last) }
	}
	return
}

reftests_child_begin :: proc(env: ^headless.Env) {
	ref_run.env = env
	ref_run.infos = make(map[string]^reftest.Page_Info)
	ref_run.cache = make([dynamic]^Cached)
}

// Writes the result of one reference test as the child writes results.
reftest_one :: proc(out: ^os.File, path: string, limit_ms: f64) {
	t0 := time.tick_now()
	status, message := run_reftest(path, limit_ms)
	ms := int(time.duration_milliseconds(time.tick_since(t0)))
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "T\t%s\t%s\t%d\t%s", escape(path), status, ms, escape(message))
	fmt.sbprintln(&b, "E")
	os.write_string(out, strings.to_string(b))
	os.flush(out)
	free_all(context.temp_allocator)
}
