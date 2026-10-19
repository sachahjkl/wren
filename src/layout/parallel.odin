package layout

import "base:intrinsics"
import "base:runtime"
import "core:sync"
import "core:thread"
import "wb:host"
import "wb:style"

// Parallel pre-layout of inline formatting contexts, for full passes over large documents (a page load) and for
// incremental passes that lay many paragraphs out again (a change of the viewport width: a window being resized). Line
// building (words, measuring, breaking, vertical alignment) is most of such a pass, and the lines of a paragraph depend
// only on its content, its content width and the floats around it. Before the block layout, the content width of every
// block in normal flow whose width follows from its ancestors' (auto widths down from the viewport) is predicted, and the
// paragraphs with simple content (text, inline boxes, forced breaks) are laid out on the layout threads at that width,
// as if no float reached them. The block layout then takes such a result as is when it asks for the same width, with the
// same border and padding, and no float in the formatting context; anything else is laid out as usual. The result is the
// same as without threads (layout.threads = 0); a wrong prediction only costs the work done in advance.
//
// An incremental pass only lays out ahead the paragraphs its block layout will not take from their cache: those
// invalidated, and those whose predicted width is not the one they were last laid out at (a column that reached its
// max-width keeps its paragraphs, and they are not touched). Their measured segments are reused as on the UI thread;
// segments measured on a thread are kept only when the result is taken.
//
// What a worker touches: its own copy of the pass state, scratch fields of the inline boxes of its contexts (left as
// it found them otherwise: box models are put back, and resolved again when the result is taken), and output arrays of
// its own. Everything else (items, fonts, styles, the document, the caches of the boxes) is only read, and the UI thread
// waits meanwhile. Measuring text from several threads needs `Text_Api.concurrent`.

// Lines and fragments laid out ahead of time by one share of the work (kept by the layout to reuse their storage).
Pre_Chunk :: struct {
	frags: [dynamic]Frag,
	lines: [dynamic]Line,
	segs:  [dynamic]Seg,   // incremental passes: segments measured on the thread (Pre_Result.segs)
	models: [dynamic]Box_Model_Save,   // inline boxes' edges (Pre_Result.models)
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
	segs:         [2]i32,      // in the chunk's segs: measured there, to keep (empty: none)
	models:       [2]i32,      // in the chunk's models: the edges of its inline boxes (and their fragments' union)
	settled:      bool,        // models have the unions: pre_adopt needs not read the fragments (ifc_settle)
	inline_abs:   bool,        // some inline box of the context is the containing block of positioned boxes
	baseline, last_baseline: f32,
	part:         i32,         // the share that lays it out (Pre_Pass.done)
	taken:        bool,
}

@(private)
Pre_Pass :: struct {
	c:       ^Ctx,
	roots:   []i32,
	results: []Pre_Result,
	slot:    []i32,            // box -> index in roots (NONE: not laid out ahead)
	chunks:  int,
	// the shares are taken in order by whoever comes (the threads, the UI thread when the block layout needs one that
	// nobody started), and marked done
	next:    int,              // atomic
	done:    []bool,           // atomic
	streaming: bool,           // shares may still be in the making: the UI thread grows nothing the threads read
	ui:      int,              // thread id of the caller (the block layout runs there)
	walk:    proc(c: ^Ctx),
	walked:  bool,
	pending_segs: [dynamic]Pending_Segs,   // keep_segs on the UI thread while streaming: applied afterwards
}

@(private)
Pending_Segs :: struct { box: i32, segs: []Seg }

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
	simple:      bool,   // a live inline formatting context with a parent, that pre_simple accepts
	parent:      i32,
	old_cw:      f32,    // incremental passes, a simple context: the content width it was last laid out at (-1: lay it out)
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
	plain:  []bool,
	chunks: int,
}

// What pre_predict finds from the boxes and their styles, kept for the next passes while neither changes (a resize:
// only the widths change, and old_cw, read again from the boxes of the contexts that qualify).
@(private)
Pre_Keep :: struct {
	key:   [3]u64,          // as Dl_Walks
	boxes: [dynamic]Pre_Box,
	plain: [dynamic]bool,
	ifcs:  [dynamic]i32,    // the simple contexts
}

