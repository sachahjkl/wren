package bigint

// Arbitrary-precision integers for the JavaScript engine (ECMAScript BigInt), written natively in
// Odin. Rather than copy QuickJS's two's-complement limb layout mechanically, this uses a clean
// sign-magnitude representation that is natural in Odin and gives identical numeric results; the
// bitwise operators (& | ^ ~ << >>) implement ECMAScript's two's-complement-on-an-infinite-integer
// semantics on top of it. Results were checked against Python's arbitrary-precision integers over
// millions of random operands and sizes (arithmetic, every base 2..36, asIntN/asUintN, f64 round
// trips). The magnitude is little-endian u32 limbs with no leading zero limb; the allocator is the
// one in `context.allocator`, so the caller injects it (the engine passes the realm allocator). The
// package builds for windows_amd64, linux_amd64 and freestanding_wasm32 with no OS dependency.

Limb :: u32
Dlimb :: u64
LIMB_BITS :: 32

// A big integer. mag is little-endian, normalized: the last limb is non-zero, or mag is empty for 0.
// neg is false for zero. The slice is owned and freed with `destroy`.
Int :: struct {
	neg: bool,
	mag: []Limb,
}

// --- lifetime ---

// Free the magnitude. Safe on a zero/empty value.
destroy :: proc(a: ^Int) {
	if a.mag != nil {
		delete(a.mag)
		a.mag = nil
	}
	a.neg = false
}

// Deep copy.
clone :: proc(a: Int) -> Int {
	if len(a.mag) == 0 {
		return Int{}
	}
	m := make([]Limb, len(a.mag))
	copy(m, a.mag)
	return Int{neg = a.neg, mag = m}
}

// --- small constructors ---

from_i64 :: proc(v: i64) -> Int {
	if v == 0 {
		return Int{}
	}
	neg := v < 0
	u: u64 = neg ? u64(-(v + 1)) + 1 : u64(v) // avoid overflow on min(i64)
	return Int{neg = neg, mag = mag_from_u64(u)}
}

from_u64 :: proc(v: u64) -> Int {
	if v == 0 {
		return Int{}
	}
	return Int{neg = false, mag = mag_from_u64(v)}
}

@(private)
mag_from_u64 :: proc(v: u64) -> []Limb {
	if v <= u64(max(Limb)) {
		m := make([]Limb, 1)
		m[0] = Limb(v)
		return m
	}
	m := make([]Limb, 2)
	m[0] = Limb(v)
	m[1] = Limb(v >> 32)
	return m
}

is_zero :: #force_inline proc(a: Int) -> bool {
	return len(a.mag) == 0
}

sign :: proc(a: Int) -> int {
	if len(a.mag) == 0 {
		return 0
	}
	return a.neg ? -1 : 1
}

// --- normalization helpers ---

// Build an Int from an owned, possibly-denormalized little-endian limb buffer. Trims leading zeros;
// if the result is zero, frees the buffer and returns the canonical zero, so neg can't stick to 0.
@(private)
norm :: proc(neg: bool, mag: []Limb) -> Int {
	n := len(mag)
	for n > 0 && mag[n - 1] == 0 {
		n -= 1
	}
	if n == 0 {
		delete(mag)
		return Int{}
	}
	if n != len(mag) {
		// shrink: keep the same backing but reslice; the extra capacity is released by resizing.
		shrunk := make([]Limb, n)
		copy(shrunk, mag[:n])
		delete(mag)
		return Int{neg = neg, mag = shrunk}
	}
	return Int{neg = neg, mag = mag}
}

// --- magnitude comparison (ignores sign) ---

@(private)
mag_cmp :: proc(a, b: []Limb) -> int {
	if len(a) != len(b) {
		return len(a) < len(b) ? -1 : 1
	}
	for i := len(a) - 1; i >= 0; i -= 1 {
		if a[i] != b[i] {
			return a[i] < b[i] ? -1 : 1
		}
	}
	return 0
}

// Signed comparison: -1 if a<b, 0 if equal, 1 if a>b.
cmp :: proc(a, b: Int) -> int {
	sa, sb := sign(a), sign(b)
	if sa != sb {
		return sa < sb ? -1 : 1
	}
	if sa == 0 {
		return 0
	}
	c := mag_cmp(a.mag, b.mag)
	return sa > 0 ? c : -c
}

equals :: proc(a, b: Int) -> bool {
	return cmp(a, b) == 0
}

// --- magnitude add / sub (on raw limb slices) ---

