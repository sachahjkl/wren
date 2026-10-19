package layout

import "wb:base"

// Compositing support (the shell's compositor, browser/compositor.odin): the display list cut into paint chunks that
// the shell records once into retained GPU pictures and replays every frame.
//
// A chunk is a run of consecutive items (paint order) under the same effect group, recorded together. Within a chunk
// every space (document, fixed, scroll container, sticky box, transformed box) is a transform *slot* of the picture:
// scrolling, sticky shifts and transform animations only change slot matrices (space_world), never the recorded
// instances. Clips of the spaces inside go into the picture too. What changes the chunks is a new display list (a
// layout pass), a paint value of one of its items, or a clip radius.
//
// Boundaries, like Chromium's paint chunks: an effect group starts or ends (opacity, filter, blend mode, backdrop,
// clip-path, isolation are applied around replays, so their parameters animate without recording), an item that
// cannot be recorded (the caller's `immediate`: images and form controls, whose content changes on its own), and a
// size cap. Inside long runs, chunks end where an item's node hash says so (content-defined boundaries: inserting or
// removing items moves the boundaries next to the change only, so the other chunks keep their pictures).

Chunk :: struct {
	first, end: i32,     // [first, end) of Layout.items
	group:      i32,     // effect group of its items (NONE: none)
	immediate:  bool,    // drawn item by item every frame
	root:       i32,     // top space (document or fixed) the picture is recorded in
}

Chunk_Settings :: struct {
	min_items, max_items: int,   // content-defined boundaries only past min_items; always at max_items
	boundary_mask:        u64,   // a boundary after an item whose node hash has these bits clear
}

// The top space above `s` (document or fixed).
space_root :: proc(l: ^Layout, s: i32) -> i32 {
	x := s
	for l.spaces[x].parent != NONE { x = l.spaces[x].parent }
	return x
}

// Where the layout coordinates of space `s` land in viewport pixels for view `v`: W(p) = mats[s](p + offsets[s]).
// The matrix of slot s relative to its picture's root r is inverse(W_r) * W_s.
space_world :: proc(v: ^View, s: i32) -> Matrix {
	return mat_mul(v.mats[s], Matrix{1, 0, 0, 1, v.offsets[s].x, v.offsets[s].y})
}

// An identity of a space that survives the renumbering of a layout pass.
Space_Key :: struct {
	kind:   Space_Kind,
	node:   base.Handle,   // the element of its box (NIL: document, fixed)
	pseudo: u8,            // 1: ::before, 2: ::after
}

space_key :: proc(l: ^Layout, s: i32) -> Space_Key {
	sp := &l.spaces[s]
	if sp.kind == .Document || sp.kind == .Fixed { return {kind = sp.kind} }
	b := &l.boxes[sp.box]
	k := Space_Key{kind = sp.kind, node = b.node}
	if .Pseudo in b.flags { k.pseudo = .Pseudo_After in b.flags ? 2 : 1 }
	return k
}

// Cuts the display list into chunks (appended to `out`).
build_chunks :: proc(l: ^Layout, out: ^[dynamic]Chunk, s: Chunk_Settings, user: rawptr, immediate: proc(user: rawptr, l: ^Layout, it: ^Display_Item) -> bool) {
	n := i32(len(l.items))
	i := i32(0)
	for i < n {
		it := &l.items[i]
		c := Chunk{first = i, group = it.group, immediate = immediate(user, l, it), root = space_root(l, it.space)}
		j := i + 1
		for j < n {
			nx := &l.items[j]
			if nx.group != c.group || immediate(user, l, nx) != c.immediate { break }
			count := int(j - i)
			if !c.immediate {
				if count >= s.max_items { break }
				prev := &l.items[j - 1]
				if count >= s.min_items && node_hash(prev.node, prev.kind) & s.boundary_mask == 0 { break }
			}
			j += 1
		}
		c.end = j
		append(out, c)
		i = j
	}
}

// A well mixed hash of an item's node (stable across passes) for content-defined boundaries.
@(private)
node_hash :: proc(h: base.Handle, kind: Item_Kind) -> u64 {
	x := u64(h) * 0x9E3779B97F4A7C15 + u64(kind) * 0xBF58476D1CE4E5B9
	x ~= x >> 31
	x *= 0x94D049BB133111EB
	x ~= x >> 29
	return x
}
