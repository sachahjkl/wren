package host

// Modal dialogs of the system (a file to open, a folder to save in) on a thread of their own each. Such a call returns
// when the person answers, minutes later perhaps: on the blocking pool it would hold a worker that long, and the file
// reads, the hashes and the other dialogs queued behind it would wait as long; on the loop's thread the window would
// stop drawing. `work` runs on the dialog's thread, `done` on the loop's afterwards, with the same data.
//
// The browser may end while a dialog is still open: dialogs_destroy does not wait for an answer that may never come.
// Such a thread is let go (it frees its own record when the dialog returns; its data is not freed: the process ends).

import "core:sync"
import "wb:base"

Dialogs :: struct {
	loop:    ^Loop,
	running: [dynamic]^Dialog_Run,   // loop thread only: the dialogs whose `done` has not run
}

// Dialog_Run.state (an integer: atomics take it as it is)
@(private) DIALOG_OPEN :: i32(0)
@(private) DIALOG_ANSWERED :: i32(1)
@(private) DIALOG_ORPHAN :: i32(2)

@(private)
Dialog_Run :: struct {
	d:       ^Dialogs,
	thread:  ^Thread,
	work, done, discard: Task_Proc,
	data:    rawptr,
	state:   i32,   // atomic: DIALOG_OPEN -> DIALOG_ANSWERED (its thread posts dialog_answered) or -> DIALOG_ORPHAN (dialogs_destroy let it go)
}

dialogs_init :: proc(d: ^Dialogs, loop: ^Loop) {
	d.loop = loop
	d.running = make([dynamic]^Dialog_Run, base.process_allocator())
}

// Loop thread. Runs `work(data)` on a new thread, then `done(data)` on the loop's. `discard`: what frees `data` when the
// browser ends after the answer came and before `done` ran (nil: nothing to free). false: no thread could be made, and
// nothing will run (the caller still owns `data`).
run_dialog :: proc(d: ^Dialogs, work, done: Task_Proc, data: rawptr, discard: Task_Proc = nil, name := "wren-dialog") -> bool {
	r := new(Dialog_Run, base.process_allocator())
	r.d, r.work, r.done, r.discard, r.data = d, work, done, discard, data
	// (listed before it starts: dialog_answered runs on this thread, so not before this call returns, whatever the thread does)
	append(&d.running, r)
	r.thread = thread_start(dialog_thread, r, name = name)
	if r.thread == nil {
		pop(&d.running)
		free(r, base.process_allocator())
		return false
	}
	return true
}

@(private)
dialog_thread :: proc(data: rawptr) {
	r := (^Dialog_Run)(data)
	r.work(r.data)
	if _, ok := sync.atomic_compare_exchange_strong(&r.state, DIALOG_OPEN, DIALOG_ANSWERED); ok {
		post(r.d.loop, dialog_answered, r)
	} else {
		free(r, base.process_allocator())   // let go by dialogs_destroy: nobody waits for this answer
	}
}

// Loop thread: the thread is done (it ends right after this post), `done` runs.
@(private)
dialog_answered :: proc(data: rawptr) {
	r := (^Dialog_Run)(data)
	thread_join(r.thread)
	dialog_forget(r.d, r)
	done, payload := r.done, r.data
	free(r, base.process_allocator())
	done(payload)
}

// What dialogs_destroy does with an answer whose `done` will not run.
@(private)
dialog_discard :: proc(data: rawptr) {
	r := (^Dialog_Run)(data)
	if r.thread != nil { thread_join(r.thread) }
	dialog_forget(r.d, r)
	if r.discard != nil { r.discard(r.data) }
	free(r, base.process_allocator())
}

@(private)
dialog_forget :: proc(d: ^Dialogs, r: ^Dialog_Run) {
	for x, i in d.running { if x == r { unordered_remove(&d.running, i); return } }
}

// Loop thread, as the browser ends, before the loop goes. A dialog still open is let go (its answer is ignored); one
// answered whose `done` has not run is discarded.
dialogs_destroy :: proc(d: ^Dialogs) {
	open := make([dynamic]^Dialog_Run, context.temp_allocator)
	for r in d.running {
		if _, ok := sync.atomic_compare_exchange_strong(&r.state, DIALOG_OPEN, DIALOG_ORPHAN); ok {
			append(&open, r)
		} else {
			thread_join(r.thread)   // answered: it posted dialog_answered, and ends
			r.thread = nil
		}
	}
	for r in open { dialog_forget(d, r) }   // (their threads own them now)
	discard_posted(d.loop, dialog_answered, dialog_discard)
	delete(d.running)
	d.running = nil
}

// Loop thread. Dialogs open now (their `done` has not run).
dialogs_open :: proc(d: ^Dialogs) -> int { return len(d.running) }
