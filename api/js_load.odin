// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=scripts order=41 exposed=(Window,Worker)
/// Script loading, the event loop and JavaScript workers as the engine needs them (HTML "scripting"): document.write /
/// open / close, the script element's own state, Content-Security-Policy checks of inline code and of eval, ES module
/// graphs (the browser fetches a whole graph, the engine links and runs it), unhandled promise rejections, javascript:
/// URLs, workers whose script is JavaScript and their structured-clone messages. Implemented in src/page/js_load*.odin
/// and js_workers.odin; used by native/js/runtime (load.c, modules.c, handlers.c, load_errors.c, timers.c, workers.c).
package api_js_load

/// What a Content-Security-Policy check of inline code is about: a script element's text, an event handler
/// attribute (script-src-attr), a javascript: URL.
InlineScriptKind :: enum i32 {
	Element,
	Attribute,
	Navigation,
}

/// The type of a module (import attributes: `with {type: "json"}`).
ModuleType :: enum i32 {
	JavaScript,
	Json,
}

/// The type of a worker's script (`new Worker(url, {type})`).
WorkerType :: enum i32 {
	Classic,
	Module,
}

/// document.write(markup) (writeln adds the newline): inserted at the parser's insertion point while the document
/// loads (scripts written run before it returns), else the document is opened again first and replaced. Invalid_State
/// for a document that does not accept it now (a custom element constructor, a parser that would have to be aborted).
//@wb fn raises
Document_writeMarkup :: proc(markup: usvstring)

/// document.open(): the document is emptied and its parser starts again (does nothing while the parser runs a
/// script; the listeners and handlers of its tree and of its Window are erased, the engine's records first through
/// its export wj_document_opening). Invalid_State when the document cannot be opened.
//@wb fn raises
Document_openStream :: proc()

/// document.close(): the parser of a document.open() finishes (DOMContentLoaded, then load).
//@wb fn raises
Document_closeStream :: proc()

/// The "force async" flag of a script element (set when a script creates it: dynamic scripts are async unless
/// their async attribute is set to false).
//@wb fn
HTMLScriptElement_forceAsync :: proc(element: u64) -> bool

/// script.async = value: the attribute is set or removed by the caller, this clears the flag.
//@wb fn
HTMLScriptElement_setForceAsync :: proc(element: u64, value: bool)

/// May this inline code run (Content-Security-Policy: 'unsafe-inline', nonces, hashes)? A refusal is reported as a
/// violation. `element` is the element it comes from (0 for a javascript: URL).
//@wb fn
Script_allowInline :: proc(element: u64, kind: InlineScriptKind, source: usvstring) -> bool

/// May eval() / new Function / setTimeout(string) compile this ('unsafe-eval')? A refusal is reported.
//@wb fn
Script_allowEval :: proc(source: usvstring) -> bool

/// The result of a javascript: URL that was a string: it becomes the document (HTML "navigate to a javascript: URL").
//@wb fn
Script_javascriptResult :: proc(html: usvstring)

/// The URL naming code that has no script of its own in stack traces and as the base of import() (handlers,
/// timer strings): the document's (the worker's script in a worker).
//@wb fn
Script_baseName :: proc() -> string

/// The URL a module specifier stands for, imported from the module (or script) at `base` ("" for the root of a
/// graph, given as a URL already): import maps, then URL parsing. Type: a bare specifier nothing maps, or not a URL.
//@wb fn raises
Module_resolve :: proc(specifier: usvstring, base: usvstring) -> string

/// The source of a module of the page's module map. Not_Found when the browser does not have it.
//@wb fn raises
Module_source :: proc(url: usvstring) -> string

/// The module at `module_url` imports `specifier`: resolved and fetched if new (part of the module's graph).
//@wb fn raises
Module_request :: proc(module_url: usvstring, specifier: usvstring, type: ModuleType)

/// import(specifier) from code at `base`: the browser fetches the graph, then calls the engine's
/// wj_module_import_done(id, ...) from a task of its own. Type: the specifier cannot be resolved.
//@wb fn raises
Module_import :: proc(id: i32, specifier: usvstring, base: usvstring, type: ModuleType)

/// Unhandled promise rejections are waiting: run the engine's wj_notify_rejections in a task of its own.
//@wb fn
Engine_queueRejectionCheck :: proc()

/// new Worker(url, {name, type}) for a JavaScript worker: the Worker object (a handle of module workers). Syntax for
/// an invalid URL, Not_Allowed when the browser refuses (the console says why).
//@wb fn raises
Worker_createScript :: proc(url: usvstring, name: usvstring, type: WorkerType) -> u64

/// worker.postMessage(message): the message as structured serialization bytes (native/js/runtime/clone.c).
//@wb fn raises
Worker_postSerialized :: proc(worker: u64, data: bytes)

/// postMessage(message) in a JavaScript worker.
//@wb fn raises
DedicatedWorkerGlobalScope_postSerialized :: proc(data: bytes)

/// importScripts(url), one URL: fetched synchronously (same rules as the worker's script). The result is the
/// response's URL, a NUL byte, then the script. Network when it cannot be fetched or is not JavaScript; Type in a
/// module worker (importScripts is a classic worker's).
//@wb fn raises
WorkerGlobalScope_importScript :: proc(url: usvstring) -> string

/// Whether the calling worker's script is a module ({type: "module"}).
//@wb fn
WorkerGlobalScope_isModule :: proc() -> bool

/// new SharedWorker(url, {name, type, extendedLifetime}) from a document: the SharedWorker object (it gets `error`
/// events), connected to the shared worker of (the document's storage key, the URL, the name), which starts if none
/// runs. Its port: SharedWorker_portEnd. Syntax for an invalid URL, Security for a URL of another origin,
/// Not_Allowed when the browser refuses (shared workers disabled, too many: the console says why).
//@wb fn raises
SharedWorker_connect :: proc(url: usvstring, name: usvstring, type: WorkerType, extended_lifetime: bool) -> u64

/// new Worker(blobURL) / new SharedWorker(blobURL): the same, with the script the engine read from the Blob the
/// URL stands for (blob: URLs live in the realm that made them, the browser cannot fetch them).
//@wb fn raises
Worker_createScriptBytes :: proc(url: usvstring, name: usvstring, type: WorkerType, script: bytes) -> u64

/// While wj_worker_error_to_global runs: the worker's uncaught error that its Worker object's error event did not
/// cancel, "message TAB filename" (HTML: it is reported in the owner's global, window.onerror).
//@wb fn
Worker_pendingError :: proc() -> string

//@wb fn raises
SharedWorker_connectBytes :: proc(url: usvstring, name: usvstring, type: WorkerType, extended_lifetime: bool, script: bytes) -> u64

/// The port end of the SharedWorker's port, given once (the caller binds it with Port_bind); 0 afterwards.
//@wb fn
SharedWorker_portEnd :: proc(worker: u64) -> u64

/// The end of the port of the next connect event of the calling shared worker (0: none waits).
//@wb fn
SharedWorkerGlobalScope_takeConnection :: proc() -> u64

