// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=43 partial
/// Printing. Wren has no printing: window.print() tells the browser (which says so, discreetly) and returns at once;
/// it never throws (HTML's printing steps simply end when the user agent cannot print).
package api_js_print

/// window.print().
//@wb fn
Window_print :: proc()

