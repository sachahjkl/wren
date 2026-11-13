package licensetool

// wrentool license: the toolkit's licence commands (toolbox.licence_commands) for Wren's product (src/license). Offline but
// for `paddle -apply`. See docs/licence.md.
//
//   license licence keygen [-private:FILE] [-force]
//   license licence pubkey [-private:FILE | -dev]
//   license licence issue -name:N -email:E -edition:supporter|patron -order:ID [-date:YYYY-MM-DD] [-private:FILE | -dev] [-out:FILE]
//   license licence verify FILE | -text:KEY [-public:KEY | -dev]
//   license licence secrets <secrets.yaml> <out.env> [-keys:A,B]
//   license paddle [-apply] ...

import "core:os"
import "core:path/filepath"
import "wb:license"
import toolbox "../../../ext/gui_toolkit/src/toolbox"

main :: proc() {
	tool := toolbox.Licence_Tool{
		product  = license.WREN,
		// (the maintainer's key stays where Wren's own tool made it: outside every repository)
		key_dir  = key_dir(),
		dev_seed = license.DEV_SEED,
		hint     = "Open this file with Wren, or paste the key in about:wren.",
		paddle   = {name = "Wren Supporter Licence", description = "A personal, perpetual licence that supports Wren's development.", currency = "EUR"},
	}
	l := toolbox.licence_commands(tool)
	toolbox.tool_main("license", {l[0], l[1]})
}

// %USERPROFILE%\.wren-license, ~/.wren-license elsewhere ("": the toolkit's folder in the user's configuration).
key_dir :: proc() -> string {
	home := os.get_env(ODIN_OS == .Windows ? "USERPROFILE" : "HOME", context.temp_allocator)
	if home == "" { return "" }
	dir, _ := filepath.join({home, ".wren-license"}, context.temp_allocator)
	return dir
}
