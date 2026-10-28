package bigint

// BigInt <-> string in any base 2..36, and BigInt <-> f64. to_string returns an owned string (the
// caller frees it). from_string parses a plain magnitude of digits with an optional leading sign; the
// engine strips 0x/0o/0b prefixes and separators before calling (matching how QuickJS feeds a clean
// buffer to js_bigint_from_string). The digit chunking mirrors numconv: pack many base-R digits into
// one limb before the big multiply, so parsing a million-digit number stays close to linear.

import "base:intrinsics"

@(private)
digit_chars := "0123456789abcdefghijklmnopqrstuvwxyz"

// Largest power of `radix` that fits in a u32, and how many digits that is.
@(private)
radix_chunk :: proc(radix: u32) -> (base: Limb, digits: int) {
	b: u64 = 1
	d := 0
	for {
		nb := b * u64(radix)
		if nb > u64(max(Limb)) {
			break
		}
		b = nb
		d += 1
	}
	return Limb(b), d
}

// Parse str as a base-`radix` integer (2..36). Leading '+'/'-' allowed. Returns ok=false if any
// character is not a valid digit (the engine turns that into NaN for Number()/BigInt()).
from_string :: proc(str: string, radix: int) -> (value: Int, ok: bool) {
	s := transmute([]u8)str
	i := 0
	neg := false
	if len(s) > 0 && (s[0] == '+' || s[0] == '-') {
		neg = s[0] == '-'
		i += 1
	}
	if i >= len(s) {
		return Int{}, false
	}

	r := Int{} // accumulator
	base_chunk, chunk_digits := radix_chunk(u32(radix))

	// Process in chunks to amortize the big multiply.
	pos := i
	for pos < len(s) {
		chunk: Limb = 0
		this_base: u64 = 1
		cnt := 0
		for cnt < chunk_digits && pos < len(s) {
			d := digit_value(s[pos])
			if d < 0 || d >= radix {
				destroy(&r)
				return Int{}, false
			}
			chunk = chunk * Limb(radix) + Limb(d)
			this_base *= u64(radix)
			pos += 1
			cnt += 1
		}
		_ = base_chunk
		// r = r * this_base + chunk
		mb := from_u64(this_base)
		t := mul(r, mb)
		destroy(&mb)
		destroy(&r)
		cv := from_u64(u64(chunk))
		r = add(t, cv)
		destroy(&t)
		destroy(&cv)
	}
	r.neg = neg && !is_zero(r)
	return r, true
}

@(private)
digit_value :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'z':
		return int(c - 'a') + 10
	case 'A' ..= 'Z':
		return int(c - 'A') + 10
	}
	return -1
}

// Convert to a base-`radix` string (2..36). Owned result; caller deletes it.
to_string :: proc(a: Int, radix: int) -> string {
	if is_zero(a) {
		return clone_string("0")
	}

	// Collect digits least-significant first by repeated division by the largest chunk base.
	base_chunk, chunk_digits := radix_chunk(u32(radix))
	tmp := clone(a)
	tmp.neg = false
	out: [dynamic]u8

	for !is_zero(tmp) {
		qmag, rmag := mag_divmod_1(tmp.mag, base_chunk)
		rem_val: u64 = len(rmag) > 0 ? u64(rmag[0]) : 0
		delete(rmag)
		destroy(&tmp)
		tmp = norm(false, qmag)

		// emit chunk_digits digits of rem_val (least significant first), but only pad with leading
		// zeros when there are more chunks to come.
		for _ in 0 ..< chunk_digits {
			append(&out, digit_chars[rem_val % u64(radix)])
			rem_val /= u64(radix)
			if is_zero(tmp) && rem_val == 0 {
				break
			}
		}
	}
	destroy(&tmp)

	// Now `out` holds the digits least-significant first. Build the final string (reversed) with sign.
	n := len(out)
	total := n + (a.neg ? 1 : 0)
	buf := make([]u8, total)
	j := 0
	if a.neg {
		buf[0] = '-'
		j = 1
	}
	for k in 0 ..< n {
		buf[j + k] = out[n - 1 - k]
	}
	delete(out)
	return string(buf)
}

