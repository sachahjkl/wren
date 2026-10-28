package frontend

// The abstract syntax tree, as Odin tagged unions on an arena. Every node is a pointer into arena memory; a whole
// parse is freed by resetting the arena. Expressions and statements are each a `union` of concrete node structs,
// so a `switch e in node` is exhaustive and the compiler checks we handle every shape. This is the "profit from
// the language" the brief asks for: no manual tag field, no vtables, no per-node free.
//
// Node structs keep a Source_Pos for diagnostics and the pc2line table. Child links are pointers (^Expr, ^Stmt)
// or arena slices ([]^Expr). Identifier references carry the interned Atom so the resolver and emitter never
// re-hash a name.

// --- expressions --------------------------------------------------------------------------------------------

Expr :: union {
	Ident_Expr,
	This_Expr,
	Super_Expr,
	New_Target_Expr,
	Import_Meta_Expr,
	Null_Lit,
	Bool_Lit,
	Num_Lit,
	BigInt_Lit,
	Str_Lit,
	Regexp_Lit,
	Template_Lit,
	Tagged_Template_Expr,
	Array_Lit,
	Object_Lit,
	Function_Expr,     // function / arrow / async / generator expression
	Class_Expr,
	Unary_Expr,
	Update_Expr,       // ++ / -- prefix and postfix
	Binary_Expr,
	Logical_Expr,      // && || ??  (short-circuit; separate because of control flow)
	Assign_Expr,
	Conditional_Expr,  // ?:
	Call_Expr,
	New_Expr,
	Member_Expr,       // a.b and a[b], with optional-chaining flag
	Sequence_Expr,     // comma operator
	Spread_Expr,       // ...x in an argument or array/object literal
	Yield_Expr,
	Await_Expr,
	Paren_Expr,        // kept so the differential judge can reproduce parenthesized-expression quirks
	Optional_Chain,    // the root of an optional chain (QuickJS resolves this in a dedicated phase)
}

Ident_Expr :: struct {
	pos:  Source_Pos,
	name: Atom,
	text: string, // original spelling, for diagnostics
}

This_Expr :: struct {pos: Source_Pos}
Super_Expr :: struct {pos: Source_Pos}
New_Target_Expr :: struct {pos: Source_Pos}
Import_Meta_Expr :: struct {pos: Source_Pos}
Null_Lit :: struct {pos: Source_Pos}
Bool_Lit :: struct {pos: Source_Pos, value: bool}

Num_Lit :: struct {
	pos:    Source_Pos,
	value:  f64,
	is_int: bool, // fits i32: emit push_i32 rather than a float constant
}

BigInt_Lit :: struct {
	pos:    Source_Pos,
	digits: string,
	radix:  int,
}

Str_Lit :: struct {
	pos:   Source_Pos,
	value: String_Value,
}

Regexp_Lit :: struct {
	pos:     Source_Pos,
	pattern: string,
	flags:   string,
}

Template_Lit :: struct {
	pos:    Source_Pos,
	// cooked[i] is the string between expression i-1 and i; exprs[i] sits between cooked[i] and cooked[i+1].
	cooked: []String_Value,
	raw:    []string,
	exprs:  []^Expr,
}

Tagged_Template_Expr :: struct {
	pos:   Source_Pos,
	tag:   ^Expr,
	quasi: ^Template_Lit,
}

Array_Lit :: struct {
	pos:      Source_Pos,
	// nil entries are elisions (holes); a Spread_Expr entry is a spread element.
	elements: []^Expr,
}

Object_Lit :: struct {
	pos:        Source_Pos,
	properties: []Property,
}

// A member of an object literal or a class body. `kind` distinguishes data, shorthand, method, getter, setter,
// spread and (for classes) fields and static blocks.
Property_Kind :: enum u8 {
	init,        // key: value
	shorthand,   // {x}
	method,
	get,
	set,
	spread,      // ...x
	field,       // class field
	static_block,// class static {}
}

