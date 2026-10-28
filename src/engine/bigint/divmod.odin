package bigint

// Division and modulo. ECMAScript BigInt division truncates toward zero and the remainder takes the
// sign of the dividend (like C's /, %), which is what js uses for `/` and `%` on BigInt. The core is
// Knuth's Algorithm D on magnitudes; small divisors use a fast single-limb path.

import "base:intrinsics"

// Quotient and remainder: a = q*b + r, q truncated toward zero, sign(r) == sign(a) (or zero).
// Panics (via the caller's guard) on b == 0 — callers in the engine must reject that first; here we
// return zero/zero to stay allocation-safe.
divmod :: proc(a, b: Int) -> (q: Int, r: Int) {
	if is_zero(b) {
		return Int{}, Int{} // caller must have rejected division by zero
	}
	if is_zero(a) {
		return Int{}, Int{}
	}
	c := mag_cmp(a.mag, b.mag)
	if c < 0 {
		// |a| < |b|: quotient 0, remainder a
		return Int{}, clone(a)
	}
	if c == 0 {
		qq := from_i64(a.neg != b.neg ? -1 : 1)
		return qq, Int{}
	}
	qmag, rmag := mag_divmod(a.mag, b.mag)
	q = norm(a.neg != b.neg, qmag)
	r = norm(a.neg, rmag)
	return
}

div :: proc(a, b: Int) -> Int {
	q, r := divmod(a, b)
	destroy(&r)
	return q
}

rem :: proc(a, b: Int) -> Int {
	q, r := divmod(a, b)
	destroy(&q)
	return r
}

// Magnitude division: returns owned quotient and remainder buffers (un-normalized; caller norms).
@(private)
mag_divmod :: proc(a, b: []Limb) -> (q: []Limb, r: []Limb) {
	if len(b) == 1 {
		return mag_divmod_1(a, b[0])
	}
	return knuth_d(a, b)
}

// Single-limb divisor.
@(private)
mag_divmod_1 :: proc(a: []Limb, d: Limb) -> (q: []Limb, r: []Limb) {
	qq := make([]Limb, len(a))
	rem: Dlimb = 0
	for i := len(a) - 1; i >= 0; i -= 1 {
		cur := (rem << LIMB_BITS) | Dlimb(a[i])
		qq[i] = Limb(cur / Dlimb(d))
		rem = cur % Dlimb(d)
	}
	rr := make([]Limb, 1)
	rr[0] = Limb(rem)
	return qq, rr
}

// Knuth's Algorithm D (TAOCP vol. 2, 4.3.1). a has m+n limbs conceptually, b has n limbs, n >= 2.
@(private)
knuth_d :: proc(a, b: []Limb) -> (q: []Limb, r: []Limb) {
	n := len(b)
	m := len(a) - n

	// Normalize: shift so the top limb of b has its high bit set.
	shift := uint(intrinsics.count_leading_zeros(b[n - 1]))

	bn := make([]Limb, n)
	if shift == 0 {
		copy(bn, b)
	} else {
		carry: Limb = 0
		for i in 0 ..< n {
			v := (Dlimb(b[i]) << shift) | Dlimb(carry)
			bn[i] = Limb(v)
			carry = Limb(v >> LIMB_BITS)
		}
	}

	// un = a << shift, with one extra high limb.
	un := make([]Limb, len(a) + 1)
	if shift == 0 {
		copy(un, a)
		un[len(a)] = 0
	} else {
		carry: Limb = 0
		for i in 0 ..< len(a) {
			v := (Dlimb(a[i]) << shift) | Dlimb(carry)
			un[i] = Limb(v)
			carry = Limb(v >> LIMB_BITS)
		}
		un[len(a)] = carry
	}

	qq := make([]Limb, m + 1)
	b1 := Dlimb(bn[n - 1])
	b2 := Dlimb(bn[n - 2])

	for j := m; j >= 0; j -= 1 {
		// Estimate qhat.
		num := (Dlimb(un[j + n]) << LIMB_BITS) | Dlimb(un[j + n - 1])
		qhat := num / b1
		rhat := num % b1
		for {
			if qhat >= (Dlimb(1) << LIMB_BITS) || qhat * b2 > ((rhat << LIMB_BITS) | Dlimb(un[j + n - 2])) {
				qhat -= 1
				rhat += b1
				if rhat < (Dlimb(1) << LIMB_BITS) {
					continue
				}
			}
			break
		}

		// Multiply and subtract: un[j..j+n] -= qhat * bn.
		borrow: i64 = 0
		carry: Dlimb = 0
		for i in 0 ..< n {
			p := qhat * Dlimb(bn[i]) + carry
			carry = p >> LIMB_BITS
			sub := i64(un[j + i]) - borrow - i64(Limb(p))
			if sub < 0 {
				sub += 1 << LIMB_BITS
				borrow = 1
			} else {
				borrow = 0
			}
			un[j + i] = Limb(sub)
		}
		sub := i64(un[j + n]) - borrow - i64(Limb(carry))
		add_back := false
		if sub < 0 {
			sub += 1 << LIMB_BITS
			add_back = true
		}
		un[j + n] = Limb(sub)

		if add_back {
			// qhat was one too large; add bn back and decrement.
			qhat -= 1
			c: Dlimb = 0
			for i in 0 ..< n {
				s := Dlimb(un[j + i]) + Dlimb(bn[i]) + c
				un[j + i] = Limb(s)
				c = s >> LIMB_BITS
			}
			un[j + n] = Limb(Dlimb(un[j + n]) + c)
		}
		qq[j] = Limb(qhat)
	}

	// Remainder = un[0..n] >> shift.
	rr := make([]Limb, n)
	if shift == 0 {
		copy(rr, un[:n])
	} else {
		for i in 0 ..< n {
			lo := Dlimb(un[i]) >> shift
			hi: Dlimb = 0
			if i + 1 < n {
				hi = Dlimb(un[i + 1]) << (LIMB_BITS - shift)
			} else {
				hi = Dlimb(un[n]) << (LIMB_BITS - shift)
			}
			rr[i] = Limb(lo | hi)
		}
	}
	delete(bn)
	delete(un)
	return qq, rr
}

// a ** e for e >= 0 (BigInt exponentiation). Negative exponent is a RangeError at the engine level;
// here e is a u64.
pow :: proc(a: Int, e: u64) -> Int {
	if e == 0 {
		return from_i64(1)
	}
	if is_zero(a) {
		return Int{}
	}
	result := from_i64(1)
	base := clone(a)
	exp := e
	for exp > 0 {
		if exp & 1 != 0 {
			t := mul(result, base)
			destroy(&result)
			result = t
		}
		exp >>= 1
		if exp > 0 {
			t := mul(base, base)
			destroy(&base)
			base = t
		}
	}
	destroy(&base)
	return result
}
