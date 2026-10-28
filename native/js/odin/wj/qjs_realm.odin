// qjs_realm.odin: the state of the one realm of this module instance and what every part of the engine shares about it
// (ported from native/js/engine/qjs_realm.c): the realm itself and the scratch buffer (wj_the_realm, wj_scratch: the C
// that remains links against them), the engine's malloc, interruption (the browser writes wj_interrupt) and the page's
// own profiler sampled from the interrupt handler, the console sink, reporting an exception, and the C stack budget of
// JavaScript. The browser's entry points (wj_eval_script, wj_run_jobs, wj_preinit, wj_realm_start...) are in
// native/js/odin/qjs_realm.odin.
package wj

import "base:intrinsics"

@(export, link_name = "wj_the_realm") wj_the_realm: Realm
@(export, link_name = "wj_scratch")   wj_scratch: Buf

// ---- memory ----

@(export, link_name = "wj_malloc")
wj_malloc :: proc "c" (n: uint) -> rawptr { return libc_malloc(n) }

@(export, link_name = "wj_free")
wj_free :: proc "c" (p: rawptr) { libc_free(p) }

// The browser's allocations in this memory (sources, URLs, rule text it hands to an entry point).
@(export, link_name = "wj_alloc")
wj_alloc :: proc "c" (n: u32) -> u32 { return u32(uintptr(libc_malloc(uint(n != 0 ? n : 1)))) }

@(export, link_name = "wj_dealloc")
wj_dealloc :: proc "c" (p: u32) { libc_free(rawptr(uintptr(p))) }

@(export, link_name = "wj_scratch_grow")
wj_scratch_grow :: proc "c" (need: u32) -> bool {
	cap := wj_scratch.cap != 0 ? wj_scratch.cap : 256
	for cap < need { cap = cap > 0x40000000 ? need : cap * 2 }
	d := ([^]u8)(libc_realloc(wj_scratch.data, uint(cap)))
	if d == nil { return false }
	wj_scratch.data = d
	wj_scratch.cap = cap
	return true
}

// Date's local time (native/js/patches: the engine asks the browser for the offset of a time).
@(export, link_name = "wren_js_timezone_offset")
wren_js_timezone_offset :: proc "c" (time_ms: i64) -> i32 { return wr_Engine_timezoneOffset(f64(time_ms)) }

// ---- interruption ----

// Written by the browser (epoch callback) when the current task ran past javascript.slow_script_ms; cleared before
// each task. Its address is exported (wj_interrupt_address): read it with interrupted().
@(export, link_name = "wj_interrupt") wj_interrupt: i32
interrupt_count: u32

interrupted :: #force_inline proc "contextless" () -> bool { return intrinsics.volatile_load(&wj_interrupt) != 0 }

@(export, link_name = "wj_interrupt_address")
wj_interrupt_address :: proc "c" () -> u32 { return u32(uintptr(&wj_interrupt)) }

// How many times the current realm's tasks were interrupted (diagnostics).
@(export, link_name = "wj_interrupts")
wj_interrupts :: proc "c" () -> u32 { return interrupt_count }

// ---- the page's own functions (the measuring tools: WREN_JS_PROFILE): every few calls of the interrupt handler (it
// runs every JS_INTERRUPT_COUNTER_INIT calls and loop iterations of the interpreter) the stack is read from a new
// Error's `stack` and the frames counted by their text ("name (url:line:col)"): self for the innermost, inclusive for
// each distinct frame of the first few. wj_profile_dump writes "self<TAB>inclusive<TAB>frame" lines. Off, the handler
// is as it was. ----

@(private = "file") PROF_SLOTS :: 8192
@(private = "file") PROF_EVERY :: 4
@(private = "file") PROF_DEPTH :: 10

@(private = "file")
Prof_Slot :: struct { key: [^]u8, key_len: u32, self, incl: u32 }

@(private = "file") prof_tab: [PROF_SLOTS]Prof_Slot
@(private = "file") prof_on: i32
@(private = "file") prof_calls, prof_samples, prof_used, prof_lost: u32

