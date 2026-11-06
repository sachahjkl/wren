#+build windows
package e2e_scenarios

// Closing with every processor busy, a video playing (test_all -Perf, alone: it saturates the machine): `quit` with a client connected, and the window closed as its button does, must end
// within CLOSE_LIMIT with no forced exit. A close that waits for a thread of lower priority starved by the load fails here (the disk cache's writer did: ten seconds).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import "core:testing"
import "core:thread"
import "core:time"
import "wb:base"
import "wb:e2e"
import "wb:remote/api"

@(private = "file") ROUNDS :: 2
@(private = "file") CLOSE_LIMIT :: 8 * time.Second
// How long a video is given to play: the close is timed either way, on a machine whose every processor is busy.
@(private = "file") PLAY_LIMIT :: 3 * time.Second
@(private = "file") PLAYING :: `document.getElementById("round").currentTime > 0.5`
@(private = "file") FORCED_WORDS :: "ending the process"

@(private = "file")
Load :: struct { stop: bool, threads: [dynamic]^thread.Thread }

// Every processor busy until load_stop.
@(private = "file")
load_start :: proc(load: ^Load) {
	for _ in 0 ..< os.get_processor_core_count() {
		th := thread.create(proc(th: ^thread.Thread) {
			l := (^Load)(th.data)
			n := 0
			for !sync.atomic_load(&l.stop) { n += 1 }
		})
		th.data = load
		thread.start(th)
		append(&load.threads, th)
	}
}

@(private = "file")
load_stop :: proc(load: ^Load) {
	sync.atomic_store(&load.stop, true)
	for th in load.threads { thread.destroy(th) }
	delete(load.threads)
}

@(private = "file")
playing :: proc(t: ^testing.T, url, profile: string) -> ^e2e.Wren_Process {
	p := e2e.launch(t, {hidden = true, profile = profile})
	api.navigate(p.s, url)
	stop := p.s.on_failure
	p.s.on_failure = nil
	api.wait_js(p.s, PLAYING, PLAY_LIMIT)
	p.s.on_failure = stop
	return p
}

@(private = "file")
close_all_windows :: proc(pid: int) {
	win.EnumWindows(proc "system" (h: win.HWND, l: win.LPARAM) -> win.BOOL {
		owner: win.DWORD
		win.GetWindowThreadProcessId(h, &owner)
		if owner == win.DWORD(l) { win.PostMessageW(h, win.WM_CLOSE, 0, 0) }
		return true
	}, win.LPARAM(pid))
}

@(test)
closing_with_every_processor_busy :: proc(t: ^testing.T) {
	if base.perf_skip("the browser closes within 8 s with every processor busy") { return }
	url := e2e.url(e2e.test_server(t), "/site/video.html")
	load: Load
	load_start(&load)
	defer load_stop(&load)
	for round in 1 ..= ROUNDS {
		// `quit`, a client connected
		profile := e2e.temp_profile(t)
		p := playing(t, url, profile)
		listener: api.Conn
		testing.expect(t, api.connect(&listener, p.wren.name, e2e.PROCESS_WAIT_MS))
		began := time.tick_now()
		EXIT_CODE :: 3
		testing.expect_value(t, e2e.quit(p, EXIT_CODE), EXIT_CODE)
		took := time.tick_since(began)
		api.disconnect(&listener)
		testing.expectf(t, took < CLOSE_LIMIT, "round %d: quit with a client connected and a video playing: %v", round, took)
		testing.expect(t, !strings.contains(e2e.read_text(fmt.tprintf("%s/shutdown.log", profile)), FORCED_WORDS), "no forced exit")

		// the window's button: WM_CLOSE
		profile = e2e.temp_profile(t)
		p = playing(t, url, profile)
		pid := p.wren.pid
		began = time.tick_now()
		close_all_windows(pid)
		testing.expect(t, api.process_wait(&p.wren.process, int(e2e.PROCESS_WAIT_MS)), "it ends")
		took = time.tick_since(began)
		p.s.on_failure = nil
		testing.expectf(t, took < CLOSE_LIMIT, "round %d: the window closed with a video playing: %v", round, took)
		testing.expect(t, !strings.contains(e2e.read_text(fmt.tprintf("%s/shutdown.log", profile)), FORCED_WORDS), "no forced exit")
	}
}
