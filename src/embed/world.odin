package embed

// Headless browser runtime stack (Layer 7: zero UI, window, or renderer dependencies).
// Owns loop, network client, blocking pool, Fetch profile/cache, loader, Web Storage,
// page settings, shared page state, and root process scope in one canonical init order
// and exact reverse teardown order.

import "core:mem"
import config "toolkit:config"
import "wb:base"
import "wb:cookies"
import "wb:fetch"
import "wb:host"
import "wb:httpcache"
import "wb:js"
import js_code "wb:js/image/code"
import "wb:net"
import "wb:page"
import "wb:wasm"

DEFAULT_BLOCKING_THREADS :: 2

// Initialization stages of a World. `world_destroy` tears down active stages in reverse order.
Stage :: enum u8 {
	Pages_Bound,
	Loop,
	Client,
	Blocking,
	Profile,
	Http_Cache,
	Loader,
	Settings,
	Storage,
	Runtime,
	Process_Scope,
}

Stages :: bit_set[Stage; u16]

// Configuration for `world_init` and `world_make`.
// The zero value builds a complete headless page world with defaults and no disk state.
Options :: struct {
	prefs:             ^config.Prefs,     // nil uses package defaults; register with `embed.register_prefs`
	wake:              proc(user: rawptr), // optional loop wakeup hook (windowed embedders)
	wake_user:         rawptr,
	blocking_threads:  int,               // <= 0 uses DEFAULT_BLOCKING_THREADS
	network_only:      bool,              // true skips pages, settings, storage, and Wasm/JS runtime
	http_cache:        bool,              // true enables Fetch HTTP cache (in memory unless http_cache_dir is set)
	http_cache_dir:    string,            // non-empty enables disk-backed HTTP cache in this folder
	storage_dir:       string,            // non-empty initializes page.Storage_Manager in this folder
	storage_in_memory: bool,              // true initializes an in-memory Storage_Manager when storage_dir is ""
	storage_writer:    ^host.File_Writer, // optional shared profile file writer
	wasm_args:         []string,          // when non-nil, calls wasm.configure_from_args(wasm_args, wasm_cache_dir)
	wasm_cache_dir:    string,
	configure_wasm:    bool,              // true configures wasm from prefs or defaults even when wasm_args is nil
	shipped_js:        bool,              // true registers the precompiled JS engine code (wasm.shipped_set)
	js_cache_bytes:    i64,               // > 0 starts in-memory JS bytecode cache with this byte budget
	scope_name:        string,            // root scope name ("" defaults to "process")
	process_share:     ^Process_Share,    // optional multi-world refcount gate; nil means this World owns shutdown
	process_hooks:     Process_Hooks,     // optional extra hooks when process_share is set
}

// Headless browser runtime stack. Must stay pinned at one address while initialized because
// client, blocking pool, loader, storage, and `page.bind` keep pointers into its fields.
World :: struct {
	loop:          host.Loop,
	client:        net.Client,
	blocking:      host.Blocking_Pool,
	profile:       fetch.Profile,
	loader:        fetch.Loader,
	storage:       page.Storage_Manager,
	settings:      page.Settings,
	pages:         page.Pages,
	process:       ^base.Scope,
	made:          Stages,
	process_share: ^Process_Share,
	process_hooks: Process_Hooks,
	allocator:     mem.Allocator,
}

// Registers all preferences read by `world_init`: network, Fetch, HTTP cache, cookies, and page.
register_prefs :: proc(p: ^config.Prefs) {
	net.register_prefs(p)
	fetch.register_prefs(p)
	httpcache.register_prefs(p)
	cookies.register_prefs(p)
	page.register_prefs(p)
}

// Allocates and initializes a heap-pinned World. Returns nil on failure. Free with `world_free`.
world_make :: proc(opts: Options = {}, allocator := context.allocator) -> ^World {
	w := new(World, allocator)
	if !world_init(w, opts) {
		free(w, allocator)
		return nil
	}
	w.allocator = allocator
	return w
}

// Tears down and frees a World allocated by `world_make`.
world_free :: proc(w: ^World) {
	if w == nil { return }
	alloc := w.allocator
	world_destroy(w)
	free(w, alloc)
}

