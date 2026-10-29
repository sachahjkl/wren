package frontend

import "base:runtime"

// The compiler's data model. The front-end reproduces QuickJS-ng's single-pass parser/compiler because the
// contract with E2 and with the differential judge is the exact bytecode, and that bytecode is defined by the
// order in which QuickJS's parser emits phase-1 instructions and by its resolve_variables / resolve_labels passes.
// These structures mirror JSFunctionDef, JSToken, JSParseState and friends field for field where a field affects
// the output; everything lives on one caller-supplied allocator (an arena frees a whole compilation at once).

// --- tokens (quickjs.c TOK_*; a single character token is its own code) ------------------------------------

TOK_NUMBER :: -128
TOK_STRING :: -127
TOK_TEMPLATE :: -126
TOK_IDENT :: -125
TOK_REGEXP :: -124
TOK_MUL_ASSIGN :: -123
TOK_DIV_ASSIGN :: -122
TOK_MOD_ASSIGN :: -121
TOK_PLUS_ASSIGN :: -120
TOK_MINUS_ASSIGN :: -119
TOK_SHL_ASSIGN :: -118
TOK_SAR_ASSIGN :: -117
TOK_SHR_ASSIGN :: -116
TOK_AND_ASSIGN :: -115
TOK_XOR_ASSIGN :: -114
TOK_OR_ASSIGN :: -113
TOK_POW_ASSIGN :: -112
TOK_LAND_ASSIGN :: -111
TOK_LOR_ASSIGN :: -110
TOK_DOUBLE_QUESTION_MARK_ASSIGN :: -109
TOK_DEC :: -108
TOK_INC :: -107
TOK_SHL :: -106
TOK_SAR :: -105
TOK_SHR :: -104
TOK_LT :: -103
TOK_LTE :: -102
TOK_GT :: -101
TOK_GTE :: -100
TOK_EQ :: -99
TOK_STRICT_EQ :: -98
TOK_NEQ :: -97
TOK_STRICT_NEQ :: -96
TOK_LAND :: -95
TOK_LOR :: -94
TOK_POW :: -93
TOK_ARROW :: -92
TOK_ELLIPSIS :: -91
TOK_DOUBLE_QUESTION_MARK :: -90
TOK_QUESTION_MARK_DOT :: -89
TOK_ERROR :: -88
TOK_PRIVATE_NAME :: -87
TOK_EOF :: -86
// keywords, in the same order as the first predefined atoms
TOK_NULL :: -85
TOK_FALSE :: -84
TOK_TRUE :: -83
TOK_IF :: -82
TOK_ELSE :: -81
TOK_RETURN :: -80
TOK_VAR :: -79
TOK_THIS :: -78
TOK_DELETE :: -77
TOK_VOID :: -76
TOK_TYPEOF :: -75
TOK_NEW :: -74
TOK_IN :: -73
TOK_INSTANCEOF :: -72
TOK_DO :: -71
TOK_WHILE :: -70
TOK_FOR :: -69
TOK_BREAK :: -68
TOK_CONTINUE :: -67
TOK_SWITCH :: -66
TOK_CASE :: -65
TOK_DEFAULT :: -64
TOK_THROW :: -63
TOK_TRY :: -62
TOK_CATCH :: -61
TOK_FINALLY :: -60
TOK_FUNCTION :: -59
TOK_DEBUGGER :: -58
TOK_WITH :: -57
TOK_CLASS :: -56
TOK_CONST :: -55
TOK_ENUM :: -54
TOK_EXPORT :: -53
TOK_EXTENDS :: -52
TOK_IMPORT :: -51
TOK_SUPER :: -50
TOK_USING :: -49
TOK_IMPLEMENTS :: -48
TOK_INTERFACE :: -47
TOK_LET :: -46
TOK_PACKAGE :: -45
TOK_PRIVATE :: -44
TOK_PROTECTED :: -43
TOK_PUBLIC :: -42
TOK_STATIC :: -41
TOK_YIELD :: -40
TOK_AWAIT :: -39
TOK_OF :: -38

TOK_FIRST_KEYWORD :: TOK_NULL
TOK_LAST_KEYWORD :: TOK_AWAIT

