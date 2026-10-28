package jsrt

// The compiled form of a JavaScript function: Function_Bytecode mirrors QuickJS's JSFunctionBytecode.
//
// This is the contract between the two halves of the engine. The compiler front-end (E1) and the
// reference QuickJS C compiler both emit exactly this structure (through the serialized bytecode the
// reader in serialize.odin parses), and the interpreter in interp.odin executes it. The field set and
// the flags match quickjs-opcode.h / quickjs.c so bytecode round-trips byte-for-byte.
//
// A Function_Bytecode is a refcounted GC cell because its constant pool can hold other functions
// (closures) and objects (template literals), which can form cycles with the functions they close
// over.

Func_Kind :: enum u8 {
	normal          = 0,
	generator       = 1,
	async           = 2,
	async_generator = 3,
}

// A local variable slot definition (JSVarDef).
Var_Def :: struct {
	name:        Atom,
	scope_level: u32,
	scope_next:  i32, // stored as scope_next+1 in the stream; -1 means none after decode
	var_kind:    u8,
	is_const:    bool,
	is_lexical:  bool,
	is_captured: bool,
	var_ref_idx: u32, // valid when is_captured
}

// A closure variable descriptor (JSClosureVar): where an upvalue comes from in the parent frame.
Closure_Var :: struct {
	name:         Atom,
	var_idx:      u32,
	closure_type: u8, // 0 = local of parent, 1 = parent's closure var, ...
	is_const:     bool,
	is_lexical:   bool,
	var_kind:     u8,
}

Function_Bytecode :: struct {
	using header:              GC_Header,
	// Flags (JS_WriteFunctionTag layout).
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
	is_strict_mode:            bool,
	has_debug:                 bool,

	func_name:                 Atom,
	arg_count:                 u32,
	var_count:                 u32,
	defined_arg_count:         u32,
	stack_size:                u32,
	var_ref_count:             u32,
	closure_var_count:         u32,

	vardefs:                   []Var_Def,     // arg_count + var_count entries, or empty
	closure_vars:              []Closure_Var, // closure_var_count entries
	cpool:                     []Value,       // constant pool (owned)
	byte_code:                 []u8,          // the instruction stream (atoms already resolved)

	// Debug info (present iff has_debug).
	filename:                  Atom,
	line_num:                  u32,
	col_num:                   u32,
	pc2line:                   []u8,
	source:                    []u8, // original source text, may be empty
}

function_bc_new :: proc(rt: ^Runtime) -> ^Function_Bytecode {
	return gc_new_cell(rt, Function_Bytecode, .function_bc)
}

function_bc_ref :: proc(fb: ^Function_Bytecode) -> ^Function_Bytecode {
	fb.ref_count += 1
	return fb
}

function_bc_unref :: proc(rt: ^Runtime, fb: ^Function_Bytecode) {
	fb.ref_count -= 1
	if fb.ref_count == 0 {gc_free_cell(rt, fb)}
}

function_bc_destroy :: proc(rt: ^Runtime, fb: ^Function_Bytecode) {
	for v in fb.cpool {value_free(rt, v)}
	if fb.cpool != nil {delete(fb.cpool, rt.allocator)}
	if fb.vardefs != nil {delete(fb.vardefs, rt.allocator)}
	if fb.closure_vars != nil {delete(fb.closure_vars, rt.allocator)}
	if fb.byte_code != nil {delete(fb.byte_code, rt.allocator)}
	if fb.pc2line != nil {delete(fb.pc2line, rt.allocator)}
	if fb.source != nil {delete(fb.source, rt.allocator)}
	gc_raw_free(rt, fb, size_of(Function_Bytecode))
}