@(private)
pre_predict :: proc(c: ^Ctx, pred: []f32, pool: ^host.Thread_Pool) -> []Pre_Box {
	l := c.l
	keep := &l.pre_keep
	if keep.key == dl_walks_key(l) && len(keep.boxes) == len(l.boxes) {
		c.plain = keep.plain[:]
		if c.inc != nil {
			Stale :: struct { l: ^Layout, chunks: int }
			st := Stale{l, clamp(len(keep.ifcs) / 512, 1, host.thread_pool_size(pool) * 4)}
			host.parallel_for(pool, st.chunks, proc(data: rawptr, k: int) {
				st := (^Stale)(data)
				l := st.l
				n := len(l.pre_keep.ifcs)
				for i in l.pre_keep.ifcs[k * n / st.chunks:(k + 1) * n / st.chunks] {
					b := &l.boxes[i]
					l.pre_keep.boxes[i].old_cw = pre_stale(b) ? -1 : b.cache_in[0] - pb_w(b)
				}
			}, &st)
		}
		pre_widths(c, pred, keep.boxes[:], nil)
		return keep.boxes[:]
	}
	pp := Pre_Predict{c = c, boxes = make([]Pre_Box, len(l.boxes), context.temp_allocator), plain = make([]bool, len(l.boxes), context.temp_allocator)}
	c.plain = pp.plain
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
			p := b.parent
			x.parent = p
			// dead boxes (partial rebuilds) may point at styles freed since
			if p == NONE || .Dead in b.flags { continue }
			if cs := b.cs; cs != nil {
				pp.plain[i] = cs.width.kind == .Auto && cs.min_width.kind == .Auto && cs.max_width.kind == .None &&
					cs.height.kind == .Auto && cs.min_height.kind == .Auto && cs.max_height.kind == .None && cs.aspect_ratio <= 0
			}
			if .Ifc in b.flags {
				x.simple = pre_simple(l, b)
				if x.simple && c.inc != nil { x.old_cw = pre_stale(b) ? -1 : b.cache_in[0] - pb_w(b) }
			}
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

	clear(&keep.ifcs)
	pre_widths(c, pred, pp.boxes, &keep.ifcs)
	keep.key = dl_walks_key(l)
	resize(&keep.boxes, len(pp.boxes)); copy(keep.boxes[:], pp.boxes)
	resize(&keep.plain, len(pp.plain)); copy(keep.plain[:], pp.plain)
	return pp.boxes
}

// The predicted content widths (pred), from the viewport down; `ifcs`: collects the simple contexts.
@(private)
pre_widths :: proc(c: ^Ctx, pred: []f32, boxes: []Pre_Box, ifcs: ^[dynamic]i32) {
	l := c.l
	pred[0] = c.vp.x
	for i in 1 ..< len(l.boxes) {
		pred[i] = -1
		x := &boxes[i]
		if ifcs != nil && x.simple { append(ifcs, i32(i)) }
		if !x.follows { continue }
		// parents come first, except after partial rebuilds (new boxes go at the end): not known then
		p := x.parent
		if int(p) >= i { continue }
		pcw := pred[p]
		if pcw < 0 { continue }
		ml, mr, pbw := x.ml, x.mr, x.pbw
		if x.relative { ml, mr, pbw = pre_edges(c, l.boxes[i].cs, pcw) }
		w := max(pcw - ml - mr, pbw)
		pred[i] = max(w - pbw, 0)
	}
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

// The block layout of the pass (`walk`), with the contexts that qualify laid out on the layout threads meanwhile: the
// threads build the shares in document order while the UI thread runs the block layout, which takes each context when
// it reaches it (waiting for its share, or building it itself when nobody started it). Sets c.pre while it runs.
@(private)
pre_run :: proc(c: ^Ctx, walk: proc(c: ^Ctx)) {
	l := c.l
	l.pre_counts = {}
	defer c.pre_boxes, c.plain = nil, nil   // found for this block layout only
	pool, pre := pre_layout(c)
	if pre == nil { walk(c); return }
	defer par_release()
	pre.walk = walk
	pre.ui = sync.current_thread_id()
	pre.done = make([]bool, pre.chunks, context.temp_allocator)
	pre.pending_segs = make([dynamic]Pending_Segs, 0, 16, context.temp_allocator)
	pre.streaming = true
	c.pre = pre
	// one item per thread: each takes shares until none is left; the caller's first item is the block layout
	host.parallel_for(pool, host.thread_pool_size(pool), pre_stream, pre)
	pre.streaming = false
	if !pre.walked { walk(c) }   // the threads took every item first: the shares are all done
	for &p in pre.pending_segs { keep_segs(c, p.box, p.segs) }
	clear(&pre.pending_segs)
}

@(private)
pre_stream :: proc(data: rawptr, _: int) {
	pre := (^Pre_Pass)(data)
	if !pre.walked && sync.current_thread_id() == pre.ui {
		pre.walked = true
		pre.walk(pre.c)
		return
	}
	for {
		k := sync.atomic_add(&pre.next, 1)
		if k >= pre.chunks { return }
		pre_chunk(pre, k)
		sync.atomic_store(&pre.done[k], true)
	}
}

// Before the UI thread touches box `bi` while the threads may be building its context: its share is done.
@(private)
pre_wait_box :: #force_inline proc(c: ^Ctx, bi: i32) {
	pre := c.pre
	if pre == nil || !pre.streaming || int(bi) >= len(pre.slot) { return }
	if ri := pre.slot[bi]; ri != NONE { pre_wait(pre, int(pre.results[ri].part)) }
}

