#+build windows
package layout

import "core:fmt"
import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import win "core:sys/windows"
import "wb:dom"
import "wb:html"
import "wb:style"

// Full passes on a fresh layout (a page load) and on a reused one, on the pages tools\perf.ps1 generates. Opt-in:
//   set WREN_LOADBENCH=1 & odin test src/layout -collection:wb=src -o:speed -define:ODIN_TEST_TRACK_MEMORY=false
//       -define:ODIN_TEST_NAMES=layout.bench_load
// WREN_LOADBENCH_PAGES=p10k,p50k (default), WREN_LOADBENCH_ROUNDS (7). With WREN_LOADBENCH_SAMPLE=<seconds> (build with
// -debug for symbols), passes on the largest page are repeated that long under a sampling profiler that walks the stack of
// the test thread every millisecond: self and inclusive shares per function.
@(test)
bench_load :: proc(t: ^testing.T) {
	if os.get_env("WREN_LOADBENCH", context.temp_allocator) == "" { return }
	defer shutdown_threads()
	// the browser's allocators, not the test runner's
	context.allocator = runtime.heap_allocator()
	temp: runtime.Arena
	defer runtime.arena_destroy(&temp)
	context.temp_allocator = runtime.arena_allocator(&temp)
	env_pages := os.get_env("WREN_LOADBENCH_PAGES", context.allocator)
	defer delete(env_pages)   // (not the default below: a literal)
	pages := env_pages != "" ? env_pages : "p10k,p50k"
	rounds := 7
	if r := os.get_env("WREN_LOADBENCH_ROUNDS", context.temp_allocator); r != "" { rounds = max(1, parse_int(r)) }
	sample_s := parse_int(os.get_env("WREN_LOADBENCH_SAMPLE", context.temp_allocator))
	names := strings.split(pages, ",")
	defer delete(names)
	for name in names {
		data, err := os.read_entire_file(fmt.tprintf("build/perf/%s.html", name), context.allocator)
		if err != nil { fmt.println("missing page", name); continue }
		defer delete(data)
		doc := dom.document_create(nil)
		defer dom.document_destroy(doc)
		html.parse_into(doc, doc.root, data, 4_000_000)
		ss := style.settings_default()
		eng := style.engine_make(ss)
		style.settings_destroy(&ss)
		defer style.engine_destroy(eng)
		style.sync_document_sheets(eng, doc, "about:test")
		st := style.compute_styles(eng, doc, {})
		defer style.styled_destroy(st)
		set := settings_default()
		if th := os.get_env("WREN_LOADBENCH_THREADS", context.temp_allocator); th != "" { set.threads = parse_int(th) }
		if mb := os.get_env("WREN_LOADBENCH_MIN_BOXES", context.temp_allocator); mb != "" { set.threads_min_boxes = parse_int(mb) }
		in_ := Input{doc = doc, styled = st, settings = &set, text = bench_text_api(), viewport = {1500, 900}, scale = 1.5, band_h = 256}

		cold := make([]f64, rounds, context.temp_allocator)
		warm := make([]f64, rounds, context.temp_allocator)
		cs := make([][5]f32, rounds, context.temp_allocator)
		ws := make([][5]f32, rounds, context.temp_allocator)
		nb, ni: int
		for r in 0 ..< rounds {
			l: Layout
			t0 := time.tick_now()
			run(&l, in_)
			cold[r], cs[r] = time.duration_milliseconds(time.tick_since(t0)), l.stats
			l.valid = false
			t1 := time.tick_now()
			run(&l, in_)
			warm[r], ws[r] = time.duration_milliseconds(time.tick_since(t1)), l.stats
			nb, ni = len(l.boxes), len(l.items)
			if r == 0 { fmt.printfln("LOADBENCH %s contexts ahead %d taken %d", name, l.pre_counts[0], l.pre_counts[1]) }
			if r == 0 { fmt.printfln("LOADBENCH %s nodes %d (used %d) inline_items %d lines %d frags %d fonts %d", name, doc.nodes.count, doc.nodes.used, len(l.inline_items), len(l.lines), len(l.frags), len(l.fonts)) }
			destroy(&l)
		}
		c, w := bench_median_stats(cs), bench_median_stats(ws)
		fmt.printfln("LOADBENCH %s (%d boxes, %d items) size_of Box %d Box_Info %d Inline_Item %d Line %d Frag %d Display_Item %d", name, nb, ni,
			size_of(Box), size_of(Box_Info), size_of(Inline_Item), size_of(Line), size_of(Frag), size_of(Display_Item))
		fmt.printfln("LOADBENCH size_of Computed %d, Node %d", size_of(style.Computed), size_of(dom.Node))
		fmt.printfln("LOADBENCH %s cold %6.2f ms [tree %.2f layout %.2f finish %.2f display %.2f bands %.2f]", name, bench_median(cold), c[0], c[1], c[2], c[3], c[4])
		fmt.printfln("LOADBENCH %s warm %6.2f ms [tree %.2f layout %.2f finish %.2f display %.2f bands %.2f]", name, bench_median(warm), w[0], w[1], w[2], w[3], w[4])

		// WREN_LOADBENCH_RESIZE=<steps>: incremental passes at a width that changes every pass (a window being resized),
		// medians of each step; with WREN_LOADBENCH_SAMPLE, those are what is sampled
		resize_steps := parse_int(os.get_env("WREN_LOADBENCH_RESIZE", context.temp_allocator))
		if resize_steps > 0 {
			rl: Layout
			run(&rl, in_)
			tot := make([]f64, resize_steps)
			st5 := make([][5]f32, resize_steps)
			defer { delete(tot); delete(st5) }
			ahead, taken := 0, 0
			// WREN_LOADBENCH_RESIZE_GAP_MS: a pause between passes, as between the frames of a window (threads go idle)
			gap := parse_int(os.get_env("WREN_LOADBENCH_RESIZE_GAP_MS", context.temp_allocator))
			// WREN_LOADBENCH_RESIZE_AXIS=h: the height changes instead (a window resized from its bottom edge), =wh: both
			axis := os.get_env("WREN_LOADBENCH_RESIZE_AXIS", context.allocator)   // (the temp allocator is emptied every step)
			defer delete(axis)
			for k in 0 ..< resize_steps {
				if gap > 0 { time.sleep(time.Duration(gap) * time.Millisecond) }
				ri := in_
				if axis != "h" { ri.viewport.x = resize_width(k) }
				if axis == "h" || axis == "wh" { ri.viewport.y = resize_width(k) - 600 }
				t0 := time.tick_now()
				run(&rl, ri)
				tot[k], st5[k] = time.duration_milliseconds(time.tick_since(t0)), rl.stats
				ahead, taken = ahead + rl.pre_counts[0], taken + rl.pre_counts[1]
				if rl.last_pass != .Incremental { fmt.printfln("RESIZEBENCH %s step %d: %v (%s)", name, k, rl.last_pass, rl.inc.fallback) }
				free_all(context.temp_allocator)
			}
			s := bench_median_stats(st5)
			fmt.printfln("RESIZEBENCH %s %d steps: median %6.2f ms p95 %6.2f [tree %.2f layout %.2f finish %.2f display %.2f bands %.2f] ahead %d taken %d",
				name, resize_steps, bench_median(tot), bench_pct(tot, 0.95), s[0], s[1], s[2], s[3], s[4], ahead, taken)
			if sample_s > 0 && name == names[len(names) - 1] {
				sampler_start()
				end := time.tick_now()
				n := 0
				for time.duration_seconds(time.tick_since(end)) < f64(sample_s) {
					ri := in_
					ri.viewport.x = resize_width(n)
					run(&rl, ri)
					free_all(context.temp_allocator)
					n += 1
				}
				sampler_stop()
				fmt.printfln("SAMPLE %s: %d resize passes", name, n)
				sampler_report()
				sample_s = 0
			}
			destroy(&rl)
		}

		if sample_s > 0 && name == names[len(names) - 1] {
			// WREN_LOADBENCH_WARM=1: passes on a reused layout (no growth of its arrays)
			warm_only := os.get_env("WREN_LOADBENCH_WARM", context.temp_allocator) != ""
			wl: Layout
			if warm_only { run(&wl, in_) }
			sampler_start()
			end := time.tick_now()
			n := 0
			for time.duration_seconds(time.tick_since(end)) < f64(sample_s) {
				if warm_only {
					wl.valid = false
					run(&wl, in_)
				} else {
					l: Layout
					run(&l, in_)
					destroy(&l)
				}
				n += 1
			}
			sampler_stop()
			destroy(&wl)
			fmt.printfln("SAMPLE %s: %d %s passes", name, n, warm_only ? "warm" : "cold")
			sampler_report()
		}
		free_all(context.temp_allocator)
	}
}

