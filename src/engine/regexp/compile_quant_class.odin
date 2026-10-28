package regexp

// Quantifier lowering and character-class resolution.

import uni "wb:engine/unicode"

// A quantifier `X{min,max}` with a greedy flag lowers to:
//   - `min` mandatory copies of X (unrolled), then
//   - the optional part:
//       {0,}  (after min)         : a loop     L: Split X,END ; <X> ; Goto L ; END   (greedy)
//       {0,k}  (k = max-min)      : k nested optional copies  Split X,END ; <X> ; ... (greedy)
// Lazy quantifiers swap the split preference (Split_Next vs Split_Goto). To forbid infinite empty-match loops
// (e.g. (a*)*), the unbounded form guards each iteration with Push_Char_Pos / Check_Advance around the body,
// which fails an iteration that consumed nothing.
@(private)
compile_quant :: proc(c: ^Compiler, n: ^Node) {
	body := n.children[0]
	min := n.min
	max := n.max
	greedy := n.greedy

	// Mandatory prefix: `min` copies.
	for _ in 0 ..< min {
		compile_node(c, body)
	}

	if max == -1 {
		compile_star(c, body, greedy)
		return
	}
	// Bounded optional tail: (max - min) optional copies.
	opt := max - min
	compile_optional_chain(c, body, opt, greedy)
}

// Unbounded repetition of `body` (the `*` after the mandatory prefix), with an empty-match guard.
@(private)
compile_star :: proc(c: ^Compiler, body: ^Node, greedy: bool) {
	// L:
	//   Split(END)            ; greedy: Split_Next END means "prefer body (fall-through)"; lazy: Split_Goto END
	//   Push_Char_Pos
	//   <body>
	//   Check_Advance         ; fail iteration if body matched empty
	//   Goto L
	// END:
	l := len(c.code)
	if greedy {
		emit_op(c, .Split_Next)
	} else {
		emit_op(c, .Split_Goto)
	}
	split_at := emit_jump_placeholder(c)
	emit_op(c, .Push_Char_Pos)
	compile_node(c, body)
	emit_op(c, .Check_Advance)
	emit_op(c, .Goto)
	goto_at := emit_jump_placeholder(c)
	patch_jump_to(c, goto_at, l)
	patch_jump_to_here(c, split_at)
}

// A chain of `count` optional copies of body (for a bounded {min,max}). Each is a Split; greedy prefers the body.
@(private)
compile_optional_chain :: proc(c: ^Compiler, body: ^Node, count: int, greedy: bool) {
	if count <= 0 { return }
	ends := make([dynamic]int, c.allocator)
	defer delete(ends)
	for _ in 0 ..< count {
		if greedy {
			emit_op(c, .Split_Next)
		} else {
			emit_op(c, .Split_Goto)
		}
		split_at := emit_jump_placeholder(c)
		compile_node(c, body)
		append(&ends, split_at)
	}
	for at in ends {
		patch_jump_to_here(c, at)
	}
}

// ---- Character classes --------------------------------------------------------------------------------------

@(private)
compile_class :: proc(c: ^Compiler, spec: ^Class_Spec) {
	cr: uni.Char_Range
	uni.cr_init(&cr, c.allocator)
	build_class_range(c, spec, &cr, spec.negated)
	if c.err != "" { uni.cr_destroy(&cr); return }

	// Case folding: expand the set to its canonical forms so a single interpreter comparison handles the i flag.
	if .Ignore_Case in c.flags {
		uni.cr_canonicalize(&cr, unicode_mode(c.flags))
	}

	idx := len(c.ranges)
	append(&c.ranges, cr)
	emit_op(c, .Range) // negation already folded into the range contents
	emit_u32(c, u32(idx))
}

