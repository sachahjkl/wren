package jsrt

// Function_Bytecode: the compiled form of a function, the contract between the compiler front-end
// and this runtime. Field-for-field what QuickJS-ng 0.17 serializes (JS_WriteFunctionTag), so the
// Odin compiler (E1) and the reference C compiler produce interchangeable input.

Func_Kind :: enum u8 {
	normal          = 0,
	generator       = 1,
	async           = 2,
	async_generator = 3,
}

Var_Def :: struct {
	name:        Atom,
	scope_level: i32,
	scope_next:  i32,
	var_kind:    u8,
	is_const:    bool,
	is_lexical:  bool,
	is_captured: bool,
	var_ref_idx: u16,
}

Closure_Type :: enum u8 {
	local      = 0, // a local variable of the parent frame
	arg        = 1, // an argument of the parent frame
	ref        = 2, // one of the parent's own closure variables
	global_ref = 3, // a global reference captured by an eval/closure
	global_decl = 4,
	global     = 5,
	module_decl = 6,
	module_import = 7,
}

Closure_Var :: struct {
	name:         Atom,
	var_idx:      u16,
	closure_type: Closure_Type,
	is_const:     bool,
	is_lexical:   bool,
	var_kind:     u8,
}

Function_Bytecode :: struct {
	using cell:                Cell,
	has_prototype:             bool,
	has_simple_parameter_list: bool,
	is_derived_class_ctor:     bool,
	need_home_object:          bool,
	func_kind:                 Func_Kind,
	new_target_allowed:        bool,
	super_call_allowed:        bool,
	super_allowed:             bool,
	arguments_allowed:         bool,
	backtrace_barrier:         bool,
	has_debug:                 bool,
	is_strict_mode:            bool,
	func_name:                 Atom,
	arg_count:                 u16,
	var_count:                 u16,
	defined_arg_count:         u16,
	stack_size:                u16,
	var_ref_count:             u16,
	closure_var_count:         u16,
	vardefs:                   []Var_Def,
	closure_vars:              []Closure_Var,
	cpool:                     []Value,
	code:                      []u8,
	realm:                     ^Context,
	filename:                  Atom,
	line_num:                  int,
	col_num:                   int,
	pc2line:                   []u8,
	source:                    []u8,
	source_string:             ^JS_String, // cached Function.prototype.toString text
	catch_levels:              []Catch_Level, // verified operand stack height at each catch handler
	image:                     []u8, // the serialized form this function was read from, kept on request (Compile_Request.keep_image)
}

Catch_Level :: struct {
	pos:   i32,
	level: i32,
}

// The verified stack height at handler `pos` (-1: not a handler of this function).
catch_level_at :: proc(b: ^Function_Bytecode, pos: int) -> int {
	for c in b.catch_levels {if int(c.pos) == pos {return int(c.level)}}
	return -1
}

function_bc_new :: proc(rt: ^Runtime) -> ^Function_Bytecode {
	return cell_new(rt, Function_Bytecode, .function_bc)
}

function_bc_finalize :: proc(rt: ^Runtime, b: ^Function_Bytecode) {
	a := rt_allocator(rt)
	if b.vardefs != nil {delete(b.vardefs, a)}
	if b.closure_vars != nil {delete(b.closure_vars, a)}
	if b.cpool != nil {delete(b.cpool, a)}
	if b.code != nil {delete(b.code, a)}
	if b.pc2line != nil {delete(b.pc2line, a)}
	if b.source != nil {delete(b.source, a)}
	if b.catch_levels != nil {delete(b.catch_levels, a)}
	if b.image != nil {delete(b.image, a)}
}

// The source line of instruction `pc`, decoded from the pc2line table (QuickJS's format: a leb128
// pc delta followed by a sleb128 line delta and a sleb128 column delta per entry, with short forms).
pc_to_line :: proc(b: ^Function_Bytecode, pc: int) -> int {
	line, _ := pc_to_pos(b, pc)
	return line
}

// The source line and column of instruction pc.
pc_to_pos :: proc(b: ^Function_Bytecode, pc: int) -> (line: int, col: int) {
	if b.pc2line == nil {return b.line_num, b.col_num}
	p := b.pc2line
	pos := 0
	line = b.line_num
	col = b.col_num
	cur_pc := 0
	PC2LINE_BASE :: -1
	PC2LINE_RANGE :: 5
	PC2LINE_OP_FIRST :: 1
	for pos < len(p) {
		op := int(p[pos])
		pos += 1
		new_line: int
		if op == 0 {
			v, n := leb128_u(p[pos:])
			pos += n
			cur_pc += int(v)
			dl, n2 := leb128_s(p[pos:])
			pos += n2
			new_line = line + int(dl)
		} else {
			op -= PC2LINE_OP_FIRST
			cur_pc += op / PC2LINE_RANGE
			new_line = line + op % PC2LINE_RANGE + PC2LINE_BASE
		}
		// column delta
		dc, n3 := leb128_s(p[pos:])
		pos += n3
		if cur_pc > pc {break}
		line = new_line
		col += int(dc)
	}
	return line, col
}

leb128_u :: proc(b: []u8) -> (u32, int) {
	v: u32 = 0
	shift: u32 = 0
	for i in 0 ..< min(len(b), 5) {
		c := b[i]
		v |= u32(c & 0x7f) << shift
		if c & 0x80 == 0 {return v, i + 1}
		shift += 7
	}
	return v, min(len(b), 5)
}

leb128_s :: proc(b: []u8) -> (i32, int) {
	v, n := leb128_u(b)
	return i32(v >> 1) ~ -i32(v & 1), n
}
