package page

import "base:runtime"
import "core:testing"
import "wb:wasm"

// Every import the browser registers has a host-call thunk for its signature (src/wasm/thunks_generated.odin, written
// by src/tools/wasmthunks): otherwise wasm.register refuses it and the engine would not start.
@(test)
every_import_signature_has_a_thunk :: proc(t: ^testing.T) {
	context.allocator = runtime.default_allocator()   // the forms table lives as long as the process
	tables := [][]wasm.Native_Symbol{
		dom_symbols[:], events_symbols[:], timers_symbols[:], net_symbols[:], document_symbols[:], console_symbols[:],
		async_symbols[:], eventsource_symbols[:], websocket_symbols[:], abort_symbols[:], fetch_symbols[:],
		encoding_symbols[:], crypto_symbols[:], storage_symbols[:], url_symbols[:], performance_symbols[:],
		history_symbols[:], build_forms_symbols(), workers_symbols[:], images_symbols[:],
	}
	n := 0
	for table in tables {
		for s in table {
			testing.expectf(t, wasm.signature_supported(string(s.signature)), "%s %s has no thunk: run src/tools/wasmthunks", s.symbol, s.signature)
			n += 1
		}
	}
	testing.expect(t, n > 200, "every table is listed")
}
