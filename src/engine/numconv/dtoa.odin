package numconv

// Exact float64 <-> string conversion, ported from QuickJS-ng's dtoa.c (Fabrice Bellard, MIT).
// The port is deliberate rather than mechanical: it keeps Bellard's bignum algorithm, which gives
// the *shortest round-tripping* decimal and correctly-rounded parsing, so the strings this package
// produces are identical to QuickJS for every finite f64, every radix 2..36 and every format
// (free / fixed significant digits / fixed fractional digits). The scratch bignums live on fixed
// stack arrays (JSDTOATempMem / JSATODTempMem in the original): no allocation happens here, which
// is what lets the package build for freestanding_wasm32 without an allocator.
//
// C constructs mapped to Odin:
//   - clz32/clz64/ctz32  -> intrinsics.count_leading_zeros / count_trailing_zeros
//   - float64_as_uint64  -> transmute
//   - the mpb_t flexible-array struct -> Mpb, a fixed array sized to the worst case
//
// The public surface (format_f64, parse_f64, radix integer helpers) is in numconv.odin.

import "base:intrinsics"

Limb :: u32
Slimb :: i32
Dlimb :: u64

LIMB_BITS :: 32
LIMB_DIGITS :: 9
RADIX_MAX :: 36

// Worst-case bignum lengths from the original (~ 2^(1072+53)*36^100 for dtoa; < 36^100 for a mantissa).
DBIGNUM_LEN_MAX :: 52
MANT_LEN_MAX :: 18

MAX_DIGITS :: 101 // JS_DTOA_MAX_DIGITS: maximum digits for fixed and frac formats

// Format selects how many digits appear. Matches JS_DTOA_FORMAT_*.
Format :: enum i32 {
	Free  = 0, // as many digits as needed for a round trip
	Fixed = 1, // exactly n_digits significant digits (1..MAX_DIGITS)
	Frac  = 2, // [-]dd.dd with n_digits fractional digits (0..MAX_DIGITS)
}

// Exponent policy, matches JS_DTOA_EXP_*.
Exp_Mode :: enum i32 {
	Auto     = 0,
	Enabled  = 1,
	Disabled = 2,
}

// A free-standing bignum: sum(i, tab[i] * 2^(LIMB_BITS*i)). len >= 1.
// Sized for the worst case so it lives on the stack with the scratch memory.
Mpb :: struct {
	len: int,
	tab: [DBIGNUM_LEN_MAX + 2]Limb, // +2 for the carry room mpb_shr_round can need
}

Rnd :: enum {
	Nearest_Even, // JS_RNDN
	Nearest_Away, // JS_RNDNA
	Zero,         // JS_RNDZ
}

@(private = "file")
clz32 :: #force_inline proc(a: u32) -> int {
	return int(intrinsics.count_leading_zeros(a))
}

@(private = "file")
clz64 :: #force_inline proc(a: u64) -> int {
	return int(intrinsics.count_leading_zeros(a))
}

@(private = "file")
ctz32 :: #force_inline proc(a: u32) -> int {
	return int(intrinsics.count_trailing_zeros(a))
}

@(private = "file")
min_int :: #force_inline proc(a, b: int) -> int {
	return a < b ? a : b
}

@(private = "file")
max_int :: #force_inline proc(a, b: int) -> int {
	return a > b ? a : b
}

// tab[0..n) += b, returns the high carry.
@(private = "file")
mp_add_ui :: proc(tab: [^]Limb, b: Limb, n: int) -> Limb {
	k := b
	for i in 0 ..< n {
		if k == 0 {
			break
		}
		a := tab[i] + k
		k = a < k ? 1 : 0
		tab[i] = a
	}
	return k
}

// tabr[] = taba[] * b + l, returns the high carry.
@(private = "file")
mp_mul1 :: proc(tabr, taba: [^]Limb, n: int, b, l_in: Limb) -> Limb {
	l := Dlimb(l_in)
	for i in 0 ..< n {
		t := Dlimb(taba[i]) * Dlimb(b) + l
		tabr[i] = Limb(t)
		l = t >> LIMB_BITS
	}
	return Limb(l)
}

// WARNING: d must be >= 2^(LIMB_BITS-1).
@(private = "file")
udiv1norm_init :: proc(d: Limb) -> Limb {
	a1 := ~d // -d - 1 in two's complement
	a0 := ~Limb(0) // -1
	return Limb(((Dlimb(a1) << LIMB_BITS) | Dlimb(a0)) / Dlimb(d))
}

// Quotient of (a1*2^LIMB_BITS + a0) / d with 0 <= a1 < d, remainder in pr.
@(private = "file")
udiv1norm :: proc(pr: ^Limb, a1, a0, d, d_inv: Limb) -> Limb {
	n1m := Limb(Slimb(a0) >> (LIMB_BITS - 1))
	n_adj := a0 + (n1m & d)
	a := Dlimb(d_inv) * Dlimb(a1 - n1m) + Dlimb(n_adj)
	q := Limb(a >> LIMB_BITS) + a1
	a = (Dlimb(a1) << LIMB_BITS) | Dlimb(a0)
	a = a - Dlimb(q) * Dlimb(d) - Dlimb(d)
	ah := Limb(a >> LIMB_BITS)
	q += 1 + ah
	r := Limb(a) + (ah & d)
	pr^ = r
	return q
}

