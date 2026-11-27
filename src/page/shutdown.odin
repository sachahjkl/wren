package page

import "core:log"
import "core:time"
import "wb:images"
import lay "wb:layout"
import "wb:media"
import "wb:wasm"

// How long the end of the process waits for the media players' threads to end. Short: a system decoder that hangs must
// not hold the exit (the shutdown watchdog is longer), and a player it keeps is only memory the process gives back.
PLAYERS_SETTLE_BOUND :: 2 * time.Second

// Frees what one embedder's pages share (the_pages: this thread's), once every page of it is closed: the passkey ceremonies, the timelines'
// requests, the style threads, the image cache, the script compile threads, the navigables, the shared workers and ports, the Cache API's
// and the file system's stores. A program that embeds pages without the browser's shell (the end-to-end tools) calls it after closing its
// pages and before destroying its loader and loop; the browser's end (browser/main.odin) runs the same steps in its own order.
pages_shutdown :: proc() {
	webauthn_shutdown()
	notifications_shutdown()
	timeline_shutdown()
	shutdown_threads()
	images_shutdown()
	compile_shutdown()   // (before js_shutdown: the compile threads store into the bytecode cache)
	frames_shutdown()
	cache_store_shutdown()   // cache_store.odin
	fs_store_shutdown()   // fs_store.odin
}

// Frees what the page stack keeps for the whole process, once no embedder has a page left (pages_shutdown, each): the layout threads, the
// image decoders, the decoded web fonts, the headless clipboard, the bytecode cache, the Wasm engine and its host functions. Everything
// starts again on demand afterwards. First the media players that closed pages left: their threads end on their own
// (src/md/infrastructure/media-player-lifetime.md), and what is counted after this must not see them.
process_shutdown :: proc() {
	if !media.players_settle(PLAYERS_SETTLE_BOUND) { log.warnf("media: a player's thread did not end within %v (a decoder that does not return): the process ends without it", PLAYERS_SETTLE_BOUND) }
	lay.shutdown_threads()
	images.decoder_stop()
	fonts_shutdown()
	clipboard_shutdown()
	js_shutdown()
	wasm.runtime_destroy()
}
