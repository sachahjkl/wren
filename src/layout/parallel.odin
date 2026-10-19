package layout

import "core:sync"
import "wb:host"

// Parallel pre-layout of inline formatting contexts, for full passes over large documents (a page load). Line building
// (words, measuring, breaking, vertical alignment) is most of a full pass, and the lines of a paragraph depend only on
// its content, its content width and the floats around it. Before the block layout, the content width of every block
// in normal flow whose width follows from its ancestors' (auto widths down from the viewport) is predicted, and the
// paragraphs with simple content (text, inline boxes, forced breaks) are laid out on the layout threads at that width,
// as if no float reached them. The block layout then takes such a result as is when it asks for the same width, with the
// same border and padding, and no float in the formatting context; anything else is laid out as usual. The result is the
// same as without threads (layout.threads = 0); a wrong prediction only costs the work done in advance.
//
// What a worker touches: its own copy of the pass state, the boxes of its contexts (the root's box model, the inline
// boxes' edges and scratch), and output arrays of its own. Everything else (items, fonts, styles, the document) is only
// read, and the UI thread waits meanwhile. Measuring text from several threads needs `Text_Api.concurrent`.

// Lines and fragments laid out ahead of time by one share of the work (kept by the layout to reuse their storage).
Pre_Chunk :: struct {
	frags: [dynamic]Frag,
	lines: [dynamic]Line,
}

@(private)
Pre_Result :: struct {
	pcw:          f32,         // content width of the parent (the root's box model resolves against it)
	cw:           f32,         // content width laid out at
	cx, cy:       f32,         // content box offset of the root it was laid out with
	h:            f32,
	empty:        bool,
	chunk:        i32,
	frags, lines: [2]i32,      // in the chunk's arrays; lines refer to fragments from frags[0]
}

@(private)
Pre_Pass :: struct {
	c:       ^Ctx,
	roots:   []i32,
	results: []Pre_Result,
	slot:    []i32,            // box -> index in roots (NONE: not laid out ahead)
	chunks:  int,
}

// One parallel step at a time in the process: a layout that finds the threads busy (another layout on another thread)
// does its work alone.
@(private)
par_mu: sync.Mutex
@(private)
par_pool: ^host.Thread_Pool
@(private)
par_pool_size: int

@(private)
par_threads :: proc(setting: int) -> int {
	if setting >= 0 { return setting }
	return clamp(host.processor_count() - 1, 0, 7)
}

// The helper threads, or nil (none wanted, or busy). Released with par_release.
@(private)
par_acquire :: proc(setting: int) -> ^host.Thread_Pool {
	n := par_threads(setting)
	if n <= 0 { return nil }
	if !sync.mutex_try_lock(&par_mu) { return nil }
	if n != par_pool_size || par_pool == nil {
		host.thread_pool_destroy(par_pool)
		par_pool = host.thread_pool_make(n)
		par_pool_size = n
	}
	if host.thread_pool_size(par_pool) < 2 { sync.mutex_unlock(&par_mu); return nil }
	return par_pool
}

@(private)
par_release :: proc() { sync.mutex_unlock(&par_mu) }

// Joins the layout threads. Call once no layout runs any more, before exiting; they are made again if needed.
shutdown_threads :: proc() {
	sync.mutex_lock(&par_mu)
	host.thread_pool_destroy(par_pool)
	par_pool, par_pool_size = nil, 0
	sync.mutex_unlock(&par_mu)
}

// Content width of every block in normal flow whose width is its containing block's minus its own margins, borders and
// padding, from the viewport down (-1: not known ahead). Mirrors block_width for auto widths.
@(private)
pre_predict :: proc(c: ^Ctx, pred: []f32) {
	l := c.l
	pred[0] = c.vp.x
	for i in 1 ..< len(l.boxes) {
		pred[i] = -1
		b := &l.boxes[i]
		p := b.parent
		if p == NONE || pred[p] < 0 { continue }
		pb := &l.boxes[p]
		if pb.kind != .Block || .Ifc in pb.flags { continue }
		if b.kind != .Block || b.flags & {.Abs, .Float, .Block_In_Inline, .Atomic, .Dead} != {} { continue }
		cs := b.cs
		if cs == nil || cs.width.kind != .Auto || cs.max_width.kind != .None { continue }
		if cs.min_width.kind != .Auto && !(cs.min_width.kind == .Px && cs.min_width.v <= 0) { continue }
		pcw := pred[p]
		ml := cs.margin[.Left].kind == .Auto ? 0 : px_of(c, cs.margin[.Left], pcw)
		mr := cs.margin[.Right].kind == .Auto ? 0 : px_of(c, cs.margin[.Right], pcw)
		pbw := max(px_of(c, cs.padding[.Left], pcw), 0) + max(px_of(c, cs.padding[.Right], pcw), 0) +
			border_px(c, cs.border_width[.Left]) + border_px(c, cs.border_width[.Right])
		w := max(pcw - ml - mr, pbw)
		pred[i] = max(w - pbw, 0)
	}
}

