package jsrt

// TypedArray element codecs: read/write one element of a given element type from a byte buffer.
//
// The TypedArray and DataView builtins layer on these. Multi-byte values use the platform's native
// (little-endian on all our targets) byte order; DataView adds explicit endianness on top. Float16 is
// encoded/decoded by hand since Odin's core does not expose an f16<->f32 bridge everywhere.

import "core:math"

elem_byte_size :: proc(kind: Typed_Array_Element) -> int {
	switch kind {
	case .i8, .u8, .u8_clamped:
		return 1
	case .i16, .u16, .f16:
		return 2
	case .i32, .u32, .f32:
		return 4
	case .bi64, .bu64, .f64:
		return 8
	}
	return 1
}

typed_array_read_element :: proc(bytes: []u8, byte_offset: int, kind: Typed_Array_Element, idx: u32) -> Value {
	off := byte_offset + int(idx) * elem_byte_size(kind)
	p := raw_data(bytes[off:])
	switch kind {
	case .i8:
		return mk_int(i32((cast(^i8)p)^))
	case .u8, .u8_clamped:
		return mk_int(i32((cast(^u8)p)^))
	case .i16:
		return mk_int(i32((cast(^i16)p)^))
	case .u16:
		return mk_int(i32((cast(^u16)p)^))
	case .i32:
		return mk_int((cast(^i32)p)^)
	case .u32:
		return mk_number(f64((cast(^u32)p)^))
	case .f32:
		return mk_number(f64((cast(^f32)p)^))
	case .f64:
		return mk_number((cast(^f64)p)^)
	case .f16:
		return mk_number(f64(f16_to_f32((cast(^u16)p)^)))
	case .bi64, .bu64:
		// BigInt-backed elements are built by the BigInt64Array wave; return undefined for now.
		return UNDEFINED
	}
	return UNDEFINED
}

typed_array_write_element :: proc(bytes: []u8, byte_offset: int, kind: Typed_Array_Element, idx: u32, n: f64) {
	off := byte_offset + int(idx) * elem_byte_size(kind)
	p := raw_data(bytes[off:])
	switch kind {
	case .i8:
		(cast(^i8)p)^ = i8(f64_to_int32(n))
	case .u8:
		(cast(^u8)p)^ = u8(f64_to_int32(n))
	case .u8_clamped:
		(cast(^u8)p)^ = clamp_u8(n)
	case .i16:
		(cast(^i16)p)^ = i16(f64_to_int32(n))
	case .u16:
		(cast(^u16)p)^ = u16(f64_to_int32(n))
	case .i32:
		(cast(^i32)p)^ = f64_to_int32(n)
	case .u32:
		(cast(^u32)p)^ = u32(f64_to_int32(n))
	case .f32:
		(cast(^f32)p)^ = f32(n)
	case .f64:
		(cast(^f64)p)^ = n
	case .f16:
		(cast(^u16)p)^ = f32_to_f16(f32(n))
	case .bi64, .bu64:
		// Handled by the BigInt64Array wave.
	}
}

@(private = "file")
clamp_u8 :: proc(n: f64) -> u8 {
	if math.is_nan(n) || n <= 0 {return 0}
	if n >= 255 {return 255}
	// Round half to even (ECMAScript ToUint8Clamp).
	r := math.round(n)
	if abs(n - math.trunc(n)) == 0.5 {
		r = 2 * math.round(n / 2)
	}
	return u8(r)
}

// --- half-precision float conversion ---

f16_to_f32 :: proc(h: u16) -> f32 {
	sign := u32(h >> 15) & 1
	exp := u32(h >> 10) & 0x1F
	mant := u32(h) & 0x3FF
	f: u32
	if exp == 0 {
		if mant == 0 {
			f = sign << 31
		} else {
			// Subnormal: normalise.
			e := i32(-1)
			m := mant
			for m & 0x400 == 0 {
				m <<= 1
				e -= 1
			}
			m &= 0x3FF
			f = (sign << 31) | (u32(127 - 15 + 1 + e) << 23) | (m << 13)
		}
	} else if exp == 0x1F {
		f = (sign << 31) | (0xFF << 23) | (mant << 13)
	} else {
		f = (sign << 31) | ((exp + (127 - 15)) << 23) | (mant << 13)
	}
	return transmute(f32)f
}

f32_to_f16 :: proc(x: f32) -> u16 {
	f := transmute(u32)x
	sign := u16((f >> 16) & 0x8000)
	exp := i32((f >> 23) & 0xFF) - 127 + 15
	mant := f & 0x7FFFFF
	if exp <= 0 {
		if exp < -10 {return sign}
		mant |= 0x800000
		shift := u32(14 - exp)
		return sign | u16(mant >> shift)
	}
	if exp >= 0x1F {
		if (f & 0x7FFFFFFF) > 0x7F800000 {
			return sign | 0x7E00 // NaN
		}
		return sign | 0x7C00 // Inf
	}
	return sign | u16(exp << 10) | u16(mant >> 13)
}
