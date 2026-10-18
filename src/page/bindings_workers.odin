package page

// Imports: module "workers" (HTML §10, dedicated workers).
//
// In a page:
//   Worker_create(url, name) -> worker        a Worker object (EventTarget: message, messageerror, error), 0 if refused
//   Worker_postMessage(worker, text, transfer) -> err
//   Worker_terminate(worker) -> err
// In a worker:
//   DedicatedWorkerGlobalScope_self() -> scope       the global scope (EventTarget: message, messageerror); 0 in a page
//   DedicatedWorkerGlobalScope_postMessage(text, transfer) -> err
//   DedicatedWorkerGlobalScope_close() -> err
//   DedicatedWorkerGlobalScope_name(buf) -> len
//   WorkerGlobalScope_location(buf) -> len          the worker's script URL
// Both:
//   MessageEvent_transfer(event, index) -> buffer   the buffers that came with a message event
//
// `transfer` is a list of buffer handles (i64 each, `bytes` long). A message event carries the text in Event_data, the
// number of transferred buffers in Event_code and the first one in Event_object; the buffers belong to the receiver
// (release them with Object_release). Errors: Invalid_Handle (not a Worker), Invalid_Argument (a handle that is not a
// transferable buffer or appears twice, a message over workers.max_message_bytes, a receiver with too much waiting,
// or a function of the other context: a page calling a worker function or the reverse).

import "wb:dom"
import "wb:wasm"

@(private)
handle_list :: #force_inline proc "contextless" (list: [^]u8, bytes: i32) -> []u64 {
	n := max(bytes, 0) / 8
	return ([^]u64)(list)[:n]
}

n_Worker_create :: proc "c" (env: wasm.Exec_Env, src: [^]u8, sl: i32, name: [^]u8, nl: i32) -> u64 {
	context = ctx()
	return worker_create(page_of(env), str(src, sl), str(name, nl), inst_of(env).index)
}

n_Worker_postMessage :: proc "c" (env: wasm.Exec_Env, w: u64, text: [^]u8, tl: i32, list: [^]u8, lb: i32) -> i32 {
	context = ctx()
	p := page_of(env)
	if p.worker != nil { return i32(dom.Error.Invalid_Argument) }
	return i32(worker_post(p, w, str(text, tl), handle_list(list, lb)))
}

n_Worker_terminate :: proc "c" (env: wasm.Exec_Env, w: u64) -> i32 {
	context = ctx()
	return i32(worker_terminate_object(page_of(env), w))
}

n_DedicatedWorkerGlobalScope_self :: proc "c" (env: wasm.Exec_Env) -> u64 {
	p := page_of(env)
	return p.worker != nil ? p.worker.self : 0
}

n_DedicatedWorkerGlobalScope_postMessage :: proc "c" (env: wasm.Exec_Env, text: [^]u8, tl: i32, list: [^]u8, lb: i32) -> i32 {
	context = ctx()
	return i32(worker_post_to_page(page_of(env), str(text, tl), handle_list(list, lb)))
}

n_DedicatedWorkerGlobalScope_close :: proc "c" (env: wasm.Exec_Env) -> i32 {
	context = ctx()
	p := page_of(env)
	if p.worker == nil { return i32(dom.Error.Invalid_Argument) }
	worker_close(p)
	return 0
}

n_DedicatedWorkerGlobalScope_name :: proc "c" (env: wasm.Exec_Env, buf: [^]u8, cap: i32) -> i32 {
	p := page_of(env)
	if p.worker == nil { return i32(dom.Error.Invalid_Argument) }
	return out_string(p.worker.name, buf, cap)
}

n_WorkerGlobalScope_location :: proc "c" (env: wasm.Exec_Env, buf: [^]u8, cap: i32) -> i32 {
	p := page_of(env)
	if p.worker == nil { return i32(dom.Error.Invalid_Argument) }
	return out_string(p.worker.url, buf, cap)
}

n_MessageEvent_transfer :: proc "c" (env: wasm.Exec_Env, ev: u64, index: i32) -> u64 {
	context = ctx()
	return message_transfer(page_of(env), ev, int(index))
}

workers_symbols := [?]wasm.Native_Symbol{
	{"Worker_create", rawptr(n_Worker_create), "(*~*~)I", nil},
	{"Worker_postMessage", rawptr(n_Worker_postMessage), "(I*~*~)i", nil},
	{"Worker_terminate", rawptr(n_Worker_terminate), "(I)i", nil},
	{"DedicatedWorkerGlobalScope_self", rawptr(n_DedicatedWorkerGlobalScope_self), "()I", nil},
	{"DedicatedWorkerGlobalScope_postMessage", rawptr(n_DedicatedWorkerGlobalScope_postMessage), "(*~*~)i", nil},
	{"DedicatedWorkerGlobalScope_close", rawptr(n_DedicatedWorkerGlobalScope_close), "()i", nil},
	{"DedicatedWorkerGlobalScope_name", rawptr(n_DedicatedWorkerGlobalScope_name), "(*~)i", nil},
	{"WorkerGlobalScope_location", rawptr(n_WorkerGlobalScope_location), "(*~)i", nil},
	{"MessageEvent_transfer", rawptr(n_MessageEvent_transfer), "(Ii)I", nil},
}
