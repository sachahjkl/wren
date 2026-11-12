#+build !freestanding
package jsrt

// The scans of string_scan.odin against their scalar definitions: every length around the 16-byte step, and a
// difference or a byte out of range at every position.

import "core:testing"

@(private = "file")
SCAN_MAX :: 70

@(test)
scan_ascii_prefix :: proc(t: ^testing.T) {
	buf: [SCAN_MAX]u8
	for n in 0 ..= SCAN_MAX {
		for i in 0 ..< n {buf[i] = u8('a' + i % 26)}
		testing.expect_value(t, ascii_prefix(buf[:n]), n)
		for at in 0 ..< n {
			for bad in ([]u8{0x80, 0xc3, 0xff}) {
				buf[at] = bad
				testing.expect_value(t, ascii_prefix(buf[:n]), at)
				buf[at] = 'x'
			}
		}
	}
}

@(test)
scan_units_fit_latin1 :: proc(t: ^testing.T) {
	buf: [SCAN_MAX]u16
	for n in 0 ..= SCAN_MAX {
		for i in 0 ..< n {buf[i] = u16(0xa0 + i % 0x60)}
		testing.expect(t, units_fit_latin1(buf[:n]))
		for at in 0 ..< n {
			for bad in ([]u16{0x100, 0x1ff, 0xd800, 0xffff}) {
				buf[at] = bad
				testing.expect(t, !units_fit_latin1(buf[:n]))
				buf[at] = 0xff
			}
			testing.expect(t, units_fit_latin1(buf[:n]))
		}
	}
}

@(test)
scan_mismatch :: proc(t: ^testing.T) {
	a8, b8: [SCAN_MAX]u8
	a16, b16: [SCAN_MAX]u16
	for n in 0 ..= SCAN_MAX {
		for i in 0 ..< n {
			a8[i], b8[i] = u8(i * 3), u8(i * 3)
			a16[i], b16[i] = u16(i * 3), u16(i * 3)
		}
		testing.expect_value(t, mismatch_u8(raw_data(a8[:]), raw_data(b8[:]), n), n)
		testing.expect_value(t, mismatch_u16(raw_data(a16[:]), raw_data(b16[:]), n), n)
		testing.expect_value(t, mismatch_u8_u16(raw_data(a8[:]), raw_data(b16[:]), n), n)
		for at in 0 ..< n {
			b8[at] ~= 0x40
			b16[at] ~= 0x4000 // (differs above the low byte only: a 16-bit unit is compared whole)
			testing.expect_value(t, mismatch_u8(raw_data(a8[:]), raw_data(b8[:]), n), at)
			testing.expect_value(t, mismatch_u16(raw_data(a16[:]), raw_data(b16[:]), n), at)
			testing.expect_value(t, mismatch_u8_u16(raw_data(a8[:]), raw_data(b16[:]), n), at)
			b8[at] ~= 0x40
			b16[at] ~= 0x4000
		}
	}
}

@(test)
scan_widen_narrow :: proc(t: ^testing.T) {
	src: [SCAN_MAX]u8
	wide: [SCAN_MAX]u16
	back: [SCAN_MAX]u8
	for i in 0 ..< SCAN_MAX {src[i] = u8(i * 37)}
	for n in 0 ..= SCAN_MAX {
		widen_latin1(raw_data(wide[:]), src[:n])
		narrow_u16(raw_data(back[:]), wide[:n])
		for i in 0 ..< n {
			testing.expect_value(t, wide[i], u16(src[i]))
			testing.expect_value(t, back[i], src[i])
		}
	}
}
