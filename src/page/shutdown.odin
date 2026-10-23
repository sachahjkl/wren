package page

import lay "wb:layout"
import "wb:wasm"

// Frees what the page stack keeps for the whole process, once every page is closed: the style and layout threads, the
// image cache and its decoders, the decoded web fonts, the passkey ceremonies, the script compile threads and the
// bytecode cache, the Wasm engine and its host functions. A program that embeds pages without the browser's shell (the
// end-to-end tools) calls it after closing its pages and before destroying its loader and loop; the browser's exit
// (browser/main.odin) runs the same steps in its own order. Everything starts again on demand afterwards.
process_shutdown :: proc() {
	webauthn_shutdown()
	timeline_shutdown()
	shutdown_threads()
	lay.shutdown_threads()
	images_shutdown()
	fonts_shutdown()
	clipboard_shutdown()
	js_shutdown()
	frames_shutdown()
	wasm.runtime_destroy()
}
