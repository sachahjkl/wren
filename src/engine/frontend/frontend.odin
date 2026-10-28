package frontend

// frontend: a complete ECMAScript front-end written in Odin. It turns JavaScript source into QuickJS-ng 0.17
// bytecode, byte-for-byte compatible with what qjs/qjsc produce via JS_WriteObject. It is the E1 half of the
// Odin JavaScript engine; the E2 half (runtime: values, objects, GC, interpreter, built-ins) reads the bytecode
// this package emits. The two halves meet only at the bytecode format (opcodes.odin, atoms.odin, serialize.odin).
//
// Design, in the spirit of the brief ("profit from the language, do better than a mechanical copy"):
//
//   * The AST is a tagged union (Odin `union`) of node structs allocated on an arena. A whole parse frees in one
//     shot; there is no per-node free and no reference counting. (ast.odin)
//   * Every allocation goes through an injected allocator, and the package builds for freestanding_wasm32 with no
//     OS and no libc: it reuses the leaf packages numconv (number/bigint literals), unicode/ucd (identifier and
//     whitespace classification, case folding) and regexp (validating regexp literals).
//   * Diagnostics carry a line/column and a message in QuickJS's wording, so the parse judge can compare our
//     SyntaxError verdicts against QuickJS's.
//   * The opcode set, the atom numbering and the serialization are faithful to QuickJS so a differential judge
//     over a large corpus can measure exactly how much of our output matches, function by function.
//
// Pipeline (compile.odin ties it together):
//
//   source bytes
//     -> Lexer           (lexer.odin)        tokens, with positions and cooked literal values
//     -> Parser          (parser*.odin)      AST + early-error detection
//     -> Resolver        (resolve.odin)      scopes, variable kinds, closures, TDZ, this/arguments/new.target
//     -> Emitter phase 1 (emit*.odin)        temporary + real opcodes, labels, scope markers
//     -> resolve_labels  (passes.odin)       lower scope ops, drop labels, choose short opcodes, peephole
//     -> compute_stack_size (passes.odin)    stack_size for the function header
//     -> Function_Bytecode                   the QuickJS JSFunctionBytecode, ready to serialize
//     -> serialize       (serialize.odin)    the JS_WriteObject byte stream
//
// Public entry points live in compile.odin: parse_script, parse_module, compile_script, compile_module,
// write_object.
