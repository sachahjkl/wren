package web

// Promise-based Fetch API (import module "fetch"). The response handle is a fetch handle: Fetch_status, Fetch_headers,
// Fetch_url... apply, and Fetch_release frees it. Rejections carry Web_Error codes (Network, Abort...) and a message.

foreign import fetch_mod "fetch"

@(default_calling_convention = "contextless")
foreign fetch_mod {
	@(link_name = "Fetch_promise") raw_fetchPromise :: proc(url: [^]u8, ul: i32, method: [^]u8, ml: i32, headers: [^]u8, hl: i32, body: [^]u8, bl: i32, body_buffer: Handle, options: i32, signal: Handle) -> Handle ---
	@(link_name = "Fetch_startWithSignal") raw_fetchWithSignal :: proc(url: [^]u8, ul: i32, method: [^]u8, ml: i32, headers: [^]u8, hl: i32, body: [^]u8, bl: i32, body_buffer: Handle, options: i32, callback: Fetch_Callback, user: i32, signal: Handle) -> Handle ---
	// promise: text of the body (Promise_value = its length, promise_text = the text)
	Response_text :: proc(response: Handle) -> Handle ---
	// promise: Promise_value = a buffer handle with the body
	Response_arrayBuffer :: proc(response: Handle) -> Handle ---
	Response_bytes :: proc(response: Handle) -> Handle ---
	Response_bodyUsed :: proc(response: Handle) -> i32 ---
	// a stream of the body; 0 when it was already used
	Response_body :: proc(response: Handle) -> Handle ---
	// promise: Promise_value = a buffer with the next chunk, 0 at the end
	Stream_read :: proc(stream: Handle) -> Handle ---
	Stream_cancel :: proc(stream: Handle) -> Error ---
}

Fetch_Init :: struct {
	method:      string,
	headers:     string,      // "Name: value" lines
	body:        []u8,
	body_buffer: Handle,      // instead of body
	options:     Fetch_Options,
	signal:      Handle,
}

@(private)
pack_options :: proc "contextless" (opt: Fetch_Options) -> i32 {
	o := u32(opt.mode) | u32(opt.credentials) << 2 | u32(opt.redirect) << 4 | (opt.referrer_policy & 0xF) << 6
	if opt.no_referrer { o |= 1 << 10 }
	return i32(o)
}

// fetch(url, init): a promise fulfilled with the response handle (Promise_value) once the headers are in.
fetch_promise :: proc "contextless" (url: string, init := Fetch_Init{}) -> Handle {
	m := init.method if init.method != "" else "GET"
	return raw_fetchPromise(raw_data(url), i32(len(url)), raw_data(m), i32(len(m)), raw_data(init.headers), i32(len(init.headers)),
		raw_data(init.body), i32(len(init.body)), init.body_buffer, pack_options(init.options), init.signal)
}

// The callback API with an abort signal.
fetch_with_signal :: proc "contextless" (url: string, cb: Fetch_Callback, user: i32, init := Fetch_Init{}) -> Handle {
	m := init.method if init.method != "" else "GET"
	return raw_fetchWithSignal(raw_data(url), i32(len(url)), raw_data(m), i32(len(m)), raw_data(init.headers), i32(len(init.headers)),
		raw_data(init.body), i32(len(init.body)), init.body_buffer, pack_options(init.options), cb, user, init.signal)
}
