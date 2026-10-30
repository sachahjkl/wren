package style

// The full style pass on several threads, with the same result as the sequential one.
//
// An element's computed style depends only on its parent's, on the rules (read-only during the pass) and on the
// document (read-only too). So: the top of the tree is styled on the calling thread, breadth first, until there are
// enough subtrees to share out; each thread then styles whole subtrees with a Pass of its own (match caches, winners,
// lists) and an arena of its own for the computed styles, kept by the Styled until it is destroyed. Each element's
// slot in `by_node` is written by exactly one thread and the array is sized beforehand, so nothing is shared for
// writing. What compiling inline styles finds out about the engine is collected per pass and merged afterwards on the
// calling thread.

import "core:mem/virtual"
import "wb:base"
import "wb:dom"
import "wb:host"

@(private)
Par_Frame :: struct {
	h:      base.Handle,
	parent: ^Computed,
	bloom:  Bloom,
	ctx:    Elem_Ctx,
}

@(private)
Par_Job :: struct {
	e:      ^Engine,
	s:      ^Styled,
	doc:    ^dom.Document,
	state:  State,
	frames: []Par_Frame,
	ranges: [][2]int,
	passes: []^Pass,
	arenas: []^virtual.Arena,
}

@(private)
style_document_parallel :: proc(e: ^Engine, s: ^Styled, doc: ^dom.Document, state: State, pool: ^host.Thread_Pool) {
	resize(&s.by_node, int(doc.nodes.used))
	main := pass_make(e, s, doc, state)
	defer pass_destroy(main)

	threads := host.thread_pool_size(pool)
	frontier := make([dynamic]Par_Frame, context.temp_allocator)
	root := dom.get(doc, doc.root)
	for c := root.first_child; c != base.NIL_HANDLE; c = dom.get(doc, c).next { append(&frontier, Par_Frame{c, nil, {}, {}}) }
	// How many elements each subtree holds: a page is rarely a balanced tree (one container holds most of it), so what the
	// threads share out is chosen by that weight, not by how deep the tree has been opened.
	sizes := flat_sizes(doc)
	total := 0
	for f in frontier { total += int(sizes[base.handle_index(f.h)]) }
	// a subtree above this many elements is opened on this thread (its children go on the frontier); the rest is shared out
	limit := max(total / (threads * 8), 24)
	// the root element always on this thread (it sets the root font size); then every subtree that is too big to be a task
	for round := 0; len(frontier) > 0 && round < 64; round += 1 {
		next := make([dynamic]Par_Frame, context.temp_allocator)
		opened := false
		for f in frontier {
			n := dom.get(doc, f.h)
			if n == nil || n.kind != .Element { continue }
			if round > 0 && int(sizes[base.handle_index(f.h)]) <= limit { append(&next, f); continue }
			opened = true
			style_subtree(main, f.h, f.parent, f.bloom, descend = false, root_ctx = f.ctx)
			c := s.by_node[int(base.handle_index(f.h))]
			child_bloom := f.bloom
			bloom_add_element(&child_bloom, n)
			for ch := dom.flat_first_child(doc, f.h); ch != base.NIL_HANDLE; ch = dom.flat_next(doc, ch) { append(&next, Par_Frame{ch, c, child_bloom, child_ctx(main, f.h, f.ctx, ch)}) }
		}
		frontier = next
		if !opened { break }
	}
	if len(frontier) == 0 { return }

	// contiguous ranges of about the same weight (the elements they hold), at most four per thread
	wanted := min(len(frontier), threads * 4)
	weight := 0
	for f in frontier { weight += max(int(sizes[base.handle_index(f.h)]), 1) }
	ranges := make([dynamic][2]int, 0, wanted + 1, context.temp_allocator)
	start, acc := 0, 0
	for f, i in frontier {
		acc += max(int(sizes[base.handle_index(f.h)]), 1)
		if acc * wanted >= weight * (len(ranges) + 1) || i == len(frontier) - 1 {
			append(&ranges, [2]int{start, i + 1})
			start = i + 1
		}
	}
	tasks := len(ranges)
	job := Par_Job{e = e, s = s, doc = doc, state = state, frames = frontier[:]}
	job.ranges = ranges[:]
	job.passes = make([]^Pass, tasks, context.temp_allocator)
	job.arenas = make([]^virtual.Arena, tasks, context.temp_allocator)
	host.parallel_for(pool, tasks, proc(data: rawptr, i: int) {
		j := (^Par_Job)(data)
		p := pass_make(j.e, j.s, j.doc, j.state)
		arena := thread_arena_make()
		p.alloc = virtual.arena_allocator(arena)
		r := j.ranges[i]
		for f in j.frames[r[0]:r[1]] { style_subtree(p, f.h, f.parent, f.bloom, root_ctx = f.ctx) }
		j.passes[i], j.arenas[i] = p, arena
	}, &job)
	for i in 0 ..< tasks {
		append(&s.thread_arenas, job.arenas[i])
		pass_destroy(job.passes[i])
	}
}

// How many elements each element's subtree holds (itself included), by the index of its handle: the flat tree, as the style
// pass walks it. In the temporary allocator.
@(private)
flat_sizes :: proc(doc: ^dom.Document) -> []i32 {
	n := int(doc.nodes.used)
	size := make([]i32, n, context.temp_allocator)
	parent := make([]i32, n, context.temp_allocator)   // the parent's index + 1; 0: none
	order := make([dynamic]base.Handle, 0, 256, context.temp_allocator)
	stack := make([dynamic]base.Handle, 0, 64, context.temp_allocator)
	root := dom.get(doc, doc.root)
	for c := root.first_child; c != base.NIL_HANDLE; c = dom.get(doc, c).next { append(&stack, c) }
	for len(stack) > 0 {
		h := pop(&stack)
		nd := dom.get(doc, h)
		if nd == nil || nd.kind != .Element { continue }
		i := int(base.handle_index(h))
		if i >= n { continue }
		size[i] = 1
		append(&order, h)
		for ch := dom.flat_first_child(doc, h); ch != base.NIL_HANDLE; ch = dom.flat_next(doc, ch) {
			if cn := dom.get(doc, ch); cn != nil && cn.kind == .Element && int(base.handle_index(ch)) < n {
				parent[base.handle_index(ch)] = i32(i + 1)
				append(&stack, ch)
			}
		}
	}
	#reverse for h in order {
		i := int(base.handle_index(h))
		if p := parent[i]; p > 0 { size[p - 1] += size[i] }
	}
	return size
}

// The arena of a style thread's computed styles, kept by the Styled (thread_arenas) and freed by its owner's thread: its
// header comes from the process's allocator, whoever runs the item (the caller's allocator may not be thread-safe: a
// test's), and styled_destroy frees it there.
@(private)
thread_arena_make :: proc() -> ^virtual.Arena {
	arena := new(virtual.Arena, base.process_allocator())
	_ = virtual.arena_init_growing(arena)
	return arena
}