Property :: struct {
	pos:          Source_Pos,
	kind:         Property_Kind,
	computed:     bool,
	is_static:    bool,   // class member
	is_private:   bool,   // #name
	key:          ^Expr,  // the property key (an Ident/Str/Num literal or a computed expr); nil for spread/static_block
	key_atom:     Atom,   // the key atom when it is a plain name (not computed)
	value:        ^Expr,  // value / method function; nil for a field with no initializer
	func:         ^Function_Node, // for method/get/set: the function
}

Function_Kind :: enum u8 {
	normal,
	arrow,
	method,
	getter,
	setter,
	ctor,         // class constructor
	ctor_derived, // derived class constructor
}

// A shared function description, pointed to by Function_Expr, Function_Stmt, Property (methods) and classes.
Function_Node :: struct {
	pos:         Source_Pos,
	name:        Atom,           // JS_ATOM_NULL for anonymous
	name_text:   string,
	kind:        Function_Kind,
	is_async:    bool,
	is_generator:bool,
	params:      []^Pattern,     // parameter patterns (incl. defaults/rest via Pattern)
	defined_arg_count: int,      // params before the first default/rest (the .length)
	simple_params: bool,         // no destructuring, default or rest (affects arguments object / strict rules)
	body_stmts:  []^Stmt,        // for a block body
	body_expr:   ^Expr,          // for a concise arrow body (`x => x+1`); nil otherwise
	is_expr_body:bool,
	strict:      bool,
	// Resolver/emitter fill these in:
	resolved:    ^Func_Scope,
}

Function_Expr :: struct {
	pos:  Source_Pos,
	func: ^Function_Node,
}

Class_Expr :: struct {
	pos:  Source_Pos,
	class: ^Class_Node,
}

Class_Node :: struct {
	pos:        Source_Pos,
	name:       Atom,            // JS_ATOM_NULL if anonymous
	name_text:  string,
	super_class:^Expr,           // nil if no extends
	members:    []Property,      // methods, fields, static blocks
}

Unary_Op :: enum u8 { neg, plus, lnot, bitnot, typeof_, void_, delete_ }

Unary_Expr :: struct {
	pos:     Source_Pos,
	op:      Unary_Op,
	operand: ^Expr,
}

Update_Expr :: struct {
	pos:     Source_Pos,
	inc:     bool, // ++ when true, -- when false
	prefix:  bool,
	operand: ^Expr,
}

Binary_Op :: enum u8 {
	add, sub, mul, div, mod, pow,
	shl, sar, shr,
	band, bor, bxor,
	lt, lte, gt, gte,
	eq, neq, strict_eq, strict_neq,
	instanceof, in_,
}

Binary_Expr :: struct {
	pos:   Source_Pos,
	op:    Binary_Op,
	left:  ^Expr,
	right: ^Expr,
}

Logical_Op :: enum u8 { and_and, or_or, nullish }

Logical_Expr :: struct {
	pos:   Source_Pos,
	op:    Logical_Op,
	left:  ^Expr,
	right: ^Expr,
}

Assign_Op :: enum u8 {
	assign,
	add, sub, mul, div, mod, pow,
	shl, sar, shr, band, bor, bxor,
	and_and, or_or, nullish,
}

Assign_Expr :: struct {
	pos:    Source_Pos,
	op:     Assign_Op,
	target: ^Expr,     // an lvalue expression or (for plain assign) a destructuring pattern expr
	value:  ^Expr,
}

Conditional_Expr :: struct {
	pos:  Source_Pos,
	cond: ^Expr,
	then: ^Expr,
	els:  ^Expr,
}

Call_Expr :: struct {
	pos:      Source_Pos,
	callee:   ^Expr,
	args:     []^Expr,  // spread elements are Spread_Expr entries
	optional: bool,     // a?.b() : the call is short-circuited by an optional chain
}

New_Expr :: struct {
	pos:    Source_Pos,
	callee: ^Expr,
	args:   []^Expr,
}

