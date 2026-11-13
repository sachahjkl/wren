package test_all

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"
import "wb:tools/tooling"

// Code of a test that runs in every program: Odin builds the *_test.odin files of a package into every program that imports it, so an
// @(init) or @(fini) there, or a package-level variable whose initialiser calls something, runs at each start of wren.exe (an init of the
// idb tests read the whole temporary folder there, 0.8 s, and left a folder in it). What a test needs is made inside the test (a
// sync.Once when several share it). The declarations the compiler reads at the top level of a file, and in its `when` blocks.
// Only the folders a program can import are scanned: Wren's packages and the toolkit's. A test package of its own (the toolkit's
// tests/ folder) is built only by its test run, where its inits are the test's to make.

TEST_INIT_DIRS :: [?]string{"src", "ext/gui_toolkit/src"}
TEST_FILE_SUFFIX :: "_test.odin"

Test_Init :: struct { file: string, line: int, name, what: string }

find_test_inits :: proc(dirs: []string, allocator := context.allocator) -> []Test_Init {
	found := make([dynamic]Test_Init, allocator)
	for dir in dirs { scan_test_inits(dir, &found, allocator) }
	return found[:]
}

@(private = "file")
scan_test_inits :: proc(dir: string, found: ^[dynamic]Test_Init, allocator := context.allocator) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	for e in entries {
		if e.type == .Directory {
			if !strings.has_prefix(e.name, ".") { scan_test_inits(e.fullpath, found, allocator) }
			continue
		}
		if !strings.has_suffix(e.name, TEST_FILE_SUFFIX) { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rerr != nil { continue }
		file := ast.File{src = string(data), fullpath = e.fullpath}
		p := parser.default_parser({.Optional_Semicolons})
		p.err = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
		p.warn = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
		if !parser.parse_file(&p, &file) { fmt.eprintfln("%s does not parse", e.fullpath); continue }
		for decl in file.decls { check_test_decl(e.fullpath, decl, found, allocator) }
	}
}

@(private = "file")
check_test_decl :: proc(path: string, decl: ^ast.Stmt, found: ^[dynamic]Test_Init, allocator := context.allocator) {
	#partial switch d in decl.derived_stmt {
	case ^ast.When_Stmt:
		check_test_decl(path, d.body, found, allocator)
		if d.else_stmt != nil { check_test_decl(path, d.else_stmt, found, allocator) }
	case ^ast.Block_Stmt:
		for s in d.stmts { check_test_decl(path, s, found, allocator) }
	case ^ast.Value_Decl:
		name := ""
		line := d.pos.line
		if len(d.names) > 0 {
			line = d.names[0].pos.line
			if id, ok := d.names[0].derived_expr.(^ast.Ident); ok { name = id.name }
		}
		add :: proc(found: ^[dynamic]Test_Init, path: string, line: int, name, what: string, allocator := context.allocator) {
			append(found, Test_Init{strings.clone(path, allocator), line, strings.clone(name, allocator), what})
		}
		for attr in d.attributes {
			for elem in attr.elems {
				key := elem
				if fv, is_field := elem.derived_expr.(^ast.Field_Value); is_field { key = fv.field }
				if id, ok := key.derived_expr.(^ast.Ident); ok && (id.name == "init" || id.name == "fini") {
					add(found, path, line, name, id.name == "init" ? "an @(init)" : "an @(fini)", allocator)
				}
			}
		}
		if d.is_mutable {
			for value in d.values {
				if runs_code(value) { add(found, path, line, name, "an initialiser that calls something", allocator); break }
			}
		}
	}
}

// A call anywhere in the expression, except in the body of a procedure literal (which runs only when called).
runs_code :: proc(expr: ^ast.Expr) -> bool {
	calls := false
	v := ast.Visitor{data = &calls, visit = proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
		if node == nil { return nil }
		#partial switch n in node.derived {
		case ^ast.Proc_Lit: return nil
		case ^ast.Call_Expr:
			// (#load, #config, #directory...: the compiler runs them, the program does not)
			if _, directive := n.expr.derived.(^ast.Basic_Directive); directive { return nil }
			(^bool)(v.data)^ = true
			return nil
		}
		return v
	}}
	ast.walk(&v, expr)
	return calls
}

lint_test_inits :: proc(log := "") -> bool {
	dirs := TEST_INIT_DIRS
	found := find_test_inits(dirs[:])
	out := strings.builder_make()
	for f in found {
		fmt.sbprintfln(&out, "error: %s(%d): '%s' is %s in a test file, which runs in every program that imports its package: make it inside the tests (a sync.Once if several share it)", f.file, f.line, f.name, f.what)
	}
	fmt.sbprintfln(&out, "code of a test file run at the start of every program: %d", len(found))
	tooling.say(log, strings.to_string(out))
	return len(found) == 0
}
