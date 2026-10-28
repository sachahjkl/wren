// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=forms order=51 partial
/// FormData file entries for JavaScript.
package api_js_web__forms

/// The bytes of the index-th entry, a file (a file chosen in an <input type=file> is read now). Not_Found when there
/// is no such entry or it is not a file.
//@wb fn raises
FormData_fileAt :: proc(data: FormData, index: i32) -> Buffer

/// set(name, blob, filename): like FormData_set with a file entry.
//@wb fn raises
FormData_setBlob :: proc(data: FormData, name: usvstring, blob: Buffer, filename: usvstring = "", mime: string = "")

/// The entries as a multipart/form-data body with this boundary (files chosen in an <input type=file> are read now).
//@wb fn raises
FormData_encode :: proc(data: FormData, boundary: string) -> Buffer

