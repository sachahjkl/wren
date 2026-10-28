// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=navigator order=49 exposed=(Window,Worker)
/// What the web APIs of JavaScript need beyond the modules Wasm pages use (native/js/runtime/web*.c): the browser's
/// identity for navigator, beacons, the screen, media queries scripts evaluate (matchMedia), and FormData file entries.
package api_js_web__navigator

/// A string member of Navigator.
NavigatorField :: enum i32 {
	/// navigator.userAgent: the User-Agent header the browser sends (network.user_agent).
	User_Agent,
	/// navigator.appVersion: the user agent without its leading "Mozilla/".
	App_Version,
	/// navigator.platform ("Win32").
	Platform,
	/// navigator.vendor.
	Vendor,
	/// navigator.languages, comma separated, from the Accept-Language preference (network.accept_language), without
	/// quality values.
	Languages,
	/// navigator.doNotTrack: "1", or "" for null (privacy.do_not_track).
	Do_Not_Track,
}

/// A string member of Navigator.
//@wb fn
Navigator_get :: proc(field: NavigatorField) -> string

/// navigator.hardwareConcurrency: the logical processors the page may use.
//@wb fn
Navigator_hardwareConcurrency :: proc() -> i32

/// navigator.onLine: whether the system has a network connection.
//@wb fn
Navigator_onLine :: proc() -> bool

/// navigator.maxTouchPoints: the touches the touch screen takes at once (0: none), as browser.touch.expose says.
//@wb fn
Navigator_maxTouchPoints :: proc() -> i32

/// navigator.cookieEnabled: whether the document may use cookies.
//@wb fn
Navigator_cookieEnabled :: proc() -> bool

/// navigator.userActivation.isActive: whether the document has transient activation now (a recent click or key press
/// within the transient activation window, security.webauthn.user_activation_ms).
//@wb fn
UserActivation_isActive :: proc() -> bool

/// navigator.userActivation.hasBeenActive: whether the document has ever had an activation-triggering input (sticky:
/// it does not expire).
//@wb fn
UserActivation_hasBeenActive :: proc() -> bool

/// navigator.sendBeacon(url, data): a POST queued with the page's policy (CORS no-cors mode, credentials included),
/// whose response nobody reads; it is not cancelled when the page closes. False when the beacon is refused (too large:
/// navigator.beacon_max_bytes, or an invalid URL). `content_type` "" sends none.
//@wb fn optional=data
Beacon_send :: proc(url: string, data: bytes, content_type: string = "") -> bool

/// navigator.clipboard.writeText(data): puts the text on the system clipboard. Fulfilled when it is there; rejected
/// with NotAllowedError when the document is not focused and has no recent click or key press, when the clipboard
/// cannot be had, or when writing is turned off (navigator.clipboard_write).
//@wb fn
Clipboard_writeText :: proc(data: string) -> Promise

/// navigator.clipboard.readText(): the text on the system clipboard (an empty string when it holds none). Rejected
/// with NotAllowedError unless the document is focused and has a recent click or key press (there is no permission
/// prompt), or when reading is turned off (navigator.clipboard_read).
//@wb fn
Clipboard_readText :: proc() -> Promise(string)

