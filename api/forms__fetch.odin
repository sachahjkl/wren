// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=fetch order=16 partial
package api_forms__fetch

/// fetch with a FormData body: the Content-Type (with its boundary) is set unless `headers` name one. Same callback
/// and options as Fetch_start.
//@wb fn
Fetch_startFormData :: proc(url: string, data: FormData, callback: FetchCallback, user: i32 = 0, method: string = "POST", headers: string = "", enctype: FormEnctype = .Multipart, options: FetchOptions = none) -> Fetch