@(private)
pre_wait :: proc(pre: ^Pre_Pass, k: int) {
	for spins := 0; !sync.atomic_load(&pre.done[k]); spins += 1 {
		// nobody started it (or a later one): build the next one here rather than wait
		if j := sync.atomic_add(&pre.next, 1); j < pre.chunks {
			pre_chunk(pre, j)
			sync.atomic_store(&pre.done[j], true)
			continue
		}
		if spins < 4096 { intrinsics.cpu_relax() } else { thread.yield() }
	}
}

// Every share done: the UI thread may grow what the threads read (fonts).
@(private)
pre_drain :: proc(c: ^Ctx) {
	pre := c.pre
	if pre == nil || !pre.streaming { return }
	for k in 0 ..< pre.chunks { pre_wait(pre, k) }
	pre.streaming = false
}

// The contexts that qualify and their shares (nil: none, the threads are not used). The threads are held when the
// pass is returned (par_release).
@(private)
pre_layout :: proc(c: ^Ctx) -> (^host.Thread_Pool, ^Pre_Pass) {
	l := c.l
	if !c.text.concurrent || par_threads(l.settings.threads) <= 0 { return nil, nil }
	// an incremental pass: worth a look only when much may be laid out again (run_incremental sets `wide`)
	if c.inc != nil && (!l.settings.threads_incremental || !c.inc.wide) { return nil, nil }
	n_ifc := 0
	if c.inc == nil {
		for &b in l.boxes { if .Ifc in b.flags { n_ifc += 1 } }
	} else {
		n_ifc = len(l.boxes)   // at most (the boxes are read on the threads; the contexts are counted below)
	}
	if n_ifc == 0 || n_ifc < l.settings.threads_min_contexts { return nil, nil }
	pool := par_acquire(l.settings.threads)
	if pool == nil { return nil, nil }
	ok := false
	defer if !ok { par_release() }

	pred := make([]f32, len(l.boxes), context.temp_allocator)
	info := pre_predict(c, pred, pool)
	c.pre_boxes = info
	roots := make([dynamic]i32, 0, n_ifc, context.temp_allocator)
	results := make([dynamic]Pre_Result, 0, n_ifc, context.temp_allocator)
	slot := make([]i32, len(l.boxes), context.temp_allocator)
	for i in 0 ..< len(l.boxes) {
		slot[i] = NONE
		x := &info[i]
		if !x.simple || pred[i] < 0 { continue }
		// an incremental pass: only what its block layout will lay out again
		if c.inc != nil && x.old_cw == pred[i] { continue }
		slot[i] = i32(len(roots))
		append(&roots, i32(i))
		append(&results, Pre_Result{pcw = pred[x.parent], cw = pred[i], chunk = NONE})
	}
	if len(roots) == 0 || len(roots) < l.settings.threads_min_contexts { return nil, nil }

	pre := new(Pre_Pass, context.temp_allocator)
	pre^ = Pre_Pass{c = c, roots = roots[:], results = results[:], slot = slot}
	// small shares: the block layout waits for the first one only
	pre.chunks = clamp(len(roots) / 16, 1, host.thread_pool_size(pool) * 16)
	n := len(roots)
	for k in 0 ..< pre.chunks {
		for ri in k * n / pre.chunks ..< (k + 1) * n / pre.chunks { results[ri].part = i32(k) }
	}
	for len(l.pre_chunks) < pre.chunks { append(&l.pre_chunks, Pre_Chunk{}) }
	l.pre_counts[0] = len(roots)
	ok = true
	return pool, pre
}

