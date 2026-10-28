// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=console order=6 exposed=(Window,Worker)
/// The console of the page (or of the worker): messages appear in the browser's console. Invalid UTF-8 is shown as
/// U+FFFD.
package api_console

/// console.log(message)
//@wb fn
console_log :: proc(message: usvstring)

/// console.warn(message)
//@wb fn
console_warn :: proc(message: usvstring)

/// console.error(message)
//@wb fn
console_error :: proc(message: usvstring)

