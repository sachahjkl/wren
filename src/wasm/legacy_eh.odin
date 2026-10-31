package wasm

// The old form of WebAssembly exceptions (try, catch, catch_all, rethrow, delegate), which browsers still take and many
// modules are built with, as the form Wasmtime takes (try_table, throw_ref). A module Wasmtime refused goes through here;
// what comes out is compiled and validated like any module, so a mistake here is a CompileError, not a wrong program.
//
//   try (bt) B catch $a Ha catch_all Hz end
//
// becomes, with $exn a local of type exnref for each depth of handlers:
//
//   block (bt)                                    ; the try's label: a branch to the try lands at the end of this
//     block (param P) (result exnref)             ; catch_all
//       block (param P) (result <$a's> exnref)    ; catch $a
//         try_table (bt) (catch_ref $a 0) (catch_all_ref 1)
//           B
//         end
//         br 2
//       end
//       local.set $exn  Ha  br 1
//     end
//     local.set $exn  Hz
//   end
//
// rethrow is `local.get $exn  throw_ref`. `try B delegate L` sends what B throws to the handlers of the try at L: its
// try_table catches everything to a block at the start of that try's body, which throws it again from there:
//
//   try_table (bt) ... [its handlers] ...
//     block (bt)
//       block (param P) (result exnref)     ; where the delegates land
//         B
//         br 1
//       end
//       throw_ref
//     end
//   end
//
// (and the same around a function's body, when a delegate leaves the function). So one label of the source is several here:
// the labels of every branch are computed again, which is why the whole code section is decoded.

import "core:mem"
import vmem "core:mem/virtual"

@(private = "file")
Func_Type :: struct {
	params, results: []u8,   // the value types' encoded bytes
	np, nr:          int,
}

@(private = "file")
Try_Info :: struct {
	catches:  [dynamic]i32,   // the tag of each catch, -1 for catch_all
	delegate: bool,
	pad:      bool,           // a delegate lands in its body
	bt:       []u8,           // its block type, encoded
}

@(private = "file")
Frame_Kind :: enum u8 { Function, Block, Try_Body, Try_Handler }

@(private = "file")
Frame :: struct {
	kind:    Frame_Kind,
	try_id:  int,
	catch_i: int,   // Try_Handler: which handler (0: the first)
	depth:   int,   // Try_Handler: the handlers around this one and itself: its $exn is this local
	pad:     bool,  // a delegate lands in this function or try body
}

@(private = "file")
Translator :: struct {
	types:      [dynamic]Func_Type,
	nfixed:     int,                  // how many types the module has itself
	type_of:    map[string]int,       // the types added, by their encoding
	added:      [dynamic]u8,          // their encoding
	tag_types:  [dynamic]u32,
	func_types: [dynamic]u32,
	bad:        bool,
}

@(private = "file")
out_leb :: proc(b: ^[dynamic]u8, v: u64) { put_leb(b, v) }

// A type of the given parameters and results, as a block type's index.
@(private = "file")
intern_type :: proc(t: ^Translator, params: []u8, np: int, results: []u8, nr: int) -> int {
	e := make([dynamic]u8)
	append(&e, 0x60)
	out_leb(&e, u64(np))
	append(&e, ..params)
	out_leb(&e, u64(nr))
	append(&e, ..results)
	if i, ok := t.type_of[string(e[:])]; ok { return i }
	i := t.nfixed + len(t.type_of)
	t.type_of[string(e[:])] = i
	append(&t.added, ..e[:])
	return i
}

@(private = "file")
EXNREF :: u8(0x69)

// A type's index as a block type: signed (s33), so what has bit 6 set in its last group takes one more.
@(private = "file")
out_blocktype :: proc(b: ^[dynamic]u8, index: int) {
	v := u64(index)
	for {
		c := u8(v & 0x7f)
		v >>= 7
		if v == 0 && c & 0x40 == 0 { append(b, c); return }
		append(b, c | 0x80)
	}
}

// A block type's bytes at r, moved past.
@(private)
rd_blocktype :: proc(r: ^Reader) -> []u8 {
	start := r.pos
	if r.pos >= len(r.b) { r.bad = true; return nil }
	c := r.b[r.pos]
	if c == 0x40 {
		r.pos += 1
	} else if c & 0xC0 == 0x40 {
		rd_reftype(r)   // (a value type reads as a reference type does)
	} else {
		rd_leb(r, 33)
	}
	return r.b[start:r.pos]
}