// Initializes a caller-owned World in place. On failure, rolls back every partial stage and returns false.
world_init :: proc(w: ^World, opts: Options = {}) -> bool {
	w^ = {}

	if !opts.network_only {
		page.bind(&w.pages)
		w.made += {.Pages_Bound}
	}

	host.loop_init(&w.loop, opts.wake, opts.wake_user)
	w.made += {.Loop}

	if opts.prefs != nil {
		ns := net.settings_from_prefs(opts.prefs)
		ok := net.client_init(&w.client, &w.loop, ns)
		net.settings_destroy(&ns)
		if !ok { world_destroy(w); return false }
	} else {
		if !net.client_init(&w.client, &w.loop) { world_destroy(w); return false }
	}
	w.made += {.Client}

	threads := opts.blocking_threads > 0 ? opts.blocking_threads : DEFAULT_BLOCKING_THREADS
	host.blocking_init(&w.blocking, &w.loop, threads)
	w.made += {.Blocking}

	if opts.prefs != nil {
		w.profile = fetch.profile_make(fetch.settings_from_prefs(opts.prefs), cookies.settings_from_prefs(opts.prefs))
	} else {
		w.profile = fetch.profile_make()
	}
	w.made += {.Profile}

	if opts.http_cache || opts.http_cache_dir != "" {
		cs := opts.prefs != nil ? httpcache.settings_from_prefs(opts.prefs) : httpcache.settings_default()
		defer httpcache.settings_destroy(&cs)
		w.profile.cache = httpcache.create(&w.loop, cs, opts.http_cache_dir)
		if w.profile.cache != nil { w.made += {.Http_Cache} }
	}

	fetch.loader_init(&w.loader, &w.loop, &w.client, &w.blocking, &w.profile)
	w.made += {.Loader}

	scope_name := opts.scope_name != "" ? opts.scope_name : "process"
	w.process = base.scope_make(scope_name)
	w.made += {.Process_Scope}

	if !opts.network_only {
		if !world_enable_pages(w, opts) { world_destroy(w); return false }
		if opts.storage_dir != "" || opts.storage_in_memory {
			world_enable_storage(w, opts.storage_dir, opts.storage_writer)
		}
	}
	return true
}

// Upgrades a `network_only` World in place to run pages and scripts (idempotent per stage).
world_enable_pages :: proc(w: ^World, opts: Options = {}) -> bool {
	if .Pages_Bound not_in w.made {
		page.bind(&w.pages)
		w.made += {.Pages_Bound}
	}
	if .Settings not_in w.made {
		w.settings = opts.prefs != nil ? page.settings_from_prefs(opts.prefs) : page.settings_default()
		w.made += {.Settings}
	}
	if .Runtime not_in w.made {
		w.process_share = opts.process_share
		w.process_hooks = opts.process_hooks
		if w.process_share != nil {
			ctx := Runtime_Join_Ctx{w = w, opts = opts}
			if !process_share_join(w.process_share, {on_begin = runtime_join_begin, on_end = runtime_join_end, user = &ctx}) {
				w.process_share = nil
				w.process_hooks = {}
				return false
			}
		} else {
			if !runtime_setup(opts) { return false }
		}
		w.made += {.Runtime}
	}
	return true
}

// Initializes Web Storage on demand (idempotent if already initialized).
world_enable_storage :: proc(w: ^World, dir: string, writer: ^host.File_Writer = nil) {
	if .Storage in w.made { return }
	page.storage_manager_init(&w.storage, &w.loop, &w.blocking, dir, writer)
	w.made += {.Storage}
}

// Binds the current thread to this World's shared `page.Pages`.
world_bind :: proc(w: ^World) {
	page.bind(&w.pages)
	w.made += {.Pages_Bound}
}

world_has_storage :: proc(w: ^World) -> bool { return .Storage in w.made }

world_storage :: proc(w: ^World) -> ^page.Storage_Manager {
	return .Storage in w.made ? &w.storage : nil
}

// Replaces `w.settings` with fresh defaults (or values from `prefs`), freeing any previous copy.
world_reset_settings :: proc(w: ^World, prefs: ^config.Prefs = nil) {
	if .Settings in w.made {
		page.settings_destroy(&w.settings)
		w.settings = {}
	}
	w.settings = prefs != nil ? page.settings_from_prefs(prefs) : page.settings_default()
	w.made += {.Settings}
}