// tabr[] = taba[] / b, returns the remainder.
@(private = "file")
mp_div1 :: proc(tabr, taba: [^]Limb, n: int, b, r_in: Limb) -> Limb {
	r := r_in
	for i := n - 1; i >= 0; i -= 1 {
		a1 := (Dlimb(r) << LIMB_BITS) | Dlimb(taba[i])
		tabr[i] = Limb(a1 / Dlimb(b))
		r = Limb(a1 % Dlimb(b))
	}
	return r
}

// r = (a + high*B^n) >> shift, returns the dropped remainder. 1 <= shift <= LIMB_BITS-1.
@(private = "file")
mp_shr :: proc(tab_r, tab: [^]Limb, n: int, shift: int, high: Limb) -> Limb {
	l := high
	for i := n - 1; i >= 0; i -= 1 {
		a := tab[i]
		tab_r[i] = (a >> uint(shift)) | (l << uint(LIMB_BITS - shift))
		l = a
	}
	return l & ((Limb(1) << uint(shift)) - 1)
}

// r = (a << shift) + low. 1 <= shift <= LIMB_BITS-1.
@(private = "file")
mp_shl :: proc(tab_r, tab: [^]Limb, n: int, shift: int, low: Limb) -> Limb {
	l := low
	for i in 0 ..< n {
		a := tab[i]
		tab_r[i] = (a << uint(shift)) | l
		l = a >> uint(LIMB_BITS - shift)
	}
	return l
}

@(private = "file")
mp_div1norm :: proc(tabr, taba: [^]Limb, n: int, b, r_in, b_inv: Limb, shift: int) -> Limb {
	r := r_in
	if shift != 0 {
		r = (r << uint(shift)) | mp_shl(tabr, taba, n, shift, 0)
	}
	for i := n - 1; i >= 0; i -= 1 {
		tabr[i] = udiv1norm(&r, r, taba[i], b, b_inv)
	}
	r >>= uint(shift)
	return r
}

@(private = "file")
mpb_renorm :: proc(r: ^Mpb) {
	for r.len > 1 && r.tab[r.len - 1] == 0 {
		r.len -= 1
	}
}

@(private = "file")
pow5_table := [17]u32 {
	0x00000005, 0x00000019, 0x0000007d, 0x00000271,
	0x00000c35, 0x00003d09, 0x0001312d, 0x0005f5e1,
	0x001dcd65, 0x009502f9, 0x02e90edd, 0x0e8d4a51,
	0x48c27395, 0x6bcc41e9, 0x1afd498d, 0x86f26fc1,
	0xa2bc2ec5,
}

@(private = "file")
pow5h_table := [4]u8{0x01, 0x07, 0x23, 0xb1}

@(private = "file")
pow5_inv_table := [13]u32 {
	0x99999999, 0x47ae147a, 0x0624dd2f, 0xa36e2eb1,
	0x4f8b588e, 0x0c6f7a0b, 0xad7f29ab, 0x5798ee23,
	0x12e0be82, 0xb7cdfd9d, 0x5fd7fe17, 0x19799812,
	0xc25c2684,
}

// a^b with the pow5/pow10 fast path.
@(private = "file")
pow_ui :: proc(a: u32, b: u32) -> u64 {
	if b == 0 {
		return 1
	}
	if b == 1 {
		return u64(a)
	}
	if (a == 5 || a == 10) && b <= 17 {
		r := u64(pow5_table[b - 1])
		if b >= 14 {
			r |= u64(pow5h_table[b - 14]) << 32
		}
		if a == 10 {
			r <<= uint(b)
		}
		return r
	}
	r := u64(a)
	n_bits := 32 - clz32(b)
	for i := n_bits - 2; i >= 0; i -= 1 {
		r *= r
		if (b >> uint(i)) & 1 != 0 {
			r *= u64(a)
		}
	}
	return r
}

@(private = "file")
pow_ui_inv :: proc(pr_inv: ^u32, pshift: ^int, a: u32, b: u32) -> u32 {
	r, r_inv: u32
	shift: int
	if a == 5 && b >= 1 && b <= 13 {
		r = pow5_table[b - 1]
		shift = clz32(r)
		r <<= uint(shift)
		r_inv = pow5_inv_table[b - 1]
	} else {
		r = u32(pow_ui(a, b))
		shift = clz32(r)
		r <<= uint(shift)
		r_inv = udiv1norm_init(r)
	}
	pshift^ = shift
	pr_inv^ = r_inv
	return r
}

@(private = "file")
mpb_get_bit :: proc(r: ^Mpb, k_in: int) -> Limb {
	l := k_in / LIMB_BITS
	k := k_in & (LIMB_BITS - 1)
	if l >= r.len {
		return 0
	}
	return (r.tab[l] >> uint(k)) & 1
}