// r = a + b (magnitudes). Returns an owned normalized buffer (not trimmed; caller norms).
@(private)
mag_add :: proc(a, b: []Limb) -> []Limb {
	x, y := a, b
	if len(x) < len(y) {
		x, y = y, x
	}
	lx, ly := len(x), len(y)
	r := make([]Limb, lx + 1)
	carry: Dlimb = 0
	for i in 0 ..< lx {
		s := Dlimb(x[i]) + carry
		if i < ly {
			s += Dlimb(y[i])
		}
		r[i] = Limb(s)
		carry = s >> LIMB_BITS
	}
	r[lx] = Limb(carry)
	return r
}

// r = a - b (magnitudes), requires a >= b. Returns an owned buffer.
@(private)
mag_sub :: proc(a, b: []Limb) -> []Limb {
	r := make([]Limb, len(a))
	borrow: i64 = 0
	for i in 0 ..< len(a) {
		d := i64(a[i]) - borrow
		if i < len(b) {
			d -= i64(b[i])
		}
		if d < 0 {
			d += 1 << LIMB_BITS
			borrow = 1
		} else {
			borrow = 0
		}
		r[i] = Limb(d)
	}
	return r
}

// --- signed add / sub ---

add :: proc(a, b: Int) -> Int {
	if is_zero(a) {
		return clone(b)
	}
	if is_zero(b) {
		return clone(a)
	}
	if a.neg == b.neg {
		return norm(a.neg, mag_add(a.mag, b.mag))
	}
	// opposite signs: subtract smaller magnitude from larger
	c := mag_cmp(a.mag, b.mag)
	if c == 0 {
		return Int{}
	}
	if c > 0 {
		return norm(a.neg, mag_sub(a.mag, b.mag))
	}
	return norm(b.neg, mag_sub(b.mag, a.mag))
}

sub :: proc(a, b: Int) -> Int {
	nb := Int{neg = !b.neg && !is_zero(b), mag = b.mag}
	return add(a, nb)
}

neg :: proc(a: Int) -> Int {
	r := clone(a)
	if !is_zero(r) {
		r.neg = !r.neg
	}
	return r
}

abs :: proc(a: Int) -> Int {
	r := clone(a)
	r.neg = false
	return r
}

// --- multiplication ---

KARATSUBA_THRESHOLD :: 40 // limbs; below this, schoolbook is faster

mul :: proc(a, b: Int) -> Int {
	if is_zero(a) || is_zero(b) {
		return Int{}
	}
	m := mag_mul(a.mag, b.mag)
	return norm(a.neg != b.neg, m)
}

@(private)
mag_mul :: proc(a, b: []Limb) -> []Limb {
	if len(a) < KARATSUBA_THRESHOLD || len(b) < KARATSUBA_THRESHOLD {
		return mag_mul_school(a, b)
	}
	return mag_mul_karatsuba(a, b)
}

@(private)
mag_mul_school :: proc(a, b: []Limb) -> []Limb {
	r := make([]Limb, len(a) + len(b))
	for j in 0 ..< len(b) {
		if b[j] == 0 {
			continue
		}
		carry: Dlimb = 0
		bj := Dlimb(b[j])
		for i in 0 ..< len(a) {
			t := Dlimb(a[i]) * bj + Dlimb(r[i + j]) + carry
			r[i + j] = Limb(t)
			carry = t >> LIMB_BITS
		}
		r[len(a) + j] += Limb(carry)
	}
	return r
}

// Karatsuba: split at n = max(len)/2. Works on temporary Ints for clarity; temporaries freed.
@(private)
mag_mul_karatsuba :: proc(a, b: []Limb) -> []Limb {
	n := max(len(a), len(b)) / 2

	alo := trim_view(a[:min(n, len(a))])
	ahi := trim_view(len(a) > n ? a[n:] : []Limb{})
	blo := trim_view(b[:min(n, len(b))])
	bhi := trim_view(len(b) > n ? b[n:] : []Limb{})

	z0 := mag_mul(alo, blo) // alo*blo
	z2 := mag_mul(ahi, bhi) // ahi*bhi

	// (alo+ahi)*(blo+bhi)
	sa := mag_add(alo, ahi)
	sb := mag_add(blo, bhi)
	sa_t := trim_view(sa)
	sb_t := trim_view(sb)
	z1 := mag_mul(sa_t, sb_t)
	delete(sa)
	delete(sb)

	// z1 = z1 - z0 - z2
	z1a := mag_sub_trim(z1, z0)
	delete(z1)
	z1b := mag_sub_trim(z1a, z2)
	delete(z1a)

	// result = z0 + (z1b << (n*32)) + (z2 << (2n*32)). Size generously; norm() trims the surplus.
	total := len(a) + len(b) + 2 * n + 4
	r := make([]Limb, total)
	add_shifted(r, z0, 0)
	add_shifted(r, z1b, n)
	add_shifted(r, z2, 2 * n)
	delete(z0)
	delete(z1b)
	delete(z2)
	return r
}