// Build the interval set for a class into `cr`. Handles the item list and, for the v flag, the nested set
// operation against `operands`. `negated` complements the final result.
@(private)
build_class_range :: proc(c: ^Compiler, spec: ^Class_Spec, cr: ^uni.Char_Range, negated: bool) {
	add_items_to_range(c, spec.items[:], cr)
	if c.err != "" { return }
	uni.cr_normalize(cr)

	// v-flag set arithmetic with the (single) right-hand operand.
	if spec.op != .None && len(spec.operands) > 0 {
		rhs: uni.Char_Range
		uni.cr_init(&rhs, c.allocator)
		defer uni.cr_destroy(&rhs)
		build_class_range(c, spec.operands[0], &rhs, spec.operands[0].negated)
		if c.err != "" { return }
		op: uni.Set_Op = spec.op == .Intersection ? .Inter : .Sub
		uni.cr_op_inplace(cr, &rhs, op)
	}

	if negated {
		uni.cr_invert(cr)
	}
}

@(private)
add_items_to_range :: proc(c: ^Compiler, items: []Class_Item, cr: ^uni.Char_Range) {
	for item in items {
		switch item.kind {
		case .Char:
			uni.cr_add_interval(cr, u32(item.lo), u32(item.lo) + 1)
		case .Range:
			uni.cr_add_interval(cr, u32(item.lo), u32(item.hi) + 1)
		case .Digit:
			uni.cr_add_interval(cr, '0', '9' + 1)
		case .Not_Digit:
			add_negated_builtin(cr, .Digit)
		case .Word:
			add_word(cr)
		case .Not_Word:
			add_negated_builtin(cr, .Word)
		case .Space:
			add_space(cr)
		case .Not_Space:
			add_negated_builtin(cr, .Space)
		case .Prop:
			if !uni.property(cr, item.prop_name, item.prop_value) {
				c_fail(c, "unknown Unicode property")
				return
			}
			uni.cr_normalize(cr)
		case .Not_Prop:
			tmp: uni.Char_Range
			uni.cr_init(&tmp, c.allocator)
			defer uni.cr_destroy(&tmp)
			if !uni.property(&tmp, item.prop_name, item.prop_value) {
				c_fail(c, "unknown Unicode property")
				return
			}
			uni.cr_normalize(&tmp)
			uni.cr_invert(&tmp)
			uni.cr_op_inplace(cr, &tmp, .Union)
		}
	}
}

@(private)
add_word :: proc(cr: ^uni.Char_Range) {
	uni.cr_add_interval(cr, '0', '9' + 1)
	uni.cr_add_interval(cr, 'A', 'Z' + 1)
	uni.cr_add_interval(cr, 'a', 'z' + 1)
	uni.cr_add_interval(cr, '_', '_' + 1)
}

@(private)
add_space :: proc(cr: ^uni.Char_Range) {
	// \s = WhiteSpace + LineTerminator per spec: \t \n \v \f \r space, plus NBSP, the Unicode Zs set, LS, PS,
	// and FEFF. We use the White_Space binary property plus the ASCII controls which it already includes.
	uni.cr_add_interval(cr, 0x09, 0x0D + 1)
	uni.cr_add_interval(cr, 0x20, 0x20 + 1)
	uni.cr_add_interval(cr, 0xA0, 0xA0 + 1)
	uni.cr_add_interval(cr, 0x1680, 0x1680 + 1)
	uni.cr_add_interval(cr, 0x2000, 0x200A + 1)
	uni.cr_add_interval(cr, 0x2028, 0x2029 + 1)
	uni.cr_add_interval(cr, 0x202F, 0x202F + 1)
	uni.cr_add_interval(cr, 0x205F, 0x205F + 1)
	uni.cr_add_interval(cr, 0x3000, 0x3000 + 1)
	uni.cr_add_interval(cr, 0xFEFF, 0xFEFF + 1)
}

Builtin :: enum u8 { Digit, Word, Space }

// Add the complement (within [0, CODE_POINT_MAX)) of a built-in class to `cr`.
@(private)
add_negated_builtin :: proc(cr: ^uni.Char_Range, which: Builtin) {
	tmp: uni.Char_Range
	uni.cr_init(&tmp, cr.allocator)
	defer uni.cr_destroy(&tmp)
	switch which {
	case .Digit: uni.cr_add_interval(&tmp, '0', '9' + 1)
	case .Word:  add_word(&tmp)
	case .Space: add_space(&tmp)
	}
	uni.cr_normalize(&tmp)
	uni.cr_invert(&tmp)
	uni.cr_op_inplace(cr, &tmp, .Union)
}
