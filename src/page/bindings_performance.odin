package page

// High Resolution Time and User Timing (import module "performance"): performance.now() and timeOrigin on the page's
// own timeline, mark / measure, getEntriesByName / getEntriesByType (one entry at a time), clearMarks / clearMeasures.
// Entries are kept in startTime order, at most performance.max_user_timing_entries (the oldest go first).

import "core:math"
import "core:strings"

Perf_Kind :: enum u8 { Mark, Measure }

Perf_Entry :: struct {
	name:     string,   // owned
	kind:     Perf_Kind,
	start:    f64,
	duration: f64,
}

// Removes the entries of `kind` named `name` (all of them when name is "").
perf_clear :: proc(p: ^Page, name: string, kind: Perf_Kind) {
	w := p.web
	k := 0
	for e in w.perf {
		if e.kind == kind && (name == "" || e.name == name) { delete(e.name); continue }
		w.perf[k] = e
		k += 1
	}
	resize(&w.perf, k)
}

@(private)
perf_add :: proc(p: ^Page, e: Perf_Entry) {
	w := p.web
	if len(w.perf) >= p.settings.web.perf_max_entries {
		if !w.perf_warned { w.perf_warned = true; log(p, .Warn, "performance entry buffer full: the oldest entries are dropped") }
		for len(w.perf) >= max(p.settings.web.perf_max_entries, 1) {
			delete(w.perf[0].name)
			ordered_remove(&w.perf, 0)
		}
	}
	// keep startTime order: entries are nearly always appended at the end
	i := len(w.perf)
	for i > 0 && w.perf[i - 1].start > e.start { i -= 1 }
	inject_at(&w.perf, i, Perf_Entry{name = strings.clone(e.name), kind = e.kind, start = e.start, duration = e.duration})
}

// The most recent mark called `name`.
@(private)
perf_mark_time :: proc(p: ^Page, name: string) -> (f64, bool) {
	w := p.web
	for i := len(w.perf) - 1; i >= 0; i -= 1 {
		if w.perf[i].kind == .Mark && w.perf[i].name == name { return w.perf[i].start, true }
	}
	return 0, false
}

// The `index`-th entry matching name ("" = any) and type (0 any, 1 mark, 2 measure).
@(private)
perf_find :: proc(p: ^Page, name: string, type: i32, index: i32) -> ^Perf_Entry {
	k: i32 = 0
	for &e in p.web.perf {
		if name != "" && e.name != name { continue }
		if type != 0 && i32(e.kind) + 1 != type { continue }
		if k == index { return &e }
		k += 1
	}
	return nil
}

////////////////////////////////
// Imports

Performance_now :: proc(c: ^Call) -> f64 { return page_now_ms(c.page) }
Performance_timeOrigin :: proc(c: ^Call) -> f64 { return c.page.web.origin_unix_ms }

// performance.mark(name, {startTime}): start < 0 or NaN = now.
Performance_mark :: proc(c: ^Call, name: string, start_time: f64) -> Api_Error {
	p := c.page
	if name == "" { return fail(c, .Syntax, "SyntaxError: empty mark name") }
	t := start_time
	if math.is_nan(t) || t < 0 { t = page_now_ms(p) }
	perf_add(p, Perf_Entry{name = name, kind = .Mark, start = t})
	return .None
}

// performance.measure(name, startMark, endMark): an empty start is the time origin, an empty end is now.
Performance_measure :: proc(c: ^Call, name: string, start_mark: string, end_mark: string) -> Api_Error {
	p := c.page
	if name == "" { return fail(c, .Syntax, "SyntaxError: empty measure name") }
	start, end := 0.0, page_now_ms(p)
	if start_mark != "" {
		ok: bool
		if start, ok = perf_mark_time(p, start_mark); !ok { return fail(c, .Syntax, "SyntaxError: no such mark") }
	}
	if end_mark != "" {
		ok: bool
		if end, ok = perf_mark_time(p, end_mark); !ok { return fail(c, .Syntax, "SyntaxError: no such mark") }
	}
	perf_add(p, Perf_Entry{name = name, kind = .Measure, start = start, duration = end - start})
	return .None
}

// measure with explicit times (the {start, end} options form).
Performance_measureTimes :: proc(c: ^Call, name: string, start, end: f64) -> Api_Error {
	if name == "" || math.is_nan(start) || math.is_nan(end) { return fail(c, .Syntax, "SyntaxError: empty name or NaN time") }
	perf_add(c.page, Perf_Entry{name = name, kind = .Measure, start = start, duration = end - start})
	return .None
}

Performance_entryCount :: proc(c: ^Call, name: string, entry_type: Api_PerformanceEntryType) -> i32 {
	k: i32 = 0
	for e in c.page.web.perf {
		if name != "" && e.name != name { continue }
		if entry_type != .Any && i32(e.kind) + 1 != i32(entry_type) { continue }
		k += 1
	}
	return k
}

Performance_entryStartTime :: proc(c: ^Call, name: string, entry_type: Api_PerformanceEntryType, index: i32) -> f64 {
	if e := perf_find(c.page, name, i32(entry_type), index); e != nil { return e.start }
	return math.nan_f64()
}

Performance_entryDuration :: proc(c: ^Call, name: string, entry_type: Api_PerformanceEntryType, index: i32) -> f64 {
	if e := perf_find(c.page, name, i32(entry_type), index); e != nil { return e.duration }
	return math.nan_f64()
}

Performance_entryName :: proc(c: ^Call, name: string, entry_type: Api_PerformanceEntryType, index: i32) -> (string, Api_Error) {
	e := perf_find(c.page, name, i32(entry_type), index)
	if e == nil { return "", .Not_Found }
	return e.name, .None
}

Performance_entryType :: proc(c: ^Call, name: string, entry_type: Api_PerformanceEntryType, index: i32) -> (Api_PerformanceEntryType, Api_Error) {
	e := perf_find(c.page, name, i32(entry_type), index)
	if e == nil { return .Any, .Not_Found }
	return e.kind == .Mark ? .Mark : .Measure, .None
}

Performance_clearMarks :: proc(c: ^Call, name: string) { perf_clear(c.page, name, .Mark) }
Performance_clearMeasures :: proc(c: ^Call, name: string) { perf_clear(c.page, name, .Measure) }