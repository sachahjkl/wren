// errors.odin: the exception throwers and the error-as-value constructors of wj.h / web.h. A thrower returns EXCEPTION
// and sets the pending exception; a *_value / *_exception constructor returns the error object as a value (for a
// promise rejection reason). The throwers are implemented in qjs_errors.odin, the error values in web_core.odin
// (exported under their C names).
package wj

// wj_throw_type / wj_throw_range are the engine's own JS_ThrowTypeError / JS_ThrowRangeError (wj.h defines them as
// macros for the C): the C versions formatted into 512 bytes then threw "%s", which the engine formats into 256 again,
// so the message is the same. C varargs: pass cstring / i32 / f64, keep formats %-safe.
wj_throw_type  :: JS_ThrowTypeError
wj_throw_range :: JS_ThrowRangeError
// (wj_throw_arity is implemented in Odin: convert.odin)
