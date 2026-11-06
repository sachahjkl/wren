package wasm

// Polls in place of the epoch, for the JavaScript engine's image. Wasmtime's epoch is a check at every function entry and
// every loop head of a module, fixed per Wasmtime engine: 12 to 20 % of all of the JavaScript engine's code, and two
// checks for each bytecode the interpreter runs (docs/performance.md, rounds 34 and 36). What it gives is one thing: at
// a place where the module may run forever, the host gets the thread back. Such a place is a loop; a recursion ends on the
// stack's limit. So the image's loops carry the check themselves, and the image runs on a Wasmtime engine of its own,
// without epochs (engine.odin):
//
//   * At build time `poll_instrument` puts at the head of every Wasm loop of the image
//         i32.const 0  i32.load offset=<word>  if  call $wren.poll  end
//     A poll cannot be forgotten: a loop has one unless its function is named in the list given here (POLL_EXEMPT of
//     src/tools/jsengine: the interpreter's dispatch and the making of a call, which look at the word by themselves).
//     The word's address goes in a custom section (POLL_SECTION), which is also what says that the image has polls.
//   * While a call is in progress the instance's word is on a list (Wt_Global.polls): at each tick the ticker raises the
//     words of that list. At its next poll the module calls `wren.poll`, which does what the epoch's callback does (wt_tick):
//     the deadlines, the stop flag, the profiler's tick, the preemption hook. A trap from there is a trap at a
//     loop head, as the epoch's was.
//   * Code that does not go through a polled loop reaches the word by itself (jsrt.poll_host): the interpreter's calls
//     (frame_push, interp_call), its back edges every INTERRUPT_POLL_EVERY (poll_interrupt), the JIT's direct calls (a
//     helper) and its back edges (the budget, which leaves for the interpreter). What has no poll is a recursion in
//     a native with no loop on its way: it ends at the stack's limit, unless it branches as well.
//
// A page's own modules are not trusted to poll, and never run here: Options.polled is the embedder's word for an image
// it built, and an image without the section stays on the engine with epochs whatever is asked.

import "core:fmt"
import "core:strings"
import "core:sync"

// The import a module with polls calls when its word is raised.
POLL_IMPORT_MODULE :: "wren"
POLL_IMPORT_NAME :: "poll"
// The custom section of an image with polls: the address of the word, as a LEB128.
POLL_SECTION :: "wren.poll"

@(private = "file") WASM_HEADER_BYTES :: 8
@(private = "file") OP_LOOP :: 0x03
@(private = "file") OP_IF :: 0x04
@(private = "file") OP_END :: 0x0b
@(private = "file") OP_CALL :: 0x10
@(private = "file") OP_I32_LOAD :: 0x28
@(private = "file") OP_I32_CONST :: 0x41
@(private = "file") BLOCK_VOID :: 0x40
@(private = "file") LOAD_ALIGN_WORD :: 2     // (log2 of 4)
@(private = "file") SECTION_CUSTOM :: 0
@(private = "file") SECTION_IMPORT :: 2
@(private = "file") SECTION_CODE :: 10
@(private = "file") NAME_SECTION :: "name"
@(private = "file") NAME_FUNCTIONS :: 1      // subsection of the name section

Poll_Stats :: struct {
	functions: int,   // with code
	loops:     int,   // in all
	polled:    int,   // of them, with a poll at their head
	exempt:    int,   // of them, in the functions the caller named
}

// One function's code: its loops, each with what `visit` makes of its head.
@(private = "file")
Poll_Walk :: struct {
	r:      Reader,    // over the function's body
	loops:  int,
	bad:    bool,
}

// The next `loop` of the body: the position after its block type. False at the end of the function.
@(private = "file")
next_loop :: proc(w: ^Poll_Walk) -> (head: int, found: bool) {
	r := &w.r
	for r.pos < len(r.b) {
		op := rd_byte(r)
		switch op {
		case 0x02, OP_LOOP, OP_IF:
			rd_blocktype(r)
			if op == OP_LOOP {
				w.loops += 1
				return r.pos, true
			}
		case 0x05, OP_END:
		case 0x0c, 0x0d, 0xd5, 0xd6:
			rd_leb(r, 32)
		case 0x0e:
			n := rd_leb(r, 32)
			for _ in 0 ..= n { if r.bad { break }; rd_leb(r, 32) }
		case:
			if !skip_immediates(r, op) { w.bad = true; return 0, false }
		}
		if r.bad { w.bad = true; return 0, false }
	}
	return 0, false
}

// The body of a code entry past its locals.
@(private = "file")
skip_locals :: proc(r: ^Reader) {
	groups := rd_leb(r, 32)
	for _ in 0 ..< groups {
		if r.bad { return }
		rd_leb(r, 32)
		c := rd_byte(r)
		if c == 0x63 || c == 0x64 { rd_leb(r, 33) }
	}
}