// Incremental passes: context `b` misses its layout cache whatever its width (else: when the width differs from the
// one it was laid out at). A guess: a context laid out ahead and not taken is lost work, one not laid out ahead is laid
// out on the UI thread.
@(private)
pre_stale :: proc(b: ^Box) -> bool { return !b.cache_ok || b.inc != {} }

@(private)
pre_chunk :: proc(pre: ^Pre_Pass, k: int) {
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
	clear(&ch.segs)
	clear(&ch.models)
	if wc.inc != nil { wc.segs_out = &ch.segs }
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
		// the box models it resolves are put back: an incremental pass may take this box (or its inline boxes) from
		// their caches; pre_adopt resolves them again when it takes the result
		saved := Box_Model_Save{}
		model_save(&saved, b)
		resolve_box_model(&wc, b, r.pcw)
		r.cx, r.cy = content_x(b), content_y(b)
		inl := make([dynamic]Box_Model_Save, 0, 8, context.temp_allocator)
		r.inline_abs = false
		for i in b.items[0] ..< b.items[1] {
			if it := &l.inline_items[i]; it.kind == .Open {
				s: Box_Model_Save
				ib := &l.boxes[it.box]
				model_save(&s, ib, it.box)
				append(&inl, s)
				if ib.abs_first != NONE { r.inline_abs = true }
			}
		}
		s0 := len(ch.segs)
		out, lines, h, empty, _ := ifc_build(&wc, bi, r.cw, &fc)   // (simple contexts: no trailing block)
		r.frags = {i32(len(ch.frags)), i32(len(ch.frags) + len(out))}
		r.lines = {i32(len(ch.lines)), i32(len(ch.lines) + len(lines))}
		r.segs = {i32(s0), i32(len(ch.segs))}
		append(&ch.frags, ..out)
		append(&ch.lines, ..lines)
		r.h, r.empty, r.chunk = h, empty, i32(k)
		model_restore(&l.boxes[bi], saved)
		if len(lines) > 0 {
			fl, ll := lines[0], lines[len(lines) - 1]
			r.baseline, r.last_baseline = fl.y + fl.baseline, ll.y + ll.baseline
		}
		// the edges the inline boxes were laid out with go to the result (pre_adopt), what they had goes back; and what
		// ifc_settle would do on the UI thread: the union of each inline box's fragments
		r.models[0] = i32(len(ch.models))
		for &s, j in inl {
			ib := &l.boxes[s.box]
			used: Box_Model_Save
			model_save(&used, ib, s.box)
			append(&ch.models, used)
			model_restore(ib, s)
			ib.tmp_al = -3 - i32(j)   // scratch: its entry
		}
		r.settled = true
		for &f in out {
			if f.kind != .Box { continue }
			j := -3 - l.boxes[f.box].tmp_al
			if j < 0 || int(j) >= len(inl) { r.settled = false; continue }   // not an inline box of the context
			m := &ch.models[r.models[0] + j]
			fr := Rect{{f.x, f.y}, {f.x + f.w, f.y + f.h}}
			if !m.has_rect {
				m.rect, m.has_rect = fr, true
			} else {
				m.rect = rect_union(m.rect, fr)
			}
		}
		for &s in inl { l.boxes[s.box].tmp_al = -1 }
		r.models[1] = i32(len(ch.models))
		clear(&inl)
	}
}

// What resolve_box_model sets, for box `box`; for an inline box laid out ahead, also the union of its fragments.
@(private)
Box_Model_Save :: struct {
	margin, border, padding: [4]f32,
	auto: [4]bool,
	box:  i32,
	has_rect: bool,
	rect: Rect,
}

@(private)
model_save :: #force_inline proc(s: ^Box_Model_Save, b: ^Box, bi: i32 = NONE) {
	s.margin, s.border, s.padding = b.margin, b.border, b.padding
	s.auto = {b.auto_t, b.auto_r, b.auto_b, b.auto_l}
	s.box = bi
}

@(private)
model_restore :: #force_inline proc(b: ^Box, s: Box_Model_Save) {
	b.margin, b.border, b.padding = s.margin, s.border, s.padding
	b.auto_t, b.auto_r, b.auto_b, b.auto_l = s.auto[0], s.auto[1], s.auto[2], s.auto[3]
}

