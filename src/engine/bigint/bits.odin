package bigint

// Bitwise operators with ECMAScript two's-complement-on-an-infinite-integer semantics, implemented on
// the sign-magnitude representation. The idea: a negative value -x is, in two's complement, the bit
// pattern ~(x-1). We convert each operand to its "two's complement limb view" over a common width,
// apply the op per limb, then convert back. asIntN / asUintN wrap to a fixed bit width.

// Two's-complement limb value of operand at limb index i, over `width` limbs. For a negative number
// this yields ~(mag-1) limbs with infinite sign extension handled by the caller using width.
@(private)
tc_limb :: proc(a: Int, i: int, inv_carry: ^Limb) -> Limb {
	// For non-negative: just the magnitude limb (0 past the end).
	if !a.neg {
		return i < len(a.mag) ? a.mag[i] : 0
	}
	// Negative: two's complement = ~mag + 1, computed limb by limb with a running add carry.
	m := i < len(a.mag) ? a.mag[i] : 0
	v := ~m
	s := Dlimb(v) + Dlimb(inv_carry^)
	inv_carry^ = Limb(s >> LIMB_BITS)
	return Limb(s)
}

Bit_Op :: enum {
	And,
	Or,
	Xor,
}

bit_op :: proc(a, b: Int, op: Bit_Op) -> Int {
	width := max(len(a.mag), len(b.mag)) + 1
	out := make([]Limb, width)
	ca: Limb = 1
	cb: Limb = 1
	for i in 0 ..< width {
		la := tc_limb(a, i, &ca)
		lb := tc_limb(b, i, &cb)
		switch op {
		case .And:
			out[i] = la & lb
		case .Or:
			out[i] = la | lb
		case .Xor:
			out[i] = la ~ lb
		}
	}
	// Determine the sign of the result from the operation on the sign bits.
	rneg: bool
	switch op {
	case .And:
		rneg = a.neg && b.neg
	case .Or:
		rneg = a.neg || b.neg
	case .Xor:
		rneg = a.neg != b.neg
	}
	return from_tc(rneg, out)
}

bit_and :: proc(a, b: Int) -> Int { return bit_op(a, b, .And) }
bit_or :: proc(a, b: Int) -> Int { return bit_op(a, b, .Or) }
bit_xor :: proc(a, b: Int) -> Int { return bit_op(a, b, .Xor) }

// ~a == -(a+1).
bit_not :: proc(a: Int) -> Int {
	one := from_i64(1)
	defer destroy(&one)
	s := add(a, one)
	r := neg(s)
	destroy(&s)
	return r
}

// Convert a two's-complement limb buffer (owned) with the given sign back to sign-magnitude. The
// buffer represents the value directly if rneg is false; if rneg is true it is the two's complement
// pattern and we invert back to the magnitude (~x + 1). Frees the input buffer.
@(private)
from_tc :: proc(rneg: bool, tc: []Limb) -> Int {
	if !rneg {
		return norm(false, tc)
	}
	// magnitude = ~tc + 1
	mag := make([]Limb, len(tc))
	carry: Limb = 1
	for i in 0 ..< len(tc) {
		s := Dlimb(~tc[i]) + Dlimb(carry)
		mag[i] = Limb(s)
		carry = Limb(s >> LIMB_BITS)
	}
	delete(tc)
	return norm(true, mag)
}

// BigInt.asUintN(bits, a): a mod 2^bits, as a non-negative value.
as_uintn :: proc(bits: u64, a: Int) -> Int {
	if bits == 0 {
		return Int{}
	}
	nlimbs := int((bits + LIMB_BITS - 1) / LIMB_BITS)
	out := make([]Limb, nlimbs)
	ca: Limb = 1
	for i in 0 ..< nlimbs {
		out[i] = tc_limb(a, i, &ca)
	}
	// mask the top limb to the exact bit count
	top_bits := uint(bits % LIMB_BITS)
	if top_bits != 0 {
		out[nlimbs - 1] &= (Limb(1) << top_bits) - 1
	}
	return norm(false, out)
}

// BigInt.asIntN(bits, a): a mod 2^bits interpreted as a signed two's-complement value of `bits` bits.
as_intn :: proc(bits: u64, a: Int) -> Int {
	if bits == 0 {
		return Int{}
	}
	u := as_uintn(bits, a) // non-negative, < 2^bits
	// If the sign bit (bit bits-1) is set, the signed value is u - 2^bits.
	sign_bit := test_bit(u, bits - 1)
	if !sign_bit {
		return u
	}
	// result = u - 2^bits
	two_pow := one_shifted(uint(bits))
	defer destroy(&two_pow)
	r := sub(u, two_pow)
	destroy(&u)
	return r
}

// Is bit k of the (non-negative) magnitude set?
@(private)
test_bit :: proc(a: Int, k: u64) -> bool {
	limb := int(k / LIMB_BITS)
	bit := uint(k % LIMB_BITS)
	if limb >= len(a.mag) {
		return false
	}
	return (a.mag[limb] >> bit) & 1 != 0
}

// 2^n as a positive Int.
@(private)
one_shifted :: proc(n: uint) -> Int {
	one := from_i64(1)
	r := shl(one, n)
	destroy(&one)
	return r
}