// Function index -> name, from the name section.
@(private = "file")
function_names :: proc(image: []byte, secs: []Section, allocator := context.temp_allocator) -> map[u32]string {
	names := make(map[u32]string, allocator = allocator)
	for s in secs {
		if s.id != SECTION_CUSTOM { continue }
		r := Reader{b = image[:s.end], pos = s.body}
		if rd_name(&r) != NAME_SECTION { continue }
		for r.pos < s.end && !r.bad {
			sub := rd_byte(&r)
			size := int(rd_leb(&r, 32))
			end := r.pos + size
			if sub == NAME_FUNCTIONS {
				n := rd_leb(&r, 32)
				for _ in 0 ..< n {
					if r.bad { break }
					index := u32(rd_leb(&r, 32))
					names[index] = rd_name(&r)
				}
			}
			r.pos = end
		}
	}
	return names
}

// How many functions the module imports, and the index of wren.poll among them (-1: none).
@(private = "file")
imported_functions :: proc(image: []byte, secs: []Section) -> (count: u32, poll: i64) {
	poll = -1
	for s in secs {
		if s.id != SECTION_IMPORT { continue }
		r := Reader{b = image[:s.end], pos = s.body}
		n := rd_leb(&r, 32)
		for _ in 0 ..< n {
			if r.bad { break }
			module := rd_name(&r)
			name := rd_name(&r)
			kind := rd_byte(&r)
			switch kind {
			case 0:
				rd_leb(&r, 32)
				if module == POLL_IMPORT_MODULE && name == POLL_IMPORT_NAME { poll = i64(count) }
				count += 1
			case 1: rd_reftype(&r); rd_limits(&r)
			case 2: rd_limits(&r)
			case 3: rd_reftype(&r); rd_byte(&r)
			case 4: rd_byte(&r); rd_leb(&r, 32)
			}
		}
	}
	return
}

@(private = "file")
poll_code :: proc(word: u32, function: u32, allocator := context.temp_allocator) -> []byte {
	b := make([dynamic]byte, allocator)
	append(&b, OP_I32_CONST, 0)
	append(&b, OP_I32_LOAD, LOAD_ALIGN_WORD)
	put_leb(&b, u64(word))
	append(&b, OP_IF, BLOCK_VOID, OP_CALL)
	put_leb(&b, u64(function))
	append(&b, OP_END)
	return b[:]
}

// `image` with a poll at the head of every loop of its functions, those named in `exempt` aside (each must exist: a name
// that changed must not leave a list that means nothing), and the section that says so. `word`: the address, in memory 0, of
// the word polled.
poll_instrument :: proc(image: []byte, word: u32, exempt: []string, allocator := context.allocator) -> (out: []byte, stats: Poll_Stats, err: string) {
	secs, serr := sections_of(image)
	if serr != "" { return nil, stats, serr }
	imports, poll := imported_functions(image, secs[:])
	if poll < 0 { return nil, stats, fmt.tprintf("the module does not import %s.%s", POLL_IMPORT_MODULE, POLL_IMPORT_NAME) }
	names := function_names(image, secs[:])
	skipped := make(map[u32]bool, allocator = context.temp_allocator)
	for want in exempt {
		found := false
		for index, name in names {
			if name == want { skipped[index] = true; found = true }
		}
		if !found { return nil, stats, fmt.tprintf("no function is named %s (is the name section there?)", want) }
	}
	poll_bytes := poll_code(word, u32(poll))

	res := make([dynamic]byte, 0, len(image) + len(image) / 8, allocator)
	append(&res, ..image[:WASM_HEADER_BYTES])
	for s in secs {
		if s.id != SECTION_CODE {
			append(&res, ..image[s.start:s.end])
			continue
		}
		body := make([dynamic]byte, 0, s.end - s.body + (s.end - s.body) / 8, context.temp_allocator)
		r := Reader{b = image[:s.end], pos = s.body}
		count := rd_leb(&r, 32)
		put_leb(&body, count)
		for i in 0 ..< count {
			size := int(rd_leb(&r, 32))
			if r.bad || r.pos + size > s.end { return nil, stats, "malformed module: truncated code" }
			code := image[r.pos:r.pos + size]
			r.pos += size
			stats.functions += 1
			w := Poll_Walk{r = Reader{b = code}}
			skip_locals(&w.r)
			fn := make([dynamic]byte, 0, size + size / 4, context.temp_allocator)
			done := 0
			exempted := skipped[imports + u32(i)]
			for {
				head, found := next_loop(&w)
				if !found { break }
				stats.loops += 1
				if exempted { stats.exempt += 1; continue }
				append(&fn, ..code[done:head])
				append(&fn, ..poll_bytes)
				done = head
				stats.polled += 1
			}
			if w.bad || w.r.bad { return nil, stats, fmt.tprintf("function %d: an operator this does not know", imports + u32(i)) }
			append(&fn, ..code[done:])
			put_leb(&body, u64(len(fn)))
			append(&body, ..fn[:])
		}
		put_section(&res, SECTION_CODE, body[:])
	}
	section := make([dynamic]byte, context.temp_allocator)
	put_leb(&section, u64(len(POLL_SECTION)))
	append(&section, POLL_SECTION)
	put_leb(&section, u64(word))
	put_section(&res, SECTION_CUSTOM, section[:])
	return res[:], stats, ""
}

