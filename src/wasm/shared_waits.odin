package wasm

// A `memory.atomic.wait` of a module blocks its thread in Wasmtime, where neither the epoch nor anything else reaches it: a
// worker waiting without a timeout could never be stopped, and closing its page waits for it. So in a module with a shared
// memory each wait becomes a call of a function added at the end of the module, which waits in slices and loops; the
// epoch is checked at a loop's back edge, which is how a module's code stops (wt_on_epoch).
//
//   (func (param addr expected timeout) (result i32) (local r i32) (local later i32)
//     loop (result i32)
//       addr  expected  (select SLICE timeout (timeout >u SLICE))  memory.atomic.wait32 <the memarg of the original>
//       local.tee r
//       if r == 2 (timed out) and timeout >u SLICE:
//         if timeout >= 0: timeout -= SLICE
//         later = 1
//         br loop
//       (select 0 r (r == 1 and later))   ; changed between two slices: what a notify would have told
//     end)
//
// Only functions are added, after the others, so no index of the module moves. What comes out is compiled like any
// module; nil when there is nothing to do or it cannot be read, and the module stands as it is.

import "core:mem"
import vmem "core:mem/virtual"

@(private = "file")
wait_wrapper_body :: proc(b: ^[dynamic]u8, wide: bool, memarg: []u8) {
	body := make([dynamic]u8, 0, 64)
	slice :: proc(b: ^[dynamic]u8) {
		append(b, 0x42)
		put_sleb(b, WAIT_SLICE_NS)
	}
	append(&body, 1, 2, 0x7f)                     // two i32 locals: r (3), later (4)
	append(&body, 0x03, 0x7f)                     // loop (result i32)
	append(&body, 0x20, 0, 0x20, 1)
	slice(&body)
	append(&body, 0x20, 2, 0x20, 2)
	slice(&body)
	append(&body, 0x56, 0x1b)                     // i64.gt_u select
	append(&body, 0xfe, wide ? 2 : 1)
	append(&body, ..memarg)
	append(&body, 0x21, 3)                        // local.set r
	append(&body, 0x20, 3, 0x41, 2, 0x46, 0x20, 2)   // r == 2
	slice(&body)
	append(&body, 0x56, 0x71)                     // i64.gt_u i32.and
	append(&body, 0x04, 0x40)                     // if
	append(&body, 0x20, 2, 0x42, 0, 0x59)         // timeout >= 0
	append(&body, 0x04, 0x40, 0x20, 2)
	slice(&body)
	append(&body, 0x7d, 0x21, 2, 0x0b)            // timeout -= SLICE
	append(&body, 0x41, 1, 0x21, 4, 0x0c, 1, 0x0b)   // later = 1; br loop
	append(&body, 0x41, 0, 0x20, 3, 0x20, 3, 0x41, 1, 0x46, 0x20, 4, 0x71, 0x1b)
	append(&body, 0x0b, 0x0b)                     // end loop, end function
	put_leb(b, u64(len(body)))
	append(b, ..body[:])
}

@(private = "file")
put_sleb :: proc(b: ^[dynamic]u8, v: i64) {
	v := v
	for {
		x := u8(v & 0x7f)
		v >>= 7
		if (v == 0 && x & 0x40 == 0) || (v == -1 && x & 0x40 != 0) {
			append(b, x)
			return
		}
		append(b, x | 0x80)
	}
}

// One operator of a function's code, moved past it. false when it does not know it.
@(private = "file")
skip_op :: proc(r: ^Reader, op: u8) -> bool {
	switch op {
	case 0x02, 0x03, 0x04, 0x06: rd_blocktype(r)
	case 0x05, 0x0b, 0x19:
	case 0x07, 0x09, 0x18, 0x0c, 0x0d, 0xd5, 0xd6: rd_leb(r, 32)
	case 0x0e:
		n := rd_leb(r, 32)
		for _ in 0 ..= n { if r.bad { break }; rd_leb(r, 32) }
	case 0x1f:
		rd_blocktype(r)
		n := rd_leb(r, 32)
		for _ in 0 ..< n {
			if r.bad { break }
			k := rd_byte(r)
			if k <= 1 { rd_leb(r, 32) }
			rd_leb(r, 32)
		}
	case: return skip_immediates(r, op)
	}
	return !r.bad
}