Member_Expr :: struct {
	pos:       Source_Pos,
	object:    ^Expr,
	// Exactly one of these is set:
	property:  ^Expr,  // computed: a[b]
	name:      Atom,   // static: a.b
	name_text: string,
	is_private:bool,   // a.#b
	computed:  bool,
	optional:  bool,   // a?.b
}

Sequence_Expr :: struct {
	pos:   Source_Pos,
	exprs: []^Expr,
}

Spread_Expr :: struct {
	pos:  Source_Pos,
	arg:  ^Expr,
}

Yield_Expr :: struct {
	pos:      Source_Pos,
	arg:      ^Expr, // nil for `yield`
	delegate: bool,  // yield*
}

Await_Expr :: struct {
	pos: Source_Pos,
	arg: ^Expr,
}

Paren_Expr :: struct {
	pos:  Source_Pos,
	expr: ^Expr,
}

Optional_Chain :: struct {
	pos:  Source_Pos,
	expr: ^Expr,
}

// --- patterns (binding and assignment targets) -------------------------------------------------------------

Pattern :: union {
	Ident_Pattern,
	Array_Pattern,
	Object_Pattern,
	Assign_Pattern,  // default value: x = 1
	Rest_Pattern,    // ...x
	Member_Pattern,  // assignment target a.b / a[b] (only in assignment destructuring)
}

Ident_Pattern :: struct {
	pos:  Source_Pos,
	name: Atom,
	text: string,
}

Array_Pattern :: struct {
	pos:      Source_Pos,
	elements: []^Pattern, // nil entry = hole
}

Object_Pattern :: struct {
	pos:        Source_Pos,
	properties: []Pattern_Prop,
	rest:       ^Pattern, // ...rest, nil if none
}

Pattern_Prop :: struct {
	pos:      Source_Pos,
	computed: bool,
	key:      ^Expr,
	key_atom: Atom,
	value:    ^Pattern,
}

Assign_Pattern :: struct {
	pos:     Source_Pos,
	target:  ^Pattern,
	default: ^Expr,
}

Rest_Pattern :: struct {
	pos:    Source_Pos,
	target: ^Pattern,
}

Member_Pattern :: struct {
	pos:    Source_Pos,
	member: ^Member_Expr,
}

// --- statements ---------------------------------------------------------------------------------------------

Stmt :: union {
	Expr_Stmt,
	Block_Stmt,
	Empty_Stmt,
	Var_Decl,
	Function_Stmt,
	Class_Stmt,
	If_Stmt,
	For_Stmt,
	For_In_Stmt,   // for-in and for-of
	While_Stmt,
	Do_While_Stmt,
	Switch_Stmt,
	Return_Stmt,
	Break_Stmt,
	Continue_Stmt,
	Throw_Stmt,
	Try_Stmt,
	Labeled_Stmt,
	With_Stmt,
	Debugger_Stmt,
	Import_Decl,
	Export_Decl,
}

Expr_Stmt :: struct {
	pos:  Source_Pos,
	expr: ^Expr,
	// A leading directive like "use strict"; the string value and whether it is the directive prologue.
	directive: string,
}

Block_Stmt :: struct {
	pos:   Source_Pos,
	stmts: []^Stmt,
}

Empty_Stmt :: struct {pos: Source_Pos}

Decl_Kind :: enum u8 { var, let, const_, using_, await_using }

Var_Decl :: struct {
	pos:  Source_Pos,
	kind: Decl_Kind,
	decls: []Var_Declarator,
}

Var_Declarator :: struct {
	pos:  Source_Pos,
	target: ^Pattern,
	init: ^Expr, // nil if no initializer
}

Function_Stmt :: struct {
	pos:  Source_Pos,
	func: ^Function_Node,
}

Class_Stmt :: struct {
	pos:   Source_Pos,
	class: ^Class_Node,
}

If_Stmt :: struct {
	pos:  Source_Pos,
	cond: ^Expr,
	then: ^Stmt,
	els:  ^Stmt, // nil if no else
}