// The context laid out ahead, when the block layout asks for what it was laid out with.
@(private)
pre_adopt :: proc(c: ^Ctx, bi: i32, cw: f32, fc: ^Flow_Ctx) -> (h: f32, empty: bool, ok: bool) {
	pre := c.pre
	if int(bi) >= len(pre.slot) { return }
	ri := pre.slot[bi]
	if ri == NONE { return }
	r := &pre.results[ri]
	if pre.streaming { pre_wait(pre, int(r.part)) }
	if r.chunk == NONE || r.cw != cw { return }
	if fc != nil && fc.bfc != nil && len(fc.bfc.floats) > 0 { return }
	b := &c.l.boxes[bi]
	if content_x(b) != r.cx || content_y(b) != r.cy { return }
	ch := &c.l.pre_chunks[r.chunk]
	if r.segs[1] > r.segs[0] { keep_segs(c, bi, ch.segs[r.segs[0]:r.segs[1]]) }
	// its lines and fragments join the layout's (the threads never read those)
	l := c.l
	fb := i32(len(l.frags))   // the lines' fragments count from the context's first
	append(&l.frags, ..ch.frags[r.frags[0]:r.frags[1]])
	l0 := i32(len(l.lines))
	for ln in ch.lines[r.lines[0]:r.lines[1]] {
		ln2 := ln
		ln2.frags += fb
		append(&l.lines, ln2)
	}
	glines := [2]i32{l0, i32(len(l.lines))}
	if r.settled {
		// ifc_settle, from what the thread found
		b.lines = glines
		if glines[1] > glines[0] { b.baseline, b.last_baseline = r.baseline, r.last_baseline }
		for &s in ch.models[r.models[0]:r.models[1]] {
			ib := &c.l.boxes[s.box]
			model_restore(ib, s)
			if s.has_rect { ib.pos, ib.size = s.rect.min, s.rect.max - s.rect.min }
		}
	} else {
		for &s in ch.models[r.models[0]:r.models[1]] { model_restore(&c.l.boxes[s.box], s) }
		ifc_settle(c, bi, glines)
	}
	if !r.taken { c.l.pre_counts[1] += 1 }
	r.taken = true
	return r.h, r.empty, true
}

// Context `bi` was taken from the threads and none of its inline boxes contains positioned boxes: layout_inline_abs
// has nothing to do (it would read every item of the context to find out).
@(private)
pre_no_inline_abs :: #force_inline proc(c: ^Ctx, bi: i32) -> bool {
	pre := c.pre
	if pre == nil || int(bi) >= len(pre.slot) { return false }
	ri := pre.slot[bi]
	if ri == NONE { return false }
	r := &pre.results[ri]
	return r.taken && !r.inline_abs
}

@(private)
pre_destroy :: proc(l: ^Layout) {
	for &ch in l.pre_chunks {
		delete(ch.frags); delete(ch.lines); delete(ch.segs); delete(ch.models)
		delete(ch.items3); delete(ch.items5)
		delete(ch.outlines3); delete(ch.outlines5); delete(ch.scrollers3); delete(ch.scrollers5); delete(ch.fix5)
	}
	delete(l.pre_chunks)
	l.pre_chunks = nil
	delete(l.pre_keep.boxes); delete(l.pre_keep.plain); delete(l.pre_keep.ifcs)
	l.pre_keep = {}
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

	// the boxes steps 3 and 5 visit, and the floats (step 4) in the same walk's order; the page's are kept (Dl_Walks)
	walk, floats: []i32
	kept := root == 0 && l.dl_walks.key == dl_walks_key(l) ? &l.dl_walks : nil
	if kept != nil && kept.walk_ok {
		walk, floats = kept.walk[:], kept.floats[:]
	} else {
		dwalk := make([dynamic]i32, 0, int(end - root), context.temp_allocator)
		dfloats := make([dynamic]i32, 0, 16, context.temp_allocator)
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
			if hoisted(b) || .Atomic in b.flags { continue }
			if .Float in b.flags { append(&dfloats, x); continue }
			append(&dwalk, x)
			push(l, &stack, x)
		}
		walk, floats = dwalk[:], dfloats[:]
		if kept != nil {
			clear(&kept.walk); clear(&kept.floats)
			append(&kept.walk, ..walk); append(&kept.floats, ..floats)
			kept.walk_ok = true
		}
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
		for x in floats { paint_pseudo(&mp, x) }
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