// Well-known atoms (quickjs-atom.h order). Keywords are atoms 1..47.
A_null :: Atom(1)
A_this :: Atom(8)
A_let :: Atom(40)
A_static :: Atom(45)
A_yield :: Atom(46)
A_await :: Atom(47)
A_empty_string :: Atom(48)
JS_ATOM_LAST_KEYWORD :: Atom(37)        // using
JS_ATOM_LAST_STRICT_KEYWORD :: Atom(46) // yield

A_using: Atom
A_length, A_name, A_eval, A_prototype, A_constructor, A_value, A_get, A_set, A_of, A___proto__: Atom
A_undefined, A_arguments, A__eval_, A__ret_, A__var_, A__arg_var_, A__with_, A__using_dispose_: Atom
A_use, A_dispose, A_disposeAsync, A_target, A_concat, A_done, A_next, A_raw: Atom
A_new_target, A_this_active_func, A_home_object, A_computed_field, A_static_computed_field: Atom
A_class_fields_init, A_brand, A_hash_constructor, A_as, A_from, A_meta, A__default_, A__star_: Atom
A_async, A_default, A_return, A_function: Atom
A_ECMAScript_ignore: Atom

@(init)
init_well_known_atoms :: proc "contextless" () {
	find :: proc "contextless" (name: string) -> Atom {
		for n, i in PREDEFINED_ATOMS {
			if n == name {return Atom(i + 1)}
		}
		return JS_ATOM_NULL
	}
	A_using = find("using")
	A_length = find("length")
	A_name = find("name")
	A_eval = find("eval")
	A_prototype = find("prototype")
	A_constructor = find("constructor")
	A_value = find("value")
	A_get = find("get")
	A_set = find("set")
	A_of = find("of")
	A___proto__ = find("__proto__")
	A_undefined = find("undefined")
	A_arguments = find("arguments")
	A__eval_ = find("<eval>")
	A__ret_ = find("<ret>")
	A__var_ = find("<var>")
	A__arg_var_ = find("<arg_var>")
	A__with_ = find("<with>")
	A__using_dispose_ = find("<using_dispose>")
	A_use = find("use")
	A_dispose = find("dispose")
	A_disposeAsync = find("disposeAsync")
	A_target = find("target")
	A_concat = find("concat")
	A_done = find("done")
	A_next = find("next")
	A_raw = find("raw")
	A_new_target = find("new.target")
	A_this_active_func = find("this.active_func")
	A_home_object = find("<home_object>")
	A_computed_field = find("<computed_field>")
	A_static_computed_field = find("<static_computed_field>")
	A_class_fields_init = find("<class_fields_init>")
	A_brand = find("<brand>")
	A_hash_constructor = find("#constructor")
	A_as = find("as")
	A_from = find("from")
	A_meta = find("meta")
	A__default_ = find("*default*")
	A__star_ = find("*")
	A_async = find("async")
	A_default = find("default")
	A_return = find("return")
	A_function = find("function")
}

JS_Token :: struct {
	val:         int,
	line_num:    int,
	col_num:     int,
	ptr:         int, // byte index of the token start
	line_start:  int,
	// TOK_STRING / TOK_TEMPLATE
	str:         String_Value,
	sep:         int,
	// TOK_NUMBER
	num:         JS_Value,
	// TOK_IDENT / keywords / TOK_PRIVATE_NAME
	atom:        Atom,
	has_escape:  bool,
	is_reserved: bool,
	// TOK_REGEXP
	re_body:     String_Value,
	re_flags:    String_Value,
}

// --- function definition (JSFunctionDef) ------------------------------------------------------------------

Func_Kind :: enum u8 {
	normal          = 0,
	generator       = 1,
	async           = 2,
	async_generator = 3,
}

func_kind_is_generator :: #force_inline proc(k: Func_Kind) -> bool {return (u8(k) & 1) != 0}
func_kind_is_async :: #force_inline proc(k: Func_Kind) -> bool {return (u8(k) & 2) != 0}

Parse_Func :: enum u8 {
	statement,
	var_,
	expr,
	arrow,
	getter,
	setter,
	method,
	class_static_init,
	class_constructor,
	derived_class_constructor,
}

Parse_Export :: enum u8 {
	none,
	named,
	default_,
}

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

Var_Def :: struct {
	var_name:          Atom,
	scope_level:       int,
	scope_next:        int,
	is_const:          bool,
	is_lexical:        bool,
	is_captured:       bool,
	is_static_private: bool,
	var_kind:          Var_Kind,
	var_ref_idx:       int,
	func_pool_idx:     int,
}

