package jsdate

// ECMAScript Date time-value math, ported from QuickJS-ng quickjs.c (the Date section) to native
// Odin. It covers the proleptic Gregorian calendar used by ECMAScript: time <-> broken-down fields,
// MakeDay / MakeTime / MakeDate, TimeClip, and the day/year helpers. The local-time offset comes from
// a host callback (timezone_offset), exactly as the Wren host provides js.timezone_offset; UTC math
// needs no callback. No allocation, no OS dependency: builds for windows_amd64, linux_amd64 and
// freestanding_wasm32.
//
// Time values are milliseconds since the Unix epoch as f64 (NaN for an invalid Date). The valid range
// is +/-8.64e15 ms (about +/-273790 years). Fields use the ECMAScript order:
//   [0]=year [1]=month(0..11) [2]=day(1..31) [3]=hour [4]=min [5]=sec [6]=ms [7]=weekday [8]=tz-min

MS_PER_SEC :: 1000
MS_PER_MINUTE :: 60 * 1000
MS_PER_HOUR :: 60 * MS_PER_MINUTE
MS_PER_DAY :: 24 * MS_PER_HOUR
MAX_TIME :: 8.64e15 // ms

// The host supplies the offset, in minutes, between UTC and local time for a given instant: the value
// of getTimezoneOffset(t) (positive west of UTC). The engine sets this to js.timezone_offset. When it
// is nil, local time equals UTC (offset 0), so UTC-only code works without a host.
timezone_offset_proc: proc "contextless" (time_ms: i64) -> int

@(private)
tz_offset :: proc(time_ms: i64) -> int {
	if timezone_offset_proc != nil {
		return timezone_offset_proc(time_ms)
	}
	return 0
}

// Fields indices, named for clarity.
Field :: enum {
	Year    = 0,
	Month   = 1,
	Day     = 2,
	Hour    = 3,
	Minute  = 4,
	Second  = 5,
	Ms      = 6,
	Weekday = 7,
	Tz      = 8,
}

Fields :: [9]f64

