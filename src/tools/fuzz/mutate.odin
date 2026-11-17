package fuzz

// The mutations (src/md/features/fuzzing.md, "The loop of the worker"). Input `i` of a run is a function of the seed, `i`
// and the corpus alone, so a seed keeps naming the same inputs.

// Inputs grow by insertions and splices: past this the growth only slows the target down.
MAX_INPUT :: 1 << 20
MAX_MUTATIONS :: 8

// SplitMix64: twelve lines that no compiler update changes (core:math/rand may change its algorithm).
Rng :: struct { state: u64 }

rng_next :: proc(r: ^Rng) -> u64 {
	r.state += 0x9E3779B97F4A7C15
	z := r.state
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

// A number in [0, n); 0 when n <= 0.
rng_below :: proc(r: ^Rng, n: int) -> int {
	if n <= 0 { return 0 }
	return int(rng_next(r) % u64(n))
}

rng_for :: proc(seed: u64, iteration: int) -> Rng {
	r := Rng{state = seed ~ (u64(iteration) * 0xD1342543DE82EF95)}
	_ = rng_next(&r)
	return r
}

// Bytes that sit on the edges of signed and unsigned ranges, and the 32-bit sizes and counts that binary formats read.
INTERESTING_BYTES :: [?]u8{0x00, 0x01, 0x7F, 0x80, 0xFF, 0x20, 0x0A, 0x0D, '<', '>', '"', '\'', '\\', '/', ';', ':', '{', '}', '(', ')', '%', '&'}
INTERESTING_U32 :: [?]u32{0, 1, 2, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFFFF, 0x10000, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFE, 0xFFFF_FFFF}

// Input `iteration` of a run: a corpus entry with 1 to MAX_MUTATIONS mutations, in the temporary allocator.
mutated :: proc(t: ^Target, corpus: [][]u8, seed: u64, iteration: int) -> []u8 {
	r := rng_for(seed, iteration)
	source := corpus[rng_below(&r, len(corpus))]
	buf := make([dynamic]u8, 0, len(source) + 64, context.temp_allocator)
	append(&buf, ..source)
	for _ in 0 ..< 1 + rng_below(&r, MAX_MUTATIONS) {
		mutate_once(&r, &buf, corpus, t.dictionary)
	}
	if len(buf) > MAX_INPUT { resize(&buf, MAX_INPUT) }
	return buf[:]
}

mutate_once :: proc(r: ^Rng, buf: ^[dynamic]u8, corpus: [][]u8, dictionary: []string) {
	n := len(buf^)
	choice := rng_below(r, 13)
	// (an empty input only grows)
	if n == 0 && choice != 4 && choice != 10 { choice = 4 }
	switch choice {
	case 0:   // a bit flipped
		buf^[rng_below(r, n)] ~= u8(1) << uint(rng_below(r, 8))
	case 1:   // a random byte
		buf^[rng_below(r, n)] = u8(rng_next(r))
	case 2:   // an interesting byte
		table := INTERESTING_BYTES
		buf^[rng_below(r, n)] = table[rng_below(r, len(table))]
	case 3:   // a byte incremented or decremented: a length one off
		at := rng_below(r, n)
		buf^[at] = rng_below(r, 2) == 0 ? buf^[at] + 1 : buf^[at] - 1
	case 4:   // random bytes inserted
		count := 1 + rng_below(r, 16)
		at := rng_below(r, n + 1)
		chunk := make([]u8, count, context.temp_allocator)
		for &c in chunk { c = u8(rng_next(r)) }
		inject_at(buf, at, ..chunk)
	case 5:   // a span deleted: mostly short, sometimes half the input
		at := rng_below(r, n)
		count := rng_below(r, 4) == 0 ? 1 + rng_below(r, max(n / 2, 1)) : 1 + rng_below(r, 64)
		remove_range(buf, at, min(at + count, n))
	case 6:   // a span duplicated in place
		at := rng_below(r, n)
		count := min(1 + rng_below(r, 128), n - at)
		chunk := make([]u8, count, context.temp_allocator)
		copy(chunk, buf^[at:at + count])
		inject_at(buf, rng_below(r, len(buf^) + 1), ..chunk)
	case 7:   // cut short
		resize(buf, rng_below(r, n))
	case 8:   // an interesting 32-bit number, little- or big-endian
		table := INTERESTING_U32
		v := table[rng_below(r, len(table))]
		// (and the input's own length: a size field that says exactly "to the end")
		if rng_below(r, 4) == 0 { v = u32(n) }
		at := rng_below(r, n)
		big := rng_below(r, 2) == 0
		for k in 0 ..< min(4, n - at) {
			shift := big ? uint(24 - 8 * k) : uint(8 * k)
			buf^[at + k] = u8(v >> shift)
		}
	case 9:   // a span written over by another part of the input
		from := rng_below(r, n)
		to := rng_below(r, n)
		count := min(1 + rng_below(r, 64), n - from, n - to)
		chunk := make([]u8, count, context.temp_allocator)
		copy(chunk, buf^[from:from + count])
		copy(buf^[to:], chunk)
	case 10:  // a span of another corpus entry inserted
		other := corpus[rng_below(r, len(corpus))]
		if len(other) == 0 { return }
		from := rng_below(r, len(other))
		count := min(1 + rng_below(r, 256), len(other) - from)
		inject_at(buf, rng_below(r, n + 1), ..other[from:from + count])
	case 11:  // the tail replaced by the tail of another corpus entry: two valid halves of different files
		other := corpus[rng_below(r, len(corpus))]
		cut := rng_below(r, n + 1)
		from := rng_below(r, len(other) + 1)
		resize(buf, cut)
		append(buf, ..other[from:])
	case 12:  // a token of the format inserted or written over
		if len(dictionary) == 0 { buf^[rng_below(r, n)] = u8(rng_next(r)); return }
		token := transmute([]u8)dictionary[rng_below(r, len(dictionary))]
		at := rng_below(r, n + 1)
		if rng_below(r, 2) == 0 || at + len(token) > n {
			inject_at(buf, at, ..token)
		} else {
			copy(buf^[at:], token)
		}
	}
}
