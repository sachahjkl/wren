// `wrentool threadtime <spans.tsv>...`: whose work the window thread did during a load, from the files WREN_SPANS leaves
// (base/spans.odin): time by origin and class, up to the first contentful paint, the largest, and the moment the thread settled.
// Each instant of the thread goes to the innermost owner (a Task's, inside it a Work's); a frame's phases outside any task
// are the browser's input and paint, and its wait is no work at all. With several files, the median of each row and its range.
package threadtime

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "wb:tools/tooling"

FLAGS :: "-Top= -Tasks"
// What a table shows by default: the rows that weigh most.
TOP_ROWS :: 25
// A thread has settled when, after the load event, a window this long passes with less than this share of it busy.
SETTLE_WINDOW_MS :: 500.0
SETTLE_BUSY_SHARE :: 0.1
// The percentiles of a run of several.
MEDIAN :: 0.5
// What a span table says of who works, as the browser writes them (base.Work_Class, the names of the wait phases).
CLASS_BACKGROUND :: "Background"
CLASS_ARRIVAL :: "Arrival"
CLASS_INPUT :: "Input"
BROWSER_ORIGIN :: "(browser)"
SOURCES :: "/src/"   // (a label is a path of the machine that built it: the part after this)
MARK_NAVIGATE :: "navigate"
MARK_CONTENTFUL :: "first-contentful-paint"
MARK_LARGEST :: "largest-contentful-paint"   // (each larger one: the last counts)
MARK_LOAD :: "load"
// The columns of a row: start, duration, thread, kind, label, then class, page, origin, third party for what has an owner.
COLUMNS_MIN :: 5
COLUMNS_OWNED :: 9

Owner :: struct {
	class:       string,
	origin:      string,   // resolved from its number (BROWSER_ORIGIN: none)
	third_party: bool,
}

Span :: struct {
	start, end: f64,
	kind:       string,
	label:      string,
	owner:      Owner,
}

// A stretch of the thread with one owner.
Segment :: struct {
	start, end: f64,
	owner:      Owner,
	task:       string,   // who posted the task it is in
}

// One load, from one file.
Load :: struct {
	navigate, contentful, largest, load_event: f64,   // ms in the trace; -1: not seen
	settled:  f64,                           // -1: not in the trace
	segments: []Segment,
}

Key :: struct {
	owner: Owner,
	task:  string,
}

// Up to the first contentful paint, the largest and up to settled, ms.
Sums :: struct {
	contentful, largest, settled: f64,
}

Report :: struct {
	busy:     Sums,
	by_owner: map[Owner]Sums,
	by_task:  map[Key]Sums,
}

run :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, FLAGS)
	if !ok { return 2 }
	if len(f.rest) == 0 { fmt.eprintln("wrentool threadtime <spans.tsv>... [-Top n] [-Tasks]"); return 2 }
	reports := make([dynamic]Report)
	loads := make([dynamic]Load)
	for path in f.rest {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil { fmt.eprintfln("cannot read %s", path); return 1 }
		l := load_read(string(data))
		if l.contentful < 0 && l.load_event < 0 { fmt.eprintfln("%s: no load in it", path); continue }
		append(&loads, l)
		append(&reports, report_of(l))
	}
	print_report(loads[:], reports[:], tooling.flag_int(f, "-Top", TOP_ROWS), tooling.flag_has(f, "-Tasks"))
	return 0
}

// The window thread's spans of a file, its marks and what its numbers mean, as stretches of one owner.
load_read :: proc(text: string) -> Load {
	Row :: struct {
		start, ms: f64,
		thread:    string,
		cols:      []string,
	}
	rows := make([dynamic]Row, context.temp_allocator)
	thread := ""
	for line in strings.split_lines(text, context.temp_allocator) {
		cols := strings.split(line, "\t", context.temp_allocator)
		if len(cols) < COLUMNS_MIN { continue }
		start, _ := strconv.parse_f64(cols[0])
		ms, _ := strconv.parse_f64(cols[1])
		append(&rows, Row{start, ms, cols[2], cols})
		if cols[3] == "Mark" && (cols[4] == MARK_LOAD || thread == "") { thread = cols[2] }   // (the window thread says the load)
	}
	origins := make(map[string]string, context.temp_allocator)
	for r in rows {
		if r.thread == thread && r.cols[3] == "Origin" && len(r.cols) >= COLUMNS_OWNED { origins[r.cols[7]] = r.cols[4] }
	}
	l := Load{navigate = -1, contentful = -1, largest = -1, load_event = -1, settled = -1}
	spans := make([dynamic]Span, context.temp_allocator)
	for r in rows {
		if r.thread != thread && r.cols[3] != "Mark" { continue }
		switch r.cols[3] {
		case "Mark":
			switch r.cols[4] {
			case MARK_NAVIGATE: l.navigate, l.contentful, l.largest, l.load_event = r.start, -1, -1, -1   // (the blank page before it had its own)
			case MARK_CONTENTFUL: if l.contentful < 0 { l.contentful = r.start }
			case MARK_LARGEST: l.largest = r.start
			case MARK_LOAD: if l.load_event < 0 { l.load_event = r.start }
			}
		case "Phase":
			append(&spans, Span{start = r.start, end = r.start + r.ms, kind = "Phase", label = r.cols[4]})
		case "Task", "Work":
			if len(r.cols) < COLUMNS_OWNED { continue }
			origin, known := origins[r.cols[7]]
			at := strings.last_index(r.cols[4], SOURCES)
			append(&spans, Span{start = r.start, end = r.start + r.ms, kind = r.cols[3], label = at >= 0 ? r.cols[4][at + len(SOURCES):] : r.cols[4],
				owner = Owner{r.cols[5], known ? origin : BROWSER_ORIGIN, r.cols[8] == "true"}})
		}
	}
	l.segments = segments_of(spans[:])
	l.settled = settled_at(l)
	return l
}