Closure_Var :: struct {
	closure_type: Closure_Type,
	is_lexical:   bool,
	is_const:     bool,
	var_kind:     Var_Kind,
	var_idx:      int,
	var_name:     Atom,
}

Var_Scope :: struct {
	parent:            int,
	first:             int,
	has_using:         bool,
	is_await_using:    bool,
	using_label_catch: int,
	using_label_end:   int,
}

ARG_SCOPE_INDEX :: 1
ARG_SCOPE_END :: -2
GLOBAL_VAR_OFFSET :: 0x40000000
ARGUMENT_VAR_OFFSET :: 0x20000000
JS_MAX_LOCAL_VARS :: 65535
JS_STACK_SIZE_MAX :: 65534

Block_Env :: struct {
	prev:              ^Block_Env,
	label_name:        Atom,
	label_break:       int,
	label_cont:        int,
	drop_count:        int,
	label_finally:     int,
	scope_level:       int,
	has_iterator:      bool,
	is_async_iterator: bool,
	is_regular_stmt:   bool,
	has_using:         bool,
	using_scope_level: int,
}

Global_Var :: struct {
	cpool_idx:   int,
	force_init:  bool,
	is_lexical:  bool,
	is_const:    bool,
	scope_level: int,
	var_name:    Atom,
}

Reloc_Entry :: struct {
	next: ^Reloc_Entry,
	addr: int,
	size: int,
}

Jump_Slot :: struct {
	op, size, pos, label: int,
}

Label_Slot :: struct {
	ref_count:   int,
	pos:         int,
	pos2:        int,
	addr:        int,
	first_reloc: ^Reloc_Entry,
}

Source_Loc_Slot :: struct {
	pc:       int,
	line_num: int,
	col_num:  int,
}

Func_Def :: struct {
	parent:                       ^Func_Def,
	parent_cpool_idx:             int,
	parent_scope_level:           int,
	child_list:                   [dynamic]^Func_Def,

	eval_type:                    Eval_Type,
	is_eval:                      bool,
	is_global_var:                bool,
	is_func_expr:                 bool,
	has_home_object:              bool,
	has_prototype:                bool,
	has_simple_parameter_list:    bool,
	has_parameter_expressions:    bool,
	has_use_strict:               bool,
	has_eval_call:                bool,
	has_arguments_binding:        bool,
	has_this_binding:             bool,
	new_target_allowed:           bool,
	super_call_allowed:           bool,
	super_allowed:                bool,
	arguments_allowed:            bool,
	is_derived_class_constructor: bool,
	in_function_body:             bool,
	backtrace_barrier:            bool,
	need_home_object:             bool,
	use_short_opcodes:            bool,
	has_await:                    bool,

	func_kind:                    Func_Kind,
	func_type:                    Parse_Func,
	is_strict_mode:               bool,
	func_name:                    Atom,

	vars:                         [dynamic]Var_Def,
	source_loc_size:              int, // the number of OP_source_loc resolve_variables left in byte_code
	args:                         [dynamic]Var_Def,
	defined_arg_count:            int,
	var_ref_count:                int,
	var_object_idx:               int,
	arg_var_object_idx:           int,
	arguments_var_idx:            int,
	arguments_arg_idx:            int,
	func_var_idx:                 int,
	eval_ret_idx:                 int,
	this_var_idx:                 int,
	new_target_var_idx:           int,
	this_active_func_var_idx:     int,
	home_object_var_idx:          int,

	scope_level:                  int,
	scope_first:                  int,
	scopes:                       [dynamic]Var_Scope,
	body_scope:                   int,

	global_vars:                  [dynamic]Global_Var,

	byte_code:                    [dynamic]u8,
	last_opcode_pos:              int,

	label_slots:                  [dynamic]Label_Slot,
	top_break:                    ^Block_Env,

	cpool:                        [dynamic]JS_Value,
	closure_var:                  [dynamic]Closure_Var,

	jump_slots:                   [dynamic]Jump_Slot,
	source_loc_slots:             [dynamic]Source_Loc_Slot,
	line_number_last:             int,
	line_number_last_pc:          int,
	col_number_last:              int,

	filename:                     Atom,
	line_num:                     int,
	col_num:                      int,
	pc2line:                      [dynamic]u8,
	source:                       []u8, // the function's text for toString (a slice of the parse buffer), kept only with Compile_Options.keep_source

	module:                       ^Module_Def,
}