// The parameters of a block type.
@(private = "file")
blocktype_params :: proc(t: ^Translator, bt: []u8) -> (params: []u8, np: int) {
	c := bt[0]
	if c == 0x40 || c & 0xC0 == 0x40 { return nil, 0 }
	r := Reader{b = bt}
	i := int(rd_leb(&r, 33))
	if i < 0 || i >= len(t.types) { t.bad = true; return nil, 0 }
	return t.types[i].params, t.types[i].np
}

// What the code of a function has at r, up to its operator's immediates: the operator, moved past them unless it has
// labels or block types (those the callers read). false for an operator this does not know.
@(private)
skip_immediates :: proc(r: ^Reader, op: u8) -> bool {
	memarg :: proc(r: ^Reader) {
		align := rd_leb(r, 32)
		if align & 0x40 != 0 { rd_leb(r, 32) }   // a memory index
		rd_leb(r, 64)
	}
	switch op {
	case 0x00, 0x01, 0x0f, 0x1a, 0x1b, 0x0a: return true
	case 0x10, 0x12, 0x14, 0x15, 0x08: rd_leb(r, 32)
	case 0x11, 0x13: rd_leb(r, 32); rd_leb(r, 32)
	case 0x1c:
		n := rd_leb(r, 32)
		for _ in 0 ..< n { if r.bad { break }; rd_reftype(r) }
	case 0x20 ..= 0x26: rd_leb(r, 32)
	case 0x28 ..= 0x3e: memarg(r)
	case 0x3f, 0x40: rd_leb(r, 32)
	case 0x41: rd_leb(r, 33)
	case 0x42: rd_leb(r, 65)
	case 0x43: r.pos += 4
	case 0x44: r.pos += 8
	case 0x45 ..= 0xc4: return true
	case 0xd0: rd_leb(r, 33)
	case 0xd1, 0xd3, 0xd4: return true
	case 0xd2: rd_leb(r, 32)
	case 0xfc:
		sub := rd_leb(r, 32)
		switch sub {
		case 0 ..= 7: return true
		case 8, 10, 12, 14: rd_leb(r, 32); rd_leb(r, 32)
		case 9, 11, 13, 15, 16, 17: rd_leb(r, 32)
		case 19 ..= 22: return true   // (wide arithmetic)
		case: return false
		}
	case 0xfd:
		sub := rd_leb(r, 32)
		switch sub {
		case 0 ..= 11, 92, 93: memarg(r)
		case 12, 13: r.pos += 16
		case 21 ..= 34: r.pos += 1
		case 84 ..= 91: memarg(r); r.pos += 1
		}
	case 0xfe:
		sub := rd_leb(r, 32)
		if sub == 3 { r.pos += 1 } else { memarg(r) }
	case: return false
	}
	return !r.bad && r.pos <= len(r.b)
}

// First pass over a function's code: what each try has (catches, delegate), and who a delegate lands in.
// The code is `body`; func_pad says a delegate leaves the function.
@(private = "file")
scan_function :: proc(t: ^Translator, body: []u8, tries: ^[dynamic]Try_Info) -> (func_pad: bool, has_legacy: bool, ok: bool) {
	r := Reader{b = body}
	stack := make([dynamic]Frame)
	append(&stack, Frame{kind = .Function})
	for len(stack) > 0 {
		if r.pos >= len(body) { return false, false, false }
		op := rd_byte(&r)
		switch op {
		case 0x02, 0x03, 0x04:
			rd_blocktype(&r)
			append(&stack, Frame{kind = .Block})
		case 0x05:
		case 0x06:
			has_legacy = true
			bt := rd_blocktype(&r)
			append(tries, Try_Info{bt = bt, catches = make([dynamic]i32)})
			append(&stack, Frame{kind = .Try_Body, try_id = len(tries) - 1})
		case 0x07, 0x19:
			f := &stack[len(stack) - 1]
			if f.kind != .Try_Body && f.kind != .Try_Handler { return false, false, false }
			tag := i32(-1)
			if op == 0x07 { tag = i32(rd_leb(&r, 32)) }
			append(&tries[f.try_id].catches, tag)
			f.kind = .Try_Handler
		case 0x18:
			f := stack[len(stack) - 1]
			if f.kind != .Try_Body { return false, false, false }
			tries[f.try_id].delegate = true
			L := int(rd_leb(&r, 32))
			// the label is counted from outside the try; the first try whose body encloses it, or else out of the function
			at := len(stack) - 2 - L
			for at > 0 && stack[at].kind != .Try_Body { at -= 1 }
			if at <= 0 {
				func_pad = true
			} else {
				tries[stack[at].try_id].pad = true
			}
			pop(&stack)
		case 0x09, 0x0c, 0x0d, 0xd5, 0xd6:
			if op == 0x09 { has_legacy = true }
			rd_leb(&r, 32)
		case 0x0e:
			n := rd_leb(&r, 32)
			for _ in 0 ..= n { if r.bad { break }; rd_leb(&r, 32) }
		case 0x0b:
			pop(&stack)
		case 0x1f:   // try_table: a block as far as labels go
			rd_blocktype(&r)
			n := rd_leb(&r, 32)
			for _ in 0 ..< n {
				if r.bad { break }
				k := rd_byte(&r)
				if k <= 1 { rd_leb(&r, 32) }
				rd_leb(&r, 32)
			}
			append(&stack, Frame{kind = .Block})
		case:
			if !skip_immediates(&r, op) { return false, false, false }
		}
		if r.bad { return false, false, false }
	}
	return func_pad, has_legacy, r.pos == len(body)
}

