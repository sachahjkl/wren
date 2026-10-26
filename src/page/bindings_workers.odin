package page

// Module "workers" (HTML dedicated workers). In a page: Worker_create, Worker_postMessage, Worker_terminate. In a
// worker: the DedicatedWorkerGlobalScope functions. Both: MessageEvent_transfer. `transfer` lists buffer handles; a
// message event carries the text in Event_data, the number of transferred buffers in Event_code and the first one in
// Event_object; the buffers belong to the receiver. Invalid_Argument for a handle that is not a transferable buffer or
// appears twice, a message over workers.max_message_bytes, a receiver with too much waiting, or a function of the other
// side (a page calling a worker function or the reverse).

Worker_create :: proc(c: ^Call, src: string, name: string) -> (u64, Api_Error) {
	h := worker_create(c.page, src, name, c.owner)
	if h == 0 { return 0, fail(c, .Not_Allowed, "NotAllowedError: the worker was refused (see the console)") }
	return h, .None
}

Worker_postMessage :: proc(c: ^Call, worker: Api_Object, message: string, transfer: []u64) -> Api_Error {
	return dom_error(worker_post(c.page, worker.handle, message, transfer))
}

Worker_terminate :: proc(c: ^Call, worker: Api_Object) -> Api_Error { return dom_error(worker_terminate_object(c.page, worker.handle)) }

DedicatedWorkerGlobalScope_self :: proc(c: ^Call) -> u64 {
	p := c.page
	return p.worker != nil ? p.worker.self : 0
}

DedicatedWorkerGlobalScope_postMessage :: proc(c: ^Call, message: string, transfer: []u64) -> Api_Error {
	return dom_error(worker_post_to_page(c.page, message, transfer))
}

DedicatedWorkerGlobalScope_close :: proc(c: ^Call) -> Api_Error {
	p := c.page
	if p.worker == nil { return fail(c, .Invalid_Argument, "not in a worker") }
	worker_close(p)
	return .None
}

DedicatedWorkerGlobalScope_name :: proc(c: ^Call) -> (string, Api_Error) {
	p := c.page
	if p.worker == nil { return "", fail(c, .Invalid_Argument, "not in a worker") }
	return p.worker.name, .None
}

WorkerGlobalScope_location :: proc(c: ^Call) -> (string, Api_Error) {
	p := c.page
	if p.worker == nil { return "", fail(c, .Invalid_Argument, "not in a worker") }
	return p.worker.url, .None
}

MessageEvent_transfer :: proc(c: ^Call, event: Api_Event, index: i32) -> u64 { return message_transfer(c.page, event.handle, int(index)) }