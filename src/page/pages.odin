package page

import "core:sync"
import "wb:base"
import "wb:canvas2d"
import "wb:host"

// What one App's pages share (docs/architecture.md, Where state lives): the embedder's hooks, the image cache, the script compile
// service, the profile's stores, the message ports, the shared workers, the style threads. Its embedder owns it (browser.App.pages; a
// test program its own) and binds it to the threads that run its pages: the loop's and the page thread's (bind). A worker's thread is
// bound to its creator's (worker_main). What is the process's (the Wasm engine, the decoding threads, the bytecode cache, the order of a
// file's writes) is not here.
Pages :: struct {
	// the embedder's hooks
	embedder:                Embedder_Hooks,
	frame_hooks:             Frame_Hooks,
	fs_embedder:             Fs_Embedder,
	fullscreen_embedder:     Fullscreen_Embedder,
	clipboard_embedder:      Clipboard_Embedder,
	sw_embedder:             Sw_Embedder,
	storage_access_embedder: Storage_Access_Embedder,
	webauthn_embedder:       Webauthn_Embedder,
	notification_embedder:   Notification_Embedder,   // notification.odin: the permission, the system's notifications
	canvas_text_engine:      canvas2d.Text_Engine,   // the embedder's fonts; `user` is replaced by the page when a context is made
	canvas_gpu_host:         ^canvas2d.Gpu_Host,      // the GPU a canvas draws on; nil: every canvas is drawn in software
	dev_console_max:         int,                     // devtools_api.odin: console calls describe their arguments while the developer tools are open

	// what the pages make and the embedder takes
	image_cache:     Image_Cache,      // images.odin (its jobs come back on the loop of the first page that needed it)
	canvas_released: [dynamic]u64,     // canvas.odin: backings that died, whose textures the embedder frees
	compiler:        Compile_Service,  // js_load_compile.odin: its threads post to the loop of the page that asked
	style_pool:      ^host.Thread_Pool,   // offthread.odin: the style threads (made on first use, page.threads.style)
	style_pool_size: int,

	// the profile's stores (locked where workers ask from their threads)
	lock_registry:  Lock_Registry,     // bindings_locks.odin: the Web Locks
	cache_store:    Cache_Store,       // cache_store.odin: the Cache API's index of every origin
	fs_store:       Fs_Store,          // fs_store.odin: file system roots, writables, locks
	sw_registry:    Sw_Registry,       // service_worker.odin: the service worker registrations
	notification_waits: map[u64]^Notification_Wait,   // notification.odin: the notifications shown, by their id
	sa_decisions:   map[string]bool,   // storage_access.odin: owned keys "frame site TAB tab site": granted (true) or refused (false)
	buckets_state:  Buckets_State,     // storage_buckets.odin
	buckets_mu:     sync.Mutex,        // ... pages and workers (threads of their own) ask

	// realms and workers
	router:         Port_Router,              // ports.odin: the message ports of the realms (locked: workers' threads)
	shared_workers: [dynamic]^Shared_Worker,  // shared_worker.odin
	shared_next:    u64,
	shared_scope:   ^base.Scope,              // ... the host pages' parent
	webauthn_ops:   [dynamic]^Webauthn_Op,    // bindings_webauthn.odin: every op whose thread may still run (webauthn_shutdown joins them)
	tl_pending:     map[u64]Pending_Resource, // timeline.odin: the resources the timelines wait for

	// statistics (the profile report, tests)
	forced_layouts:           Forced_Layouts,   // js_dom_layout.odin
	styles_stats:             Styles_Stats,     // styles.odin
	storage_events_delivered: u64,              // storage.odin
	profile_seq:              int,              // js_profile.odin: the profiles written
}

Forced_Layouts :: struct { n: int, ns: i64 }

// The Pages of the pages this thread runs (bind); nil on a thread that runs none.
@(thread_local)
the_pages: ^Pages

// This thread runs the pages of `s` from here on (nil: none). `s` is the caller's, kept until it binds another (rawptr: on purpose).
bind :: proc(s: ^Pages) { the_pages = (^Pages)(rawptr(s)) }