// How many labels of the output a frame stands for, and so where a branch to it goes: its destination is the outermost.
@(private = "file")
frame_labels :: proc(f: Frame, tries: []Try_Info) -> int {
	switch f.kind {
	case .Block: return 1
	case .Function: return f.pad ? 3 : 1
	case .Try_Body:
		ti := &tries[f.try_id]
		pad := f.pad ? 2 : 0
		if ti.delegate { return 1 + pad }
		return 2 + len(ti.catches) + pad
	case .Try_Handler:
		ti := &tries[f.try_id]
		return len(ti.catches) - f.catch_i   // the blocks of the handlers after it, and the try's own
	}
	return 1
}

// The label of the output for label L of the source, with `stack` the frames around the code.
@(private = "file")
new_label :: proc(stack: []Frame, tries: []Try_Info, L: int) -> (int, bool) {
	n := 0
	at := len(stack) - 1
	for i in 0 ..< L {
		if at - i < 0 { return 0, false }
		n += frame_labels(stack[at - i], tries)
	}
	if at - L < 0 { return 0, false }
	return n + frame_labels(stack[at - L], tries) - 1, true
}

// Second pass: the code as try_table. Writes to `out`; `exn_base` the first local of type exnref. How many of them it
// used: `max_depth`.
@(private = "file")
translate_function :: proc(t: ^Translator, body: []u8, tries: []Try_Info, func_pad: bool, func_results: []u8, nr: int, exn_base: int, out: ^[dynamic]u8) -> (max_depth: int, ok: bool) {
	r := Reader{b = body}
	stack := make([dynamic]Frame)
	append(&stack, Frame{kind = .Function, pad = func_pad})
	next_try := 0

	// the two blocks of a body where delegates land
	open_pad :: proc(t: ^Translator, out: ^[dynamic]u8, bt: []u8, params: []u8, np: int) {
		append(out, 0x02)
		append(out, ..bt)
		append(out, 0x02)
		out_blocktype(out, intern_type(t, params, np, {EXNREF}, 1))
	}
	close_pad :: proc(out: ^[dynamic]u8) {
		append(out, 0x0c, 1)   // br to the end of the outer one
		append(out, 0x0b)
		append(out, 0x0a)      // throw_ref
		append(out, 0x0b)
	}
	if func_pad {
		// (block (result ...)) for the function's results
		bt := make([dynamic]u8)
		out_blocktype(&bt, intern_type(t, nil, 0, func_results, nr))
		open_pad(t, out, bt[:], nil, 0)
	}

	// `end of a try's body`: what follows the body, up to the handler that is next
	end_body :: proc(out: ^[dynamic]u8, f: Frame, ncatch: int) {
		if f.pad { close_pad(out) }
		append(out, 0x0b)                  // the try_table
		append(out, 0x0c)
		out_leb(out, u64(ncatch))          // past the blocks of the handlers
	}

	for {
		if r.pos >= len(body) { return 0, false }
		start := r.pos
		op := rd_byte(&r)
		switch op {
		case 0x02, 0x03, 0x04:
			rd_blocktype(&r)
			append(out, ..body[start:r.pos])
			append(&stack, Frame{kind = .Block})
		case 0x05:
			append(out, op)
		case 0x06:
			bt := rd_blocktype(&r)
			id := next_try
			next_try += 1
			ti := &tries[id]
			params, np := blocktype_params(t, bt)
			if t.bad { return 0, false }
			if ti.delegate {
				// try_table (bt) (catch_all_ref <where it lands>)
				// (found as scan_function did; the label comes after the body, so it is read ahead there)
				label, found := delegate_label(body, r.pos, stack[:], tries)
				if !found { return 0, false }
				append(out, 0x1f)
				append(out, ..bt)
				append(out, 1, 3)
				out_leb(out, u64(label))
			} else {
				append(out, 0x02)
				append(out, ..bt)
				for i := len(ti.catches) - 1; i >= 0; i -= 1 {
					tag := ti.catches[i]
					results := make([dynamic]u8)
					n := 1
					if tag >= 0 {
						if int(tag) >= len(t.tag_types) { return 0, false }
						ft := t.types[t.tag_types[tag]]
						append(&results, ..ft.params)
						n += ft.np
					}
					append(&results, EXNREF)
					append(out, 0x02)
					out_blocktype(out, intern_type(t, params, np, results[:], n))
				}
				append(out, 0x1f)
				append(out, ..bt)
				out_leb(out, u64(len(ti.catches)))
				for tag, i in ti.catches {
					if tag >= 0 {
						append(out, 1)
						out_leb(out, u64(tag))
					} else {
						append(out, 3)
					}
					out_leb(out, u64(i))
				}
			}
			if ti.pad { open_pad(t, out, bt, params, np) }
			append(&stack, Frame{kind = .Try_Body, try_id = id, pad = ti.pad})
		case 0x07, 0x19:
			f := &stack[len(stack) - 1]
			ti := &tries[f.try_id]
			if op == 0x07 { rd_leb(&r, 32) }
			if f.kind == .Try_Body {
				end_body(out, f^, len(ti.catches))
				f.pad = false
				f.kind = .Try_Handler
				f.catch_i = 0
				f.depth = handler_depth(stack[:len(stack) - 1]) + 1
				max_depth = max(max_depth, f.depth)
			} else {
				// the handler before it ends: past the blocks of the handlers after it
				append(out, 0x0c)
				out_leb(out, u64(len(ti.catches) - f.catch_i - 1))
				f.catch_i += 1
			}
			append(out, 0x0b)   // the block of this handler
			append(out, 0x21)   // local.set $exn
			out_leb(out, u64(exn_base + f.depth - 1))
		case 0x18:
			f := stack[len(stack) - 1]
			rd_leb(&r, 32)
			if f.pad { close_pad(out) }
			append(out, 0x0b)
			pop(&stack)
		case 0x09:
			L := int(rd_leb(&r, 32))
			at := len(stack) - 1 - L
			if at < 0 || stack[at].kind != .Try_Handler { return 0, false }
			append(out, 0x20)
			out_leb(out, u64(exn_base + stack[at].depth - 1))
			append(out, 0x0a)
		case 0x0c, 0x0d, 0xd5, 0xd6:
			L := int(rd_leb(&r, 32))
			n, found := new_label(stack[:], tries, L)
			if !found { return 0, false }
			append(out, op)
			out_leb(out, u64(n))
		case 0x0e:
			n := rd_leb(&r, 32)
			append(out, op)
			out_leb(out, n)
			for _ in 0 ..= n {
				if r.bad { break }
				L, found := new_label(stack[:], tries, int(rd_leb(&r, 32)))
				if !found { return 0, false }
				out_leb(out, u64(L))
			}
		case 0x0b:
			f := pop(&stack)
			switch f.kind {
			case .Try_Body:
				// a try with no handler at all
				end_body(out, f, 0)
			case .Function:
				if f.pad { close_pad(out) }
			case .Block, .Try_Handler:
			}
			append(out, 0x0b)
			if len(stack) == 0 { return max_depth, r.pos == len(body) && !r.bad }
		case 0x1f:
			bt := rd_blocktype(&r)
			append(out, 0x1f)
			append(out, ..bt)
			n := rd_leb(&r, 32)
			out_leb(out, n)
			for _ in 0 ..< n {
				if r.bad { break }
				k := rd_byte(&r)
				append(out, k)
				if k <= 1 { out_leb(out, rd_leb(&r, 32)) }
				L, found := new_label(stack[:], tries, int(rd_leb(&r, 32)))
				if !found { return 0, false }
				out_leb(out, u64(L))
			}
			append(&stack, Frame{kind = .Block})
		case:
			if !skip_immediates(&r, op) { return 0, false }
			append(out, ..body[start:r.pos])
		}
		if r.bad || t.bad { return 0, false }
	}
}

