package page

// Imports of module "websocket": WebSocket and CloseEvent. See websocket.odin for the semantics.
//   WebSocket_create(url, protocols): `protocols` is a comma-separated list ("" = none); 0 = SyntaxError.
//   WebSocket_close(ws, code, reason): code < 0 = absent.
//   Errors are negative: dom.Error.Invalid_Handle, or a Net_Api_Error (InvalidStateError, SyntaxError...).

import "wb:dom"
import "wb:fetch"
import "wb:wasm"

@(private)
ws_of :: proc(env: wasm.Exec_Env, h: u64) -> ^Web_Socket { return websocket_get(page_of(env), h) }

n_WebSocket_create :: proc "c" (env: wasm.Exec_Env, target: [^]u8, tl: i32, protocols: [^]u8, pl: i32) -> u64 {
	context = ctx()
	return websocket_create(page_of(env), inst_of(env).index, str(target, tl), fetch.websocket_split_protocols(str(protocols, pl)))
}

n_WebSocket_readyState :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	if w := ws_of(env, h); w != nil { return w.state }
	return i32(dom.Error.Invalid_Handle)
}

n_WebSocket_url :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	if w := ws_of(env, h); w != nil { return out_string(w.href, buf, cap) }
	return i32(dom.Error.Invalid_Handle)
}

n_WebSocket_protocol :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	if w := ws_of(env, h); w != nil { return out_string(w.protocol, buf, cap) }
	return i32(dom.Error.Invalid_Handle)
}

n_WebSocket_extensions :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	if w := ws_of(env, h); w != nil { return out_string(w.extensions, buf, cap) }
	return i32(dom.Error.Invalid_Handle)
}

n_WebSocket_bufferedAmount :: proc "c" (env: wasm.Exec_Env, h: u64) -> i64 {
	context = ctx()
	if w := ws_of(env, h); w != nil { return w.buffered }
	return i64(dom.Error.Invalid_Handle)
}

// 0 = "arraybuffer" (buffer handles), the only type this platform has.
n_WebSocket_binaryType :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	if ws_of(env, h) != nil { return 0 }
	return i32(dom.Error.Invalid_Handle)
}

n_WebSocket_setBinaryType :: proc "c" (env: wasm.Exec_Env, h: u64, type: i32) -> i32 {
	context = ctx()
	if ws_of(env, h) == nil { return i32(dom.Error.Invalid_Handle) }
	return type == 0 ? 0 : i32(Net_Api_Error.Not_Supported)
}

n_WebSocket_send :: proc "c" (env: wasm.Exec_Env, h: u64, data: [^]u8, n: i32) -> i32 {
	context = ctx()
	w := ws_of(env, h)
	if w == nil { return i32(dom.Error.Invalid_Handle) }
	return websocket_send(w, data[:max(n, 0)], false)
}

n_WebSocket_sendBuffer :: proc "c" (env: wasm.Exec_Env, h: u64, buffer: u64) -> i32 {
	context = ctx()
	p := page_of(env)
	w := websocket_get(p, h)
	if w == nil { return i32(dom.Error.Invalid_Handle) }
	b := buffer_get(p, buffer)
	if b == nil { return i32(dom.Error.Invalid_Handle) }
	return websocket_send(w, b.bytes[:], true)
}

n_WebSocket_close :: proc "c" (env: wasm.Exec_Env, h: u64, code: i32, reason: [^]u8, rl: i32) -> i32 {
	context = ctx()
	w := ws_of(env, h)
	if w == nil { return i32(dom.Error.Invalid_Handle) }
	return websocket_close(w, int(code), str(reason, rl))
}

n_CloseEvent_wasClean :: proc "c" (env: wasm.Exec_Env, ev: u64) -> i32 {
	context = ctx()
	e := with_event(env, ev)
	if e == nil { return i32(dom.Error.Invalid_Handle) }
	if w := websocket_get(page_of(env), u64(e.target)); w != nil && e.type == "close" { return w.was_clean ? 1 : 0 }
	return 0
}

websocket_symbols := [?]wasm.Native_Symbol{
	{"WebSocket_create", rawptr(n_WebSocket_create), "(*~*~)I", nil},
	{"WebSocket_readyState", rawptr(n_WebSocket_readyState), "(I)i", nil},
	{"WebSocket_url", rawptr(n_WebSocket_url), "(I*~)i", nil},
	{"WebSocket_protocol", rawptr(n_WebSocket_protocol), "(I*~)i", nil},
	{"WebSocket_extensions", rawptr(n_WebSocket_extensions), "(I*~)i", nil},
	{"WebSocket_bufferedAmount", rawptr(n_WebSocket_bufferedAmount), "(I)I", nil},
	{"WebSocket_binaryType", rawptr(n_WebSocket_binaryType), "(I)i", nil},
	{"WebSocket_setBinaryType", rawptr(n_WebSocket_setBinaryType), "(Ii)i", nil},
	{"WebSocket_send", rawptr(n_WebSocket_send), "(I*~)i", nil},
	{"WebSocket_sendBuffer", rawptr(n_WebSocket_sendBuffer), "(II)i", nil},
	{"WebSocket_close", rawptr(n_WebSocket_close), "(Ii*~)i", nil},
	{"CloseEvent_wasClean", rawptr(n_CloseEvent_wasClean), "(I)i", nil},
}
