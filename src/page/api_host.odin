package page

// What the generated bindings (api_generated.odin, from api/*.widl) need from the page:
//   * Call: the context of one import call; `api_begin` builds it from the calling instance, `api_end` closes it (the
//     custom element reactions it queued run then: js_custom_elements.odin);
//   * api_raise: records the exception of an import that raises (web.Exception_code / Exception_message read it back);
//   * one lookup per handle the API checks: the live object of that kind, or nil;
// and one implementation per import (bindings_*.odin), whose prototype is written above its trampoline.

import "base:runtime"
import "wb:base"
import "wb:dom"
import "wb:wasm"

Call :: struct {
	page:    ^Page,
	inst:    ^wasm.Instance,
	owner:   u32,      // the instance's index in the page: owner of what the call creates, target of its callbacks
	message: string,   // detail of the error an implementation returns (optional; must outlive the return)
	ce_mark: int,      // custom element reactions queued before the call (api_end runs only those it queued)
}

api_begin :: #force_inline proc "contextless" (inst: ^wasm.Instance) -> Call {
	p := (^Page)(inst.user)
	mark := p != nil && p.jsdom != nil ? len(p.jsdom.ce.queue) : 0
	return Call{page = p, inst = inst, owner = inst.index, ce_mark = mark}
}

api_raise :: proc(c: ^Call, code: Api_Error, message: string) {
	wasm.set_exception(c.inst, i32(code), message)
}

// The error of an implementation, with its message.
fail :: proc(c: ^Call, code: Api_Error, message: string) -> Api_Error {
	c.message = message
	return code
}

// dom.Error and the API's errors share their values.
dom_error :: #force_inline proc "contextless" (e: dom.Error) -> Api_Error { return Api_Error(e) }

// The document the calling module may touch; nil in a worker, which has none.
@(private)
call_doc :: #force_inline proc "contextless" (c: ^Call) -> ^dom.Document {
	return c.page.worker == nil ? c.page.doc : nil
}

@(private)
H :: #force_inline proc "contextless" (v: u64) -> base.Handle { return base.Handle(v) }

////////////////////////////////
// Lookups of checked handles

lookup_Node :: proc(c: ^Call, h: u64) -> ^dom.Node {
	d := call_doc(c)
	if d == nil { return nil }
	return dom.get(d, H(h))
}

lookup_Element :: proc(c: ^Call, h: u64) -> ^dom.Node {
	n := lookup_Node(c, h)
	if n == nil || n.kind != .Element { return nil }
	return n
}

lookup_Event :: proc(c: ^Call, h: u64) -> ^dom.Event { return base.pool_get(&c.page.dp.events, H(h)) }
lookup_Timer :: proc(c: ^Call, h: u64) -> ^Timer { return base.pool_get(&c.page.timers, H(h)) }
lookup_Fetch :: proc(c: ^Call, h: u64) -> ^Fetch { return base.pool_get(&c.page.fetches, H(h)) }
lookup_Object :: proc(c: ^Call, h: u64) -> ^Object { return object_get(c.page, h) }
lookup_Promise :: proc(c: ^Call, h: u64) -> ^Promise { return promise_get(c.page, h) }
lookup_Buffer :: proc(c: ^Call, h: u64) -> ^Buffer { return buffer_get(c.page, h) }
lookup_ReadableStream :: proc(c: ^Call, h: u64) -> ^Body_Stream { return stream_get(c.page, h) }
lookup_AbortController :: proc(c: ^Call, h: u64) -> ^Abort_Controller { return (^Abort_Controller)(object_data(c.page, h, &abort_controller_vt)) }
lookup_AbortSignal :: proc(c: ^Call, h: u64) -> ^Abort_Signal { return signal_get(c.page, h) }
lookup_TextDecoder :: proc(c: ^Call, h: u64) -> ^Text_Decoder { return decoder_get(c.page, h) }
lookup_URL :: proc(c: ^Call, h: u64) -> ^Url_Object { return url_obj(c.page, h) }
lookup_URLSearchParams :: proc(c: ^Call, h: u64) -> ^Params_Object { return params_obj(c.page, h) }
lookup_EventSource :: proc(c: ^Call, h: u64) -> ^Event_Source { return eventsource_get(c.page, h) }
lookup_WebSocket :: proc(c: ^Call, h: u64) -> ^Web_Socket { return websocket_get(c.page, h) }
lookup_FormData :: proc(c: ^Call, h: u64) -> ^Form_Data { return formdata_get(c.page, h) }

lookup_HTMLImageElement :: proc(c: ^Call, h: u64) -> ^Img_Element {
	if call_doc(c) == nil { return nil }
	return image_element(c.page, H(h))
}

////////////////////////////////
// Module "web"

Exception_code :: proc(c: ^Call) -> Api_Error { return Api_Error(c.inst.exception_code) }
Exception_message :: proc(c: ^Call) -> string { return c.inst.exception_message }

////////////////////////////////
// Module "console"

console_log :: proc(c: ^Call, message: string) { log(c.page, .Log, message) }
console_warn :: proc(c: ^Call, message: string) { log(c.page, .Warn, message) }
console_error :: proc(c: ^Call, message: string) { log(c.page, .Error, message) }

////////////////////////////////

// Registers every import. Call once, after wasm.runtime_init (it starts the engine if needed).
register_imports :: proc() -> bool {
	if !wasm.runtime_init() { return false }
	// WASI (the two calls the engine module imports: the clock and random bytes; the rest of the table is for other guests): its standard output and error go to the page's console
	wasm.wasi_output = proc(inst: ^wasm.Instance, fd: i32, text: []u8) {
		p := (^Page)(inst.user)
		if p == nil || p.closed { return }
		log(p, fd == 2 ? .Warn : .Log, string(text))
	}
	if !wasm.register_wasi() { return false }
	return api_register()
}

// Whether a worker's module may import module.name: what the description exposes to workers ([Exposed=Worker]).
@(private)
worker_import_filter :: proc(module_name, field: string) -> bool {
	realms, ok := wasm.import_realms(module_name, field)
	return ok && realms & API_WORKER != 0
}

_ :: runtime