// The spans of a thread, nested by their times, as stretches: the innermost that has an owner says whose it is.
segments_of :: proc(spans: []Span) -> []Segment {
	slice.sort_by(spans, proc(a, b: Span) -> bool { return a.start < b.start || (a.start == b.start && a.end > b.end) })
	out := make([dynamic]Segment)
	stack := make([dynamic]Span, context.temp_allocator)
	emit :: proc(out: ^[dynamic]Segment, stack: []Span, from, to: f64) {
		if to <= from || len(stack) == 0 { return }
		top := stack[len(stack) - 1]
		if top.kind == "Phase" && (top.label == "wait" || top.label == "idle") { return }
		s := Segment{start = from, end = to, owner = Owner{CLASS_INPUT, BROWSER_ORIGIN, false}}
		found := false
		#reverse for sp in stack {
			if sp.kind == "Task" { s.task = sp.label; if !found { s.owner = sp.owner }; break }
			if sp.kind == "Work" && !found { s.owner, found = sp.owner, true }
		}
		append(out, s)
	}
	at := 0.0
	for sp in spans {
		for len(stack) > 0 && stack[len(stack) - 1].end <= sp.start {
			end := stack[len(stack) - 1].end
			emit(&out, stack[:], at, end)
			at = max(at, end)
			pop(&stack)
		}
		emit(&out, stack[:], at, sp.start)
		at = max(at, sp.start)
		append(&stack, sp)
	}
	for len(stack) > 0 {
		top := stack[len(stack) - 1]
		emit(&out, stack[:], at, top.end)
		at = max(at, top.end)
		pop(&stack)
	}
	return out[:]
}

// When the thread settled: the first end of work from the load event on after which a window passes nearly free. -1: the trace ends first.
settled_at :: proc(l: Load) -> f64 {
	if l.load_event < 0 || len(l.segments) == 0 { return -1 }
	last := l.segments[len(l.segments) - 1].end
	for seg, i in l.segments {
		t := seg.end
		if t < l.load_event { continue }
		if t + SETTLE_WINDOW_MS > last { return -1 }
		busy := 0.0
		for s in l.segments[i + 1:] {
			if s.start >= t + SETTLE_WINDOW_MS { break }
			busy += min(s.end, t + SETTLE_WINDOW_MS) - s.start
		}
		if busy < SETTLE_WINDOW_MS * SETTLE_BUSY_SHARE { return t }
	}
	return -1
}

@(private = "file")
sums_add :: proc(a, b: Sums) -> Sums { return {a.contentful + b.contentful, a.largest + b.largest, a.settled + b.settled} }

// The time of each owner and of each task's poster inside the windows of the load.
report_of :: proc(l: Load) -> (r: Report) {
	r.by_owner = make(map[Owner]Sums)
	r.by_task = make(map[Key]Sums)
	from := max(l.navigate, 0)
	settled := l.settled >= 0 ? l.settled : (len(l.segments) > 0 ? l.segments[len(l.segments) - 1].end : 0)
	for s in l.segments {
		add: Sums
		if l.contentful >= 0 { add.contentful = max(min(s.end, l.contentful) - max(s.start, from), 0) }
		if l.largest >= 0 { add.largest = max(min(s.end, l.largest) - max(s.start, from), 0) }
		add.settled = max(min(s.end, settled) - max(s.start, from), 0)
		if add.settled == 0 { continue }
		r.busy = sums_add(r.busy, add)
		r.by_owner[s.owner] = sums_add(r.by_owner[s.owner], add)
		k := Key{s.owner, s.task}
		r.by_task[k] = sums_add(r.by_task[k], add)
	}
	return
}

