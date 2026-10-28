// The baseline: the current wr_* scalar ABI, hand-written exactly as src/tools/bindgen emits it (a proc "c" that
// reads the raw cells and calls the implementation). Registered under module "url_scalar" next to the serialised
// boundary, so the same guest, same engine, same machine times both and the design note compares like with like.
// These two imports mirror URLSearchParams_size (handle -> i32) and URL_get (handle, enum -> string into a (ptr,cap)
// buffer): the two shapes the generic path is measured against.
package abi_bench

import "base:intrinsics"
import "../abi_url"
import "wb:base"
import "wb:url"
import "wb:wasm"

@(private) scalar_params_size := [1]wasm.Val_Kind{.I64}
@(private) scalar_params_size_res := [1]wasm.Val_Kind{.I32}
@(private) scalar_get_params := [4]wasm.Val_Kind{.I64, .I32, .I32, .I32}
@(private) scalar_get_wide := [4]wasm.Val_Kind{.I64, .I32, .I64, .I64}
@(private) scalar_get_res := [1]wasm.Val_Kind{.I32}

scalar_imports := [2]wasm.Import{
	{module = "url_scalar", name = "size", fn = t_size, realms = 3, params = scalar_params_size[:], results = scalar_params_size_res[:]},
	{module = "url_scalar", name = "get", fn = t_get, realms = 3, params = scalar_get_params[:], results = scalar_get_res[:], wide_params = scalar_get_wide[:], wide_results = scalar_get_res[:]},
}

// URLSearchParams_size: a[0] = handle (i64), result into a[0].i32. The whole trampoline — no serialisation, the
// argument is already a scalar, exactly as the generated C does.
t_size :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	f := wasm.frame(env, caller)
	context = wasm.default_context()
	h := base.Handle(a[0].i64)
	o := base.pool_get(&abi_url.host.params, h)
	r: i32 = o != nil ? i32(len(o.sp.list)) : 0
	a[0] = {}
	a[0].i32 = r
	return nil
}

// URL_get: a[0] = handle, a[1] = component (enum i32), a[2] = buffer ptr, a[3] = buffer cap. The result string is
// copied into the guest buffer and its full length returned (the (ptr,cap) convention), exactly as generated.
t_get :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	f := wasm.frame(env, caller)
	context = wasm.default_context()
	on := wasm.addr(&f, a[3])
	os, ok := wasm.span(&f, wasm.addr(&f, a[2]), on)
	if !ok { return wasm.trap_bounds(&f, "url_scalar.get", "result buffer") }
	h := base.Handle(a[0].i64)
	o := base.pool_get(&abi_url.host.urls, h)
	s: string
	if o != nil { s = url.component(o.u, url.Component(a[1].i32), context.temp_allocator) }
	copy(os[:on], transmute([]u8)s)
	wasm.put_size(&f, a, i64(len(s)))
	return nil
}

_ :: intrinsics
