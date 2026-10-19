// Guest of src/tools/wasmbench: compute kernels and host-call loops (the imports are bench_generated.odin, from
// src/tools/wasmbench/bench.widl).
package wasmbench

N_MAX :: 1 << 20

data: [N_MAX]u32
bytes: [64]u8

// integer and float arithmetic in a dependent chain
@(export)
numeric :: proc "contextless" (n: i32) -> i64 {
	acc: u64 = 1
	f: f64 = 0
	for i in 0 ..< n {
		acc = acc * 6364136223846793005 + u64(i)
		f += f64(acc >> 40) * 1e-9
		if f > 1e6 { f *= 0.5 }
	}
	return i64(acc) ~ i64(f)
}

@(private)
fill :: proc "contextless" (n: int) {
	x: u32 = 2463534242
	for i in 0 ..< n {
		x ~= x << 13
		x ~= x >> 17
		x ~= x << 5
		data[i] = x
	}
}

@(private)
sift :: proc "contextless" (a: []u32, start, end: int) {
	root := start
	for {
		child := 2 * root + 1
		if child > end { return }
		if child + 1 <= end && a[child] < a[child + 1] { child += 1 }
		if a[root] >= a[child] { return }
		a[root], a[child] = a[child], a[root]
		root = child
	}
}

// heap sort of n pseudo-random words; returns a checksum (and 0 if the result is not sorted)
@(export)
sort :: proc "contextless" (n: i32) -> u32 {
	m := min(int(n), N_MAX)
	fill(m)
	a := data[:m]
	for start := (m - 2) / 2; start >= 0; start -= 1 { sift(a, start, m - 1) }
	for end := m - 1; end > 0; end -= 1 {
		a[0], a[end] = a[end], a[0]
		sift(a, 0, end - 1)
	}
	sum: u32
	for i in 0 ..< m {
		if i > 0 && a[i - 1] > a[i] { return 0 }
		sum = sum * 31 + a[i]
	}
	return sum
}

// FNV-1a over 4 MiB, `rounds` times
@(export)
hash :: proc "contextless" (rounds: i32) -> u32 {
	fill(N_MAX)
	p := ([^]u8)(&data[0])
	h: u32 = 2166136261
	for _ in 0 ..< rounds {
		for i in 0 ..< N_MAX * 4 {
			h = (h ~ u32(p[i])) * 16777619
		}
	}
	return h
}

@(export)
calls_nop :: proc "contextless" (n: i32) {
	for _ in 0 ..< n { nop() }
}

@(export)
calls_bytes :: proc "contextless" (n: i32) -> i32 {
	s: i32
	for _ in 0 ..< n { s += touch(bytes[:]) }
	return s
}

@(export)
calls_string :: proc "contextless" (n: i32) -> i32 {
	s: i32
	text := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	for _ in 0 ..< n { s += touch_string(text) }
	return s
}

@(export)
touch_memory :: proc "contextless" (n: i32) -> u32 {
	fill(min(int(n), N_MAX))
	return data[0]
}