// A window dragged back and forth between 1100 and 1500 px, a few px a step.
@(private = "file")
resize_width :: proc(k: int) -> f32 {
	p := k % 160
	return p < 80 ? 1500 - f32(p) * 5 : 1100 + f32(p - 80) * 5
}

@(private = "file")
bench_pct :: proc(v: []f64, q: f64) -> f64 {
	s := slice.clone(v, context.temp_allocator)
	slice.sort(s)
	return s[min(int(f64(len(s)) * q), len(s) - 1)]
}

@(private = "file")
parse_int :: proc(s: string) -> int {
	v := 0
	for ch in s { if ch >= '0' && ch <= '9' { v = v * 10 + int(ch - '0') } }
	return v
}

// Text measured as a fixed advance per byte: the pass without the font (the browser caches advances per font and size).
bench_text_api :: proc() -> Text_Api {
	return Text_Api{
		font = proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font { return 1 },
		width = proc(user: rawptr, f: Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(len(text)) },
		metrics = proc(user: rawptr, f: Font, size: f32) -> Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} },
		concurrent = true,
	}
}

bench_median :: proc(v: []f64) -> f64 {
	s := slice.clone(v, context.temp_allocator)
	slice.sort(s)
	return s[len(s) / 2]
}

bench_median_stats :: proc(v: [][5]f32) -> (o: [5]f64) {
	x := make([]f64, len(v), context.temp_allocator)
	for k in 0 ..< 5 {
		for r, i in v { x[i] = f64(r[k]) }
		o[k] = bench_median(x)
	}
	return
}

