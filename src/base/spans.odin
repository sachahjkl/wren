package base

// WREN_SPANS=<prefix>: what a process's threads spend their time on, span by span, written as <prefix>.<pid>.tsv when the
// process ends (start ms, duration ms, thread, kind, label, and for what has an owner: class, page, origin, third party;
// `wrentool threadtime` reads them). For the measuring tools: the frame's phases and the sampling
// profile say how much, these say in which order and on behalf of what: which task, which script, how long it waited for its
// bytes and for its bytecode, what the engine did inside it. A span is one store in a table made once; off, one test of a flag.
// Spans of one thread nest by their times: what a span spent itself is its time less the spans inside it.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

SPANS_ENV :: "WREN_SPANS"
SPANS_MAX :: 1 << 22
SPANS_LABEL_BYTES :: 64 << 20
@(private = "file") NS_PER_MS :: 1e6

Span_Kind :: enum u8 {
	Mark,         // an instant of the load: DOMContentLoaded, load
	Phase,        // a phase of a frame (the shell)
	Task,         // a task or a timer of the loop, by who posted it
	Script,       // a script runs (js_run)
	Realm,        // a realm is made
	Guest,        // an outermost call into the engine
	Host,         // an import of the engine, when it took long enough to say
	Compile,      // the engine's front end
	Deserialize,  // bytecode read into the realm
	Gc,
	Jit,          // a translation to Wasm
	Fetch,        // a script's life: from its request to its last byte
	Compile_Wait, // ... from there to its bytecode (off-thread compile)
	Turn_Wait,    // ... from there to its run
	Off_Thread,   // a compile thread at work
	Work,         // inside a task, what another owner does: a script's run, a response's callback, a listener
	Origin,       // not time: this thread's number for an origin (Work.origin), its name the label
}

// The classes of work on a thread. What a loop may put off is the last one (host: Scheduling).
Work_Class :: enum u8 {
	Background,   // timers, and whatever nobody said is more
	Arrival,      // parsing, and what arrives for it: scripts, sheets, what the pump does next
	Input,        // input and paint
}

// Who a task or a timer works for, and what kind of work it is. The zero value: the browser's own, in the background.
Work :: struct {
	page:        u32,    // the document's (0: the browser's own work)
	origin:      u32,    // the script's that asked for it, as far as it is known, numbered by the thread's loop (0: none)
	class:       Work_Class,
	third_party: bool,   // that origin is not of the site of the page on top
}

Span :: struct {
	start, ns: i64,
	label:     string,
	line:      i32,
	thread:    i32,
	kind:      Span_Kind,
	work:      Work,
}

@(private = "file")
Spans :: struct {
	on:     bool,
	path:   string,
	table:  []Span,
	count:  int,      // atomic
	labels: []u8,
	used:   int,      // atomic
	origin: time.Tick,
}

@(private = "file")
spans: Spans

// From main, before anything to measure: nothing without WREN_SPANS.
spans_start :: proc() {
	prefix := os.get_env(SPANS_ENV, context.temp_allocator)
	if prefix == "" { return }
	spans_open(fmt.aprintf("%s.%d.tsv", prefix, os.get_pid(), allocator = process_allocator()), SPANS_MAX, SPANS_LABEL_BYTES)
}

// Recording starts, for `path` (owned), with room for `max_spans` spans and `label_bytes` of copied labels.
@(private)
spans_open :: proc(path: string, max_spans, label_bytes: int) {
	spans.path = path
	spans.table = make([]Span, max_spans, process_allocator())
	spans.labels = make([]u8, label_bytes, process_allocator())
	spans.origin = time.tick_now()
	spans.on = true
}

// Recording ends and what it held goes.
@(private)
spans_close :: proc() {
	delete(spans.path, process_allocator())
	delete(spans.table, process_allocator())
	delete(spans.labels, process_allocator())
	spans = {}
}

spans_enabled :: #force_inline proc "contextless" () -> bool { return spans.on }

// The start of a span: what span_add takes. 0 when spans are off.
span_now :: #force_inline proc "contextless" () -> i64 {
	if !spans.on { return 0 }
	return i64(time.tick_diff(spans.origin, time.tick_now()))
}

// A span from `start` (span_now) to now. A string that does not outlive the call is copied (`copy_label`).
span_add :: proc "contextless" (kind: Span_Kind, start: i64, label: string, line: i32 = 0, copy_label := false, work := Work{}) {
	if !spans.on { return }
	span_add_until(kind, start, span_now(), label, line, copy_label, work)
}

span_add_until :: proc "contextless" (kind: Span_Kind, start, end: i64, label: string, line: i32 = 0, copy_label := false, work := Work{}) {
	if !spans.on { return }
	i := sync.atomic_add(&spans.count, 1)
	if i >= len(spans.table) { return }
	text := label
	if copy_label {
		at := sync.atomic_add(&spans.used, len(label))
		text = ""
		if at + len(label) <= len(spans.labels) {
			text = string(spans.labels[at:][:len(label)])
			copy(spans.labels[at:][:len(label)], label)
		}
	}
	spans.table[i] = Span{start = start, ns = end - start, label = text, line = line, thread = i32(sync.current_thread_id()), kind = kind, work = work}
}

span_mark :: proc "contextless" (label: string) { span_add(.Mark, span_now(), label) }

// Process end.
spans_write :: proc() {
	if !spans.on { return }
	n := min(sync.atomic_load(&spans.count), len(spans.table))
	b := strings.builder_make(process_allocator())
	defer strings.builder_destroy(&b)
	for s in spans.table[:n] {
		fmt.sbprintf(&b, "%.3f\t%.3f\t%d\t%v\t%s", f64(s.start) / NS_PER_MS, f64(s.ns) / NS_PER_MS, s.thread, s.kind, s.label)
		if s.line != 0 { fmt.sbprintf(&b, ":%d", s.line) }
		if s.kind == .Task || s.kind == .Work || s.kind == .Origin || s.kind == .Realm { fmt.sbprintf(&b, "\t%v\t%d\t%d\t%v", s.work.class, s.work.page, s.work.origin, s.work.third_party) }
		strings.write_byte(&b, '\n')
	}
	_ = os.write_entire_file(spans.path, transmute([]byte)strings.to_string(b))
}
