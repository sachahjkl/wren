package fetch

// What a script request (destination Script or Worker) fetches: the browser's own WebAssembly modules (the default:
// application/wasm only), or JavaScript, whose MIME rules are HTML's and the Fetch Standard's:
//   * a classic script (and a classic worker's script) may have any type but audio/*, image/*, video/* and text/csv
//     ("should response to request be blocked due to its MIME type"), and must be JavaScript with nosniff;
//   * a module script must be a JavaScript MIME type (or JSON for a JSON module).
// `parser_inserted` is the request's parser metadata (CSP 'strict-dynamic' trusts scripts that scripts inserted).
Script_Type :: enum u8 { Wasm, Classic, Module, Json_Module }

@(private)
JS_MIME_ESSENCES := [?]string{
	"application/ecmascript", "application/javascript", "application/x-ecmascript", "application/x-javascript",
	"text/ecmascript", "text/javascript", "text/javascript1.0", "text/javascript1.1", "text/javascript1.2",
	"text/javascript1.3", "text/javascript1.4", "text/javascript1.5", "text/jscript", "text/livescript",
	"text/x-ecmascript", "text/x-javascript",
}

// MIME Sniffing "JavaScript MIME type" (on the essence: type/subtype in lower case).
is_javascript_mime :: proc(type, subtype: string) -> bool {
	for e in JS_MIME_ESSENCES {
		slash := 0
		for c, i in e { if c == '/' { slash = i; break } }
		if e[:slash] == type && e[slash + 1:] == subtype { return true }
	}
	return false
}

// The MIME check of a JavaScript script response (`has` false: no Content-Type).
@(private)
check_script_mime :: proc(st: Script_Type, type, subtype: string, has, nosniff: bool) -> (why: string, ok: bool) {
	js := has && is_javascript_mime(type, subtype)
	json := has && (subtype == "json" || (len(subtype) > 5 && subtype[len(subtype) - 5:] == "+json")) && (type == "application" || type == "text")
	switch st {
	case .Wasm:
	case .Classic:
		if nosniff && !js { return "script blocked: nosniff and not a JavaScript MIME type", false }
		if has && (type == "audio" || type == "image" || type == "video" || (type == "text" && subtype == "csv")) {
			return "script blocked: its MIME type is not executable", false
		}
	case .Module:
		if !js { return "a module script must be served with a JavaScript MIME type", false }
	case .Json_Module:
		if !json { return "a JSON module must be served with a JSON MIME type", false }
	}
	return "", true
}