////////////////////////////////
// Sampling profiler with stack walks (the sampler never allocates while the target is suspended)

foreign import k32 "system:Kernel32.lib"
foreign import dbghelp "system:dbghelp.lib"

@(private = "file")
@(default_calling_convention = "system")
foreign k32 {
	RtlLookupFunctionEntry :: proc(pc: u64, image_base: ^u64, history: rawptr) -> rawptr ---
	RtlVirtualUnwind :: proc(handler_type: u32, image_base: u64, pc: u64, entry: rawptr, ctx: ^win.CONTEXT, handler_data: ^rawptr, establisher: ^u64, ptrs: rawptr) -> rawptr ---
}

@(private = "file")
SYMBOL_INFO :: struct {
	SizeOfStruct, TypeIndex: u32,
	Reserved:   [2]u64,
	Index, Size: u32,
	ModBase:    u64,
	Flags:      u32,
	Value, Address: u64,
	Register, Scope, Tag, NameLen, MaxNameLen: u32,
	Name:       [1]u8,
}

@(private = "file")
@(default_calling_convention = "system")
foreign dbghelp {
	SymInitialize :: proc(process: win.HANDLE, search_path: cstring, invade: win.BOOL) -> win.BOOL ---
	SymSetOptions :: proc(options: u32) -> u32 ---
	SymFromAddr :: proc(process: win.HANDLE, address: u64, displacement: ^u64, symbol: ^SYMBOL_INFO) -> win.BOOL ---
	SymGetLineFromAddr64 :: proc(process: win.HANDLE, address: u64, displacement: ^u32, line: ^IMAGEHLP_LINE64) -> win.BOOL ---
}

@(private = "file")
IMAGEHLP_LINE64 :: struct {
	SizeOfStruct: u32,
	Key:          rawptr,
	LineNumber:   u32,
	FileName:     cstring,
	Address:      u64,
}

@(private = "file")
DEPTH :: 48

@(private = "file")
Sampler :: struct {
	target:  win.HANDLE,
	th:      ^thread.Thread,
	stop:    bool,
	frames:  [][DEPTH]u64,
	depth:   []u8,
	n:       int,
}

@(private = "file")
smp: Sampler

