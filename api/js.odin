// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=js order=24 exposed=(Window,Worker)
/// What the JavaScript engine (native/js, a C guest) needs from the browser beyond the web API itself: the console with
/// its levels, uncaught exceptions with their position, compiled code handed back for the bytecode cache, the local time
/// zone, and the bookkeeping of the wrappers that keep DOM nodes alive (a node referenced by a JavaScript object is
/// "pinned": it is not freed when it leaves the tree, and a detached tree is freed once nothing pins it any more).
package api_js

/// The level of a console message.
ConsoleLevel :: enum i32 {
	Log,
	Info,
	Warn,
	Error,
	Debug,
}

/// console.log / info / warn / error / debug..., the arguments already formatted.
//@wb fn
Engine_console :: proc(level: ConsoleLevel, text: usvstring)

/// An exception nothing caught (after the error event, when no handler cancelled it): message, stack, and where it
/// was thrown (source URL, 1-based line and column; 0 when unknown).
//@wb fn
Engine_reportException :: proc(message: usvstring, stack: usvstring, source: usvstring, line: i32, column: i32)

/// The bytecode of the script being run (asked for with a flag of wj_eval_script): the browser keeps it in its
/// bytecode cache under the key it computed for that script.
//@wb fn
Engine_storeBytecode :: proc(code: bytes)

/// Minutes to add to local time to get UTC at `time_ms` (ms since the Unix epoch), as Date.prototype.getTimezoneOffset.
//@wb fn
Engine_timezoneOffset :: proc(time_ms: f64) -> i32

/// The IANA name of the local time zone ("Europe/Paris"; "UTC" when unknown), for Intl.
//@wb fn
Engine_timeZone :: proc() -> string

/// The language of the user interface ("en-US"), for Intl.
//@wb fn
Engine_locale :: proc() -> string

/// Machine code for a hot function (the engine's JIT, native/js/jit): `module` is a WebAssembly module whose imports
/// are the engine's own exports (module "e") and that exports one function "f". The browser compiles it, instantiates
/// it next to the engine (same store, same memory) and puts "f" in the engine's function table: the result is that
/// table index, 0 when it refused (javascript.jit.* limits, invalid module, not the realm's engine), or minus a
/// ticket when it compiles it in the background: Engine_jitPoll then tells when it is ready.
//@wb fn
Engine_jitCompile :: proc(module: bytes) -> i32

/// The table index of the function of an Engine_jitCompile ticket once compiled and attached; -1 while it still
/// compiles; 0 when it failed (the ticket is then forgotten).
//@wb fn
Engine_jitPoll :: proc(ticket: i32) -> i32

/// A JavaScript object (its wrapper) now refers to `node`: pins it (it stays alive while pinned, even out of the tree)
/// and returns the wrapper's interface, an index into the engine's interface table (gen/bindings.c) chosen from the
/// node's type, namespace and local name (HTMLDivElement, SVGSVGElement, Text...). One call per new wrapper.
//@wb fn
Node_wrap :: proc(node: Node) -> u32

/// That object is gone (called while the engine collects garbage: a handle that died meanwhile is ignored). A
/// detached tree no longer pinned anywhere is freed.
//@wb fn
Node_unpin :: proc(node: u64)

/// For each node, the root of its tree as a u64 in `roots` (8 bytes per node): 1 for a node of the document's own
/// tree, else the handle of its topmost ancestor (itself when it has none), 0 for a dead handle. The engine keeps the
/// wrappers of one tree alive together.
//@wb fn out=roots
Node_treeRoots :: proc(nodes: []u64, roots: bytes)

