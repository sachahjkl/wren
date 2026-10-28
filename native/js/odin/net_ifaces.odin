// net_ifaces.odin: the interfaces the network, stream and blob domains name (web_abort, web_blob, web_formdata,
// web_stream, web_writable, web_transform, web_pipe, web_fetch, web_xhr, web_socket), resolved by name once and cached.
// An enumerator is spelled as its interface is named, so the name comes from the enum itself: no table to keep in step.
package odin_glue

import "base:runtime"
import "../odin/wj"

Net_Iface :: enum u8 {
	Blob, File, FileReader, ProgressEvent, MediaSource,
	FormData, HTMLFormElement, HTMLElement, URLSearchParams, Document,
	ReadableStream, ReadableStreamDefaultReader, ReadableStreamDefaultController,
	WritableStream, WritableStreamDefaultWriter, WritableStreamDefaultController,
	TransformStream, TransformStreamDefaultController, TextDecoderStream, TextEncoderStream,
	CompressionStream, DecompressionStream, TextDecoder, TextEncoder, AbortController, AbortSignal,
	Headers, Request, Response, XMLHttpRequest, XMLHttpRequestUpload,
	WebSocket, CloseEvent, EventSource, MessageEvent, MessagePort, Event,
}

// The interface index of `k` (-1 when the table has no such interface).
net_iface :: proc "contextless" (k: Net_Iface) -> i32 {
	@(static) cache: [Net_Iface]i32   // index + 2; 0 while unresolved
	if cache[k] == 0 {
		info, _ := runtime.type_info_base(type_info_of(Net_Iface)).variant.(runtime.Type_Info_Enum)
		name: [64]u8
		n := copy(name[:len(name) - 1], info.names[int(k)])
		name[n] = 0
		cache[k] = wj.iface(cstring(&name[0])) + 2
	}
	return cache[k] - 2
}