@(private)
clone_string :: proc(s: string) -> string {
	b := make([]u8, len(s))
	copy(b, transmute([]u8)s)
	return string(b)
}

// --- f64 conversion ---

// BigInt(n) from an integer-valued f64 (the engine checks finiteness and integrality first).
from_f64 :: proc(d: f64) -> Int {
	bits := transmute(u64)d
	neg := bits >> 63 != 0
	exp := int((bits >> 52) & 0x7ff)
	mant := bits & ((u64(1) << 52) - 1)
	if exp == 0 && mant == 0 {
		return Int{}
	}
	if exp == 0 {
		// subnormal: |d| < 1, not an integer unless 0 (caller guards); treat as 0.
		return Int{}
	}
	mant |= u64(1) << 52
	e := exp - 1075 // value = mant * 2^e
	base := from_u64(mant)
	defer destroy(&base)
	r: Int
	if e >= 0 {
		r = shl(base, uint(e))
	} else {
		r = shr(base, uint(-e)) // mant is an integer; for integral d, -e <= 52 and low bits are zero
	}
	r.neg = neg && !is_zero(r)
	return r
}

// Round to the nearest f64 (ties to even), matching Number(bigint). Returns +/-Inf on overflow.
to_f64 :: proc(a: Int) -> f64 {
	if is_zero(a) {
		return 0
	}
	// Bit length of the magnitude.
	top := a.mag[len(a.mag) - 1]
	topbits := 32 - int(intrinsics.count_leading_zeros(top))
	nbits := (len(a.mag) - 1) * LIMB_BITS + topbits

	if nbits > 1024 {
		return a.neg ? neg_inf() : pos_inf()
	}

	// Gather the top 54 bits (53 for the mantissa + 1 round bit) plus a sticky bit.
	// Build value = mant * 2^shift, round to 53 significant bits.
	// Extract the top 53 bits and whether anything below is set (sticky).
	want := 53
	// index of the highest set bit (0-based)
	hi := nbits - 1
	m: u64 = 0
	// take bits hi down to hi-52
	for k in 0 ..< want {
		bit := hi - k
		if bit < 0 {
			m <<= 1
			continue
		}
		m = (m << 1) | u64(get_bit(a.mag, bit))
	}
	// round bit and sticky
	round_bit := 0
	sticky := false
	rb := hi - want
	if rb >= 0 {
		round_bit = int(get_bit(a.mag, rb))
		for bit := rb - 1; bit >= 0; bit -= 1 {
			if get_bit(a.mag, bit) == 1 {
				sticky = true
				break
			}
		}
	}
	// round to nearest, ties to even
	if round_bit == 1 && (sticky || (m & 1) == 1) {
		m += 1
		if m == (u64(1) << 53) {
			m >>= 1
			hi += 1 // mantissa overflow bumps the exponent
		}
	}

	exp := hi // unbiased exponent of the leading bit
	if exp > 1023 {
		return a.neg ? neg_inf() : pos_inf()
	}
	// assemble: 1.xxxx * 2^exp, mantissa m has 53 bits with the implicit leading 1 at bit 52.
	frac := m & ((u64(1) << 52) - 1)
	bexp := u64(exp + 1023)
	bits := (bexp << 52) | frac
	if a.neg {
		bits |= u64(1) << 63
	}
	return transmute(f64)bits
}

@(private)
get_bit :: proc(mag: []Limb, bit: int) -> int {
	limb := bit / LIMB_BITS
	b := uint(bit % LIMB_BITS)
	if limb >= len(mag) {
		return 0
	}
	return int((mag[limb] >> b) & 1)
}

@(private)
pos_inf :: proc() -> f64 { return transmute(f64)u64(0x7ff0_0000_0000_0000) }
@(private)
neg_inf :: proc() -> f64 { return transmute(f64)u64(0xfff0_0000_0000_0000) }