// round(r / 2^shift). shift can be negative (a left shift).
@(private = "file")
mpb_shr_round :: proc(r: ^Mpb, shift_in: int, rnd_mode: Rnd) {
	shift := shift_in
	if shift == 0 {
		return
	}
	if shift < 0 {
		shift = -shift
		l := shift / LIMB_BITS
		shift &= (LIMB_BITS - 1)
		if shift != 0 {
			r.tab[r.len] = mp_shl(&r.tab[0], &r.tab[0], r.len, shift, 0)
			r.len += 1
			mpb_renorm(r)
		}
		if l > 0 {
			for i := r.len - 1; i >= 0; i -= 1 {
				r.tab[i + l] = r.tab[i]
			}
			for i in 0 ..< l {
				r.tab[i] = 0
			}
			r.len += l
		}
	} else {
		add_one: Limb
		switch rnd_mode {
		case .Zero:
			add_one = 0
		case .Nearest_Even, .Nearest_Away:
			bit1 := mpb_get_bit(r, shift - 1)
			if bit1 != 0 {
				bit2: Limb
				if rnd_mode == .Nearest_Away {
					bit2 = 1
				} else {
					bit2 = 0
					if shift >= 2 {
						k := shift - 1
						l := k / LIMB_BITS
						k &= (LIMB_BITS - 1)
						for i in 0 ..< min_int(l, r.len) {
							bit2 |= r.tab[i]
						}
						if l < r.len {
							bit2 |= r.tab[l] & ((Limb(1) << uint(k)) - 1)
						}
					}
				}
				if bit2 != 0 {
					add_one = 1
				} else {
					add_one = mpb_get_bit(r, shift) // round to even
				}
			} else {
				add_one = 0
			}
		}

		l := shift / LIMB_BITS
		shift &= (LIMB_BITS - 1)
		if l >= r.len {
			r.len = 1
			r.tab[0] = add_one
		} else {
			if l > 0 {
				r.len -= l
				for i in 0 ..< r.len {
					r.tab[i] = r.tab[i + l]
				}
			}
			if shift != 0 {
				mp_shr(&r.tab[0], &r.tab[0], r.len, shift, 0)
				mpb_renorm(r)
			}
			if add_one != 0 {
				a := mp_add_ui(&r.tab[0], 1, r.len)
				if a != 0 {
					r.tab[r.len] = a
					r.len += 1
				}
			}
		}
	}
}

@(private = "file")
mpb_cmp :: proc(a, b: ^Mpb) -> int {
	if a.len < b.len {
		return -1
	} else if a.len > b.len {
		return 1
	}
	for i := a.len - 1; i >= 0; i -= 1 {
		if a.tab[i] != b.tab[i] {
			return a.tab[i] < b.tab[i] ? -1 : 1
		}
	}
	return 0
}

@(private = "file")
mpb_set_u64 :: proc(r: ^Mpb, m: u64) {
	r.tab[0] = Limb(m)
	r.tab[1] = Limb(m >> LIMB_BITS)
	r.len = r.tab[1] == 0 ? 1 : 2
}

@(private = "file")
mpb_get_u64 :: proc(r: ^Mpb) -> u64 {
	if r.len == 1 {
		return u64(r.tab[0])
	}
	return u64(r.tab[0]) | (u64(r.tab[1]) << LIMB_BITS)
}

// Position of the first non-zero bit, or -1 if zero.
@(private = "file")
mpb_floor_log2 :: proc(a: ^Mpb) -> int {
	v := a.tab[a.len - 1]
	if v == 0 {
		return -1
	}
	return a.len * LIMB_BITS - 1 - clz32(v)
}

MUL_LOG2_RADIX_BASE_LOG2 :: 24

@(private = "file")
mul_log2_radix_table := [RADIX_MAX - 1]u32 {
	0x000000, 0xa1849d, 0x000000, 0x6e40d2,
	0x6308c9, 0x5b3065, 0x000000, 0x50c24e,
	0x4d104d, 0x4a0027, 0x4768ce, 0x452e54,
	0x433d00, 0x418677, 0x000000, 0x3ea16b,
	0x3d645a, 0x3c43c2, 0x3b3b9a, 0x3a4899,
	0x39680b, 0x3897b3, 0x37d5af, 0x372069,
	0x367686, 0x35d6df, 0x354072, 0x34b261,
	0x342bea, 0x33ac62, 0x000000, 0x32bfd9,
	0x3251dd, 0x31e8d6, 0x318465,
}

// floor(a / log2(radix)) for -2048 <= a <= 2047.
@(private = "file")
mul_log2_radix :: proc(a_in: int, radix: int) -> int {
	a := a_in
	if (radix & (radix - 1)) == 0 {
		radix_bits := 31 - clz32(u32(radix))
		if a < 0 {
			a -= radix_bits - 1
		}
		return a / radix_bits
	} else {
		mult := int(mul_log2_radix_table[radix - 2])
		return int((i64(a) * i64(mult)) >> MUL_LOG2_RADIX_BASE_LOG2)
	}
}

@(private = "file")
u32toa_len :: proc(buf: [^]u8, n_in: u32, length: int) {
	n := n_in
	for i := length - 1; i >= 0; i -= 1 {
		digit := n % 10
		n /= 10
		buf[i] = u8(digit) + '0'
	}
}

// For power-of-two radixes. len >= 1.
@(private = "file")
u64toa_bin_len :: proc(buf: [^]u8, n_in: u64, radix_bits: uint, length: int) {
	n := n_in
	mask := (u64(1) << radix_bits) - 1
	for i := length - 1; i >= 0; i -= 1 {
		digit := int(n & mask)
		n >>= radix_bits
		if digit < 10 {
			digit += '0'
		} else {
			digit += 'a' - 10
		}
		buf[i] = u8(digit)
	}
}

