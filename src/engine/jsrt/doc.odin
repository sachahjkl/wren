package jsrt

// The ECMAScript runtime for Wren's JavaScript engine, written natively in Odin.
//
// This package is the "second half" of the Odin JavaScript engine (E2 = the runtime). It consumes
// the QuickJS-ng 0.17 bytecode produced either by the Odin compiler front-end (E1) or by the
// reference QuickJS C compiler through JS_WriteObject, and executes it. It is designed to build for
// windows_amd64, linux_amd64 and freestanding_wasm32 with an injected allocator and no OS
// dependency, so the same code runs inside Wren's Wasm sandbox and in native test harnesses.
//
// See docs/engine/runtime.md for the value model, object shapes, memory management, the interpreter
// and the embedding interface.