@(private = "file")
prof_slot_of :: proc "contextless" (s: [^]u8, n: int) -> ^Prof_Slot {
	h: u32 = 2166136261
	for i in 0 ..< n { h = (h ~ u32(s[i])) * 16777619 }
	for k: u32 = 0; k < PROF_SLOTS; k += 1 {
		e := &prof_tab[(h + k) & (PROF_SLOTS - 1)]
		if e.key == nil {
			if prof_used >= PROF_SLOTS * 3 / 4 { prof_lost += 1; return nil }
			e.key = ([^]u8)(libc_malloc(uint(n) + 1))
			if e.key == nil { return nil }
			if n > 0 { memcpy(e.key, s, uint(n)) }
			e.key[n] = 0
			e.key_len = u32(n)
			prof_used += 1
			return e
		}
		if int(e.key_len) == n && (n == 0 || memcmp(e.key, s, uint(n)) == 0) { return e }
	}
	return nil
}

@(private = "file")
ends_native :: #force_inline proc "contextless" (p: [^]u8, n: int) -> bool {
	return n > 9 && memcmp(p[n - 8:], raw_data(string("(native)")), 8) == 0
}

@(private = "file")
prof_sample :: proc "contextless" (ctx: ^Context) {
	err := JS_NewError(ctx)
	st := JS_GetPropertyStr(ctx, err, "stack")
	slen: uint
	s := is_string(st) ? ([^]u8)(rawptr(JS_ToCStringLen2(ctx, &slen, st, false))) : nil
	if s != nil {
		seen: [PROF_DEPTH][^]u8
		seen_n: [PROF_DEPTH]int
		nseen := 0
		p, end := 0, int(slen)
		depth := 0
		for p < end && depth < PROF_DEPTH {
			nl := index_byte(s[p:], end - p, '\n')
			le := nl >= 0 ? p + nl : end
			a := p
			for a < le && s[a] == ' ' { a += 1 }
			if le - a > 3 && s[a] == 'a' && s[a + 1] == 't' && s[a + 2] == ' ' { a += 3 }
			n := min(le - a, 220)
			if n > 0 {
				// distinct frames only (a recursion counts once)
				dup := false
				for i in 0 ..< nseen {
					if seen_n[i] == n && memcmp(seen[i], s[a:], uint(n)) == 0 { dup = true; break }
				}
				e := dup ? nil : prof_slot_of(s[a:], n)
				if e != nil {
					e.incl += 1
					if depth == 0 { e.self += 1 }
				}
				if !dup && nseen < PROF_DEPTH { seen[nseen] = s[a:]; seen_n[nseen] = n; nseen += 1 }
				depth += 1
			}
			p = nl >= 0 ? le + 1 : end
		}
		// a native function on top (exec, test, replace, forEach...): the frames down to the first that is not native,
		// as one ("native <= native <= caller"): who is behind the time the natives take
		if nseen >= 2 && ends_native(seen[0], seen_n[0]) {
			two: [700]u8
			used := 0
			for k in 0 ..< min(nseen, 4) {
				nk := min(seen_n[k], 160)
				if used + nk + 4 >= len(two) { break }
				if k > 0 { memcpy(&two[used], raw_data(string(" <= ")), 4); used += 4 }
				memcpy(&two[used], seen[k], uint(nk)); used += nk
				if !ends_native(seen[k], seen_n[k]) { break }
			}
			e := prof_slot_of(&two[0], used)
			if e != nil { e.self += 1; e.incl += 1 }
		}
		prof_samples += 1
		JS_FreeCString(ctx, cstring(rawptr(s)))
	}
	JS_FreeValue(ctx, st)
	JS_FreeValue(ctx, err)
}

@(export, link_name = "wj_profile_set")
wj_profile_set :: proc "c" (on: i32) { prof_on = on }

@(export, link_name = "wj_profile_dump")
wj_profile_dump :: proc "c" (buf: u32, size: u32) -> u32 {
	out := ([^]u8)(uintptr(buf))
	w := snprintf(out, uint(size), "samples\t%u\t%u\tfunctions\t%u\tlost\t%u\n", prof_samples, prof_calls, prof_used, prof_lost)
	if w < 0 || u32(w) >= size { return 0 }
	n := u32(w)
	for i in 0 ..< PROF_SLOTS {
		e := &prof_tab[i]
		if e.key == nil { continue }
		w = snprintf(out[n:], uint(size - n), "%u\t%u\t%s\n", e.self, e.incl, e.key)
		if w < 0 || n + u32(w) >= size { break }
		n += u32(w)
	}
	return n
}

// The engine's interrupt handler (installed at pre-initialization).
interrupt_handler :: proc "c" (rt: ^Runtime, opaque: rawptr) -> i32 {
	if intrinsics.expect(prof_on != 0, false) && wj_the_realm.ctx != nil {
		prof_calls += 1
		if prof_calls % PROF_EVERY == 0 { prof_sample(wj_the_realm.ctx) }
	}
	if intrinsics.expect(!interrupted(), true) { return 0 }
	interrupt_count += 1
	return 1
}