// len >= 1, 2 <= radix <= 36.
@(private = "file")
limb_to_a :: proc(buf: [^]u8, n_in: Limb, radix: Limb, length: int) {
	n := n_in
	if radix == 10 {
		u32toa_len(buf, u32(n), length)
	} else {
		for i := length - 1; i >= 0; i -= 1 {
			digit := int(n % radix)
			n /= radix
			if digit < 10 {
				digit += '0'
			} else {
				digit += 'a' - 10
			}
			buf[i] = u8(digit)
		}
	}
}

@(private = "file")
digits_per_limb_table := [RADIX_MAX - 1]u8 {
	32, 20, 16, 13, 12, 11, 10, 10, 9, 9, 8, 8, 8, 8, 8, 7, 7, 7, 7, 7, 7, 7, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
}

@(private = "file")
radix_base_table := [RADIX_MAX - 1]u32 {
	0x00000000, 0xcfd41b91, 0x00000000, 0x48c27395,
	0x81bf1000, 0x75db9c97, 0x40000000, 0xcfd41b91,
	0x3b9aca00, 0x8c8b6d2b, 0x19a10000, 0x309f1021,
	0x57f6c100, 0x98c29b81, 0x00000000, 0x18754571,
	0x247dbc80, 0x3547667b, 0x4c4b4000, 0x6b5a6e1d,
	0x94ace180, 0xcaf18367, 0x0b640000, 0x0e8d4a51,
	0x1269ae40, 0x17179149, 0x1cb91000, 0x23744899,
	0x2b73a840, 0x34e63b41, 0x40000000, 0x4cfa3cc1,
	0x5c13d840, 0x6d91b519, 0x81bf1000,
}

@(private = "file")
dtoa_max_digits_table := [RADIX_MAX - 1]u8 {
	54, 35, 28, 24, 22, 20, 19, 18, 17, 17, 16, 16, 15, 15, 15, 14, 14, 14, 14, 14, 13, 13, 13, 13, 13, 13, 13, 12, 12, 12, 12, 12, 12, 12, 12,
}

@(private = "file")
atod_max_digits_table := [RADIX_MAX - 1]u8 {
	64, 80, 32, 55, 49, 45, 21, 40, 38, 37, 35, 34, 33, 32, 16, 31, 30, 30, 29, 29, 28, 28, 27, 27, 27, 26, 26, 26, 26, 25, 12, 25, 25, 24, 24,
}

@(private = "file")
max_exponent := [RADIX_MAX - 1]i16 {
	1024, 647, 512, 442, 397, 365, 342, 324,
	309, 297, 286, 277, 269, 263, 256, 251,
	246, 242, 237, 234, 230, 227, 224, 221,
	218, 216, 214, 211, 209, 207, 205, 203,
	202, 200, 199,
}

@(private = "file")
min_exponent := [RADIX_MAX - 1]i16 {
	-1075, -679, -538, -463, -416, -383, -359, -340,
	-324, -311, -300, -291, -283, -276, -269, -263,
	-258, -254, -249, -245, -242, -238, -235, -232,
	-229, -227, -224, -222, -220, -217, -215, -214,
	-212, -210, -208,
}

// Write the digits of 'a' into buf, inserting a dot at dot_pos. 'a' is consumed.
@(private = "file")
output_digits :: proc(buf: [^]u8, a: ^Mpb, radix: int, n_digits1: int, dot_pos: int) -> int {
	n_digits := n_digits1
	radix_bits := 0
	if (radix & (radix - 1)) == 0 {
		radix_bits = 31 - clz32(u32(radix))
	}
	digits_per_limb := int(digits_per_limb_table[radix - 2])
	if radix_bits != 0 {
		for {
			n := min_int(n_digits, digits_per_limb)
			n_digits -= n
			u64toa_bin_len(buf[n_digits:], u64(a.tab[0]), uint(radix_bits), n)
			if n_digits == 0 {
				break
			}
			mpb_shr_round(a, digits_per_limb * radix_bits, .Zero)
		}
	} else {
		for n_digits != 0 {
			n := min_int(n_digits, digits_per_limb)
			n_digits -= n
			r := mp_div1(&a.tab[0], &a.tab[0], a.len, radix_base_table[radix - 2], 0)
			mpb_renorm(a)
			limb_to_a(buf[n_digits:], r, Limb(radix), n)
		}
	}

	length := n_digits1
	if dot_pos != n_digits1 {
		// Shift the fractional digits one byte right to make room for the dot (overlapping, so copy
		// from the high end down, as memmove would).
		for k := n_digits1 - dot_pos - 1; k >= 0; k -= 1 {
			buf[dot_pos + 1 + k] = buf[dot_pos + k]
		}
		buf[dot_pos] = '.'
		length += 1
	}
	return length
}

