package ucd

// CharRange: a set of Unicode code points stored as a sorted, non-overlapping list of half-open intervals
// [lo, hi). This is the Odin counterpart of QuickJS's `CharRange`, but it leans on the language: a `[dynamic]`
// of points on a caller-chosen allocator instead of a hand-rolled realloc callback. The invariant kept by every
// operation here is: `points` has an even length, holds strictly increasing values, and no two intervals touch
// or overlap (they are already merged). Callers that build a range by hand with `add_interval` must finish with
// `normalize` before relying on that invariant.
//
// The package is written to compile for freestanding_wasm32 as well as the hosted targets: nothing here touches
// the OS, and every allocation goes through the allocator carried by the range. The interpreter and the regexp
// compiler pass an arena so a whole compilation frees at once.

import "base:runtime"

Char_Range :: struct {
	// Sorted boundaries, always an even count. Interval i is [points[2*i], points[2*i+1]).
	points:    [dynamic]u32,
	// The allocator the range owns; every interior allocation (set-op scratch, invert) reuses it, so an arena
	// passed in frees the whole regexp compilation at once.
	allocator: runtime.Allocator,
}

// MAX code point + 1; intervals never exceed this upper bound.
CODE_POINT_MAX :: 0x110000

cr_init :: proc(cr: ^Char_Range, allocator := context.allocator) {
	cr.allocator = allocator
	cr.points = make([dynamic]u32, 0, 8, allocator)
}

cr_destroy :: proc(cr: ^Char_Range) {
	delete(cr.points)
	cr.points = nil
}

cr_clear :: proc(cr: ^Char_Range) {
	clear(&cr.points)
}

cr_len :: proc(cr: ^Char_Range) -> int {
	return len(cr.points) / 2
}

// Append a raw boundary. Used by the table decoders that already emit sorted, well-formed runs.
cr_add_point :: proc(cr: ^Char_Range, v: u32) {
	append(&cr.points, v)
}

// Append a half-open interval [c1, c2) without checking order. Follow with `cr_normalize` before use unless the
// caller is appending strictly increasing, non-touching intervals (the common case for table decoders).
cr_add_interval :: proc(cr: ^Char_Range, c1, c2: u32) {
	if c1 >= c2 { return }
	append(&cr.points, c1, c2)
}

cr_copy :: proc(dst: ^Char_Range, src: ^Char_Range) {
	clear(&dst.points)
	reserve(&dst.points, len(src.points))
	for v in src.points { append(&dst.points, v) }
}

cr_contains :: proc(cr: ^Char_Range, c: u32) -> bool {
	// Binary search over interval starts. points is sorted, even length.
	lo, hi := 0, len(cr.points) / 2
	for lo < hi {
		mid := (lo + hi) / 2
		if c < cr.points[2 * mid] {
			hi = mid
		} else if c >= cr.points[2 * mid + 1] {
			lo = mid + 1
		} else {
			return true
		}
	}
	return false
}

// Merge touching/overlapping intervals and drop empties, sorting first. After this the invariant holds.
cr_normalize :: proc(cr: ^Char_Range) {
	n := len(cr.points) / 2
	if n <= 1 { return }
	// Insertion sort by interval start is fine for the small ranges class membership produces; the differential
	// harness exercises large synthetic ranges too, so use a simple comparison sort on index pairs.
	sort_intervals(cr)
	w := 0
	cur_lo := cr.points[0]
	cur_hi := cr.points[1]
	for i in 1 ..< n {
		lo := cr.points[2 * i]
		hi := cr.points[2 * i + 1]
		if lo <= cur_hi {
			if hi > cur_hi { cur_hi = hi }
		} else {
			cr.points[2 * w] = cur_lo
			cr.points[2 * w + 1] = cur_hi
			w += 1
			cur_lo = lo
			cur_hi = hi
		}
	}
	cr.points[2 * w] = cur_lo
	cr.points[2 * w + 1] = cur_hi
	w += 1
	resize(&cr.points, 2 * w)
}

@(private)
sort_intervals :: proc(cr: ^Char_Range) {
	// Heap-free, allocation-free insertion sort on interval pairs. Ranges from property lookups arrive already
	// sorted; set operations keep them sorted. This is the belt-and-braces path for hand-built ranges and fuzz.
	n := len(cr.points) / 2
	for i in 1 ..< n {
		lo := cr.points[2 * i]
		hi := cr.points[2 * i + 1]
		j := i - 1
		for j >= 0 && cr.points[2 * j] > lo {
			cr.points[2 * (j + 1)] = cr.points[2 * j]
			cr.points[2 * (j + 1) + 1] = cr.points[2 * j + 1]
			j -= 1
		}
		cr.points[2 * (j + 1)] = lo
		cr.points[2 * (j + 1) + 1] = hi
	}
}

Set_Op :: enum u8 { Union, Inter, Xor, Sub }

// Boolean combination of two normalized ranges into `dst` (which may alias neither input). A sweep over the two
// sorted boundary lists, emitting a boundary whenever membership flips. This is the core the `v` flag set
// notation builds on (union/intersection/difference), and what `invert` and `union_interval` reduce to.
cr_op :: proc(dst, a, b: ^Char_Range, op: Set_Op) {
	clear(&dst.points)
	al := len(a.points)
	bl := len(b.points)
	a_idx, b_idx := 0, 0
	in_out := false
	for a_idx < al || b_idx < bl {
		v: u32
		if a_idx < al && b_idx < bl {
			if a.points[a_idx] < b.points[b_idx] {
				v = a.points[a_idx]; a_idx += 1
			} else if a.points[a_idx] == b.points[b_idx] {
				v = a.points[a_idx]; a_idx += 1; b_idx += 1
			} else {
				v = b.points[b_idx]; b_idx += 1
			}
		} else if a_idx < al {
			v = a.points[a_idx]; a_idx += 1
		} else {
			v = b.points[b_idx]; b_idx += 1
		}
		in_a := (a_idx & 1) == 1
		in_b := (b_idx & 1) == 1
		is_in: bool
		switch op {
		case .Union: is_in = in_a || in_b
		case .Inter: is_in = in_a && in_b
		case .Xor:   is_in = in_a != in_b
		case .Sub:   is_in = in_a && !in_b
		}
		if is_in != in_out {
			append(&dst.points, v)
			in_out = is_in
		}
	}
}

// In-place variant: dst = dst OP other.
cr_op_inplace :: proc(cr, other: ^Char_Range, op: Set_Op) {
	tmp: Char_Range
	cr_init(&tmp, cr.allocator)
	defer cr_destroy(&tmp)
	cr_op(&tmp, cr, other, op)
	cr_copy(cr, &tmp)
}

// Complement within [0, CODE_POINT_MAX).
cr_invert :: proc(cr: ^Char_Range) {
	n := len(cr.points)
	out := make([dynamic]u32, 0, n + 2, cr.allocator)
	start: u32 = 0
	i := 0
	for i < n {
		lo := cr.points[i]
		hi := cr.points[i + 1]
		if lo > start {
			append(&out, start, lo)
		}
		start = hi
		i += 2
	}
	if start < CODE_POINT_MAX {
		append(&out, start, CODE_POINT_MAX)
	}
	delete(cr.points)
	cr.points = out
}

cr_union_interval :: proc(cr: ^Char_Range, c1, c2: u32) {
	other: Char_Range
	cr_init(&other, cr.allocator)
	defer cr_destroy(&other)
	cr_add_interval(&other, c1, c2)
	cr_op_inplace(cr, &other, .Union)
}
