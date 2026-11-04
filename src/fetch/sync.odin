package fetch

// A document's synchronous XMLHttpRequest. The window's loop cannot turn while a script waits on the window's thread: it would
// run the tasks and timers of every page under the waiting script. So such a request has a stack of its own on that thread: a
// loop, a network client and a loader, made at the first one, over the same profile (cookies, cache, HSTS: nothing else
// touches them while the thread waits). Only this request's events run in its turns.

import "wb:host"
import "wb:net"

// Enough for the files such a request reads: it waits for one job at a time.
SYNC_BLOCKING_WORKERS :: 1

@(private)
Sync_Stack :: struct {
	loop:     host.Loop,
	client:   net.Client,
	blocking: host.Blocking_Pool,
	loader:   Loader,
}

// The loader of the waiting requests of `l`, with what `l` observes and blocks today. nil when the client cannot start.
sync_loader :: proc(l: ^Loader) -> ^Loader {
	if l.sync == nil {
		s := new(Sync_Stack)
		host.loop_init(&s.loop)
		if !net.client_init(&s.client, &s.loop, l.net.settings) {
			host.loop_destroy(&s.loop)
			free(s)
			return nil
		}
		host.blocking_init(&s.blocking, &s.loop, SYNC_BLOCKING_WORKERS)
		loader_init(&s.loader, &s.loop, &s.client, &s.blocking, l.profile)
		l.sync = s
	}
	s := l.sync
	s.loader.observer, s.loader.observers, s.loader.interceptor = l.observer, l.observers, l.interceptor
	return &s.loader
}

// One turn of the loader of sync_loader: what is ready runs, after a wait of `max_ms` at most for something to be.
sync_turn :: proc(l: ^Loader, max_ms: int) { host.loop_wait(l.loop, max_ms) }

@(private)
sync_destroy :: proc(l: ^Loader) {
	s := l.sync
	if s == nil { return }
	s.loader.observers = nil   // (`l`'s)
	loader_destroy(&s.loader)
	host.blocking_destroy(&s.blocking)
	net.client_destroy(&s.client)
	host.loop_drain(&s.loop)
	host.loop_destroy(&s.loop)
	free(s)
	l.sync = nil
}