// a = a * (radix1*2^radix_shift)^f * 2^-e_offset, returns e_offset. f may be negative.
@(private = "file")
mul_pow :: proc(a: ^Mpb, radix1: int, radix_shift: int, f_in: int, is_int: bool, e: int) -> int {
	f := f_in
	e_offset := -f * radix_shift
	if radix1 != 1 {
		d := int(digits_per_limb_table[radix1 - 2])
		if f >= 0 {
			b: Limb = 0
			n0 := 0
			for f != 0 {
				n := min_int(f, d)
				if n != n0 {
					b = Limb(pow_ui(u32(radix1), u32(n)))
					n0 = n
				}
				h := mp_mul1(&a.tab[0], &a.tab[0], a.len, b, 0)
				if h != 0 {
					a.tab[a.len] = h
					a.len += 1
				}
				f -= n
			}
		} else {
			f = -f
			l := (f + d - 1) / d
			e_offset += l * LIMB_BITS
			extra_bits: int
			if !is_int {
				extra_bits = max_int(e - mpb_floor_log2(a), 0)
			} else {
				extra_bits = max_int(2 + e - e_offset, 0)
			}
			e_offset += extra_bits
			mpb_shr_round(a, -(l * LIMB_BITS + extra_bits), .Zero)

			b: Limb = 0
			b_inv: Limb = 0
			shift := 0
			n0 := 0
			rem: Limb = 0
			for f != 0 {
				n := min_int(f, d)
				if n != n0 {
					b = pow_ui_inv(&b_inv, &shift, u32(radix1), u32(n))
					n0 = n
				}
				r := mp_div1norm(&a.tab[0], &a.tab[0], a.len, b, 0, b_inv, shift)
				rem |= r
				mpb_renorm(a)
				f -= n
			}
			a.tab[0] |= (rem != 0) ? 1 : 0
		}
	}
	return e_offset
}

// tmp1 = round(m * 2^e * radix^f).
@(private = "file")
mul_pow_round :: proc(tmp1: ^Mpb, m: u64, e: int, radix1, radix_shift, f: int, rnd_mode: Rnd) {
	mpb_set_u64(tmp1, m)
	e_offset := mul_pow(tmp1, radix1, radix_shift, f, true, e)
	mpb_shr_round(tmp1, -e + e_offset, rnd_mode)
}

// round(a * 2^e_offset) as a float64 mantissa with its exponent. 'a' is consumed.
@(private = "file")
round_to_d :: proc(pe: ^int, a: ^Mpb, e_offset: int, rnd_mode: Rnd) -> u64 {
	e: int
	m: u64
	if a.tab[0] == 0 && a.len == 1 {
		m = 0
		e = 0
	} else {
		e = mpb_floor_log2(a) + 1 - e_offset
		prec1 := 53
		e_min := -1021
		prec := prec1
		if e < e_min {
			prec = prec1 - (e_min - e)
		}
		mpb_shr_round(a, e + e_offset - prec, rnd_mode)
		m = mpb_get_u64(a)
		m <<= uint(53 - prec)
		if m >= u64(1) << 53 {
			m >>= 1
			e += 1
		}
	}
	pe^ = e
	return m
}

@(private = "file")
mul_pow_round_to_d :: proc(pe: ^int, a: ^Mpb, radix1, radix_shift, f: int, rnd_mode: Rnd) -> u64 {
	e_offset := mul_pow(a, radix1, radix_shift, f, false, 55)
	return round_to_d(pe, a, e_offset, rnd_mode)
}

// Maximum string length a dtoa call may need (sign, digits, dot, exponent, NaN/Infinity).
dtoa_max_len :: proc(d: f64, radix: int, n_digits: int, format: Format, exp_mode: Exp_Mode) -> int {
	n, e: int
	a: u64
	if format != .Frac {
		if format == .Free {
			n = int(dtoa_max_digits_table[radix - 2])
		} else {
			n = n_digits
		}
		if exp_mode == .Disabled {
			a = transmute(u64)d
			e = int((a >> 52) & 0x7ff)
			if e == 0x7ff {
				n = 0
			} else {
				e -= 1023
				n += 10 + abs(mul_log2_radix(e - 1, radix))
			}
		} else {
			n += 1 + 1 + 6
		}
	} else {
		a = transmute(u64)d
		e = int((a >> 52) & 0x7ff)
		if e == 0x7ff {
			n = 0
		} else {
			e -= 1023
			if e < 0 {
				n = 1
			} else {
				n = 2 + mul_log2_radix(e - 1, radix)
			}
			n += 1 + 1 + 1 + n_digits
		}
	}
	return max_int(n, 9)
}

