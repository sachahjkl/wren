// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=webassembly order=68 exposed=(Window,Worker)
/// The WebAssembly JavaScript API (src/page/webassembly.odin, the objects: native/js/odin/web_wasm.odin): a page's own
/// WebAssembly modules, compiled and run by Wasmtime beside the engine's. Off until it is complete
/// (javascript.webassembly.enabled): a page that finds a `WebAssembly` object expects all of it.
///
/// What a page makes (memories, tables, globals, functions, instances) lives in one store per realm, known by numbers.
/// A call that can fail gives a number >= 0 or the opposite of a failure (1 LinkError, 2 RuntimeError, 3 RangeError,
/// 4 TypeError), the message from WebAssembly_lastError. A value crosses as a cell: an i64 holding an i32, an i64, the
/// bits of a float, a function's number + 1, or an externref's number (0: a null reference).
package api_webassembly

//@wb handle parent=Object host=Wasm_Module lookup=lookup_WebAssemblyModule
WebAssemblyModule :: distinct Handle

/// Whether the page's realm has the `WebAssembly` object (javascript.webassembly.enabled).
//@wb fn
WebAssembly_enabled :: proc() -> bool

/// WebAssembly.validate(bytes): whether `bytes` is a valid module.
//@wb fn
WebAssembly_validate :: proc(module: bytes) -> bool

/// new WebAssembly.Module(bytes): `bytes` compiled. Syntax with the reason when it is not a valid module, Security when
/// the page's Content Security Policy refuses it.
//@wb fn raises
WebAssembly_compile :: proc(module: bytes) -> WebAssemblyModule

/// WebAssembly.compile(bytes): the same on a thread of its own; the promise is rejected with the reason.
//@wb fn
WebAssembly_compileAsync :: proc(module: bytes) -> Promise(WebAssemblyModule)

/// WebAssembly.Module.imports(module), as JSON.
//@wb fn
WebAssembly_Module_imports :: proc(module: WebAssemblyModule) -> string

/// WebAssembly.Module.exports(module), as JSON.
//@wb fn
WebAssembly_Module_exports :: proc(module: WebAssemblyModule) -> string

/// How many custom sections of the module are called `name`.
//@wb fn
WebAssembly_Module_customSectionCount :: proc(module: WebAssemblyModule, name: string) -> i32

/// The bytes of the custom section number `index` of those called `name`.
//@wb fn
WebAssembly_Module_customSection :: proc(module: WebAssemblyModule, name: string, index: i32) -> bytes

/// What the module imports with the types, as JSON: [{module, name, kind, sig, value, mutable}].
//@wb fn
WebAssembly_Module_linkInfo :: proc(module: WebAssemblyModule) -> string

/// The message of the last failure.
//@wb fn
WebAssembly_lastError :: proc() -> string

/// new WebAssembly.Memory: a number. `maximum` -1 for none.
//@wb fn
WebAssembly_Memory_create :: proc(initial: i64, maximum: i64) -> i32

/// The size in pages (-1: no such memory).
//@wb fn
WebAssembly_Memory_pages :: proc(memory: i32) -> i64

/// memory.grow: the previous size in pages.
//@wb fn
WebAssembly_Memory_grow :: proc(memory: i32, delta: i64) -> i64

/// Bytes of the memory at `offset`: how many were copied. What memory.buffer reads.
//@wb fn out=destination
WebAssembly_Memory_read :: proc(memory: i32, offset: i64, destination: bytes) -> i32

/// `source` into the memory at `offset`: how many were copied. What memory.buffer writes.
//@wb fn
WebAssembly_Memory_write :: proc(memory: i32, offset: i64, source: bytes) -> i32

/// new WebAssembly.Table: a number. `element` "r" (funcref) or "e" (externref), `maximum` -1 for none.
//@wb fn
WebAssembly_Table_create :: proc(element: string, initial: i64, maximum: i64, init: i64) -> i32

/// "r", "e", or "" for no such table.
//@wb fn
WebAssembly_Table_element :: proc(table: i32) -> string

//@wb fn
WebAssembly_Table_length :: proc(table: i32) -> i64

/// The cell at `index`, into `cell` (8 bytes): 0, or the opposite of a failure.
//@wb fn out=cell
WebAssembly_Table_get :: proc(table: i32, index: i64, cell: bytes) -> i32

//@wb fn
WebAssembly_Table_set :: proc(table: i32, index: i64, cell: i64) -> i32

/// table.grow: the previous length.
//@wb fn
WebAssembly_Table_grow :: proc(table: i32, delta: i64, init: i64) -> i64

/// new WebAssembly.Global: a number. `type` a value type's letter.
//@wb fn
WebAssembly_Global_create :: proc(type: string, mutable: bool, cell: i64) -> i32

/// The value type's letter, then "m" when it can change; "" for no such global.
//@wb fn
WebAssembly_Global_type :: proc(global: i32) -> string

//@wb fn
WebAssembly_Global_get :: proc(global: i32) -> i64

//@wb fn
WebAssembly_Global_set :: proc(global: i32, cell: i64) -> i32

/// A function of signature `sig` that runs import `slot` of the realm (wj_wasm_import).
//@wb fn
WebAssembly_Func_import :: proc(slot: i32, sig: string) -> i32

/// The signature of a function, "params:results" (see src/wasm/user_store.odin); "" for no such function.
//@wb fn
WebAssembly_Func_sig :: proc(func: i32) -> string

/// Calls a function: `args` its cells (8 bytes each). 0, or the opposite of a failure.
//@wb fn
WebAssembly_Func_call :: proc(func: i32, args: bytes) -> i32

/// The results of the call that just ended, as cells (apart: the call may have moved the engine's memory).
//@wb fn
WebAssembly_Func_results :: proc() -> bytes

/// The arguments of the import running, as cells.
//@wb fn
WebAssembly_import_args :: proc() -> bytes

/// The results of the import running, as cells.
//@wb fn
WebAssembly_import_results :: proc(results: bytes)

/// Why the import running failed.
//@wb fn
WebAssembly_import_failed :: proc(message: string)

/// new WebAssembly.Instance: a number. `externs` the number of a thing for each import (4 bytes each); the start function
/// runs here.
//@wb fn
WebAssembly_Instance_create :: proc(module: WebAssemblyModule, externs: bytes) -> i32

/// The exports of an instance, as JSON: [{name, kind, id, index}].
//@wb fn
WebAssembly_Instance_exports :: proc(instance: i32, module: WebAssemblyModule) -> string

