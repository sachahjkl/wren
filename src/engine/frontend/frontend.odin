package frontend

// frontend: the ECMAScript front-end of the Odin JavaScript engine. It turns JavaScript source into QuickJS-ng
// 0.17 bytecode, byte-for-byte identical to what JS_WriteObject writes (BC_VERSION 28). It is the E1 half of the
// engine; the E2 half (values, objects, GC, interpreter, built-ins) reads that bytecode. The two halves meet only
// at the bytecode format (opcodes.odin, atoms.odin, serialize.odin).
//
// Structure: QuickJS compiles in a single pass, emitting while it parses, and its bytes depend on that order
// (last-opcode rewrites, variable and scope creation order, label numbering). So this package follows quickjs.c's
// compiler rather than an AST pipeline:
//
//   source bytes
//     -> js_lex.odin            tokens (next_token), strings, templates, numbers, regexp literals
//     -> js_expr*.odin, js_stmt.odin, js_func.odin, js_module.odin
//                               parse and emit phase-1 bytecode (js_emit.odin: opcodes, labels, scopes, vars)
//     -> js_resolve.odin        resolve_variables: scope opcodes to local/arg/closure/global accesses
//     -> js_passes.odin         resolve_labels (jumps, short opcodes, peephole), compute_stack_size,
//                               js_create_function: the Function_Bytecode
//     -> serialize.odin         the JS_WriteObject byte stream
//
// Regexp literals are compiled to libregexp bytecode by js_regexp.odin (QuickJS keeps it in the constant pool).
// Every allocation goes through the injected allocator, recursion is bounded by a stack budget (Stack_Guard),
// and the package builds for freestanding_wasm32 with no OS and no libc. Entry points: compile.odin.
