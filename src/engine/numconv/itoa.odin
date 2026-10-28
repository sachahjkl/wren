package numconv

// Integer -> ASCII, ported from QuickJS cutils/dtoa (u32toa .. i64toa_radix). These feed both the
// public integer path of Number.prototype.toString and the fast integer path inside dtoa. They write
// into a caller buffer and return the length; no NUL is appended (dtoa adds its own).

import "base:intrinsics"

@(private = "file")
clz32i :: #force_inline proc(a: u32) -> int {
	return int(intrinsics.count_leading_zeros(a))
}

@(private = "file")
clz64i :: #force_inline proc(a: u64) -> int {
	return int(intrinsics.count_leading_zeros(a))
}

// Decimal u32. buf must hold at least 10 bytes.
u32toa :: proc(buf: [^]u8, n_in: u32) -> int {
	n := n_in
	tmp: [10]u8
	q := len(tmp)
	for {
		q -= 1
		tmp[q] = u8(n % 10) + '0'
		n /= 10
		if n == 0 {
			break
		}
	}
	length := len(tmp) - q
	intrinsics.mem_copy(buf, &tmp[q], length)
	return length
}

// Decimal i32. buf must hold at least 11 bytes.
i32toa :: proc(buf: [^]u8, n: i32) -> int {
	if n >= 0 {
		return u32toa(buf, u32(n))
	}
	buf[0] = '-'
	return u32toa(buf[1:], u32(-i64(n))) + 1
}

@(private = "file")
u32toa_pad :: proc(buf: [^]u8, n_in: u32, length: int) {
	n := n_in
	for i := length - 1; i >= 0; i -= 1 {
		buf[i] = u8(n % 10) + '0'
		n /= 10
	}
}

// Decimal u64. buf must hold at least 20 bytes.
u64toa :: proc(buf: [^]u8, n_in: u64) -> int {
	n := n_in
	if n < 0x1_0000_0000 {
		return u32toa(buf, u32(n))
	}
	q := 0
	n1 := n / 1_000_000_000
	n %= 1_000_000_000
	if n1 >= 0x1_0000_0000 {
		n2 := u32(n1 / 1_000_000_000)
		n1 = n1 % 1_000_000_000
		if n2 >= 10 {
			buf[q] = u8(n2 / 10) + '0';q += 1
			n2 %= 10
		}
		buf[q] = u8(n2) + '0';q += 1
		u32toa_pad(buf[q:], u32(n1), 9)
		q += 9
	} else {
		q += u32toa(buf[q:], u32(n1))
	}
	u32toa_pad(buf[q:], u32(n), 9)
	q += 9
	return q
}

// Decimal i64. buf must hold at least 21 bytes.
i64toa :: proc(buf: [^]u8, n: i64) -> int {
	if n >= 0 {
		return u64toa(buf, u64(n))
	}
	buf[0] = '-'
	return u64toa(buf[1:], u64(-n)) + 1
}

@(private = "file")
u64toa_bin :: proc(buf: [^]u8, n_in: u64, radix_bits: uint, length: int) {
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

// u64 in radix 2..36. buf must hold at least 64 bytes.
u64toa_radix :: proc(buf: [^]u8, n_in: u64, radix: int) -> int {
	n := n_in
	if radix == 10 {
		return u64toa(buf, n)
	}
	if (radix & (radix - 1)) == 0 {
		radix_bits := 31 - clz32i(u32(radix))
		l: int
		if n == 0 {
			l = 1
		} else {
			l = (64 - clz64i(n) + radix_bits - 1) / radix_bits
		}
		u64toa_bin(buf, n, uint(radix_bits), l)
		return l
	}
	tmp: [41]u8 // longest for radix 3
	q := len(tmp)
	for {
		digit := int(n % u64(radix))
		n /= u64(radix)
		if digit < 10 {
			digit += '0'
		} else {
			digit += 'a' - 10
		}
		q -= 1
		tmp[q] = u8(digit)
		if n == 0 {
			break
		}
	}
	length := len(tmp) - q
	intrinsics.mem_copy(buf, &tmp[q], length)
	return length
}

// i64 in radix 2..36. buf must hold at least 65 bytes.
i64toa_radix :: proc(buf: [^]u8, n: i64, radix: int) -> int {
	if n >= 0 {
		return u64toa_radix(buf, u64(n), radix)
	}
	buf[0] = '-'
	return u64toa_radix(buf[1:], u64(-n), radix) + 1
}