For_Stmt :: struct {
	pos:    Source_Pos,
	init_decl: ^Var_Decl, // one of init_decl / init_expr may be set (or neither); a standalone arena Var_Decl
	init_expr: ^Expr,
	cond:   ^Expr,  // nil if omitted
	update: ^Expr,  // nil if omitted
	body:   ^Stmt,
}

For_In_Kind :: enum u8 { in_, of_, await_of }

For_In_Stmt :: struct {
	pos:      Source_Pos,
	kind:     For_In_Kind,
	left_decl: ^Var_Decl, // when the left is a declaration
	left_expr: ^Expr,     // when the left is an assignment target
	right:    ^Expr,
	body:     ^Stmt,
}

While_Stmt :: struct {
	pos:  Source_Pos,
	cond: ^Expr,
	body: ^Stmt,
}

Do_While_Stmt :: struct {
	pos:  Source_Pos,
	body: ^Stmt,
	cond: ^Expr,
}

Switch_Stmt :: struct {
	pos:   Source_Pos,
	disc:  ^Expr,
	cases: []Switch_Case,
}

Switch_Case :: struct {
	pos:   Source_Pos,
	test:  ^Expr, // nil for `default`
	body:  []^Stmt,
}

Return_Stmt :: struct {
	pos: Source_Pos,
	arg: ^Expr, // nil for `return;`
}

Break_Stmt :: struct {
	pos:   Source_Pos,
	label: Atom, // JS_ATOM_NULL if unlabeled
	label_text: string,
}

Continue_Stmt :: struct {
	pos:   Source_Pos,
	label: Atom,
	label_text: string,
}

Throw_Stmt :: struct {
	pos: Source_Pos,
	arg: ^Expr,
}

Try_Stmt :: struct {
	pos:         Source_Pos,
	block:       ^Stmt, // a Block_Stmt
	catch_param: ^Pattern, // nil for optional catch binding
	catch_block: ^Stmt, // a Block_Stmt, nil if none
	finally_block: ^Stmt, // a Block_Stmt, nil if none
}

Labeled_Stmt :: struct {
	pos:   Source_Pos,
	label: Atom,
	label_text: string,
	body:  ^Stmt,
}

With_Stmt :: struct {
	pos:  Source_Pos,
	obj:  ^Expr,
	body: ^Stmt,
}

Debugger_Stmt :: struct {pos: Source_Pos}

// --- module declarations ------------------------------------------------------------------------------------

Import_Decl :: struct {
	pos:          Source_Pos,
	source:       String_Value,
	source_text:  string,
	default_name: Atom,       // import x from ...
	namespace_name: Atom,     // import * as x from ...
	names:        []Import_Specifier,
	attributes:   []Import_Attribute,
	type_only:    bool,
}

Import_Specifier :: struct {
	imported: Atom,  // the name in the module
	local:    Atom,  // the local binding
	imported_text: string,
	local_text: string,
}

Import_Attribute :: struct {
	key:   string,
	value: String_Value,
}

Export_Decl :: struct {
	pos:         Source_Pos,
	// one of these shapes:
	decl:        ^Stmt,       // export <decl>
	default_expr:^Expr,       // export default <expr>
	default_decl:^Stmt,       // export default <function/class>
	names:       []Export_Specifier, // export { a, b as c }
	source:      String_Value,       // re-export: export ... from "mod"
	source_text: string,
	has_source:  bool,
	star:        bool,        // export * from "mod"
	star_as:     Atom,        // export * as ns from "mod"
	is_default:  bool,
}

Export_Specifier :: struct {
	local:    Atom,
	exported: Atom,
	local_text: string,
	exported_text: string,
}

// --- program ------------------------------------------------------------------------------------------------

Program_Kind :: enum u8 { script, module, eval, indirect_eval, function_body }

Program :: struct {
	kind:  Program_Kind,
	stmts: []^Stmt,
	strict:bool,
	resolved: ^Func_Scope,
}