Eval_Type :: enum u8 {
	global   = 0,
	module   = 1,
	direct   = 2,
	indirect = 3,
}

// --- modules (JSModuleDef, the parts the compiler fills and JS_WriteModule writes) --------------------------

Export_Type :: enum u8 {
	local    = 0,
	indirect = 1,
}

Req_Module_Entry :: struct {
	module_name: Atom,
	attributes:  ^Import_Attributes, // nil when there is no `with` clause (not serialized by JS_WriteModule)
}

Export_Entry :: struct {
	var_idx:        int, // local export: closure variable index
	req_module_idx: int, // indirect export
	export_type:    Export_Type,
	local_name:     Atom,
	export_name:    Atom,
}

Import_Entry :: struct {
	var_idx:        int,
	import_name:    Atom,
	req_module_idx: int,
	is_star:        bool,
}

Module_Def :: struct {
	module_name:         Atom,
	req_module_entries:  [dynamic]Req_Module_Entry,
	export_entries:      [dynamic]Export_Entry,
	star_export_entries: [dynamic]int,
	import_entries:      [dynamic]Import_Entry,
	has_tla:             bool,
	func_obj:            ^Function_Bytecode,
}

// --- output (JSFunctionBytecode, the serialized shape) -----------------------------------------------------

Function_Bytecode :: struct {
	is_strict_mode:               bool,
	has_prototype:                bool,
	has_simple_parameter_list:    bool,
	is_derived_class_constructor: bool,
	need_home_object:             bool,
	func_kind:                    Func_Kind,
	new_target_allowed:           bool,
	super_call_allowed:           bool,
	super_allowed:                bool,
	arguments_allowed:            bool,
	backtrace_barrier:            bool,
	byte_code:                    []u8,
	func_name:                    Atom,
	vardefs:                      []Var_Def, // nil when the function has no vardefs table
	closure_var:                  []Closure_Var,
	arg_count:                    int,
	var_count:                    int,
	defined_arg_count:            int,
	stack_size:                   int,
	var_ref_count:                int,
	cpool:                        []JS_Value,
	filename:                     Atom,
	line_num:                     int,
	col_num:                      int,
	pc2line:                      []u8,
	source:                       []u8,
}

// --- parse state (JSParseState) ---------------------------------------------------------------------------

Parse_State :: struct {
	allocator:           runtime.Allocator,
	atoms:               ^Atom_Table,
	last_line_num:       int,
	last_col_num:        int,
	line_num:            int,
	col_num:             int,
	filename:            Atom,
	token:               JS_Token,
	got_lf:              bool,
	last_ptr:            int,
	buf_start:           int,
	buf_ptr:             int,
	buf_end:             int,
	line_start:          int,
	eol:                 int,
	mark:                int,
	buf:                 []u8, // source bytes followed by NUL padding (the C lexer reads a few bytes ahead)
	cur_func:            ^Func_Def,
	keep_source:         bool,
	is_module:           bool,
	allow_html_comments: bool,
	// error state: the first error wins, like a thrown SyntaxError
	has_error:           bool,
	error:               Error,
	depth:               int, // recursion guard (js_check_stack_overflow)
	max_depth:           int,
	stack:               Stack_Guard,
}

// Stack_Guard is js_check_stack_overflow: the recursive parts of the compiler stop with a "stack overflow" error
// once the stack has grown `budget` bytes below `base` (the address of a local taken at the compile entry). On
// wasm32 the address-taken local lives on the shadow stack, which is the one that would overflow.
Stack_Guard :: struct {
	base:   uintptr,
	budget: uintptr, // 0: no limit
}

@(require_results)
stack_guard_here :: #force_no_inline proc(budget: uintptr) -> Stack_Guard {
	marker: u8
	return Stack_Guard{base = uintptr(&marker), budget = budget}
}

stack_exhausted :: #force_no_inline proc(g: Stack_Guard) -> bool {
	if g.budget == 0 {return false}
	marker: u8
	sp := uintptr(&marker)
	used := g.base > sp ? g.base - sp : sp - g.base
	return used > g.budget
}
