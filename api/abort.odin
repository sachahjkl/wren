// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=abort order=0 exposed=Window
/// AbortController and AbortSignal (DOM Standard). A signal is an EventTarget ("abort"). Its reason is a (code, text)
/// pair: AbortError by default, TimeoutError for AbortSignal.timeout(). Dependent signals (AbortSignal.any) follow their
/// sources as the specification describes.
package api_abort

//@wb handle parent=Object host=Abort_Controller lookup=lookup_AbortController
AbortController :: distinct Handle

//@wb handle parent=Object host=Abort_Signal lookup=lookup_AbortSignal
AbortSignal :: distinct Handle

/// new AbortController()
//@wb fn
AbortController_create :: proc() -> AbortController

/// controller.signal
//@wb fn
AbortController_signal :: proc(controller: AbortController) -> AbortSignal

/// controller.abort(reason): code 0 and an empty reason give the default AbortError.
//@wb fn
AbortController_abort :: proc(controller: AbortController, code: i64 = 0, reason: string = "")

/// signal.aborted
//@wb fn
AbortSignal_aborted :: proc(signal: AbortSignal) -> bool

/// The code of signal.reason (0 while not aborted).
//@wb fn
AbortSignal_reasonCode :: proc(signal: AbortSignal) -> i64

/// The text of signal.reason.
//@wb fn
AbortSignal_reason :: proc(signal: AbortSignal) -> string

/// signal.throwIfAborted(): 0, or the reason's code.
//@wb fn
AbortSignal_throwIfAborted :: proc(signal: AbortSignal) -> i64

/// AbortSignal.abort(reason): a signal aborted already.
//@wb fn
AbortSignal_abort :: proc(code: i64 = 0, reason: string = "") -> AbortSignal

/// AbortSignal.timeout(ms): aborted with TimeoutError after `ms`. Range for a negative or NaN delay.
//@wb fn raises
AbortSignal_timeout :: proc(ms: f64) -> AbortSignal

/// AbortSignal.any(signals). Invalid_Handle when one is not a signal, Range past abort.max_signal_sources.
//@wb fn raises
AbortSignal_any :: proc(signals: []AbortSignal) -> AbortSignal

