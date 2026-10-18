package page

// High Resolution Time and User Timing (import module "performance"): performance.now() and timeOrigin on the page's
// own timeline, mark / measure, getEntriesByName / getEntriesByType (one entry at a time), clearMarks / clearMeasures.
// Entries are kept in startTime order, at most performance.max_user_timing_entries (the oldest go first).

import "core:math"
import "core:strings"
import "wb:dom"
import "wb:wasm"

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

n_Performance_now :: proc "c" (env: wasm.Exec_Env) -> f64 {
	context = ctx()
	return page_now_ms(page_of(env))
}

n_Performance_timeOrigin :: proc "c" (env: wasm.Exec_Env) -> f64 {
	context = ctx()
	return page_of(env).web.origin_unix_ms
}

// performance.mark(name, {startTime}): start < 0 or NaN = now.
n_Performance_mark :: proc "c" (env: wasm.Exec_Env, name: [^]u8, nl: i32, start: f64) -> i32 {
	context = ctx()
	p := page_of(env)
	n := str(name, nl)
	if n == "" { return WEB_ERR_SYNTAX }
	t := start
	if math.is_nan(t) || t < 0 { t = page_now_ms(p) }
	perf_add(p, Perf_Entry{name = n, kind = .Mark, start = t})
	return 0
}

// performance.measure(name, startMark, endMark): an empty start is the time origin, an empty end is now. A missing
// mark is a SyntaxError. Returns 0; the duration is in the entry.
n_Performance_measure :: proc "c" (env: wasm.Exec_Env, name: [^]u8, nl: i32, start_mark: [^]u8, sl: i32, end_mark: [^]u8, el: i32) -> i32 {
	context = ctx()
	p := page_of(env)
	n := str(name, nl)
	if n == "" { return WEB_ERR_SYNTAX }
	start, end := 0.0, page_now_ms(p)
	if s := str(start_mark, sl); s != "" {
		ok: bool
		if start, ok = perf_mark_time(p, s); !ok { return WEB_ERR_SYNTAX }
	}
	if e := str(end_mark, el); e != "" {
		ok: bool
		if end, ok = perf_mark_time(p, e); !ok { return WEB_ERR_SYNTAX }
	}
	perf_add(p, Perf_Entry{name = n, kind = .Measure, start = start, duration = end - start})
	return 0
}

// measure with explicit times (the {start, end} options form).
n_Performance_measureTimes :: proc "c" (env: wasm.Exec_Env, name: [^]u8, nl: i32, start, end: f64) -> i32 {
	context = ctx()
	p := page_of(env)
	n := str(name, nl)
	if n == "" || math.is_nan(start) || math.is_nan(end) { return WEB_ERR_SYNTAX }
	perf_add(p, Perf_Entry{name = n, kind = .Measure, start = start, duration = end - start})
	return 0
}

// getEntriesByName(name, type) / getEntriesByType(type) / getEntries(): name "" matches any, type 0 any, 1 "mark",
// 2 "measure". Returns how many entries match; read them with Performance_entry*.
n_Performance_entryCount :: proc "c" (env: wasm.Exec_Env, name: [^]u8, nl: i32, type: i32) -> i32 {
	context = ctx()
	p := page_of(env)
	n := str(name, nl)
	k: i32 = 0
	for e in p.web.perf {
		if n != "" && e.name != n { continue }
		if type != 0 && i32(e.kind) + 1 != type { continue }
		k += 1
	}
	return k
}

n_Performance_entryStartTime :: proc "c" (env: wasm.Exec_Env, name: [^]u8, nl: i32, type: i32, index: i32) -> f64 {
	context = ctx()
	if e := perf_find(page_of(env), str(name, nl), type, index); e != nil { return e.start }
	return math.nan_f64()
}

n_Performance_entryDuration :: proc "c" (env: wasm.Exec_Env, name: [^]u8, nl: i32, type: i32, index: i32) -> f64 {
	context = ctx()
	if e := perf_find(page_of(env), str(name, nl), type, index); e != nil { return e.duration }
	return math.nan_f64()
}

// The entry's name (length needed), Not_Found when there is no such entry.
n_Performance_entryName :: proc "c" (env: wasm.Exec_Env, name: [^]u8, nl: i32, type: i32, index: i32, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	e := perf_find(page_of(env), str(name, nl), type, index)
	if e == nil { return i32(dom.Error.Not_Found) }
	return out_string(e.name, buf, cap)
}

n_Performance_entryType :: proc "c" (env: wasm.Exec_Env, name: [^]u8, nl: i32, type: i32, index: i32) -> i32 {
	context = ctx()
	e := perf_find(page_of(env), str(name, nl), type, index)
	if e == nil { return i32(dom.Error.Not_Found) }
	return i32(e.kind) + 1
}

n_Performance_clearMarks :: proc "c" (env: wasm.Exec_Env, name: [^]u8, nl: i32) {
	context = ctx()
	perf_clear(page_of(env), str(name, nl), .Mark)
}

n_Performance_clearMeasures :: proc "c" (env: wasm.Exec_Env, name: [^]u8, nl: i32) {
	context = ctx()
	perf_clear(page_of(env), str(name, nl), .Measure)
}

performance_symbols := [?]wasm.Native_Symbol{
	{"Performance_now", rawptr(n_Performance_now), "()F", nil},
	{"Performance_timeOrigin", rawptr(n_Performance_timeOrigin), "()F", nil},
	{"Performance_mark", rawptr(n_Performance_mark), "(*~F)i", nil},
	{"Performance_measure", rawptr(n_Performance_measure), "(*~*~*~)i", nil},
	{"Performance_measureTimes", rawptr(n_Performance_measureTimes), "(*~FF)i", nil},
	{"Performance_entryCount", rawptr(n_Performance_entryCount), "(*~i)i", nil},
	{"Performance_entryStartTime", rawptr(n_Performance_entryStartTime), "(*~ii)F", nil},
	{"Performance_entryDuration", rawptr(n_Performance_entryDuration), "(*~ii)F", nil},
	{"Performance_entryName", rawptr(n_Performance_entryName), "(*~ii*~)i", nil},
	{"Performance_entryType", rawptr(n_Performance_entryType), "(*~ii)i", nil},
	{"Performance_clearMarks", rawptr(n_Performance_clearMarks), "(*~)", nil},
	{"Performance_clearMeasures", rawptr(n_Performance_clearMeasures), "(*~)", nil},
}
