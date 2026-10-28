// errors.odin: the exception throwers and the error-as-value constructors of wj.h / web.h (real symbols). A thrower
// returns EXCEPTION and sets the pending exception; a *_value / *_exception constructor returns the error object as a
// value (for a promise rejection reason). One declaration per symbol.
package wj

@(default_calling_convention = "c")
foreign {
	// throwers (C varargs for the *_type / *_range: the glue passes a plain message, keep formats %-safe)
	wj_throw_type        :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---
	wj_throw_range       :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> JSValue ---
	wj_throw_dom         :: proc(ctx: ^Context, name: cstring, message: cstring) -> JSValue ---
	wj_throw_status      :: proc(ctx: ^Context, status: i32, what: cstring) -> JSValue ---
	wj_throw_unsupported :: proc(ctx: ^Context, iface: cstring, member: cstring) -> JSValue ---
	// (wj_throw_arity is implemented in Odin: convert.odin)

	// error-as-value constructors (web.h)
	web_dom_exception :: proc(ctx: ^Context, name: cstring, message: cstring) -> JSValue ---
	web_type_error    :: proc(ctx: ^Context, message: cstring) -> JSValue ---
	web_range_error   :: proc(ctx: ^Context, message: cstring) -> JSValue ---
}
