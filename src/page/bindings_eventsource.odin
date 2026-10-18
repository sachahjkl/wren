package page

// Imports of module "eventsource": EventSource and the MessageEvent members that are not plain event payload.
// See eventsource.odin for the semantics.

import "wb:dom"
import "wb:wasm"

n_EventSource_create :: proc "c" (env: wasm.Exec_Env, target: [^]u8, tl: i32, with_credentials: i32) -> u64 {
	context = ctx()
	return eventsource_create(page_of(env), inst_of(env).index, str(target, tl), with_credentials != 0)
}

n_EventSource_readyState :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	if es := eventsource_get(page_of(env), h); es != nil { return es.state }
	return i32(dom.Error.Invalid_Handle)
}

n_EventSource_url :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	if es := eventsource_get(page_of(env), h); es != nil { return out_string(es.href, buf, cap) }
	return i32(dom.Error.Invalid_Handle)
}

n_EventSource_withCredentials :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	if es := eventsource_get(page_of(env), h); es != nil { return es.with_credentials ? 1 : 0 }
	return i32(dom.Error.Invalid_Handle)
}

n_EventSource_close :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	es := eventsource_get(page_of(env), h)
	if es == nil { return i32(dom.Error.Invalid_Handle) }
	eventsource_close(es)
	return 0
}

n_MessageEvent_origin :: proc "c" (env: wasm.Exec_Env, ev: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	e := with_event(env, ev)
	if e == nil { return i32(dom.Error.Invalid_Handle) }
	return out_string(message_event_origin(page_of(env), e), buf, cap)
}

n_MessageEvent_lastEventId :: proc "c" (env: wasm.Exec_Env, ev: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	e := with_event(env, ev)
	if e == nil { return i32(dom.Error.Invalid_Handle) }
	if eventsource_get(page_of(env), u64(e.target)) == nil { return out_string("", buf, cap) }
	return out_string(e.text, buf, cap)
}

eventsource_symbols := [?]wasm.Native_Symbol{
	{"EventSource_create", rawptr(n_EventSource_create), "(*~i)I", nil},
	{"EventSource_readyState", rawptr(n_EventSource_readyState), "(I)i", nil},
	{"EventSource_url", rawptr(n_EventSource_url), "(I*~)i", nil},
	{"EventSource_withCredentials", rawptr(n_EventSource_withCredentials), "(I)i", nil},
	{"EventSource_close", rawptr(n_EventSource_close), "(I)i", nil},
	{"MessageEvent_origin", rawptr(n_MessageEvent_origin), "(I*~)i", nil},
	{"MessageEvent_lastEventId", rawptr(n_MessageEvent_lastEventId), "(I*~)i", nil},
}