// Destroys `w.settings` without tearing down the rest of the World (per-test cleanup).
world_clear_settings :: proc(w: ^World) {
	if .Settings not_in w.made { return }
	page.settings_destroy(&w.settings)
	w.settings = {}
	w.made -= {.Settings}
}

// Tears down every initialized stage of `w` in exact reverse dependency order.
world_destroy :: proc(w: ^World) {
	if w == nil { return }

	if .Pages_Bound in w.made {
		page.bind(&w.pages)
	}
	if .Process_Scope in w.made {
		base.scope_close(w.process)
		w.process = nil
		w.made -= {.Process_Scope}
	}
	if .Blocking in w.made {
		host.blocking_settle(&w.blocking)
	}
	if .Storage in w.made {
		page.storage_manager_destroy(&w.storage)
		if .Blocking in w.made { host.blocking_settle(&w.blocking) }
		w.made -= {.Storage}
	}
	if .Loop in w.made {
		host.loop_drain(&w.loop)
	}
	if .Pages_Bound in w.made {
		page.pages_shutdown()
	}
	if .Runtime in w.made {
		if w.process_share != nil {
			process_share_leave(w.process_share, {on_end = runtime_leave_end, user = w})
		} else {
			page.process_shutdown()
		}
		w.made -= {.Runtime}
	}
	if .Loader in w.made {
		fetch.loader_destroy(&w.loader)
		w.made -= {.Loader}
	}
	if .Http_Cache in w.made {
		if w.profile.cache != nil {
			httpcache.destroy(w.profile.cache)
			w.profile.cache = nil
		}
		w.made -= {.Http_Cache}
	}
	if .Blocking in w.made {
		host.blocking_destroy(&w.blocking)
		w.made -= {.Blocking}
	}
	if .Client in w.made {
		net.client_destroy(&w.client)
		w.made -= {.Client}
	}
	if .Profile in w.made {
		fetch.profile_destroy(&w.profile)
		w.made -= {.Profile}
	}
	if .Loop in w.made {
		if .Pages_Bound in w.made { page.discard_page_tasks(&w.loop) }
		host.loop_destroy(&w.loop)
		w.made -= {.Loop}
	}
	if .Settings in w.made {
		page.settings_destroy(&w.settings)
		w.settings = {}
		w.made -= {.Settings}
	}
	if .Pages_Bound in w.made {
		if page.the_pages == &w.pages { page.bind(nil) }
		w.made -= {.Pages_Bound}
	}
	w.process_share = nil
	w.process_hooks = {}
}

@(private = "file")
Runtime_Join_Ctx :: struct {
	w:    ^World,
	opts: Options,
}

@(private = "file")
runtime_join_begin :: proc(user: rawptr) -> bool {
	ctx := (^Runtime_Join_Ctx)(user)
	hooks := ctx.w.process_hooks
	if hooks.on_begin != nil && !hooks.on_begin(hooks.user) { return false }
	if !runtime_setup(ctx.opts) {
		if hooks.on_end != nil { hooks.on_end(hooks.user) }
		return false
	}
	return true
}

@(private = "file")
runtime_join_end :: proc(user: rawptr) {
	ctx := (^Runtime_Join_Ctx)(user)
	runtime_leave_end(ctx.w)
}

@(private = "file")
runtime_leave_end :: proc(user: rawptr) {
	w := (^World)(user)
	page.process_shutdown()
	if w.process_hooks.on_end != nil { w.process_hooks.on_end(w.process_hooks.user) }
}

@(private = "file")
runtime_setup :: proc(opts: Options) -> bool {
	if opts.shipped_js { wasm.shipped_set(js_code.CODE) }
	switch {
	case opts.wasm_args != nil:
		wasm.configure_from_args(opts.wasm_args, opts.wasm_cache_dir)
	case opts.configure_wasm && opts.prefs != nil:
		rs := wasm.runtime_settings_from_prefs(opts.prefs, opts.wasm_cache_dir)
		wasm.configure(rs)
		wasm.runtime_settings_destroy(&rs)
	case opts.configure_wasm:
		wasm.configure_from_args(nil, opts.wasm_cache_dir)
	}
	if !page.register_imports() {
		wasm.runtime_destroy()
		return false
	}
	if opts.js_cache_bytes > 0 {
		js.cache_start({memory_bytes = opts.js_cache_bytes, min_source_bytes = 0})
	}
	return true
}