// ---- console output (also what the realm uses before the console bindings exist) ----

@(export, link_name = "wj_console_text")
wj_console_text :: proc "c" (level: i32, text: [^]u8, n: uint) {
	wr_Engine_console(level, text, u32(n))
}

// ---- exceptions ----

// Where an error was thrown: the first "(url:line:col)" or "at url:line:col" frame of its stack (NUL-terminated, `n`
// bytes). `url` points into `stack` (or is an empty string).
stack_position :: proc "contextless" (stack: [^]u8, n: uint) -> (url: [^]u8, url_len: uint, line: i32, col: i32) {
	url = empty_ptr()
	if stack == nil { return }
	limit := 0
	for limit < int(n) && stack[limit] != 0 { limit += 1 }
	at := index_of(stack, limit, "    at ")
	if at < 0 { return }
	end := index_byte(stack[at:], int(n) - at, '\n')
	end = end >= 0 ? at + end : int(n)
	open := index_byte(stack[at:], end - at, '(')
	s := open >= 0 ? at + open + 1 : at + 7
	e := end
	if open >= 0 {
		close := index_byte(stack[s:], end - s, ')')
		if close >= 0 { e = s + close }
	}
	// url:line:col, the url possibly containing ':'
	c2, c1 := -1, -1
	for p := e - 1; p > s; p -= 1 {
		if stack[p] == ':' {
			if c2 < 0 { c2 = p } else { c1 = p; break }
		}
	}
	url = stack[s:]
	if c1 < 0 || c2 < 0 { url_len = uint(e - s); return }
	url_len = uint(c1 - s)
	line = atoi(stack[c1 + 1:])
	col = atoi(stack[c2 + 1:])
	return
}

// A growable text (libc heap), NUL-terminated.
@(private = "file")
Text :: struct { p: [^]u8, len, cap: uint }

@(private = "file")
text_append :: proc "contextless" (t: ^Text, s: [^]u8, n: uint) {
	if t.len + n + 1 > t.cap {
		c := t.cap != 0 ? t.cap : 256
		for c < t.len + n + 1 { c *= 2 }
		b := ([^]u8)(libc_realloc(t.p, c))
		if b == nil { return }
		t.p = b
		t.cap = c
	}
	if n > 0 { memcpy(t.p[t.len:], s, n) }
	t.len += n
	t.p[t.len] = 0
}

@(export, link_name = "wj_report_to_host")
wj_report_to_host :: proc "c" (ctx: ^Context, exc: JSValue) {
	stack: cstring
	stack_len: uint
	text: Text
	if JS_IsError(exc) {
		name := JS_GetPropertyStr(ctx, exc, "name")
		message := JS_GetPropertyStr(ctx, exc, "message")
		st := JS_GetPropertyStr(ctx, exc, "stack")
		n1, n2: uint
		s1 := JS_ToCStringLen2(ctx, &n1, name, false)
		s2 := JS_ToCStringLen2(ctx, &n2, message, false)
		if JS_HasException(ctx) { JS_FreeValue(ctx, JS_GetException(ctx)) }
		if s1 != nil { text_append(&text, ([^]u8)(rawptr(s1)), n1) }
		if s2 != nil && n2 > 0 { text_append(&text, raw_data(string(": ")), 2); text_append(&text, ([^]u8)(rawptr(s2)), n2) }
		if s1 != nil { JS_FreeCString(ctx, s1) }
		if s2 != nil { JS_FreeCString(ctx, s2) }
		if !is_undefined(st) { stack = JS_ToCStringLen2(ctx, &stack_len, st, false) }
		if JS_HasException(ctx) { JS_FreeValue(ctx, JS_GetException(ctx)) }
		JS_FreeValue(ctx, name)
		JS_FreeValue(ctx, message)
		JS_FreeValue(ctx, st)
	} else {
		// throw "x", throw {..}: shown as the value
		msg_len: uint
		msg := JS_ToCStringLen2(ctx, &msg_len, exc, false)
		if JS_HasException(ctx) { JS_FreeValue(ctx, JS_GetException(ctx)) }
		if msg != nil {
			text_append(&text, ([^]u8)(rawptr(msg)), msg_len)
			JS_FreeCString(ctx, msg)
		} else {
			text_append(&text, raw_data(string("(exception)")), 11)
		}
	}
	url, url_len, line, col := stack_position(([^]u8)(rawptr(stack)), stack_len)
	wr_Engine_reportException(text.p != nil ? text.p : empty_ptr(), u32(text.len), stack != nil ? ([^]u8)(rawptr(stack)) : empty_ptr(), u32(stack_len),
		url, u32(url_len), line, col)
	if stack != nil { JS_FreeCString(ctx, stack) }
	libc_free(text.p)
}