// The handlers enclosing the code of `stack`.
@(private = "file")
handler_depth :: proc(stack: []Frame) -> int {
	d := 0
	for f in stack { if f.kind == .Try_Handler { d = max(d, f.depth) } }
	return d
}

// The label a delegating try's try_table catches to: the place where its delegate lands, seen from outside the try. `at`:
// just after the try's block type. Its delegate is found by walking its body.
@(private = "file")
delegate_label :: proc(body: []u8, at: int, stack: []Frame, tries: []Try_Info) -> (int, bool) {
	r := Reader{b = body, pos = at}
	depth := 0
	for {
		if r.pos >= len(body) { return 0, false }
		op := rd_byte(&r)
		switch op {
		case 0x02, 0x03, 0x04, 0x06:
			rd_blocktype(&r)
			depth += 1
		case 0x05, 0x19:
		case 0x07: rd_leb(&r, 32)
		case 0x18:
			L := int(rd_leb(&r, 32))
			if depth > 0 { depth -= 1; continue }
			// from the frames around the try: the first try body at or outside L, or the function
			target := len(stack) - 1 - L
			for target > 0 && stack[target].kind != .Try_Body { target -= 1 }
			if target < 0 { return 0, false }
			n := 0
			for i := len(stack) - 1; i > target; i -= 1 { n += frame_labels(stack[i], tries) }
			return n, true   // (the landing block is the innermost label of its frame)
		case 0x09, 0x0c, 0x0d, 0xd5, 0xd6: rd_leb(&r, 32)
		case 0x0e:
			n := rd_leb(&r, 32)
			for _ in 0 ..= n { if r.bad { break }; rd_leb(&r, 32) }
		case 0x0b:
			if depth == 0 { return 0, false }
			depth -= 1
		case 0x1f:
			rd_blocktype(&r)
			n := rd_leb(&r, 32)
			for _ in 0 ..< n {
				if r.bad { break }
				k := rd_byte(&r)
				if k <= 1 { rd_leb(&r, 32) }
				rd_leb(&r, 32)
			}
			depth += 1
		case:
			if !skip_immediates(&r, op) { return 0, false }
		}
		if r.bad { return 0, false }
	}
}

