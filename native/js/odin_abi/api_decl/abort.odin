// Module abort (api/abort.widl): AbortController and AbortSignal on the browser's signals.
package api_decl

import "../abi"

AbortController :: distinct abi.Handle
AbortSignal :: distinct abi.Handle

// new AbortController()
AbortController_create :: #type proc() -> AbortController
// controller.signal
AbortController_signal :: #type proc(controller: AbortController) -> AbortSignal
// controller.abort(reason): code 0 and an empty reason give the default AbortError.
AbortController_abort :: #type proc(controller: AbortController, code: i64, reason: string)
// signal.aborted
AbortSignal_aborted :: #type proc(signal: AbortSignal) -> bool
// The code of signal.reason (0 while not aborted).
AbortSignal_reasonCode :: #type proc(signal: AbortSignal) -> i64
// The text of signal.reason.
AbortSignal_reason :: #type proc(signal: AbortSignal) -> string
// AbortSignal.abort(reason): a signal aborted already.
AbortSignal_abort :: #type proc(code: i64, reason: string) -> AbortSignal
// AbortSignal.timeout(ms): Range for a negative or NaN delay.
AbortSignal_timeout :: #type proc(ms: f64) -> (AbortSignal, abi.Api_Error)
// AbortSignal.any(signals): Invalid_Handle when one is not a signal, Range past abort.max_signal_sources.
AbortSignal_any :: #type proc(signals: []AbortSignal) -> (AbortSignal, abi.Api_Error)