@(private)
month_days := [12]int{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

@(private)
month_names := "JanFebMarAprMayJunJulAugSepOctNovDec"

@(private)
day_names := "SunMonTueWedThuFriSat"

// positive modulo
@(private)
math_mod :: proc(a, b: i64) -> i64 {
	m := a % b
	return m + (m < 0 ? b : 0)
}

// integer division rounding toward -Infinity
@(private)
floor_div :: proc(a, b: i64) -> i64 {
	m := a % b
	return (a - (m + (m < 0 ? b : 0))) / b
}

@(private)
days_from_year :: proc(y: i64) -> i64 {
	return 365 * (y - 1970) + floor_div(y - 1969, 4) - floor_div(y - 1901, 100) + floor_div(y - 1601, 400)
}

@(private)
days_in_year :: proc(y: i64) -> i64 {
	return 365 + (y % 4 == 0 ? 1 : 0) - (y % 100 == 0 ? 1 : 0) + (y % 400 == 0 ? 1 : 0)
}

// Return the year, update *days to the day-of-year. Faithful to the C: the approximation is close,
// so this converges in a couple of steps.
@(private)
year_from_days :: proc(days: ^i64) -> i64 {
	d := days^
	y := floor_div(d * 10000, 3652425) + 1970
	for {
		d1 := d - days_from_year(y)
		if d1 < 0 {
			y -= 1
		} else {
			nd := days_in_year(y)
			if d1 < nd {
				days^ = d1
				return y
			}
			y += 1
		}
	}
}

// TimeClip (21.4.1.1): keep only values in the valid range, truncate toward zero, normalize -0 to +0.
time_clip :: proc(t: f64) -> f64 {
	if t >= -MAX_TIME && t <= MAX_TIME {
		r := trunc_f64(t)
		return r + 0.0 // -0 -> +0
	}
	return nan()
}

// Broken-down fields from a time value. Returns ok=false when t is NaN and force is false (the caller
// then reports "Invalid Date"); with force, fields are filled from t=0. is_local applies the host tz.
get_date_fields :: proc(dval: f64, is_local: bool, force: bool) -> (fields: Fields, ok: bool) {
	d: i64
	tz: i64 = 0
	if is_nan(dval) {
		if !force {
			return fields, false
		}
		d = 0
	} else {
		d = i64(dval)
		if is_local {
			tz = -i64(tz_offset(d))
			d += tz * MS_PER_MINUTE
		}
	}

	h := math_mod(d, MS_PER_DAY)
	days := (d - h) / MS_PER_DAY
	ms := h % 1000
	h = (h - ms) / 1000
	s := h % 60
	h = (h - s) / 60
	m := h % 60
	h = (h - m) / 60
	wd := math_mod(days + 4, 7)
	y := year_from_days(&days)

	i := 0
	for i = 0; i < 11; i += 1 {
		md := i64(month_days[i])
		if i == 1 {
			md += days_in_year(y) - 365
		}
		if days < md {
			break
		}
		days -= md
	}
	fields[0] = f64(y)
	fields[1] = f64(i)
	fields[2] = f64(days + 1)
	fields[3] = f64(h)
	fields[4] = f64(m)
	fields[5] = f64(s)
	fields[6] = f64(ms)
	fields[7] = f64(wd)
	fields[8] = f64(tz)
	return fields, true
}

// MakeDate(MakeDay(y,mon,d), MakeTime(h,m,s,ms)) then TimeClip, with optional local-time adjustment.
// Mirrors set_date_fields: the spec mandates f64 and a specific order of operations; we follow it so
// the results match QuickJS and test262 (including fp-evaluation-order). Only fields[0..6] are read.
set_date_fields :: proc(fields: Fields, is_local: bool) -> f64 {
	y := fields[0]
	m := fields[1]
	dt := fields[2]
	ym := y + floor_f64(m / 12)
	mn := fmod_f64(m, 12)
	if mn < 0 {
		mn += 12
	}
	if ym < -271821 || ym > 275760 {
		return nan()
	}

	yi := i64(ym)
	mi := int(mn)
	days := days_from_year(yi)
	for i in 0 ..< mi {
		days += i64(month_days[i])
		if i == 1 {
			days += days_in_year(yi) - 365
		}
	}
	day := f64(days) + dt - 1

	h := fields[3]
	mm := fields[4]
	s := fields[5]
	milli := fields[6]
	// The intermediate temporaries keep the operation order the spec requires (and stop a compiler
	// from fusing a multiply-add, which would change the rounding).
	time := h * 3600000
	temp := mm * 60000
	time += temp
	temp = s * 1000
	time += temp
	time += milli

	temp = day * 86400000
	tv := temp + time
	if !is_finite(tv) {
		return nan()
	}

	if is_local {
		ti: i64
		if tv < -9.2e18 {
			ti = min(i64)
		} else if tv >= 9.2e18 {
			ti = max(i64)
		} else {
			ti = i64(tv)
		}
		tv += f64(tz_offset(ti)) * 60000
	}
	return time_clip(tv)
}

// --- tiny math helpers (no core:math dependency, to keep freestanding_wasm32 clean) ---

@(private)
nan :: #force_inline proc() -> f64 {
	return transmute(f64)u64(0x7ff8_0000_0000_0000)
}

@(private)
is_nan :: #force_inline proc(x: f64) -> bool {
	return x != x
}

@(private)
is_finite :: #force_inline proc(x: f64) -> bool {
	bits := transmute(u64)x
	return (bits & 0x7ff0_0000_0000_0000) != 0x7ff0_0000_0000_0000
}

// trunc toward zero for the finite values Date uses (|t| <= 8.64e15 < 2^53, so i64 is exact there;
// larger finite values are returned unchanged because they already have no fractional part).
@(private)
trunc_f64 :: proc(x: f64) -> f64 {
	if !is_finite(x) {
		return x
	}
	if x >= -9.007199254740992e15 && x <= 9.007199254740992e15 {
		return f64(i64(x))
	}
	return x // |x| >= 2^53: already integral
}

@(private)
floor_f64 :: proc(x: f64) -> f64 {
	if !is_finite(x) {
		return x
	}
	t := trunc_f64(x)
	if t > x {
		return t - 1
	}
	return t
}

// fmod for the small arguments Date uses (m / 12 where m is an integral field). Computed as
// x - trunc(x/y)*y, which matches C fmod for these integral inputs.
@(private)
fmod_f64 :: proc(x, y: f64) -> f64 {
	if y == 0 || !is_finite(x) {
		return nan()
	}
	q := trunc_f64(x / y)
	return x - q * y
}