// Uncaught: the error event of the global first (load_errors.odin may cancel), then the console. Takes `exc`.
@(export, link_name = "wj_report_exception")
wj_report_exception :: proc "c" (ctx: ^Context, exc: JSValue) {
	if JS_IsUncatchableError(exc) {
		// the task was interrupted: the browser says so itself (slow script)
		JS_FreeValue(ctx, exc)
		return
	}
	if error_event_hook == nil || !error_event_hook(ctx, exc) { wj_report_to_host(ctx, exc) }
	JS_FreeValue(ctx, exc)
}

// The global's error event (native/js/odin/load_errors.odin's wj_fire_error_event, set by wj_preinit): false when
// nobody canceled it or there is none. Does not take `exc`.
error_event_hook: proc "c" (ctx: ^Context, exc: JSValue) -> bool

// Takes the pending exception and reports it.
@(export, link_name = "wj_report_pending")
wj_report_pending :: proc "c" (ctx: ^Context) {
	wj_report_exception(ctx, JS_GetException(ctx))
}

// ---- the C stack budget of JavaScript ----
// QuickJS bounds recursion from the stack top it was last given (JS_UpdateStackTop). Every entry from the browser calls
// wj_stack_enter, but only the outermost one moves the top: when the browser calls back into the engine from inside one
// of its own calls (a listener calling dispatchEvent, a getter that runs script...), the frames below stay counted, so
// recursion through the browser meets the same limit as plain recursion instead of starting over at each level and
// running past the end of the C stack. The C stack grows down: an entry nested in running frames is below the mark.

STACK_BUDGET :: 768 * 1024

@(private = "file") stack_mark: uintptr

// The current position of the C stack (the shadow stack in linear memory that C and Odin share): the address of a
// local of a frame of its own, as __builtin_frame_address(0) gave the C.
@(private = "file")
stack_pointer :: #force_no_inline proc "contextless" () -> uintptr {
	marker: u32
	intrinsics.volatile_store(&marker, 0)
	return uintptr(&marker)
}

// C recursion with no JavaScript frame in between (structured clone of a deeply nested value) never meets QuickJS's
// check: it asks here, against the same budget, measured from the same outermost entry.
@(export, link_name = "wj_stack_exhausted")
wj_stack_exhausted :: proc "c" () -> bool {
	sp := stack_pointer()
	return stack_mark != 0 && sp < stack_mark && stack_mark - sp > STACK_BUDGET
}

@(export, link_name = "wj_stack_enter")
wj_stack_enter :: proc "c" (ctx_in: ^Context) {
	ctx := ctx_in != nil ? ctx_in : wj_the_realm.ctx
	if ctx == nil { return }
	sp := stack_pointer()
	if sp >= stack_mark {
		JS_UpdateStackTop(JS_GetRuntime(ctx))
		stack_mark = sp
	}
}

// ---- small byte helpers (contextless: the glue has no Odin runtime) ----

// The index of byte `b` in p[0 ..< n], -1 when absent.
index_byte :: proc "contextless" (p: [^]u8, n: int, b: u8) -> int {
	for i in 0 ..< n { if p[i] == b { return i } }
	return -1
}

// The index of `needle` in p[0 ..< n], -1 when absent.
index_of :: proc "contextless" (p: [^]u8, n: int, needle: string) -> int {
	m := len(needle)
	if m == 0 { return 0 }
	for i := 0; i + m <= n; i += 1 {
		if p[i] == needle[0] && memcmp(p[i:], raw_data(needle), uint(m)) == 0 { return i }
	}
	return -1
}

// C's atoi: leading white space, a sign, decimal digits.
atoi :: proc "contextless" (p: [^]u8) -> i32 {
	i := 0
	for p[i] == ' ' || (p[i] >= '\t' && p[i] <= '\r') { i += 1 }
	neg := false
	if p[i] == '-' || p[i] == '+' { neg = p[i] == '-'; i += 1 }
	v: i32
	for p[i] >= '0' && p[i] <= '9' { v = v * 10 + i32(p[i] - '0'); i += 1 }
	return neg ? -v : v
}
