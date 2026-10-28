// The single import of the serialised boundary. On wasm32 it is the real Wasm import (module "url_abi", the module
// the host registered it under); on any other target it is a stub a host-side test installs to forward the call to
// the in-process dispatcher, so the exact guest bindings can be exercised without a Wasm instance.
package abi_guest

import "../abi"

when ODIN_ARCH == .wasm32 {

	foreign import _host "url_abi"

	@(default_calling_convention = "contextless")
	foreign _host {
		@(link_name = "host_call")
		host_call :: proc(op: i32, args: [^]u8, args_len: u32, ret: [^]u8, ret_cap: u32) -> abi.Status ---
	}

} else {

	// The forwarder a host test installs. It receives the guest's own buffers (native pointers here) and returns the
	// status, exactly as the Wasm import would. `install_host_call` plugs in the real dispatcher.
	host_call_fn: proc "contextless" (op: i32, args: [^]u8, args_len: u32, ret: [^]u8, ret_cap: u32) -> abi.Status

	host_call :: proc "contextless" (op: i32, args: [^]u8, args_len: u32, ret: [^]u8, ret_cap: u32) -> abi.Status {
		if host_call_fn == nil { return abi.Status(abi.Api_Error.Not_Supported) }
		return host_call_fn(op, args, args_len, ret, ret_cap)
	}

	install_host_call :: proc(fn: proc "contextless" (op: i32, args: [^]u8, args_len: u32, ret: [^]u8, ret_cap: u32) -> abi.Status) {
		host_call_fn = fn
	}

}
