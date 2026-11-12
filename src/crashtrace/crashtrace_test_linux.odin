package crashtrace

import "core:os"
import "core:testing"

@(test)
utc_dates_are_civil :: proc(t: ^testing.T) {
	y, mo, d, h, mi, s := civil_utc(0)
	testing.expect(t, y == 1970 && mo == 1 && d == 1 && h == 0 && mi == 0 && s == 0)
	y, mo, d, h, mi, s = civil_utc(1_793_126_096)   // 2026-10-27 18:34:56
	testing.expect(t, y == 2026 && mo == 10 && d == 27 && h == 18 && mi == 34 && s == 56)
	y, mo, d, _, _, _ = civil_utc(951_782_400)   // 2000-02-29 (a leap day of a century)
	testing.expect(t, y == 2000 && mo == 2 && d == 29)
}

@(test)
this_process_has_a_start :: proc(t: ^testing.T) {
	testing.expect(t, start_ticks(os.get_pid()) != 0, "read from /proc")
	testing.expect_value(t, start_ticks(0x7fff_fff0), u64(0))
	buf: [64]u8
	fp := build_fingerprint(buf[:])
	testing.expect(t, len(fp) % 2 == 0, "hex, or empty without a build id")
}
