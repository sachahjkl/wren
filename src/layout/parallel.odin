package layout

import "base:runtime"
import "core:sync"
import "wb:host"
import "wb:style"

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
	// display list (steps 3 and 5 of a share of the walk)
	items3, items5:         [dynamic]Display_Item,
	outlines3, outlines5:   [dynamic]i32,
	scrollers3, scrollers5: [dynamic]i32,
	fix5:                   [dynamic]i32,
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
		// the threads outlive the caller: they get the process heap, not the caller's allocators (a test's tracker)
		context = runtime.default_context()
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
	context = runtime.default_context()
	sync.mutex_lock(&par_mu)
	host.thread_pool_destroy(par_pool)
	par_pool, par_pool_size = nil, 0
	sync.mutex_unlock(&par_mu)
}

// Content width of every block in normal flow whose width is its containing block's minus its own margins, borders and
// padding, from the viewport down (-1: not known ahead). Mirrors block_width for auto widths.
// What each box contributes, found on the layout threads (styles are read there): whether its width follows from its
// parent's, and its horizontal margins and border + padding when they do not depend on that width.
@(private)
Pre_Box :: struct {
	follows:     bool,   // a block in flow with an auto width, in a block container
	relative:    bool,   // some margin or padding is a percentage or calc(): resolved against the parent's width
	simple:      bool,   // an inline formatting context pre_simple accepts
	ml, mr, pbw: f32,
	// a child flow_blocks lays out whose margins and padding do not depend on the width: its box model, resolved here,
	// copied by flow_blocks instead of resolve_box_model (pre_model)
	has_model:   bool,
	auto:        [4]bool,          // top right bottom left
	margin, border, padding: [4]f32,
}

// The box model of child `ch` of a flow_blocks, resolved on the layout threads: what resolve_box_model gives at any
// width (no percentage, no calc()).
@(private)
pre_model :: #force_inline proc(c: ^Ctx, ch: i32, k: ^Box) -> bool {
	if c.pre_boxes == nil || int(ch) >= len(c.pre_boxes) { return false }
	pm := &c.pre_boxes[ch]
	if !pm.has_model { return false }
	k.margin, k.border, k.padding = pm.margin, pm.border, pm.padding
	k.auto_t, k.auto_r, k.auto_b, k.auto_l = pm.auto[0], pm.auto[1], pm.auto[2], pm.auto[3]
	return true
}

@(private)
Pre_Predict :: struct {
	c:      ^Ctx,
	boxes:  []Pre_Box,
	chunks: int,
}

@(private)
pre_predict :: proc(c: ^Ctx, pred: []f32, pool: ^host.Thread_Pool) -> []Pre_Box {
	l := c.l
	pp := Pre_Predict{c = c, boxes = make([]Pre_Box, len(l.boxes), context.temp_allocator)}
	pp.chunks = clamp(len(l.boxes) / 1024, 1, host.thread_pool_size(pool) * 4)
	host.parallel_for(pool, pp.chunks, proc(data: rawptr, k: int) {
		pp := (^Pre_Predict)(data)
		c := pp.c
		l := c.l
		n := len(l.boxes)
		AHEAD :: 8
		lo, hi := k * n / pp.chunks, (k + 1) * n / pp.chunks
		for i in lo ..< hi {
			if i + AHEAD < hi { prefetch_fields(l.boxes[i + AHEAD].cs, LAYOUT_FIELDS) }
			b := &l.boxes[i]
			x := &pp.boxes[i]
			if .Ifc in b.flags { x.simple = pre_simple(l, b) }
			p := b.parent
			if p == NONE { continue }
			pb := &l.boxes[p]
			if pb.kind != .Block || .Ifc in pb.flags || b.cs == nil { continue }
			cs := b.cs
			fixed :: proc(l: style.Length) -> bool { return l.kind != .Percent && l.kind != .Calc }
			model_fixed := true
			for s in style.Side { if !fixed(cs.margin[s]) || !fixed(cs.padding[s]) { model_fixed = false } }
			if model_fixed && b.kind != .Inline && b.flags & {.Abs, .Float, .Dead} == {} {
				// what flow_blocks resolves for this child: independent of the width here
				tmp: Box
				tmp.cs, tmp.kind = cs, b.kind
				resolve_box_model(c, &tmp, 0)
				x.has_model = true
				x.margin, x.border, x.padding = tmp.margin, tmp.border, tmp.padding
				x.auto = {tmp.auto_t, tmp.auto_r, tmp.auto_b, tmp.auto_l}
			}
			if b.kind != .Block || b.flags & {.Abs, .Float, .Block_In_Inline, .Atomic, .Dead} != {} { continue }
			if cs.width.kind != .Auto || cs.max_width.kind != .None { continue }
			if cs.min_width.kind != .Auto && !(cs.min_width.kind == .Px && cs.min_width.v <= 0) { continue }
			x.follows = true
			if !model_fixed {
				x.relative = true
				continue
			}
			x.ml, x.mr, x.pbw = pre_edges(c, cs, 0)
		}
	}, &pp)

	pred[0] = c.vp.x
	for i in 1 ..< len(l.boxes) {
		pred[i] = -1
		x := &pp.boxes[i]
		if !x.follows { continue }
		pcw := pred[l.boxes[i].parent]
		if pcw < 0 { continue }
		ml, mr, pbw := x.ml, x.mr, x.pbw
		if x.relative { ml, mr, pbw = pre_edges(c, l.boxes[i].cs, pcw) }
		w := max(pcw - ml - mr, pbw)
		pred[i] = max(w - pbw, 0)
	}
	return pp.boxes
}