// Write d into buf (which must hold dtoa_max_len + 1 bytes) and return the written length.
// This is the exact equivalent of QuickJS js_dtoa. radix 2..36; radix != 10 requires Format.Free.
dtoa :: proc(buf: [^]u8, d: f64, radix: int, n_digits: int, format: Format, exp_mode: Exp_Mode, minus_zero := false) -> int {
	tmp1: Mpb
	mant_max: Mpb

	radix_shift := ctz32(u32(radix))
	radix1 := radix >> uint(radix_shift)
	a := transmute(u64)d
	sgn := a >> 63
	e := int((a >> 52) & 0x7ff)
	m := a & ((u64(1) << 52) - 1)
	q := 0
	P, E: int

	write :: #force_inline proc(buf: [^]u8, q: ^int, s: string) {
		for c in transmute([]u8)s {
			buf[q^] = c
			q^ += 1
		}
	}

	if e == 0x7ff {
		if m == 0 {
			if sgn != 0 {
				buf[q] = '-';q += 1
			}
			write(buf, &q, "Infinity")
		} else {
			write(buf, &q, "NaN")
		}
		buf[q] = 0
		return q
	} else if e == 0 {
		if m == 0 {
			tmp1.len = 1
			tmp1.tab[0] = 0
			E = 1
			if format == .Free {
				P = 1
			} else if format == .Frac {
				P = n_digits + 1
			} else {
				P = n_digits
			}
			if sgn != 0 && minus_zero {
				buf[q] = '-';q += 1
			}
			return dtoa_output(buf, q, &tmp1, &mant_max, radix, radix1, radix_shift, P, E, n_digits, format, exp_mode)
		}
		// denormal: normalise
		l := clz64(m) - 11
		e -= l - 1
		m <<= uint(l)
	} else {
		m |= u64(1) << 52
	}
	if sgn != 0 {
		buf[q] = '-';q += 1
	}
	e -= 1022 // remove the bias: d = 2^(e-53)*m

	// Fast path for small exact integers in free format.
	if format == .Free && e >= 1 && e <= 53 && (m & ((u64(1) << uint(53 - e)) - 1)) == 0 && exp_mode != .Enabled {
		m >>= uint(53 - e)
		q += u64toa_radix(buf[q:], m, radix)
		buf[q] = 0
		return q
	}

	E = 1 + mul_log2_radix(e - 1, radix)

	if format == .Free {
		P_max := int(dtoa_max_digits_table[radix - 2])
		E0 := E
		E_found := 0
		P_found := 0
		mant_found: u64 = 0
		mant: u64
		P = P_max
		for {
			mant_max1 := pow_ui(u32(radix), u32(P))
			E = E0
			for {
				mul_pow_round(&tmp1, m, e - 53, radix1, radix_shift, P - E, .Nearest_Even)
				mant = mpb_get_u64(&tmp1)
				if mant < mant_max1 {
					break
				}
				E += 1
			}
			for (mant % u64(radix)) == 0 {
				mant /= u64(radix)
				P -= 1
			}
			found := false
			if P_found == 0 {
				found = true
			} else {
				mpb_set_u64(&tmp1, mant)
				e1: int
				m1 := mul_pow_round_to_d(&e1, &tmp1, radix1, radix_shift, E - P, .Nearest_Even)
				if m1 == m && e1 == e {
					found = true
				}
			}
			if found {
				P_found = P
				E_found = E
				mant_found = mant
				if P == 1 {
					break
				}
				P -= 1
			} else {
				break
			}
		}
		P = P_found
		E = E_found
		mpb_set_u64(&tmp1, mant_found)
	} else if format == .Frac {
		mul_pow_round(&tmp1, m, e - 53, radix1, radix_shift, n_digits, .Nearest_Away)
		length := output_digits(buf[q:], &tmp1, radix, max_int(E + 1, 1) + n_digits, max_int(E + 1, 1))
		if buf[q] == '0' && length >= 2 && buf[q + 1] != '.' {
			length -= 1
			for k in 0 ..< length { // overlapping left shift by one byte
				buf[q + k] = buf[q + k + 1]
			}
		}
		q += length
		buf[q] = 0
		return q
	} else {
		P = n_digits
		mant_max.len = 1
		mant_max.tab[0] = 1
		pow_shift := mul_pow(&mant_max, radix1, radix_shift, P, false, 0)
		mpb_shr_round(&mant_max, pow_shift, .Zero)
		for {
			mul_pow_round(&tmp1, m, e - 53, radix1, radix_shift, P - E, .Nearest_Away)
			if mpb_cmp(&tmp1, &mant_max) < 0 {
				break
			}
			E += 1
		}
	}
	return dtoa_output(buf, q, &tmp1, &mant_max, radix, radix1, radix_shift, P, E, n_digits, format, exp_mode)
}

// The shared tail (label `output:` in the original): lay out digits, dot and exponent.
@(private = "file")
dtoa_output :: proc(buf: [^]u8, q_in: int, tmp1, mant_max: ^Mpb, radix, radix1, radix_shift, P, E_in, n_digits: int, format: Format, exp_mode: Exp_Mode) -> int {
	q := q_in
	E := E_in
	E_max: int
	if format == .Fixed {
		E_max = n_digits
	} else {
		E_max = int(dtoa_max_digits_table[radix - 2]) + 4
	}
	if exp_mode == .Enabled || (exp_mode == .Auto && (E <= -6 || E > E_max)) {
		q += output_digits(buf[q:], tmp1, radix, P, 1)
		E -= 1
		if radix == 10 {
			buf[q] = 'e';q += 1
		} else if radix1 == 1 && radix_shift <= 4 {
			E *= radix_shift
			buf[q] = 'p';q += 1
		} else {
			buf[q] = '@';q += 1
		}
		if E < 0 {
			buf[q] = '-';q += 1
			E = -E
		} else {
			buf[q] = '+';q += 1
		}
		q += u32toa(buf[q:], u32(E))
	} else if E <= 0 {
		buf[q] = '0';q += 1
		buf[q] = '.';q += 1
		for _ in 0 ..< -E {
			buf[q] = '0';q += 1
		}
		q += output_digits(buf[q:], tmp1, radix, P, P)
	} else {
		q += output_digits(buf[q:], tmp1, radix, P, min_int(P, E))
		for _ in 0 ..< E - P {
			buf[q] = '0';q += 1
		}
	}
	buf[q] = 0
	return q
}

