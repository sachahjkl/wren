package frontend

import "base:runtime"

// The resolver assigns each function its variables (arguments then locals) and classifies every identifier
// reference as a local slot, an argument, a closure variable or a free (global/var) name. It is a pragmatic
// model of QuickJS's two-pass scope analysis: enough to emit correct get_loc/get_arg/get_var_ref/get_var and to
// fill the vardef / closure_var tables the serializer writes. Full fidelity (TDZ checks on every access, the
// exact var_ref_idx assignment, eval-induced dynamic scopes) is layered on top incrementally; the structure
// keeps each concern isolated.
//
// Scope model: a Func_Scope holds a flat `vars` list. During resolution we also keep a stack of lexical scopes
// (block scopes) mapping a name to a var index, so a reference finds the nearest binding. `var` declarations
// hoist to the function scope; `let`/`const`/`class`/`function`-in-block bind in the current block scope.

Resolver :: struct {
	allocator: runtime.Allocator,
	atoms:     ^Atom_Table,
	cur:       ^Func_Scope,
	scopes:    [dynamic]Name_Scope, // block-scope stack within the current function
	had_error: bool,
	error:     Error,
	strict:    bool,
}

Name_Scope :: struct {
	names: map[Atom]int, // name -> index into cur.vars
	is_function_top: bool,
}

resolver_init :: proc(r: ^Resolver, atoms: ^Atom_Table, allocator: runtime.Allocator) {
	r.allocator = allocator
	r.atoms = atoms
	r.scopes = make([dynamic]Name_Scope, allocator)
}

@(private = "file")
push_scope :: proc(r: ^Resolver, is_func_top := false) {
	append(&r.scopes, Name_Scope{names = make(map[Atom]int, 8, r.allocator), is_function_top = is_func_top})
}

@(private = "file")
pop_scope :: proc(r: ^Resolver) {
	pop(&r.scopes)
}

// declare_var adds a variable to the current function's `vars`, recording it in the current (or function-top for
// `var`) name scope. Returns the var index.
declare_var :: proc(r: ^Resolver, name: Atom, kind: Var_Kind, is_lexical, is_const: bool, is_arg := false) -> int {
	idx := len(r.cur.vars)
	append(&r.cur.vars, Var_Def{
		var_name = name, var_kind = kind, is_lexical = is_lexical, is_const = is_const,
		scope_level = 0, scope_next = -1, func_pool_idx = -1,
	})
	// register in a name scope for lookup
	if len(r.scopes) > 0 {
		target := len(r.scopes) - 1
		if !is_lexical {
			// var hoists to the function top scope
			for i := len(r.scopes) - 1; i >= 0; i -= 1 {
				if r.scopes[i].is_function_top {
					target = i
					break
				}
			}
		}
		r.scopes[target].names[name] = idx
	}
	if is_arg {
		r.cur.arg_count += 1
	}
	return idx
}

// Resolution result for an identifier reference: where the binding lives.
Ref_Kind :: enum u8 { local, arg, closure, global }

Ref :: struct {
	kind: Ref_Kind,
	idx:  int,
}

// resolve_ref finds the binding for a name in the current function's visible scopes. If not found locally it is
// treated as a global/free name (emitted as get_var/put_var with the atom). Closure capture across function
// boundaries is handled by lookup_closure.
resolve_ref :: proc(r: ^Resolver, name: Atom) -> Ref {
	for i := len(r.scopes) - 1; i >= 0; i -= 1 {
		if idx, ok := r.scopes[i].names[name]; ok {
			if idx < r.cur.arg_count {
				return Ref{kind = .arg, idx = idx}
			}
			return Ref{kind = .local, idx = idx - r.cur.arg_count}
		}
	}
	return Ref{kind = .global, idx = 0}
}