// The median and the range of `values`.
@(private = "file")
spread :: proc(values: []f64) -> (mid, low, high: f64) {
	slice.sort(values)
	return values[int(f64(len(values) - 1) * MEDIAN)], values[0], values[len(values) - 1]
}

@(private = "file")
cell :: proc(values: []f64) -> string {
	mid, low, high := spread(values)
	if len(values) == 1 { return fmt.tprintf("%.0f", mid) }
	return fmt.tprintf("%.0f (%.0f-%.0f)", mid, low, high)
}

// A line per key, the heaviest up to settled first.
@(private = "file")
print_rows :: proc($K: typeid, reports: []Report, keys: map[K]bool, get: proc(r: ^Report, k: K) -> Sums, name: proc(k: K) -> string, top: int) {
	Row :: struct {
		key:    K,
		weight: f64,
	}
	rows := make([dynamic]Row, context.temp_allocator)
	for k in keys {
		w := make([]f64, len(reports), context.temp_allocator)
		for &r, i in reports { w[i] = get(&r, k).settled }
		mid, _, _ := spread(w)
		append(&rows, Row{k, mid})
	}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool { return a.weight > b.weight })
	for row, n in rows {
		if n >= top { fmt.printfln("(%d more)", len(rows) - top); break }
		c := make([]f64, len(reports), context.temp_allocator)
		g := make([]f64, len(reports), context.temp_allocator)
		s := make([]f64, len(reports), context.temp_allocator)
		for &r, i in reports { v := get(&r, row.key); c[i], g[i], s[i] = v.contentful, v.largest, v.settled }
		fmt.printfln("%-14s %-18s %-20s %s", cell(c), cell(g), cell(s), name(row.key))
	}
}

@(private = "file")
owner_name :: proc(o: Owner) -> string {
	return fmt.tprintf("%-10s %-3s %s", o.class, o.third_party ? "3rd" : "", o.origin)
}

print_report :: proc(loads: []Load, reports: []Report, top: int, tasks: bool) {
	if len(reports) == 0 { return }
	n := len(reports)
	fcp := make([]f64, n, context.temp_allocator)
	largest := make([]f64, n, context.temp_allocator)
	load := make([]f64, n, context.temp_allocator)
	settled := make([]f64, n, context.temp_allocator)
	unsettled := 0
	for l, i in loads {
		from := max(l.navigate, 0)
		fcp[i], largest[i], load[i], settled[i] = l.contentful - from, l.largest - from, l.load_event - from, l.settled - from
		if l.settled < 0 { settled[i] = l.segments[len(l.segments) - 1].end - from; unsettled += 1 }
	}
	fmt.printfln("%d load(s), ms from the navigation: first contentful paint %s, largest %s, load %s, settled %s%s", n, cell(fcp), cell(largest), cell(load), cell(settled), unsettled > 0 ? fmt.tprintf(" (%d did not settle: the end of the trace)", unsettled) : "")
	bc := make([]f64, n, context.temp_allocator)
	bs := make([]f64, n, context.temp_allocator)
	owners := make(map[Owner]bool, context.temp_allocator)
	task_keys := make(map[Key]bool, context.temp_allocator)
	classes := make(map[Owner]bool, context.temp_allocator)
	for &r, i in reports {
		bc[i], bs[i] = r.busy.contentful, r.busy.settled
		for o in r.by_owner { owners[o] = true; classes[Owner{class = o.class, third_party = o.third_party}] = true }
		for k in r.by_task { task_keys[k] = true }
	}
	fmt.printfln("the thread busy: %s up to the paint, %s up to settled", cell(bc), cell(bs))
	fmt.printfln("%-14s %-18s %-20s %s", "to the paint", "to the largest", "to settled", "class, party, origin")
	print_rows(Owner, reports, classes, proc(r: ^Report, k: Owner) -> Sums {
		s: Sums
		for o, v in r.by_owner { if o.class == k.class && o.third_party == k.third_party { s = sums_add(s, v) } }
		return s
	}, proc(k: Owner) -> string { return fmt.tprintf("%-10s %s", k.class, k.third_party ? "third party" : "first party, or the browser") }, top)
	fmt.println()
	print_rows(Owner, reports, owners, proc(r: ^Report, k: Owner) -> Sums { return r.by_owner[k] }, owner_name, top)
	if !tasks { return }
	fmt.println()
	print_rows(Key, reports, task_keys, proc(r: ^Report, k: Key) -> Sums { return r.by_task[k] }, proc(k: Key) -> string { return fmt.tprintf("%s  by %s", owner_name(k.owner), k.task) }, top)
}