// Horizontal margins (auto: 0) and border + padding of a block in flow against its parent's content width, as
// resolve_box_model, pb_w and block_width find them.
@(private)
pre_edges :: proc(c: ^Ctx, cs: ^style.Computed, pcw: f32) -> (ml, mr, pbw: f32) {
	ml = cs.margin[.Left].kind == .Auto ? 0 : px_of(c, cs.margin[.Left], pcw)
	mr = cs.margin[.Right].kind == .Auto ? 0 : px_of(c, cs.margin[.Right], pcw)
	pbw = max(px_of(c, cs.padding[.Right], pcw), 0) + max(px_of(c, cs.padding[.Left], pcw), 0) +
		border_px(c, cs.border_width[.Right]) + border_px(c, cs.border_width[.Left])
	return
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
	info := pre_predict(c, pred, pool)
	c.pre_boxes = info
	roots := make([dynamic]i32, 0, n_ifc, context.temp_allocator)
	results := make([dynamic]Pre_Result, 0, n_ifc, context.temp_allocator)
	slot := make([]i32, len(l.boxes), context.temp_allocator)
	for i in 0 ..< len(l.boxes) {
		slot[i] = NONE
		b := &l.boxes[i]
		if .Ifc not_in b.flags || pred[i] < 0 || b.parent == NONE || !info[i].simple { continue }
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
	// about a fragment per item and a line per two (as reserve_lines)
	want := 0
	for ri in k * n / pre.chunks ..< (k + 1) * n / pre.chunks {
		b := &l.boxes[pre.roots[ri]]
		want += int(b.items[1] - b.items[0])
	}
	reserve(&ch.frags, want + want / 4 + 16)
	reserve(&ch.lines, want / 2 + 16)
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
	for &ch in l.pre_chunks {
		delete(ch.frags); delete(ch.lines)
		delete(ch.items3); delete(ch.items5)
		delete(ch.outlines3); delete(ch.outlines5); delete(ch.scrollers3); delete(ch.scrollers5); delete(ch.fix5)
	}
	delete(l.pre_chunks)
	l.pre_chunks = nil
}

////////////////////////////////
// Display list

// Steps 3 (block backgrounds) and 5 (lines) of Appendix E walk the same boxes in the same order: every box under the
// stacking context except floats, atomic inlines and positioned or stacking boxes, and what is inside those. That walk
// is listed once, cut into shares, and each share makes its items for both steps into arrays of its own (a float or an
// inline-block met in a line is painted inside its share, as on one thread); they are then joined in order around
// step 4 (floats), made on the UI thread. Returns false (nothing done) for a small stacking context.
@(private)
paint_content_shared :: proc(p: ^Paint_Ctx, root: i32) -> bool {
	c := p.c
	l := c.l
	// boxes are in tree order after a full pass: the subtree is about the boxes up to the next one outside it
	end := i32(len(l.boxes))
	for x := root; x != NONE; x = l.boxes[x].parent {
		if nx := l.boxes[x].next; nx != NONE { end = nx; break }
	}
	if int(end - root) < l.settings.threads_min_boxes { return false }

	walk := make([dynamic]i32, 0, int(end - root), context.temp_allocator)
	stack := make([dynamic]i32, 0, 64, context.temp_allocator)
	push :: proc(l: ^Layout, stack: ^[dynamic]i32, x: i32) {
		n := len(stack)
		for ch := l.boxes[x].first; ch != NONE; ch = l.boxes[ch].next { append(stack, ch) }
		for i, j := n, len(stack) - 1; i < j; i, j = i + 1, j - 1 { stack[i], stack[j] = stack[j], stack[i] }
	}
	push(l, &stack, root)
	for len(stack) > 0 {
		x := pop(&stack)
		b := &l.boxes[x]
		if hoisted(b) || .Float in b.flags || .Atomic in b.flags { continue }
		append(&walk, x)
		push(l, &stack, x)
	}
	if len(walk) < l.settings.threads_min_boxes { return false }
	pool := par_acquire(l.settings.threads)
	if pool == nil { return false }

	defer par_release()

	sh := Dl_Share{c = c, walk = walk[:]}
	sh.chunks = clamp(len(walk) / 512, 1, host.thread_pool_size(pool) * 8)
	for len(l.pre_chunks) < sh.chunks { append(&l.pre_chunks, Pre_Chunk{}) }
	host.parallel_for(pool, sh.chunks, dl_chunk, &sh)

	// 4 (floats) and the stacking context's own lines, between the shares' steps 3 and 5, made here aside
	mid := make([dynamic]Display_Item, 0, 16, context.temp_allocator)
	mid_fix := make([dynamic]i32, 0, 4, context.temp_allocator)
	mid_outlines := make([dynamic]i32, 0, 0, context.temp_allocator)
	mid_scrollers := make([dynamic]i32, 0, 0, context.temp_allocator)
	{
		c.dl_out, c.dl_fix = &mid, &mid_fix
		defer c.dl_out, c.dl_fix = nil, nil
		mp := Paint_Ctx{c = c, outlines = &mid_outlines, scrollers = &mid_scrollers}
		push(l, &stack, root)
		for len(stack) > 0 {
			x := pop(&stack)
			b := &l.boxes[x]
			if hoisted(b) || .Atomic in b.flags { continue }
			if .Float in b.flags { paint_pseudo(&mp, x); continue }
			push(l, &stack, x)
		}
		rb := &l.boxes[root]
		if rb.kind == .Inline { emit_lines(&mp, rb.ifc_root, root) } else { emit_own_lines(&mp, root) }
	}

	// where everything goes: the shares' step 3 in order, the middle, the shares' step 5 in order
	at := len(l.items)
	sh.off3 = make([]int, sh.chunks, context.temp_allocator)
	sh.off5 = make([]int, sh.chunks, context.temp_allocator)
	for k in 0 ..< sh.chunks { sh.off3[k] = at; at += len(l.pre_chunks[k].items3) }
	mid_at := at
	at += len(mid)
	for k in 0 ..< sh.chunks { sh.off5[k] = at; at += len(l.pre_chunks[k].items5) }
	non_zero_resize(&l.items, at)
	host.parallel_for(pool, sh.chunks, dl_copy, &sh)
	copy(l.items[mid_at:], mid[:])
	for x in mid_fix { l.inc.info[x].items += i32(mid_at) }

	for k in 0 ..< sh.chunks { append(p.outlines, ..l.pre_chunks[k].outlines3[:]); append(p.scrollers, ..l.pre_chunks[k].scrollers3[:]) }
	append(p.outlines, ..mid_outlines[:])
	append(p.scrollers, ..mid_scrollers[:])
	for k in 0 ..< sh.chunks { append(p.outlines, ..l.pre_chunks[k].outlines5[:]); append(p.scrollers, ..l.pre_chunks[k].scrollers5[:]) }
	return true
}

@(private)
Dl_Share :: struct {
	c:          ^Ctx,
	walk:       []i32,
	chunks:     int,
	off3, off5: []int,   // where each share's items go in Layout.items
}

@(private)
dl_chunk :: proc(data: rawptr, k: int) {
	sh := (^Dl_Share)(data)
	marker: u8
	wc := sh.c^
	wc.stack_base = uintptr(&marker)
	l := wc.l
	ch := &l.pre_chunks[k]
	clear(&ch.items3); clear(&ch.items5)
	clear(&ch.outlines3); clear(&ch.outlines5); clear(&ch.scrollers3); clear(&ch.scrollers5); clear(&ch.fix5)
	n := len(sh.walk)
	part := sh.walk[k * n / sh.chunks:(k + 1) * n / sh.chunks]
	// about one background and two lines' worth of items per box
	reserve(&ch.items3, len(part) + 16)
	reserve(&ch.items5, 2 * len(part) + 16)
	wc.dl_out = &ch.items3
	sub := Paint_Ctx{c = &wc, outlines = &ch.outlines3, scrollers = &ch.scrollers3}
	AHEAD :: 8
	for x, i in part {
		if i + AHEAD < len(part) { prefetch_fields(l.boxes[part[i + AHEAD]].cs, PAINT_FIELDS) }
		if l.boxes[x].kind != .Inline { emit_box(&sub, x) }
	}
	wc.dl_out, wc.dl_fix = &ch.items5, &ch.fix5
	sub.outlines, sub.scrollers = &ch.outlines5, &ch.scrollers5
	for x in part { emit_own_lines(&sub, x) }
}

@(private)
dl_copy :: proc(data: rawptr, k: int) {
	sh := (^Dl_Share)(data)
	l := sh.c.l
	ch := &l.pre_chunks[k]
	copy(l.items[sh.off3[k]:], ch.items3[:])
	copy(l.items[sh.off5[k]:], ch.items5[:])
	for x in ch.fix5 { l.inc.info[x].items += i32(sh.off5[k]) }
}