// `image` with the waits of a module with a shared memory as above, in `allocator`.
translate_shared_waits :: proc(image: []byte, allocator: mem.Allocator) -> []byte {
	if len(image) < 8 { return nil }
	arena: vmem.Arena
	if vmem.arena_init_growing(&arena) != nil { return nil }
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	shared := false
	type_at, func_at, code_at := [2]int{-1, -1}, [2]int{-1, -1}, [2]int{-1, -1}
	imported_funcs := 0
	r := Reader{b = image, pos = 8}
	for r.pos < len(image) {
		id := rd_byte(&r)
		size := int(rd_leb(&r, 32))
		if r.bad || r.pos + size > len(image) { return nil }
		end := r.pos + size
		body := Reader{b = image[r.pos:end]}
		switch id {
		case 1: type_at = {r.pos, end}
		case 2:
			n := rd_leb(&body, 32)
			for _ in 0 ..< n {
				if body.bad { return nil }
				rd_name(&body)
				rd_name(&body)
				switch rd_byte(&body) {
				case 0: rd_leb(&body, 32); imported_funcs += 1
				case 1: rd_reftype(&body); rd_limits(&body)
				case 2: if rd_limits(&body) & 2 != 0 { shared = true }
				case 3: rd_reftype(&body); rd_byte(&body)
				case 4: rd_byte(&body); rd_leb(&body, 32)
				case: return nil
				}
			}
		case 3: func_at = {r.pos, end}
		case 5:
			n := rd_leb(&body, 32)
			for _ in 0 ..< n {
				if body.bad { return nil }
				if rd_limits(&body) & 2 != 0 { shared = true }
			}
		case 10: code_at = {r.pos, end}
		}
		if body.bad { return nil }
		r.pos = end
	}
	if !shared || type_at[0] < 0 || func_at[0] < 0 || code_at[0] < 0 { return nil }

	types := Reader{b = image, pos = type_at[0]}
	type_count := rd_leb(&types, 32)
	funcs := Reader{b = image, pos = func_at[0]}
	func_count := rd_leb(&funcs, 32)
	if types.bad || funcs.bad { return nil }

	Wrapper :: struct { wide: bool, memarg: []u8 }
	wrappers := make([dynamic]Wrapper)
	wrapper_of := make(map[string]int)
	first_wrapper := imported_funcs + int(func_count)

	code := Reader{b = image, pos = code_at[0]}
	nfuncs := rd_leb(&code, 32)
	if code.bad || nfuncs != func_count { return nil }
	new_code := make([dynamic]u8, 0, code_at[1] - code_at[0] + 1024)
	for _ in 0 ..< nfuncs {
		size := int(rd_leb(&code, 32))
		if code.bad || code.pos + size > code_at[1] { return nil }
		fn := image[code.pos:code.pos + size]
		code.pos += size
		lr := Reader{b = fn}
		nl := rd_leb(&lr, 32)
		for _ in 0 ..< nl {
			if lr.bad { return nil }
			rd_leb(&lr, 32)
			rd_reftype(&lr)
		}
		if lr.bad { return nil }
		out := make([dynamic]u8, 0, 0)
		copied := 0   // of fn, into out
		for lr.pos < len(fn) {
			at := lr.pos
			op := rd_byte(&lr)
			if op == 0xfe && lr.pos < len(fn) && (fn[lr.pos] == 1 || fn[lr.pos] == 2) {
				wide := fn[lr.pos] == 2
				lr.pos += 1
				start := lr.pos
				align := rd_leb(&lr, 32)
				if align & 0x40 != 0 { rd_leb(&lr, 32) }
				rd_leb(&lr, 64)
				if lr.bad { return nil }
				memarg := fn[start:lr.pos]
				key := string(fn[start - 1:lr.pos])
				k, seen := wrapper_of[key]
				if !seen {
					k = len(wrappers)
					wrapper_of[key] = k
					append(&wrappers, Wrapper{wide, memarg})
				}
				append(&out, ..fn[copied:at])
				append(&out, 0x10)
				put_leb(&out, u64(first_wrapper + k))
				copied = lr.pos
			} else if !skip_op(&lr, op) {
				return nil
			}
		}
		if lr.pos != len(fn) { return nil }
		if copied == 0 {
			put_leb(&new_code, u64(size))
			append(&new_code, ..fn)
		} else {
			append(&out, ..fn[copied:])
			put_leb(&new_code, u64(len(out)))
			append(&new_code, ..out[:])
		}
	}
	if len(wrappers) == 0 { return nil }

	// (the two types come last, whatever the section has)
	new_types := make([dynamic]u8)
	put_leb(&new_types, type_count + 2)
	append(&new_types, ..image[types.pos:type_at[1]])
	append(&new_types, 0x60, 3, 0x7f, 0x7f, 0x7e, 1, 0x7f)
	append(&new_types, 0x60, 3, 0x7f, 0x7e, 0x7e, 1, 0x7f)

	new_funcs := make([dynamic]u8)
	put_leb(&new_funcs, func_count + u64(len(wrappers)))
	append(&new_funcs, ..image[funcs.pos:func_at[1]])
	for w in wrappers { put_leb(&new_funcs, type_count + (w.wide ? 1 : 0)) }

	full_code := make([dynamic]u8, 0, len(new_code) + 128)
	put_leb(&full_code, nfuncs + u64(len(wrappers)))
	append(&full_code, ..new_code[:])
	for w in wrappers { wait_wrapper_body(&full_code, w.wide, w.memarg) }

	section :: proc(b: ^[dynamic]u8, id: u8, body: []u8) {
		append(b, id)
		put_leb(b, u64(len(body)))
		append(b, ..body)
	}
	module := make([dynamic]u8, allocator)
	reserve(&module, len(image) + len(full_code) - (code_at[1] - code_at[0]) + 256)
	append(&module, ..image[:8])
	r = Reader{b = image, pos = 8}
	for r.pos < len(image) {
		start := r.pos
		id := rd_byte(&r)
		size := int(rd_leb(&r, 32))
		switch id {
		case 1: section(&module, 1, new_types[:])
		case 3: section(&module, 3, new_funcs[:])
		case 10: section(&module, 10, full_code[:])
		case: append(&module, ..image[start:r.pos + size])
		}
		r.pos += size
	}
	return module[:]
}