// --- atod ---

@(private = "file")
to_digit :: proc(c: int) -> int {
	if c >= '0' && c <= '9' {
		return c - '0'
	} else if c >= 'A' && c <= 'Z' {
		return c - 'A' + 10
	} else if c >= 'a' && c <= 'z' {
		return c - 'a' + 10
	}
	return 36
}

// r = r * radix_base + a. radix_base == 0 means 2^32.
@(private = "file")
mpb_mul1_base :: proc(r: ^Mpb, radix_base: Limb, a: Limb) {
	if r.tab[0] == 0 && r.len == 1 {
		r.tab[0] = a
	} else {
		if radix_base == 0 {
			for i := r.len; i >= 0; i -= 1 {
				r.tab[i + 1] = r.tab[i]
			}
			r.tab[0] = a
		} else {
			r.tab[r.len] = mp_mul1(&r.tab[0], &r.tab[0], r.len, radix_base, a)
		}
		r.len += 1
		mpb_renorm(r)
	}
}

// Flags for atod, matching JS_ATOD_*.
Atod_Flags :: bit_set[Atod_Flag;u32]
Atod_Flag :: enum u32 {
	Int_Only,            // no dot, no exponent
	Accept_Bin_Oct,      // 0o, 0b prefixes when radix == 0
	Accept_Legacy_Octal, // leading 0 as octal (Annex B)
	Accept_Underscores,  // _ between digits
}