// Contexts whose content needs nothing but the content width (no atomic inline, float, positioned or block-level box).
@(private)
pre_simple :: proc(l: ^Layout, b: ^Box) -> bool {
	if b.fi < 0 || b.items[1] <= b.items[0] { return false }
	for i in b.items[0] ..< b.items[1] {
		switch l.inline_items[i].kind {
		case .Text, .Open, .Close, .Break:
		case .Atomic, .Float, .Abs, .Block: return false
		}
	}
	return true
}

// Lays out ahead of time, on the layout threads, the contexts that qualify (full passes only). Sets c.pre.
@(private)
pre_layout :: proc(c: ^Ctx) {
	l := c.l
	l.pre_counts = {}
	if !c.text.concurrent || par_threads(l.settings.threads) <= 0 || c.inc != nil { return }
	n_ifc := 0
	for &b in l.boxes { if .Ifc in b.flags { n_ifc += 1 } }
	if n_ifc == 0 || n_ifc < l.settings.threads_min_contexts { return }
	pool := par_acquire(l.settings.threads)
	if pool == nil { return }
	defer par_release()

	pred := make([]f32, len(l.boxes), context.temp_allocator)
	pre_predict(c, pred)
	roots := make([dynamic]i32, 0, n_ifc, context.temp_allocator)
	results := make([dynamic]Pre_Result, 0, n_ifc, context.temp_allocator)
	slot := make([]i32, len(l.boxes), context.temp_allocator)
	for i in 0 ..< len(l.boxes) {
		slot[i] = NONE
		b := &l.boxes[i]
		if .Ifc not_in b.flags || pred[i] < 0 || b.parent == NONE || !pre_simple(l, b) { continue }
		slot[i] = i32(len(roots))
		append(&roots, i32(i))
		append(&results, Pre_Result{pcw = pred[b.parent], cw = pred[i], chunk = NONE})
	}
	if len(roots) == 0 || len(roots) < l.settings.threads_min_contexts { return }

	pre := new(Pre_Pass, context.temp_allocator)
	pre^ = Pre_Pass{c = c, roots = roots[:], results = results[:], slot = slot}
	pre.chunks = clamp(len(roots) / 32, 1, host.thread_pool_size(pool) * 8)
	for len(l.pre_chunks) < pre.chunks { append(&l.pre_chunks, Pre_Chunk{}) }
	host.parallel_for(pool, pre.chunks, pre_chunk, pre)
	c.pre = pre
	l.pre_counts[0] = len(roots)
}

@(private)
pre_chunk :: proc(data: rawptr, k: int) {
	pre := (^Pre_Pass)(data)
	marker: u8
	wc := pre.c^
	wc.stack_base = uintptr(&marker)
	wc.lb_bufs = make([dynamic]^LB_Buffers, 0, 2, context.temp_allocator)
	wc.lb_depth = 0
	wc.pre = nil
	l := wc.l
	ch := &l.pre_chunks[k]
	clear(&ch.frags)
	clear(&ch.lines)
	n := len(pre.roots)
	fc: Flow_Ctx   // no formatting context: no float reaches the lines
	for ri in k * n / pre.chunks ..< (k + 1) * n / pre.chunks {
		bi := pre.roots[ri]
		r := &pre.results[ri]
		b := &l.boxes[bi]
		resolve_box_model(&wc, b, r.pcw)
		r.cx, r.cy = content_x(b), content_y(b)
		out, lines, h, empty := ifc_build(&wc, bi, r.cw, &fc)
		r.frags = {i32(len(ch.frags)), i32(len(ch.frags) + len(out))}
		r.lines = {i32(len(ch.lines)), i32(len(ch.lines) + len(lines))}
		append(&ch.frags, ..out)
		append(&ch.lines, ..lines)
		r.h, r.empty, r.chunk = h, empty, i32(k)
	}
}

// The context laid out ahead, when the block layout asks for what it was laid out with.
@(private)
pre_adopt :: proc(c: ^Ctx, bi: i32, cw: f32, fc: ^Flow_Ctx) -> (h: f32, empty: bool, ok: bool) {
	pre := c.pre
	if int(bi) >= len(pre.slot) { return }
	ri := pre.slot[bi]
	if ri == NONE { return }
	r := &pre.results[ri]
	if r.chunk == NONE || r.cw != cw { return }
	if fc != nil && fc.bfc != nil && len(fc.bfc.floats) > 0 { return }
	b := &c.l.boxes[bi]
	if content_x(b) != r.cx || content_y(b) != r.cy { return }
	ch := &c.l.pre_chunks[r.chunk]
	ifc_publish(c, bi, ch.frags[r.frags[0]:r.frags[1]], ch.lines[r.lines[0]:r.lines[1]])
	c.l.pre_counts[1] += 1
	return r.h, r.empty, true
}

@(private)
pre_destroy :: proc(l: ^Layout) {
	for &ch in l.pre_chunks { delete(ch.frags); delete(ch.lines) }
	delete(l.pre_chunks)
}