// trim a view to drop trailing zero limbs (returns a subslice, no allocation).
@(private)
trim_view :: proc(a: []Limb) -> []Limb {
	n := len(a)
	for n > 0 && a[n - 1] == 0 {
		n -= 1
	}
	return a[:n]
}

// a - b into a fresh trimmed buffer, requires a >= b (used in Karatsuba where that holds).
@(private)
mag_sub_trim :: proc(a, b: []Limb) -> []Limb {
	at := trim_view(a)
	bt := trim_view(b)
	r := mag_sub(at, bt)
	return r
}

// r[offset_limbs:] += v (magnitude), in place. r must be large enough.
@(private)
add_shifted :: proc(r: []Limb, v: []Limb, offset: int) {
	carry: Dlimb = 0
	i := 0
	for i < len(v) {
		idx := i + offset
		s := Dlimb(r[idx]) + Dlimb(v[i]) + carry
		r[idx] = Limb(s)
		carry = s >> LIMB_BITS
		i += 1
	}
	idx := i + offset
	for carry != 0 && idx < len(r) {
		s := Dlimb(r[idx]) + carry
		r[idx] = Limb(s)
		carry = s >> LIMB_BITS
		idx += 1
	}
}

// --- shifts (arithmetic on the signed value, ECMAScript semantics) ---

// a << n (n >= 0): multiply magnitude by 2^n, sign preserved.
shl :: proc(a: Int, n: uint) -> Int {
	if is_zero(a) || n == 0 {
		return clone(a)
	}
	limb_shift := int(n / LIMB_BITS)
	bit_shift := uint(n % LIMB_BITS)
	src := a.mag
	out := make([]Limb, len(src) + limb_shift + 1)
	if bit_shift == 0 {
		for i in 0 ..< len(src) {
			out[i + limb_shift] = src[i]
		}
	} else {
		carry: Limb = 0
		for i in 0 ..< len(src) {
			v := (Dlimb(src[i]) << bit_shift) | Dlimb(carry)
			out[i + limb_shift] = Limb(v)
			carry = Limb(v >> LIMB_BITS)
		}
		out[len(src) + limb_shift] = carry
	}
	return norm(a.neg, out)
}

// a >> n (n >= 0): ECMAScript arithmetic right shift. For negatives this is floor division by 2^n
// (two's-complement sign extension), so a >> n == floor(a / 2^n).
shr :: proc(a: Int, n: uint) -> Int {
	if is_zero(a) || n == 0 {
		return clone(a)
	}
	if !a.neg {
		return mag_shr(a.neg, a.mag, n)
	}
	// negative: floor division. floor(-x / 2^n) = -(ceil(x / 2^n)). Detect if any shifted-out bit set.
	lost := any_low_bits_set(a.mag, n)
	r := mag_shr(true, a.mag, n)
	if lost {
		one := from_i64(1)
		defer destroy(&one)
		adj := sub(r, one) // r is negative; subtract 1 makes it more negative => -(q+1)
		destroy(&r)
		return adj
	}
	return r
}

@(private)
mag_shr :: proc(neg: bool, src: []Limb, n: uint) -> Int {
	limb_shift := int(n / LIMB_BITS)
	bit_shift := uint(n % LIMB_BITS)
	if limb_shift >= len(src) {
		return Int{}
	}
	out_len := len(src) - limb_shift
	out := make([]Limb, out_len)
	if bit_shift == 0 {
		for i in 0 ..< out_len {
			out[i] = src[i + limb_shift]
		}
	} else {
		for i in 0 ..< out_len {
			lo := Dlimb(src[i + limb_shift]) >> bit_shift
			hi: Dlimb = 0
			if i + limb_shift + 1 < len(src) {
				hi = Dlimb(src[i + limb_shift + 1]) << (LIMB_BITS - bit_shift)
			}
			out[i] = Limb(lo | hi)
		}
	}
	return norm(neg, out)
}

// True if any of the low n bits of the magnitude are set.
@(private)
any_low_bits_set :: proc(mag: []Limb, n: uint) -> bool {
	limbs := int(n / LIMB_BITS)
	bits := uint(n % LIMB_BITS)
	for i in 0 ..< min(limbs, len(mag)) {
		if mag[i] != 0 {
			return true
		}
	}
	if bits != 0 && limbs < len(mag) {
		if mag[limbs] & ((Limb(1) << bits) - 1) != 0 {
			return true
		}
	}
	return false
}