// Parse a number from str, exactly like QuickJS js_atod. Returns the value, the number of bytes
// consumed (the cursor position, as the original's *pnext), and ok=false on a parse failure (the
// value is then NaN, as QuickJS does; `consumed` still points past the sign as the C does). radix 0
// means "decide from the prefix / default 10".
atod :: proc(str: string, radix_in: int, flags: Atod_Flags) -> (value: f64, consumed: int, ok: bool) {
	tmp0: Mpb
	radix := radix_in
	NAN :: 0x7ff8_0000_0000_0000

	// We operate on bytes with an explicit cursor and a sentinel reader (0 past the end), as the C does
	// on a NUL-terminated string; 0 is never a digit nor a structural character, so the branches match.
	s := transmute([]u8)str
	at :: #force_inline proc(s: []u8, i: int) -> int {
		if i < 0 || i >= len(s) {
			return 0
		}
		return int(s[i])
	}

	p := 0
	p_start := 0
	is_neg := false
	if at(s, p) == '+' {
		p += 1
		p_start = p
	} else if at(s, p) == '-' {
		is_neg = true
		p += 1
		p_start = p
	} else {
		p_start = p
	}

	sep := (.Accept_Underscores in flags) ? int('_') : 256
	int_only := .Int_Only in flags

	// Prefix detection. `prefix_taken` tracks whether a 0x/0o/0b/legacy-octal prefix was consumed, so
	// the "there must be a digit after the prefix" guard only fires then (goto no_prefix otherwise).
	prefix_taken := false
	if at(s, p) == '0' {
		c1 := at(s, p + 1)
		if (c1 == 'x' || c1 == 'X') && (radix == 0 || radix == 16) {
			p += 2
			radix = 16
			prefix_taken = true
		} else if (c1 == 'o' || c1 == 'O') && radix == 0 && (.Accept_Bin_Oct in flags) {
			p += 2
			radix = 8
			prefix_taken = true
		} else if (c1 == 'b' || c1 == 'B') && radix == 0 && (.Accept_Bin_Oct in flags) {
			p += 2
			radix = 2
			prefix_taken = true
		} else if (c1 >= '0' && c1 <= '9') && radix == 0 && (.Accept_Legacy_Octal in flags) {
			sep = 256
			i := 1
			for at(s, p + i) >= '0' && at(s, p + i) <= '7' {
				i += 1
			}
			if at(s, p + i) != '8' && at(s, p + i) != '9' {
				p += 1
				radix = 8
				prefix_taken = true
			}
		}
		if prefix_taken {
			if to_digit(at(s, p)) >= radix {
				return transmute(f64)u64(NAN), p, false
			}
		}
	} else if !int_only {
		// Infinity (only reachable when no prefix path was taken, i.e. first char != '0').
		inf := "Infinity"
		matched := true
		for k in 0 ..< len(inf) {
			if at(s, p + k) != int(inf[k]) {
				matched = false
				break
			}
		}
		if matched {
			p += len(inf)
			a := u64(0x7ff) << 52
			a |= u64(is_neg) << 63
			return transmute(f64)a, p, true
		}
	}

	if radix == 0 {
		radix = 10
	}

	cur_limb: Limb = 0
	expn_offset := 0
	digit_count := 0
	limb_digit_count := 0
	max_digits := int(atod_max_digits_table[radix - 2])
	digits_per_limb := int(digits_per_limb_table[radix - 2])
	radix_base := radix_base_table[radix - 2]
	radix_shift := ctz32(u32(radix))
	radix1 := radix >> uint(radix_shift)
	radix_bits := radix1 == 1 ? radix_shift : 0

	tmp0.len = 1
	tmp0.tab[0] = 0
	extra_digits: Limb = 0
	pos := 0
	dot_pos := -1

	// skip leading zeros
	for {
		if at(s, p) == '.' && (p > p_start || to_digit(at(s, p + 1)) < radix) && !int_only {
			if at(s, p) == sep {
				return transmute(f64)u64(NAN), p, false
			}
			if dot_pos >= 0 {
				break
			}
			dot_pos = pos
			p += 1
		}
		if at(s, p) == sep && p > p_start && at(s, p + 1) == '0' {
			p += 1
		}
		if at(s, p) != '0' {
			break
		}
		p += 1
		pos += 1
	}

	sig_pos := pos
	for {
		if at(s, p) == '.' && (p > p_start || to_digit(at(s, p + 1)) < radix) && !int_only {
			if at(s, p) == sep {
				return transmute(f64)u64(NAN), p, false
			}
			if dot_pos >= 0 {
				break
			}
			dot_pos = pos
			p += 1
		}
		if at(s, p) == sep && p > p_start && to_digit(at(s, p + 1)) < radix {
			p += 1
		}
		c := to_digit(at(s, p))
		if c >= radix {
			break
		}
		p += 1
		pos += 1
		if digit_count < max_digits {
			cur_limb = cur_limb * Limb(radix) + Limb(c)
			limb_digit_count += 1
			if limb_digit_count == digits_per_limb {
				mpb_mul1_base(&tmp0, radix_base, cur_limb)
				cur_limb = 0
				limb_digit_count = 0
			}
			digit_count += 1
		} else {
			extra_digits |= Limb(c)
		}
	}
	if limb_digit_count != 0 {
		mpb_mul1_base(&tmp0, Limb(pow_ui(u32(radix), u32(limb_digit_count))), cur_limb)
	}

	is_zero: bool
	if digit_count == 0 {
		is_zero = true
		expn_offset = 0
	} else {
		is_zero = false
		if dot_pos < 0 {
			dot_pos = pos
		}
		expn_offset = sig_pos + digit_count - dot_pos
	}

	if radix_bits != 0 && extra_digits != 0 {
		tmp0.tab[0] |= 1
	}

	expn := 0
	expn_overflow := false
	is_bin_exp := false
	c0 := at(s, p)
	exp_ok := false
	if !int_only && p > p_start {
		if radix == 10 && (c0 == 'e' || c0 == 'E') {
			exp_ok = true
		} else if radix != 10 && (c0 == '@' || (radix_bits >= 1 && radix_bits <= 4 && (c0 == 'p' || c0 == 'P'))) {
			exp_ok = true
		}
	}
	if exp_ok {
		is_bin_exp = (c0 == 'p' || c0 == 'P')
		p += 1
		exp_is_neg := false
		if at(s, p) == '+' {
			p += 1
		} else if at(s, p) == '-' {
			exp_is_neg = true
			p += 1
		}
		c := to_digit(at(s, p))
		if c >= 10 {
			return transmute(f64)u64(NAN), p, false
		}
		expn = c
		p += 1
		for {
			if at(s, p) == sep && to_digit(at(s, p + 1)) < 10 {
				p += 1
			}
			c = to_digit(at(s, p))
			if c >= 10 {
				break
			}
			if !expn_overflow {
				if expn > int((max(i32) - 2 - 9) / 10) {
					expn_overflow = true
				} else {
					expn = expn * 10 + c
				}
			}
			p += 1
		}
		if exp_is_neg {
			expn = -expn
		}
		if !is_zero && expn_overflow {
			a: u64
			if exp_is_neg {
				a = 0
			} else {
				a = u64(0x7ff) << 52
			}
			a |= u64(is_neg) << 63
			return transmute(f64)a, p, true
		}
	}

	if p == p_start {
		return transmute(f64)u64(NAN), p, false
	}

	a: u64
	if is_zero {
		a = 0
	} else {
		e: int
		m: u64
		expn1: int
		if radix_bits != 0 {
			if !is_bin_exp {
				expn *= radix_bits
			}
			expn -= expn_offset * radix_bits
			expn1 = expn + digit_count * radix_bits
			if expn1 >= 1024 + radix_bits {
				a = u64(0x7ff) << 52
				a |= u64(is_neg) << 63
				return transmute(f64)a, p, true
			} else if expn1 <= -1075 {
				a = 0
				a |= u64(is_neg) << 63
				return transmute(f64)a, p, true
			}
			m = round_to_d(&e, &tmp0, -expn, .Nearest_Even)
		} else {
			expn -= expn_offset
			expn1 = expn + digit_count
			if expn1 >= int(max_exponent[radix - 2]) + 1 {
				a = u64(0x7ff) << 52
				a |= u64(is_neg) << 63
				return transmute(f64)a, p, true
			} else if expn1 <= int(min_exponent[radix - 2]) {
				a = 0
				a |= u64(is_neg) << 63
				return transmute(f64)a, p, true
			}
			m = mul_pow_round_to_d(&e, &tmp0, radix1, radix_shift, expn, .Nearest_Even)
		}
		if m == 0 {
			a = 0
		} else if e > 1024 {
			a = u64(0x7ff) << 52
		} else if e < -1073 {
			a = 0
		} else if e < -1021 {
			a = m >> uint(-e - 1021)
		} else {
			a = (u64(e + 1022) << 52) | (m & ((u64(1) << 52) - 1))
		}
	}
	a |= u64(is_neg) << 63
	return transmute(f64)a, p, true
}
