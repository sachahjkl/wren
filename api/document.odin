// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=document order=9 exposed=(Window,Worker)
/// The document's address, origin and cookies. Window_origin and Window_isSecureContext belong to
/// WindowOrWorkerGlobalScope: in a worker they describe the worker.
package api_document

/// document.URL. Invalid_Handle in a worker (see WorkerGlobalScope_location).
//@wb fn raises
Document_URL :: proc() -> string

/// self.origin ("null" for an opaque origin).
//@wb fn
Window_origin :: proc() -> string

/// self.isSecureContext
//@wb fn
Window_isSecureContext :: proc() -> bool

/// document.cookie: the cookies scripts may see, "name=value; ...". Security for a document without a tuple origin
/// on http(s), and in a worker.
//@wb fn raises
Document_cookie_get :: proc() -> string

/// document.cookie = cookie. 0 when stored (or deleted), else 1 + the browser's reason (cookies.Store_Result) for
/// refusing it. Security as for the getter.
//@wb fn raises
Document_cookie_set :: proc(cookie: string) -> i32

