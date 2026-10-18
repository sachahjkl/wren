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
	for c := root.first_child; c != base.NIL_HANDLE; c = dom.get(doc, c).next { append(&frontier, Par_Frame{c, nil, {}}) }
	// the root element always on this thread (it sets the root font size); then deeper until subtrees are plenty
	for depth := 0; len(frontier) > 0 && (depth == 0 || len(frontier) < threads * 8) && depth < 16; depth += 1 {
		next := make([dynamic]Par_Frame, context.temp_allocator)
		for f in frontier {
			n := dom.get(doc, f.h)
			if n == nil || n.kind != .Element { continue }
			style_subtree(main, f.h, f.parent, f.bloom, descend = false)
			c := s.by_node[int(base.handle_index(f.h))]
			child_bloom := f.bloom
			bloom_add_element(&child_bloom, n)
			for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&next, Par_Frame{ch, c, child_bloom}) }
		}
		frontier = next
	}
	if len(frontier) == 0 { return }

	tasks := min(len(frontier), threads * 4)
	job := Par_Job{e = e, s = s, doc = doc, state = state, frames = frontier[:]}
	job.ranges = make([][2]int, tasks, context.temp_allocator)
	job.passes = make([]^Pass, tasks, context.temp_allocator)
	job.arenas = make([]^virtual.Arena, tasks, context.temp_allocator)
	for i in 0 ..< tasks { job.ranges[i] = {i * len(frontier) / tasks, (i + 1) * len(frontier) / tasks} }
	host.parallel_for(pool, tasks, proc(data: rawptr, i: int) {
		j := (^Par_Job)(data)
		p := pass_make(j.e, j.s, j.doc, j.state)
		arena := new(virtual.Arena)
		_ = virtual.arena_init_growing(arena)
		p.alloc = virtual.arena_allocator(arena)
		r := j.ranges[i]
		for f in j.frames[r[0]:r[1]] { style_subtree(p, f.h, f.parent, f.bloom) }
		j.passes[i], j.arenas[i] = p, arena
	}, &job)
	for i in 0 ..< tasks {
		append(&s.thread_arenas, job.arenas[i])
		pass_destroy(job.passes[i])
	}
}