// `image` with the old form of exceptions translated, in `allocator`; nil when it has none, or when it cannot be read: its
// own error then stands.
translate_legacy_exceptions :: proc(image: []byte, allocator: mem.Allocator) -> []byte {
	if len(image) < 8 { return nil }
	arena: vmem.Arena
	if vmem.arena_init_growing(&arena) != nil { return nil }
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	t := Translator{types = make([dynamic]Func_Type), type_of = make(map[string]int), added = make([dynamic]u8), tag_types = make([dynamic]u32), func_types = make([dynamic]u32)}
	code_start, code_end, type_start, type_end := -1, -1, -1, -1
	type_count: u64
	r := Reader{b = image, pos = 8}
	nimported_funcs := 0
	for r.pos < len(image) {
		start := r.pos
		id := rd_byte(&r)
		size := int(rd_leb(&r, 32))
		if r.bad || r.pos + size > len(image) { return nil }
		end := r.pos + size
		body := Reader{b = image[r.pos:end]}
		switch id {
		case 1:
			type_start, type_end = start, end
			type_count = rd_leb(&body, 32)
			for _ in 0 ..< type_count {
				if body.bad { return nil }
				if rd_byte(&body) != 0x60 { return nil }   // (rec groups, structs: gc, which this does not read)
				vec :: proc(b: ^Reader) -> ([]u8, int) {
					n := int(rd_leb(b, 32))
					s := b.pos
					for _ in 0 ..< n { if b.bad { break }; rd_reftype(b) }
					return b.b[s:b.pos], n
				}
				ft: Func_Type
				ft.params, ft.np = vec(&body)
				ft.results, ft.nr = vec(&body)
				append(&t.types, ft)
			}
			t.nfixed = len(t.types)
		case 2:
			n := rd_leb(&body, 32)
			for _ in 0 ..< n {
				if body.bad { return nil }
				rd_name(&body)
				rd_name(&body)
				switch rd_byte(&body) {
				case 0: append(&t.func_types, u32(rd_leb(&body, 32))); nimported_funcs += 1
				case 1: rd_reftype(&body); rd_limits(&body)
				case 2: rd_limits(&body)
				case 3: rd_reftype(&body); rd_byte(&body)
				case 4: rd_byte(&body); append(&t.tag_types, u32(rd_leb(&body, 32)))
				case: return nil
				}
			}
		case 3:
			n := rd_leb(&body, 32)
			for _ in 0 ..< n { if body.bad { return nil }; append(&t.func_types, u32(rd_leb(&body, 32))) }
		case 13:
			n := rd_leb(&body, 32)
			for _ in 0 ..< n { if body.bad { return nil }; rd_byte(&body); append(&t.tag_types, u32(rd_leb(&body, 32))) }
		case 10:
			code_start, code_end = start, end
		}
		if body.bad { return nil }
		r.pos = end
	}
	if code_start < 0 || type_start < 0 { return nil }
	for ty in t.tag_types { if int(ty) >= t.nfixed { return nil } }

	// the code section again
	code := Reader{b = image, pos = code_start + 1}
	rd_leb(&code, 32)
	nfuncs := int(rd_leb(&code, 32))
	if code.bad { return nil }
	new_code := make([dynamic]u8, 0, code_end - code_start + 1024)
	put_leb(&new_code, u64(nfuncs))
	any_legacy := false
	for i in 0 ..< nfuncs {
		size := int(rd_leb(&code, 32))
		if code.bad || code.pos + size > code_end { return nil }
		fn := image[code.pos:code.pos + size]
		code.pos += size
		// its locals
		lr := Reader{b = fn}
		nl := rd_leb(&lr, 32)
		locals_at := lr.pos
		nlocals := 0
		for _ in 0 ..< nl {
			if lr.bad { return nil }
			nlocals += int(rd_leb(&lr, 32))
			rd_reftype(&lr)
		}
		if lr.bad { return nil }
		ops := fn[lr.pos:]
		tries := make([dynamic]Try_Info)
		func_pad, legacy, ok := scan_function(&t, ops, &tries)
		if !ok { return nil }
		if !legacy {
			put_leb(&new_code, u64(size))
			append(&new_code, ..fn)
			continue
		}
		any_legacy = true
		fi := nimported_funcs + i
		if fi >= len(t.func_types) || int(t.func_types[fi]) >= t.nfixed { return nil }
		ft := t.types[t.func_types[fi]]
		nparams := ft.np
		out := make([dynamic]u8, 0, size + 64)
		depth, done := translate_function(&t, ops, tries[:], func_pad, ft.results, ft.nr, nparams + nlocals, &out)
		if !done || t.bad { return nil }
		head := make([dynamic]u8)
		put_leb(&head, nl + (depth > 0 ? 1 : 0))
		append(&head, ..fn[locals_at:lr.pos])
		if depth > 0 {
			put_leb(&head, u64(depth))
			append(&head, EXNREF)
		}
		put_leb(&new_code, u64(len(head) + len(out)))
		append(&new_code, ..head[:])
		append(&new_code, ..out[:])
	}
	if !any_legacy { return nil }

	// the module: its type section with the new types, its code section
	new_types := make([dynamic]u8)
	put_leb(&new_types, type_count + u64(len(t.type_of)))
	tr := Reader{b = image, pos = type_start + 1}
	rd_leb(&tr, 32)
	rd_leb(&tr, 32)
	append(&new_types, ..image[tr.pos:type_end])
	append(&new_types, ..t.added[:])

	section :: proc(b: ^[dynamic]u8, id: u8, body: []u8) {
		append(b, id)
		put_leb(b, u64(len(body)))
		append(b, ..body)
	}
	out := make([dynamic]u8, 0, len(image) + len(new_code))
	first, second := type_start, code_start
	append(&out, ..image[:first])
	section(&out, 1, new_types[:])
	append(&out, ..image[type_end:second])
	section(&out, 10, new_code[:])
	append(&out, ..image[code_end:])
	result := make([]byte, len(out), allocator)
	copy(result, out[:])
	return result
}
