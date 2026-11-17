package jscapi_check

// The check of Wren's QuickJS C API (src/jscapi) on the native engine. It is Wren's tool, not the engine's judge:
// jscapi is Wren's glue layer, and its 32-bit JSValue heap below 4 GiB is a jscapi concern.
//
//   jscapi_check    run the checks of capi_test.odin; exit code 0 if all pass, 1 if one fails, 2 if no low heap

import "core:os"

main :: proc() {
	os.exit(capi_main())
}