// The address of the word of an image with polls; false for any other module.
poll_word_of :: proc(image: []byte) -> (word: u32, ok: bool) {
	secs, err := sections_of(image)
	if err != "" { return 0, false }
	#reverse for s in secs {
		if s.id != SECTION_CUSTOM { continue }
		r := Reader{b = image[:s.end], pos = s.body}
		if rd_name(&r) != POLL_SECTION { continue }
		word = u32(rd_leb(&r, 32))
		return word, !r.bad
	}
	return 0, false
}

// What an image's loops are: how many, how many have a poll at their head, and the names of the functions (and how many
// loops) where one has none. For the test that says none was left out.
poll_audit :: proc(image: []byte, allocator := context.allocator) -> (stats: Poll_Stats, without: map[string]int, err: string) {
	without = make(map[string]int, allocator = allocator)
	secs, serr := sections_of(image)
	if serr != "" { return stats, without, serr }
	word, has := poll_word_of(image)
	if !has { return stats, without, "the module has no polls" }
	imports, poll := imported_functions(image, secs[:])
	if poll < 0 { return stats, without, "the module does not import wren.poll" }
	names := function_names(image, secs[:])
	want := poll_code(word, u32(poll))
	for s in secs {
		if s.id != SECTION_CODE { continue }
		r := Reader{b = image[:s.end], pos = s.body}
		count := rd_leb(&r, 32)
		for i in 0 ..< count {
			size := int(rd_leb(&r, 32))
			if r.bad || r.pos + size > s.end { return stats, without, "malformed module: truncated code" }
			code := image[r.pos:r.pos + size]
			r.pos += size
			stats.functions += 1
			w := Poll_Walk{r = Reader{b = code}}
			skip_locals(&w.r)
			for {
				head, found := next_loop(&w)
				if !found { break }
				stats.loops += 1
				if head + len(want) <= len(code) && string(code[head:][:len(want)]) == string(want) {
					stats.polled += 1
					continue
				}
				index := imports + u32(i)
				name, named := names[index]
				if !named { name = fmt.tprintf("function %d", index) }
				if _, seen := without[name]; !seen { name = strings.clone(name, allocator) }
				without[name] += 1
			}
			if w.bad || w.r.bad { return stats, without, "an operator this does not know" }
		}
	}
	return stats, without, ""
}

////////////////////////////////
// At run time

// Raises the word of every call in progress (the ticker).
@(private)
polls_raise :: proc() {
	sync.mutex_lock(&wt.polls_lock)
	defer sync.mutex_unlock(&wt.polls_lock)
	for inst := wt.polls; inst != nil; inst = inst.poll_next { sync.atomic_store(inst.poll_word, 1) }
}

// The outermost call of `inst` begins.
@(private)
polls_join :: proc(inst: ^Instance) {
	sync.mutex_lock(&wt.polls_lock)
	defer sync.mutex_unlock(&wt.polls_lock)
	inst.poll_prev, inst.poll_next = nil, wt.polls
	if wt.polls != nil { wt.polls.poll_prev = inst }
	wt.polls = inst
}

// It ended. (After this the ticker no longer writes to the instance's memory, which may go.)
@(private)
polls_leave :: proc(inst: ^Instance) {
	sync.mutex_lock(&wt.polls_lock)
	defer sync.mutex_unlock(&wt.polls_lock)
	if inst.poll_prev != nil { inst.poll_prev.poll_next = inst.poll_next } else { wt.polls = inst.poll_next }
	if inst.poll_next != nil { inst.poll_next.poll_prev = inst.poll_prev }
	inst.poll_prev, inst.poll_next = nil, nil
}

// wren.poll: the word was seen raised.
@(private)
poll_called :: proc "c" (env: rawptr, caller: wt_caller, a: [^]wt_val_raw, n: uint) -> wt_trap {
	inst := frame(env, caller).inst
	if inst.poll_word == nil { return nil }   // (any other module that imports it)
	sync.atomic_store(inst.poll_word, 0)
	if why := wt_tick(inst); why != nil { return trap_new(string(why)) }
	return nil
}

@(private)
POLL_IMPORTS := [?]Import{{module = POLL_IMPORT_MODULE, name = POLL_IMPORT_NAME, fn = poll_called}}

// Whether an instance of `image` runs without epoch checks, and the address of its word.
@(private)
polled_image :: proc(image: []byte, opt: Options) -> (word: u32, polled: bool) {
	if !opt.polled || wt.polled_engine == nil { return 0, false }
	return poll_word_of(image)
}