@(private = "file")
sampler_start :: proc() {
	win.timeBeginPeriod(1)
	win.DuplicateHandle(win.GetCurrentProcess(), win.GetCurrentThread(), win.GetCurrentProcess(), &smp.target, 0, false, win.DUPLICATE_SAME_ACCESS)
	smp.frames = make([][DEPTH]u64, 200_000)
	smp.depth = make([]u8, 200_000)
	smp.n = 0
	smp.stop = false
	smp.th = thread.create(proc(_: ^thread.Thread) {
		for !sync.atomic_load(&smp.stop) {
			win.Sleep(1)
			if smp.n >= len(smp.frames) { continue }
			if win.SuspendThread(smp.target) == ~u32(0) { continue }
			ctx: win.CONTEXT
			ctx.ContextFlags = 0x10000B   // CONTEXT_FULL (AMD64)
			if win.GetThreadContext(smp.target, &ctx) {
				d := 0
				for d < DEPTH && ctx.Rip != 0 {
					smp.frames[smp.n][d] = ctx.Rip
					d += 1
					base: u64
					fe := RtlLookupFunctionEntry(ctx.Rip, &base, nil)
					if fe == nil {
						ctx.Rip = (^u64)(uintptr(ctx.Rsp))^
						ctx.Rsp += 8
					} else {
						hd: rawptr
						ef: u64
						RtlVirtualUnwind(0, base, ctx.Rip, fe, &ctx, &hd, &ef, nil)
					}
				}
				smp.depth[smp.n] = u8(d)
				smp.n += 1
			}
			win.ResumeThread(smp.target)
		}
	})
	thread.start(smp.th)
}

@(private = "file")
sampler_stop :: proc() {
	sync.atomic_store(&smp.stop, true)
	thread.join(smp.th)
	thread.destroy(smp.th)
	win.CloseHandle(smp.target)
	win.timeEndPeriod(1)
}

@(private = "file")
sampler_report :: proc() {
	defer { delete(smp.frames); delete(smp.depth) }
	ph := win.GetCurrentProcess()
	SymSetOptions(0x2 | 0x4)
	SymInitialize(ph, nil, true)
	names := make(map[u64]string, 1024, context.temp_allocator)
	buf: [1024]u8
	name_of :: proc(addr: u64, ph: win.HANDLE, buf: []u8, names: ^map[u64]string) -> string {
		if n, ok := names[addr]; ok { return n }
		info := (^SYMBOL_INFO)(raw_data(buf))
		info^ = {}
		info.SizeOfStruct = size_of(SYMBOL_INFO)
		info.MaxNameLen = u32(len(buf) - size_of(SYMBOL_INFO))
		disp: u64
		n := fmt.tprintf("?%x", addr)
		if SymFromAddr(ph, addr, &disp, info) { n = strings.clone(string(cstring(&info.Name[0])), context.temp_allocator) }
		names[addr] = n
		return n
	}
	self := make(map[string]int, 256, context.temp_allocator)
	incl := make(map[string]int, 256, context.temp_allocator)
	seen := make(map[string]bool, 64, context.temp_allocator)
	for i in 0 ..< smp.n {
		clear(&seen)
		for d in 0 ..< int(smp.depth[i]) {
			nm := name_of(smp.frames[i][d], ph, buf[:], &names)
			if d == 0 { self[nm] += 1 }
			if !seen[nm] { seen[nm] = true; incl[nm] += 1 }
		}
	}
	Row :: struct { k: string, v: int }
	top :: proc(m: map[string]int, n, total: int, what: string) {
		rows := make([dynamic]Row, context.temp_allocator)
		for k, v in m { append(&rows, Row{k, v}) }
		slice.sort_by(rows[:], proc(a, b: Row) -> bool { return a.v > b.v })
		fmt.printfln("SAMPLE -- %s (%d samples)", what, total)
		for r, i in rows { if i >= n { break }; fmt.printfln("SAMPLE %5.1f %%  %6d  %s", f64(r.v) * 100 / f64(max(total, 1)), r.v, r.k) }
	}
	top(self, 45, smp.n, "self")
	top(incl, 70, smp.n, "inclusive")
	// WREN_LOADBENCH_LINES=<file.odin>: self samples by source line of that file
	if want := os.get_env("WREN_LOADBENCH_LINES", context.temp_allocator); want != "" {
		by_line := make(map[string]int, 256, context.temp_allocator)
		total := 0
		for i in 0 ..< smp.n {
			if smp.depth[i] == 0 { continue }
			ln := IMAGEHLP_LINE64{SizeOfStruct = size_of(IMAGEHLP_LINE64)}
			disp: u32
			if !SymGetLineFromAddr64(ph, smp.frames[i][0], &disp, &ln) { continue }
			file := string(ln.FileName)
			if !strings.has_suffix(file, want) { continue }
			by_line[fmt.tprintf("%s:%d", want, ln.LineNumber)] += 1
			total += 1
		}
		top(by_line, 40, total, fmt.tprintf("self by line in %s", want))
	}
}
