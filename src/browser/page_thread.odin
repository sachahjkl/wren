package browser

// The page thread: a long layout pass runs there while the interface thread keeps drawing the chrome.
//
// page_prepare (page_frame.odin) hands the layout of the current tab to this thread when it is expected to be long
// (its last pass took browser.shell.page_thread_min_ms or more, or none is known yet), then waits for it and makes
// chrome frames meanwhile (shell_frames.odin), at the frame rate. While the pass runs, the layout, the document, the
// styles and the page's fonts belong to the page thread: the chrome frames draw the page's last frame (the snapshot)
// and read nothing of its layout (chrome_frames.page_locked). What the pass reads besides (measuring text: the font
// state and the measure cache are made for several threads; natural sizes of images: only read, nothing decodes into
// the cache meanwhile since no loop task runs) is safe to share. Only one pass at a time; the thread has the window
// thread's stack (deep documents recurse).

import "base:runtime"
import "core:sync"
import "core:time"
import "toolkit:draw"
import "wb:config"
import "wb:host"
import "wb:style"

PAGE_THREAD_PREFS := [?]config.Def{
	{name = "browser.shell.page_thread", kind = .Bool, default = {b = true},
		description = "Run long layout passes of a page on a thread of their own, so the browser draws its interface meanwhile (tabs, address bar, menus, scrolling, resizing). Off: on the interface thread, which waits for them."},
	{name = "browser.shell.page_thread_min_ms", kind = .Float, default = {f = 3}, bounded = true, min = 0, max = 1000, unit = "ms",
		description = "A page's layout goes to the page thread (browser.shell.page_thread) when its last pass took at least this long (or none was measured yet). Shorter passes stay on the interface thread: handing them over costs more than it saves."},
	{name = "browser.shell.page_thread_stack_mb", kind = .Int, default = {i = 32}, bounded = true, min = 1, max = 1024, unit = "MB", restart = true,
		description = "Stack of the page thread: a deeply nested document recurses that deep in layout."},
}

register_page_thread_prefs :: proc(p: ^config.Prefs) { config.register(p, PAGE_THREAD_PREFS[:]) }

@(private = "file")
Layout_Job :: struct {
	l:        ^Layout,
	t:        ^Tab,
	styled:   ^style.Styled,
	size:     draw.Vec2,
	scale:    f32,
	fonts_gen: u64,
}

@(private = "file")
Page_Thread :: struct {
	thread:   ^host.Thread,
	go, done: sync.Sema,
	job:      Layout_Job,
	stop:     bool,
	last_ms:  map[u64]f64,   // per tab id: its last layout pass
	passes:   u64,           // passes run on the thread (statistics)
}

@(private = "file")
pt: Page_Thread

// The layout of `t` for this frame, on the page thread when it is expected to be long (see above), else here.
page_layout :: proc(app: ^App, t: ^Tab, styled: ^style.Styled, size: draw.Vec2, scale: f32, fonts_gen: u64) {
	t0 := time.tick_now()
	defer pt.last_ms[t.id] = time.duration_milliseconds(time.tick_since(t0))
	job := Layout_Job{&t.layout, t, styled, size, scale, fonts_gen}
	last, known := pt.last_ms[t.id]
	if !page_thread_wanted(app) || (known && last < config.float_of(&app.prefs, "browser.shell.page_thread_min_ms")) {
		layout_job_run(&job)
		return
	}
	if pt.thread == nil {
		stack := int(config.int_of(&app.prefs, "browser.shell.page_thread_stack_mb")) << 20
		context = runtime.default_context()
		pt.thread = host.thread_start(page_thread_main, &pt, stack)
		if pt.thread == nil { layout_job_run(&job); return }
	}
	pt.job = job
	chrome_frames.page_locked = true
	defer chrome_frames.page_locked = false
	sync.sema_post(&pt.go)
	pt.passes += 1
	// chrome frames while it runs, at the frame rate (shell_preempt decides when one is due)
	for !sync.sema_wait_with_timeout(&pt.done, time.Millisecond) { shell_preempt(app) }
}

// Debug builds: who may touch the current page's world (its layout, document, styles) now. Not a chrome frame (it
// draws the page's last frame, nothing of the page runs or is laid out there); not the interface thread while the
// page thread lays the page out (page_locked). Called where the shell reads or changes a layout.
page_world_check :: #force_inline proc(what: string) {
	when ODIN_DEBUG {
		if chrome_frames.nested { panic(what) }
		if chrome_frames.page_locked && sync.current_thread_id() != sync.atomic_load(&pt_thread_id) { panic(what) }
	}
}

@(private = "file")
pt_thread_id: int   // (the page thread's id: page_world_check)

// The last layout pass of `t` was long enough for the page thread (and the preference allows it).
page_layout_is_long :: proc(app: ^App, t: ^Tab) -> bool {
	last, known := pt.last_ms[t.id]
	return known && config.bool_of(&app.prefs, "browser.shell.page_thread") && chrome_frames.cfg.preempt && last >= config.float_of(&app.prefs, "browser.shell.page_thread_min_ms")
}

// Chrome frames can be made now (the frame is in its page phase, not inside one), and the preference allows it.
@(private = "file")
page_thread_wanted :: proc(app: ^App) -> bool {
	return config.bool_of(&app.prefs, "browser.shell.page_thread") && chrome_frames.cfg.preempt && chrome_frames.phase != .None && !chrome_frames.nested
}

@(private = "file")
layout_job_run :: proc(j: ^Layout_Job) {
	app := the_app
	layout_document(j.l, j.t.page.doc, j.styled, &app.measure, &app.page_settings.style, j.size, j.scale, app.cfg.layout_band_px, j.t.image_sizes, j.fonts_gen)
}

@(private = "file")
page_thread_main :: proc(data: rawptr) {
	p := (^Page_Thread)(data)
	sync.atomic_store(&pt_thread_id, sync.current_thread_id())
	for {
		sync.sema_wait(&p.go)
		if sync.atomic_load(&p.stop) { return }
		layout_job_run(&p.job)
		free_all(context.temp_allocator)
		sync.sema_post(&p.done)
	}
}

page_thread_destroy :: proc() {
	if pt.thread != nil {
		sync.atomic_store(&pt.stop, true)
		sync.sema_post(&pt.go)
		host.thread_join(pt.thread)
	}
	delete(pt.last_ms)
	pt = {}
}
