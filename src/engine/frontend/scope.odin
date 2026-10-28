package frontend

import "base:runtime"

// Scope analysis data structures, mirroring QuickJS's JSFunctionDef / JSVarDef / JSClosureVar / JSVarScope. The
// resolver (resolve.odin) fills a Func_Scope per function; the emitter (emit*.odin) reads it to turn variable
// references into get_loc / get_arg / get_var_ref / get_var, and the serializer writes the vardefs and
// closure_var tables straight out of it. Keeping the exact fields and the exact var-kind / closure-type enums is
// what lets the vardef and closure tables serialize byte-for-byte like QuickJS's.

// JSVarKindEnum
Var_Kind :: enum u8 {
	normal = 0,
	function_decl,
	new_function_decl,
	catch_,
	function_name,
	private_field,
	private_method,
	private_getter,
	private_setter,
	private_getter_setter,
	using_,
	using_method,
}

// JSClosureTypeEnum
Closure_Type :: enum u8 {
	local = 0,
	arg,
	ref,
	global_ref,
	global_decl,
	global,
	module_decl,
	module_import,
}

// JSFunctionKindEnum bit values, used in the serialized function flags.
Func_Flag_Kind :: enum u8 {
	normal = 0,
	generator = 1,
	async = 2,
	async_generator = 3,
}

// JSVarDef: one argument or local variable. Mirrors the C struct's serialized fields exactly.
Var_Def :: struct {
	var_name:    Atom,
	scope_level: int,
	scope_next:  int,
	is_const:    bool,
	is_lexical:  bool,
	is_captured: bool,
	is_static_private: bool,
	var_kind:    Var_Kind,
	var_ref_idx: u16,
	func_pool_idx: int, // compile-time only: constant-pool index of a hoisted function definition
}

// JSClosureVar: one captured variable visible to the function through its closure.
Closure_Var :: struct {
	closure_type: Closure_Type,
	is_lexical:   bool,
	is_const:     bool,
	var_kind:     Var_Kind,
	var_idx:      u16,
	var_name:     Atom,
}

// JSVarScope: a lexical scope within a function (a block, the parameter scope, etc.).
Var_Scope :: struct {
	parent: int, // index into Func_Scope.scopes of the enclosing scope
	first:  int, // index into Func_Scope.vars of the last variable in this scope (-1 if none)
	has_using:   bool,
	is_await_using: bool,
	using_label_catch: int,
	using_label_end:   int,
}

// Func_Scope is the resolved description of one function (or the top-level program). It owns the variable and
// scope tables and, after emission, the final bytecode. It is the Odin counterpart of JSFunctionDef, trimmed to
// the fields the front-end needs and the serializer writes.
Func_Scope :: struct {
	allocator: runtime.Allocator,
	parent:    ^Func_Scope,

	// function header fields (serialized)
	func_name:         Atom,
	is_strict_mode:    bool,
	has_prototype:     bool,
	has_simple_parameter_list: bool,
	is_derived_class_constructor: bool,
	need_home_object:  bool,
	func_kind:         Func_Flag_Kind,
	new_target_allowed:bool,
	super_call_allowed:bool,
	super_allowed:     bool,
	arguments_allowed: bool,
	backtrace_barrier: bool,

	arg_count:         int,
	var_count:         int,
	defined_arg_count: int,
	stack_size:        int,
	var_ref_count:     int,

	// variable / scope / closure tables
	vars:       [dynamic]Var_Def,       // arguments (0..arg_count-1) then locals
	args:       [dynamic]Var_Def,       // separate arg list during resolution (merged into vars at finish)
	scopes:     [dynamic]Var_Scope,
	closure_vars: [dynamic]Closure_Var,

	scope_level: int, // current scope during resolution
	scope_first: int, // first var index of the current scope

	// constant pool: nested functions, template objects, regexp bytecode, float constants.
	cpool:      [dynamic]Const_Value,

	// final bytecode
	byte_code:  [dynamic]u8,

	// debug
	filename:   Atom,
	line_num:   int,
	col_num:    int,
	pc2line:    [dynamic]u8,
	source:     string,
}

// A constant-pool entry. QuickJS's cpool holds JSValues; for the front-end the only things that land there are
// child function bytecodes, boxed numbers that do not fit push_i32, strings, bigints, regexps (pattern+bytecode)
// and template objects. We keep a tagged union so the serializer can write each with the right BC tag.
Const_Value :: union {
	Const_Func,
	Const_F64,
	Const_Str,
	Const_BigInt,
	Const_Regexp,
	Const_Template,
	Const_Int,
}

Const_Func :: struct {fn: ^Func_Scope}
Const_F64 :: struct {value: f64}
Const_Int :: struct {value: i32}
Const_Str :: struct {value: String_Value}
Const_BigInt :: struct {digits: string, radix: int}
Const_Regexp :: struct {source: String_Value, bytecode: []u8}
Const_Template :: struct {cooked: []String_Value, raw: []String_Value}

func_scope_init :: proc(fs: ^Func_Scope, allocator: runtime.Allocator) {
	fs.allocator = allocator
	fs.vars = make([dynamic]Var_Def, allocator)
	fs.args = make([dynamic]Var_Def, allocator)
	fs.scopes = make([dynamic]Var_Scope, allocator)
	fs.closure_vars = make([dynamic]Closure_Var, allocator)
	fs.cpool = make([dynamic]Const_Value, allocator)
	fs.byte_code = make([dynamic]u8, allocator)
	fs.pc2line = make([dynamic]u8, allocator)
	// Scope 0 is the function (top-level) scope, as in QuickJS.
	append(&fs.scopes, Var_Scope{parent = -1, first = -1, using_label_catch = -1, using_label_end = -1})
	fs.scope_level = 0
	fs.scope_first = -1
}
